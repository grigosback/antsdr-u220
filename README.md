# ANTSDR U220 without vendor software

Build your own FPGA images for the MicroPhase ANTSDR U220 (AD9361 version) and
talk to them over USB from Python and C++, without UHD, GNU Radio or MicroPhase
tools. The own design streams AD9361 RX samples at up to 61.44 MS/s.

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
| Clock | 40 MHz always-on oscillator, LTC2630 DAC for trimming | The vendor pin names say AD5662 |
| GPS / reference | On-board GPS module (GPS + GLONASS NMEA at 9600 baud, PPS to the FPGA), REF input for PPS or 10 MHz | See "GPS module and reference inputs" |
| RF ports | RX1, TX/RX1, RX2, TX/RX2 | Two receivers: each channel switches between its RX port and its TX/RX port. See "RF switches" |
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
| `u220` | `fpga/u220/u220_top.v` | **Own design**: register file, USB loopback, packet generator, AD9361 SPI master, RX sample streaming (1 or 2 channels). AD9361 held in reset at power-up, TX amps off, TX data port idle |
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
| 0x0010 | rw | STREAM_MODE | 0 drain, 1 loopback, 2 generator, 3 RX samples |
| 0x0011 | rw | GEN_LEN | generator payload words/packet (1021 = 8176-byte packets) |
| 0x0012-15 | ro | TX_PKTS, TX_WORDS, RX_PKTS, RX_WORDS | data counters |
| 0x0016 | wo | STREAM_CLEAR | clear counters and generator |
| 0x0020 | rw | CAT_CTRL | AD9361 RESETn, EN, TXnRX, EN_AGC, CTRL_IN, SYNC (default 0x1E: in reset) |
| 0x0021 | ro | CAT_CTRL_OUT | AD9361 CTRL_OUT |
| 0x0022 | rw | FE_CTRL | TX amps, RF switches (default 0: amps off) |
| 0x0023 | rw | VCTCXO_DAC | 40 MHz trim DAC (LTC2630), default 0xBFFF |
| 0x0030 | rw | SPI_XFER | write: start a 24-bit AD9361 transfer; read: {busy, last 24 bits in} |
| 0x0031 | ro | SPI_RDATA | last 24 bits shifted in, [7:0] = value of a read |
| 0x0032 | rw | SPI_HALF | SCLK half period in bus_clk cycles, default 10 (5 MHz) |
| 0x0040 | rw | RADIO_CTRL | [0] enable, [1] two channels, [2] test counter, [3] reset (default 1) |
| 0x0041 | rw | RADIO_SPP | sample words per packet, 1..2000, default 1020 (8176-byte packets) |
| 0x0042 | ro | RADIO_STATUS | RX_FRAME patterns seen, overflow flags, running, idle |
| 0x0043 | ro | RADIO_CLK_HZ | measured AD9361 DATA_CLK, 10 Hz resolution |
| 0x0044/5 | ro | RADIO_PKTS, RADIO_DROPS | sample packets sent / dropped |
| 0x0050 | rw | GPS_CTRL | [0] GPS module nRST (default 1: running) |
| 0x0051 | rw | GPS_UART_DIV | bus_clk cycles per bit, default 9600 baud |
| 0x0052 | ro | GPS_UART_COUNT | bytes received from the GPS module |
| 0x0053/4 | rw/ro | GPS_UART_ADDR, GPS_UART_DATA | 512-byte ring buffer, read 4 bytes at ADDR |
| 0x0055 | rw | GPS_RX_MINW | shortest pulse on the GPS UART line (one bit time); write: restart |
| 0x0056 | ro | GPS_UART_FERR | framing errors |
| 0x0057 | ro | REF_LEVELS | {CLKIN_10MHz, GPS_UART_RX, PPS_IN_EXT, PPS_IN_INT} |
| 0x0058..B | ro | EDGES_* | rising edges in the last second: PPS_IN_INT, PPS_IN_EXT, CLKIN_10MHz, GPS_UART_RX |
| 0x005C/D | ro | PPS_INT/EXT_PERIOD | bus_clk cycles between the last two PPS edges (measures the 40 MHz oscillator) |
| 0x0060..3 | ro | EDGES_TOTAL_* | rising edges in total, same order |

