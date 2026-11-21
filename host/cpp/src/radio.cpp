#include "radio.hpp"

#include "ad9361_device.h"

#include <chrono>
#include <thread>

using uhd::usrp::ad9361_device_t;
using clk = std::chrono::steady_clock;

namespace u220 {

static double secs(clk::time_point t0)
{
    return std::chrono::duration<double>(clk::now() - t0).count();
}

const char* ensm_name(int s)
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

radio::radio(std::shared_ptr<device> dev)
    : _dev(std::move(dev)),
      _io(std::make_shared<ad9361_spi>(_dev)),
      _params(std::make_shared<ad9361_params>())
{
}

radio::~radio() = default;

radio_status radio::setup(const radio_config& cfg)
{
    if (!cfg.rx1 && !cfg.rx2) throw error("no RX channel selected");
    if (_dev->rd(reg::FE_CTRL) & 0x3)
        throw error("TX amplifiers are enabled in FE_CTRL; refusing to continue");
    _cfg = cfg;
    radio_status st;

    // sample path off and in reset while DATA_CLK stops and changes
    _dev->wr(reg::RADIO_CTRL, RADIO_RESET);
    _dev->wr(reg::STREAM_MODE, STREAM_DRAIN);

    _dev->ad9361_reset();
    _ad = std::make_unique<ad9361_device_t>(_params, _io);

    auto t0 = clk::now();
    _ad->initialize();
    st.init_s = secs(t0);

    t0 = clk::now();
    st.rate = _ad->set_clock_rate(cfg.rate);
    st.rate_s = secs(t0);

    _ad->set_active_chains(false, false, cfg.rx1, cfg.rx2);
    _ad->set_gain(ad9361_device_t::TX, ad9361_device_t::CHAIN_BOTH, 0.0);  // max attenuation

    st.freq = _ad->tune(ad9361_device_t::RX, cfg.freq);
    st.bw = _ad->set_bw_filter(ad9361_device_t::RX, cfg.bw > 0 ? cfg.bw : cfg.rate);
    if (cfg.rx1) st.gain[0] = _ad->set_gain(ad9361_device_t::RX, ad9361_device_t::CHAIN_1, cfg.gain);
    if (cfg.rx2) st.gain[1] = _ad->set_gain(ad9361_device_t::RX, ad9361_device_t::CHAIN_2, cfg.gain);

    st.ensm = _dev->ad9361_peek(0x017) & 0x0F;
    st.bbpll_locked = _dev->ad9361_peek(0x05E) & 0x80;
    st.rx_locked = _dev->ad9361_peek(0x247) & 0x02;
    return st;
}

void radio::bist_tone(bool on, int index, int atten, int mask)
{
    // 0x3F4 BIST config: [7:6] tone frequency, [5:4] tone level, [3:2] control
    // point (2 = RX data port), [1] tone instead of PRBS, [0] enable.
    // 0x3F6 [5:2] mask: RX2 I, RX2 Q, RX1 I, RX1 Q (as seen at our I/Q, checked
    // on the board against off-air signals for the I/Q orientation).
    if (!on) {
        _dev->ad9361_poke(0x3F4, 0x00);
        return;
    }
    _dev->ad9361_poke(0x3F6, uint8_t((mask & 0xF) << 2));
    _dev->ad9361_poke(0x3F4, uint8_t((index & 3) << 6 | (atten & 3) << 4 | 2 << 2 | 1 << 1 | 1));
}

void radio::sample_path(bool test_counter)
{
    uint32_t mode = (mimo() ? RADIO_MIMO : 0) | (test_counter ? RADIO_TEST : 0);
    _dev->wr(reg::RADIO_CTRL, RADIO_RESET | mode);   // modes change only in reset
    _dev->wr(reg::RADIO_CTRL, mode);
}

uint32_t radio::data_clk_hz()
{
    std::this_thread::sleep_for(std::chrono::milliseconds(220));
    return _dev->rd(reg::RADIO_CLK_HZ);
}

} // namespace u220
