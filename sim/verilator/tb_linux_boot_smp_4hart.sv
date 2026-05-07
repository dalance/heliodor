// SystemVerilog testbench for heliodor_test_linux_boot_smp_harness under Verilator.
// 4-hart SMP boot. The harness internally loads firmware + DRAM via $readmemh
// and streams UART output via $write, so this binary must be run from the
// heliodor project root directory.

`timescale 1ns/1ps

module tb_linux_boot_smp_4hart;
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
    logic [63:0] h2_pc;
    logic [31:0] h2_retire_cnt;
    logic        h2_kernel_seen;
    logic [63:0] h3_pc;
    logic [31:0] h3_retire_cnt;
    logic        h3_kernel_seen;

    heliodor_test_linux_boot_smp_harness #(
        .N_HARTS (4),
        .HEX_FW  ("test/hex/linux_boot_fw_4hart.hex"),
        .HEX_DRAM("test/hex/linux_dram_real_4hart.hex")
    ) dut (
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
        .o_h1_complete   (h1_complete),
        .o_h2_pc         (h2_pc),
        .o_h2_retire_cnt (h2_retire_cnt),
        .o_h2_kernel_seen(h2_kernel_seen),
        .o_h3_pc         (h3_pc),
        .o_h3_retire_cnt (h3_retire_cnt),
        .o_h3_kernel_seen(h3_kernel_seen)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        for (int unsigned i = 0; i < 100_000_000; i++) begin
            @(posedge clk);
            if (pass) break;
        end

        $display("tb_linux_boot_smp_4hart: r3=%h pass=%0b h1_complete=%0b h1_retired=%0d h2_kseen=%0b h2_retired=%0d h3_kseen=%0b h3_retired=%0d",
                 r3, pass, h1_complete, h1_retire_cnt, h2_kernel_seen, h2_retire_cnt, h3_kernel_seen, h3_retire_cnt);
        if (pass) begin
            $display("4-hart SMP Linux kernel boot test PASSED");
            $finish;
        end else begin
            $display("4-hart SMP Linux kernel boot test FAILED (cycle limit reached)");
            $finish;
        end
    end
endmodule
