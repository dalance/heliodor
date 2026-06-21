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
veryl test --ignored --test test_soc_linux_boot_71v    # expect x3 == 0xAA
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

**The pinned `toolchain/linux` (riscv-collab 2026.x, binutils 2.43) has all
three.** So `build.sh` uses one `CROSS_COMPILE` with no `LD=` override and no
Kconfig edits. The only remaining flag is `-mno-relax` on the freestanding
`/init` — a genuine requirement (a `-nostartfiles` binary never inits `gp`, so
gp-relative relaxation of its static arrays would fault), not a toolchain
workaround.

> If a future toolchain/kernel pairing resurfaces the vDSO `dynamic relocations
> are not supported` error (gcc lowering struct copies to `memcpy` in the
> getrandom vDSO), the fallback is to gate `VDSO_GETRANDOM` off in
> `arch/riscv/Kconfig`. The full history of the old mixed-toolchain recipe +
> symptom→cause table is in git (`doc/linux_boot_hex_build.md` before this
> commit).

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
