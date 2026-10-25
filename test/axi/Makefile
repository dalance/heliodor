# AXI4 directed tests: i1.S (a read after a write the slave has not
# finished), i4.S (a write into a line being gathered, two harts) and
# err.S (DECERR responses).
# Same flat layout as ../coh/ad.ld.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
CFLAGS  = -march=rv64ima_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

all: i1.hex i4.hex err.hex

i1.elf: i1.S ../coh/ad.ld
	$(CC) $(CFLAGS) -T ../coh/ad.ld -o $@ i1.S

i1.hex: i1.elf
	$(OBJCOPY) -O binary $< i1.bin
	$(ELF2HEX) i1.bin $@

i4.elf: i4.S ../coh/ad.ld
	$(CC) $(CFLAGS) -T ../coh/ad.ld -o $@ i4.S

i4.hex: i4.elf
	$(OBJCOPY) -O binary $< i4.bin
	$(ELF2HEX) i4.bin $@

err.elf: err.S ../coh/ad.ld
	$(CC) $(CFLAGS) -T ../coh/ad.ld -o $@ err.S

err.hex: err.elf
	$(OBJCOPY) -O binary $< err.bin
	$(ELF2HEX) err.bin $@

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all clean
