# Heliodor SMP kernel config fragment for Linux 6.6 (RVA23 verification).
# Apply on top of: make ARCH=riscv tinyconfig
#   merge_config.sh + scripts/config --disable WERROR + make olddefconfig
#
# Same as heliodor_kernel_66.frag but SMP (NR_CPUS=8 covers the N=2/N=4 boots;
# the actual hart count comes from the device tree). One SMP kernel Image
# serves every hart count; only the DTS / firmware / DRAM hex differ.

# === Architecture: 64-bit RISC-V S-mode kernel ===
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

# === RVA23 ISA extensions (6.6-supported, heliodor-implemented) ===
CONFIG_RISCV_ISA_ZBB=y
CONFIG_RISCV_ISA_ZICBOZ=y
CONFIG_RISCV_ISA_ZICBOM=y
CONFIG_RISCV_ISA_SVPBMT=y
CONFIG_RISCV_ISA_SVNAPOT=y
# CONFIG_RISCV_ISA_V is not set

# === SMP (hart count from DTS; NR_CPUS is the upper bound) ===
CONFIG_SMP=y
CONFIG_NR_CPUS=8

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
