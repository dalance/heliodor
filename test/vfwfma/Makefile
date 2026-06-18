# Phase 12 V3j directed test: widening vector FP FMA (vfwmacc family).
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64gcv_zicsr -mabi=lp64d -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

SRCS = $(wildcard *_test.S)
HEX  = $(SRCS:.S=.hex)

all: $(HEX)

%.elf: %.S vfwfma.ld
	$(CC) $(CFLAGS) -T vfwfma.ld -o $@ $<

%.hex: %.elf
	$(OBJCOPY) -O binary $< $*.bin
	$(ELF2HEX) $*.bin $@

dump-%: %.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all clean
