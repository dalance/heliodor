# Linux Boot Hex File Generation

How to regenerate `test/hex/linux_boot_fw.hex` and `test/hex/linux_dram_real.hex`
for the Linux boot integration test (`test_linux_boot`).

## Prerequisites

| Item | Location |
|------|----------|
| Linux kernel source | `/tmp/claude-4004/linux/` (v5.15, shallow clone from torvalds/linux) |
| Cross compiler | `/storage/eda/tools/riscv/riscv64.2022.01/bin/riscv64-unknown-linux-gnu-*` |
| initramfs directory | `/tmp/claude-4004/initramfs/` (contains `/init` and `/dev/`) |
| init binary source | `test/c/linux_init.S` (sys_write "Hello" + sys_reboot POWER_OFF) |

## Key Addresses (from System.map, change with each kernel rebuild)

| Symbol | Address | Notes |
|--------|---------|-------|
| hart_lottery | `0x80A85380` | Firmware must zero this before jump to kernel |
| __bss_stop | `0x80AB743D` | End of BSS |
| DTB_ADDR | `0x80AB9000` | Page-aligned, after __bss_stop |
| mscratch | `0x81FFF000` | Last page of 32MB DRAM (firmware register save) |

## Configuration Summary

### DTS (`test/c/heliodor.dts`)
```
reg = <0x0 0x80000000 0x0 0x1FFF000>;    /* 32MB - 4KB */
timebase-frequency = <10000000>;           /* 10MHz */
bootargs = "earlycon=sbi no4lvl nokaslr";
```

### Firmware (`test/c/linux_boot_fw.S`)
```
DTB_ADDR        = 0x80AB9000
hart_lottery PA = 0x80A85380  (changes per kernel build!)
mscratch        = 0x81FFF000  (top of 32MB DRAM)
```

### Kernel config

Two snapshots are committed to the repo to prevent the "lost config"
problem we hit when the original 1-hart `.config` was overwritten by a
2-hart rebuild:

| File | Source | Use |
|------|--------|-----|
| `test/c/heliodor_kernel_2hart.config` | Extracted from `linux_dram_real_2hart.hex` via IKCONFIG (CONFIG_IKCONFIG=y embeds .config in the Image; extract via `gzip -d` of the `IKCFG_ST..IKCFG_ED` region) | Canonical 2-hart build config — copy to `linux/.config` and run `make Image` to reproduce the committed 2-hart hex |
| `test/c/heliodor_kernel.frag` | merge_config fragment — applies on top of `make ARCH=riscv defconfig` to produce a minimal 1-hart kernel | Use to derive the 1-hart minimal config when the original is unavailable |

Note: the original Apr 6 1-hart `.config` was lost (IKCONFIG was not
enabled). All future builds **must** keep `CONFIG_IKCONFIG=y` so future
configs are recoverable directly from the kernel binary.

Key overrides included in the fragment:
```
# CONFIG_SMP is not set
CONFIG_NR_CPUS=1
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_HZ=250
# CONFIG_VMAP_STACK is not set
# CONFIG_HVC_RISCV_SBI is not set
CONFIG_CMDLINE="earlycon=sbi nokaslr"
CONFIG_CMDLINE_FORCE=y
CONFIG_INITRAMFS_SOURCE="/tmp/claude-4004/initramfs_clean.cpio"
CONFIG_INITRAMFS_COMPRESSION_NONE=y
# Disabled to match Apr 6 minimal: NET, PCI, SCSI, USB, MMC, DRM, FB,
# SOUND, HID, INPUT, SERIO, I2C, HWMON, RTC, MTD, VT, BLOCK, VIRTIO,
# DEBUG_PLIST, etc. (see fragment for complete list)
```

To extract `.config` from a built kernel Image:
```bash
python3 -c "
import gzip
data = open('/path/to/Image', 'rb').read()
st = data.find(b'IKCFG_ST') + 8
ed = data.find(b'IKCFG_ED')
print(gzip.decompress(data[st:ed]).decode(), end='')
" > extracted.config
```

### Test harness (`tb/test_linux_boot.veryl`)
- DRAM: 32 MB (8388608 × 32-bit words, 23-bit index)
- Cycle limit: 400M (boot completes at ~31M cycles)

