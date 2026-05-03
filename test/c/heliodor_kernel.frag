# Heliodor 1-hart kernel config fragment (matches Apr 6 build #26 behavior)
# Applied on top of `make ARCH=riscv defconfig`.
#
# Goal: same console output and ~26M cycle boot as the committed Apr 6 hex.
# Old kernel had EFI=y but USB/SCSI/NET/MMC/DRM/VT all OFF.

# === SMP: 1-hart only ===
# CONFIG_SMP is not set
CONFIG_NR_CPUS=1

# === Future-proofing: always embed config in kernel image ===
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y

# === Heliodor-specific essentials ===
CONFIG_HZ_250=y
CONFIG_HZ=250
# CONFIG_VMAP_STACK is not set
# CONFIG_HVC_RISCV_SBI is not set
CONFIG_CMDLINE="earlycon=sbi nokaslr"
CONFIG_CMDLINE_FORCE=y
CONFIG_INITRAMFS_SOURCE="/tmp/claude-4004/initramfs_clean.cpio"
CONFIG_INITRAMFS_COMPRESSION_NONE=y

# === Disable heavy non-essential subsystems (old kernel didn't have these) ===
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
# CONFIG_VT is not set
# CONFIG_VT_CONSOLE is not set
# CONFIG_DUMMY_CONSOLE is not set
# CONFIG_HW_CONSOLE is not set
# CONFIG_SERIAL_8250 is not set
# CONFIG_SERIAL_OF_PLATFORM is not set

# Block layer and virtio (defconfig pulls in VIRTIO_BLK/SCSI)
# CONFIG_BLOCK is not set
# CONFIG_VIRTIO_MENU is not set
# CONFIG_VIRTIO is not set

# Boot-time self-tests / debug — enabled by defconfig but slow under sim
# CONFIG_DEBUG_PLIST is not set
# CONFIG_DEBUG_LIST is not set
# CONFIG_DEBUG_NOTIFIERS is not set
# CONFIG_DEBUG_VM_PGTABLE is not set
# CONFIG_DEBUG_PAGEALLOC is not set
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_DEBUG_INFO is not set
# CONFIG_DEBUG_FS is not set
# CONFIG_DEBUG_MISC is not set
# CONFIG_RCU_EQS_DEBUG is not set
# CONFIG_STACKTRACE is not set
# CONFIG_LOCKUP_DETECTOR is not set
# CONFIG_SOFTLOCKUP_DETECTOR is not set
# CONFIG_DETECT_HUNG_TASK is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_DEBUG_PREEMPT is not set
# CONFIG_RCU_TRACE is not set
# CONFIG_FTRACE is not set
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_TRACING is not set
# CONFIG_KPROBES is not set
