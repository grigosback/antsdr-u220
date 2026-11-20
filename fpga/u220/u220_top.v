// u220_top: minimal own design for the ANTSDR U220 (XC7A200T + AD9361 + FX3).
//
// Keeps from the vendor design only:
//   - gpif2_slave_fifo32: the FPGA side of the stock FX3 firmware's slave FIFO
//   - gen_clks: MMCM, 40 MHz in -> 100 MHz bus_clk and gpif_clk
// Everything else is u220_core. At power-up the AD9361 is held in reset
// (CAT_CTRL), the TX amplifiers are off (FE_CTRL), and every other output sits
// at a fixed idle level. The AD9361 SPI is driven by u220_spi.

`default_nettype none
module u220_top (
    // AD9361 SPI + control
    output wire        CAT_SPI_EN,      // active low chip select
    input  wire        CAT_SPI_DO,
    output wire        CAT_SPI_DI,
    output wire        CAT_SPI_CLK,
    output wire        CAT_EN,
    output wire        CAT_EN_AGC,
    output wire        CAT_RESETn,
    output wire        CAT_TXnRX,
    output wire        CAT_SYNC,
    output wire [3:0]  CAT_CTL_IN,
    input  wire [7:0]  CAT_CTL_OUT,

    // AD9361 data port (CMOS, 12-bit): unused for now
    input  wire        CAT_DCLK_P,
    output wire        CAT_FBCLK_P,
    output wire        CAT_FBCLK_N,
    input  wire [11:0] CAT_P0_D,
    output wire [11:0] CAT_P1_D,
    input  wire        CAT_RX_FR_P,
    output wire        CAT_TX_FR_P,
    output wire        CAT_TX_FR_N,

    // FX3 GPIF II slave FIFO
    output wire        IFCLK,
    input  wire        FX3_EXTINT,
    output wire        GPIF_CTL0,       // slcs
    output wire        GPIF_CTL1,       // slwr
    output wire        GPIF_CTL2,       // sloe
    output wire        GPIF_CTL3,       // slrd
    output wire        GPIF_CTL7,       // pktend
    input  wire        GPIF_CTL4,       // flag: ready
    input  wire        GPIF_CTL5,       // flag: watermark
    input  wire        GPIF_CTL6,
    input  wire        GPIF_CTL8,
    output wire        GPIF_CTL11,      // fifoadr[1]
    output wire        GPIF_CTL12,      // fifoadr[0]
    inout  wire [31:0] GPIF_D,
    input  wire        GPIF_CTL9,

    // clocks / reference
    input  wire        CLK_40MHz_FPGA,
    input  wire        PPS_IN_EXT,
    input  wire        PPS_IN_INT,
    input  wire        CLKIN_10MHz,
    output wire        REF_CLK_REQ,
    output wire        CLK_40M_DAC_nSYNC,
    output wire        CLK_40M_DAC_SCLK,
    output wire        CLK_40M_DAC_DIN,

    // LEDs
    output wire        PPS_LED,
    output wire        REF_LOCKED,

    // GPS module
    output wire        GPS_nRST,
    output wire        GPS_UART_TX,
    input  wire        GPS_UART_RX,

    // RF front end
    output wire        tx_amp_en1,
    output wire        tx_amp_en2,
    output wire        FE_RX1_SEL1,
    output wire        FE_RX2_SEL1,
    output wire        FE_TXRX1_SEL1,
    output wire        FE_TXRX2_SEL1,

    // debug UART pins
    input  wire        FPGA_RXD0,
    output wire        FPGA_TXD0
);
    // ------------------------------------------------------------ clocks/reset
    wire bus_clk, gpif_clk, mmcm_locked;

    gen_clks clocks (
        .clk_in1(CLK_40MHz_FPGA),
        .clk_out1(),            // 40 MHz, unused
        .clk_out2(bus_clk),     // 100 MHz
        .clk_out3(gpif_clk),    // 100 MHz
        .locked(mmcm_locked));

    // hold everything in reset for 65536 cycles after the MMCM locks
    reg [15:0] ready_cnt = 16'd0;
    reg        clocks_ready = 1'b0;
    always @(posedge bus_clk or negedge mmcm_locked)
        if (!mmcm_locked) begin
            ready_cnt    <= 16'd0;
            clocks_ready <= 1'b0;
        end else if (!clocks_ready) begin
            ready_cnt    <= ready_cnt + 16'd1;
            clocks_ready <= (ready_cnt == 16'hFFFF);
        end

    wire bus_rst, gpif_rst;
    reset_sync bus_rst_sync  (.clk(bus_clk),  .reset_in(!clocks_ready), .reset_out(bus_rst));
    reset_sync gpif_rst_sync (.clk(gpif_clk), .reset_in(!clocks_ready), .reset_out(gpif_rst));

    // bitstream timestamp (BITSTREAM.CONFIG.USR_ACCESS TIMESTAMP in the xdc)
    wire [31:0] build_id;
    USR_ACCESSE2 usr_access (.DATA(build_id), .CFGCLK(), .DATAVALID());

    // ------------------------------------------------------------------- core
    wire [63:0] ctrl_tdata, resp_tdata, tx_tdata, rx_tdata;
    wire        ctrl_tlast, resp_tlast, tx_tlast, rx_tlast;
    wire        ctrl_tvalid, resp_tvalid, tx_tvalid, rx_tvalid;
    wire        ctrl_tready, resp_tready, tx_tready, rx_tready;

    wire [8:0]  cat_ctrl;
    wire [5:0]  fe_ctrl;
    wire [15:0] vctcxo_dac;
    wire        led_heartbeat, led_activity;

    u220_core core (
        .clk(bus_clk), .rst(bus_rst), .build_id(build_id),
        .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
        .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
        .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
        .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
        .cat_ctrl(cat_ctrl), .cat_ctrl_out(CAT_CTL_OUT), .fe_ctrl(fe_ctrl), .vctcxo_dac(vctcxo_dac),
        .spi_sclk(CAT_SPI_CLK), .spi_sen_n(CAT_SPI_EN), .spi_mosi(CAT_SPI_DI), .spi_miso(CAT_SPI_DO),
        .led_heartbeat(led_heartbeat), .led_activity(led_activity));

    // ------------------------------------------------------------------- FX3
    gpif2_slave_fifo32 #(.DATA_RX_FIFO_SIZE(14), .DATA_TX_FIFO_SIZE(14)) slave_fifo32 (
        .gpif_clk(gpif_clk), .gpif_rst(gpif_rst), .gpif_enb(1'b1),
        .gpif_ctl({GPIF_CTL8, GPIF_CTL6, GPIF_CTL5, GPIF_CTL4}), .fifoadr({GPIF_CTL11, GPIF_CTL12}),
        .slwr(GPIF_CTL1), .sloe(GPIF_CTL2), .slcs(GPIF_CTL0), .slrd(GPIF_CTL3), .pktend(GPIF_CTL7),
        .gpif_d(GPIF_D),
        .fifo_clk(bus_clk), .fifo_rst(bus_rst),
        .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
        .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
        .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
        .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
        .debug());

    // FX3 interface clock, forwarded through an ODDR as in the vendor design
    ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) ifclk_oddr (
        .Q(IFCLK), .C(gpif_clk), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));

    // ----------------------------------------------------------------- AD9361
    assign CAT_RESETn  = cat_ctrl[0];
    assign CAT_EN      = cat_ctrl[1];
    assign CAT_TXnRX   = cat_ctrl[2];
    assign CAT_EN_AGC  = cat_ctrl[3];
    assign CAT_CTL_IN  = cat_ctrl[7:4];
    assign CAT_SYNC    = cat_ctrl[8];


    assign CAT_FBCLK_P = 1'b0;
    assign CAT_FBCLK_N = 1'b0;
    assign CAT_TX_FR_P = 1'b0;
    assign CAT_TX_FR_N = 1'b0;
    assign CAT_P1_D    = 12'd0;

    // -------------------------------------------------------------- front end
    assign tx_amp_en1    = fe_ctrl[0];
    assign tx_amp_en2    = fe_ctrl[1];
    assign FE_RX1_SEL1   = fe_ctrl[2];
    assign FE_TXRX1_SEL1 = fe_ctrl[3];
    assign FE_RX2_SEL1   = fe_ctrl[4];
    assign FE_TXRX2_SEL1 = fe_ctrl[5];

    // ------------------------------------------------------------ oscillator
    ltc2630_spi vctcxo_trim (
        .clk(bus_clk), .rst(bus_rst), .data(vctcxo_dac),
        .sclk(CLK_40M_DAC_SCLK), .mosi(CLK_40M_DAC_DIN), .sync_n(CLK_40M_DAC_nSYNC));
    assign REF_CLK_REQ = 1'b1;          // as in the vendor design

    // ------------------------------------------------------------------ misc
    assign PPS_LED     = led_heartbeat;
    assign REF_LOCKED  = led_activity;
    assign GPS_nRST    = 1'b1;
    assign GPS_UART_TX = 1'b1;
    assign FPGA_TXD0   = 1'b1;
endmodule
`default_nettype wire
