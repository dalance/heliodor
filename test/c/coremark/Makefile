CC      = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy

ITERATIONS ?= 1
PERFORMANCE_RUN = 1

CFLAGS = -march=rv64imafdc -mabi=lp64d -mcmodel=medany -O2 \
         -nostdlib -nostartfiles -ffreestanding -fno-builtin -fno-common \
         -Wno-implicit-function-declaration -Wno-implicit-int -Wno-unused-result \
         -I. \
         -DITERATIONS=$(ITERATIONS) -DPERFORMANCE_RUN=$(PERFORMANCE_RUN)
LDFLAGS = -T link.ld -nostdlib

HEX_DIR = ../../hex
ELF2HEX = python3 ../bin2hex.py

OBJS = start.o core_portme.o core_main.o core_list_join.o core_matrix.o core_state.o core_util.o

all: $(HEX_DIR)/coremark.hex

$(HEX_DIR)/coremark.hex: coremark.elf
	$(OBJCOPY) -O binary $< coremark.bin
	$(ELF2HEX) coremark.bin $@ 0x80000000

coremark.elf: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.S
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f *.o *.elf *.bin $(HEX_DIR)/coremark.hex

.PHONY: all clean
