#!/usr/bin/env python3
"""Convert flat binary to simple hex (one 32-bit word per line)."""
import struct, sys

data = bytearray(open(sys.argv[1], 'rb').read())
# Pad to 4-byte alignment
if len(data) % 4:
    data += b'\x00' * (4 - len(data) % 4)
lines = ['%08X' % struct.unpack('<I', data[i:i+4])[0] for i in range(0, len(data), 4)]
open(sys.argv[2], 'w').write('\n'.join(lines) + '\n')
print('%d words (%d bytes)' % (len(lines), len(data)))
