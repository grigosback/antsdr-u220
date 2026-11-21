cmake_minimum_required(VERSION 3.16)
project(u220_host CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBUSB REQUIRED IMPORTED_TARGET libusb-1.0)
find_package(Boost REQUIRED)   # header-only parts: format, scoped_array

# UHD's AD9361 driver and the two UHD types it needs, vendored unchanged except
# for include fixes; third_party/uhd/include holds minimal stand-ins for the
# rest of UHD (config, exception, log, noncopyable).
add_library(uhd_ad9361 STATIC
  third_party/uhd/ad9361_driver/ad9361_device.cpp
  third_party/uhd/lib/filters.cpp
  third_party/uhd/lib/sensors.cpp)
target_include_directories(uhd_ad9361 PUBLIC
  third_party/uhd/include third_party/uhd/ad9361_driver)
target_link_libraries(uhd_ad9361 PUBLIC Boost::headers)
target_compile_options(uhd_ad9361 PRIVATE -w)

add_library(u220 STATIC src/u220.cpp src/radio.cpp src/rx_stream.cpp)
target_include_directories(u220 PUBLIC src)
target_link_libraries(u220 PUBLIC uhd_ad9361 PkgConfig::LIBUSB)
target_compile_options(u220 PRIVATE -Wall -Wextra)

add_executable(u220_ad9361 tools/u220_ad9361.cpp)
target_link_libraries(u220_ad9361 PRIVATE u220)
target_compile_options(u220_ad9361 PRIVATE -Wall -Wextra)

add_executable(u220_rx tools/u220_rx.cpp)
target_link_libraries(u220_rx PRIVATE u220)
target_compile_options(u220_rx PRIVATE -Wall -Wextra)
