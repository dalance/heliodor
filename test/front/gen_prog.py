#!/usr/bin/env python3
"""Instruction images for the front-end unit test (tb/test_front.veryl).

Writes two 4 KiB images of 16-bit parcels, one hex parcel per line: dram.hex
and rom.hex. The test mirrors each image over its whole region, and the
predictor aliases a ROM block with the DRAM block at the same offset.

dram.hex starts with a loop that calls two functions (one nested), so that
returns are predicted from the return address stack; the rest is a random mix
of RVC and 32-bit instructions at any halfword alignment (so 32-bit
instructions straddle fetch blocks), short branches and jumps, and calls and
returns per the JALR hint table. rom.hex keeps the first half of dram.hex with
different jump offsets (aliased blocks predict a wrong direct target) and has
random contents in the second half (aliased blocks predict exits that are not
there).
"""
import random
import sys
from pathlib import Path

N_HW = 2048


def rvc_alu(r):
    while True:
        k = r.randrange(3)
        if k == 0:  # c.addi rd, imm (rd != 0)
            rd = r.randrange(1, 32)
            v = (0b000 << 13) | (r.randrange(2) << 12) | (rd << 7) | (r.randrange(32) << 2) | 0b01
        elif k == 1:  # c.mv rd, rs2 (rd, rs2 != 0)
            v = (0b100 << 13) | (0 << 12) | (r.randrange(1, 32) << 7) | (r.randrange(1, 32) << 2) | 0b10
        else:  # c.lw rd', imm(rs1')
            v = (0b010 << 13) | (r.randrange(8) << 10) | (r.randrange(8) << 7) | (r.randrange(4) << 5) \
                | (r.randrange(8) << 2) | 0b00
        if v != 0:
            return [v]


def w32(v):
    return [v & 0xFFFF, (v >> 16) & 0xFFFF]


def addi(r):
    return w32((r.randrange(4096) << 20) | (r.randrange(32) << 15) | (0 << 12) | (r.randrange(32) << 7) | 0b0010011)


def br(r):
    off = r.choice([-1, 1]) * r.randrange(1, 64) * 2
    f3 = r.choice([0, 1, 4, 5, 6, 7])
    imm = off & 0x1FFF
    v = (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (r.randrange(32) << 20) | (r.randrange(32) << 15) \
        | (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0b1100011
    return w32(v)


def jal(r, rd, lo, hi):
    off = r.choice([-1, 1]) * r.randrange(lo, hi) * 2
    imm = off & 0x1FFFFF
    v = (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) \
        | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0b1101111
    return w32(v)


def jalr(rd, rs1):
    return w32((0 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0b1100111)


def cb(r):
    off = r.choice([-1, 1]) * r.randrange(1, 32) * 2
    imm = off & 0x1FF
    v = (r.choice([0b110, 0b111]) << 13) | (((imm >> 8) & 1) << 12) | (((imm >> 3) & 3) << 10) \
        | (r.randrange(8) << 7) | (((imm >> 6) & 3) << 5) | (((imm >> 1) & 3) << 3) | (((imm >> 5) & 1) << 2) | 0b01
    return [v]


def cj(r):
    off = r.choice([-1, 1]) * r.randrange(2, 128) * 2
    imm = off & 0xFFF
    v = (0b101 << 13) | (((imm >> 11) & 1) << 12) | (((imm >> 4) & 1) << 11) | (((imm >> 8) & 3) << 9) \
        | (((imm >> 10) & 1) << 8) | (((imm >> 6) & 1) << 7) | (((imm >> 7) & 1) << 6) | (((imm >> 1) & 7) << 3) \
        | (((imm >> 5) & 1) << 2) | 0b01
    return [v]


def jal_at(src, dst, rd):
    off = (dst - src) & 0x1FFFFF
    v = (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21) | (((off >> 11) & 1) << 20) \
        | (((off >> 12) & 0xFF) << 12) | (rd << 7) | 0b1101111
    return w32(v)


# The call loop at offset 0: main calls f and g, g calls f; f returns with
# c.jr ra, g with jalr x0, 0(x1).
def call_loop():
    hw = [None] * 128
    def put(byte_off, parcels):
        for i, p in enumerate(parcels):
            hw[byte_off // 2 + i] = p
    put(0x00, [0x0505])                  # c.addi x10, 1
    put(0x02, jal_at(0x02, 0x40, 1))     # call f
    put(0x06, addi(random.Random(7)))
    put(0x0a, jal_at(0x0a, 0x80, 1))     # call g
    put(0x0e, [0x0505])
    put(0x10, jal_at(0x10, 0x00, 0))     # loop
    put(0x40, [0x0505])                  # f:
    put(0x42, addi(random.Random(8)))
    put(0x46, [0x8082])                  # ret
    put(0x80, addi(random.Random(9)))    # g:
    put(0x84, jal_at(0x84, 0x40, 1))     # call f
    put(0x88, [0x0505])
    put(0x8a, [0x0505])
    put(0x8c, [0x0505])
    put(0x8e, jalr(0, 1))                # ret, straddles 16-byte blocks
    return [0x0001 if p is None else p for p in hw]  # c.nop fill


def gen(seed):
    r = random.Random(seed)
    table = [
        (34, rvc_alu),
        (30, addi),
        (10, br),
        (4, cb),
        (4, lambda r: jal(r, 0, 2, 128)),
        (3, lambda r: jal(r, 1, 2, 256)),  # call
        (2, cj),
        (3, lambda r: jalr(0, 1)),  # ret
        (2, lambda r: [0x8082]),  # c.jr x1, ret
        (2, lambda r: [0x9302]),  # c.jalr x6, call
        (1, lambda r: jalr(1, 5)),  # pop then push
        (1, lambda r: jalr(0, 6)),  # plain indirect jump
        (1, lambda r: [0x8282]),  # c.jr x5, ret
    ]
    total = sum(w for w, _ in table)
    out = []
    while len(out) < N_HW:
        x = r.randrange(total)
        for w, f in table:
            if x < w:
                out += f(r)
                break
            x -= w
    return out[:N_HW]


def retarget(img, seed):
    """Copy of img with new offsets for every 32-bit JAL found on a sequential walk."""
    r = random.Random(seed)
    out = list(img)
    i = 0
    while i < len(img):
        if img[i] & 3 == 3:
            if img[i] & 0x7F == 0x6F and i + 1 < len(img):
                rd = (img[i] >> 7) & 0x1F
                out[i:i + 2] = jal(r, rd, 2, 128)
            i += 2
        else:
            i += 1
    return out


def main():
    d = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent)
    dram = call_loop() + gen(1)[128:]
    rom = retarget(dram[:N_HW // 2], 3) + gen(2)[N_HW // 2:]
    for name, img in (("dram.hex", dram), ("rom.hex", rom)):
        (d / name).write_text("".join(f"{v:04x}\n" for v in img))


if __name__ == "__main__":
    main()
