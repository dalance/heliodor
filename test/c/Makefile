CC = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS = -march=rv64im -mabi=lp64 -Os -nostdlib -nostartfiles -ffreestanding -fno-builtin
LDFLAGS = -T bare.ld -nostdlib

HEX_DIR = ../hex
ELF2HEX = python3 bin2hex.py

all: $(HEX_DIR)/hello_c.hex $(HEX_DIR)/hello_str.hex

$(HEX_DIR)/hello_c.hex: hello.elf
	$(OBJCOPY) -O binary $< hello.bin
	$(ELF2HEX) hello.bin $@

$(HEX_DIR)/hello_str.hex: hello_str.elf
	$(OBJCOPY) -O binary $< hello_str.bin
	$(ELF2HEX) hello_str.bin $@

hello.elf: start.o hello.o
	$(CC) $(LDFLAGS) -o $@ $^

hello_str.elf: start.o hello_str.o
	$(CC) $(LDFLAGS) -o $@ $^

start.o: start.S
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

dump: hello.elf
	$(OBJDUMP) -d $<

dump-str: hello_str.elf
	$(OBJDUMP) -d -s $<

clean:
	rm -f *.o *.elf *.bin $(HEX_DIR)/hello_c.hex $(HEX_DIR)/hello_str.hex

.PHONY: all dump dump-str clean
