#!/usr/bin/env bash
# Vivado out-of-context synthesis of heliodor.
#
#   synth/vivado/run.sh <target> [threads]
#
# Targets:
#   soc_w2       N=1 W2 SoC, functional ports only (syn_soc_w2.sv), with the
#                L2 (heliodor_l2cache) as a black box: its data arrays do not
#                infer RAM (see soc_w2_l2)
#   soc_w2_l2    the same with the L2; fails in elaboration until the L2
#                data arrays are 1R1W
#   core_w2      W2 core alone, functional ports only (syn_core.sv)
#   core_w4      W4 core alone, functional ports only
#   core_w2_obs  W2 core alone, retire/perf/checker outputs kept alive
#   core_w4_obs  W4 core alone, likewise
#   pmp1, pmp3, pmp_if4, pmp_if8
#                one PMP range check, three on one range (r/w/x), and the
#                ifu's 4 or 8 per-word checks (syn_pmp.sv), for costing
#
# Run from the project root after `veryl build` (it reads heliodor.f). No
# HELIODOR_CHK define: the checkers are out of synthesis, as in a real build.
# Vivado needs its license, so run this outside the sandbox. Output goes to
# synth/vivado/out/<target>/ (gitignored).
set -euo pipefail

target=${1:?target}
threads=${2:-2}
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/synth/vivado"
vivado=${VIVADO_BIN:-/storage/eda/tools/xilinx/Vivado/2021.2/bin/vivado}
part=${SYN_PART:-xcku15p-ffve1517-2-e}

case "$target" in
    soc_w2)      top=syn_soc_w2; gen="" ;;
    soc_w2_l2)   top=syn_soc_w2; gen="" ;;
    core_w2)     top=syn_core;   gen="W4=1'b0 OBS=1'b0" ;;
    core_w4)     top=syn_core;   gen="W4=1'b1 OBS=1'b0" ;;
    core_w2_obs) top=syn_core;   gen="W4=1'b0 OBS=1'b1" ;;
    core_w4_obs) top=syn_core;   gen="W4=1'b1 OBS=1'b1" ;;
    pmp1)        top=syn_pmp;    gen="MODE=0" ;;
    pmp3)        top=syn_pmp;    gen="MODE=1" ;;
    pmp_if4)     top=syn_pmp;    gen="MODE=2 GRAN=4" ;;
    pmp_if8)     top=syn_pmp;    gen="MODE=2 GRAN=8" ;;
    *) echo "unknown target $target" >&2; exit 2 ;;
esac

out="$here/out/$target"
mkdir -p "$out"

# The design sources minus the frozen old core, plus the tb packages that the
# generated core_types refers to (cfg_bad, cfg_w4_sb8) and the boot memory map.
files="$out/files.f"
{
    grep '/src/' "$root/heliodor.f" | grep -v '/src/v14/'
    printf '%s\n' "$root/tb/cfg_bad.sv" "$root/tb/cfg_w4_sb8.sv" \
        "$root/tb/tb_platform_pkg.sv" "$here/syn_soc_w2.sv" "$here/syn_core.sv" "$here/syn_pmp.sv"
} > "$files.in"
if [ "$target" = soc_w2 ]; then
    python3 "$here/stub.py" "$root/src/cache/l2cache.sv" heliodor_l2cache \
        > "$out/l2cache_stub.sv"
    sed -i "s|^$root/src/cache/l2cache.sv\$|$out/l2cache_stub.sv|" "$files.in"
fi
python3 "$here/order.py" < "$files.in" > "$files"

cd "$out"
SYN_TOP=$top SYN_GENERICS="$gen" SYN_FILES="$files" SYN_PART=$part \
SYN_OUT="$out" SYN_THREADS=$threads \
    "$vivado" -mode batch -nojournal -log "$out/vivado.log" \
    -source "$here/synth.tcl"
