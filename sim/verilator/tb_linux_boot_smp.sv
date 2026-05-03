// SystemVerilog testbench for heliodor_test_linux_boot_smp_harness under Verilator.
// 2-hart SMP boot. The harness internally loads firmware + DRAM via $readmemh
// and streams UART output via $write, so this binary must be run from the
// heliodor project root directory.

`timescale 1ns/1ps

module tb_linux_boot_smp;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r3;
    logic [63:0] pc0;
    logic [63:0] pc1;
    logic        h1_kernel_seen;
    logic [31:0] h1_retire_cnt;
    logic        h1_callin;
    logic        h1_notify;
    logic        h1_set_online;
    logic        h1_complete;

    heliodor_test_linux_boot_smp_harness #(.N_HARTS(2)) dut (
        .clk             (clk),
        .rst             (rst),
        .o_pass          (pass),
        .o_dbg_r3        (r3),
        .o_dbg_pc0       (pc0),
        .o_dbg_pc1       (pc1),
        .o_h1_kernel_seen(h1_kernel_seen),
        .o_h1_retire_cnt (h1_retire_cnt),
        .o_h1_callin     (h1_callin),
        .o_h1_notify     (h1_notify),
        .o_h1_set_online (h1_set_online),
        .o_h1_complete   (h1_complete)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        // 60M cycles — same budget as Veryl sim. We're using this to
        // differentiate sim-specific quirks: if Verilator boots all the
        // way to SBI shutdown but Veryl sim doesn't, the bug is in Veryl
        // simulator. If both fail at the same point, the bug is real.
        for (int unsigned i = 0; i < 60_000_000; i++) begin
            @(posedge clk);
            if (pass) break;
        end

        $display("tb_linux_boot_smp: r3=%h pass=%0b h1_callin=%0b h1_notify=%0b h1_set_online=%0b h1_complete=%0b h1_retired=%0d",
                 r3, pass, h1_callin, h1_notify, h1_set_online, h1_complete, h1_retire_cnt);
        if (pass) begin
            $display("Real SMP Linux kernel boot test PASSED");
            $finish;
        end else begin
            $display("Real SMP Linux kernel boot test FAILED (cycle limit reached)");
            $finish;
        end
    end
endmodule
