# M2 privileged-architecture directed test. Builds priv_test.hex.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64imac_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

all: priv_test.hex

priv_test.elf: priv_test.S priv.ld
	$(CC) $(CFLAGS) -T priv.ld -o $@ priv_test.S

priv_test.hex: priv_test.elf
	$(OBJCOPY) -O binary $< priv_test.bin
	$(ELF2HEX) priv_test.bin $@

dump: priv_test.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all dump clean
