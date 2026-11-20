// Minimal stand-in for UHD's noncopyable. Not part of UHD.
#pragma once
namespace uhd {
class noncopyable {
protected:
    noncopyable() = default;
    ~noncopyable() = default;
public:
    noncopyable(const noncopyable&) = delete;
    noncopyable& operator=(const noncopyable&) = delete;
};
} // namespace uhd
