// u220_ctrl: control packets from the host -> register bus -> response packets.
//
// Packets are streams of 64-bit words (bits [63:32] travel first on USB).
//
//   word 0 (header)  [63:48] seq   [47:32] packet length in bytes   [31:0] tag
//   word 1..N (ops)  [63] write    [62:48] 0   [47:32] reg address  [31:0] write data
//
// The response has the same length: the header is echoed unchanged and each
// op word comes back as {op[63:32], read data}. The read happens in the same
// cycle as the write, so a write returns the register's previous value.
//
// The length field must be right: the GPIF interface checks it against the
// number of words it receives.

`default_nettype none
module u220_ctrl (
    input  wire        clk,
    input  wire        rst,

    input  wire [63:0] i_tdata,
    input  wire        i_tlast,
    input  wire        i_tvalid,
    output wire        i_tready,

    output reg  [63:0] o_tdata,
    output reg         o_tlast,
    output reg         o_tvalid,
    input  wire        o_tready,

    output wire        reg_wr,     // one-cycle strobe: write reg_wdata to reg_addr
    output wire        reg_rd,     // one-cycle strobe: reg_rdata is being returned
    output wire [15:0] reg_addr,
    output wire [31:0] reg_wdata,
    input  wire [31:0] reg_rdata   // combinational from reg_addr
);
    reg expect_hdr;

    assign i_tready  = ~o_tvalid | o_tready;
    wire   accept    = i_tvalid & i_tready;
    wire   is_op     = ~expect_hdr;

    assign reg_addr  = i_tdata[47:32];
    assign reg_wdata = i_tdata[31:0];
    assign reg_wr    = accept & is_op & i_tdata[63];
    assign reg_rd    = accept & is_op;

    always @(posedge clk) begin
        if (rst) begin
            expect_hdr <= 1'b1;
            o_tvalid   <= 1'b0;
            o_tlast    <= 1'b0;
            o_tdata    <= 64'd0;
        end else begin
            if (o_tvalid & o_tready)
                o_tvalid <= 1'b0;
            if (accept) begin
                o_tvalid   <= 1'b1;
                o_tlast    <= i_tlast;
                o_tdata    <= is_op ? {i_tdata[63:32], reg_rdata} : i_tdata;
                expect_hdr <= i_tlast;
            end
        end
    end
endmodule
`default_nettype wire
