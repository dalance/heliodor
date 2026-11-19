#!/usr/bin/env bash
# Add the allow-all PMP entry of linux_boot_fw.S to a prebuilt firmware image
# that predates it. The first instruction (csrw mie, zero, which every image
# starts with and every hart runs at reset) becomes a jump to a trampoline
# appended after the image, so no other address moves. The trampoline runs the
# displaced instruction, sets pmpaddr0 = all ones and pmpcfg0 = NAPOT|R|W|X,
# and returns to 0x4.
#
#   test/linux/fw/patch_pmp_allow_all.sh in.hex out.hex
set -euo pipefail
in="${1:?in.hex}"; out="${2:?out.hex}"
CC="${RISCV_LINUX_PREFIX:-riscv64-unknown-linux-gnu-}"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
first=$(head -1 "$in" | tr 'A-F' 'a-f')
[ "$first" = "30401073" ] || { echo "$in does not start with csrw mie, zero"; exit 1; }
words=$(wc -w < "$in"); tramp=$(( words * 4 ))
cat > "$t/p.S" <<ASM
.option norvc
.section .text
  j $tramp
.org $tramp
  csrw mie, zero
  li   t0, -1
  csrw pmpaddr0, t0
  li   t0, 0x1f
  csrw pmpcfg0, t0
  j    4
ASM
"${CC}gcc" -nostdlib -nostartfiles -Ttext=0x0 -march=rv64imac_zicsr -mabi=lp64 -o "$t/p.elf" "$t/p.S"
"${CC}objcopy" -O binary "$t/p.elf" "$t/p.bin"
python3 - "$in" "$t/p.bin" "$out" "$tramp" <<'PY'
import struct, sys
src, pbin, dst, tramp = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
w = [int(x, 16) for x in open(src).read().split()]
p = open(pbin, 'rb').read()
pw = list(struct.unpack('<%dI' % (len(p) // 4), p))
w[0] = pw[0]
w += pw[tramp // 4:]
open(dst, 'w').write(''.join('%08x\n' % x for x in w))
PY
