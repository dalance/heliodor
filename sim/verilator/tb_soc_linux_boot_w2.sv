// SystemVerilog wrapper to run the N=1 SoC Linux 5.15 boot on the new core
// (CORE = W2) on an external SV simulator. Same harness as tb_soc_linux_boot.sv
// with the CORE parameter overridden; mtime runs from the cycle count, as in
// the native test_w2_linux_boot. Polls o_pass (x3==0xAA = SBI shutdown).
// See CLAUDE.md "Running Tests on Verilator" for the build/run commands.

`timescale 1ns/1ps

module tb_soc_linux_boot_w2;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r3;
    logic [31:0] cy;
    logic [31:0] instret;
    logic [63:0] last_pc;

    heliodor_test_soc_linux_boot_harness #(
        .CORE(heliodor_soc_pkg::CoreSel_W2)
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .o_pass   (pass),
        .o_r3     (r3),
        .o_cy     (cy),
        .o_instret(instret),
        .o_last_pc(last_pc)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    localparam longint unsigned MAX_CY = 60_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;
        for (longint unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass) break;
            if (i % 1_000_000 == 0)
                $display("  [verilator W2 N=1] cy=%0d instret=%0d pc=%h r3=%h", cy, instret, last_pc, r3);
        end
        $display("[tb_soc_linux_boot_w2] pass=%0b r3=%h cy=%0d instret=%0d", pass, r3, cy, instret);
        if (pass)
            $display("W2 N=1 LINUX BOOT PASSED on Verilator (SBI shutdown, x3==0xAA)");
        else
            $display("W2 N=1 did NOT reach SBI shutdown within %0d cy", MAX_CY);
        $finish;
    end
endmodule
