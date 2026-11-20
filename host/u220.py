#!/usr/bin/env python3
"""Host side of the own U220 design (fpga/u220). Needs the FPGA loaded with
build/u220/u220.bin (see u220load.py).

  u220.py info                      ID, version, build time, uptime, pin registers
  u220.py rd ADDR [N]               read N registers from ADDR
  u220.py wr ADDR VALUE             write a register
  u220.py loopback [N]              send N random-size packets, check they come back
  u220.py gen [SECONDS] [THREADS]   FPGA->host throughput with the packet generator
  u220.py drain [SECONDS] [THREADS] host->FPGA throughput

Protocol: see fpga/u220/u220_ctrl.v (control) and u220_stream.v (data).
"""
import os, random, struct, sys, threading, time
import usb.core

VID, PID = 0x2500, 0x0020
EP_DATA_OUT, EP_DATA_IN, EP_CTRL_OUT, EP_CTRL_IN = 0x02, 0x86, 0x04, 0x88
MAX_OPS = 14            # keeps control packets within 120 bytes

REG = dict(ID=0x0000, VERSION=0x0001, BUILD=0x0002, SCRATCH=0x0003, UPTIME_LO=0x0004,
           UPTIME_HI=0x0005, BUS_CLK_HZ=0x0006, STREAM_MODE=0x0010, GEN_LEN=0x0011,
           TX_PKTS=0x0012, TX_WORDS=0x0013, RX_PKTS=0x0014, RX_WORDS=0x0015,
           STREAM_CLEAR=0x0016, CAT_CTRL=0x0020, CAT_CTRL_OUT=0x0021, FE_CTRL=0x0022,
           VCTCXO_DAC=0x0023)
MODE_DRAIN, MODE_LOOP, MODE_GEN = 0, 1, 2
ID_U220 = 0x55323230


def words_to_bytes(words):
    """64-bit words -> wire bytes: [63:32] first, each 32-bit half little-endian."""
    return b''.join(struct.pack('<II', w >> 32, w & 0xFFFFFFFF) for w in words)


def bytes_to_words(data):
    return [(hi << 32) | lo for hi, lo in struct.iter_unpack('<II', data)]


def decode_usr_access(v):
    """Vivado USR_ACCESS TIMESTAMP: ddddd MMMM yyyyyy hhhhh mmmmmm ssssss."""
    d, mo, y = v >> 27, (v >> 23) & 0xF, (v >> 17) & 0x3F
    h, mi, s = (v >> 12) & 0x1F, (v >> 6) & 0x3F, v & 0x3F
    return f'{2000 + y:04d}-{mo:02d}-{d:02d} {h:02d}:{mi:02d}:{s:02d}'