Accesses to 0x0030/0x0031 wait in hardware until the previous SPI transfer is
done, so one control packet can carry up to 14 SPI ops with no polling.

### AD9361 SPI, see `fpga/u220/u220_spi.v`

24-bit words: `[23]` write, `[17:8]` register, `[7:0]` data. The AD9361 needs
**SPI mode 1** (MOSI changes on rising edges, MISO sampled before falling
edges), which is how the vendor core runs it with UHD's settings. Found on the
board with an A/B test against the vendor core:
- mode 0 gives garbage
- sampling MISO before the rising edge reads every value one bit late

Product ID (0x037) reads `0x0A`: AD9361, revision 2, which matches UHD's check
`(ID & 0xF8) == 0x08`. Write/readback works at 1, 5 and 10 MHz SCLK. At 16.7 MHz
reads are one bit late. Batched reads take about 14 µs each above 5 MHz, so USB
round trips set the pace there, not the SPI clock.

### Data endpoints (0x02 / 0x86), see `fpga/u220/u220_stream.v`

Every data packet starts with a header word whose `[47:32]` is the packet
length in bytes. The GPIF interface checks this on the way in.

**USB packet rule.** Bulk packets on USB 3 are 1024 bytes.
- A host-to-FPGA transfer that is an exact multiple of 1024 bytes stays stuck
  in the FX3 until a zero-length packet follows it.
- In the other direction, the GPIF interface appends a 32-bit pad word to such
  packets.

`U220.send_data()` and `U220.recv_data()` in `host/u220.py` handle both.

### AD9361 bring-up with UHD's driver, see `host/cpp`

`host/cpp` is a small C++ library (libusb) for the own design. It includes
UHD's AD9361 driver (`ad9361_device.cpp`), vendored together with UHD's
filter and sensor types and minimal stand-ins for the rest of UHD. The driver
only needs `peek8`/`poke8`, which go through the FPGA SPI master. The board
parameters are UHD's B200/B210 values: LVCMOS DDR FDD interface, XTAL_N clock
path, RX/TX delays 0/0xF.

```sh
cmake -S host/cpp -B host/cpp/build && cmake --build host/cpp/build
host/cpp/build/u220_ad9361 --rate 30.72e6 --freq 2.4e9 --gain 60 --bw 20e6
```

`u220_ad9361` resets the AD9361 and runs UHD's `initialize()` (BBPLL,
calibrations). It then sets the clock rate, enables only the RX chains, tunes,
and reports the PLL locks, the ENSM state, the temperature and RSSI. TX chains
stay disabled, TX gain stays at minimum, and it refuses to run if the board's
TX amplifiers are on in `FE_CTRL`.

On the board, these all ended with the BBPLL and RX synthesizer locked and the
ENSM in FDD:

| Clock rate | RX frequency | Chains |
|---|---|---|
| 16 MHz | 100 MHz | RX1+RX2 |
| 30.72 MHz | 2.4 GHz | RX1+RX2 |
| 61.44 MHz | 5.8 GHz | RX1 |
| 1 MHz | 433.92 MHz | RX2 |

A full init at 16 MHz is about 1 s and about 4,700 SPI transfers.

### RX samples, see `fpga/u220/u220_rx_io.v`, `fpga/u220/u220_radio.v`

**Capture.** The AD9361 data port runs in CMOS DDR FDD mode: 12 bits, I on one
edge of DATA_CLK and Q on the other. The FPGA captures it exactly like the
vendor design (`DATA_CLK -> BUFR -> IDDR`, then a BUFG for the rest), because
that structure is known to work with UHD's interface delays. DATA_CLK equals
the sample rate on one channel. With two channels it is twice the rate, and
RX_FRAME is high for RX1 and low for RX2. `RADIO_CLK_HZ` measures it.

**Samples.** Samples are 16-bit I and Q with the 12 bits left-justified, the
usual `sc16` layout. Two samples go in each 64-bit word: consecutive samples on
one channel, or `{RX1, RX2}` of the same instant on two channels. The words
cross into bus_clk through a 16-deep gray-code FIFO (`u220_cdc_fifo.v`), and
the bus_clk side always reads it, so it can't overflow.

**Packets** (endpoint 0x86):

```
word 0  [63:48] seq  [47:32] length in bytes  [31:8] "SMP"  [7:0] flags
word 1  time: per-channel sample count of the first sample
word 2+ two samples each
flags   [0] packets were dropped before this one  [1] two channels
```

