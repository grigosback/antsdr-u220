// u220_ad9361: bring up the AD9361 with UHD's driver over the own FPGA design.
//
//   u220_ad9361 [--rate HZ] [--freq HZ] [--gain DB] [--bw HZ] [--rx1|--rx2|--rx12]
//
// Resets the AD9361, runs the full UHD initialization (BBPLL, calibrations),
// sets the sample clock, enables only RX chains, tunes and reports status.
// TX chains stay disabled, TX gain is at its minimum and the board's TX
// amplifiers stay off (FE_CTRL), so nothing is transmitted.

#include "ad9361_device.h"
#include "u220.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

using uhd::usrp::ad9361_device_t;
using clk = std::chrono::steady_clock;

static double secs(clk::time_point t0)
{
    return std::chrono::duration<double>(clk::now() - t0).count();
}

static const char* ensm_name(int s)
{
    switch (s) {
        case 0x0: return "SLEEP";
        case 0x1: return "WAIT";
        case 0x5: return "ALERT";
        case 0x6: return "TX";
        case 0x7: return "TX FLUSH";
        case 0x8: return "RX";
        case 0x9: return "RX FLUSH";
        case 0xA: return "FDD";
        case 0xB: return "FDD FLUSH";
        default:  return "?";
    }
}

int main(int argc, char** argv)
{
    double rate = 16e6, freq = 100e6, gain = 30, bw = 10e6;
    bool rx1 = true, rx2 = true;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto val = [&] {
            if (i + 1 >= argc) { std::fprintf(stderr, "%s needs a value\n", a.c_str()); std::exit(2); }
            return std::strtod(argv[++i], nullptr);
        };
        if (a == "--rate") rate = val();
        else if (a == "--freq") freq = val();
        else if (a == "--gain") gain = val();
        else if (a == "--bw") bw = val();
        else if (a == "--rx1") { rx1 = true; rx2 = false; }
        else if (a == "--rx2") { rx1 = false; rx2 = true; }
        else if (a == "--rx12") { rx1 = rx2 = true; }
        else {
            std::fprintf(stderr, "usage: %s [--rate HZ] [--freq HZ] [--gain DB] [--bw HZ] [--rx1|--rx2|--rx12]\n", argv[0]);
            return 2;
        }
    }

    try {
        auto dev = std::make_shared<u220::device>();
        uint32_t v = dev->version();
        std::printf("FPGA design %u.%u\n", v >> 16, v & 0xFFFF);
        if (dev->rd(u220::reg::FE_CTRL) & 0x3)
            throw u220::error("TX amplifiers are enabled in FE_CTRL; refusing to continue");

        dev->ad9361_reset();
        auto io = std::make_shared<u220::ad9361_spi>(dev);
        auto params = std::make_shared<u220::ad9361_params>();
        ad9361_device_t ad(params, io);

        auto t0 = clk::now();
        ad.initialize();
        std::printf("initialize():        %.2f s\n", secs(t0));

        t0 = clk::now();
        double actual_rate = ad.set_clock_rate(rate);
        std::printf("set_clock_rate():    %.6f MHz (asked %.6f) in %.2f s\n", actual_rate / 1e6, rate / 1e6, secs(t0));

        ad.set_active_chains(false, false, rx1, rx2);
        ad.set_gain(ad9361_device_t::TX, ad9361_device_t::CHAIN_BOTH, 0.0);  // max attenuation

        t0 = clk::now();
        double actual_freq = ad.tune(ad9361_device_t::RX, freq);
        std::printf("tune(RX):            %.6f MHz (asked %.6f) in %.2f s\n", actual_freq / 1e6, freq / 1e6, secs(t0));
        double actual_bw = ad.set_bw_filter(ad9361_device_t::RX, bw);
        std::printf("set_bw_filter(RX):   %.3f MHz\n", actual_bw / 1e6);
        for (auto ch : {ad9361_device_t::CHAIN_1, ad9361_device_t::CHAIN_2})
            if ((ch == ad9361_device_t::CHAIN_1 && rx1) || (ch == ad9361_device_t::CHAIN_2 && rx2))
                std::printf("set_gain(RX%d):       %.1f dB\n", ch == ad9361_device_t::CHAIN_1 ? 1 : 2,
                            ad.set_gain(ad9361_device_t::RX, ch, gain));

        int ensm = dev->ad9361_peek(0x017) & 0x0F;
        bool bbpll = dev->ad9361_peek(0x05E) & 0x80;
        bool rxpll = dev->ad9361_peek(0x247) & 0x02;
        std::printf("\nBBPLL locked:        %s\n", bbpll ? "yes" : "NO");
        std::printf("RX synth locked:     %s\n", rxpll ? "yes" : "NO");
        std::printf("ENSM state:          0x%x (%s)\n", ensm, ensm_name(ensm));
        std::printf("temperature:         %.1f C (UHD's uncalibrated estimate)\n", ad.get_average_temperature());
        if (rx1) std::printf("RSSI RX1:            %.2f dB\n", ad.get_rssi(ad9361_device_t::CHAIN_1));
        if (rx2) std::printf("RSSI RX2:            %.2f dB\n", ad.get_rssi(ad9361_device_t::CHAIN_2));
        std::printf("SPI transfers:       %llu\n", (unsigned long long)io->transfers);
        return bbpll && rxpll ? 0 : 1;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }
}
