// Minimal stand-in for UHD's exception.hpp. Not part of UHD.
#pragma once
#include <stdexcept>
#include <string>

namespace uhd {
struct runtime_error : std::runtime_error {
    using std::runtime_error::runtime_error;
};
struct value_error : std::runtime_error {
    using std::runtime_error::runtime_error;
};
struct assertion_error : std::runtime_error {
    using std::runtime_error::runtime_error;
};
} // namespace uhd

#define UHD_THROW_INVALID_CODE_PATH() \
    throw ::uhd::runtime_error(std::string("invalid code path in ") + __FILE__)
#define UHD_ASSERT_THROW(code)                                                 \
    do {                                                                       \
        if (!(code))                                                           \
            throw ::uhd::assertion_error(std::string("assertion failed: ") + #code); \
    } while (0)
