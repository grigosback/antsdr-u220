// u220_rx_io: AD9361 RX data port capture (CMOS, DDR, 12 bits, FDD).
//
// Same capture structure as the vendor's antsdr_u205_io.v, which is known to
// work with UHD's B200 interface delays (rx clock 0, rx data 0xF):
// DATA_CLK -> BUFR clocks the IDDRs, and the same BUFR output drives a BUFG
// that clocks the rest of the radio logic (radio_clk). One DATA_CLK cycle
// carries one 12-bit I/Q pair: Q on the rising edge, I on the falling edge
// (UHD sets "swap I and Q" in AD9361 register 0x010).
//
// Outputs are the IDDR registers (BUFR domain); register them once on
// radio_clk before use. The TX port is not driven here.

`default_nettype none
module u220_rx_io (
    input  wire        dclk,        // CAT_DCLK_P
    input  wire        rx_frame,    // CAT_RX_FR_P
    input  wire [11:0] rx_data,     // CAT_P0_D

    output wire        radio_clk,
    output wire [11:0] cap_i,
    output wire [11:0] cap_q,
    output wire        cap_fr_r,    // RX_FRAME at the rising edge
    output wire        cap_fr_f     // RX_FRAME at the following falling edge
);
    wire cap_clk;
    BUFR #(.BUFR_DIVIDE("BYPASS"), .SIM_DEVICE("7SERIES")) bufr_dclk (
        .I(dclk), .O(cap_clk), .CE(1'b1), .CLR(1'b0));
    BUFG bufg_dclk (.I(cap_clk), .O(radio_clk));

    genvar n;
    generate
        for (n = 0; n < 12; n = n + 1) begin : g_iddr
            IDDR #(.DDR_CLK_EDGE("SAME_EDGE")) iddr (
                .C(cap_clk), .CE(1'b1), .R(1'b0), .S(1'b0),
                .D(rx_data[n]), .Q1(cap_q[n]), .Q2(cap_i[n]));
        end
    endgenerate

    IDDR #(.DDR_CLK_EDGE("SAME_EDGE")) iddr_frame (
        .C(cap_clk), .CE(1'b1), .R(1'b0), .S(1'b0),
        .D(rx_frame), .Q1(cap_fr_r), .Q2(cap_fr_f));
endmodule
`default_nettype wire
