#!/usr/bin/env bash
# Run the riscv-tests debug suite (gdbserver.py) against spike, one test per
# process, and write "<test> <status>" lines to the output file.
#
# Usage: run_spike_ref.sh <spike64|spike64-2|path/to/target.py> <out.txt> [jobs]
# Env:   UPSTREAM  riscv-tests clone (default: test/riscv-arch-test/upstream)
#        LOGDIR    per-test logs (default: a fresh temp dir)
# Needs on PATH (source toolchain/env.sh): spike, openocd, riscv64-unknown-elf-gdb,
# riscv64-unknown-elf-gcc.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
target="${1:?target (spike64 | spike64-2)}"
out="${2:?output file}"
jobs="${3:-4}"
upstream="${UPSTREAM:-$root/test/riscv-arch-test/upstream}"
logdir="${LOGDIR:-$(mktemp -d)}"
dbg="$upstream/debug"
tfile="$dbg/targets/RISC-V/$target.py"
[ -f "$target" ] && tfile="$(realpath "$target")"

mkdir -p "$logdir"
tests="$("$dbg/gdbserver.py" --list-tests "$tfile")"

run_one() {
  local t="$1" log
  log="$("$dbg/gdbserver.py" --isolate --logs "$logdir" "$tfile" "$t" 2>&1)"
  local line
  line="$(printf '%s\n' "$log" | sed -n "s/^\[$t\] \(pass\|fail\|not_applicable\|exception\|skip\)[^ ]*.*/\1/p" | tail -1)"
  echo "$t ${line:-unknown}"
}
export -f run_one
export dbg tfile logdir

printf '%s\n' $tests | xargs -P "$jobs" -I{} bash -c 'run_one {}' | sort > "$out"
echo "wrote $out"