A packet only starts if the 64 KB packet FIFO has room for all of it.
Otherwise the whole packet is dropped, the time keeps counting and the next
packet is flagged. A slow host therefore loses whole packets, never parts of
them, and can count exactly how many samples it missed.

**Rules.** Hold `RADIO_CTRL[3]` (reset) while the AD9361 is reset or its clocks
change, and while changing the channel count or the test mode. Reset pads an
unfinished packet with zeros, so the USB side never sees a partial packet.
Clearing enable finishes the current packet and stops.

```sh
host/cpp/build/u220_rx --rate 20e6 --freq 98e6 --gain 40 --rx1 --num 20e6 --out fm.cs16
python host/iq_spectrum.py fm.cs16 --rate 20e6 --freq 98e6 --png fm.png
host/cpp/build/u220_rx --test --rate 61.44e6 --rx1 --num 3.7e9 --discard   # 60 s stress test
host/cpp/build/u220_rx --rate 61.44e6 --rx1 --bist 0 --num 4e6 --out bist.cs16
```

`u220_rx` sets up the AD9361 (RX only), checks DATA_CLK, streams, and checks
the sequence number and time of every packet. `--test` replaces the samples
with a counter in the FPGA and checks every sample. `--bist` makes the AD9361
inject a digital tone at its data port instead of ADC data. A clean tone means
every bit of the capture is right, which an RF signal can't show.

Measured on the board (C++, libusb, 32 async transfers):

| Test | Result |
|---|---|
| test counter, 1 channel, 61.44 MS/s | 246 MB/s for 60 s, 3.7 G samples, 0 drops, 0 errors |
| test counter, 2 channels, 30.72 MS/s | 246 MB/s, DATA_CLK 61.44 MHz, 0 drops, 0 errors |
| AD9361 tone, 61.44 MS/s (DATA_CLK 61.44 MHz) | tone exactly at rate/32, image −178 dB, floor −194 dBFS: no capture bit errors |
| AD9361 tone, 2 channels, mask on RX2 | RX2 reads exact zeros, RX1 unaffected: channels are not swapped |
| FM band, 98 MHz LO, 20 MS/s | stations visible; retuning the LO by 1 MHz leaves them at the same RF frequencies, so I/Q are not swapped |

### RF switches (FE_CTRL)

The vendor pin names and their comments disagree, so the switches were mapped
on the board. Setup: antennas on TX/RX1 and TX/RX2, nothing on RX1/RX2; FM band,
98 MHz LO, gain 40, levels of six FM stations compared.

| FE_CTRL | RX1 | RX2 |
|---|---|---|
| 0x00 (default) | antenna on TX/RX1 (90.5 MHz at −45 dBFS) | antenna on TX/RX2 (−44 dBFS) |
| bit 2 set | stations gone (−32 dB, noise floor): TX/RX1 disconnected | unchanged |
| bit 3, 4 or 5 set (any combination) | unchanged | unchanged |

So bit 2 (port `FE_RX1_SEL1`, pin R18; the vendor comment calls the net
`FE_TXRX1_SEL1`) is channel 1's TX/RX switch. Nothing found so far switches
channel 2, which always hears TX/RX2. Its switches may be on the four pins the
vendor constraints leave commented out (T18, N14, R14, R16, "SEL2"); those are
not driven yet. Still unknown: what bits 3-5 do, and the RX-port routing (needs
an antenna on RX1/RX2).

`u220_rx --poke REG=VAL` writes AD9361 registers after the setup (RX
experiments only; ENSM, TX attenuation and TX synth registers are refused).
Register 0x004 picks the AD9361 RX input: with port A (0x03) both channels
drop to the noise floor at 98 MHz, ports B (0x0C) and C (0x30, the driver's choice
below 1.2 GHz) both work there.

### GPS module and reference inputs, see `fpga/u220/u220_gps.v`

From the vendor design: the REF connector goes to `PPS_IN_EXT` (a 3.3 V FPGA
input) and takes a PPS or a 10 MHz square wave; the vendor's `ppsloop.v` tells
which and disciplines the 40 MHz oscillator through the trim DAC. There is no
separate reference PLL chip. The GPS connector feeds an on-board GPS module whose
serial output and PPS go to the FPGA. `CLKIN_10MHz` is a 1.8 V input the vendor
design does not use (purpose unknown).

