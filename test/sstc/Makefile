# P10 Sstc directed test. Builds sstc_test.hex from sstc_test.S.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64ima_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

all: sstc_test.hex

sstc_test.elf: sstc_test.S sstc.ld
	$(CC) $(CFLAGS) -T sstc.ld -o $@ sstc_test.S

sstc_test.hex: sstc_test.elf
	$(OBJCOPY) -O binary $< sstc_test.bin
	$(ELF2HEX) sstc_test.bin $@

dump: sstc_test.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all dump clean
