// SystemVerilog testbench for heliodor_test_linux_boot_harness under Verilator.
// The harness internally loads firmware + DRAM via $readmemh and streams
// UART output via $write, so this binary must be run from the heliodor
// project root directory.

`timescale 1ns/1ps

module tb_linux_boot;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r1, r2, r3;

    heliodor_test_linux_boot_harness dut (
        .clk   (clk),
        .rst   (rst),
        .o_pass(pass),
        .o_r1  (r1),
        .o_r2  (r2),
        .o_r3  (r3)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        // Linux boot completes around 31M cycles; give 60M as headroom.
        for (int unsigned i = 0; i < 60_000_000; i++) begin
            @(posedge clk);
            if (pass) break;
        end

        $display("tb_linux_boot: r1=%h r2=%h r3=%h pass=%0b", r1, r2, r3, pass);
        if (pass) begin
            $display("Real Linux kernel boot test PASSED");
            $finish;
        end else begin
            $display("Real Linux kernel boot test FAILED");
            $fatal(1, "tb_linux_boot failure");
        end
    end
endmodule
