// u220_spi: 24-bit SPI master for the AD9361.
//
// AD9361 word: [23] 1 = write, [22:20] byte count - 1 (0 here), [19:18] 0,
// [17:8] register address, [7:0] data. For a read, rdata[7:0] holds the value.
//
// SPI mode 1 (CPOL 0, CPHA 1), as the vendor simple_spi_core runs it with
// UHD's AD9361 settings: MOSI changes on SCLK rising edges and the AD9361
// samples it on falling edges; the AD9361 changes SPI_DO on rising edges and
// MISO is sampled just before the falling edge. Checked on the board: mode 0
// (MOSI changing on falling edges) gives garbage, and sampling MISO before
// the rising edge reads every value one bit late (0x05 instead of 0x0A).

`default_nettype none
module u220_spi (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] half_period,   // bus_clk cycles per SCLK half period (10 -> 5 MHz)
    input  wire        start,         // ignored while busy
    input  wire [23:0] wdata,
    output reg         busy,
    output reg  [23:0] rdata,

    output reg         sclk,
    output reg         sen_n,
    output reg         mosi,
    input  wire        miso           // asynchronous
);
    localparam IDLE = 2'd0, SHIFT = 2'd1, HOLD = 2'd2, GAP = 2'd3;

    reg [1:0]  state;
    reg [15:0] cnt;
    reg [4:0]  bits;
    reg [23:0] shreg;
    reg        miso_s1, miso_s2;
    wire [15:0] hp = (half_period == 16'd0) ? 16'd1 : half_period;
    wire        tick = (cnt == hp - 16'd1);

    always @(posedge clk) begin
        miso_s1 <= miso;
        miso_s2 <= miso_s1;
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            busy  <= 1'b0;
            sclk  <= 1'b0;
            sen_n <= 1'b1;
            mosi  <= 1'b0;
            cnt   <= 16'd0;
            bits  <= 5'd0;
            shreg <= 24'd0;
            rdata <= 24'd0;
        end else begin
            cnt <= tick ? 16'd0 : cnt + 16'd1;
            case (state)
                IDLE: begin
                    cnt <= 16'd0;
                    if (start) begin
                        busy  <= 1'b1;
                        sen_n <= 1'b0;
                        shreg <= wdata;
                        mosi  <= wdata[23];
                        bits  <= 5'd0;
                        state <= SHIFT;
                    end
                end
                SHIFT: if (tick) begin
                    if (!sclk) begin                        // rising edge: next MOSI bit
                        sclk <= 1'b1;
                        if (bits != 5'd0) begin
                            shreg <= {shreg[22:0], 1'b0};
                            mosi  <= shreg[22];
                        end
                    end else begin                          // falling edge: sample MISO
                        sclk  <= 1'b0;
                        rdata <= {rdata[22:0], miso_s2};
                        bits  <= bits + 5'd1;
                        if (bits == 5'd23)
                            state <= HOLD;
                    end
                end
                HOLD: if (tick) begin                       // hold time before deselect
                    sen_n <= 1'b1;
                    mosi  <= 1'b0;
                    state <= GAP;
                end
                GAP: if (tick) begin                        // minimum deselect time
                    busy  <= 1'b0;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
