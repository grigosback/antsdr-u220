// u220_gps: watch the GPS module and reference inputs (all asynchronous, sampled on clk).
//
//   - UART receiver on gps_rx (8N1, divider = clk cycles per bit) into a
//     512-byte ring buffer; the host reads it 4 bytes at a time by address.
//   - shortest pulse seen on gps_rx (one bit time of whatever baud rate the
//     module uses), so the host can find the baud rate.
//   - for each of pps_int, pps_ext, clk10 and gps_rx: rising edges in the last
//     gate period (1 s by default: PPS gives 1, a 10 MHz clock 10000000) and in total.
//   - for pps_int and pps_ext: clk cycles between the last two rising edges,
//     which measures the 40 MHz oscillator (clk is derived from it) against the PPS.
//
// Edges are counted by sampling at clk, so inputs up to about clk / 4 are counted
// correctly (10 MHz at 100 MHz).
`default_nettype none
module u220_gps #(
    parameter [31:0] GATE_CYCLES = 32'd100_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        gps_rx,
    input  wire        pps_int,
    input  wire        pps_ext,
    input  wire        clk10,

    input  wire [15:0] uart_div,
    input  wire [8:0]  raddr,
    output wire [31:0] rdata,        // bytes raddr .. raddr+3, raddr in [7:0]
    output reg  [31:0] wcount,       // bytes received in total (write pointer)
    output reg  [31:0] ferr,         // framing errors
    input  wire        minw_clear,
    output reg  [31:0] minw,         // shortest gps_rx pulse in clk cycles

    output wire [3:0]  levels,       // {clk10, gps_rx, pps_ext, pps_int}
    output wire [127:0] rate,        // edges in the last gate period, 4 x 32
    output wire [127:0] total,       // edges in total, 4 x 32
    output reg  [31:0] period_int,
    output reg  [31:0] period_ext
);
    // ------------------------------------------------------------- synchronise
    (* ASYNC_REG = "TRUE" *) reg [3:0] s1, s2;
    reg [3:0] s3;
    always @(posedge clk) begin
        s1 <= {clk10, gps_rx, pps_ext, pps_int};
        s2 <= s1;
        s3 <= s2;
    end
    assign levels = s2;
    wire [3:0] rise = s2 & ~s3;
    wire       rx   = s2[2];

    // ------------------------------------------------------------ edge meters
    reg [31:0] gate;
    reg [31:0] cnt   [0:3];
    reg [31:0] rate_r[0:3];
    reg [31:0] tot   [0:3];
    integer k;
    always @(posedge clk)
        if (rst) begin
            gate <= 32'd0;
            for (k = 0; k < 4; k = k + 1) begin
                cnt[k] <= 32'd0; rate_r[k] <= 32'd0; tot[k] <= 32'd0;
            end
        end else begin
            gate <= (gate == GATE_CYCLES - 1) ? 32'd0 : gate + 32'd1;
            for (k = 0; k < 4; k = k + 1) begin
                if (rise[k]) tot[k] <= tot[k] + 32'd1;
                if (gate == GATE_CYCLES - 1) begin
                    rate_r[k] <= cnt[k] + rise[k];
                    cnt[k]    <= 32'd0;
                end else if (rise[k])
                    cnt[k] <= cnt[k] + 32'd1;
            end
        end
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : g_out
        assign rate[32*g +: 32]  = rate_r[g];
        assign total[32*g +: 32] = tot[g];
    end endgenerate

    // ------------------------------------------------------------ PPS periods
    reg [31:0] since_int, since_ext;
    always @(posedge clk)
        if (rst) begin
            since_int <= 32'd0; since_ext <= 32'd0; period_int <= 32'd0; period_ext <= 32'd0;
        end else begin
            since_int <= rise[0] ? 32'd1 : (&since_int ? since_int : since_int + 32'd1);
            since_ext <= rise[1] ? 32'd1 : (&since_ext ? since_ext : since_ext + 32'd1);
            if (rise[0]) period_int <= since_int;
            if (rise[1]) period_ext <= since_ext;
        end

    // ------------------------------------------------------ shortest rx pulse
    reg [31:0] run;
    reg        rx_d;
    always @(posedge clk)
        if (rst || minw_clear) begin
            run <= 32'd0; rx_d <= rx; minw <= 32'hFFFFFFFF;
        end else begin
            rx_d <= rx;
            if (rx != rx_d) begin
                if (run != 32'd0 && run < minw) minw <= run;  // skip the first, partial run
                run <= 32'd1;
            end else if (run != 32'd0 && !(&run))
                run <= run + 32'd1;
        end

    // ------------------------------------------------------------ UART receiver
    localparam IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0]  st;
    reg [15:0] tick;
    reg [2:0]  nbit;
    reg [7:0]  sh;
    reg [7:0]  mem [0:511];
    reg        we;
    reg [7:0]  wbyte;

    always @(posedge clk)
        if (rst) begin
            st <= IDLE; tick <= 16'd0; nbit <= 3'd0; sh <= 8'd0;
            wcount <= 32'd0; ferr <= 32'd0; we <= 1'b0; wbyte <= 8'd0;
        end else begin
            we <= 1'b0;
            if (we) wcount <= wcount + 32'd1;
            case (st)
                IDLE:  if (!rx) begin st <= START; tick <= {1'b0, uart_div[15:1]}; end
                START: if (tick == 16'd0) begin
                           if (rx) st <= IDLE;              // glitch, not a start bit
                           else begin st <= DATA; tick <= uart_div - 16'd1; nbit <= 3'd0; end
                       end else tick <= tick - 16'd1;
                DATA:  if (tick == 16'd0) begin
                           sh <= {rx, sh[7:1]};
                           tick <= uart_div - 16'd1;
                           nbit <= nbit + 3'd1;
                           if (nbit == 3'd7) st <= STOP;
                       end else tick <= tick - 16'd1;
                STOP:  if (tick == 16'd0) begin
                           if (rx) begin we <= 1'b1; wbyte <= sh; end
                           else ferr <= ferr + 32'd1;
                           st <= IDLE;                      // a framing error waits for idle again
                       end else tick <= tick - 16'd1;
            endcase
        end

    always @(posedge clk)
        if (we) mem[wcount[8:0]] <= wbyte;

    assign rdata = {mem[raddr + 9'd3], mem[raddr + 9'd2], mem[raddr + 9'd1], mem[raddr]};
endmodule
`default_nettype wire
