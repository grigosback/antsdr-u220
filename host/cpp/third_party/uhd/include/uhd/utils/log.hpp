// Minimal stand-in for UHD's logging. Not part of UHD.
// Messages go to stderr when U220_LOG is set in the environment
// (U220_LOG=trace also shows trace messages).
#pragma once
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>

namespace uhd { namespace log_shim {
inline int level()
{
    static int lvl = [] {
        const char* e = std::getenv("U220_LOG");
        if (!e) return 0;
        return std::strcmp(e, "trace") == 0 ? 2 : 1;
    }();
    return lvl;
}
struct line {
    std::ostringstream ss;
    bool on;
    line(const char* tag, const char* comp, int need) : on(level() >= need)
    {
        if (on) ss << "[" << tag << "] [" << comp << "] ";
    }
    ~line() { if (on) std::cerr << ss.str() << std::endl; }
    template <typename T> line& operator<<(const T& v) { if (on) ss << v; return *this; }
};
}} // namespace uhd::log_shim

#define UHD_LOGGER_TRACE(comp)   ::uhd::log_shim::line("TRACE", comp, 2)
#define UHD_LOGGER_DEBUG(comp)   ::uhd::log_shim::line("DEBUG", comp, 1)
#define UHD_LOGGER_INFO(comp)    ::uhd::log_shim::line("INFO", comp, 1)
#define UHD_LOGGER_WARNING(comp) ::uhd::log_shim::line("WARNING", comp, 0)
#define UHD_LOGGER_ERROR(comp)   ::uhd::log_shim::line("ERROR", comp, 0)
#define UHD_LOG_TRACE(comp, msg) UHD_LOGGER_TRACE(comp) << msg
#define UHD_LOG_DEBUG(comp, msg) UHD_LOGGER_DEBUG(comp) << msg
#define UHD_LOG_INFO(comp, msg)  UHD_LOGGER_INFO(comp) << msg
#define UHD_LOG_WARNING(comp, msg) UHD_LOGGER_WARNING(comp) << msg