## Step 0: Build init binary and initramfs

```bash
CC=/storage/eda/tools/riscv/riscv64.2022.01/bin/riscv64-unknown-linux-gnu

# Build init (static ELF, sys_write + sys_reboot)
${CC}-gcc -nostdlib -nostartfiles -Ttext=0x10000 -march=rv64imac -mabi=lp64 \
  -o /tmp/claude-4004/initramfs/init test/c/linux_init.S

# Create cpio archive (without trailing cpio stderr)
cd /tmp/claude-4004/initramfs && find . | cpio -o -H newc 2>/dev/null \
  > /tmp/claude-4004/initramfs_clean.cpio
```

## Step 1: Build DTB

```bash
dtc -I dts -O dtb -o /tmp/claude-4004/heliodor.dtb test/c/heliodor.dts
```

## Step 2: Build Linux kernel

```bash
cd /tmp/claude-4004/linux
# Apply .config (copy from backup or configure manually)
make ARCH=riscv CROSS_COMPILE=${CC}- -j$(nproc) Image
```

After build, check if hart_lottery address changed:
```bash
grep 'hart_lottery' /tmp/claude-4004/linux/System.map
# If changed, update test/c/linux_boot_fw.S with new address
```

## Step 3: Build firmware hex

```bash
CC=/storage/eda/tools/riscv/riscv64.2022.01/bin/riscv64-unknown-linux-gnu

${CC}-gcc -nostdlib -nostartfiles -Ttext=0x00000000 -march=rv64imac -mabi=lp64 \
  -o /tmp/claude-4004/linux_boot_fw.elf test/c/linux_boot_fw.S

${CC}-objcopy -O binary /tmp/claude-4004/linux_boot_fw.elf /tmp/claude-4004/linux_boot_fw.bin

python3 -c "
import struct
data = open('/tmp/claude-4004/linux_boot_fw.bin','rb').read()
data = data + b'\x00' * ((4 - len(data) % 4) % 4)
words = [struct.unpack_from('<I', data, i)[0] for i in range(0, len(data), 4)]
with open('test/hex/linux_boot_fw.hex','w') as f:
    for w in words: f.write(f'{w:08x}\n')
print(f'Firmware: {len(words)} words')
"
```

## Step 4: Build combined kernel+DTB DRAM hex

```bash
python3 << 'PYEOF'
import struct
image = open("/tmp/claude-4004/linux/arch/riscv/boot/Image","rb").read()
dtb = open("/tmp/claude-4004/heliodor.dtb","rb").read()
dtb_offset = 0x80AB9000 - 0x80000000  # DTB_ADDR - DRAM_BASE
total = dtb_offset + len(dtb)
combined = bytearray(total)
combined[:len(image)] = image
combined[dtb_offset:dtb_offset+len(dtb)] = dtb
# Verify DTB magic
magic = struct.unpack_from(">I", combined, dtb_offset)[0]
assert magic == 0xd00dfeed, f"DTB magic mismatch: 0x{magic:08x}"
num_words = (len(combined)+3)//4
with open("test/hex/linux_dram_real.hex","w") as f:
    for i in range(num_words):
        off = i*4
        w = struct.unpack_from("<I", combined, off)[0] if off+4<=len(combined) else 0
        f.write(f"{w:08x}\n")
print(f"Written {num_words} words ({num_words*4} bytes)")
PYEOF
```

## Step 5: Run test

```bash
rm -f .build/lock
veryl test --test test_linux_boot
```

Expected output: `x3=00000000000000aa pass=1` (SBI SRST shutdown success).

## After kernel rebuild

hart_lottery address changes with each kernel build. Always check:
```bash
grep 'hart_lottery' /tmp/claude-4004/linux/System.map
```
Update the address in `test/c/linux_boot_fw.S` and rebuild firmware hex (Step 3).

## Important Notes

- `initramfs_clean.cpio` must NOT contain cpio stderr ("3 blocks\n").
  Always use `2>/dev/null` when creating with `cpio -o`.
- The kernel `.config` is NOT committed to the repo. Back it up separately.
- `linux_dram_real.hex` is ~11 MB and committed to `test/hex/`.
- DRAM size (32MB) must match DTS `reg` field and test harness array size.

