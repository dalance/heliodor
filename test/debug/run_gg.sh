#!/usr/bin/env bash
# GG: run the riscv-tests debug suite (gdbserver.py) against the heliodor SoC
# on Verilator, one test per process, and write "<test> <status> <seconds>"
# lines to the output file. Each test's simulator log (with the firing
# counters it dumps when OpenOCD quits) is kept under <logdir>/<test>/.
#
# Usage: run_gg.sh <w2_n1|w2_n4|w4_n1> <out.txt> [jobs] [test ...]
# Env:   UPSTREAM  riscv-tests clone (default: test/riscv-arch-test/upstream,
#                  falling back to the main checkout's for a worktree)
#        LOGDIR    per-test logs (default: a fresh temp dir)
#        HELIODOR_GG_BUILD, HELIODOR_CMD_TIMEOUT: see targets/heliodor/heliodor_sim.py
# Needs: the Verilator build (sim/verilator/build_dm_<target>, see
# sim/verilator/tb_soc_dm.sv) and, on PATH, openocd, riscv64-unknown-elf-gdb
# and riscv64-unknown-elf-gcc (source toolchain/env.sh).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
target="${1:?target (w2_n1 | w2_n4 | w4_n1)}"
out="$(realpath -m "${2:?output file}")"
jobs="${3:-4}"
shift 3 2>/dev/null || shift $#
upstream="${UPSTREAM:-$root/test/riscv-arch-test/upstream}"
if [ ! -d "$upstream/debug" ]; then
  upstream="$(git -C "$root" worktree list --porcelain | sed -n '1s/^worktree //p')/test/riscv-arch-test/upstream"
fi
logdir="$(realpath -m "${LOGDIR:-$(mktemp -d)}")"
dbg="$upstream/debug"
tfile="$here/targets/heliodor/$target.py"
excl="$here/heliodor_excludes.yaml"
export HELIODOR_ROOT="$root"

mkdir -p "$logdir"
if [ $# -gt 0 ]; then
  tests="$*"
else
  tests="$(cd "$dbg" && ./gdbserver.py --list-tests "$tfile")"
fi

run_one() {
  local t="$1" log t0 line
  t0=$(date +%s)
  mkdir -p "$logdir/$t"
  log="$(cd "$dbg" && HELIODOR_GG_LOGDIR="$logdir/$t" ./gdbserver.py --isolate \
          --exclude-tests "$excl" --logs "$logdir/$t" "$tfile" "$t" 2>&1)"
  printf '%s\n' "$log" > "$logdir/$t/gdbserver.out"
  line="$(printf '%s\n' "$log" | sed -n "s/^\[$t\] \(pass\|fail\|not_applicable\|exception\|skip\)[^ ]*.*/\1/p" | tail -1)"
  echo "$t ${line:-unknown} $(( $(date +%s) - t0 ))"
}
export -f run_one
export dbg tfile logdir excl

printf '%s\n' $tests | xargs -P "$jobs" -I{} bash -c 'run_one {}' | sort > "$out"
echo "wrote $out (logs in $logdir)"
