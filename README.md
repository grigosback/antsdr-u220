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

## Two FPGA targets

| Target | Top | What it is |
|---|---|---|
| `u220` | `fpga/u220/u220_top.v` | **Own minimal design**: register file, USB loopback, packet generator. AD9361 held in reset, TX amps off |
| `b210compat` | `fpga/b210compat/antsdr_u220.v` | MicroPhase's B210-compatible design, retargeted to the 200T. Known-good reference |

Both share `fpga/lib` (Ettus/MicroPhase library subset) and `fpga/ip`.
The own design reuses only two pieces of the vendor design: `gpif2_slave_fifo32`
(the FPGA side of the stock FX3 firmware's slave FIFO) and the `gen_clks` MMCM
(40 MHz in, 100 MHz out).

## Own design (`u220`)

### Control packets (endpoints 0x04 / 0x88), see `fpga/u220/u220_ctrl.v`

Packets are 64-bit words; bits [63:32] go first on the wire, each 32-bit half
little-endian.

```
header  [63:48] seq  [47:32] packet length in bytes  [31:0] tag
op      [63] write   [47:32] register address        [31:0] write data
```

Up to 14 ops per packet. The response has the same length: the header is echoed
and each op comes back as `{op[63:32], read data}`. A write returns the
register's previous value.

### Registers, see `fpga/u220/u220_core.v`

| Addr | | Name | |
|---|---|---|---|
| 0x0000 | ro | ID | `0x55323230` "U220" |
| 0x0001 | ro | VERSION | major.minor |
| 0x0002 | ro | BUILD | bitstream timestamp (USR_ACCESS) |
| 0x0003 | rw | SCRATCH | |
| 0x0004/5 | ro | UPTIME_LO/HI | bus_clk cycles, reading LO latches HI |
| 0x0006 | ro | BUS_CLK_HZ | 100 MHz |
| 0x0010 | rw | STREAM_MODE | 0 drain, 1 loopback, 2 generator |
| 0x0011 | rw | GEN_LEN | generator payload words/packet (1021 = 8176-byte packets) |
| 0x0012-15 | ro | TX_PKTS, TX_WORDS, RX_PKTS, RX_WORDS | data counters |
| 0x0016 | wo | STREAM_CLEAR | clear counters and generator |
| 0x0020 | rw | CAT_CTRL | AD9361 RESETn, EN, TXnRX, EN_AGC, CTRL_IN, SYNC (default 0x1E: in reset) |
| 0x0021 | ro | CAT_CTRL_OUT | AD9361 CTRL_OUT |
| 0x0022 | rw | FE_CTRL | TX amps, RF switches (default 0: amps off) |
| 0x0023 | rw | VCTCXO_DAC | 40 MHz trim DAC (LTC2630), default 0xBFFF |
| 0x0030-3F | | | reserved for the AD9361 SPI master |

### Data endpoints (0x02 / 0x86), see `fpga/u220/u220_stream.v`

Every data packet starts with a header word whose `[47:32]` is the packet
length in bytes. The GPIF interface checks this on the way in.

**USB packet rule.** Bulk packets on USB 3 are 1024 bytes.
- A host-to-FPGA transfer that is an exact multiple of 1024 bytes stays stuck
  in the FX3 until a zero-length packet follows it.
- In the other direction, the GPIF interface appends a 32-bit pad word to such
  packets.

`U220.send_data()` and `U220.recv_data()` in `host/u220.py` handle both.

### Measured on the board (USB 3, Python + pyusb, 4 threads)

| Test | Result |
|---|---|
| loopback | 400 packets of random sizes up to 8 KB incl. multiples of 1024, all identical |
| FPGA to host (generator) | 377 MB/s, 230k packets, no counter gaps |
| host to FPGA (drain) | 294 MB/s, FPGA packet/word counts match |

## Usage

```sh
# simulate the own core (xsim): registers, loopback, generator with backpressure
fpga/u220/sim/run.sh

# build (Vivado 2026.1, about 5 min); -> fpga/build/<target>/<target>.bin
cd fpga && vivado -mode batch -source build.tcl -tclargs u220
cd fpga && vivado -mode batch -source build.tcl -tclargs b210compat

# load (needs python-pyusb and read/write access to the USB device)
python host/u220load.py fw path/to/usrp_b200_fw.hex   # once per power-up
python host/u220load.py fpga fpga/build/u220/u220.bin

# own design
python host/u220.py info
python host/u220.py rd 0x0010 4
python host/u220.py wr 0x0003 0x12345678
python host/u220.py loopback
python host/u220.py gen 5        # seconds
python host/u220.py drain 5

# B210-compatible image
python host/b210compat_regs.py
```

The FX3 firmware is not in this repo. It ships with MicroPhase's U220 package
and with UHD's B2xx images (`uhd_images_downloader`).

## Repo layout

```
fpga/build.tcl     build either target out of tree into fpga/build/
fpga/u220/         own design (top, core, ctrl, stream, constraints, sim/)
fpga/b210compat/   vendor B210-compatible design (top, b200_core, ppsloop, constraints)
fpga/lib/          the subset of the Ettus/MicroPhase FPGA library both targets use
fpga/ip/           Vivado IP (.xci only, regenerated into build/); <target>/ip.txt picks them
host/              loader, own-design tool, B210-compat register tool, bitstream chip-ID checker
```

## Changes from the vendor project

- Part `xc7a100tfgg484-2` changed to `xc7a200tfbg484-1`. IP upgraded to Vivado 2026.1.
  Timing is met at -1.
- Only files the build actually uses are kept. The build script uses relative
  paths and an out-of-tree `build/` directory.
- `b210compat`: `COMPAT_MINOR` is set to 1, so this repo's image reads back as
  16.1 and the stock image as 16.0.

## Known warnings

- `b210compat`: `u220.xdc:75-76` constrain `FPGA_RXD0/TXD0`, which aren't ports of that top.
- Both: the vendor constraints set `SLEW` on some input pins, which Vivado ignores.

## License

The FPGA sources come from Ettus Research's UHD and MicroPhase's antsdr_uhd and
keep their original licenses: most file headers say LGPL-3.0-or-later and a few
say GPL. The vendor repo ships GPL-3.0, copied here as `LICENSE`, which also
covers the host tools.