## V-enabled kernel build (CONFIG_RISCV_ISA_V) — toolchain version pitfalls

Building a `CONFIG_RISCV_ISA_V=y` kernel (e.g. the `test_soc_linux_boot_71v`
gold-standard vector boot) needs THREE toolchain capabilities that, in this
environment, NO single toolchain provides — so the build mixes two toolchains
and patches two kernel Kconfig lines. This is the recurring trial-and-error; use
the recipe + symptom table below to skip straight to the answer. Tool *versions*
and *prefixes* are given (they matter); absolute install paths are environment-
specific and intentionally omitted — locate them with `which` / by `--version`.

### The conflict

Two relevant toolchain families:
- **bare-metal** `riscv64-unknown-elf-*` — newer (gcc 14.2 / **binutils 2.43**).
- **linux-gnu** `riscv64-unknown-linux-gnu-*` — older (gcc 11.1 / **binutils 2.37**).

| Capability needed | elf 2.43 | linux-gnu 2.37 |
|---|---|---|
| Assemble RVV 1.0 (`vsetvli`, `vle8ff.v`, …) — needs binutils ≥ 2.38 | ✅ | ❌ (`unrecognized opcode`) |
| Link the vDSO shared object (`ld -shared`) | ❌ `-shared not supported` (newlib elf target) | ✅ |
| Kconfig `TOOLCHAIN_HAS_V` gate `LD_VERSION >= 23800` (ld ≥ 2.38) | ✅ | ❌ |

The vector *instructions* are turned into bytes by `as` (so **CC** must be the
2.43 elf gcc); the *linker* only sees them as opcode bytes, so **LD** can be the
2.37 linux-gnu ld — and it is the only one here that can `-shared`-link the vDSO.

### Recipe

1. **Mixed toolchain**: build with `CROSS_COMPILE=<elf-prefix>-` (so cc/as/objcopy/
   ar/nm are the elf 2.43 tools) but override **`LD=<linux-gnu-ld>`** (the only
   `-shared`-capable linker). I.e. `make ARCH=riscv CROSS_COMPILE=riscv64-unknown-elf- LD=<…linux-gnu-ld> …`.

2. **`KCFLAGS=-mno-relax KAFLAGS=-mno-relax`**. as 2.43 emits `R_RISCV_ALIGN`
   relaxation relocs that ld 2.37 cannot relax; they survive into the vDSO and the
   `dynamic relocations are not supported` check deletes `vdso.so.dbg`. `-mno-relax`
   stops them being emitted. Safe: vmlinux already links with `--no-relax`.

3. **Disable the getrandom vDSO.** gcc 14 lowers struct copies in the getrandom
   vDSO glue to external `memcpy` calls → `R_RISCV_JUMP_SLOT memcpy` dynamic reloc
   → the same vDSO check fails. It is auto-`select`ed, so gate it off in
   `arch/riscv/Kconfig`: append `&& BROKEN` to
   `select VDSO_GETRANDOM if HAVE_GENERIC_VDSO && 64BIT`, then `make olddefconfig`.

4. **Relax the `TOOLCHAIN_HAS_V` LD-version gate.** In `arch/riscv/Kconfig`,
   `config TOOLCHAIN_HAS_V` carries `depends on LD_IS_LLD || LD_VERSION >= 23800`.
   With the 2.37 linux-gnu LD this is false, so `olddefconfig` silently DROPS
   `CONFIG_RISCV_ISA_V` (which `depends on TOOLCHAIN_HAS_V`) — the build then has NO
   vector support even though `.config` looked right earlier. Remove that
   `depends on` line, re-run `make olddefconfig` (with the same `LD=`), and confirm
   both `CONFIG_RISCV_ISA_V=y` in `.config` AND `#define CONFIG_RISCV_ISA_V 1` in
   `include/generated/autoconf.h`.

Then `make … CROSS_COMPILE LD KCFLAGS KAFLAGS Image`. For a *usable* userspace
vector path also set `CONFIG_RISCV_ISA_V_DEFAULT_ENABLE=y`, and advertise `v` in
the DT (both `riscv,isa` and `riscv,isa-extensions`).

### Symptom → cause

