# Build the official RISC-V Architectural Compliance Tests (ACT4,
# riscv/riscv-arch-test — the RISCOF successor) for the heliodor DUT and emit
# Veryl #[test] modules under tb/.
#
# Prereq: fetch the toolchains and put them on PATH first:
#     toolchain/fetch.sh all && source toolchain/env.sh
# (provides riscv64-unknown-elf-gcc >= 15, sail_riscv_sim, uv; Ruby/UDB use the
#  system Ruby with BUNDLE_PATH set by env.sh.)
#
# Usage:
#     make -C test/act            # generate the default extension set
#     make -C test/act EXT="F D"  # generate specific extensions
#     make -C test/act clean      # remove generated ELFs/bin (keeps upstream clone)
#     make -C test/act distclean  # also remove the upstream clone
#
# The flow per extension <EXT>:
#   framework `make` -> Sail-signed self-checking ELFs in work/heliodor/elfs/**/<EXT>/
#   gen_suite.py     -> test/hex/act_<ext>_*.hex + tb/test_act_<ext>.veryl
# Run with `veryl test --ignored --test test_act_<ext>` from the repo root.

HERE       := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO       := $(abspath $(HERE)/../..)
UPSTREAM   := $(HERE)/upstream/riscv-arch-test-act
UPSTREAM_URL := https://github.com/riscv/riscv-arch-test
CFG_SRC    := $(HERE)/config/heliodor
CFG_DST    := $(UPSTREAM)/config/cores/heliodor
JOBS       ?= $(shell nproc)

# Default set: every scalar suite heliodor passes (472/472). Combined-extension
# suites are named by their test DIRECTORY (e.g. ZfaF, ZcbZba) — see README.
# Tokens are space-separated here (readable + fed to gen_suite.py) and translated
# to commas for the framework below (EXT_CSV).
EXT        ?= I M Zaamo Zalrsc Zca Zcd Zicsr Zifencei Zicntr F D \
              Zba Zbb Zbs Zcb ZcbM ZcbZba ZcbZbb Zcmop Zimop Zicond \
              Zihintntl ZihintntlZca Zihintpause ZfaF ZfaD Zfhmin ZfhminD

# The upstream framework wants EXTENSIONS comma-separated and strips all spaces
# from the value (so a space-separated list collapses to one bogus token and
# matches nothing). EXT stays space-separated for readability + gen_suite.py;
# translate to commas for the framework invocation below.
empty      :=
space      := $(empty) $(empty)
comma      := ,
EXT_CSV    := $(subst $(space),$(comma),$(strip $(EXT)))

export OBJCOPY  := riscv64-unknown-elf-objcopy
export ACT_WORK := $(UPSTREAM)/work/heliodor

.PHONY: all upstream config framework elfs hex clean distclean
all: hex

# 1. Clone the ACT4 framework (not committed — like test/riscv-arch-test/upstream).
upstream:
	@if [ ! -d "$(UPSTREAM)/.git" ]; then \
	  echo "Cloning $(UPSTREAM_URL) ..."; \
	  git clone --depth 1 $(UPSTREAM_URL) "$(UPSTREAM)"; \
	fi

# 2. Drop the heliodor DUT config into the framework's config/cores/.
config: upstream
	@mkdir -p "$(CFG_DST)"
	@cp -f "$(CFG_SRC)"/* "$(CFG_DST)/"
	@echo "config -> $(CFG_DST)"

# 3. Python (uv) + Ruby/UDB (bundler) framework setup.
framework: config
	@command -v uv  >/dev/null || { echo "uv not on PATH — run: source toolchain/env.sh"; exit 1; }
	@command -v ruby >/dev/null || { echo "system ruby >= 3.4 required"; exit 1; }
	cd "$(UPSTREAM)" && uv sync
	cd "$(UPSTREAM)/framework/src/act/data" && bundle install

# 4. Generate the Sail-signed ELFs for the requested extensions.
elfs: framework
	@command -v riscv64-unknown-elf-gcc >/dev/null || { echo "elf gcc not on PATH — source toolchain/env.sh"; exit 1; }
	@command -v sail_riscv_sim >/dev/null || { echo "sail_riscv_sim not on PATH — source toolchain/env.sh"; exit 1; }
	cd "$(UPSTREAM)" && uv run make \
	  EXTENSIONS="$(EXT_CSV)" \
	  CONFIG_FILES=config/cores/heliodor/test_config.yaml \
	  JOBS=$(JOBS)

# 5. ELF -> hex + Veryl modules.
hex: elfs
	python3 "$(HERE)/gen_suite.py" $(EXT)
	@echo "Done. Run: veryl test --ignored --test test_act_<ext>"

clean:
	rm -rf "$(HERE)/build"
	-cd "$(UPSTREAM)" && make clean 2>/dev/null || true

distclean: clean
	rm -rf "$(HERE)/upstream"