The own design (1.3) only watches these inputs for now:

```sh
host/cpp/build/u220_gps --secs 5
```

prints the level and edge rate of every input, the oscillator offset against
each PPS, the GPS baud rate (from the shortest pulse) and the module's NMEA output.
Measured without a GPS antenna: the module sends GPS + GLONASS NMEA at 9600 baud
with no fix, so no PPS yet; REF and CLKIN_10MHz are quiet.

### USB throughput (USB 3, Python + pyusb, 4 threads)

| Test | Result |
|---|---|
| loopback | 400 packets of random sizes up to 8 KB incl. multiples of 1024, all identical |
| FPGA to host (generator) | 377 MB/s, 230k packets, no counter gaps |
| host to FPGA (drain) | 294 MB/s, FPGA packet/word counts match |

## Usage

```sh
# simulate the own core (xsim): registers, loopback, generator with backpressure,
# SPI against an AD9361 model, RX sample path with a fake AD9361 data port
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
python host/u220.py ad9361 id          # releases reset, product ID, write/readback
python host/u220.py ad9361 rd 0x000 16
python host/u220.py ad9361 wr 0x006 0x00

# B210-compatible image
python host/b210compat_regs.py
```

The FX3 firmware is not in this repo. It ships with MicroPhase's U220 package
and with UHD's B2xx images (`uhd_images_downloader`).

## Repo layout

```
fpga/build.tcl     build either target out of tree into fpga/build/
fpga/u220/         own design (top, core, ctrl, stream, spi, rx_io, radio, cdc_fifo, gps, constraints, sim/)
fpga/b210compat/   vendor B210-compatible design (top, b200_core, ppsloop, constraints)
fpga/lib/          the subset of the Ettus/MicroPhase FPGA library both targets use
fpga/ip/           Vivado IP (.xci only, regenerated into build/); <target>/ip.txt picks them
host/              loader, own-design tool, B210-compat register tool, bitstream chip-ID checker,
                   iq_spectrum.py (spectrum of a cs16 capture)
host/cpp/          C++ library (libusb) + UHD's AD9361 driver; tools u220_ad9361 (bring-up),
                   u220_rx (sample streaming) and u220_gps (GPS module, PPS/REF inputs)
```

## Changes from the vendor project

- Part `xc7a100tfgg484-2` changed to `xc7a200tfbg484-1`. IP upgraded to Vivado 2026.1.
  Timing is met at -1.
- Only files the build actually uses are kept. The build script uses relative
  paths and an out-of-tree `build/` directory.
- `b210compat`: `COMPAT_MINOR` is set to 1, so this repo's image reads back as
  16.1 and the stock image as 16.0.
- `u220`: the GPIF data and flag flip-flops are forced into the I/O blocks
  (`IOB TRUE` in `u220.xdc`). The vendor constraints leave them free, and one
  build placed the `GPIF_D[9]` input flip-flop far enough away to corrupt about
  4% of host-to-FPGA words. Run `host/u220.py loopback` after every build.

## Known warnings

- `b210compat`: `u220.xdc:75-76` constrain `FPGA_RXD0/TXD0`, which aren't ports of that top.
- Both: the vendor constraints set `SLEW` on some input pins, which Vivado ignores.

## DSP

The own design sends raw AD9361 samples and has no DSP in the FPGA yet. The
AD9361 does its own filtering and decimation (FIR and half-band stages that
UHD's driver configures), so its samples can go straight to USB. The
`b210compat` design is UHD's B210 radio. Per channel it has a DDC
(CORDIC frequency shift, CIC decimator and half-band filters) and a DUC
(CORDIC, CIC interpolator, half-band filters), timestamped VITA/CHDR framing
and sample format conversion. It uses 100 of the 740 DSP48 slices.

## License

The FPGA sources come from Ettus Research's UHD and MicroPhase's antsdr_uhd and
keep their original licenses: most file headers say LGPL-3.0-or-later and a few
say GPL. `host/cpp/third_party/uhd` is UHD host code (GPL-3.0-or-later). The
vendor repo ships GPL-3.0, copied here as `LICENSE`, which also covers the
host tools.
