# CMO directed tests: cmo_test.hex from cmo_test.S, and cbo_vis1.hex /
# cbo_vis2.hex (1 and 2 harts) from cbo_vis.S.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64ima_zicsr_zicbom_zicboz -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

all: cmo_test.hex cbo_vis1.hex cbo_vis2.hex

cmo_test.elf: cmo_test.S cmo.ld
	$(CC) $(CFLAGS) -T cmo.ld -o $@ cmo_test.S

cmo_test.hex: cmo_test.elf
	$(OBJCOPY) -O binary $< cmo_test.bin
	$(ELF2HEX) cmo_test.bin $@

cbo_vis%.elf: cbo_vis.S cmo.ld
	$(CC) $(CFLAGS) -DNHARTS=$* -T cmo.ld -o $@ cbo_vis.S

cbo_vis%.hex: cbo_vis%.elf
	$(OBJCOPY) -O binary $< cbo_vis$*.bin
	$(ELF2HEX) cbo_vis$*.bin $@

dump: cmo_test.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all dump clean
