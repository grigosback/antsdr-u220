// u220_stream: what happens on the data endpoints.
//
//   mode 0  drain      host->FPGA packets are counted and dropped, nothing is sent
//   mode 1  loopback   host->FPGA packets are sent back unchanged (16 KB FIFO)
//   mode 2  generator  FPGA sends packets as fast as USB takes them:
//                      header {seq, length bytes, "GEN0"} + gen_len words of a
//                      64-bit counter that keeps counting across packets
//
// Mode changes take effect at packet boundaries on each side.

`default_nettype none
module u220_stream (
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,      // reset counters + generator state (use with mode 0)
    input  wire [1:0]  mode,
    input  wire [12:0] gen_len,    // payload words per generator packet, 1..8190

    input  wire [63:0] tx_tdata,
    input  wire        tx_tlast,
    input  wire        tx_tvalid,
    output wire        tx_tready,

    output wire [63:0] rx_tdata,
    output wire        rx_tlast,
    output wire        rx_tvalid,
    input  wire        rx_tready,

    output reg  [31:0] tx_pkts,
    output reg  [31:0] tx_words,
    output reg  [31:0] rx_pkts,
    output reg  [31:0] rx_words
);
    localparam MODE_DRAIN = 2'd0, MODE_LOOP = 2'd1, MODE_GEN = 2'd2;

    // ---------------------------------------------------------------- tx side
    reg  tx_inpkt, tx_loop;
    wire tx_loop_now = tx_inpkt ? tx_loop : (mode == MODE_LOOP);
    wire lb_i_tready;
    assign tx_tready = tx_loop_now ? lb_i_tready : 1'b1;
    wire tx_xfer = tx_tvalid & tx_tready;

    always @(posedge clk)
        if (rst) begin
            tx_inpkt <= 1'b0;
            tx_loop  <= 1'b0;
        end else if (tx_xfer) begin
            tx_inpkt <= ~tx_tlast;
            tx_loop  <= tx_loop_now;
        end

    wire [63:0] lb_tdata;
    wire        lb_tlast, lb_tvalid, lb_tready;
    axi_fifo #(.WIDTH(65), .SIZE(11)) loop_fifo (
        .clk(clk), .reset(rst), .clear(1'b0),
        .i_tdata({tx_tlast, tx_tdata}), .i_tvalid(tx_tvalid & tx_loop_now), .i_tready(lb_i_tready),
        .o_tdata({lb_tlast, lb_tdata}), .o_tvalid(lb_tvalid), .o_tready(lb_tready),
        .space(), .occupied());

    // -------------------------------------------------------------- generator
    wire [12:0] gl = (gen_len == 13'd0) ? 13'd1 : (gen_len > 13'd8190) ? 13'd8190 : gen_len;
    wire [15:0] gen_bytes = {gl + 13'd1, 3'b000};   // (header + payload) * 8

    reg         gen_hdr;
    reg  [12:0] gen_left;
    reg  [15:0] gen_seq;
    reg  [63:0] gen_count;
    wire        gen_tready;
    wire [63:0] gen_tdata = gen_hdr ? {gen_seq, gen_bytes, 32'h47454E30} : gen_count;
    wire        gen_tlast = ~gen_hdr & (gen_left == 13'd1);
    wire        gen_xfer  = gen_tready;              // generator is always valid

    always @(posedge clk)
        if (rst) begin
            gen_hdr   <= 1'b1;
            gen_left  <= 13'd0;
            gen_seq   <= 16'd0;
            gen_count <= 64'd0;
        end else if (clear & gen_hdr) begin
            gen_seq   <= 16'd0;
            gen_count <= 64'd0;
        end else if (gen_xfer) begin
            if (gen_hdr) begin
                gen_hdr  <= 1'b0;
                gen_left <= gl;
            end else begin
                gen_count <= gen_count + 64'd1;
                gen_left  <= gen_left - 13'd1;
                if (gen_left == 13'd1) begin
                    gen_hdr <= 1'b1;
                    gen_seq <= gen_seq + 16'd1;
                end
            end
        end

    // ---------------------------------------------------------------- rx side
    reg        rx_inpkt;
    reg  [1:0] rx_sel;
    wire [1:0] rx_sel_now = rx_inpkt ? rx_sel : mode;

    assign rx_tdata   = (rx_sel_now == MODE_GEN) ? gen_tdata : lb_tdata;
    assign rx_tlast   = (rx_sel_now == MODE_GEN) ? gen_tlast : lb_tlast;
    assign rx_tvalid  = (rx_sel_now == MODE_GEN) ? 1'b1 :
                        (rx_sel_now == MODE_LOOP) ? lb_tvalid : 1'b0;
    assign lb_tready  = (rx_sel_now == MODE_LOOP) & rx_tready;
    assign gen_tready = (rx_sel_now == MODE_GEN) & rx_tready;
    wire   rx_xfer    = rx_tvalid & rx_tready;

    always @(posedge clk)
        if (rst) begin
            rx_inpkt <= 1'b0;
            rx_sel   <= MODE_DRAIN;
        end else if (rx_xfer) begin
            rx_inpkt <= ~rx_tlast;
            rx_sel   <= rx_sel_now;
        end

    // --------------------------------------------------------------- counters
    always @(posedge clk)
        if (rst | clear) begin
            tx_pkts  <= 32'd0;
            tx_words <= 32'd0;
            rx_pkts  <= 32'd0;
            rx_words <= 32'd0;
        end else begin
            if (tx_xfer) tx_words <= tx_words + 32'd1;
            if (tx_xfer & tx_tlast) tx_pkts <= tx_pkts + 32'd1;
            if (rx_xfer) rx_words <= rx_words + 32'd1;
            if (rx_xfer & rx_tlast) rx_pkts <= rx_pkts + 32'd1;
        end
endmodule
`default_nettype wire
