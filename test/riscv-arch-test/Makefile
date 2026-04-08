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

# Test suites (all auto-discovered from upstream/isa/<suite>/*.S)
SUITES := rv64ui rv64um rv64ua rv64uc rv64uf rv64ud

define SUITE_template
$(1)_NAMES := $$(patsubst $$(UPSTREAM)/isa/$(1)/%.S,%,$$(wildcard $$(UPSTREAM)/isa/$(1)/*.S))
$(1)_HEX   := $$(addprefix $$(BUILD)/$(1)/,$$(addsuffix .hex,$$($(1)_NAMES)))

$(1): $$($(1)_HEX)

$$(BUILD)/$(1)/%.hex: $$(UPSTREAM)/isa/$(1)/%.S
	@mkdir -p $$(BUILD)/$(1)
	$$(CC) $$(CFLAGS) $$(LDFLAGS) $$< -o $$(BUILD)/$(1)/$$*.elf
	$$(OBJCOPY) -O binary $$(BUILD)/$(1)/$$*.elf $$(BUILD)/$(1)/$$*.bin
	$$(BIN2HEX) $$(BUILD)/$(1)/$$*.bin $$@
endef

$(foreach s,$(SUITES),$(eval $(call SUITE_template,$(s))))

all: $(SUITES)

clean:
	rm -rf $(BUILD)

.PHONY: all clean $(SUITES)
