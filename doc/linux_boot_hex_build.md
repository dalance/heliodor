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

### Kernel config (`.config`, NOT committed)
```
CONFIG_INITRAMFS_SOURCE="/tmp/claude-4004/initramfs_clean.cpio"
CONFIG_INITRAMFS_COMPRESSION_NONE=y
CONFIG_HVC_RISCV_SBI=n
CONFIG_VMAP_STACK=n
CONFIG_CMDLINE="earlycon=sbi nokaslr"
CONFIG_CMDLINE_FORCE=y
CONFIG_SLUB=y
CONFIG_HZ=250
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
