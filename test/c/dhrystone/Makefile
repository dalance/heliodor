CC       = riscv64-unknown-elf-gcc
OBJCOPY  = riscv64-unknown-elf-objcopy

UPSTREAM = ../../riscv-arch-test/upstream/benchmarks
CFLAGS   = -march=rv64imafdc -mabi=lp64d -mcmodel=medany -O2 -nostdlib -nostartfiles \
           -ffreestanding -fno-builtin -fno-common \
           -Wno-implicit-function-declaration -Wno-implicit-int \
           -I$(UPSTREAM)/common -I$(UPSTREAM)/../../upstream/env \
           -DNUMBER_OF_RUNS=100 \
           -DTIME -DHZ=1000000 -DCLOCK_TYPE="\"rdcycle\""
LDFLAGS  = -T link.ld -nostdlib

HEX_DIR  = ../../hex
ELF2HEX  = python3 ../bin2hex.py

DHRY_SRC = $(UPSTREAM)/dhrystone/dhrystone_main.c \
           $(UPSTREAM)/dhrystone/dhrystone.c
OBJS     = start.o syscalls.o dhrystone_main.o dhrystone.o

all: $(HEX_DIR)/dhrystone.hex

$(HEX_DIR)/dhrystone.hex: dhrystone.elf
	$(OBJCOPY) -O binary $< dhrystone.bin
	$(ELF2HEX) dhrystone.bin $@ 0x80000000

dhrystone.elf: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

start.o: start.S
	$(CC) $(CFLAGS) -c -o $@ $<

syscalls.o: syscalls.c
	$(CC) $(CFLAGS) -c -o $@ $<

dhrystone_main.o: $(UPSTREAM)/dhrystone/dhrystone_main.c
	$(CC) $(CFLAGS) -c -o $@ $<

dhrystone.o: $(UPSTREAM)/dhrystone/dhrystone.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f *.o *.elf *.bin $(HEX_DIR)/dhrystone.hex

.PHONY: all clean
