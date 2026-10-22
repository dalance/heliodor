# P9.0 RVWMO litmus-test program. Builds two hex images from litmus.S:
#   litmus_n2.hex  (-DNH=2)  tests 0..9          (run by test_litmus_2hart)
#   litmus_n4.hex  (-DNH=4)  tests 0..9 + IRIW   (run by test_litmus_4hart)
#   litmus_n2_short.hex (-DNH=2, ITER_SHORT) the default-suite image of the new core
# Iteration count is baked in at build time: make ITER=2000
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64ima_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
ITER   ?= 1000
ITER_SHORT ?= 200
ELF2HEX = python3 ../c/bin2hex.py

all: litmus_n2.hex litmus_n4.hex litmus_n2_short.hex

litmus_n%.elf: litmus.S litmus.ld
	$(CC) $(CFLAGS) -DNH=$* -DITER=$(ITER) -T litmus.ld -o $@ litmus.S

litmus_n%.hex: litmus_n%.elf
	$(OBJCOPY) -O binary $< litmus_n$*.bin
	$(ELF2HEX) litmus_n$*.bin $@

litmus_n2_short.elf: litmus.S litmus.ld
	$(CC) $(CFLAGS) -DNH=2 -DITER=$(ITER_SHORT) -T litmus.ld -o $@ litmus.S

litmus_n2_short.hex: litmus_n2_short.elf
	$(OBJCOPY) -O binary $< litmus_n2_short.bin
	$(ELF2HEX) litmus_n2_short.bin $@

dump: litmus_n2.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PHONY: all dump clean
