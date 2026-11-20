import sys, hashlib
PARTS = {0x3631093:'XC7A100T',0x3636093:'XC7A200T',0x362D093:'XC7A35T',0x362C093:'XC7A50T',0x3632093:'XC7A75T',0x37C4093:'XC7A25T',0x362E093:'XC7A15T'}
rev8 = bytes(int(f'{b:08b}'[::-1],2) for b in range(256))
for p in sys.argv[1:]:
    d = open(p,'rb').read()
    print(p, len(d), 'bytes', hashlib.sha256(d).hexdigest()[:16])
    for name, data in (('normal', d), ('bit-reversed', d.translate(rev8))):
        s = data.find(b'\xaa\x99\x55\x66')
        i = data.find(b'\x30\x01\x80\x01')
        if s >= 0 or i >= 0:
            idc = int.from_bytes(data[i+4:i+8],'big') if i >= 0 else None
            print(f'  {name}: sync@{s} idcode_write@{i} idcode=0x{idc:08X} -> {PARTS.get(idc & 0x0FFFFFFF,"unknown")}' if idc is not None else f'  {name}: sync@{s}, no idcode write')
