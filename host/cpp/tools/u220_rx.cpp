// u220_rx: receive AD9361 samples through the own FPGA design.
//
//   u220_rx [--rate HZ] [--freq HZ] [--gain DB] [--bw HZ] [--rx1|--rx2|--rx12]
//           [--num N] [--out FILE] [--test] [--bist [INDEX]] [--spp WORDS] [--skip-init]
//
// Sets up the AD9361 (UHD's driver, RX only, TX off), measures DATA_CLK,
// streams N samples per channel and checks every packet (sequence, time,
// drops). --out writes interleaved int16 I/Q ("cs16"); with two channels
// FILE gets "-rx1" / "-rx2" before its extension.
//   --test      FPGA replaces the samples with a counter; every sample is checked
//   --bist [i]  AD9361 injects a digital tone at (i + 1) * rate / 32 at the data
//               port instead of the ADC (checks the capture timing without RF)
//   --bist-mask M  leave the tone out of: [0] RX1 Q, [1] RX1 I, [2] RX2 Q, [3] RX2 I
//   --skip-init keep the current AD9361 setup (only for --test runs)
//   --discard   check and count samples without keeping them (long runs)
//   --poke R=V  write AD9361 register R = V (both hex) after the setup
//               (RX experiments only: ENSM, TX attenuation and TX synth registers are refused)

#include "ad9361_device.h"
#include "radio.hpp"
#include "rx_stream.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

using uhd::usrp::ad9361_device_t;

static std::string chan_path(const std::string& out, int ch, bool two)
{
    if (!two) return out;
    auto dot = out.find_last_of('.');
    auto slash = out.find_last_of('/');
    std::string tag = "-rx" + std::to_string(ch + 1);
    if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) return out + tag;
    return out.substr(0, dot) + tag + out.substr(dot);
}

