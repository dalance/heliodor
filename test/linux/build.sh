#!/usr/bin/env bash
# Build a heliodor Linux boot image (firmware + kernel + DTB + /init) into the
# test/hex/*.hex files the boot tests load — using ONE pinned linux-gnu
# toolchain (no elf-CC/linux-LD mix, no Kconfig workarounds; see README).
#
#   toolchain/fetch.sh linux && source toolchain/env.sh
#   test/linux/build.sh <variant>            # variant: 515 | 66 | 71 | 71v
#   KERNEL_SRC=/path/to/linux test/linux/build.sh 71v   # use an existing tree
#
# Without KERNEL_SRC the kernel source is expected at test/linux/src/<variant>/
# (gitignored — fetch the matching kernel version there yourself; versions:
#  515→v5.15, 66→v6.6, 71→v7.1, 71v→v7.1 + CONFIG_RISCV_ISA_V).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
variant="${1:?usage: build.sh <515|66|71|71v>}"

CC="${RISCV_LINUX_PREFIX:-riscv64-unknown-linux-gnu-}"
command -v "${CC}gcc" >/dev/null || { echo "need ${CC}gcc on PATH — source toolchain/env.sh"; exit 1; }

# ---- per-variant parameters -------------------------------------------------
case "$variant" in
  515) ksrc=v5.15; dts=heliodor.dts;     init=linux_init.c;     imarch=rv64imac; fwdef="";                          dtb_addr=0x80AB9000 ;;
  66)  ksrc=v6.6;  dts=heliodor_66.dts;  init=linux_init.c;     imarch=rv64imac; fwdef="";                          dtb_addr=0x80300000 ;;
  71)  ksrc=v7.1;  dts=heliodor_71.dts;  init=linux_init.c;     imarch=rv64imac; fwdef="-DRVA23_MENVCFG -DRVA23_ADUE"; dtb_addr=0x80300000 ;;
  71v) ksrc=v7.1;  dts=heliodor_71v.dts; init=linux_init_vec.c; imarch=rv64gcv;  fwdef="-DRVA23_MENVCFG -DRVA23_ADUE"; dtb_addr=0x80300000 ;;
  *)   echo "unknown variant '$variant'"; exit 1 ;;
esac

KERNEL_SRC="${KERNEL_SRC:-$here/src/$ksrc}"
[ -d "$KERNEL_SRC" ] || { echo "kernel source not found at $KERNEL_SRC (set KERNEL_SRC=...)"; exit 1; }

bd="$here/build/$variant"; mkdir -p "$bd"
echo "== variant $variant  kernel=$KERNEL_SRC  dts=$dts  init=$init =="

# ---- 1. userspace /init + initramfs cpio ------------------------------------
# -mno-relax is REQUIRED for the -nostartfiles init: gp is uninitialised, so
# gp-relative relaxation of the static arrays would fault. (This is a genuine
# freestanding-binary flag, not a toolchain-version workaround.)
mkdir -p "$bd/initramfs/dev"
"${CC}gcc" -nostdlib -nostartfiles -Ttext=0x10000 -march="$imarch" -mabi=lp64d -O2 -mno-relax \
  -o "$bd/initramfs/init" "$here/init/$init"
( cd "$bd/initramfs" && find . | cpio -o -H newc 2>/dev/null ) > "$bd/initramfs.cpio"

# ---- 2. kernel Image (single toolchain, no LD override / Kconfig patches) ----
# Merge the variant config fragment, then build. binutils >= 2.43 has RVV `as`,
# `ld -shared` for the vDSO, and ld >= 2.38 so TOOLCHAIN_HAS_V auto-detects.
frag="$here/configs/heliodor_kernel.frag"
[ "$variant" = 71v ] && frag="$here/configs/heliodor_kernel.frag"   # adjust per-variant frag as needed
make -C "$KERNEL_SRC" ARCH=riscv CROSS_COMPILE="$CC" O="$bd/kbuild" defconfig
if [ -f "$frag" ]; then
  "$KERNEL_SRC/scripts/kconfig/merge_config.sh" -O "$bd/kbuild" "$bd/kbuild/.config" "$frag"
fi
# Point the embedded initramfs at our cpio.
"$KERNEL_SRC/scripts/config" --file "$bd/kbuild/.config" \
  --set-str INITRAMFS_SOURCE "$bd/initramfs.cpio"
make -C "$KERNEL_SRC" ARCH=riscv CROSS_COMPILE="$CC" O="$bd/kbuild" olddefconfig
make -C "$KERNEL_SRC" ARCH=riscv CROSS_COMPILE="$CC" O="$bd/kbuild" -j"$(nproc)" Image

image="$bd/kbuild/arch/riscv/boot/Image"
hart_lottery="$(awk '/ hart_lottery$/{print "0x"$1}' "$bd/kbuild/System.map" | head -1)"
echo "hart_lottery = $hart_lottery"

# ---- 3. DTB ------------------------------------------------------------------
dtc -I dts -O dtb -o "$bd/heliodor.dtb" "$here/dts/$dts"

# ---- 4. firmware hex ---------------------------------------------------------
"${CC}gcc" -nostdlib -nostartfiles -Ttext=0x0 -march=rv64imac -mabi=lp64 \
  -DDTB_ADDR=$dtb_addr -DHART_LOTTERY_PA=$hart_lottery $fwdef \
  -o "$bd/fw.elf" "$here/fw/linux_boot_fw.S"
"${CC}objcopy" -O binary "$bd/fw.elf" "$bd/fw.bin"
python3 "$repo/test/c/bin2hex.py" "$bd/fw.bin" "$repo/test/hex/linux_boot_fw_$variant.hex"

# ---- 5. combined kernel + DTB DRAM hex --------------------------------------
python3 - "$image" "$bd/heliodor.dtb" "$dtb_addr" "$repo/test/hex/linux_dram_$variant.hex" <<'PY'
import struct, sys
image, dtb, dtb_addr, out = sys.argv[1], sys.argv[2], int(sys.argv[3], 16), sys.argv[4]
img = open(image, "rb").read(); d = open(dtb, "rb").read()
off = dtb_addr - 0x80000000
buf = bytearray(off + len(d)); buf[:len(img)] = img; buf[off:off + len(d)] = d
assert struct.unpack_from(">I", buf, off)[0] == 0xd00dfeed, "DTB magic mismatch"
if len(buf) % 4:                       # pad up to a word boundary
    buf += b"\x00" * (4 - len(buf) % 4)
with open(out, "w") as f:
    for i in range(0, len(buf), 4):
        f.write("%08x\n" % struct.unpack_from("<I", buf, i)[0])
print("wrote", out, len(buf) // 4, "words")
PY
echo "== done: test/hex/linux_boot_fw_$variant.hex + linux_dram_$variant.hex =="
