# P10 hint-bundle directed tests (Zihintpause / Zihintntl / Zicbop / Zimop / Zcmop).
# zimop/zcmop are not yet assemblable by this GCC, so MOP/C.MOP are emitted via
# raw .word/.2byte in the source; the march only needs the hint extensions GCC
# does know.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64imafdc_zicsr_zihintpause_zihintntl_zicbop -mabi=lp64d -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

SRCS = $(wildcard *_test.S)
HEX  = $(SRCS:.S=.hex)

all: $(HEX)

%.elf: %.S hint.ld
	$(CC) $(CFLAGS) -T hint.ld -o $@ $<

%.hex: %.elf
	$(OBJCOPY) -O binary $< $*.bin
	$(ELF2HEX) $*.bin $@

dump-%: %.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all clean
