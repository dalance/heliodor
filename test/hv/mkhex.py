#!/usr/bin/env python3
# Assemble a flat DRAM image (one 32-bit little-endian word per line, $readmemh
# format) from (byte_offset:binary_file) placements relative to DRAM base
# 0x80000000. Usage:
#   mkhex.py out.hex 0:hv.bin 0x600000:Image 0x1000000:guest.dtb
import sys

out = sys.argv[1]
parts = []
maxlen = 0
for arg in sys.argv[2:]:
    off_s, path = arg.split(':', 1)
    off = int(off_s, 0)
    with open(path, 'rb') as f:
        data = f.read()
    parts.append((off, data))
    maxlen = max(maxlen, off + len(data))

img = bytearray((maxlen + 3) & ~3)
for off, data in parts:
    img[off:off + len(data)] = data

with open(out, 'w') as f:
    for i in range(0, len(img), 4):
        w = img[i] | (img[i + 1] << 8) | (img[i + 2] << 16) | (img[i + 3] << 24)
        f.write('%08x\n' % w)
