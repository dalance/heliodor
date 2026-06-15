# P10 Zfa directed tests.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64imafd_zicsr_zfa -mabi=lp64d -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

SRCS = $(wildcard zfa_*.S)
HEX  = $(SRCS:.S=.hex)

all: $(HEX)

%.elf: %.S zfa.ld
	$(CC) $(CFLAGS) -T zfa.ld -o $@ $<

%.hex: %.elf
	$(OBJCOPY) -O binary $< $*.bin
	$(ELF2HEX) $*.bin $@

dump-%: %.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all clean
