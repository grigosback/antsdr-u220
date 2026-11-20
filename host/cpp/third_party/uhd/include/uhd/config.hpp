// Minimal stand-in for UHD's config.hpp: just the macros the vendored
// AD9361 driver and its filter/sensor types use. Not part of UHD.
#pragma once
#define UHD_API
#define UHD_API_HEADER
#define UHD_INLINE inline
#define UHD_UNUSED(x) x __attribute__((unused))
