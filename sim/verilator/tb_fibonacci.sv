// SystemVerilog testbench for heliodor_test_fibonacci_harness under Verilator.
// Harness internally uses $readmemh("test/hex/fibonacci.hex", ...) so this
// binary must be run from the heliodor project root directory.

`timescale 1ns/1ps

module tb_fibonacci;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r1, r2, r3;

    heliodor_test_fibonacci_harness dut (
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
        // async-low reset: assert, hold a few cycles, release
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        // Run for up to 1M cycles (fib(10) finishes in <1000 cycles)
        for (int i = 0; i < 1_000_000; i++) begin
            @(posedge clk);
            if (pass) break;
        end

        $display("tb_fibonacci: r1=%h r2=%h r3=%h pass=%0b", r1, r2, r3, pass);
        if (pass) begin
            $display("Fibonacci test PASSED");
            $finish;
        end else begin
            $display("Fibonacci test FAILED");
            $fatal(1, "tb_fibonacci failure");
        end
    end
endmodule
