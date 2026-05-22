#!/usr/bin/env bash
# Phase 7 v4 precommit gate. Run before EVERY commit that touches v4 work.
#
# Per Iron Rule 2 (doc/phase7_v4_plan.md): failing this check = no commit.
# Even debug/instrumentation commits must pass.
#
# Exits non-zero if any test fails. Prints a one-line summary either way.
#
# --test filter caveat (Rule 6):
#   `veryl test --test <substring>` does a substring match BUT also requires
#   the test was actually compiled into the current dependency graph. Tests
#   marked `#[ignore]` are skipped unless --include-ignored is also passed.
#   When in doubt grep the test output for the test name; if absent, the
#   filter silently dropped it.

set -u
set -o pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VERYL="$ROOT/veryl/target/release-verylup/veryl"

if [[ ! -x "$VERYL" ]]; then
    echo "[v4_precommit] missing $VERYL — run: (cd veryl && cargo build --profile release-verylup)" >&2
    exit 2
fi

rm -f "$ROOT/.build/lock"

fail=0

# Stage 1: fast suite (must always pass)
echo "[v4_precommit] stage 1: veryl test (fast suite)"
if ! "$VERYL" test 2>&1 | tee "$ROOT/.build/v4_precommit_fast.log" | tail -3; then
    echo "[v4_precommit] FAIL: fast suite"
    fail=1
fi

# Stage 2: cosim suite (must always pass)
echo "[v4_precommit] stage 2: veryl test --include-ignored --test test_cosim"
if ! "$VERYL" test --include-ignored --test test_cosim 2>&1 | tee "$ROOT/.build/v4_precommit_cosim.log" | tail -3; then
    echo "[v4_precommit] FAIL: cosim suite"
    fail=1
fi

# Stage 3 (placeholder for M1+): v4 arch test suite
#   "$VERYL" test --include-ignored --test test_v4_arch_rv64ui

if [[ $fail -eq 0 ]]; then
    echo "[v4_precommit] PASS"
    exit 0
else
    echo "[v4_precommit] FAIL — do not commit"
    exit 1
fi
