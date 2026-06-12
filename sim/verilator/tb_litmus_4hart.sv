// SystemVerilog wrapper to run the P9.0 RVWMO litmus battery (N=4, IRIW
// included) on an external SV simulator. Drives heliodor_test_litmus_harness
// with the 4-hart hex and polls o_pass/o_fail (riscv-tests tohost protocol:
// 1 = pass, even = forbidden outcome / trap). The harness itself dumps the
// outcome histogram when tohost goes non-zero.
// See CLAUDE.md "Running Tests on Verilator" for the build/run commands.

`timescale 1ns/1ps

module tb_litmus_4hart;
    logic        clk;
    logic        rst;
    logic        pass;
    logic        fail;
    logic [31:0] tohost;
    logic [31:0] cy;

    heliodor_test_litmus_harness #(
        .N_HARTS (4),
        .HEX_DRAM("test/litmus/litmus_n4.hex")
    ) dut (
        .clk     (clk),
        .rst     (rst),
        .o_pass  (pass),
        .o_fail  (fail),
        .o_tohost(tohost),
        .o_cy    (cy)
        // o_pc_all / o_ret_all / o_trapc_all left unconnected
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    localparam longint unsigned MAX_CY = 30_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;
        for (longint unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass || fail) break;
            if (i % 1_000_000 == 0)
                $display("  [verilator litmus n4] cy=%0d tohost=%h", cy, tohost);
        end
        $display("[tb_litmus_4hart] pass=%0b fail=%0b tohost=%h cy=%0d", pass, fail, tohost, cy);
        if (pass)
            $display("LITMUS(N=4) PASSED on Verilator (tohost==1)");
        else
            $display("LITMUS(N=4) FAILED on Verilator (tohost=%h: ((test<<8|slot)<<4)|2 = forbidden outcome, (mcause<<8)|0xE0 = trap, 0 = timeout)", tohost);
        $finish;
    end
endmodule
