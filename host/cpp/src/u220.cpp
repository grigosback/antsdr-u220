#include "u220.hpp"

#include <libusb-1.0/libusb.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

namespace u220 {
namespace {

constexpr uint16_t VID = 0x2500, PID = 0x0020;
constexpr uint8_t EP_CTRL_OUT = 0x04, EP_CTRL_IN = 0x88;
constexpr int IF_CTRL_OUT = 3, IF_CTRL_IN = 4;
constexpr size_t MAX_OPS = 14;

std::string usb_err(const char* what, int rc)
{
    return std::string(what) + ": " + libusb_error_name(rc);
}

// 64-bit words go on the wire as [63:32] then [31:0], each little-endian
void put_word(std::vector<uint8_t>& out, uint64_t w)
{
    for (uint32_t half : {uint32_t(w >> 32), uint32_t(w)})
        for (int i = 0; i < 4; i++)
            out.push_back(uint8_t(half >> (8 * i)));
}

uint64_t get_word(const uint8_t* p)
{
    auto rd32 = [](const uint8_t* q) {
        return uint32_t(q[0]) | uint32_t(q[1]) << 8 | uint32_t(q[2]) << 16 | uint32_t(q[3]) << 24;
    };
    return uint64_t(rd32(p)) << 32 | rd32(p + 4);
}

uint32_t spi_word(bool write, uint16_t r, uint8_t v)
{
    return (uint32_t(write) << 23) | (uint32_t(r & 0x3FF) << 8) | v;
}

} // namespace

device::device()
{
    int rc = libusb_init(&_ctx);
    if (rc) throw error(usb_err("libusb_init", rc));
    _h = libusb_open_device_with_vid_pid(_ctx, VID, PID);
    if (!_h) {
        libusb_exit(_ctx);
        throw error("U220 (2500:0020) not found or no permission");
    }
    for (int intf : {IF_CTRL_OUT, IF_CTRL_IN, 1, 2}) {
        rc = libusb_claim_interface(_h, intf);
        if (rc) {
            libusb_close(_h);
            libusb_exit(_ctx);
            throw error(usb_err("claim interface (is the FX3 firmware loaded?)", rc));
        }
    }
    // drop stale responses
    while (!_bulk_in(EP_CTRL_IN, 1024, 20).empty()) {}
    _seq = uint16_t(std::chrono::steady_clock::now().time_since_epoch().count());
    uint32_t id = rd(reg::ID);
    if (id != ID_U220) {
        char msg[128];
        std::snprintf(msg, sizeof msg, "ID register reads 0x%08x, expected 0x%08x: is u220.bin loaded?", id, ID_U220);
        throw error(msg);
    }
}

device::~device()
{
    if (_h) {
        for (int intf : {IF_CTRL_OUT, IF_CTRL_IN, 1, 2})
            libusb_release_interface(_h, intf);
        libusb_close(_h);
    }
    if (_ctx) libusb_exit(_ctx);
}

void device::_bulk_out(uint8_t ep, const std::vector<uint8_t>& data)
{
    int n = 0;
    int rc = libusb_bulk_transfer(_h, ep, const_cast<uint8_t*>(data.data()), int(data.size()), &n, 1000);
    if (rc || n != int(data.size())) throw error(usb_err("bulk out", rc));
}

std::vector<uint8_t> device::_bulk_in(uint8_t ep, size_t max, unsigned timeout_ms)
{
    std::vector<uint8_t> buf(max);
    int n = 0;
    int rc = libusb_bulk_transfer(_h, ep, buf.data(), int(max), &n, timeout_ms);
    if (rc == LIBUSB_ERROR_TIMEOUT) return {};
    if (rc) throw error(usb_err("bulk in", rc));
    buf.resize(size_t(n));
    return buf;
}

std::vector<uint32_t> device::transact(const std::vector<op>& ops)
{
    std::vector<uint32_t> out;
    out.reserve(ops.size());
    for (size_t i = 0; i < ops.size(); i += MAX_OPS) {
        size_t n = std::min(MAX_OPS, ops.size() - i);
        uint16_t seq = _seq++;
        uint64_t hdr = uint64_t(seq) << 48 | uint64_t((n + 1) * 8) << 32 | 0x52454700;  // "REG\0"
        std::vector<uint8_t> pkt;
        put_word(pkt, hdr);
        for (size_t k = 0; k < n; k++) {
            const op& o = ops[i + k];
            put_word(pkt, uint64_t(o.write) << 63 | uint64_t(o.addr) << 32 | o.value);
        }
        _bulk_out(EP_CTRL_OUT, pkt);
        auto resp = _bulk_in(EP_CTRL_IN, 1024, 1000);
        if (resp.size() != pkt.size() || get_word(resp.data()) != hdr)
            throw error("bad or missing control response");
        for (size_t k = 0; k < n; k++)
            out.push_back(uint32_t(get_word(resp.data() + 8 * (k + 1))));
    }
    return out;
}

uint32_t device::rd(uint16_t addr) { return transact({{false, addr, 0}})[0]; }
uint32_t device::wr(uint16_t addr, uint32_t value) { return transact({{true, addr, value}})[0]; }

// The FPGA holds SPI accesses until the previous transfer is done, so a
// read is "start transfer" + "read result" in one control packet.
uint8_t device::ad9361_peek(uint16_t r)
{
    auto v = transact({{true, reg::SPI_XFER, spi_word(false, r, 0)}, {false, reg::SPI_RDATA, 0}});
    return uint8_t(v[1]);
}

void device::ad9361_poke(uint16_t r, uint8_t value)
{
    transact({{true, reg::SPI_XFER, spi_word(true, r, value)}, {false, reg::SPI_RDATA, 0}});
}

void device::ad9361_reset()
{
    uint32_t cat = rd(reg::CAT_CTRL);
    wr(reg::CAT_CTRL, cat & ~CAT_RESETN);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    wr(reg::CAT_CTRL, cat | CAT_RESETN);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
}

} // namespace u220
