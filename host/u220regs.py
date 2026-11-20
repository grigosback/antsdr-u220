#!/usr/bin/env python3
"""Talk to the U220 FPGA's local control core (b200_core.v) over USB, no UHD.

  u220regs.py            read all 4 core readback registers
  u220regs.py peek N     select readback N (0-3) and print it
  u220regs.py poke A V   write setting register A (0-255) with 32-bit value V

Packet format (radio_ctrl_proc.v), sent as little-endian 32-bit words:
  cmd : [hdr_hi][sid][addr][data]           hdr_hi = 0x8 << 28 | seq << 16 | 16 bytes
  resp: [hdr_hi][sid][time_hi][time_lo][rb_hi][rb_lo]
The FPGA routes on sid[7:0] & 0xF0 == 0x40 (L0 = local core). Every command
returns the readback register selected by setting register 32 (SR_CORE_READBACK).
"""
import struct, sys
import usb.core

VID, PID = 0x2500, 0x0020
EP_CTRL_OUT, EP_CTRL_IN = 0x04, 0x88
LOCAL_CTRL_SID = 0x00000040
SR_CORE_READBACK = 32
RB_NAMES = {0: 'signature/compat', 1: 'SPI readback', 2: 'radio/gpsdo/misc status', 3: 'lock state'}


class U220:
    def __init__(self):
        self.dev = usb.core.find(idVendor=VID, idProduct=PID)
        if self.dev is None:
            sys.exit('U220 not found')
        self.seq = 0
        if '--reset-gpif' in sys.argv:
            sys.argv.remove('--reset-gpif')
            self.dev.ctrl_transfer(0x40, 0x72, 0, 0, b'\0' * 4, 1000)  # VREQ_GPIF_RESET
        self.flush()

    def flush(self):
        while True:
            try:
                self.dev.read(EP_CTRL_IN, 1024, 50)
            except usb.core.USBTimeoutError:
                return

    def transact(self, addr, data):
        hdr = (0x8 << 28) | ((self.seq & 0xFFF) << 16) | 16
        self.dev.write(EP_CTRL_OUT, struct.pack('<4I', hdr, LOCAL_CTRL_SID, addr, data), 1000)
        resp = bytes(self.dev.read(EP_CTRL_IN, 1024, 1000))
        if len(resp) != 24:
            raise IOError(f'unexpected response length {len(resp)}: {resp.hex()}')
        h, sid, t_hi, t_lo, rb_hi, rb_lo = struct.unpack('<6I', resp)
        rseq = (h >> 16) & 0xFFF
        if rseq != (self.seq & 0xFFF):
            raise IOError(f'seq mismatch: sent {self.seq & 0xFFF}, got {rseq}')
        self.seq += 1
        return {'hdr': h, 'sid': sid, 'time': (t_hi << 32) | t_lo, 'rb': (rb_hi << 32) | rb_lo}

    def peek(self, n):
        return self.transact(SR_CORE_READBACK, n)['rb']

    def poke(self, addr, value):
        return self.transact(addr, value)


if __name__ == '__main__':
    u = U220()
    if len(sys.argv) >= 2 and sys.argv[1] == 'poke':
        r = u.poke(int(sys.argv[2], 0), int(sys.argv[3], 0))
        print(f'ok, time {r["time"]}, rb 0x{r["rb"]:016x}')
    elif len(sys.argv) >= 2 and sys.argv[1] == 'peek':
        print(f'0x{u.peek(int(sys.argv[2], 0)):016x}')
    else:
        r = u.transact(SR_CORE_READBACK, 0)
        print(f'response header 0x{r["hdr"]:08x} sid 0x{r["sid"]:08x} time {r["time"]}')
        for n in range(4):
            print(f'rb{n} {RB_NAMES[n]:24s} 0x{u.peek(n):016x}')
        rb0 = u.peek(0)
        sig, major, minor = rb0 >> 32, (rb0 >> 16) & 0xFFFF, rb0 & 0xFFFF
        ok = sig == 0xACE0BA5E
        print(f'signature 0x{sig:08x} ({"OK" if ok else "WRONG"}), FPGA compat {major}.{minor}')
        sys.exit(0 if ok else 1)
