// SystemVerilog wrapper to run the N=1 (single-hart) SoC Linux boot on an
// external SV simulator (the native Veryl #[test] uses $tb::clock_gen, which is
// Veryl-runtime only). Drives clk/rst, polls o_pass (hart0 x3==0xAA = shutdown).
// See CLAUDE.md "Running Tests on Verilator" for the build/run commands.

`timescale 1ns/1ps

module tb_soc_linux_boot;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r3;
    logic [31:0] cy;

    heliodor_test_soc_linux_boot_harness dut (
        .clk   (clk),
        .rst   (rst),
        .o_pass(pass),
        .o_r3  (r3),
        .o_cy  (cy)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    localparam longint unsigned MAX_CY = 100_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;
        for (longint unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass) break;
            if (i % 5_000_000 == 0)
                $display("  [verilator N=1] cy=%0d r3=%h", cy, r3);
        end
        $display("[tb_soc_linux_boot] pass=%0b r3=%h cy=%0d", pass, r3, cy);
        if (pass)
            $display("N=1 LINUX BOOT PASSED on Verilator (SBI shutdown, x3==0xAA)");
        else
            $display("N=1 did NOT reach SBI shutdown within %0d cy", MAX_CY);
        $finish;
    end
endmodule
