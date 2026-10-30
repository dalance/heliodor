#!/usr/bin/env bash
# Run an M-mode program (default trig_tval.S, design doc U35) on spike and on
# the heliodor SoC (Verilator, sim/verilator/tb_soc_dm.sv), read its result
# slots through OpenOCD and print both side by side, marking differences.
# The program fills NSLOT 4-dword slots at `sig` and sets `done`.
#
# Usage: run_xcheck.sh [prog.S] [build_dir]
# Needs on PATH (source toolchain/env.sh): spike, openocd,
# riscv64-unknown-elf-gcc, riscv64-unknown-elf-nm.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
src="${1:-$here/trig_tval.S}"
build="${2:-$root/sim/verilator/build_dm_w2_n1}"
work="$(mktemp -d)"
elf="$work/prog.elf"
riscv64-unknown-elf-gcc -march=rv64gc_zicbom_zicboz -mabi=lp64 -nostdlib -nostartfiles \
  -T "$root/test/debug/prog/prog.ld" -o "$elf" "$src" || exit 1
sym() { riscv64-unknown-elf-nm "$elf" | awk -v s="$1" '$3 == s { print "0x" $1 }'; }
sig="$(sym sig)"; done_a="$(sym done)"
nslot="$(grep -c '^ *SLOT$' "$src")"

# run <name> <idcode> <cmd...>: start a simulator that prints its rbb port,
# run the program through OpenOCD and print "<name> <slot words...>".
run() {
  local name="$1" idcode="$2" log="$work/$1.log" pid port
  shift 2
  "$@" > "$log" 2>&1 &
  pid=$!
  for _ in $(seq 300); do
    port="$(sed -n 's/.*remote bitbang connection on port \([0-9]*\)\..*/\1/p' "$log")"
    [ -n "$port" ] && break
    sleep 0.1
  done
  REMOTE_BITBANG_PORT="$port" XCHECK_IDCODE="$idcode" openocd -f "$here/xcheck.cfg" \
    -c "load_image $elf" -c "resume 0x80000000" -c "sleep 3000" -c "halt" \
    -c "echo \"DONE [read_memory $done_a 32 1]\"" \
    -c "echo \"SIG [read_memory $sig 64 [expr {4 * $nslot}]]\"" -c "shutdown" \
    > "$work/$name.ocd" 2>&1
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -q '^DONE 1$' "$work/$name.ocd" || { echo "$name: program did not finish" >&2; cat "$work/$name.ocd" >&2; }
  echo "$name $(sed -n 's/^SIG //p' "$work/$name.ocd")"
}

a="$(run spike 0xdeadbeef spike --isa=rv64gc_zicbom_zicboz --rbb-port=0 --halted "$elf")"
b="$(cd "$root" && run heliodor 0x10000a03 "$build/tb_soc_dm")"
python3 - "$a" "$b" <<'PY'
import sys
s = sys.argv[1].split()[1:]
h = sys.argv[2].split()[1:]
print("%-4s %-10s %-18s %-18s | %-10s %-18s %-18s" % ("case", "spike cau", "mepc", "mtval", "heliodor", "mepc", "mtval"))
diff = 0
for i in range(0, min(len(s), len(h)), 4):
    a, b = s[i:i + 3], h[i:i + 3]
    mark = "" if a == b else "  <-- differs"
    diff += a != b
    print("%-4d %-10s %-18s %-18s | %-10s %-18s %-18s%s" % (int(s[i + 3], 16), a[0], a[1], a[2], b[0], b[1], b[2], mark))
print("%d case(s) differ" % diff)
PY
rm -rf "$work"
