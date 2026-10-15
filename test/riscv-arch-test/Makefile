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

CFLAGS := -march=rv64g_zba_zbb_zbs_zicbom_zicboz -mabi=lp64 -nostdlib -nostartfiles -static \
          -mcmodel=medany -fvisibility=hidden \
          -I$(ENV)/p -I$(ENV) -I$(UPSTREAM)/isa/macros/scalar
LDFLAGS := -T $(ENV)/p/link.ld

BUILD := build

# Test suites (all auto-discovered from upstream/isa/<suite>/*.S)
# Phase 10: B extension (Zba/Zbb/Zbs) + CMO (Zicbom/Zicboz) — march above, suites below.
SUITES := rv64ui rv64um rv64ua rv64uc rv64uf rv64ud rv64mi rv64si \
          rv64uzba rv64uzbb rv64uzbs rv64mzicbo

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

# The "v" environment runs the same tests in U-mode under Sv39 with demand
# paging (env/v/vm.c), so fetch and data translation, the walkers and page
# faults are exercised. F is in -march only because vm.c names fssr in an
# asm string; the image executes no FP instruction.
VSUITES := rv64ui
VCFLAGS := -march=rv64imf_zicsr_zifencei -mabi=lp64 -static -mcmodel=medany -fvisibility=hidden \
           -nostdlib -nostartfiles -DENTROPY=0x1234567 -std=gnu99 -O2 \
           -I$(ENV)/v -I$(UPSTREAM)/isa/macros/scalar
VSRCS   := $(ENV)/v/entry.S $(wildcard $(ENV)/v/*.c)

define VSUITE_template
$(1)_v_NAMES := $$(patsubst $$(UPSTREAM)/isa/$(1)/%.S,%,$$(wildcard $$(UPSTREAM)/isa/$(1)/*.S))
$(1)_v_HEX   := $$(addprefix $$(BUILD)/$(1)_v/,$$(addsuffix .hex,$$($(1)_v_NAMES)))

$(1)_v: $$($(1)_v_HEX)

$$(BUILD)/$(1)_v/%.hex: $$(UPSTREAM)/isa/$(1)/%.S $$(VSRCS)
	@mkdir -p $$(BUILD)/$(1)_v
	$$(CC) $$(VCFLAGS) -T $$(ENV)/v/link.ld $$(VSRCS) $$< -o $$(BUILD)/$(1)_v/$$*.elf
	$$(OBJCOPY) -O binary $$(BUILD)/$(1)_v/$$*.elf $$(BUILD)/$(1)_v/$$*.bin
	$$(BIN2HEX) $$(BUILD)/$(1)_v/$$*.bin $$@
endef

$(foreach s,$(VSUITES),$(eval $(call VSUITE_template,$(s))))

all: $(SUITES) $(addsuffix _v,$(VSUITES))

clean:
	rm -rf $(BUILD)

.PHONY: all clean $(SUITES) $(addsuffix _v,$(VSUITES))
