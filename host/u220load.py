#!/usr/bin/env python3
"""Minimal ANTSDR U220 (B210-compatible) loader, no UHD needed.

  u220load.py info                 show USB state / FX3 status
  u220load.py fw  <usrp_b200_fw.hex>   load FX3 firmware into FX3 RAM (volatile)
  u220load.py fpga <bitstream.bin>     configure the FPGA through the FX3 (volatile)

Protocol mirrors UHD host/lib/usrp/b200/b200_iface.cpp. Nothing here writes
the FX3 EEPROM.
"""
import sys, time
import usb.core, usb.util

VID, PID = 0x2500, 0x0020
OUT, IN = 0x40, 0xC0  # vendor | host->dev / dev->host

FX3_FIRMWARE_LOAD = 0xA0
VREQ_FPGA_START, VREQ_FPGA_DATA, VREQ_FPGA_CONFIG = 0x02, 0x12, 0x55
VREQ_GET_COMPAT, VREQ_LOOP = 0x15, 0x22
VREQ_SET_FPGA_HASH = 0x1C
VREQ_GET_USB, VREQ_GET_STATUS = 0x80, 0x83
VREQ_GPIF_RESET = 0x72
STATES = {0: 'UNDEFINED', 1: 'FPGA_READY', 2: 'CONFIGURING_FPGA', 3: 'BUSY',
          4: 'RUNNING', 5: 'UNCONFIGURED', 6: 'ERROR'}


def find():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit('U220 (2500:0020) not found')
    return dev


def is_bootloader(dev):
    # Bootloader: 1 interface, no bulk endpoints. B200 firmware: several bulk interfaces.
    cfg = dev.get_active_configuration()
    return not any(ep for intf in cfg for ep in intf)


def status(dev):
    return dev.ctrl_transfer(IN, VREQ_GET_STATUS, 0, 0, 1, 1000)[0]


def usb_speed(dev):
    return dev.ctrl_transfer(IN, VREQ_GET_USB, 0, 0, 1, 1000)[0]


def info():
    dev = find()
    speed = {1: 'low', 2: 'full', 3: 'high (USB 2)', 4: 'super (USB 3)'}.get(dev.speed, dev.speed)
    print(f'bus {dev.bus} addr {dev.address}  link speed: {speed}')
    print(f'manufacturer={usb.util.get_string(dev, dev.iManufacturer)!r} '
          f'product={usb.util.get_string(dev, dev.iProduct)!r} '
          f'serial={usb.util.get_string(dev, dev.iSerialNumber)!r}')
    cfg = dev.get_active_configuration()
    for intf in cfg:
        eps = ', '.join(f'0x{ep.bEndpointAddress:02x}({ep.wMaxPacketSize})' for ep in intf)
        print(f'  interface {intf.bInterfaceNumber}: {eps or "no endpoints"}')
    if is_bootloader(dev):
        print('mode: FX3 bootloader (firmware not loaded yet)')
        return
    compat = dev.ctrl_transfer(IN, VREQ_GET_COMPAT, 0, 0, 2, 1000)
    print(f'mode: B200 firmware, compat {compat[1]}.{compat[0]}, '
          f'fw usb speed {usb_speed(dev)}, state {STATES.get(status(dev), "?")}')


def load_fw(path):
    dev = find()
    if not is_bootloader(dev):
        print('firmware already running; power-cycle the board to reload it')
        return
    entry = None
    upper = 0
    n = 0
    for line in open(path):
        line = line.strip()
        if not line.startswith(':'):
            continue
        b = bytes.fromhex(line[1:])
        if (sum(b) & 0xFF) != 0:
            sys.exit(f'bad checksum in {line}')
        ln, addr, typ, data = b[0], int.from_bytes(b[1:3], 'big'), b[3], b[4:4 + b[0]]
        if typ == 0x00:
            dev.ctrl_transfer(OUT, FX3_FIRMWARE_LOAD, addr, upper, data, 1000)
            n += ln
        elif typ == 0x04:
            upper = int.from_bytes(data, 'big')
        elif typ == 0x05:
            entry = int.from_bytes(data, 'big')
        elif typ == 0x01:
            break
    print(f'wrote {n} bytes, jumping to 0x{entry:08x}')
    try:  # zero-length write to the entry point = jump; device drops off the bus
        dev.ctrl_transfer(OUT, FX3_FIRMWARE_LOAD, entry & 0xFFFF, entry >> 16, b'', 1000)
    except usb.core.USBError:
        pass
    usb.util.dispose_resources(dev)
    for _ in range(50):
        time.sleep(0.2)
        d = usb.core.find(idVendor=VID, idProduct=PID)
        if d is not None and not is_bootloader(d):
            print('firmware running')
            return
    sys.exit('device did not come back with firmware')


def wait_state(dev, want, tries, delay=0.01):
    for _ in range(tries):
        s = status(dev)
        if s == want:
            return
        if s in (0, 6):
            break
        time.sleep(delay)
    sys.exit(f'FX3 state {STATES.get(s, s)}, expected {STATES[want]}')


def load_fpga(path):
    dev = find()
    if is_bootloader(dev):
        sys.exit('load the FX3 firmware first')
    size = 512 if usb_speed(dev) == 3 else 64
    dev.ctrl_transfer(IN, VREQ_LOOP, 0, 0, size, 1000)
    dev.ctrl_transfer(OUT, VREQ_SET_FPGA_HASH, 0, 0, b'\0' * 4, 1000)
    dev.ctrl_transfer(OUT, VREQ_FPGA_CONFIG, 0, 0, b'\0', 1000)
    wait_state(dev, 1, 500)
    dev.ctrl_transfer(OUT, VREQ_FPGA_START, 0, 0, b'\0', 1000)
    wait_state(dev, 2, 1000)
    data = open(path, 'rb').read()
    t = time.time()
    for i in range(0, len(data), size):
        dev.ctrl_transfer(OUT, VREQ_FPGA_DATA, 0, 0, data[i:i + size], 5000)
    print(f'sent {len(data)} bytes in {time.time() - t:.1f} s ({size}-byte chunks)')
    try:
        wait_state(dev, 4, 500)
    except SystemExit as e:
        sys.exit(f'FPGA did NOT configure: {e}')
    print('FPGA configured (DONE high), FX3 state RUNNING')
    dev.ctrl_transfer(OUT, VREQ_GPIF_RESET, 0, 0, b'\0' * 4, 1000)  # as UHD does
    print('GPIF reset done')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'info'
    {'info': lambda: info(), 'fw': lambda: load_fw(sys.argv[2]),
     'fpga': lambda: load_fpga(sys.argv[2])}[cmd]()
