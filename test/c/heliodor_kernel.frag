# Heliodor 1-hart kernel config fragment (最小 override)
# Applied on top of `make ARCH=riscv defconfig`.
#
# 戦略: defconfig drivers を維持。最小限の override のみ:
# - SMP=n (1-hart only)
# - IKCONFIG=y (将来の config 復元)
# - VT=n (VT console steal を防いで earlycon 維持)
# - INITRAMFS source + cmdline force

# === SMP: keep =y (SMP=n triggers BUG: tty_register_driver in atomic context) ===
CONFIG_SMP=y
CONFIG_NR_CPUS=2

# === Future-proofing: always embed config in kernel image ===
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y

# === VT console disable — prevents bootconsole [sbi0] from being stolen ===
# Without this, defconfig enables VT/dummy console which becomes the primary
# console after init, and kernel printk after early boot stops appearing on
# our SBI earlycon UART.
# CONFIG_VT is not set
# CONFIG_VT_CONSOLE is not set
# CONFIG_DUMMY_CONSOLE is not set
# CONFIG_HW_CONSOLE is not set

# === Heliodor-specific essentials ===
CONFIG_HZ_250=y
CONFIG_HZ=250
# CONFIG_VMAP_STACK is not set
# CONFIG_HVC_RISCV_SBI is not set
CONFIG_CMDLINE="earlycon=sbi nokaslr"
CONFIG_CMDLINE_FORCE=y
CONFIG_INITRAMFS_SOURCE="/tmp/claude-4004/initramfs_clean.cpio"
CONFIG_INITRAMFS_COMPRESSION_NONE=y

# === Driver subsystems to disable (旧 kernel もこれら全部 OFF だった) ===
# CONFIG_NET is not set
# CONFIG_PCI is not set
# CONFIG_SCSI is not set
# CONFIG_USB_SUPPORT is not set
# CONFIG_MMC is not set
# CONFIG_DRM is not set
# CONFIG_FB is not set
# CONFIG_SOUND is not set
# CONFIG_HID is not set
# CONFIG_INPUT is not set
# CONFIG_SERIO is not set
# CONFIG_I2C is not set
# CONFIG_HWMON is not set
# CONFIG_RTC_CLASS is not set
# CONFIG_MTD is not set
# CONFIG_SERIAL_8250 is not set
# CONFIG_SERIAL_OF_PLATFORM is not set
# CONFIG_BLK_DEV is not set
# CONFIG_BLK_DEV_LOOP is not set
# CONFIG_BLK_DEV_SD is not set
# CONFIG_BLK_DEV_SR is not set
# CONFIG_BLK_DEV_BSG is not set
# CONFIG_VIRTIO_MENU is not set
# CONFIG_VIRTIO is not set
# CONFIG_VIRTIO_BLK is not set
# CONFIG_VIRTIO_PCI is not set
# CONFIG_SCSI_VIRTIO is not set
# CONFIG_NLS is not set
# CONFIG_BPF_SYSCALL is not set
# CONFIG_BPF is not set
# CONFIG_PROFILING is not set
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_STACK_TRACER is not set
# CONFIG_FTRACE is not set
# CONFIG_TRACING is not set
# CONFIG_KPROBES is not set
# CONFIG_AUDIT is not set
# CONFIG_KEYS is not set

# === ATA selects SCSI; SOC drivers pull in unrelated init ===
# CONFIG_ATA is not set
# CONFIG_SATA_AHCI_PLATFORM is not set
# CONFIG_SOC_MICROCHIP_POLARFIRE is not set
# CONFIG_SOC_SIFIVE is not set
# CONFIG_SOC_VIRT is not set
# CONFIG_HW_RANDOM_VIRTIO is not set
# CONFIG_RPMSG is not set
# CONFIG_RPMSG_VIRTIO is not set
# CONFIG_CRYPTO_DEV_VIRTIO is not set
# CONFIG_CRYPTO_HW is not set
# CONFIG_MODULES is not set
# CONFIG_CGROUPS is not set
# CONFIG_NAMESPACES is not set
# CONFIG_NO_HZ_IDLE is not set
# CONFIG_HIGH_RES_TIMERS is not set
# CONFIG_PAGE_REPORTING is not set
# CONFIG_DEVTMPFS_MOUNT is not set
# CONFIG_CHECKPOINT_RESTORE is not set
# CONFIG_USER_NS is not set
# CONFIG_HOTPLUG_CPU is not set
# CONFIG_CFS_BANDWIDTH is not set
# CONFIG_CGROUP_SCHED is not set
# CONFIG_SYSVIPC is not set
# CONFIG_FS_POSIX_ACL is not set
# CONFIG_NLS_CODEPAGE_437 is not set
# CONFIG_GOLDFISH is not set
# CONFIG_FAT_FS is not set
# CONFIG_VFAT_FS is not set
# CONFIG_MSDOS_FS is not set
# CONFIG_OVERLAY_FS is not set
# CONFIG_NFS_FS is not set

# === RCU: TINY_RCU instead of TREE_RCU ===
# CONFIG_TREE_RCU is not set
CONFIG_TINY_RCU=y
# CONFIG_RCU_NOCB_CPU is not set

# === pid_max smaller (BASE_FULL=n) ===
# CONFIG_BASE_FULL is not set

# === io scheduler disable (kernel runs them but we have no block devs) ===
# CONFIG_MQ_IOSCHED_DEADLINE is not set
# CONFIG_MQ_IOSCHED_KYBER is not set
# CONFIG_BFQ_GROUP_IOSCHED is not set
# CONFIG_IOSCHED_BFQ is not set

# === Misc init noise ===
# CONFIG_PRINTK_INDEX is not set
# CONFIG_NUMA_BALANCING is not set
# CONFIG_TRANSPARENT_HUGEPAGE is not set

# TTY KEPT enabled — disabling broke kernel printk routing entirely

# === Debug self-tests run at boot — heavy under sim ===
# CONFIG_DEBUG_PLIST is not set
# CONFIG_DEBUG_LIST is not set
# CONFIG_DEBUG_VM_PGTABLE is not set
# CONFIG_DEBUG_PAGEALLOC is not set
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_DEBUG_INFO is not set
# CONFIG_DEBUG_MISC is not set
# CONFIG_DEBUG_SPINLOCK is not set
# CONFIG_DEBUG_MUTEXES is not set
# CONFIG_DEBUG_RWSEMS is not set
# CONFIG_DEBUG_LOCK_ALLOC is not set
# CONFIG_LOCKUP_DETECTOR is not set
# CONFIG_SOFTLOCKUP_DETECTOR is not set
# CONFIG_DETECT_HUNG_TASK is not set
# CONFIG_RCU_EQS_DEBUG is not set
# CONFIG_PROVE_RCU is not set
# CONFIG_PRINTK_TIME is not set
