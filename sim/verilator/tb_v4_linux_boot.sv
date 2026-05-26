// SystemVerilog testbench for heliodor_test_v4_linux_boot_harness under Verilator.
// The harness internally loads firmware + DRAM via $readmemh and streams
// UART output via $write, so this binary must be run from the heliodor
// project root directory.

`timescale 1ns/1ps

module tb_v4_linux_boot;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r3;
    int unsigned cy;
    int          logf;

    heliodor_test_v4_linux_boot_harness dut (
        .clk   (clk),
        .rst   (rst),
        .o_pass(pass),
        .o_r3  (r3)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // dmem activity logger: for each ren or wen in DRAM range, log (cy, addr, ren, wen, wdata, rdata).
    // Filter to DRAM (addr[31]=1) to skip firmware/UART/CLINT noise.
    always @(posedge clk) begin
        if (rst) begin
            cy <= cy + 1;
            if (dut.dmem_addr[31] && (dut.dmem_ren || dut.dmem_wen)) begin
                $fdisplay(logf, "%0d %h %b %b %h %h",
                          cy, dut.dmem_addr, dut.dmem_ren, dut.dmem_wen,
                          dut.dmem_wdata, dut.dmem_rdata);
            end
        end
    end

    initial begin
        cy = 0;
        logf = $fopen("/tmp/v4_dmem.log", "w");
        if (logf == 0) $fatal(1, "v4: cannot open log file");
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        for (int unsigned i = 0; i < 5_000_000; i++) begin
            @(posedge clk);
            if (pass) break;
        end

        $fclose(logf);
        $display("tb_v4_linux_boot: r3=%h pass=%0b", r3, pass);
        if (pass) begin
            $display("v4 Real Linux kernel boot test PASSED");
            $finish;
        end else begin
            $display("v4 Real Linux kernel boot test FAILED (logged to /tmp/v4_dmem.log)");
            $finish;
        end
    end
endmodule