class U220:
    def __init__(self):
        self.dev = usb.core.find(idVendor=VID, idProduct=PID)
        if self.dev is None:
            sys.exit('U220 not found')
        self.seq = random.randrange(1 << 16)
        self._flush(EP_CTRL_IN)
        ident = self.rd(REG['ID'])
        if ident != ID_U220:
            sys.exit(f'ID register reads 0x{ident:08x}, expected 0x{ID_U220:08x}: '
                     'is build/u220/u220.bin loaded?')

    def _flush(self, ep):
        while True:
            try:
                self.dev.read(ep, 65536, 20)
            except usb.core.USBTimeoutError:
                return

    def transact(self, ops):
        """ops: list of (write, addr, value). Returns the read values."""
        out = []
        for i in range(0, len(ops), MAX_OPS):
            chunk = ops[i:i + MAX_OPS]
            seq = self.seq & 0xFFFF
            self.seq += 1
            hdr = (seq << 48) | (((len(chunk) + 1) * 8) << 32) | 0x52454700  # "REG\0"
            words = [hdr] + [(int(w) << 63) | (a << 32) | (v & 0xFFFFFFFF) for w, a, v in chunk]
            self.dev.write(EP_CTRL_OUT, words_to_bytes(words), 1000)
            resp = bytes_to_words(bytes(self.dev.read(EP_CTRL_IN, 1024, 1000)))
            if len(resp) != len(words) or resp[0] != hdr:
                raise IOError(f'bad response {[hex(w) for w in resp]} to {[hex(w) for w in words]}')
            out += [w & 0xFFFFFFFF for w in resp[1:]]
        return out

    def rd(self, addr, n=1):
        vals = self.transact([(0, addr + i, 0) for i in range(n)])
        return vals[0] if n == 1 else vals

    def wr(self, addr, value):
        return self.transact([(1, addr, value)])[0]

    # USB 3 bulk packets are 1024 bytes. A transfer that is an exact multiple of
    # 1024 has no short packet at the end, so the FX3 keeps waiting for more:
    # follow it with a zero-length packet. In the other direction the FPGA's
    # GPIF interface appends one 32-bit pad word to such packets instead, so
    # received packets are trimmed to the length in their header.
    def send_data(self, data, timeout=1000):
        self.dev.write(EP_DATA_OUT, data, timeout)
        if len(data) % 1024 == 0:
            self.dev.write(EP_DATA_OUT, b'', timeout)

    def recv_data(self, timeout=1000):
        data = bytes(self.dev.read(EP_DATA_IN, 65536, timeout))
        length = struct.unpack_from('<I', data)[0] & 0xFFFF
        if len(data) == length + 4 and length % 1024 == 0:
            data = data[:length]
        return data

    def stream_reset(self, mode=MODE_DRAIN):
        self.wr(REG['STREAM_MODE'], MODE_DRAIN)
        self.dev.write(EP_DATA_OUT, b'', 1000)   # release a packet the FX3 may still hold
        time.sleep(0.05)
        self._flush(EP_DATA_IN)
        self.wr(REG['STREAM_CLEAR'], 1)
        if mode != MODE_DRAIN:
            self.wr(REG['STREAM_MODE'], mode)


def cmd_info(u):
    r = dict(zip(REG, u.rd(0, 7)))
    lo, hi = u.transact([(0, REG['UPTIME_LO'], 0), (0, REG['UPTIME_HI'], 0)])
    clk = r['BUS_CLK_HZ']
    print(f"ID          0x{r['ID']:08x} ({struct.pack('>I', r['ID']).decode()})")
    print(f"version     {r['VERSION'] >> 16}.{r['VERSION'] & 0xFFFF}")
    print(f"built       {decode_usr_access(r['BUILD'])} (0x{r['BUILD']:08x})")
    print(f"uptime      {((hi << 32) | lo) / clk:.3f} s at {clk / 1e6:g} MHz")
    for name in ('STREAM_MODE', 'GEN_LEN', 'CAT_CTRL', 'CAT_CTRL_OUT', 'FE_CTRL', 'VCTCXO_DAC'):
        print(f'{name.lower():11s} 0x{u.rd(REG[name]):x}')


def cmd_loopback(u, n=200):
    u.stream_reset(MODE_LOOP)
    rng = random.Random(1)
    t = time.time()
    total = 0
    for p in range(n):
        # every 4th packet is an exact multiple of 1024 bytes (the ZLP/pad case)
        nwords = 128 * rng.randint(1, 8) if p % 4 == 0 else rng.randint(2, 1024)
        words = [((p & 0xFFFF) << 48) | ((nwords * 8) << 32) | 0x4C4F4F50]
        words += [rng.getrandbits(64) for _ in range(nwords - 1)]
        data = words_to_bytes(words)
        u.send_data(data)
        back = u.recv_data()
        if back != data:
            sys.exit(f'packet {p}: sent {len(data)} bytes, got {len(back)} back, '
                     f'first difference at byte {next((i for i, (a, b) in enumerate(zip(data, back)) if a != b), min(len(data), len(back)))}')
        total += len(data)
    dt = time.time() - t
    tx, rx = u.rd(REG['TX_PKTS']), u.rd(REG['RX_PKTS'])
    u.wr(REG['STREAM_MODE'], MODE_DRAIN)
    print(f'loopback OK: {n} packets, {total} bytes, all identical '
          f'(FPGA counted {tx} in / {rx} out), {total / dt / 1e6:.1f} MB/s round trip')


