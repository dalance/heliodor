// SystemVerilog testbench for heliodor_test_alu_harness under Verilator.
// Drives clock and async-low reset, polls o_done, reports o_pass.

`timescale 1ns/1ps

module tb_alu;
    logic       clk;
    logic       rst;
    logic       pass;
    logic       done;
    logic [7:0] tc;

    heliodor_test_alu_harness dut (
        .clk   (clk),
        .rst   (rst),
        .o_pass(pass),
        .o_done(done),
        .o_tc  (tc)
    );

    // Clock: 100 MHz (10 ns period)
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        // async-low reset asserted, deassert after a few cycles
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        // Wait for done or timeout (1 M cycles)
        for (int i = 0; i < 1_000_000; i++) begin
            @(posedge clk);
            if (done) break;
        end

        $display("tb_alu: done=%0b pass=%0b tc=%0d", done, pass, tc);
        if (done && pass) begin
            $display("ALU test PASSED");
            $finish;
        end else begin
            $display("ALU test FAILED");
            $fatal(1, "tb_alu failure");
        end
    end
endmodule
