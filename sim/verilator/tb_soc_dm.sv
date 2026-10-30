// SystemVerilog wrapper that puts the new-core SoC with its Debug Module
// (heliodor_gdb_soc_harness) behind the tb-only JTAG DTM (jtag_dtm.sv) and an
// OpenOCD remote_bitbang server (rbb_dpi.c), for the riscv-tests debug suite
// (test/debug/run_gg.sh, gdbserver.py). Build-time parameters (-G):
//   N_HARTS  harts (1 or 4)
//   W4       0: CORE = W2, 1: CORE = W4
//   AXI_SEL  tb AXI4 slave timing (0 FIXED, 1 SLOW, 2 BACKPRESSURE, 3 REORDER)
// Plusargs: +rbb_port=<n> (default 0: a free port, printed on stdout).
// The run ends when the debugger quits ('Q' or a closed connection) or a
// checker fires; either way the firing counters are dumped first, and a
// checker failure exits with status 1 ($fatal).

`timescale 1ns/1ps

module tb_soc_dm #(
    parameter int unsigned N_HARTS  = 1,
    parameter int unsigned W4       = 0,
    parameter int unsigned AXI_SEL  = 0,
    parameter int unsigned AXI_SEED = 1
);
    import "DPI-C" function int rbb_init(input int port);
    import "DPI-C" function int rbb_tick(input int tdo, output int tck, output int tms,
                                         output int tdi, output int trst);

    localparam heliodor_axi4_tb_pkg::SlaveCfg AXI_CFG =
        AXI_SEL == 1 ? heliodor_axi4_tb_pkg::SLOW :
        AXI_SEL == 2 ? heliodor_axi4_tb_pkg::BACKPRESSURE :
        AXI_SEL == 3 ? heliodor_axi4_tb_pkg::REORDER : heliodor_axi4_tb_pkg::FIXED;
    localparam heliodor_soc_pkg::CoreSel CORE =
        W4 != 0 ? heliodor_soc_pkg::CoreSel_W4 : heliodor_soc_pkg::CoreSel_W2;

    logic        clk;
    logic        rst;
    logic        tck, tms, tdi, trst, tdo;
    logic        psel, penable, pwrite, pready, pslverr;
    logic [8:0]  paddr;
    logic [31:0] pwdata, prdata;
    logic [3:0]  pstrb;
    logic [63:0] dmi_n;
    logic        dump;
    logic        fail;
    logic [N_HARTS-1:0] fail_h;
    logic [63:0] instret;
    logic [13+heliodor_soc_pkg::CHK_W+heliodor_retire_pkg::CHK_RET_W:0] chk;

    heliodor_gdb_soc_harness #(
        .N_HARTS (N_HARTS),
        .CORE    (CORE),
        .AXI_CFG (AXI_CFG),
        .AXI_SEED(AXI_SEED)
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .i_psel   (psel),
        .i_penable(penable),
        .i_pwrite (pwrite),
        .i_paddr  (paddr),
        .i_pwdata (pwdata),
        .i_pstrb  (pstrb),
        .o_pready (pready),
        .o_prdata (prdata),
        .o_pslverr(pslverr),
        .i_dump   (dump),
        .o_fail   (fail),
        .o_fail_h (fail_h),
        .o_chk    (chk),
        .o_instret(instret)
    );

    jtag_dtm u_dtm (
        .clk    (clk),
        .rst_n  (rst),
        .tck    (tck),
        .tms    (tms),
        .tdi    (tdi),
        .trst   (trst),
        .tdo    (tdo),
        .psel   (psel),
        .penable(penable),
        .pwrite (pwrite),
        .paddr  (paddr),
        .pwdata (pwdata),
        .pstrb  (pstrb),
        .pready (pready),
        .prdata (prdata),
        .pslverr(pslverr),
        .dmi_n  (dmi_n)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    longint unsigned cy;
    logic            en;
    logic            quit;

    // One pin change per cycle, between rising edges of clk, so the DTM
    // samples one stable value per cycle.
    always @(negedge clk) begin
        if (en && !quit) begin
            int rc, p_tck, p_tms, p_tdi, p_trst;
            rc = rbb_tick(int'(tdo), p_tck, p_tms, p_tdi, p_trst);
            if (rc == 2) quit = 1'b1;
            tck  <= p_tck[0];
            tms  <= p_tms[0];
            tdi  <= p_tdi[0];
            trst <= p_trst[0];
        end
    end

    initial begin
        int port;
        if (!$value$plusargs("rbb_port=%d", port)) port = 0;
        en   = 1'b0;
        quit = 1'b0;
        tck  = 1'b0;
        tms  = 1'b1;
        tdi  = 1'b0;
        trst = 1'b0;
        dump = 1'b0;
        cy   = 0;
        $display("[tb_soc_dm] N_HARTS=%0d W4=%0d axi_sel=%0d", N_HARTS, W4, AXI_SEL);
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;
        void'(rbb_init(port));
        en = 1'b1;
        forever begin
            @(posedge clk);
            cy++;
            if (quit || fail) break;
        end
        dump = 1'b1;
        repeat (4) @(posedge clk);
        $display("[tb_soc_dm] end cy=%0d dmi=%0d instret0=%0d quit=%0d fail=%0b fail_h=%b chk=%h",
                 cy, dmi_n, instret, quit, fail, fail_h, chk);
        if (fail) $fatal(1, "tb_soc_dm: checker failure");
        $finish;
    end
endmodule
