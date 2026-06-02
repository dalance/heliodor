// SystemVerilog testbench for test_v4_soc_linux_boot_harness under Verilator.
//
// Boots the real Linux v5.15 kernel through heliodor_soc_v4 (M8.D: v4 OoO core
// + internal CLINT/UART + L2 + memory_bus(N=1) DRAM arbiter) using REAL RTL
// semantics. The Veryl JIT simulator mis-orders the cross-module grant feedback
// (core o_dmem_req -> memory_bus -> core i_dmem_grant) and hangs; real RTL
// evaluates the combinational path correctly, so this run proves the M8.D.3 RTL
// boots when grant comes from the real bus arbiter (not tied high).
//
// The harness streams the kernel UART via $write, so this prints the boot log
// to stdout. Run from the heliodor project root ($readmemh paths).

`timescale 1ns/1ps

module tb_v4_soc_linux_boot;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r3;
    logic [31:0] cy;

    heliodor_test_v4_soc_linux_boot_harness dut (
        .clk   (clk),
        .rst   (rst),
        .o_pass(pass),
        .o_r3  (r3),
        .o_cy  (cy)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Same budget as the Veryl sim run (45M cy) plus margin.
    localparam int unsigned MAX_CY = 50_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        for (int unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass) break;
        end

        $display("\n[tb_v4_soc_linux_boot] pass=%0b x3=%h cy=%0d", pass, r3, cy);
        if (pass)
            $display("V4 SoC LINUX BOOT PASSED on Verilator (SBI shutdown x3==0xAA)");
        else
            $display("V4 SoC LINUX BOOT did NOT reach SBI shutdown within %0d cy", MAX_CY);
        $finish;
    end
endmodule
