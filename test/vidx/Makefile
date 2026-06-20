# Phase 12 V5g indexed (gather/scatter) vector load/store directed test.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

# Needs the V extension (v) in -march for the vector mnemonics.
CFLAGS  = -march=rv64gcv_zicsr -mabi=lp64d -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

SRCS = $(wildcard *_test.S)
HEX  = $(SRCS:.S=.hex)

all: $(HEX)

%.elf: %.S vidx.ld
	$(CC) $(CFLAGS) -T vidx.ld -o $@ $<

%.hex: %.elf
	$(OBJCOPY) -O binary $< $*.bin
	$(ELF2HEX) $*.bin $@

dump-%: %.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all clean
