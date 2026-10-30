#!/usr/bin/env bash
# Run an OpenOCD Tcl script against the heliodor SoC on Verilator: start the
# simulator (sim/verilator/tb_soc_dm.sv), connect OpenOCD with <cfg> and run
# <script>, then stop the simulator by its pid. Prints the OpenOCD output and
# the simulator's last lines; exits 0 only if the output has <pass_marker>.
#
# Usage: run_ocd.sh <build_dir> <cfg> <script.tcl> <pass_marker>
# Needs openocd on PATH (source toolchain/env.sh). Run from anywhere.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
build="$(realpath "${1:?build dir}")"
cfg="$(realpath "${2:?openocd cfg}")"
tcl="$(realpath "${3:?tcl script}")"
marker="${4:?pass marker}"
work="$(mktemp -d)"

cd "$root"
"$build/tb_soc_dm" > "$work/sim.log" 2>&1 &
sim=$!
port=
for _ in $(seq 300); do
  port="$(sed -n 's/.*remote bitbang connection on port \([0-9]*\)\..*/\1/p' "$work/sim.log")"
  [ -n "$port" ] && break
  sleep 0.1
done
REMOTE_BITBANG_HOST=localhost REMOTE_BITBANG_PORT="$port" WORK_AREA=0x80000000 USE_FREERTOS=0 \
  HELIODOR_CMD_TIMEOUT="${HELIODOR_CMD_TIMEOUT:-300}" \
  openocd -c "gdb port disabled" -c "tcl port disabled" -c "telnet port disabled" \
  -f "$cfg" -f "$tcl" > "$work/ocd.log" 2>&1
# The simulator dumps its counters and exits once OpenOCD has quit.
for _ in $(seq 300); do
  kill -0 "$sim" 2>/dev/null || break
  sleep 0.2
done
kill "$sim" 2>/dev/null
wait "$sim"
simrc=$?
grep -v '^Debug\|^Info\|^DEPRECATED\|^Warn : DEPRECATED' "$work/ocd.log"
grep '^\[tb_soc_dm\]' "$work/sim.log"
rc=1
grep -q "^$marker\$" "$work/ocd.log" && [ "$simrc" -eq 0 ] && rc=0
rm -rf "$work"
exit $rc
