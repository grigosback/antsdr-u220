# ANTSDR U220 without vendor software

Build your own FPGA images for the MicroPhase ANTSDR U220 (AD9361 version) and
talk to them over USB from Python, without UHD, GNU Radio or MicroPhase tools.

The starting point is MicroPhase's B210-compatible design from
[antsdr_uhd v1.0](https://github.com/MicroPhase/antsdr_uhd/tree/v1.0/firmware/fpga/antsdr_u220),
reduced to the files it actually uses and retargeted to the FPGA that is
really on this board.

## Hardware

| Part | Chip | Notes |
|---|---|---|
| FPGA | Xilinx Artix-7 **XC7A200T** | Package assumed FBG484, speed grade unknown, so builds target -1 |
| USB | Cypress FX3 (CYUSB3014) | Bridges USB 3 to the FPGA over a 32-bit GPIF II slave FIFO |
| RF | AD9361 | Its SPI, control and data lines all go to the FPGA |
| Clock | 40 MHz always-on oscillator, AD5662 DAC for trimming, PPS/10 MHz/GPS inputs | |
| Debug | 6-pin 2.54 mm JTAG header | |

**Two U220 versions exist.** MicroPhase's vendor repo targets `xc7a100tfgg484-2`,
which matches only the AD9363 version. The AD9361 version uses an XC7A200T.
This was checked two ways:

- The chip ID inside MicroPhase's images: `U220_9361` contains `0x03636093`
  (XC7A200T), `U220_9363` contains `0x03631093` (XC7A100T). See `host/bitstream_idcode.py`.
- On the board: the 9361 image configures it, the 9363 image is rejected.

## How the board starts

Both stages are volatile, so the PC loads them at every power-up. Nothing is
stored on the board except the FX3 bootloader in its I2C EEPROM.

1. **FX3 bootloader** enumerates as `2500:0020` "Cypress WestBridge", always at
   USB 2, with one interface and no data endpoints.
2. **The PC loads the FX3 firmware** (`usrp_b200_fw.hex`) into FX3 RAM using the
   standard Cypress `0xA0` request. The device re-enumerates as "Ettus Research
   LLC / USRP B200" with 4 bulk endpoints:

   | Endpoint | Direction | Use |
   |---|---|---|
   | `0x02` | out | TX samples |
   | `0x86` | in | RX samples |
   | `0x04` | out | control commands |
   | `0x88` | in | control responses |

3. **The PC loads the FPGA** through FX3 vendor requests: `0x55` (prepare),
   `0x02` (start), then `0x12` with the `.bin` in 512-byte chunks. Then it
   sends `0x72` to reset the GPIF. Without that reset, the FPGA never answers on `0x88`.

**USB 3 works only with the original U220 cable.** Several other USB-C cables
link at 480M. On USB 3 the FPGA loads in about 9 s, on USB 2 in about 65 s.
Check with `lsusb -t` (`5000M` means USB 3), but only after the FX3 firmware is
loaded, because the bootloader always shows 480M.

## Control protocol

`fpga/top/b200_core.v` routes control packets by `sid[7:0] & 0xF0` (`0x40` =
local core). `fpga/lib/control_200/radio_ctrl_proc.v` handles them. All
words are 32-bit little-endian on the wire.

```
command  (16 bytes, EP 0x04): [0x8<<28 | seq<<16 | 16] [sid] [reg addr] [value]
response (24 bytes, EP 0x88): [0xA<<28 | seq<<16 | 24] [sid swapped] [time hi] [time lo] [readback hi] [readback lo]
```

Every command writes one setting register and returns the readback register
selected by setting register 32:

| Readback | Contents |
|---|---|
| 0 | `0xACE0BA5E` signature + compat major.minor |
| 1 | SPI readback |
| 2 | radio/GPSDO/misc status |
| 3 | lock state |

## Usage

```sh
# build (Vivado 2026.1, about 6 min); writes fpga/build/u220.bin
cd fpga && vivado -mode batch -source build.tcl

# load and test (needs python-pyusb and read/write access to the USB device)
python host/u220load.py fw path/to/usrp_b200_fw.hex   # once per power-up
python host/u220load.py fpga fpga/build/u220.bin
python host/u220regs.py                               # signature + compat
python host/u220regs.py peek 2
python host/u220regs.py poke 16 0x1
```

The FX3 firmware is not in this repo. It ships with MicroPhase's U220 package
and with UHD's B2xx images (`uhd_images_downloader`).

## Repo layout

```
fpga/top     board top level (antsdr_u220.v), b200_core.v, ppsloop.v
fpga/lib     the subset of the Ettus/MicroPhase FPGA library the design uses
fpga/ip      Vivado IP (.xci only, regenerated into build/)
fpga/xdc     pin and timing constraints
host/        UHD-free loader, register tool, bitstream chip-ID checker
```

## Changes from the vendor project

- Part `xc7a100tfgg484-2` changed to `xc7a200tfbg484-1`. IP upgraded to Vivado 2026.1.
  Timing is met at -1.
- Only files the build actually uses are kept. The build script uses relative
  paths and an out-of-tree `build/` directory.
- `COMPAT_MINOR` is set to 1, so this repo's images read back as 16.1 and the
  stock image as 16.0.

## Known warnings

- `u220.xdc:75-76` constrain `FPGA_RXD0/TXD0`, which aren't top-level ports.
- The FIFO Generator upgrade adds unused `rd_rst_busy`/`wr_rst_busy` outputs.

## License

The FPGA sources come from Ettus Research's UHD and MicroPhase's antsdr_uhd and
keep their original licenses: most file headers say LGPL-3.0-or-later and a few
say GPL. The vendor repo ships GPL-3.0, copied here as `LICENSE`, which also
covers the host tools.
