// u220_ad9361: bring up the AD9361 with UHD's driver over the own FPGA design.
//
//   u220_ad9361 [--rate HZ] [--freq HZ] [--gain DB] [--bw HZ] [--rx1|--rx2|--rx12]
//
// Resets the AD9361, runs the full UHD initialization (BBPLL, calibrations),
// sets the sample clock, enables only RX chains, tunes and reports status.
// TX chains stay disabled, TX gain is at its minimum and the board's TX
// amplifiers stay off (FE_CTRL), so nothing is transmitted.

#include "ad9361_device.h"
#include "radio.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>

using uhd::usrp::ad9361_device_t;

int main(int argc, char** argv)
{
    u220::radio_config cfg;
    cfg.bw = 10e6;
    cfg.rx1 = cfg.rx2 = true;
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
        else {
            std::fprintf(stderr, "usage: %s [--rate HZ] [--freq HZ] [--gain DB] [--bw HZ] [--rx1|--rx2|--rx12]\n", argv[0]);
            return 2;
        }
    }

    try {
        auto dev = std::make_shared<u220::device>();
        uint32_t v = dev->version();
        std::printf("FPGA design %u.%u\n", v >> 16, v & 0xFFFF);

        u220::radio radio(dev);
        auto st = radio.setup(cfg);
        std::printf("initialize():        %.2f s\n", st.init_s);
        std::printf("set_clock_rate():    %.6f MHz (asked %.6f) in %.2f s\n", st.rate / 1e6, cfg.rate / 1e6, st.rate_s);
        std::printf("tune(RX):            %.6f MHz (asked %.6f)\n", st.freq / 1e6, cfg.freq / 1e6);
        std::printf("set_bw_filter(RX):   %.3f MHz\n", st.bw / 1e6);
        if (cfg.rx1) std::printf("set_gain(RX1):       %.1f dB\n", st.gain[0]);
        if (cfg.rx2) std::printf("set_gain(RX2):       %.1f dB\n", st.gain[1]);

        auto& ad = radio.ad();
        std::printf("\nBBPLL locked:        %s\n", st.bbpll_locked ? "yes" : "NO");
        std::printf("RX synth locked:     %s\n", st.rx_locked ? "yes" : "NO");
        std::printf("ENSM state:          0x%x (%s)\n", st.ensm, u220::ensm_name(st.ensm));
        std::printf("temperature:         %.1f C (UHD's uncalibrated estimate)\n", ad.get_average_temperature());
        if (cfg.rx1) std::printf("RSSI RX1:            %.2f dB\n", ad.get_rssi(ad9361_device_t::CHAIN_1));
        if (cfg.rx2) std::printf("RSSI RX2:            %.2f dB\n", ad.get_rssi(ad9361_device_t::CHAIN_2));
        if (v >= 0x00010002) {
            radio.sample_path(false);
            std::printf("DATA_CLK:            %.4f MHz\n", radio.data_clk_hz() / 1e6);
        }
        std::printf("SPI transfers:       %llu\n", (unsigned long long)radio.spi()->transfers);
        return st.bbpll_locked && st.rx_locked ? 0 : 1;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }
}
