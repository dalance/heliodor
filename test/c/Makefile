CC = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy
OBJDUMP = riscv64-unknown-elf-objdump

CFLAGS = -march=rv64im -mabi=lp64 -Os -nostdlib -nostartfiles -ffreestanding -fno-builtin
LDFLAGS = -T bare.ld -nostdlib

HEX_DIR = ../hex

all: $(HEX_DIR)/hello_c.hex

# Convert ELF → flat binary → simple hex (one word per line, no @address)
$(HEX_DIR)/hello_c.hex: hello.elf
	$(OBJCOPY) -O binary $< hello.bin
	python3 -c "\
import struct; \
data = bytearray(open('hello.bin','rb').read()); \
data += b'\x00' * (4 - len(data) % 4) if len(data) % 4 else b''; \
lines = ['%08X' % struct.unpack('<I', data[i:i+4])[0] for i in range(0,len(data),4)]; \
open('$@','w').write('\n'.join(lines)+'\n'); \
print('%d words (%d bytes)' % (len(lines), len(data)))"

hello.elf: start.o hello.o
	$(CC) $(LDFLAGS) -o $@ $^

start.o: start.S
	$(CC) $(CFLAGS) -c -o $@ $<

hello.o: hello.c
	$(CC) $(CFLAGS) -c -o $@ $<

dump: hello.elf
	$(OBJDUMP) -d $<

clean:
	rm -f *.o *.elf *.bin $(HEX_DIR)/hello_c.hex

.PHONY: all dump clean
