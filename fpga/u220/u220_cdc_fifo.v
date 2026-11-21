// u220_cdc_fifo: small asynchronous FIFO (gray-coded pointers, LUT RAM).
//
// Both sides have their own synchronous reset. After a reset of both sides
// the pointers start at zero together; the caller must keep the read side in
// reset until the write side has left reset (u220_radio does this with a
// reset acknowledge), so a reset is clean even when wr_clk starts late.
// Writes while full are dropped and flagged with wr_full.

`default_nettype none
module u220_cdc_fifo #(
    parameter WIDTH = 64,
    parameter AW    = 4          // log2 depth
)(
    input  wire             wr_clk,
    input  wire             wr_rst,
    input  wire [WIDTH-1:0] wr_data,
    input  wire             wr_en,
    output wire             wr_full,

    input  wire             rd_clk,
    input  wire             rd_rst,
    output wire [WIDTH-1:0] rd_data,
    output wire             rd_valid,
    input  wire             rd_ready
);
    (* ram_style = "distributed" *) reg [WIDTH-1:0] mem [0:(1<<AW)-1];

    reg [AW:0] wbin = 0, wgray = 0, rbin = 0, rgray = 0;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rgray_w1 = 0, rgray_w2 = 0;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wgray_r1 = 0, wgray_r2 = 0;

    // write side
    wire [AW:0] wbin_n = wbin + 1'b1;
    assign wr_full = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});

    always @(posedge wr_clk) begin
        rgray_w1 <= rgray;
        rgray_w2 <= rgray_w1;
        if (wr_rst) begin
            wbin  <= 0;
            wgray <= 0;
        end else if (wr_en && !wr_full) begin
            mem[wbin[AW-1:0]] <= wr_data;
            wbin  <= wbin_n;
            wgray <= wbin_n ^ (wbin_n >> 1);
        end
    end

    // read side
    wire [AW:0] rbin_n = rbin + 1'b1;
    assign rd_valid = ~rd_rst & (rgray != wgray_r2);
    assign rd_data  = mem[rbin[AW-1:0]];

    always @(posedge rd_clk) begin
        wgray_r1 <= wgray;
        wgray_r2 <= wgray_r1;
        if (rd_rst) begin
            rbin  <= 0;
            rgray <= 0;
        end else if (rd_valid && rd_ready) begin
            rbin  <= rbin_n;
            rgray <= rbin_n ^ (rbin_n >> 1);
        end
    end
endmodule
`default_nettype wire
