// SystemVerilog testbench for test_cosim_linux_boot_harness under Verilator.
//
// Runs the v1 (golden, in-order) and v4 (OoO) cores in lockstep on the same
// Linux boot hex and compares their retire streams in retire order. Under the
// Veryl JIT simulator this diverges at cy 843663 (a cross-module comb
// eval-order bug in the JIT — a load returns the prior load's data). Under
// the Veryl interpreter it does NOT diverge. This Verilator run uses real RTL
// semantics to independently confirm v4's RTL is correct: diverged=0 over the
// whole window means v4 matches the golden core in actual hardware semantics.
//
// The harness loads firmware + DRAM via $readmemh, so run from the heliodor
// project root.

`timescale 1ns/1ps

module tb_cosim_linux;
    logic        clk;
    logic        rst;
    logic        diverged;
    logic [31:0] compared;
    logic [31:0] v1_pushed;
    logic [31:0] v4_pushed;
    logic [31:0] fd_cy;
    logic [1:0]  fd_kind;
    logic [63:0] fd_v1pc;
    logic [63:0] fd_v4pc;

    heliodor_test_cosim_linux_boot_harness dut (
        .clk            (clk),
        .rst            (rst),
        .o_diverged     (diverged),
        .o_compared_cnt (compared),
        .o_v1_pushed_cnt(v1_pushed),
        .o_v4_pushed_cnt(v4_pushed),
        .o_fd_cy        (fd_cy),
        .o_fd_kind      (fd_kind),
        .o_fd_v1pc      (fd_v1pc),
        .o_fd_v4pc      (fd_v4pc)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    int unsigned diverge_seen_cy;

    initial begin
        diverge_seen_cy = 0;
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        // Match the Veryl tb window (clk.next 900K). Verilator is fast enough
        // to run this in seconds. Keep running ~64 cycles past a first
        // divergence so the harness ring-dump always_ff can fire, then stop.
        for (int unsigned i = 0; i < 900_000; i++) begin
            @(posedge clk);
            if (diverged) begin
                if (diverge_seen_cy == 0) diverge_seen_cy = i;
                if (i > diverge_seen_cy + 64) break;
            end
        end

        $display("[tb_cosim_linux] diverged=%0b compared=%0d v1_pushed=%0d v4_pushed=%0d fd_cy=%0d kind=%0d v1pc=%h v4pc=%h",
                 diverged, compared, v1_pushed, v4_pushed, fd_cy, fd_kind, fd_v1pc, fd_v4pc);
        if (diverged)
            $display("COSIM DIVERGED at cy %0d (v1pc=%h v4pc=%h) -- v4 RTL bug present on Verilator",
                     fd_cy, fd_v1pc, fd_v4pc);
        else
            $display("COSIM MATCH over 900K cy -- v4 RTL CONFIRMED CORRECT on Verilator");
        $finish;
    end
endmodule
