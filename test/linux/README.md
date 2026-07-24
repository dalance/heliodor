# `test/linux/` — Linux boot image build

Regenerates the `test/hex/linux_*.hex` images the Linux boot tests load
(`test_soc_linux_boot`, `_66`, `_71`, `_71v`, and the SMP variants). The boot
`.hex` are committed (they are test inputs); this directory holds the **sources**
and a reproducible build that uses one pinned toolchain.

```
fw/        linux_boot_fw.S/.ld   firmware (zeroes hart_lottery, sets up CSRs, jumps to kernel)
init/      linux_init.c          userspace /init: sys_write + reboot(POWER_OFF)
           linux_init_vec.c      V-boot /init: runs an RVV self-test, reboots only if correct
dts/       heliodor*.dts         device trees (per kernel version / hart count / V)
configs/   heliodor_kernel*.{frag,config}   kernel config fragments / snapshots
build.sh   one-toolchain build of a variant
```

## Quick start

```bash
toolchain/fetch.sh linux && source toolchain/env.sh   # pinned linux-gnu gcc (binutils 2.43)
# put the matching kernel source at test/linux/src/<ver>/ (gitignored), then:
test/linux/build.sh 71v        # variant: 515 | 66 | 71 | 71v
veryl test --ignored --test test_soc_71v_linux_boot    # expect x3 == 0xAA
```

`build.sh` builds /init + initramfs, the kernel `Image`, the DTB, the firmware
hex and the combined kernel+DTB DRAM hex into `test/hex/`.

## Stable single-toolchain (the ld-version fix)

A `CONFIG_RISCV_ISA_V=y` kernel needs three things at once: RVV `as`,
`ld -shared` (vDSO), and `ld` ≥ 2.38 (Kconfig `TOOLCHAIN_HAS_V`). The old
environment only had an **elf** gcc (binutils 2.43, no `-shared`) and an **old
linux-gnu** (binutils 2.37, no RVV `as`, fails the LD gate), which forced an
elf-CC + linux-LD **mix** plus two kernel Kconfig patches
(`VDSO_GETRANDOM`/`-mno-relax`, and dropping the `TOOLCHAIN_HAS_V` LD-version
`depends on`).

**The pinned `toolchain/linux` (riscv-collab 2026.06.06, GCC 16 / binutils
2.46) has all three.** So `build.sh` uses one `CROSS_COMPILE` with **no `LD=`
override and no `TOOLCHAIN_HAS_V` LD-version patch** — `ld` 2.46 ≥ 23800, so
`CONFIG_RISCV_ISA_V=y` survives `olddefconfig`. (Validated: a clean v7.1 tree +
the pinned toolchain keeps `CONFIG_TOOLCHAIN_HAS_V=y` with the Kconfig
unpatched, and the built V kernel boots on heliodor to `x3 == 0xAA`.)

**One workaround remains, and it is NOT an ld issue:** `build.sh` gates
`VDSO_GETRANDOM` off in `arch/riscv/Kconfig`. gcc lowers a struct copy in the
getrandom vDSO (`getrandom.o`) to a `memcpy` call → an `R_RISCV_JUMP_SLOT memcpy`
dynamic reloc, which the vDSO link rejects (`dynamic relocations are not
supported`). `-mno-relax` does **not** fix this (it is a gcc-codegen issue, not
the old as/ld relax mismatch). Disabling the getrandom vDSO is harmless (the
syscall fallback is used). `-mno-relax` is still needed on the freestanding
`/init` (a `-nostartfiles` binary never inits `gp`).

> Net vs. the old setup: the elf/linux **mix** and the **TOOLCHAIN_HAS_V
> LD-version patch** are gone (the ld-version problem is solved); only the
> getrandom-vDSO gate (a gcc-codegen workaround) survives. The full history of
> the old mixed-toolchain recipe + symptom→cause table is in git
> (`doc/linux_boot_hex_build.md` before this commit).

## Key facts

- **DRAM**: firmware @ `0x80000000`; DTB placed at `dtb_addr` (0x80AB9000 for
  v5.15, 0x80300000 for 6.6/7.1/7.1v). DRAM size must match the DTS `reg` and the
  harness array.
- **hart_lottery** PA changes every kernel build — `build.sh` reads it from
  `System.map` and passes `-DHART_LOTTERY_PA=` to the firmware (no manual edit).
- **IKCONFIG**: keep `CONFIG_IKCONFIG=y` so a built `Image`'s `.config` is
  recoverable (`IKCFG_ST..IKCFG_ED`, gzip) — an earlier 1-hart config was lost
  because it wasn't enabled.
- **V boot proves the VU end-to-end**: `linux_init_vec.c` reboots only if its
  userspace RVV self-test is correct, so `x3 == 0xAA` means first-use trap → lazy
  enable → context save/restore across syscalls all work. This boot uncovered the
  `sstatus.VS` mask bug (fixed in `src/core/csr.veryl`).
