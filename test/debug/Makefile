# Debug directed tests: DMI scripts (dmi/*.dmi -> dmi/*.hex, read by tb/dm_seq)
# and the hart programs they run against (prog/*.S -> prog/*.hex).
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
CFLAGS  = -march=rv64gc -mabi=lp64 -nostdlib -nostartfiles -ffreestanding
BIN2HEX = python3 ../c/bin2hex.py
DMIASM  = python3 dmi/dmi_asm.py

DMI  := $(patsubst %.dmi,%.hex,$(wildcard dmi/*.dmi))
PROG := $(patsubst %.S,%.hex,$(wildcard prog/*.S))

all: $(DMI) $(PROG)

dmi/%.hex: dmi/%.dmi dmi/dmi_asm.py
	$(DMIASM) $< $@

prog/%.elf: prog/%.S prog/prog.ld
	$(CC) $(CFLAGS) -T prog/prog.ld -o $@ $<

prog/%.hex: prog/%.elf
	$(OBJCOPY) -O binary $< prog/$*.bin
	$(BIN2HEX) prog/$*.bin $@

clean:
	rm -f dmi/*.hex prog/*.elf prog/*.bin prog/*.hex

.PHONY: all clean
