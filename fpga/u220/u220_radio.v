// u220_radio: AD9361 RX samples -> timestamped packets on bus_clk.
//
// radio_clk side (DATA_CLK):
//   - registers the IDDR outputs from u220_rx_io
//   - makes 16-bit samples, 12 bits left-justified: {Q[11:0], 4'b0, I[11:0], 4'b0}
//     (the usual sc16 layout: I first in memory, full scale +-32768)
//   - packs two samples per 64-bit word:
//       1 channel  (mimo = 0): one sample per DATA_CLK cycle, word = {sample n, sample n+1}
//       2 channels (mimo = 1): RX_FRAME high = channel 1, low = channel 2,
//                              word = {RX1 sample, RX2 sample} of the same instant
//   - test = 1 replaces I/Q with a 24-bit counter (I = n[11:0], Q = n[23:12])
//     that advances every DATA_CLK cycle, to check the packet path without RF
//   - writes the words into a 16-deep clock-crossing FIFO
//
// bus_clk side:
//   - the crossing FIFO is always read, so it never fills
//   - each packet is: header {seq[15:0], length bytes[15:0], "SMP", flags[7:0]},
//     time = per-channel sample count of the first sample, then spp data words.
//     flags: [0] packets were dropped before this one, [1] two channels.
//   - a packet is only started if the packet FIFO has room for all of it;
//     otherwise the whole packet is dropped (counted, time keeps running)
//   - enable = 0 finishes the current packet and stops; the time restarts at 0
//     on the next enable
//   - reset = 1 holds the clock crossing in reset and pads any unfinished
//     packet with zeros, so the output never has a partial packet. Hold it while
//     the AD9361 is reset or reconfigured (DATA_CLK stops or glitches), and
//     while changing mimo or test: they reach DATA_CLK a few cycles later, so
//     words already on their way would be packed the old way.
//   - DATA_CLK frequency is measured over METER_CYCLES bus_clk cycles

