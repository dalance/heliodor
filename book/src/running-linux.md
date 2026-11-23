# Running Linux

Heliodor boots unmodified mainline Linux through a small M-mode SBI firmware
(`test/linux/fw/`) to an SBI shutdown, and boots a Linux guest under a small
type-1 hypervisor. This chapter explains what a boot consists of and how to run
one.

## What a boot is

A boot test loads two images into the SoC testbench:

- A **firmware** hex image in the boot ROM at address 0. It programs the PMP and
  the CSRs that machine mode owns (see
  [Firmware requirements](soc-integration.md#firmware-requirements)), provides the SBI calls the kernel needs (timer, console, system reset and, for
  SMP, hart start) and jumps to the kernel.
- A **DRAM** hex image at `0x8000_0000`: the kernel `Image` with its built-in
  initramfs, and the device tree blob placed at a fixed address.

The userspace `/init` of the initramfs prints a message and powers the machine
off. The shutdown reaches the firmware as an SBI system-reset call, and the
firmware leaves the value `0xAA` in register `x3` of hart 0. A boot passes when
hart 0 reaches `x3 == 0xAA` and no invariant checker has fired.

## Boot images

The images the tests load are committed under `test/hex/`, so you can run the
boots without a Linux toolchain. They are:

| Kernel | Harts | Firmware image | DRAM image |
|---|---|---|---|
| 5.15 | 1 | `linux_boot_fw.hex` | `linux_dram_real.hex` |
| 5.15 | 2 | `linux_boot_fw_2hart.hex` | `linux_dram_real_2hart.hex` |
| 5.15 | 4 | `linux_boot_fw_4hart_mt.hex` | `linux_dram_real_4hart.hex` |
| 6.6 LTS | 1 | `linux_boot_fw_66.hex` | `linux_dram_66.hex` |
| 6.6 LTS | 2, 4 | `linux_boot_fw_66_smp.hex` | `linux_dram_66_2hart.hex`, `linux_dram_66_4hart.hex` |
| 7.1 | 1 | `linux_boot_fw_71.hex` | `linux_dram_71.hex` |
| 7.1 | 2, 4 | `linux_boot_fw_71.hex` | `linux_dram_71_2hart.hex`, `linux_dram_71_4hart.hex` |
| 7.1 with vector | 1 | `linux_boot_fw_71v.hex` | `linux_dram_71v.hex` |

The 4-hart 5.15 firmware waits for `mtime` instead of counting loop iterations
when it starts the secondary harts, so that the start-up does not depend on the
speed of the core.

The 6.6 and 7.1 device trees describe the extensions of the core, and those
kernels discover them from the device tree. The `71v` image is a 7.1 kernel
built with vector support; its `/init` runs a vector self-test and powers off
only if the result is correct.

## Build an image

`test/linux/build.sh` regenerates an image for one kernel variant with the pinned
Linux toolchain. You need your own checkout of the matching kernel source, which
the script expects in `test/linux/src/<tag>/` (git ignores it).

```bash
toolchain/fetch.sh linux
source toolchain/env.sh
git clone --depth 1 --branch v5.15 \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git test/linux/src/v5.15
test/linux/build.sh 515        # variants: 515 | 66 | 71 | 71v
```

The variants use kernel tags `v5.15`, `v6.6`, `v7.1` (for `71` and `71v`). To use
a checkout elsewhere, set `KERNEL_SRC=/path/to/linux`. The script builds the
initramfs, the kernel `Image`, the device tree, the firmware and the combined
DRAM image, and writes `test/hex/linux_boot_fw_<variant>.hex` and
`test/hex/linux_dram_<variant>.hex`.

The directory holds the sources of everything that is not the kernel:

| Path | Content |
|---|---|
| `test/linux/fw/` | Boot firmware |
| `test/linux/init/` | Userspace `/init` (`linux_init.c`, and `linux_init_vec.c` for the vector boot) |
| `test/linux/dts/` | Device trees per kernel version and hart count |
| `test/linux/configs/` | Kernel configuration fragments and snapshots |

Notes for building:

- The DRAM size must match the `reg` of the device tree memory node and the
  harness DRAM array (32 MiB in the supplied harnesses).
- Keep `CONFIG_IKCONFIG=y` so that the `.config` of an `Image` can be recovered.
- The script disables the getrandom vDSO in the kernel `Kconfig` because the
  vDSO link rejects a `memcpy` relocation that gcc generates. This is harmless:
  the syscall fallback is used.
- The address of `hart_lottery` changes with every kernel build; the script reads
  it from `System.map` and passes it to the firmware.

## Run a boot on the Veryl simulator

Boots are `#[ignore]` tests, so pass `--ignored`. Commands for the 2-wide core:

```bash
veryl test --ignored --test test_w2_linux_boot                # 5.15, 1 hart
veryl test --ignored --test test_w2_smp_linux_boot_2hart      # 5.15, 2 harts
veryl test --ignored --test test_w2_smp_linux_boot_4hart      # 5.15, 4 harts
veryl test --ignored --test test_w2_linux_boot_66             # 6.6, 1 hart
veryl test --ignored --test test_w2_smp_linux_boot_66_2hart   # 6.6, 2 harts
veryl test --ignored --test test_w2_linux_boot_71             # 7.1, 1 hart
veryl test --ignored --test test_w2_smp_linux_boot_71_2hart   # 7.1, 2 harts
veryl test --ignored --test test_w2_linux_boot_71v            # 7.1 with vector
```

Replace `w2` by `w4` for the 4-wide core, for example
`test_w4_smp_linux_boot_4hart`. The 4-hart boots of 6.6 and 7.1 are
`test_soc_66_smp_linux_boot_4hart` and `test_soc_71_smp_linux_boot_4hart` (the
`test_soc_*` tests run the default core, which is the 2-wide one). Cycle counts
of all of these are in [Performance](performance.md).

A boot takes from several minutes (one hart) to over an hour (four harts), and
the cycle counts are in the tens of millions. Progress lines show the cycle
count, retired instructions and the program counter; a boot that is stuck at the
same counters for a long time is not necessarily hung, because the probe prints
only every so many cycles. The run ends with a line `boot: x3=...aa cycles=<n> ...
chk=00...0 mismatch=0` from the harness, which has the exact cycle count, and then the
test's own line ending in `pass=1`. The test's own cycle counter advances in steps
of 10,000, so it is rounded.

Wall-clock time depends on the load of the machine. Run long boots in the
background, and do not raise a test's cycle limit without a reason.

## Run a boot on Verilator {#run-a-boot-on-verilator}

The same boots run on Verilator through the wrappers in `sim/verilator/`:

| Wrapper | Configuration |
|---|---|
| `tb_soc_linux_boot_w2.sv`, `tb_soc_linux_boot_w4.sv` | 5.15, 1 hart |
| `tb_soc_smp_linux_boot_2hart_w2.sv`, `..._w4.sv` | 5.15, 2 harts |
| `tb_soc_smp_linux_boot_4hart_w2.sv`, `..._w4.sv` | 5.15, 4 harts |
| `tb_soc_hvlinux_w2.sv`, `tb_soc_hvlinux_w4.sv` | Guest Linux under the hypervisor |
| `tb_litmus_4hart_w2.sv`, `tb_litmus_4hart_w4.sv` | Memory-model litmus tests, 4 harts |

```bash
veryl build
verilator --binary --top-module tb_soc_smp_linux_boot_2hart_w2 -f heliodor.f \
          sim/verilator/tb_soc_smp_linux_boot_2hart_w2.sv \
          +define+HELIODOR_CHK+HELIODOR_OBS \
          --timing -Wno-fatal -O3 -j 4 \
          --Mdir sim/verilator/build_n2_w2 -o tb_soc_smp_linux_boot_2hart_w2
sim/verilator/build_n2_w2/tb_soc_smp_linux_boot_2hart_w2
```

Pass `+define+HELIODOR_CHK+HELIODOR_OBS` as shown: without the defines the core has
no retire records and the run cannot detect the shutdown (see
[Getting started](getting-started.md#run-on-verilator)).

The run prints `W2 SMP(N=2) LINUX BOOT PASSED on Verilator (SBI shutdown, x3==0xAA)`
on success. The 4-hart top-level modules are large; if `-O3` makes Verilator fail,
build with `-O1`.

The wrappers take `-GAXI_SEL=<n>` and `-GAXI_SEED=<n>` to vary the timing of the
testbench's AXI4 memory model: 0 is fixed latency, 1 is slow, 2 adds
backpressure, 3 reorders responses between IDs. Boots must pass with every
setting; the cycle count changes.

## Guest Linux under a hypervisor {#guest-linux-under-a-hypervisor}

`test/hv/` holds a minimal bare-metal type-1 hypervisor that runs in
hypervisor-extended supervisor mode, sets up the second translation stage, and
boots a Linux guest in virtualized supervisor mode. It forwards the guest's SBI
console calls to the real UART and handles the remaining SBI calls itself. It is
the one test that runs the two-stage MMU under load.

| File | Content |
|---|---|
| `hvfw.S` | Minimal M-mode firmware (the boot ROM) |
| `hv_start.S`, `hv.c`, `hv.ld` | The hypervisor |
| `guest.dts` | Device tree of the guest: 28 MiB of RAM, one hart, console through SBI only |
| `mkhex.py`, `Makefile` | Assemble `hv_dram.hex` |

Build the DRAM image from a guest kernel `Image` and the compiled guest device
tree (the image is not committed because it is large). The guest kernel is the 7.1
`Image` that `test/linux/build.sh 71` builds, which has the initramfs with the
`/init` that powers the machine off; the build leaves it at
`test/linux/build/71/kbuild/arch/riscv/boot/Image`.

```bash
source toolchain/env.sh
dtc -I dts -O dtb -o test/hv/guest.dtb test/hv/guest.dts
make -C test/hv GUEST=$PWD/test/linux/build/71/kbuild/arch/riscv/boot/Image GUEST_DTB=$PWD/test/hv/guest.dtb
veryl test --ignored --test test_w2_hvlinux
```

The test passes when the guest reaches its `/init` and the SBI shutdown arrives at
the hypervisor (`x3 == 0xAA`).

`make -C test/hv` with no arguments embeds a small bare-metal guest instead of
Linux, which is useful to check the hypervisor itself. Guest physical address
`0x8000_0000` maps to host physical `0x8040_0000`; the hypervisor occupies the
first 4 MiB of DRAM.
