# Non-cacheable access smoke test. Builds io_smoke.hex from io_smoke.S.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64ima_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

all: io_smoke.hex

io_smoke.elf: io_smoke.S io_smoke.ld
	$(CC) $(CFLAGS) -T io_smoke.ld -o $@ io_smoke.S

io_smoke.hex: io_smoke.elf
	$(OBJCOPY) -O binary $< io_smoke.bin
	$(ELF2HEX) io_smoke.bin $@

dump: io_smoke.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all dump clean
