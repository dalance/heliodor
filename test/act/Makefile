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
#     make -C test/act            # every suite selected for the heliodor config
#     make -C test/act EXT="F D"  # only these suite directories
#     make -C test/act clean      # remove generated ELFs/bin (keeps upstream clone)
#     make -C test/act distclean  # also remove the upstream clone
#
# The flow per suite <EXT>:
#   framework `make` -> Sail-signed self-checking ELFs in work/heliodor/elfs/**/<EXT>/
#   gen_suite.py     -> test/hex/act_<ext>_*.hex + test/gates/mi_act.list
# Run with test/gates/run_act.py from the repo root.

HERE       := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO       := $(abspath $(HERE)/../..)
UPSTREAM   := $(HERE)/upstream/riscv-arch-test-act
UPSTREAM_URL := https://github.com/riscv/riscv-arch-test

# Pinned framework commit. `riscv/riscv-arch-test`'s default branch `act4` is the
# moving development tip (no semver release tags — only rolling `ctp-release-*`),
# so a bare `git clone` would drift: a clean rebuild could pull different test
# sources / Sail signatures and shift the pass/fail counts. Pin to an exact commit
# so the documented results are reproducible on demand. Bump deliberately (then
# `make distclean` to repin), not by accident.
ACT_COMMIT := 8b9ddedcd44a2721dd9153efb4c64fc812090148

CFG_SRC    := $(HERE)/config/heliodor
CFG_DST    := $(UPSTREAM)/config/cores/heliodor
JOBS       ?= $(shell nproc)

# Default: every suite the framework selects for the heliodor UDB config
# (config/heliodor/heliodor.yaml). EXT narrows it to suite directory names,
# space-separated (e.g. EXT="I Zba Vx8"); the framework wants them
# comma-separated with no spaces, hence EXT_CSV.
EXT        ?=

empty      :=
space      := $(empty) $(empty)
comma      := ,
EXT_CSV    := $(subst $(space),$(comma),$(strip $(EXT)))

export OBJCOPY  := riscv64-unknown-elf-objcopy
# The UDB gem downloads its solver binaries into $XDG_CACHE_HOME at install and
# writes its resolved spec into $XDG_DATA_HOME; keep both with the other
# toolchain caches.
export XDG_CACHE_HOME := $(REPO)/toolchain/.cache
export XDG_DATA_HOME  := $(REPO)/toolchain/.cache/share
export ACT_WORK := $(UPSTREAM)/work/heliodor

.PHONY: all upstream config framework elfs hex clean distclean
all: hex

# 1. Fetch the ACT4 framework at the PINNED commit (not committed — like
#    test/riscv-arch-test/upstream). Shallow fetch-by-sha keeps it a one-commit
#    checkout while guaranteeing the exact $(ACT_COMMIT). If a clone already
#    exists at a different commit, warn instead of silently mutating it.
upstream:
	@if [ ! -d "$(UPSTREAM)/.git" ]; then \
	  echo "Fetching $(UPSTREAM_URL) @ $(ACT_COMMIT) ..."; \
	  git init -q "$(UPSTREAM)"; \
	  git -C "$(UPSTREAM)" remote add origin $(UPSTREAM_URL); \
	  git -C "$(UPSTREAM)" fetch -q --depth 1 origin $(ACT_COMMIT); \
	  git -C "$(UPSTREAM)" checkout -q FETCH_HEAD; \
	fi
	@have=$$(git -C "$(UPSTREAM)" rev-parse HEAD 2>/dev/null); \
	if [ "$$have" != "$(ACT_COMMIT)" ]; then \
	  echo "WARNING: $(UPSTREAM) is at $$have,"; \
	  echo "         but the pin is $(ACT_COMMIT)."; \
	  echo "         Run 'make -C test/act distclean' then re-make to repin."; \
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

# 4. Generate the Sail-signed ELFs for the requested extensions. The vector
#    privileged suites (ExceptionsV*, MisalignV) come from a separate generator
#    that the framework's default target does not run. The framework's own
#    `elfs` target stops at the first failure; two SdtrigS/SdtrigU napot tests
#    exceed the 4 MiB harness DRAM and never link, so call `act` directly with
#    --keep-going and let the rest through.
ACT_ARGS   := config/cores/heliodor/test_config.yaml --workdir work --test-dir tests \
              --jobs $(JOBS) --keep-going $(if $(EXT_CSV),--extensions $(EXT_CSV))
elfs: framework
	@command -v riscv64-unknown-elf-gcc >/dev/null || { echo "elf gcc not on PATH — source toolchain/env.sh"; exit 1; }
	@command -v sail_riscv_sim >/dev/null || { echo "sail_riscv_sim not on PATH — source toolchain/env.sh"; exit 1; }
	cd "$(UPSTREAM)" && uv run make tests vector-tests JOBS=$(JOBS)
	-cd "$(UPSTREAM)" && uv run act $(ACT_ARGS)

# 5. ELF -> hex, and the gate list when every suite was generated.
GATE_LIST  := $(REPO)/test/gates/mi_act.list
hex: elfs
	python3 "$(HERE)/gen_suite.py" $(if $(EXT),,--list "$(GATE_LIST)") $(EXT)
	@echo "Done. Run: test/gates/run_act.py --core w2"

clean:
	rm -rf "$(HERE)/build"
	-cd "$(UPSTREAM)" && make clean 2>/dev/null || true

distclean: clean
	rm -rf "$(HERE)/upstream"
