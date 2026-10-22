#!/usr/bin/env bash
# Derive a new-core firmware image from a prebuilt one by replacing the
# instruction-count busy loop after SBI HSM HART_START (hart >= 1) with a wait
# on CLINT mtime. The loop is fixed at 16 bytes (SITE); the new code lives in a
# trampoline appended after the image (TRAMP) so no other address moves.
#
#   test/linux/fw/patch_hsm_mtime_wait.sh in.hex out.hex [site=0x404] [ticks_hi20=0x19]
#
# Delay = ticks_hi20 << 12 mtime ticks (default 102400, about 1M cycles at
# MTIME_DIV=10, the cycle budget the old loop gave the old core).
set -euo pipefail
in="${1:?in.hex}"; out="${2:?out.hex}"; site="${3:-0x404}"; hi="${4:-0x19}"
CC="${RISCV_LINUX_PREFIX:-riscv64-unknown-linux-gnu-}"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
words=$(wc -w < "$in"); tramp=$(( words * 4 )); ret=$(( site + 16 ))
cat > "$t/p.S" <<ASM
.option norvc
.section .text
.org $site
  beqz t3, $ret
  j $tramp
  nop
  nop
.org $tramp
  lui  t5, 0x200c
  ld   t6, -8(t5)
  lui  t4, $hi
  add  t6, t6, t4
1:
  ld   t4, -8(t5)
  bltu t4, t6, 1b
  j    $ret
ASM
"${CC}gcc" -nostdlib -nostartfiles -Ttext=0x0 -march=rv64imac_zicsr -mabi=lp64 -o "$t/p.elf" "$t/p.S"
"${CC}objcopy" -O binary "$t/p.elf" "$t/p.bin"
python3 - "$in" "$t/p.bin" "$out" "$site" "$tramp" <<'PY'
import struct, sys
src, pbin, dst, site, tramp = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4], 0), int(sys.argv[5])
w = [int(x, 16) for x in open(src).read().split()]
p = open(pbin, 'rb').read()
pw = list(struct.unpack('<%dI' % (len(p) // 4), p))
for i in range(4): w[site // 4 + i] = pw[site // 4 + i]
w += pw[tramp // 4:]
open(dst, 'w').write(''.join('%08x\n' % x for x in w))
PY
