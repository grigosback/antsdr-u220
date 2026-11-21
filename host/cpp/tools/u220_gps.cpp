// u220_gps: look at the GPS module and the reference inputs (FPGA design 1.3).
//
//   u220_gps [--secs S] [--baud B]
//
// Prints the level and edge rate of PPS_IN_INT (GPS module PPS), PPS_IN_EXT
// (REF connector), CLKIN_10MHz and GPS_UART_RX, measures the GPS UART baud rate
// from its shortest pulse, then prints what the module sends for S seconds.
// A PPS period also shows how far the board's 40 MHz oscillator is off.

#include "u220.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

static void sleep_s(double s) { std::this_thread::sleep_for(std::chrono::duration<double>(s)); }

int main(int argc, char** argv)
{
    double secs = 5;
    unsigned baud = 0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--secs" && i + 1 < argc) secs = std::atof(argv[++i]);
        else if (a == "--baud" && i + 1 < argc) baud = unsigned(std::atoi(argv[++i]));
        else { std::fprintf(stderr, "usage: %s [--secs S] [--baud B]\n", argv[0]); return 2; }
    }
    try {
        u220::device dev;
        uint32_t v = dev.version();
        std::printf("FPGA design %u.%u\n", v >> 16, v & 0xFFFF);
        if (v < 0x00010003) throw u220::error("FPGA design 1.3 or newer needed");
        uint32_t bus_hz = dev.rd(u220::reg::BUS_CLK_HZ);

        dev.wr(u220::reg::GPS_RX_MINW, 0);
        sleep_s(2.2);   // two full one-second gates

        const char* names[4] = {"PPS_IN_INT  (GPS module PPS)", "PPS_IN_EXT  (REF connector) ",
                                "CLKIN_10MHz                 ", "GPS_UART_RX (module serial) "};
        uint32_t lv = dev.rd(u220::reg::REF_LEVELS);
        int lvbit[4] = {0, 1, 3, 2};
        for (int k = 0; k < 4; k++)
            std::printf("%s level %u, %u edges in the last second, %u in total\n", names[k],
                        (lv >> lvbit[k]) & 1, dev.rd(uint16_t(u220::reg::EDGES + k)),
                        dev.rd(uint16_t(u220::reg::EDGES_TOTAL + k)));
        for (int k = 0; k < 2; k++) {
            uint32_t p = dev.rd(k ? u220::reg::PPS_EXT_PERIOD : u220::reg::PPS_INT_PERIOD);
            uint32_t e = dev.rd(uint16_t(u220::reg::EDGES + k));
            if (e == 1 && p > bus_hz / 2)
                std::printf("%s period %u bus cycles: oscillator %+.3f ppm vs this PPS\n", names[k], p,
                            (double(p) - bus_hz) / bus_hz * 1e6);
        }

        uint32_t minw = dev.rd(u220::reg::GPS_RX_MINW);
        uint32_t edges = dev.rd(uint16_t(u220::reg::EDGES + 3));
        if (minw == 0xFFFFFFFF || edges == 0) {
            std::printf("GPS UART: no activity (no module, or it is not sending)\n");
            return 0;
        }
        double est = double(bus_hz) / minw;
        if (!baud) {
            const unsigned std_bauds[] = {4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800};
            baud = 9600;
            for (unsigned b : std_bauds)
                if (std::fabs(std::log(est / b)) < std::fabs(std::log(est / baud))) baud = b;
        }
        std::printf("GPS UART: shortest pulse %u cycles = %.0f baud, using %u baud\n", minw, est, baud);
        dev.wr(u220::reg::GPS_UART_DIV, uint32_t(std::lround(double(bus_hz) / baud)));

        uint32_t pos = dev.rd(u220::reg::GPS_UART_COUNT), ferr0 = dev.rd(u220::reg::GPS_UART_FERR);
        std::printf("---- %g s of GPS output ----\n", secs);
        auto t_end = std::chrono::steady_clock::now() + std::chrono::duration<double>(secs);
        uint64_t got = 0;
        while (std::chrono::steady_clock::now() < t_end) {
            sleep_s(0.1);
            uint32_t cnt = dev.rd(u220::reg::GPS_UART_COUNT);
            if (cnt - pos > 512 - 16) {   // the ring buffer has overwritten unread bytes
                std::printf("\n[lost %u bytes]\n", cnt - 256 - pos);
                pos = cnt - 256;
            }
            while (pos != cnt) {
                std::vector<u220::op> ops;
                uint32_t start = pos;
                for (int j = 0; j < 8 && pos != cnt; j++) {
                    ops.push_back({true, u220::reg::GPS_UART_ADDR, pos & 511});
                    ops.push_back({false, u220::reg::GPS_UART_DATA, 0});
                    pos += std::min<uint32_t>(4, cnt - pos);
                }
                auto r = dev.transact(ops);
                std::string chunk;
                for (size_t j = 0; j < ops.size() / 2; j++)
                    for (int b = 0; b < 4; b++) chunk += char((r[2 * j + 1] >> (8 * b)) & 0xFF);
                chunk.resize(pos - start);
                for (char c : chunk)
                    std::putchar((c == '\n' || c == '\r' || (c >= 32 && c < 127)) ? c : '.');
                got += chunk.size();
            }
            std::fflush(stdout);
        }
        std::printf("\n---- %llu bytes, %u framing errors ----\n", (unsigned long long)got,
                    dev.rd(u220::reg::GPS_UART_FERR) - ferr0);
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }
}
