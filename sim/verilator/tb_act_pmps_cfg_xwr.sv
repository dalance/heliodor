// SystemVerilog wrapper to run the ACT4 PMPS cfg_XWR test on the SV sim.
// Classifies whether the cc/cranelift Veryl-sim hang on PMP-active M-mode
// cleanup is a real RTL issue or a sim-convergence artifact (standard SV NBA
// settling here). Drives clk/rst, polls o_pass / o_tohost. Build via the
// standard --binary flow (see CLAUDE.md), top module tb_act_pmps_cfg_xwr.

`timescale 1ns/1ps

module tb_act_pmps_cfg_xwr;
    logic        clk;
    logic        rst;
    logic        pass;
    logic        fail;
    logic [31:0] tohost;

    heliodor_test_arch_common_harness #(
        .HEX_FILE  ("test/hex/act_pmps_pmps_cfg_XWR.hex"),
        .TOHOST_IDX(1024)
    ) dut (
        .clk     (clk),
        .rst     (rst),
        .o_pass  (pass),
        .o_fail  (fail),
        .o_tohost(tohost)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    localparam longint unsigned MAX_CY = 2_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;
        for (longint unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass || fail) break;
            if (i % 200_000 == 0)
                $display("  [verilator pmp] cy=%0d tohost=%h", i, tohost);
        end
        $display("[tb_act_pmps_cfg_xwr] pass=%0b fail=%0b tohost=%h", pass, fail, tohost);
        if (pass)
            $display("ACT4 PMPS cfg_XWR PASSED on Verilator (tohost==1)");
        else
            $display("ACT4 PMPS cfg_XWR did NOT pass (tohost=%h)", tohost);
        $finish;
    end
endmodule
