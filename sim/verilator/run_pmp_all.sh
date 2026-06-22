#!/usr/bin/env bash
# Build + run every ACT4 PMPS test on Verilator (the Veryl cc/cranelift sim
# hangs on the PMP-active M-mode cleanup — a sim convergence artifact; the RTL
# settles correctly under real SV NBA). One wrapper, re-templated per hex.
set -u
cd "$(dirname "$0")/../.."
TESTS=(pmps_cfg_A_off pmps_cfg_XWR pmps_csr_access pmps_mprv_check_01 \
       pmps_mprv_check_02 pmps_napot_legal_lxwr_01 pmps_napot_legal_lxwr_02 \
       pmps_tor_legal_lxwr_01 pmps_tor_legal_lxwr_02)
W=sim/verilator/tb_act_pmps_gen.sv
for t in "${TESTS[@]}"; do
  cat > "$W" <<EOF
\`timescale 1ns/1ps
module tb_act_pmps_gen;
  logic clk; logic rst; logic pass; logic fail; logic [31:0] tohost;
  heliodor_test_arch_common_harness #(.HEX_FILE("test/hex/act_pmps_${t}.hex"), .TOHOST_IDX(1024)) dut
    (.clk(clk), .rst(rst), .o_pass(pass), .o_fail(fail), .o_tohost(tohost));
  initial clk = 1'b0; always #5 clk = ~clk;
  initial begin
    rst = 1'b0; repeat (4) @(posedge clk); rst = 1'b1;
    for (longint unsigned i = 0; i < 2000000; i++) begin
      @(posedge clk); if (pass || fail) break;
    end
    \$display("PMPRESULT ${t} pass=%0b fail=%0b tohost=%h", pass, fail, tohost);
    \$finish;
  end
endmodule
EOF
  rm -rf sim/verilator/build_gen
  verilator --binary --top-module tb_act_pmps_gen -f heliodor.f "$W" \
    --timing -Wno-fatal -O3 --Mdir sim/verilator/build_gen -o tb_act_pmps_gen \
    > /dev/null 2>&1
  if [ -x sim/verilator/build_gen/tb_act_pmps_gen ]; then
    timeout 300 sim/verilator/build_gen/tb_act_pmps_gen 2>&1 | grep -E "PMPRESULT|RVCP-SUMMARY"
  else
    echo "PMPRESULT ${t} BUILD_FAILED"
  fi
done
rm -f "$W"
