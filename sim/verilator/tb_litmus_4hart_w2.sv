// SystemVerilog wrapper to run the RVWMO litmus battery (N=4) on the new core
// (CORE = W2) on an external SV simulator. Drives heliodor_boot_soc_harness as
// the native test_w2_litmus_4hart does (no ROM, MAP_ARCH, tohost protocol:
// 1 = pass, anything else = forbidden outcome / trap).
// See CLAUDE.md "Running Tests on Verilator" for the build/run commands.

`timescale 1ns/1ps

module tb_litmus_4hart_w2;
    logic        clk;
    logic        rst;
    logic        pass;
    logic        fail;
    logic [63:0] cycles;

    heliodor_boot_soc_harness #(
        .N_HARTS    (32'd4),
        .DRAM_HEX   ("test/litmus/litmus_n4.hex"),
        .ROM_EN     (1'b0),
        .PMA_N      (heliodor_tb_platform_pkg::MAP_ARCH_N),
        .PMA_REGIONS(heliodor_tb_platform_pkg::MAP_ARCH),
        .RESET_PC   (64'h8000_0000),
        .PASS_BY_X3 (1'b0),
        .TOHOST_PA  (64'h8000_1000),
        .CORE       (heliodor_soc_pkg::CoreSel_W2)
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .o_pass   (pass),
        .o_fail   (fail),
        .o_x3     (),
        .o_cycles (cycles),
        .o_instret(),
        .o_last_pc(),
        .o_ret_cnt(),
        .o_traps  ()
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
                $display("  [W2 litmus N=4] cy=%0d", cycles);
        end
        $display("[tb_litmus_4hart_w2] pass=%0b fail=%0b cy=%0d", pass, fail, cycles);
        if (pass)
            $display("W2 LITMUS(N=4) PASSED on Verilator (tohost==1)");
        else
            $display("W2 LITMUS(N=4) FAILED or timed out on Verilator (fail=%0b)", fail);
        $finish;
    end
endmodule
