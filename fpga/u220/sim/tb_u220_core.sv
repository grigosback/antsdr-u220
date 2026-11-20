// Self-checking testbench for u220_core: registers, loopback, generator,
// with random backpressure on both outputs. Run with sim/run.sh.
`timescale 1ns/1ps
module tb_u220_core;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [63:0] ctrl_tdata, resp_tdata, tx_tdata, rx_tdata;
    logic        ctrl_tlast, resp_tlast, tx_tlast, rx_tlast;
    logic        ctrl_tvalid = 0, resp_tvalid, tx_tvalid = 0, rx_tvalid;
    logic        ctrl_tready, resp_tready, tx_tready, rx_tready;
    logic [8:0]  cat_ctrl;
    logic [5:0]  fe_ctrl;
    logic [15:0] vctcxo_dac;
    logic        spi_sclk, spi_sen_n, spi_mosi, spi_miso;
    int errors = 0;
    logic rx_en = 1;   // testbench only accepts RX data while a receiver is listening

    u220_core dut (
        .clk(clk), .rst(rst), .build_id(32'hB01DB01D),
        .ctrl_tdata, .ctrl_tlast, .ctrl_tvalid, .ctrl_tready,
        .resp_tdata, .resp_tlast, .resp_tvalid, .resp_tready,
        .tx_tdata, .tx_tlast, .tx_tvalid, .tx_tready,
        .rx_tdata, .rx_tlast, .rx_tvalid, .rx_tready,
        .cat_ctrl, .cat_ctrl_out(8'hA5), .fe_ctrl, .vctcxo_dac,
        .spi_sclk, .spi_sen_n, .spi_mosi, .spi_miso,
        .led_heartbeat(), .led_activity());

    // AD9361 SPI model: 24-bit words, [23] write, [17:8] address, [7:0] data.
    // Mode 1 like the real chip: samples MOSI on falling edges, drives MISO on rising edges.
    logic [7:0]  ad_regs [0:1023];
    logic [23:0] ad_in;
    logic [15:0] ad_instr;
    int          ad_bits;
    initial begin
        foreach (ad_regs[i]) ad_regs[i] = 8'h00;
        ad_regs[10'h037] = 8'h0A;   // product ID
    end
    always @(negedge spi_sen_n) begin ad_bits = 0; ad_in = 0; spi_miso = 0; end
    always @(negedge spi_sclk) if (!spi_sen_n) begin
        ad_in = {ad_in[22:0], spi_mosi};
        ad_bits++;
        if (ad_bits == 16) ad_instr = ad_in[15:0];
        if (ad_bits == 24 && ad_in[23]) ad_regs[ad_in[17:8]] = ad_in[7:0];
    end
    always @(posedge spi_sclk) if (!spi_sen_n && ad_bits >= 16 && ad_bits < 24 && !ad_instr[15])
        spi_miso <= #3 ad_regs[ad_instr[9:0]][23 - ad_bits];
    always @(posedge spi_sen_n) spi_miso = 1'bz;

    // random backpressure
    always @(posedge clk) begin
        resp_tready <= ($urandom % 4) != 0;
        rx_tready   <= rx_en && (($urandom % 3) != 0);
    end

    task automatic check(string what, logic [63:0] got, logic [63:0] exp);
        if (got !== exp) begin
            $display("FAIL %s: got %016h expected %016h", what, got, exp);
            errors++;
        end
    endtask

    // one send/receive task per channel (xsim can't drive signals through ref args)
    `define SEND_TASK(name, d, l, v, r) \
    task automatic name(input logic [63:0] words[$]); \
        foreach (words[i]) begin \
            d <= words[i]; l <= (i == words.size() - 1); v <= 1; \
            do @(posedge clk); while (!r); \
        end \
        v <= 0; \
    endtask
    `define RECV_TASK(name, d, l, v, r) \
    task automatic name(output logic [63:0] words[$]); \
        words = {}; \
        forever begin \
            @(posedge clk); \
            if (v && r) begin words.push_back(d); if (l) break; end \
        end \
    endtask
    `SEND_TASK(ctrl_send, ctrl_tdata, ctrl_tlast, ctrl_tvalid, ctrl_tready)
    `SEND_TASK(tx_send,   tx_tdata,   tx_tlast,   tx_tvalid,   tx_tready)
    `RECV_TASK(resp_recv, resp_tdata, resp_tlast, resp_tvalid, resp_tready)
    `RECV_TASK(rx_recv,   rx_tdata,   rx_tlast,   rx_tvalid,   rx_tready)

    // one control packet with n ops -> response
    function automatic logic [63:0] op(bit wr, logic [15:0] addr, logic [31:0] data);
        return {wr, 15'd0, addr, data};
    endfunction

    task automatic transact(input logic [63:0] ops[$], input logic [15:0] seq,
                            output logic [63:0] resp[$]);
        logic [63:0] pkt[$];
        pkt = {{seq, 16'((ops.size() + 1) * 8), 32'hCAFE0000 | seq}};
        foreach (ops[i]) pkt.push_back(ops[i]);
        fork
            ctrl_send(pkt);
            resp_recv(resp);
        join
        check("resp length", resp.size(), pkt.size());
        check("resp header", resp[0], pkt[0]);
    endtask

    task automatic wr(logic [15:0] addr, logic [31:0] data);
        logic [63:0] r[$];
        transact({op(1, addr, data)}, 16'h7777, r);
    endtask

    function automatic logic [31:0] lo(logic [63:0] w); return w[31:0]; endfunction

    initial begin
        logic [63:0] r[$], pkt[$], got[$];
        repeat (10) @(posedge clk);
        rst <= 0;
        repeat (5) @(posedge clk);

        // ---- registers
        transact({op(0, 16'h0000, 0), op(0, 16'h0001, 0), op(0, 16'h0002, 0),
                  op(1, 16'h0003, 32'h12345678), op(0, 16'h0003, 0),
                  op(0, 16'h0020, 0), op(0, 16'h0021, 0), op(0, 16'h0023, 0),
                  op(0, 16'h0099, 0)}, 16'd1, r);
        check("ID",            lo(r[1]), 32'h55323230);
        check("VERSION",       lo(r[2]), 32'h00010001);
        check("BUILD",         lo(r[3]), 32'hB01DB01D);
        check("SCRATCH old",   lo(r[4]), 32'h0);
        check("SCRATCH new",   lo(r[5]), 32'h12345678);
        check("CAT_CTRL",      lo(r[6]), 32'h1E);
        check("CAT_CTRL_OUT",  lo(r[7]), 32'hA5);
        check("VCTCXO_DAC",    lo(r[8]), 32'hBFFF);
        check("unmapped",      lo(r[9]), 32'hDEADBEEF);
        check("op echo",       r[4][63:32], {1'b1, 15'd0, 16'h0003});
        wr(16'h0020, 32'h1F);
        check("CAT_CTRL pin", cat_ctrl, 9'h1F);

        // ---- loopback: 3 packets of different sizes
        wr(16'h0010, 1);
        for (int p = 0; p < 3; p++) begin
            automatic int n = 2 + p * 37;
            pkt = {{16'(p), 16'(n * 8), 32'h4C4F4F50}};
            for (int i = 1; i < n; i++) pkt.push_back({32'(p), 32'(i)});
            fork
                tx_send(pkt);
                rx_recv(got);
            join
            check($sformatf("loopback %0d size", p), got.size(), pkt.size());
            foreach (pkt[i]) check($sformatf("loopback %0d word %0d", p, i), got[i], pkt[i]);
        end

        // ---- generator: 5-word payload, counter continues across packets
        wr(16'h0010, 0);
        wr(16'h0016, 1);
        wr(16'h0011, 5);
        rx_en = 0;
        wr(16'h0010, 2);
        rx_en = 1;
        for (int p = 0; p < 3; p++) begin
            rx_recv(got);
            check($sformatf("gen %0d size", p), got.size(), 6);
            check($sformatf("gen %0d header", p), got[0], {16'(p), 16'd48, 32'h47454E30});
            for (int i = 1; i < 6; i++)
                check($sformatf("gen %0d word %0d", p, i), got[i], 64'(p * 5 + i - 1));
        end
        wr(16'h0010, 0);
        repeat (50) @(posedge clk);
        transact({op(0, 16'h0012, 0), op(0, 16'h0014, 0)}, 16'd9, r);
        check("TX_PKTS", lo(r[1]), 0);           // cleared before the generator test
        if (lo(r[2]) < 3) begin $display("FAIL RX_PKTS %0d < 3", lo(r[2])); errors++; end

        // ---- AD9361 SPI: write, read back, product ID, all in one control packet
        transact({op(1, 16'h0030, (1 << 23) | (10'h005 << 8) | 8'h5A),
                  op(1, 16'h0030, (10'h005 << 8)),
                  op(0, 16'h0031, 0),
                  op(1, 16'h0030, (10'h037 << 8)),
                  op(0, 16'h0031, 0),
                  op(0, 16'h0030, 0)}, 16'd20, r);
        check("SPI readback 0x005", lo(r[3]) & 8'hFF, 8'h5A);
        check("SPI product ID", lo(r[5]) & 8'hFF, 8'h0A);
        check("SPI not busy after read", lo(r[6]) >> 31, 0);
        check("model wrote 0x005", ad_regs[10'h005], 8'h5A);

        if (errors == 0) $display("PASS: all checks");
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #2ms $display("FAIL: timeout");
        $finish;
    end
endmodule
