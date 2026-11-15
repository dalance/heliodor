// SystemVerilog wrapper for structural coverage runs of arch-harness images
// on the W2 core: one binary serves every image, because the harness reads
// cur.hex from the working directory at time 0 (run_cov.py copies each image
// there). Polls o_pass/o_fail like the native wrappers; the cycle budget is
// the +budget= plusarg.

`timescale 1ns/1ps

module tb_cov_arch_w2;
    parameter int unsigned TOHOST_IDX = 1024;

    logic        clk;
    logic        rst;
    logic        pass;
    logic        fail;
    logic [31:0] tohost;

    heliodor_test_arch_common_harness #(
        .HEX_FILE  ("cur.hex"),
        .TOHOST_IDX(TOHOST_IDX),
        .CORE      (heliodor_soc_pkg::CoreSel_W2)
    ) dut (
        .clk     (clk),
        .rst     (rst),
        .o_pass  (pass),
        .o_fail  (fail),
        .o_tohost(tohost)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    longint unsigned budget;
    longint unsigned cy;

    initial begin
        if (!$value$plusargs("budget=%d", budget)) budget = 2_000_000;
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;
        for (cy = 0; cy < budget; cy++) begin
            @(posedge clk);
            if (pass || fail) break;
        end
        $display("COVRESULT pass=%0b fail=%0b tohost=%h cy=%0d", pass, fail, tohost, cy);
        $finish;
    end
endmodule