| Build / boot symptom | Cause / fix |
|---|---|
| `ld: -shared not supported` at the `VDSOLD` step | LD is a bare-metal `*-elf-ld`; override `LD=` with a `*-linux-gnu-ld` (step 1). |
| `vdso.so.dbg: dynamic relocations are not supported` | `R_RISCV_ALIGN` (as/ld relax mismatch → step 2) or `R_RISCV_JUMP_SLOT memcpy` (getrandom vDSO → step 3). Identify with `readelf -rW vdso.so.dbg`. |
| `__vdso_rt_sigreturn_offset undeclared` in `signal.c` (incremental build) | `include/generated/vdso-offsets.h` is empty because the vDSO failed to (re)build — fix the vDSO link first (steps 2–3), don't chase signal.c. |
| Kernel boots but `riscv: base ISA extensions acdfim` (no `v`) and userspace dies `unhandled signal 4` (SIGILL) at the first vector insn | `CONFIG_RISCV_ISA_V` got dropped (TOOLCHAIN_HAS_V failed the LD-version gate, step 4). Verify `autoconf.h` has `CONFIG_RISCV_ISA_V 1`. The DT `v` is parsed but `riscv_ext_vector_float_validate` rejects it whenever `!IS_ENABLED(CONFIG_RISCV_ISA_V)`. |

> The Kconfig edits (steps 3–4) are workarounds for THIS toolchain pairing, not
> upstream-correct changes — keep them local to the kernel build tree (they live
> outside the heliodor repo, under the gitignored kernel source).

### Userspace vector /init + test assets

`test/c/linux_init_vec.c` is the V-boot `/init`: it runs a userspace RVV self-test
(`vsetvli` + `vle32` + `vadd.vv` + `vmul.vx` + `vse32`, results verified) and only
issues `reboot(POWER_OFF)` if the vector results are correct — so the boot reaching
SBI shutdown (`x3 == 0xAA`) proves the VU works end-to-end under Linux (first-use
trap → lazy enable → context save/restore across syscalls). Build it freestanding
with the V march **and `-mno-relax`**:

```bash
riscv64-unknown-elf-gcc -nostdlib -nostartfiles -Ttext=0x10000 \
    -march=rv64gcv -mabi=lp64d -O2 -mno-relax -o <initramfs>/init test/c/linux_init_vec.c
```

`-mno-relax` is REQUIRED: without it the linker relaxes the static-array addresses
(`va`/`vb`/`vc`) to **gp-relative** (`addi a6, gp, …`), but a `-nostartfiles` binary
never initializes `gp`, so the `vse32` store lands at `gp(0) + offset` → store page
fault (SIGSEGV, `badaddr` near `0xffff…`). `-mno-relax` keeps PC-relative addressing.

Then rebuild the embedded cpio and re-link the kernel (the cpio is embedded via
`CONFIG_INITRAMFS_SOURCE`, so the init change needs a kernel re-link, not a full
rebuild), and assemble the hex like `mkhex71.py` but with the V DTB:

- DT: `test/c/heliodor_71v.dts` (adds `v` to `riscv,isa` + `riscv,isa-extensions`).
- Firmware: `test/c/linux_boot_fw.S` with `-DDTB_ADDR=0x80300000 -DHART_LOTTERY_PA=<hart_lottery PA from System.map> -DRVA23_MENVCFG -DRVA23_ADUE` → `test/hex/linux_boot_fw_71v.hex`.
- DRAM: V-kernel `Image` @ 0 + `heliodor_71v.dtb` @ `0x300000` → `test/hex/linux_dram_71v.hex`.
- Test: `veryl test --ignored --test test_soc_linux_boot_71v` (expect `x3 == 0xAA`).

### A heliodor bug this boot uncovered: sstatus.VS

The first V-enabled boot SIGILL'd / panicked because heliodor's `SSTATUS_MASK`
(`src/core/csr.veryl`) omitted the **VS field (bits 10:9)**, so Linux's
`riscv_v_enable()` — a `csr_set(sstatus, SR_VS)` from S-mode — was silently dropped
and vector could never be enabled in S-mode. The M-mode directed tests set
`mstatus.VS` (a different write mask) and so never exercised this path. Fix: add
`0x600` to `SSTATUS_MASK`. Inert at V=0 (VS stays 0 with no vector op).
