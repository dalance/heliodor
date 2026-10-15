# Self-checking directed probes for the old-core deviations (verification
# plan, appendix B) and the directed tests of the new core. Each <name>.S
# builds <name>.hex.
CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS  = -march=rv64gcv_zicsr_zifencei_zacas_svinval -mabi=lp64d -nostdlib -nostartfiles -ffreestanding -I.
ELF2HEX = python3 ../c/bin2hex.py

SRCS = $(wildcard *.S)
HEXS = $(SRCS:.S=.hex)

all: $(HEXS)

%.elf: %.S common/probe.h common/probe.ld
	$(CC) $(CFLAGS) -T common/probe.ld -o $@ $<

%.hex: %.elf
	$(OBJCOPY) -O binary $< $*.bin
	$(ELF2HEX) $*.bin $@

dump-%: %.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.elf *.bin *.hex

.PRECIOUS: %.elf
.PHONY: all clean
