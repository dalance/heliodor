// SystemVerilog wrapper to run the N=8 SMP SoC Linux boot on an external SV
// simulator. Drives the shared SMP harness with N_HARTS=8 + the 8-hart hex
// assets and polls o_pass (hart0 x3==0xAA = SBI shutdown); the per-hart liveness
// arrays are left unconnected.
// See CLAUDE.md "Running Tests on Verilator" for the build/run commands.

`timescale 1ns/1ps

module tb_soc_smp_linux_boot_8hart;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r3;
    logic [31:0] cy;

    heliodor_test_soc_smp_linux_boot_harness #(
        .N_HARTS (8),
        .HEX_FW  ("test/hex/linux_boot_fw_8hart.hex"),
        .HEX_DRAM("test/hex/linux_dram_real_8hart.hex")
    ) dut (
        .clk   (clk),
        .rst   (rst),
        .o_pass(pass),
        .o_r3  (r3),
        .o_cy  (cy)
        // o_r3_h1 / o_pc* / o_ret* / o_trapc* / o_*_all left unconnected
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
                $display("  [verilator N=8] cy=%0d r3=%h", cy, r3);
        end
        $display("[tb_soc_smp_linux_boot_8hart] pass=%0b r3=%h cy=%0d", pass, r3, cy);
        if (pass)
            $display("SMP(N=8) LINUX BOOT PASSED on Verilator (SBI shutdown, x3==0xAA)");
        else
            $display("SMP(N=8) did NOT reach SBI shutdown within %0d cy", MAX_CY);
        $finish;
    end
endmodule
