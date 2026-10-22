# SMP coherence directed tests: coh.S (coh_n2.hex, coh_n4.hex) and the Svadu
# A/D test ad.S (ad_n2.hex) and the uncached-read recall test unc.S
# (unc_n2.hex, same layout as ad.ld).
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
CFLAGS  = -march=rv64ima_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ELF2HEX = python3 ../c/bin2hex.py

all: coh_n2.hex coh_n4.hex ad_n2.hex unc_n2.hex

coh_n%.elf: coh.S coh.ld
	$(CC) $(CFLAGS) -DNH=$* -T coh.ld -o $@ coh.S

coh_n%.hex: coh_n%.elf
	$(OBJCOPY) -O binary $< coh_n$*.bin
	$(ELF2HEX) coh_n$*.bin $@

ad_n%.elf: ad.S ad.ld
	$(CC) $(CFLAGS) -DNH=$* -T ad.ld -o $@ ad.S

ad_n%.hex: ad_n%.elf
	$(OBJCOPY) -O binary $< ad_n$*.bin
	$(ELF2HEX) ad_n$*.bin $@

unc_n%.elf: unc.S ad.ld
	$(CC) $(CFLAGS) -DNH=$* -T ad.ld -o $@ unc.S

unc_n%.hex: unc_n%.elf
	$(OBJCOPY) -O binary $< unc_n$*.bin
	$(ELF2HEX) unc_n$*.bin $@

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all clean
