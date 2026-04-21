CC       = riscv64-unknown-elf-gcc
OBJCOPY  = riscv64-unknown-elf-objcopy

UPSTREAM = ../../riscv-arch-test/upstream/benchmarks
CFLAGS   = -march=rv64imafdc -mabi=lp64d -mcmodel=medany -O2 -nostdlib -nostartfiles \
           -ffreestanding -fno-builtin -fno-common \
           -Wno-implicit-function-declaration -Wno-implicit-int \
           -I$(UPSTREAM)/common \
           -I$(UPSTREAM)/../../upstream/env \
           -DPREALLOCATE=0
LDFLAGS  = -T link.ld -nostdlib

HEX_DIR  = ../../hex
ELF2HEX  = python3 ../bin2hex.py

BENCHMARKS = median memcpy multiply

HEXES = $(foreach b,$(BENCHMARKS),$(HEX_DIR)/bench_$(b).hex)

all: $(HEXES)

# Shared objects (compiled once per benchmark to keep per-benchmark
# section layout tidy; overhead is negligible).
start.o: start.S
	$(CC) $(CFLAGS) -c -o $@ $<

syscalls.o: syscalls.c
	$(CC) $(CFLAGS) -c -o $@ $<

# --- median ---
median_main.o: $(UPSTREAM)/median/median_main.c
	$(CC) $(CFLAGS) -I$(UPSTREAM)/median -c -o $@ $<

median.o: $(UPSTREAM)/median/median.c
	$(CC) $(CFLAGS) -I$(UPSTREAM)/median -c -o $@ $<

bench_median.elf: start.o syscalls.o median_main.o median.o
	$(CC) $(LDFLAGS) -o $@ $^

$(HEX_DIR)/bench_median.hex: bench_median.elf
	$(OBJCOPY) -O binary $< bench_median.bin
	$(ELF2HEX) bench_median.bin $@ 0x80000000

# --- memcpy ---
memcpy_main.o: $(UPSTREAM)/memcpy/memcpy_main.c
	$(CC) $(CFLAGS) -I$(UPSTREAM)/memcpy -c -o $@ $<

bench_memcpy.elf: start.o syscalls.o memcpy_main.o
	$(CC) $(LDFLAGS) -o $@ $^

$(HEX_DIR)/bench_memcpy.hex: bench_memcpy.elf
	$(OBJCOPY) -O binary $< bench_memcpy.bin
	$(ELF2HEX) bench_memcpy.bin $@ 0x80000000

# --- multiply ---
multiply_main.o: $(UPSTREAM)/multiply/multiply_main.c
	$(CC) $(CFLAGS) -I$(UPSTREAM)/multiply -c -o $@ $<

multiply.o: $(UPSTREAM)/multiply/multiply.c
	$(CC) $(CFLAGS) -I$(UPSTREAM)/multiply -c -o $@ $<

bench_multiply.elf: start.o syscalls.o multiply_main.o multiply.o
	$(CC) $(LDFLAGS) -o $@ $^

$(HEX_DIR)/bench_multiply.hex: bench_multiply.elf
	$(OBJCOPY) -O binary $< bench_multiply.bin
	$(ELF2HEX) bench_multiply.bin $@ 0x80000000

clean:
	rm -f *.o *.elf *.bin
	rm -f $(HEXES)

.PHONY: all clean
