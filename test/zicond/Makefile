# P10 Zicond directed test. Builds zicond_test.hex from zicond_test.S.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64ima_zicsr_zicond -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

all: zicond_test.hex

zicond_test.elf: zicond_test.S zicond.ld
	$(CC) $(CFLAGS) -T zicond.ld -o $@ zicond_test.S

zicond_test.hex: zicond_test.elf
	$(OBJCOPY) -O binary $< zicond_test.bin
	$(ELF2HEX) zicond_test.bin $@

dump: zicond_test.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all dump clean