int main(int argc, char** argv)
{
    u220::radio_config cfg;
    double num = 10e6;
    std::string out;
    bool test = false, skip_init = false, discard = false;
    int bist = -1, bist_mask = 0;
    unsigned spp = 1020;
    std::vector<std::pair<unsigned, unsigned>> pokes;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto val = [&] {
            if (i + 1 >= argc) { std::fprintf(stderr, "%s needs a value\n", a.c_str()); std::exit(2); }
            return std::strtod(argv[++i], nullptr);
        };
        if (a == "--rate") cfg.rate = val();
        else if (a == "--freq") cfg.freq = val();
        else if (a == "--gain") cfg.gain = val();
        else if (a == "--bw") cfg.bw = val();
        else if (a == "--rx1") { cfg.rx1 = true; cfg.rx2 = false; }
        else if (a == "--rx2") { cfg.rx1 = false; cfg.rx2 = true; }
        else if (a == "--rx12") { cfg.rx1 = cfg.rx2 = true; }
        else if (a == "--num") num = val();
        else if (a == "--out") { if (i + 1 >= argc) return 2; out = argv[++i]; }
        else if (a == "--test") test = true;
        else if (a == "--skip-init") skip_init = true;
        else if (a == "--discard") discard = true;
        else if (a == "--spp") spp = unsigned(val());
        else if (a == "--bist-mask") bist_mask = int(val());
        else if (a == "--poke" && i + 1 < argc) {
            unsigned r = 0, v = 0;
            if (std::sscanf(argv[++i], "%x=%x", &r, &v) != 2 || r > 0x3FF || v > 0xFF) {
                std::fprintf(stderr, "--poke needs REG=VALUE in hex\n");
                return 2;
            }
            // keep this RX-only: no ENSM/TX enable, TX attenuation or TX synth changes
            if (r == 0x002 || r == 0x013 || r == 0x014 || r == 0x015 || (r >= 0x073 && r <= 0x07C) ||
                (r >= 0x270 && r <= 0x29F)) {
                std::fprintf(stderr, "--poke: register 0x%03x touches TX or the ENSM, refused\n", r);
                return 2;
            }
            pokes.emplace_back(r, v);
        }
        else if (a == "--bist") {
            bist = 0;
            if (i + 1 < argc && argv[i + 1][0] != '-') bist = std::atoi(argv[++i]);
        } else {
            std::fprintf(stderr,
                "usage: %s [--rate HZ] [--freq HZ] [--gain DB] [--bw HZ] [--rx1|--rx2|--rx12]\n"
                "          [--num N] [--out FILE] [--test] [--bist [INDEX]] [--bist-mask M] [--spp WORDS] [--skip-init] [--discard]\n"
                "          [--poke REG=VAL ...]\n",
                argv[0]);
            return 2;
        }
    }

    try {
        auto dev = std::make_shared<u220::device>();
        uint32_t v = dev->version();
        std::printf("FPGA design %u.%u\n", v >> 16, v & 0xFFFF);
        if (v < 0x00010002) throw u220::error("FPGA design 1.2 or newer needed (RX sample path)");

        u220::radio radio(dev);
        bool two = cfg.rx1 && cfg.rx2;
        if (!skip_init) {
            auto st = radio.setup(cfg);
            std::printf("AD9361: rate %.6f MHz, RX LO %.6f MHz, bw %.3f MHz, gain %.0f dB, %s, "
                        "BBPLL %s, RX synth %s, ENSM %s\n",
                        st.rate / 1e6, st.freq / 1e6, st.bw / 1e6, cfg.rx1 ? st.gain[0] : st.gain[1],
                        two ? "RX1+RX2" : cfg.rx1 ? "RX1" : "RX2", st.bbpll_locked ? "locked" : "NOT LOCKED",
                        st.rx_locked ? "locked" : "NOT LOCKED", u220::ensm_name(st.ensm));
            if (!st.bbpll_locked || !st.rx_locked) throw u220::error("AD9361 PLL not locked");
            cfg.rate = st.rate;
        } else if (!test) {
            throw u220::error("--skip-init only works with --test");
        }
        if (bist >= 0) radio.bist_tone(true, bist, 1, bist_mask);
        for (auto [r, v] : pokes) {
            dev->ad9361_poke(uint16_t(r), uint8_t(v));
            std::printf("AD9361 0x%03x = 0x%02x (read back 0x%02x)\n", r, v, dev->ad9361_peek(uint16_t(r)));
        }

        dev->wr(u220::reg::RADIO_SPP, spp);
        radio.sample_path(test);
        uint32_t dclk = radio.data_clk_hz();
        uint32_t status = dev->rd(u220::reg::RADIO_STATUS);
        std::printf("DATA_CLK %.4f MHz (%.2f x rate), RX_FRAME seen 0x%x, sample path %s\n", dclk / 1e6,
                    dclk / cfg.rate, status & u220::RADIO_ST_FRAME,
                    (status & u220::RADIO_ST_RUNNING) ? "running" : "NOT RUNNING");
        if (!(status & u220::RADIO_ST_RUNNING)) throw u220::error("no DATA_CLK from the AD9361");

        uint32_t drops0 = dev->rd(u220::reg::RADIO_DROPS);
        u220::rx_stream rx(*dev, two, test);
        std::vector<std::vector<uint32_t>> buf;
        if (discard && !out.empty()) throw u220::error("--discard and --out exclude each other");
        auto s = rx.run(size_t(num), buf, !discard);
        if (bist >= 0) radio.bist_tone(false);
        status = dev->rd(u220::reg::RADIO_STATUS);
        uint32_t fpga_drops = dev->rd(u220::reg::RADIO_DROPS) - drops0;

        double rate_meas = s.seconds > 0 ? double(s.last_time - s.first_time) / s.seconds : 0;
        std::printf("received %llu packets, %.1f MB in %.3f s = %.1f MB/s, %.3f MS/s per channel\n",
                    (unsigned long long)s.packets, s.bytes / 1e6, s.seconds,
                    s.seconds > 0 ? s.bytes / 1e6 / s.seconds : 0.0, rate_meas / 1e6);
        std::printf("kept %llu samples per channel; FPGA dropped %u packets (%llu samples), "
                    "seq errors %llu, time errors %llu, format errors %llu",
                    (unsigned long long)s.samples, fpga_drops, (unsigned long long)s.lost_samples,
                    (unsigned long long)s.seq_errors, (unsigned long long)s.time_errors,
                    (unsigned long long)s.format_errors);
        if (test) std::printf(", test counter errors %llu", (unsigned long long)s.test_errors);
        std::printf("\n");
        if (status & (u220::RADIO_ST_XOVF | u220::RADIO_ST_POVF))
            std::printf("WARNING: FPGA overflow flags set (status 0x%02x)\n", status);

        for (size_t ch = 0; ch < buf.size() && !discard; ch++) {
            double si = 0, sq = 0, p = 0;
            int16_t peak = 0;
            for (uint32_t w : buf[ch]) {
                int16_t i = int16_t(w & 0xFFFF), q = int16_t(w >> 16);
                si += i;
                sq += q;
                p += double(i) * i + double(q) * q;
                peak = std::max<int16_t>(peak, std::max<int16_t>(std::abs(i), std::abs(q)));
            }
            double n = double(std::max<size_t>(buf[ch].size(), 1));
            int which = two ? int(ch) + 1 : (cfg.rx1 ? 1 : 2);
            std::printf("RX%d: mean I %.1f Q %.1f, power %.1f dBFS, peak %d\n", which, si / n, sq / n,
                        10 * std::log10(p / n / (32768.0 * 32768.0) + 1e-20), peak);
        }

        if (!out.empty()) {
            for (size_t ch = 0; ch < buf.size(); ch++) {
                std::string path = chan_path(out, int(ch), two);
                FILE* f = std::fopen(path.c_str(), "wb");
                if (!f) throw u220::error("cannot write " + path);
                std::fwrite(buf[ch].data(), 4, buf[ch].size(), f);
                std::fclose(f);
                std::printf("wrote %s (%zu samples, cs16)\n", path.c_str(), buf[ch].size());
            }
        }

        bool ok = s.samples >= size_t(num) && s.seq_errors == 0 && s.time_errors == 0 &&
                  s.format_errors == 0 && s.test_errors == 0;
        return ok ? 0 : 1;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }
}
