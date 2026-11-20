// u220_core: register file + control parser + data streams, all on bus_clk.
//
// Register map (32-bit registers, 16-bit addresses):
//
//   0x0000 ro  ID            0x55323230 ("U220")
//   0x0001 ro  VERSION       [31:16] major, [15:0] minor of this design
//   0x0002 ro  BUILD         bitstream timestamp (USR_ACCESS)
//   0x0003 rw  SCRATCH
//   0x0004 ro  UPTIME_LO     bus_clk cycles since reset; reading it latches UPTIME_HI
//   0x0005 ro  UPTIME_HI
//   0x0006 ro  BUS_CLK_HZ
//
//   0x0010 rw  STREAM_MODE   0 drain, 1 loopback, 2 generator (see u220_stream.v)
//   0x0011 rw  GEN_LEN       generator payload words per packet (default 1021 = 8176-byte packets)
//   0x0012 ro  TX_PKTS       host->FPGA data packets
//   0x0013 ro  TX_WORDS      host->FPGA 64-bit words
//   0x0014 ro  RX_PKTS       FPGA->host data packets
//   0x0015 ro  RX_WORDS      FPGA->host 64-bit words
//   0x0016 wo  STREAM_CLEAR  write 1: clear counters and generator (do it in mode 0)
//
//   0x0020 rw  CAT_CTRL      AD9361 pins: [0] RESETn, [1] EN, [2] TXnRX, [3] EN_AGC,
//                            [7:4] CTRL_IN, [8] SYNC. Default 0x1E: held in reset.
//   0x0021 ro  CAT_CTRL_OUT  AD9361 CTRL_OUT[7:0]
//   0x0022 rw  FE_CTRL       [0] TX amp 1, [1] TX amp 2, [2] FE_RX1_SEL1, [3] FE_TXRX1_SEL1,
//                            [4] FE_RX2_SEL1, [5] FE_TXRX2_SEL1. Default 0: amps off.
//   0x0023 rw  VCTCXO_DAC    40 MHz oscillator trim DAC, default 0xBFFF (same as stock)
//
//   0x0030 rw  SPI_XFER      write: start a 24-bit AD9361 transfer (see u220_spi.v)
//                            read: {busy, 7'b0, last 24 bits shifted in}
//   0x0031 ro  SPI_RDATA     last 24 bits shifted in; [7:0] = register value of a read
//   0x0032 rw  SPI_HALF      SCLK half period in bus_clk cycles, default 10 (5 MHz).
//                            Reads work up to 10 MHz on the board; at 16.7 MHz MISO is one bit late.
//   Accesses to 0x0030 and 0x0031 wait in hardware until the previous transfer
//   is done, so a control packet can carry several SPI writes and reads back to back.
//
// Unmapped addresses read 0xDEADBEEF.

