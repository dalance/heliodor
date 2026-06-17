# Phase 11-H5.2b: bare-metal type-1 hypervisor + guest boot image.
#
# Produces:
#   hvfw.hex     - minimal M-mode firmware (SoC firmware ROM)
#   hv_dram.hex  - HS-mode hypervisor (+ guest, added later) flat DRAM image
#
# GUEST is the guest payload to embed at host offset 0x600000 (guest-physical
# 0x80200000). Override with `make GUEST=/path/to/Image GUEST_DTB=/path/to/dtb`.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

FWFLAGS = -march=rv64imac_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
HVFLAGS = -march=rv64imac_h_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding \
          -O2 -fno-pic -mcmodel=medany -Wall
BIN2HEX = python3 ../c/bin2hex.py
MKHEX   = python3 mkhex.py

GUEST     ?= guest_bare.bin
GUEST_DTB ?=

all: hvfw.hex hv_dram.hex

# ---- firmware ----
hvfw.elf: hvfw.S hvfw.ld
	$(CC) $(FWFLAGS) -T hvfw.ld -o $@ hvfw.S
hvfw.hex: hvfw.elf
	$(OBJCOPY) -O binary $< hvfw.bin
	$(BIN2HEX) hvfw.bin $@

# ---- hypervisor ----
hv.elf: hv_start.S hv.c hv.ld
	$(CC) $(HVFLAGS) -T hv.ld -o $@ hv_start.S hv.c
hv.bin: hv.elf
	$(OBJCOPY) -O binary $< hv.bin

# ---- bare-metal guest (infra validation) ----
guest_bare.elf: guest_bare.S guest_bare.ld
	$(CC) $(FWFLAGS) -march=rv64imac_zicsr -T guest_bare.ld -o $@ guest_bare.S
guest_bare.bin: guest_bare.elf
	$(OBJCOPY) -O binary $< guest_bare.bin

# ---- DRAM image: hypervisor @0, guest @0x600000, dtb @0x1000000 (if given) ----
# DTB host offset 0x1400000 == guest-physical 0x81000000 (GUEST_DTB_GPA in hv.c):
# the G-stage maps guest-phys G -> host (G + 0x400000), so the guest's DTB at
# guest-phys 0x81000000 lives at host 0x81400000. (Was 0x1000000, off by the
# 0x400000 G-stage offset, so the guest read a zero region instead of the DTB.)
hv_dram.hex: hv.bin $(GUEST) $(if $(GUEST_DTB),$(GUEST_DTB),)
	$(MKHEX) $@ 0:hv.bin 0x600000:$(GUEST) $(if $(GUEST_DTB),0x1400000:$(GUEST_DTB),)

dump-hv: hv.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all clean dump-hv
