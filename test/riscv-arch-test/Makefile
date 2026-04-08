# Build riscv-tests ISA tests as hex files for heliodor.
#
# The upstream tests live in upstream/isa/<isa>/<name>.S and use the
# riscv-tests "p" environment (physical addressing, _start at 0x80000000,
# tohost mechanism). Each .S compiles to a flat hex via:
#   .S → .elf (gcc -nostdlib -T env/p/link.ld)
#   .elf → .bin (objcopy -O binary)
#   .bin → .hex (bin2hex.py)

UPSTREAM := upstream
ENV      := $(UPSTREAM)/env
CC       := riscv64-unknown-elf-gcc
OBJCOPY  := riscv64-unknown-elf-objcopy
BIN2HEX  := python3 ../c/bin2hex.py

CFLAGS := -march=rv64g -mabi=lp64 -nostdlib -nostartfiles -static \
          -mcmodel=medany -fvisibility=hidden \
          -I$(ENV)/p -I$(ENV) -I$(UPSTREAM)/isa/macros/scalar
LDFLAGS := -T $(ENV)/p/link.ld

BUILD := build

# rv64ui (RV64I user-mode) tests we currently build.
RV64UI := add addi addiw addw and andi auipc beq bge bgeu blt bltu bne \
          jal jalr lb lbu lh lhu lui lw lwu ld or ori sb sh sw sd \
          sll slli slliw sllw slt slti sltiu sltu sra srai sraiw sraw \
          srl srli srliw srlw sub subw xor xori

RV64UI_HEX := $(addprefix $(BUILD)/rv64ui/,$(addsuffix .hex,$(RV64UI)))

all: rv64ui

rv64ui: $(RV64UI_HEX)

$(BUILD)/rv64ui/%.hex: $(UPSTREAM)/isa/rv64ui/%.S
	@mkdir -p $(BUILD)/rv64ui
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $(BUILD)/rv64ui/$*.elf
	$(OBJCOPY) -O binary $(BUILD)/rv64ui/$*.elf $(BUILD)/rv64ui/$*.bin
	$(BIN2HEX) $(BUILD)/rv64ui/$*.bin $@

clean:
	rm -rf $(BUILD)

.PHONY: all rv64ui clean