`default_nettype none
module u220_core #(
    parameter [15:0] VERSION_MAJOR = 16'd1,
    parameter [15:0] VERSION_MINOR = 16'd1,
    parameter [31:0] BUS_CLK_HZ    = 32'd100_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] build_id,

    input  wire [63:0] ctrl_tdata,  input  wire ctrl_tlast,  input  wire ctrl_tvalid,  output wire ctrl_tready,
    output wire [63:0] resp_tdata,  output wire resp_tlast,  output wire resp_tvalid,  input  wire resp_tready,
    input  wire [63:0] tx_tdata,    input  wire tx_tlast,    input  wire tx_tvalid,    output wire tx_tready,
    output wire [63:0] rx_tdata,    output wire rx_tlast,    output wire rx_tvalid,    input  wire rx_tready,

    output reg  [8:0]  cat_ctrl,
    input  wire [7:0]  cat_ctrl_out,   // asynchronous
    output reg  [5:0]  fe_ctrl,
    output reg  [15:0] vctcxo_dac,

    output wire        spi_sclk,
    output wire        spi_sen_n,
    output wire        spi_mosi,
    input  wire        spi_miso,

    output wire        led_heartbeat,
    output wire        led_activity
);
    // ------------------------------------------------------------ register bus
    wire        reg_wr, reg_rd;
    wire [15:0] reg_addr;
    wire [31:0] reg_wdata;
    reg  [31:0] reg_rdata;
    wire        reg_wait;

    u220_ctrl ctrl (
        .clk(clk), .rst(rst),
        .i_tdata(ctrl_tdata), .i_tlast(ctrl_tlast), .i_tvalid(ctrl_tvalid), .i_tready(ctrl_tready),
        .o_tdata(resp_tdata), .o_tlast(resp_tlast), .o_tvalid(resp_tvalid), .o_tready(resp_tready),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .reg_wait(reg_wait));

    // --------------------------------------------------------------- registers
    reg  [31:0] scratch;
    reg  [63:0] uptime;
    reg  [31:0] uptime_hi_latch;
    reg  [1:0]  stream_mode;
    reg  [12:0] gen_len;
    reg         stream_clear;
    reg  [7:0]  cat_ctrl_out_s1, cat_ctrl_out_s2;
    reg  [15:0] spi_half;
    wire        spi_busy;
    wire [23:0] spi_rdata;
    assign reg_wait = spi_busy & (reg_addr == 16'h0030 || reg_addr == 16'h0031);
    wire [31:0] tx_pkts, tx_words, rx_pkts, rx_words;

    always @(posedge clk) begin
        cat_ctrl_out_s1 <= cat_ctrl_out;
        cat_ctrl_out_s2 <= cat_ctrl_out_s1;
    end

    always @(posedge clk)
        if (rst) uptime <= 64'd0;
        else     uptime <= uptime + 64'd1;

    always @(posedge clk) begin
        if (rst) begin
            scratch         <= 32'd0;
            uptime_hi_latch <= 32'd0;
            stream_mode     <= 2'd0;
            gen_len         <= 13'd1021;
            stream_clear    <= 1'b0;
            cat_ctrl        <= 9'h01E;
            fe_ctrl         <= 6'd0;
            vctcxo_dac      <= 16'hBFFF;
            spi_half        <= 16'd10;
        end else begin
            stream_clear <= 1'b0;
            if (reg_rd && reg_addr == 16'h0004)
                uptime_hi_latch <= uptime[63:32];
            if (reg_wr)
                case (reg_addr)
                    16'h0003: scratch      <= reg_wdata;
                    16'h0010: stream_mode  <= reg_wdata[1:0];
                    16'h0011: gen_len      <= reg_wdata[12:0];
                    16'h0016: stream_clear <= reg_wdata[0];
                    16'h0020: cat_ctrl     <= reg_wdata[8:0];
                    16'h0022: fe_ctrl      <= reg_wdata[5:0];
                    16'h0023: vctcxo_dac   <= reg_wdata[15:0];
                    16'h0032: spi_half     <= reg_wdata[15:0];
                    default: ;
                endcase
        end
    end

    always @* begin
        case (reg_addr)
            16'h0000: reg_rdata = 32'h55323230;
            16'h0001: reg_rdata = {VERSION_MAJOR, VERSION_MINOR};
            16'h0002: reg_rdata = build_id;
            16'h0003: reg_rdata = scratch;
            16'h0004: reg_rdata = uptime[31:0];
            16'h0005: reg_rdata = uptime_hi_latch;
            16'h0006: reg_rdata = BUS_CLK_HZ;
            16'h0010: reg_rdata = {30'd0, stream_mode};
            16'h0011: reg_rdata = {19'd0, gen_len};
            16'h0012: reg_rdata = tx_pkts;
            16'h0013: reg_rdata = tx_words;
            16'h0014: reg_rdata = rx_pkts;
            16'h0015: reg_rdata = rx_words;
            16'h0016: reg_rdata = 32'd0;
            16'h0020: reg_rdata = {23'd0, cat_ctrl};
            16'h0021: reg_rdata = {24'd0, cat_ctrl_out_s2};
            16'h0022: reg_rdata = {26'd0, fe_ctrl};
            16'h0023: reg_rdata = {16'd0, vctcxo_dac};
            16'h0030: reg_rdata = {spi_busy, 7'd0, spi_rdata};
            16'h0031: reg_rdata = {8'd0, spi_rdata};
            16'h0032: reg_rdata = {16'd0, spi_half};
            default:  reg_rdata = 32'hDEADBEEF;
        endcase
    end

    // --------------------------------------------------------------- AD9361 SPI
    u220_spi spi (
        .clk(clk), .rst(rst), .half_period(spi_half),
        .start(reg_wr && reg_addr == 16'h0030), .wdata(reg_wdata[23:0]),
        .busy(spi_busy), .rdata(spi_rdata),
        .sclk(spi_sclk), .sen_n(spi_sen_n), .mosi(spi_mosi), .miso(spi_miso));

    // ----------------------------------------------------------------- streams
    u220_stream stream (
        .clk(clk), .rst(rst), .clear(stream_clear),
        .mode(stream_mode), .gen_len(gen_len),
        .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
        .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
        .tx_pkts(tx_pkts), .tx_words(tx_words), .rx_pkts(rx_pkts), .rx_words(rx_words));

    // -------------------------------------------------------------------- LEDs
    // heartbeat: ~0.75 Hz square wave at 100 MHz; activity: stretched USB traffic
    assign led_heartbeat = uptime[26];

    reg [22:0] act_cnt;   // ~84 ms at 100 MHz
    wire traffic = (ctrl_tvalid & ctrl_tready) | (tx_tvalid & tx_tready) | (rx_tvalid & rx_tready);
    always @(posedge clk)
        if (rst)          act_cnt <= 23'd0;
        else if (traffic) act_cnt <= {23{1'b1}};
        else if (act_cnt != 23'd0) act_cnt <= act_cnt - 23'd1;
    assign led_activity = (act_cnt != 23'd0);
endmodule
`default_nettype wire
