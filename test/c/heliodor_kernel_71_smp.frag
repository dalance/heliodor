# Heliodor SMP kernel config fragment for Linux 7.1 (RVA23 verification).
# Apply on top of: make ARCH=riscv tinyconfig
#   merge_config.sh + scripts/config --disable WERROR + make olddefconfig
#
# Extends the 6.6 SMP fragment with the RVA23 extensions that only Linux 7.1
# exercises: Svadu (hardware A/D update, no Kconfig — auto-detected and used
# via riscv_has_extension_unlikely(SVADU) in pgtable.h), Svinval (no Kconfig —
# the non-KVM TLB range flush uses sinval.vma via has_svinval() in tlbflush.c)
# and Zawrs (CONFIG_RISCV_ISA_ZAWRS — wrs.{nto,sto} in busy-wait loops). One
# SMP kernel Image serves every hart count; only the DTS / firmware / DRAM hex
# differ. The kernel discovers each extension from the device tree's
# riscv,isa-extensions list, so the firmware must also set menvcfg.ADUE for the
# kernel to actually issue hardware A/D updates (Svadu).

# === Architecture: 64-bit RISC-V S-mode kernel ===
# CONFIG_RISCV_M_MODE is not set
CONFIG_64BIT=y
CONFIG_MMU=y
CONFIG_RISCV_ISA_C=y
# FPU: left off (tinyconfig default), matching the 5.15 and 6.6 boots. The kernel
# itself is soft-float and the raw-syscall init uses no FP, so the boot does not
# need it. NB: enabling CONFIG_FPU=y wedges the N>=2 boot in __schedule's FP
# context switch (__fstate_save/__fstate_restore) — a heliodor FP-SMP-context
# -switch issue first exposed here (5.15/6.6 were both FP-off, so this path had
# never run under SMP Linux). heliodor's FPU itself passes the rv64uf/ud arch
# suite; the directed FP tests just don't exercise save/restore across a context
# switch. Deferred as a separate follow-up.
# CONFIG_FPU is not set

# === RISC-V SBI / timer / intc ===
CONFIG_RISCV_SBI=y
CONFIG_RISCV_SBI_V01=y
CONFIG_RISCV_TIMER=y
CONFIG_RISCV_INTC=y
CONFIG_SOC_VIRT=y
CONFIG_RISCV_ERRATA_ALTERNATIVE=y

# === RVA23 ISA extensions (6.6-supported, heliodor-implemented) ===
CONFIG_RISCV_ISA_ZBB=y
CONFIG_RISCV_ISA_ZICBOZ=y
CONFIG_RISCV_ISA_ZICBOM=y
CONFIG_RISCV_ISA_SVPBMT=y
CONFIG_RISCV_ISA_SVNAPOT=y
# === RVA23 extensions new to the 7.1 boot ===
# Zawrs: wrs.nto/wrs.sto in smp_cond_load / spin loops (multi-hart).
CONFIG_RISCV_ISA_ZAWRS=y
# Svadu (no Kconfig): hardware A/D update; needs menvcfg.ADUE from firmware.
# Svinval (no Kconfig): sinval.vma in the non-KVM TLB range flush path.
# Vector: heliodor has no V unit — keep OFF.
# CONFIG_RISCV_ISA_V is not set

# === SMP (hart count from DTS; NR_CPUS is the upper bound) ===
CONFIG_SMP=y
CONFIG_NR_CPUS=8

# === Unaligned access: assume fast, skip the boot-time speed probe ===
# heliodor handles misaligned scalar accesses in hardware (Zicclsm; the 6.6/7.1
# probe measured "8.00x byte access speed (fast)"). RISCV_PROBE_UNALIGNED_ACCESS
# (the default) spends ~1.6M cycles/CPU running an 8ms x2 guest-time copy probe
# at boot; assuming EFFICIENT skips it and selects DCACHE_WORD_ACCESS, which
# routes kernel string/word ops through unaligned word loads — exercising the
# hardware misaligned path in real kernel code instead. NONPORTABLE gates it.
CONFIG_NONPORTABLE=y
CONFIG_RISCV_EFFICIENT_UNALIGNED_ACCESS=y
# CONFIG_RISCV_PROBE_UNALIGNED_ACCESS is not set

# === Recoverable config ===
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y

# === Heliodor-specific ===
CONFIG_HZ_250=y
CONFIG_HZ=250
# CONFIG_VMAP_STACK is not set
# CONFIG_HVC_RISCV_SBI is not set
CONFIG_CMDLINE="earlycon=sbi no4lvl nokaslr"
CONFIG_CMDLINE_FORCE=y
CONFIG_INITRAMFS_SOURCE="/tmp/claude-4004/initramfs_clean.cpio"
CONFIG_INITRAMFS_COMPRESSION_NONE=y
CONFIG_BLK_DEV_INITRD=y

# === Filesystems for initramfs ===
# CONFIG_DEVTMPFS is not set
CONFIG_BINFMT_ELF=y

# === printk + SBI earlycon ===
CONFIG_PRINTK=y
CONFIG_TTY=y
# CONFIG_VT is not set
# CONFIG_VT_CONSOLE is not set
# CONFIG_DUMMY_CONSOLE is not set
# CONFIG_HW_CONSOLE is not set
CONFIG_SERIAL_CORE=y
CONFIG_SERIAL_EARLYCON=y
CONFIG_SERIAL_EARLYCON_RISCV_SBI=y

# === Memory ===
CONFIG_SLUB=y
# CONFIG_SLAB is not set

# === EFI ===
CONFIG_EFI=y
CONFIG_EFI_STUB=y
