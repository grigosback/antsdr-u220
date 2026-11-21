// u220: host library for the own ANTSDR U220 FPGA design (fpga/u220).
//
// Talks to the FPGA through the stock FX3 firmware's four bulk endpoints.
// The FX3 firmware and the FPGA must already be loaded (host/u220load.py).
#pragma once

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "ad9361_client.h"

struct libusb_context;
struct libusb_device_handle;

namespace u220 {

struct error : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// Register addresses (fpga/u220/u220_core.v)
namespace reg {
constexpr uint16_t ID = 0x0000, VERSION = 0x0001, BUILD = 0x0002, SCRATCH = 0x0003;
constexpr uint16_t UPTIME_LO = 0x0004, UPTIME_HI = 0x0005, BUS_CLK_HZ = 0x0006;
constexpr uint16_t STREAM_MODE = 0x0010, GEN_LEN = 0x0011, TX_PKTS = 0x0012;
constexpr uint16_t TX_WORDS = 0x0013, RX_PKTS = 0x0014, RX_WORDS = 0x0015;
constexpr uint16_t STREAM_CLEAR = 0x0016;
constexpr uint16_t CAT_CTRL = 0x0020, CAT_CTRL_OUT = 0x0021, FE_CTRL = 0x0022;
constexpr uint16_t VCTCXO_DAC = 0x0023;
constexpr uint16_t SPI_XFER = 0x0030, SPI_RDATA = 0x0031, SPI_HALF = 0x0032;
constexpr uint16_t RADIO_CTRL = 0x0040, RADIO_SPP = 0x0041, RADIO_STATUS = 0x0042;
constexpr uint16_t RADIO_CLK_HZ = 0x0043, RADIO_PKTS = 0x0044, RADIO_DROPS = 0x0045;
constexpr uint16_t GPS_CTRL = 0x0050, GPS_UART_DIV = 0x0051, GPS_UART_COUNT = 0x0052;
constexpr uint16_t GPS_UART_ADDR = 0x0053, GPS_UART_DATA = 0x0054, GPS_RX_MINW = 0x0055;
constexpr uint16_t GPS_UART_FERR = 0x0056, REF_LEVELS = 0x0057;
// rising edges in the last second / in total, in the order PPS_IN_INT, PPS_IN_EXT, CLKIN_10MHz, GPS_UART_RX
constexpr uint16_t EDGES = 0x0058, EDGES_TOTAL = 0x0060;
constexpr uint16_t PPS_INT_PERIOD = 0x005C, PPS_EXT_PERIOD = 0x005D;
} // namespace reg

// STREAM_MODE values
constexpr uint32_t STREAM_DRAIN = 0, STREAM_LOOP = 1, STREAM_GEN = 2, STREAM_RADIO = 3;

// RADIO_CTRL bits
constexpr uint32_t RADIO_ENABLE = 1u << 0, RADIO_MIMO = 1u << 1, RADIO_TEST = 1u << 2,
                   RADIO_RESET = 1u << 3;
// RADIO_STATUS bits
constexpr uint32_t RADIO_ST_FRAME = 0xF, RADIO_ST_XOVF = 1u << 4, RADIO_ST_RUNNING = 1u << 5,
                   RADIO_ST_POVF = 1u << 6, RADIO_ST_IDLE = 1u << 7;

constexpr uint32_t ID_U220 = 0x55323230;
constexpr uint32_t CAT_RESETN = 1u << 0;

struct op {
    bool write;
    uint16_t addr;
    uint32_t value;
};

class device {
public:
    device();   // opens the first 2500:0020 with the u220 image loaded
    ~device();
    device(const device&) = delete;
    device& operator=(const device&) = delete;

    // Control packets: up to 14 ops each, split automatically. Returns one
    // value per op (for writes, the register's previous value).
    std::vector<uint32_t> transact(const std::vector<op>& ops);
    uint32_t rd(uint16_t addr);
    uint32_t wr(uint16_t addr, uint32_t value);

    // AD9361 register access through the FPGA SPI master
    uint8_t ad9361_peek(uint16_t reg);
    void ad9361_poke(uint16_t reg, uint8_t value);
    void ad9361_reset();   // pulse RESETn, leave the chip running

    uint32_t version() { return rd(reg::VERSION); }

    // data endpoints, for streaming (rx_stream)
    static constexpr uint8_t EP_DATA_IN = 0x86, EP_DATA_OUT = 0x02;
    libusb_context* usb_context() { return _ctx; }
    libusb_device_handle* usb_handle() { return _h; }
    size_t flush_data_in();   // drop whatever is waiting on EP_DATA_IN, returns bytes

private:
    libusb_context* _ctx = nullptr;
    libusb_device_handle* _h = nullptr;
    uint16_t _seq = 0;
    void _bulk_out(uint8_t ep, const std::vector<uint8_t>& data);
    std::vector<uint8_t> _bulk_in(uint8_t ep, size_t max, unsigned timeout_ms);
};

// Plugs the FPGA SPI master into UHD's AD9361 driver.
class ad9361_spi : public uhd::usrp::ad9361_io {
public:
    explicit ad9361_spi(std::shared_ptr<device> dev) : _dev(std::move(dev)) {}
    uint8_t peek8(uint32_t r) override { transfers++; return _dev->ad9361_peek(uint16_t(r)); }
    void poke8(uint32_t r, uint8_t v) override { transfers++; _dev->ad9361_poke(uint16_t(r), v); }
    uint64_t transfers = 0;

private:
    std::shared_ptr<device> _dev;
};

// Board parameters for the AD9361. The U220 is B210-compatible, so these are
// UHD's B200/B210 values (host/lib/usrp/b200/b200_impl.cpp).
class ad9361_params : public uhd::usrp::ad9361_params {
public:
    uhd::usrp::digital_interface_delays_t get_digital_interface_timing() override
    {
        return {0x0, 0xF, 0x0, 0xF};   // rx clk, rx data, tx clk, tx data delay
    }
    uhd::usrp::digital_interface_mode_t get_digital_interface_mode() override
    {
        return uhd::usrp::AD9361_DDR_FDD_LVCMOS;
    }
    uhd::usrp::clocking_mode_t get_clocking_mode() override
    {
        return uhd::usrp::clocking_mode_t::AD9361_XTAL_N_CLK_PATH;
    }
    double get_band_edge(uhd::usrp::frequency_band_t band) override
    {
        switch (band) {
            case uhd::usrp::AD9361_RX_BAND0: return 2.2e9;
            case uhd::usrp::AD9361_RX_BAND1: return 4.0e9;
            case uhd::usrp::AD9361_TX_BAND0: return 2.5e9;
        }
        return 0;
    }
};

} // namespace u220
