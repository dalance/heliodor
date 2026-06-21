# Heliodor 1-hart kernel config fragment for Linux 6.6 (RVA23 verification).
# Apply on top of: make ARCH=riscv tinyconfig
#   merge_config.sh + make olddefconfig
#
# Extends heliodor_kernel.frag (5.15 1-hart) with the RVA23 ISA options that
# Linux 6.6 supports and that heliodor implements, so kernel code actually
# exercises them during boot. Features NOT in 6.6 (Svadu kernel support,
# Svinval, Zawrs) are deferred to the 7.1 stage.

# === Architecture: 64-bit RISC-V S-mode kernel (tinyconfig defaults to M-mode) ===
# CONFIG_RISCV_M_MODE is not set
CONFIG_64BIT=y
CONFIG_MMU=y
CONFIG_RISCV_ISA_C=y

# === RISC-V SBI / timer / intc ===
CONFIG_RISCV_SBI=y
CONFIG_RISCV_SBI_V01=y
CONFIG_RISCV_TIMER=y
CONFIG_RISCV_INTC=y
CONFIG_SOC_VIRT=y
CONFIG_RISCV_ERRATA_ALTERNATIVE=y

# === RVA23 ISA extensions supported by Linux 6.6 + implemented by heliodor ===
# Zbb: alternative-patched string/bitops (clz/ctz/cpop/orc.b/rev8 ...)
CONFIG_RISCV_ISA_ZBB=y
# Zicboz: clear_page() via cbo.zero
CONFIG_RISCV_ISA_ZICBOZ=y
# Zicbom: cache-block management (cbo.clean/flush/inval — no-op on coherent core)
CONFIG_RISCV_ISA_ZICBOM=y
# Svpbmt: ioremap sets PBMT=IO on device mappings
CONFIG_RISCV_ISA_SVPBMT=y
# Svnapot: 64 KB NAPOT huge-page mappings
CONFIG_RISCV_ISA_SVNAPOT=y
# Vector: heliodor has no V unit — keep OFF so the kernel never issues vector ops
# CONFIG_RISCV_ISA_V is not set
# (Sstc has no Kconfig; the riscv timer driver auto-uses stimecmp when the DTS
#  advertises "sstc" and the firmware sets menvcfg.STCE.)

# === SMP=n (1-hart first boot; SMP/Zawrs comes later) ===
# CONFIG_SMP is not set
CONFIG_NR_CPUS=1

# === Recoverable config (always keep IKCONFIG so future builds extract it) ===
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