`default_nettype none
module u220_radio #(
    parameter        PKT_FIFO_SIZE = 13,           // log2 words in the packet FIFO
    parameter [31:0] METER_CYCLES  = 32'd10_000_000,
    parameter [31:0] METER_SCALE   = 32'd10        // bus_clk_hz / METER_CYCLES
)(
    // radio_clk side
    input  wire        radio_clk,
    input  wire [11:0] cap_i,
    input  wire [11:0] cap_q,
    input  wire        cap_fr_r,
    input  wire        cap_fr_f,

    // bus_clk side
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    input  wire        mimo,
    input  wire        test,
    input  wire        reset,
    input  wire [10:0] spp,          // payload words per packet, 1..2000

    output wire [63:0] o_tdata,
    output wire        o_tlast,
    output wire        o_tvalid,
    input  wire        o_tready,

    output wire [7:0]  status,
    output reg  [31:0] dclk_hz,
    output reg  [31:0] pkts,
    output reg  [31:0] drops
);
    // =================================================== radio_clk domain
    // reset and controls from bus_clk (quasi-static)
    (* ASYNC_REG = "TRUE" *) reg [2:0] r_rst_s = 3'b111;
    (* ASYNC_REG = "TRUE" *) reg [1:0] r_mimo_s = 2'b00, r_test_s = 2'b00;
    always @(posedge radio_clk) begin
        r_rst_s  <= {r_rst_s[1:0], rst | reset};
        r_mimo_s <= {r_mimo_s[0], mimo};
        r_test_s <= {r_test_s[0], test};
    end
    wire r_rst  = r_rst_s[2];
    wire r_mimo = r_mimo_s[1];
    wire r_test = r_test_s[1];

    // capture registers
    reg [11:0] s_i, s_q;
    reg        s_fr, s_ff;
    always @(posedge radio_clk) begin
        s_i  <= cap_i;
        s_q  <= cap_q;
        s_fr <= cap_fr_r;
        s_ff <= cap_fr_f;
    end

    reg  [23:0] tcnt = 24'd0;
    always @(posedge radio_clk) tcnt <= tcnt + 24'd1;

    wire [11:0] cur_i  = r_test ? tcnt[11:0]  : s_i;
    wire [11:0] cur_q  = r_test ? tcnt[23:12] : s_q;
    wire [31:0] sample = {cur_q, 4'd0, cur_i, 4'd0};

    reg  [31:0] hold;
    reg  [63:0] w_data;
    reg         w_en, phase, have, r_mimo_d;
    always @(posedge radio_clk) begin
        w_en     <= 1'b0;
        r_mimo_d <= r_mimo;
        if (r_rst || r_mimo != r_mimo_d) begin   // restart pairing on a mode change
            phase <= 1'b0;
            have  <= 1'b0;
        end else if (!r_mimo) begin
            phase <= ~phase;
            if (phase) begin
                w_data <= {hold, sample};
                w_en   <= 1'b1;
            end else
                hold <= sample;
        end else if (s_fr) begin
            hold <= sample;
            have <= 1'b1;
        end else begin
            have <= 1'b0;
            if (have) begin
                w_data <= {hold, sample};
                w_en   <= 1'b1;
            end
        end
    end

    // diagnostics: RX_FRAME (rising, falling) combinations seen, crossing overflow
    wire       w_full;
    reg  [3:0] fr_seen = 4'd0;
    reg        cdc_ovf = 1'b0;
    always @(posedge radio_clk)
        if (r_rst) begin
            fr_seen <= 4'd0;
            cdc_ovf <= 1'b0;
        end else begin
            fr_seen[{s_fr, s_ff}] <= 1'b1;
            if (w_en && w_full) cdc_ovf <= 1'b1;
        end

    // DATA_CLK cycle counter, gray coded for the crossing
    reg [23:0] dcnt = 24'd0, dgray = 24'd0;
    always @(posedge radio_clk) begin
        dcnt  <= dcnt + 24'd1;
        dgray <= dcnt ^ (dcnt >> 1);
    end

    // ===================================================== crossing
    // the read side stays in reset until the radio side acknowledges
    (* ASYNC_REG = "TRUE" *) reg [1:0] ack_s = 2'b11;
    always @(posedge clk) ack_s <= {ack_s[0], r_rst};
    wire b_xrst = rst | reset | ack_s[1];

    wire [63:0] x_tdata;
    wire        x_tvalid;
    reg         x_tready;
    u220_cdc_fifo #(.WIDTH(64), .AW(4)) xfifo (
        .wr_clk(radio_clk), .wr_rst(r_rst), .wr_data(w_data), .wr_en(w_en), .wr_full(w_full),
        .rd_clk(clk), .rd_rst(b_xrst), .rd_data(x_tdata), .rd_valid(x_tvalid), .rd_ready(x_tready));

    // ======================================================= bus_clk domain
    (* ASYNC_REG = "TRUE" *) reg [4:0] st_s1 = 5'd0, st_s2 = 5'd0;
    (* ASYNC_REG = "TRUE" *) reg [23:0] dg_s1 = 24'd0, dg_s2 = 24'd0;
    always @(posedge clk) begin
        st_s1 <= {cdc_ovf, fr_seen};
        st_s2 <= st_s1;
        dg_s1 <= dgray;
        dg_s2 <= dg_s1;
    end

    // gray -> binary
    reg [23:0] dbin;
    integer k;
    always @* begin
        dbin[23] = dg_s2[23];
        for (k = 22; k >= 0; k = k - 1)
            dbin[k] = dbin[k + 1] ^ dg_s2[k];
    end

    reg  [31:0] mcnt;
    reg  [23:0] dbin_prev;
    wire [23:0] ddiff = dbin - dbin_prev;   // modulo 2^24
    always @(posedge clk)
        if (rst) begin
            mcnt      <= 32'd0;
            dbin_prev <= 24'd0;
            dclk_hz   <= 32'd0;
        end else if (mcnt == METER_CYCLES - 1) begin
            mcnt      <= 32'd0;
            dbin_prev <= dbin;
            dclk_hz   <= ddiff * METER_SCALE;
        end else
            mcnt <= mcnt + 32'd1;

    // --------------------------------------------------------- packetizer
    localparam S_START = 3'd0, S_TIME = 3'd1, S_DATA = 3'd2, S_DROP = 3'd3, S_PAD = 3'd4;

    reg  [2:0]  state;
    reg  [10:0] n_spp, cnt;
    reg  [63:0] scount, t0;
    reg  [1:0]  step;
    reg  [15:0] seq;
    reg         ovf, p_mimo;
    reg  [63:0] p_tdata;
    reg         p_tlast, p_tvalid;
    reg         p_overrun;

    wire [15:0] space;
    wire        p_tready;
    wire [10:0] spp_c   = (spp == 11'd0) ? 11'd1 : (spp > 11'd2000) ? 11'd2000 : spp;
    wire [15:0] pkt_len = {2'b00, spp_c + 11'd2, 3'b000};
    wire        last    = (cnt == n_spp - 11'd1);
    wire        b_reset = rst | reset;

    always @* begin
        x_tready = 1'b0;
        case (state)
            S_START: x_tready = b_reset | ~enable;   // discard while idle
            S_DATA:  x_tready = ~b_reset;
            S_DROP:  x_tready = 1'b1;
            default: x_tready = 1'b0;
        endcase
    end
    wire x_take = x_tvalid & x_tready;

    always @(posedge clk) begin
        p_tvalid <= 1'b0;
        p_tlast  <= 1'b0;
        if (rst) begin
            state     <= S_START;
            scount    <= 64'd0;
            seq       <= 16'd0;
            ovf       <= 1'b0;
            pkts      <= 32'd0;
            drops     <= 32'd0;
            p_overrun <= 1'b0;
        end else begin
            if (p_tvalid && !p_tready) p_overrun <= 1'b1;   // should never happen
            case (state)
                S_START:
                    if (b_reset || !enable) begin
                        scount <= 64'd0;
                        seq    <= 16'd0;
                        ovf    <= 1'b0;
                    end else if (x_tvalid) begin
                        n_spp  <= spp_c;
                        step   <= mimo ? 2'd1 : 2'd2;
                        p_mimo <= mimo;
                        t0     <= scount;
                        cnt    <= 11'd0;
                        if (space >= {5'd0, spp_c} + 16'd6) begin
                            p_tdata  <= {seq, pkt_len, 24'h534D50, 6'd0, mimo, ovf};
                            p_tvalid <= 1'b1;
                            ovf      <= 1'b0;
                            state    <= S_TIME;
                        end else begin
                            ovf   <= 1'b1;
                            drops <= drops + 32'd1;
                            state <= S_DROP;
                        end
                    end
                S_TIME: begin
                    p_tdata  <= t0;
                    p_tvalid <= 1'b1;
                    state    <= b_reset ? S_PAD : S_DATA;
                end
                S_DATA:
                    if (b_reset)
                        state <= S_PAD;
                    else if (x_tvalid) begin
                        p_tdata  <= x_tdata;
                        p_tvalid <= 1'b1;
                        p_tlast  <= last;
                        scount   <= scount + step;
                        cnt      <= cnt + 11'd1;
                        if (last) begin
                            seq   <= seq + 16'd1;
                            pkts  <= pkts + 32'd1;
                            state <= S_START;
                        end
                    end
                S_PAD: begin
                    p_tdata  <= 64'd0;
                    p_tvalid <= 1'b1;
                    p_tlast  <= last;
                    cnt      <= cnt + 11'd1;
                    if (last) begin
                        seq   <= seq + 16'd1;
                        pkts  <= pkts + 32'd1;
                        state <= S_START;
                    end
                end
                S_DROP:
                    if (b_reset)
                        state <= S_START;
                    else if (x_tvalid) begin
                        scount <= scount + step;
                        cnt    <= cnt + 11'd1;
                        if (last) state <= S_START;
                    end
                default: state <= S_START;
            endcase
        end
    end

    axi_fifo #(.WIDTH(65), .SIZE(PKT_FIFO_SIZE)) pkt_fifo (
        .clk(clk), .reset(rst), .clear(1'b0),
        .i_tdata({p_tlast, p_tdata}), .i_tvalid(p_tvalid), .i_tready(p_tready),
        .o_tdata({o_tlast, o_tdata}), .o_tvalid(o_tvalid), .o_tready(o_tready),
        .space(space), .occupied());

    // [3:0] RX_FRAME (rise, fall) values seen: bit {rise, fall}
    // [4] crossing FIFO overflowed (should never happen)
    // [5] radio side out of reset (DATA_CLK running and reset released)
    // [6] packet FIFO overrun (should never happen)
    // [7] packetizer idle
    assign status = {state == S_START, p_overrun, ~ack_s[1], st_s2};
endmodule
`default_nettype wire
