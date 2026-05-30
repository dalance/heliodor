// SystemVerilog testbench for test_v4_linux_boot_harness under Verilator.
//
// Boots the real Linux v5.15 kernel through SBI firmware on the v4 OoO core
// using REAL Verilator RTL semantics (no Veryl JIT cross-module comb
// eval-order artifact). The cosim (tb_cosim_linux) confirmed v4 RTL matches
// the golden v1 core for 448K retires / 900K cy; this run lets v4 boot
// stand-alone past that window toward SBI shutdown (x3 == 0xAA).
//
// The harness streams the kernel UART via $write, so this run prints the
// boot log to stdout. Run from the heliodor project root ($readmemh paths).

`timescale 1ns/1ps

module tb_v4_linux_boot;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r3;
    logic [31:0] cy;
    logic [31:0] ret;
    logic [31:0] lrc;
    logic [31:0] trapcnt;
    logic        lf;
    logic [63:0] lpc;
    logic [63:0] ftpc;
    logic [63:0] fcause;
    logic [63:0] tlpc;
    logic [63:0] tlcause;
    logic [63:0] satp;
    logic [1:0]  priv;
    logic [63:0] pc;
    logic [31:0] uart;
    logic [31:0] ecall;

    heliodor_test_v4_linux_boot_harness dut (
        .clk      (clk),
        .rst      (rst),
        .o_pass   (pass),
        .o_r3     (r3),
        .o_cy     (cy),
        .o_ret    (ret),
        .o_lrc    (lrc),
        .o_trapcnt(trapcnt),
        .o_lf     (lf),
        .o_lpc    (lpc),
        .o_ftpc   (ftpc),
        .o_fcause (fcause),
        .o_tlpc   (tlpc),
        .o_tlcause(tlcause),
        .o_satp   (satp),
        .o_priv   (priv),
        .o_pc     (pc),
        .o_uart   (uart),
        .o_ecall  (ecall)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Cap generous enough for v4 (IPC ~0.50) to reach SBI shutdown; the
    // faster golden v1 finishes ~26M cy, so allow margin. Break on pass.
    // M9.A.311 fault trace: cover the 0x80616198 fault region (~cy24M).
    localparam int unsigned MAX_CY = 28_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        for (int unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass) break;
        end

        $display("\n[tb_v4_linux_boot] pass=%0b x3=%h cy=%0d ret=%0d uart=%0d ecall=%0d trapcnt=%0d",
                 pass, r3, cy, ret, uart, ecall, trapcnt);
        $display("[tb_v4_linux_boot] last_fault lf=%0b lpc=%h | first_trap pc=%h cause=%h | last_trap pc=%h cause=%h",
                 lf, lpc, ftpc, fcause, tlpc, tlcause);
        $display("[tb_v4_linux_boot] satp=%h priv=%0d pc=%h", satp, priv, pc);
        if (pass)
            $display("V4 LINUX BOOT PASSED on Verilator (SBI shutdown x3==0xAA)");
        else
            $display("V4 LINUX BOOT did NOT reach SBI shutdown within %0d cy", MAX_CY);
        $finish;
    end
endmodule
