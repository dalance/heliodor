# P10 Zihpm directed test. Builds hpm_test.hex from hpm_test.S.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64ima_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

all: hpm_test.hex

hpm_test.elf: hpm_test.S hpm.ld
	$(CC) $(CFLAGS) -T hpm.ld -o $@ hpm_test.S

hpm_test.hex: hpm_test.elf
	$(OBJCOPY) -O binary $< hpm_test.bin
	$(ELF2HEX) hpm_test.bin $@

dump: hpm_test.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all dump clean
