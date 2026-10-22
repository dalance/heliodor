# SMP coherence directed test (coh.S). Builds coh_n2.hex and coh_n4.hex.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
CFLAGS  = -march=rv64ima_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

all: coh_n2.hex coh_n4.hex

coh_n%.elf: coh.S coh.ld
	$(CC) $(CFLAGS) -DNH=$* -T coh.ld -o $@ coh.S

coh_n%.hex: coh_n%.elf
	$(OBJCOPY) -O binary $< coh_n$*.bin
	$(ELF2HEX) coh_n$*.bin $@

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all clean
