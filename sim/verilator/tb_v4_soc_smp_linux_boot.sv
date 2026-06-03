// SystemVerilog testbench for test_v4_soc_smp_linux_boot_harness under Verilator.
//
// Definitive RTL cross-check for the N=2 SMP secondary-boot storm. The Veryl
// native simulator shows hart1 (the secondary) taking a spurious load page
// fault on a valid, mapped stack address and a stale store->load in
// handle_exception (ld sp,16(tp) returns garbage right after sd sp,16(tp)),
// driving a trap storm. hart0 (identical RTL) boots fine. This wrapper runs the
// SAME SMP SoC on a real SV simulator: if the secondary boots here, the storm
// is a Veryl-sim multi-instance evaluation bug, not an RTL bug.
//
// The harness owns the firmware ROM + DRAM and streams the kernel UART via
// $write, so this prints the boot log to stdout. Run from the heliodor project
// root ($readmemh paths are relative to it).

`timescale 1ns/1ps

module tb_v4_soc_smp_linux_boot;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r3;
    logic [63:0] r3_h1;
    logic [63:0] pc0;
    logic [63:0] pc1;
    logic [31:0] ret0;
    logic [31:0] ret1;
    logic [31:0] trapc0;
    logic [31:0] trapc1;
    logic [31:0] cy;
    // secondary-stack trace probes
    logic [63:0] h1_sp_ld;
    logic [63:0] h1_tp_ld;
    logic [63:0] sc_pc;
    logic [63:0] sc_val;
    logic [31:0] sc_cy;
    logic [63:0] pf_sp;
    logic [63:0] pf_tp;
    logic [63:0] pf_stval;
    logic        pf_seen;
    logic [63:0] scx_cause;
    logic [63:0] scx_sepc;
    logic [63:0] scx_sscr;
    logic [63:0] fhe_cause;
    logic [63:0] fhe_sscr;

    heliodor_test_v4_soc_smp_linux_boot_harness dut (
        .clk        (clk),
        .rst        (rst),
        .o_pass     (pass),
        .o_r3       (r3),
        .o_r3_h1    (r3_h1),
        .o_pc0      (pc0),
        .o_pc1      (pc1),
        .o_ret0     (ret0),
        .o_ret1     (ret1),
        .o_trapc0   (trapc0),
        .o_trapc1   (trapc1),
        .o_cy       (cy),
        .o_h1_sp_ld (h1_sp_ld),
        .o_h1_tp_ld (h1_tp_ld),
        .o_sc_pc    (sc_pc),
        .o_sc_val   (sc_val),
        .o_sc_cy    (sc_cy),
        .o_pf_sp    (pf_sp),
        .o_pf_tp    (pf_tp),
        .o_pf_stval (pf_stval),
        .o_pf_seen  (pf_seen),
        .o_scx_cause(scx_cause),
        .o_scx_sepc (scx_sepc),
        .o_scx_sscr (scx_sscr),
        .o_fhe_cause(fhe_cause),
        .o_fhe_sscr (fhe_sscr)
        // remaining debug outputs intentionally left unconnected
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Budget past the storm onset (~16.2M cy on the Veryl sim). 40M gives the
    // secondary plenty of room to come online (set_cpu_online) on real RTL.
    localparam int unsigned MAX_CY = 40_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;

        for (int unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass) break;
            if (i % 2_000_000 == 0)
                $display("  [verilator smp] cy=%0d h0_pc=%h h1_pc=%h ret0=%h ret1=%h trap1=%h sc_pc=%h",
                         cy, pc0, pc1, ret0, ret1, trapc1, sc_pc);
        end

        $display("\n[tb_v4_soc_smp_linux_boot] pass=%0b h0_x3=%h h1_x3=%h cy=%0d", pass, r3, r3_h1, cy);
        $display("  h0_pc=%h h1_pc=%h ret0=%h ret1=%h trap0=%h trap1=%h", pc0, pc1, ret0, ret1, trapc0, trapc1);
        $display("  hart1 secondary ld-sp=%h ld-tp=%h", h1_sp_ld, h1_tp_ld);
        $display("  hart1 sp-CORRUPTION: pc=%h val=%h @cy=%0d", sc_pc, sc_val, sc_cy);
        $display("  printk-PF: sp@fault=%h tp@fault=%h stval=%h seen=%0b", pf_sp, pf_tp, pf_stval, pf_seen);
        $display("  CORRUPTING trap: cause=%h sepc=%h sscratch=%h | FIRST he: cause=%h sscr=%h",
                 scx_cause, scx_sepc, scx_sscr, fhe_cause, fhe_sscr);
        if (pass)
            $display("V4 SoC SMP(N=2) LINUX BOOT PASSED on Verilator (SBI shutdown x3==0xAA)");
        else if (sc_pc != 0)
            $display("hart1 STILL CORRUPTED on Verilator (sp-corruption seen) => RTL bug, not sim");
        else
            $display("hart1 did NOT corrupt on Verilator within %0d cy => Veryl-sim multi-instance bug", MAX_CY);
        $finish;
    end
endmodule
