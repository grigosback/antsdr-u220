// Self-checking testbench for u220_core: registers, loopback, generator,
// AD9361 SPI, and the RX sample path (fake AD9361 data port on its own clock),
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

    // fake AD9361 data port: 32.26 MHz DATA_CLK, I = k, Q = ~k,
    // RX_FRAME (rise, fall) = (1, 0) for one channel, alternating (1, 1) / (0, 0) for two
    logic        radio_clk = 0;
    always #15.5 radio_clk = ~radio_clk;
    logic [11:0] cap_i = 0, cap_q = 0;
    logic        cap_fr_r = 0, cap_fr_f = 0;
    logic        model_mimo = 0;
    logic [11:0] model_k = 0;
    always @(posedge radio_clk) begin
        model_k  <= model_k + 1;
        cap_i    <= #1 model_k;
        cap_q    <= #1 ~model_k;
        if (model_mimo) begin
            cap_fr_r <= #1 ~cap_fr_r;
            cap_fr_f <= #1 ~cap_fr_r;
        end else begin
            cap_fr_r <= #1 1;
            cap_fr_f <= #1 0;
        end
    end

    u220_core #(.RADIO_FIFO(8), .METER_CYCLES(10000)) dut (
        .clk(clk), .rst(rst), .build_id(32'hB01DB01D),
        .ctrl_tdata, .ctrl_tlast, .ctrl_tvalid, .ctrl_tready,
        .resp_tdata, .resp_tlast, .resp_tvalid, .resp_tready,
        .tx_tdata, .tx_tlast, .tx_tvalid, .tx_tready,
        .rx_tdata, .rx_tlast, .rx_tvalid, .rx_tready,
        .cat_ctrl, .cat_ctrl_out(8'hA5), .fe_ctrl, .vctcxo_dac,
        .spi_sclk, .spi_sen_n, .spi_mosi, .spi_miso,
        .radio_clk, .cap_i, .cap_q, .cap_fr_r, .cap_fr_f,
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

    // RX monitor: every word the DUT sends is kept, tasks take whole packets
    logic [63:0] rx_words_q[$];
    int          rx_lens[$];
    int          rx_cur = 0, rx_total = 0;
    always @(posedge clk) if (rx_tvalid && rx_tready) begin
        rx_words_q.push_back(rx_tdata);
        rx_cur++;
        rx_total++;
        if (rx_tlast) begin rx_lens.push_back(rx_cur); rx_cur = 0; end
    end
    task automatic rx_recv(output logic [63:0] words[$]);
        int n;
        words = {};
        while (rx_lens.size() == 0) @(posedge clk);
        n = rx_lens.pop_front();
        repeat (n) words.push_back(rx_words_q.pop_front());
    endtask
    task automatic rx_flush();
        rx_words_q = {};
        rx_lens = {};
        rx_cur = 0;
    endtask

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

    task automatic rd(logic [15:0] addr, output logic [31:0] v);
        logic [63:0] r[$];
        transact({op(0, addr, 0)}, 16'h5555, r);
        v = lo(r[1]);
    endtask

    // accept RX until it has been quiet for 3 us, then check and drop all packets
    task automatic rx_drain(input int exp_words, output int n);
        int prev_total;
        rx_en = 1;
        do begin
            prev_total = rx_total;
            #3us;
            @(posedge clk);
        end while (rx_total != prev_total);
        rx_en = 0;
        check("no partial packet", rx_cur, 0);
        n = rx_lens.size();
        foreach (rx_lens[i]) check($sformatf("drained packet %0d size", i), rx_lens[i], exp_words);
        rx_flush();
    endtask

    // sample counter value carried by a test-mode sample
    function automatic logic [23:0] tval(logic [31:0] smp);
        return {smp[31:20], smp[15:4]};
    endfunction

    // receive npkt test-mode packets and check header, time and counter continuity.
    // per-word sample step: 2 samples per word on one channel, 1 sample time per word on two.
    task automatic radio_check(input string name, input int npkt, input int spp, input bit mimo,
                               output int nflagged);
        logic [63:0] got[$];
        logic [23:0] off, n;
        logic [15:0] seq;
        logic [63:0] t, t_prev;
        int spw;
        spw = mimo ? 1 : 2;   // time units per data word
        nflagged = 0;
        for (int p = 0; p < npkt; p++) begin
            rx_recv(got);
            check({name, " size"}, got.size(), spp + 2);
            check({name, " length"}, got[0][47:32], (spp + 2) * 8);
            check({name, " tag"}, got[0][31:8], 24'h534D50);
            check({name, " mimo flag"}, got[0][1], mimo);
            t = got[1];
            if (p == 0) begin
                off = tval(got[2][63:32]) - (mimo ? 24'(2 * t) : 24'(t));
            end else begin
                check({name, " seq"}, got[0][63:48], 16'(seq + 1));
                if (got[0][0]) nflagged++;
                else check({name, " time step"}, t - t_prev, spp * spw);
                if (t - t_prev < spp * spw) begin
                    $display("FAIL %s time went from %0d to %0d", name, t_prev, t); errors++;
                end
            end
            seq = got[0][63:48];
            t_prev = t;
            for (int i = 0; i < spp; i++) begin
                // counter at the first sample of word i
                n = off + (mimo ? 24'(2 * (t + i)) : 24'(t + 2 * i));
                check($sformatf("%s pkt %0d word %0d s0", name, p, i), tval(got[2 + i][63:32]), n);
                check($sformatf("%s pkt %0d word %0d s1", name, p, i), tval(got[2 + i][31:0]), 24'(n + 1));
                check($sformatf("%s pkt %0d word %0d low bits", name, p, i),
                      {got[2 + i][35:32], got[2 + i][51:48], got[2 + i][3:0], got[2 + i][19:16]}, 0);
            end
        end
        rx_en = 0;
    endtask

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
        check("VERSION",       lo(r[2]), 32'h00010002);
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
        rx_flush();
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

        // ---- RX sample path
        begin
            logic [31:0] v;
            int nf, nd, total;
            total = 0;
            rx_en = 0;
            rd(16'h0042, v);
            check("RADIO_STATUS in reset", v[5], 0);
            rd(16'h0040, v);
            check("RADIO_CTRL default", v, 32'h8);
            #250us;
            @(posedge clk);
            rd(16'h0043, v);
            if (v < 32'd32_200_000 || v > 32'd32_320_000) begin
                $display("FAIL RADIO_CLK_HZ %0d, expected ~32.26 MHz", v); errors++;
            end

            // one channel, test counter
            wr(16'h0041, 8);
            wr(16'h0010, 3);
            wr(16'h0040, 32'h4);           // test, out of reset, not enabled
            #2us;
            @(posedge clk);
            rd(16'h0042, v);
            check("RADIO_STATUS running", v[5], 1);
            check("RADIO_STATUS frame (1,0)", v[3:0], 4'b0100);
            check("RADIO_STATUS idle", v[7], 1);
            wr(16'h0040, 32'h5);           // enable
            rx_en = 1;
            radio_check("siso", 6, 8, 0, nf);
            total += 6;
            check("siso no drops", nf, 0);

            // host too slow: packets are dropped whole, time and counter stay consistent
            rx_en = 0;
            #60us;
            @(posedge clk);
            rx_en = 1;
            radio_check("siso overflow", 40, 8, 0, nf);
            total += 40;
            if (nf == 0) begin $display("FAIL no packet flagged after overflow"); errors++; end
            rd(16'h0045, v);
            if (v == 0) begin $display("FAIL RADIO_DROPS is 0"); errors++; end

            // stop: the current packet is finished, nothing partial
            wr(16'h0040, 32'h4);
            rx_drain(10, nd);
            total += nd;
            rd(16'h0042, v);
            check("idle after disable", v[7], 1);

            // two channels: (1,1)/(0,0) frames, word = {RX1, RX2} of the same instant
            model_mimo = 1;
            wr(16'h0040, 32'hE);           // change modes only in reset
            wr(16'h0040, 32'h6);
            wr(16'h0040, 32'h7);
            rx_en = 1;
            rx_en = 1;
            radio_check("mimo", 6, 8, 1, nf);
            total += 6;
            check("mimo no drops", nf, 0);

            // reset in the middle of streaming: unfinished packet is padded
            wr(16'h0040, 32'hF);
            rx_drain(10, nd);
            total += nd;
            rd(16'h0042, v);
            check("idle after reset", v[7], 1);
            check("not running in reset", v[5], 0);
            rd(16'h0044, v);
            check("RADIO_PKTS = packets received", v, total);

            // real samples (not test): I = k, Q = ~k from the model, one channel
            model_mimo = 0;
            wr(16'h0040, 32'h8);
            wr(16'h0040, 32'h0);
            rx_flush();
            wr(16'h0040, 32'h1);
            rx_en = 1;
            begin
                logic [63:0] got[$];
                rx_recv(got);
                rx_recv(got);
                for (int w = 2; w < 10; w++)
                    for (int h = 0; h < 2; h++) begin
                        automatic logic [31:0] smp = h ? got[w][31:0] : got[w][63:32];
                        check($sformatf("real I word %0d.%0d", w, h), smp[15:4], 12'(got[2][47:36] + 2 * (w - 2) + h));
                        check($sformatf("real Q word %0d.%0d", w, h), smp[31:20], 12'(~smp[15:4]));
                    end
            end
            wr(16'h0040, 32'h8);
            rx_drain(10, nd);
        end

        if (errors == 0) $display("PASS: all checks");
        else             $display("FAILED: %0d errors", errors);
        $finish;
    end

    initial begin
        #5ms $display("FAIL: timeout");
        $finish;
    end
endmodule
