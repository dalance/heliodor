// SystemVerilog wrapper to run the N=4 SMP SoC Linux 5.15 boot on the new
// core (CORE = W2) on an external SV simulator. Drives heliodor_boot_soc_harness
// as the native test_w2_smp_linux_boot_4hart does; polls o_pass (hart 0
// x3==0xAA = SBI shutdown) and o_fail (any hart's checker or failure).
// See CLAUDE.md "Running Tests on Verilator" for the build/run commands.
// AXI_SEL picks the tb AXI4 slave timing (0 FIXED, 1 SLOW, 2 BACKPRESSURE,
// 3 REORDER) and AXI_SEED its seed; set them at build time with -G, e.g.
// -GAXI_SEL=3 -GAXI_SEED=1.

`timescale 1ns/1ps

module tb_soc_smp_linux_boot_4hart_w2 #(
    parameter int unsigned AXI_SEL  = 0,
    parameter int unsigned AXI_SEED = 1
);
    localparam heliodor_axi4_tb_pkg::SlaveCfg AXI_CFG =
        AXI_SEL == 1 ? heliodor_axi4_tb_pkg::SLOW :
        AXI_SEL == 2 ? heliodor_axi4_tb_pkg::BACKPRESSURE :
        AXI_SEL == 3 ? heliodor_axi4_tb_pkg::REORDER : heliodor_axi4_tb_pkg::FIXED;

    logic        clk;
    logic        rst;
    logic        pass;
    logic        fail;
    logic [63:0] x3;
    logic [63:0] cycles;
    logic [63:0] instret;

    heliodor_boot_soc_harness #(
        .N_HARTS (32'd4),
        .FW_HEX  ("test/hex/linux_boot_fw_4hart_mt.hex"),
        .DRAM_HEX("test/hex/linux_dram_real_4hart.hex"),
        .AXI_CFG (AXI_CFG),
        .AXI_SEED(AXI_SEED),
        .CORE    (heliodor_soc_pkg::CoreSel_W2)
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .o_pass   (pass),
        .o_fail   (fail),
        .o_x3     (x3),
        .o_cycles (cycles),
        .o_instret(instret),
        .o_last_pc(),
        .o_ret_cnt(),
        .o_traps  ()
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    localparam longint unsigned MAX_CY = 100_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;
        for (longint unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass || fail) break;
            if (i % 5_000_000 == 0)
                $display("  [W2 N=4] cy=%0d instret=%0d x3=%h", cycles, instret, x3);
        end
        $display("[tb_soc_smp_linux_boot_4hart_w2] axi_sel=%0d seed=%0d pass=%0b fail=%0b x3=%h cy=%0d instret=%0d", AXI_SEL, AXI_SEED, pass, fail, x3, cycles, instret);
        if (pass)
            $display("W2 SMP(N=4) LINUX BOOT PASSED on Verilator (SBI shutdown, x3==0xAA)");
        else
            $display("W2 SMP(N=4) did NOT pass within %0d cy (fail=%0b)", MAX_CY, fail);
        $finish;
    end
endmodule
