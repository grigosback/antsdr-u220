#include "rx_stream.hpp"

#include <libusb-1.0/libusb.h>

#include <chrono>
#include <cstring>

namespace u220 {
namespace {

double now_s()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

uint32_t rd32(const uint8_t* q)
{
    return uint32_t(q[0]) | uint32_t(q[1]) << 8 | uint32_t(q[2]) << 16 | uint32_t(q[3]) << 24;
}

// value of the FPGA test counter carried by a test-mode sample
inline uint32_t tval(uint32_t s) { return ((s >> 20) & 0xFFF) << 12 | ((s >> 4) & 0xFFF); }
inline bool tlow_ok(uint32_t s) { return (s & 0x000F000F) == 0; }

} // namespace

rx_stream::rx_stream(device& dev, bool mimo, bool check_test)
    : _dev(dev), _mimo(mimo), _check_test(check_test)
{
}

rx_stream::~rx_stream() = default;

void rx_stream::_callback(libusb_transfer* t)
{
    auto* self = static_cast<rx_stream*>(t->user_data);
    if (t->status == LIBUSB_TRANSFER_COMPLETED && t->actual_length > 0)
        self->_packet(t->buffer, size_t(t->actual_length));
    bool again = !self->_stopping &&
                 (t->status == LIBUSB_TRANSFER_COMPLETED || t->status == LIBUSB_TRANSFER_TIMED_OUT);
    if (again && libusb_submit_transfer(t) == 0) return;
    self->_inflight--;
}

void rx_stream::_packet(const uint8_t* p, size_t n)
{
    double t = now_s();
    if (_st.packets == 0) _t_first = t;
    _t_last = t;
    _st.packets++;
    _st.bytes += n;

    if (n < 16) { _st.format_errors++; return; }
    uint32_t hi = rd32(p), lo = rd32(p + 4);
    size_t len = hi & 0xFFFF;
    uint16_t seq = uint16_t(hi >> 16);
    uint32_t flags = lo & 0xFF;
    // the FX3 path adds 4 pad bytes to packets that are a multiple of 1024 bytes
    if ((lo >> 8) != 0x534D50 || len < 24 || len % 8 || (n != len && n != len + 4) ||
        bool(flags & 2) != _mimo) {
        _st.format_errors++;
        return;
    }
    uint64_t time = uint64_t(rd32(p + 8)) << 32 | rd32(p + 12);
    size_t words = len / 8 - 2;
    uint64_t step = _mimo ? words : 2 * words;

    if (_have_prev) {
        if (seq != uint16_t(_prev_seq + 1)) _st.seq_errors++;
        if (time != _next_time) {
            if ((flags & 1) && time > _next_time) _st.lost_samples += time - _next_time;
            else _st.time_errors++;
        }
    } else {
        _st.first_time = time;
    }
    if (flags & 1) _st.drop_flags++;
    _have_prev = true;
    _prev_seq = seq;
    _next_time = time + step;
    _st.last_time = time;

    const uint8_t* d = p + 16;
    if (_check_test) {
        for (size_t i = 0; i < words; i++) {
            uint32_t s0 = rd32(d + 8 * i), s1 = rd32(d + 8 * i + 4);
            // counter at the first sample of word i
            uint64_t k = _mimo ? 2 * (time + i) : time + 2 * i;
            if (!_have_off) { _off = uint32_t(tval(s0) - k) & 0xFFFFFF; _have_off = true; }
            uint32_t e = uint32_t(_off + k) & 0xFFFFFF;
            if (tval(s0) != e || tval(s1) != ((e + 1) & 0xFFFFFF) || !tlow_ok(s0) || !tlow_ok(s1))
                _st.test_errors++;
        }
    }

    size_t take = std::min(_mimo ? words : 2 * words, _want - _count);
    _count += take;
    _st.samples = _count;
    if (!_keep) return;
    auto& out = *_out;
    if (!_mimo) {
        size_t at = out[0].size();
        out[0].resize(at + take);
        std::memcpy(out[0].data() + at, d, take * 4);   // little-endian host
    } else {
        for (size_t i = 0; i < take; i++) {
            out[0].push_back(rd32(d + 8 * i));
            out[1].push_back(rd32(d + 8 * i + 4));
        }
    }
}

rx_stats rx_stream::run(size_t nsamps, std::vector<std::vector<uint32_t>>& out, bool keep,
                        size_t nxfers, size_t xfer_bytes)
{
    _out = &out;
    _want = nsamps;
    _count = 0;
    _keep = keep;
    out.assign(_mimo ? 2 : 1, {});
    if (keep)
        for (auto& v : out) v.reserve(nsamps);
    _st = {};
    _have_prev = _have_off = false;
    _stopping = false;

    // start from a clean endpoint
    _dev.wr(reg::STREAM_MODE, STREAM_DRAIN);
    _dev.flush_data_in();

    std::vector<std::vector<uint8_t>> bufs(nxfers, std::vector<uint8_t>(xfer_bytes));
    std::vector<libusb_transfer*> xfers;
    for (size_t i = 0; i < nxfers; i++) {
        libusb_transfer* t = libusb_alloc_transfer(0);
        libusb_fill_bulk_transfer(t, _dev.usb_handle(), device::EP_DATA_IN, bufs[i].data(),
                                  int(xfer_bytes), &rx_stream::_callback, this, 200);
        if (libusb_submit_transfer(t) != 0) {
            libusb_free_transfer(t);
            break;
        }
        xfers.push_back(t);
        _inflight++;
    }
    if (xfers.empty()) throw error("could not submit any USB transfer");

    uint32_t ctrl = _dev.rd(reg::RADIO_CTRL) & ~RADIO_RESET;
    _dev.wr(reg::STREAM_MODE, STREAM_RADIO);
    _dev.wr(reg::RADIO_CTRL, ctrl | RADIO_ENABLE);

    libusb_context* ctx = _dev.usb_context();
    timeval tv{0, 100000};
    double last_progress = now_s();
    uint64_t last_packets = 0;
    while (_count < nsamps) {
        libusb_handle_events_timeout_completed(ctx, &tv, nullptr);
        if (_st.packets != last_packets) {
            last_packets = _st.packets;
            last_progress = now_s();
        } else if (now_s() - last_progress > 2.0) {
            break;   // no data for 2 s
        }
        if (_inflight == 0) break;
    }

    // stop: the FPGA finishes its current packet, then drain what is in flight
    _dev.wr(reg::RADIO_CTRL, ctrl);
    double quiet_from = now_s();
    uint64_t before = _st.packets;
    while (_inflight > 0 && now_s() - quiet_from < 0.1) {
        libusb_handle_events_timeout_completed(ctx, &tv, nullptr);
        if (_st.packets != before) { before = _st.packets; quiet_from = now_s(); }
    }
    _stopping = true;
    for (auto* t : xfers) libusb_cancel_transfer(t);
    while (_inflight > 0) libusb_handle_events_timeout_completed(ctx, &tv, nullptr);
    for (auto* t : xfers) libusb_free_transfer(t);
    _dev.wr(reg::STREAM_MODE, STREAM_DRAIN);

    _st.seconds = _t_last - _t_first;
    return _st;
}

} // namespace u220
