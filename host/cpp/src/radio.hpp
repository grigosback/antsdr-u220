// radio: AD9361 bring-up (UHD's driver) plus the FPGA RX sample path.
#pragma once

#include "u220.hpp"

#include <memory>

namespace uhd { namespace usrp { class ad9361_device_t; } }

namespace u220 {

struct radio_config {
    double rate = 16e6;     // sample rate per channel
    double freq = 100e6;    // RX LO
    double gain = 30;       // RX gain, dB
    double bw   = 0;        // RX analog bandwidth, 0 = same as the rate
    bool rx1 = true, rx2 = false;
};

struct radio_status {
    double rate = 0, freq = 0, bw = 0, gain[2] = {0, 0};
    bool bbpll_locked = false, rx_locked = false;
    int ensm = 0;
    double init_s = 0, rate_s = 0;
};

const char* ensm_name(int state);

class radio {
public:
    explicit radio(std::shared_ptr<device> dev);
    ~radio();

    // Reset and fully initialize the AD9361, then set rate, chains, LO, bandwidth
    // and gain. TX chains stay disabled at minimum gain; refuses to run if the
    // board's TX amplifiers are enabled. Holds the FPGA sample path in reset
    // while the AD9361 clocks change, then releases it.
    radio_status setup(const radio_config& cfg);

    // AD9361 built-in test tone injected at the RX data port, replacing the
    // ADC data: frequency (index + 1) * rate / 32, level -6 dB * atten.
    // Used to check the FPGA capture without RF. index, atten: 0..3.
    // mask: [0] RX1 Q, [1] RX1 I, [2] RX2 Q, [3] RX2 I left out of the tone
    // (checked on the board; masked parts read 0).
    void bist_tone(bool on, int index = 0, int atten = 1, int mask = 0);

    // FPGA side
    void sample_path(bool test_counter);  // configure + release reset, not yet enabled
    uint32_t data_clk_hz();               // waits for a fresh 100 ms measurement
    bool mimo() const { return _cfg.rx1 && _cfg.rx2; }
    const radio_config& config() const { return _cfg; }

    uhd::usrp::ad9361_device_t& ad() { return *_ad; }
    std::shared_ptr<ad9361_spi> spi() { return _io; }

private:
    std::shared_ptr<device> _dev;
    std::shared_ptr<ad9361_spi> _io;
    std::shared_ptr<ad9361_params> _params;
    std::unique_ptr<uhd::usrp::ad9361_device_t> _ad;
    radio_config _cfg;
};

} // namespace u220
