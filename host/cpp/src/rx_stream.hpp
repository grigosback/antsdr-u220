// rx_stream: receive AD9361 sample packets from the FPGA (STREAM_MODE 3).
//
// Packet on the wire (fpga/u220/u220_radio.v), 64-bit words, [63:32] first,
// each 32-bit half little-endian:
//   word 0  {seq[15:0], length bytes[15:0]}  {"SMP", flags}   flags: [0] drops before, [1] 2 channels
//   word 1  time: per-channel sample count of the first sample
//   word 2+ two sc16 samples each (I low 16 bits, Q high 16 bits):
//           1 channel: consecutive samples, 2 channels: {RX1, RX2}
#pragma once

#include "u220.hpp"

#include <cstdint>
#include <vector>

struct libusb_transfer;

namespace u220 {

struct rx_stats {
    uint64_t packets = 0, bytes = 0;
    uint64_t samples = 0;           // per channel, kept
    uint64_t drop_flags = 0;        // packets flagged "drops before this one"
    uint64_t lost_samples = 0;      // per channel, from time gaps
    uint64_t seq_errors = 0, time_errors = 0, format_errors = 0;
    uint64_t test_errors = 0;       // test counter mismatches (test mode only)
    uint64_t first_time = 0, last_time = 0;
    double seconds = 0;             // first to last packet
};

class rx_stream {
public:
    // mimo: two channels per word. check_test: verify the FPGA test counter.
    rx_stream(device& dev, bool mimo, bool check_test);
    ~rx_stream();

    // Enable the sample path, receive until nsamps per channel are kept, stop.
    // out[0] (and out[1] with two channels) get sc16 samples as uint32
    // (I in bits 15:0, Q in bits 31:16). keep = false only counts and checks.
    rx_stats run(size_t nsamps, std::vector<std::vector<uint32_t>>& out, bool keep = true,
                 size_t nxfers = 32, size_t xfer_bytes = 16384);

private:
    static void _callback(libusb_transfer* t);
    void _packet(const uint8_t* p, size_t n);

    device& _dev;
    bool _mimo, _check_test;
    bool _stopping = false;
    int _inflight = 0;
    size_t _want = 0, _count = 0;
    bool _keep = true;
    std::vector<std::vector<uint32_t>>* _out = nullptr;
    rx_stats _st;
    bool _have_prev = false, _have_off = false;
    uint16_t _prev_seq = 0;
    uint64_t _next_time = 0;
    uint32_t _off = 0;
    double _t_first = 0, _t_last = 0;
};

} // namespace u220
