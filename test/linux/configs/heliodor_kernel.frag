# Heliodor 1-hart kernel config fragment based on TINYCONFIG
# Apply: make tinyconfig + merge_config + olddefconfig
#
# Based on commit 8643d85's note: "Real Linux kernel build tested
# (v6.8, tinyconfig + rv64imac)". Original Apr 6 #26 kernel was likely
# built this same way (tinyconfig + minimal additions for S-mode boot
# + initramfs userspace).

# === Architecture: 64-bit RISC-V S-mode kernel (tinyconfig defaults to M-mode) ===
# CONFIG_RISCV_M_MODE is not set
CONFIG_64BIT=y
CONFIG_MMU=y

# === RISC-V SBI ===
CONFIG_RISCV_SBI=y
CONFIG_RISCV_SBI_V01=y
CONFIG_RISCV_TIMER=y
CONFIG_RISCV_INTC=y
CONFIG_SOC_VIRT=y
CONFIG_RISCV_ERRATA_ALTERNATIVE=y

# === SMP=n (1-hart only; OLD baseline matches without smp prints) ===
# CONFIG_SMP is not set
CONFIG_NR_CPUS=1

# === Future-proofing ===
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y

# === Heliodor-specific ===
CONFIG_HZ_250=y
CONFIG_HZ=250
# CONFIG_VMAP_STACK is not set
# CONFIG_HVC_RISCV_SBI is not set
CONFIG_CMDLINE="earlycon=sbi nokaslr"
CONFIG_CMDLINE_FORCE=y
CONFIG_INITRAMFS_SOURCE="/tmp/claude-4004/initramfs_clean.cpio"
CONFIG_INITRAMFS_COMPRESSION_NONE=y
CONFIG_BLK_DEV_INITRD=y

# === Filesystems for initramfs (DEVTMPFS not in baseline) ===
# CONFIG_DEVTMPFS is not set
CONFIG_BINFMT_ELF=y

# === printk + SBI earlycon (CONFIG_SERIAL_EARLYCON_RISCV_SBI) ===
CONFIG_PRINTK=y
CONFIG_TTY=y
# CONFIG_VT is not set
# CONFIG_VT_CONSOLE is not set
# CONFIG_DUMMY_CONSOLE is not set
# CONFIG_HW_CONSOLE is not set
CONFIG_SERIAL_CORE=y
CONFIG_SERIAL_EARLYCON=y
CONFIG_SERIAL_EARLYCON_RISCV_SBI=y
CONFIG_RISCV_SBI_V01=y

# === Memory ===
CONFIG_SLUB=y
# CONFIG_SLAB is not set

# === EFI (旧 kernel had EFI strings) ===
CONFIG_EFI=y
CONFIG_EFI_STUB=y