def cmd_gen(u, seconds=5.0, threads=4, gen_len=1021):
    u.stream_reset(MODE_DRAIN)
    u.wr(REG['GEN_LEN'], gen_len)
    pkt_bytes = (gen_len + 1) * 8
    results, errors = [], []
    stop = threading.Event()

    def reader():
        mine = []
        while not stop.is_set():
            try:
                data = u.recv_data(200)
            except usb.core.USBTimeoutError:
                continue
            hdr = struct.unpack_from('<II', data)
            seq, length = hdr[0] >> 16, hdr[0] & 0xFFFF
            if length != len(data) or len(data) != pkt_bytes:
                errors.append(f'packet seq {seq}: header says {length}, got {len(data)} bytes')
                continue
            first = bytes_to_words(data[8:16])[0]
            last = bytes_to_words(data[-8:])[0]
            if last - first != gen_len - 1:
                errors.append(f'packet seq {seq}: counter jumps inside the packet')
            mine.append(first)
        results.append(mine)

    ts = [threading.Thread(target=reader) for _ in range(threads)]
    for t in ts:
        t.start()
    u.wr(REG['STREAM_MODE'], MODE_GEN)
    t0 = time.time()
    time.sleep(seconds)
    u.wr(REG['STREAM_MODE'], MODE_DRAIN)
    dt = time.time() - t0
    time.sleep(0.3)
    stop.set()
    for t in ts:
        t.join()
    firsts = sorted(f for r in results for f in r)
    gaps = sum(1 for a, b in zip(firsts, firsts[1:]) if b - a != gen_len)
    fpga_pkts = u.rd(REG['RX_PKTS'])
    mb = len(firsts) * pkt_bytes / 1e6
    print(f'generator: {len(firsts)} packets of {pkt_bytes} bytes in {dt:.2f} s = {mb / dt:.1f} MB/s '
          f'({threads} reader threads)')
    print(f'  FPGA sent {fpga_pkts} packets, host got {len(firsts)}; '
          f'{gaps} gaps in the counter, {len(errors)} bad packets')
    for e in errors[:5]:
        print('  ', e)
    return not errors and gaps == 0 and fpga_pkts == len(firsts)


def cmd_drain(u, seconds=5.0, threads=4, nwords=1022):
    u.stream_reset(MODE_DRAIN)
    words = [(nwords * 8) << 32 | 0x44524E30] + list(range(nwords - 1))
    data = words_to_bytes(words)
    sent = [0] * threads
    stop = threading.Event()

    def writer(i):
        while not stop.is_set():
            u.send_data(data)
            sent[i] += 1

    ts = [threading.Thread(target=writer, args=(i,)) for i in range(threads)]
    t0 = time.time()
    for t in ts:
        t.start()
    time.sleep(seconds)
    stop.set()
    for t in ts:
        t.join()
    dt = time.time() - t0
    n = sum(sent)
    fpga_pkts, fpga_words = u.rd(REG['TX_PKTS']), u.rd(REG['TX_WORDS'])
    print(f'drain: {n} packets of {len(data)} bytes in {dt:.2f} s = {n * len(data) / dt / 1e6:.1f} MB/s')
    print(f'  FPGA counted {fpga_pkts} packets / {fpga_words} words '
          f'(expected {n} / {n * nwords})')
    return fpga_pkts == n and fpga_words == n * nwords


if __name__ == '__main__':
    args = sys.argv[1:] or ['info']
    u = U220()
    cmd, rest = args[0], args[1:]
    num = lambda s: int(s, 0)
    if cmd == 'info':
        cmd_info(u)
    elif cmd == 'rd':
        a, n = num(rest[0]), num(rest[1]) if len(rest) > 1 else 1
        vals = u.rd(a, n)
        for i, v in enumerate(vals if n > 1 else [vals]):
            print(f'0x{a + i:04x}: 0x{v:08x}')
    elif cmd == 'wr':
        old = u.wr(num(rest[0]), num(rest[1]))
        print(f'0x{num(rest[0]):04x}: 0x{old:08x} -> 0x{u.rd(num(rest[0])):08x}')
    elif cmd == 'loopback':
        cmd_loopback(u, num(rest[0]) if rest else 200)
    elif cmd == 'gen':
        sys.exit(0 if cmd_gen(u, float(rest[0]) if rest else 5.0, int(rest[1]) if len(rest) > 1 else 4) else 1)
    elif cmd == 'drain':
        sys.exit(0 if cmd_drain(u, float(rest[0]) if rest else 5.0, int(rest[1]) if len(rest) > 1 else 4) else 1)
    else:
        sys.exit(__doc__)
