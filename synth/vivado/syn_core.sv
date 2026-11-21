// Synthesis top: one core (W2 or W4) with the boot memory map. With OBS = 0
// only the functional ports are kept: the retire, perf and checker outputs
// are left open and the schedule-replay inputs tied off, so synthesis prunes
// logic that only feeds them. OBS = 1 keeps all of it alive (every
// observation bit reaches o_obs through an XOR tree, the replay inputs are
// ports), which is what a top that exports those ports costs. Without the
// HELIODOR_OBS define (the synthesis build) those outputs are 0 in the core
// and the two settings come out the same.
module syn_core #(
    parameter bit W4  = 1'b1,
    parameter bit OBS = 1'b0
) (
    input  var logic          clk,
    input  var logic          rst,
    input  var logic          i_dc_rst,
    input  var logic [7:0]    i_hart_id,
    input  var logic [63:0]   i_reset_pc,
    output var logic [63:0]   o_dmem_addr,
    output var logic          o_dmem_ren,
    output var logic          o_dmem_req,
    output var logic          o_dmem_rfo,
    output var logic          o_dmem_dram,
    output var logic          o_dmem_cmo,
    input  var logic          i_dmem_grant,
    input  var logic [63:0]   i_dmem_rdata,
    input  var logic          i_dmem_fill_excl,
    output var logic [63:0]   o_imemr_addr,
    output var logic          o_imemr_req,
    output var logic          o_imemr_dram,
    output var logic          o_imemr_iread,
    input  var logic          i_imemr_grant,
    input  var logic [63:0]   i_imemr_rdata,
    output var logic [63:0]   o_dmemw_addr,
    output var logic [63:0]   o_dmem_wdata [8],
    output var logic [7:0]    o_dmem_wstrb [8],
    output var logic          o_dmem_wen,
    output var logic          o_dmemw_wb,
    output var logic          o_dmemw_req,
    input  var logic          i_dmemw_grant,
    input  var logic          i_probe_v,
    input  var logic [63:0]   i_probe_addr,
    input  var logic          i_probe_self,
    output var logic          o_probe_ack,
    input  var logic          i_inv_v,
    input  var logic [63:0]   i_inv_addr,
    input  var logic          i_inv2_v,
    input  var logic [63:0]   i_inv2_addr,
    input  var logic          i_irq_timer_m,
    input  var logic          i_irq_sw_m,
    input  var logic          i_irq_ext_m,
    input  var logic          i_irq_ext_s,
    input  var logic [63:0]   i_mtime,
    input  var logic          i_dm_haltreq,
    input  var logic [63:0]   i_dm_halt_pc,
    input  var logic [63:0]   i_dm_exc_pc,
    output var logic          o_dm_stoptime,
    input  var logic          i_dm_hartreset,
    output var logic          o_dm_quiet,
    input  var logic          i_dbg_retire_limit_en,
    input  var logic [63:0]   i_dbg_retire_limit,
    input  var logic          i_dbg_irq_mask,
    input  var logic          i_dbg_irq_allow,
    output var logic          o_obs
);
    localparam int CW = W4 ? heliodor_cfg_w4::COMMIT_W : heliodor_cfg_w2::COMMIT_W;
    heliodor_retire_pkg::RetireRec ret [CW];
    heliodor_retire_pkg::IrqEvent  irq_evt;
    logic                          ret_dm;
    logic                          lim_en, irq_mask, irq_allow;
    logic [63:0]                   lim;
    assign lim_en    = OBS ? i_dbg_retire_limit_en : 1'b0;
    assign lim       = OBS ? i_dbg_retire_limit : 64'd0;
    assign irq_mask  = OBS ? i_dbg_irq_mask : 1'b0;
    assign irq_allow = OBS ? i_dbg_irq_allow : 1'b0;
    logic obs_ret, obs_pc;
    always_comb begin
        obs_ret = ^irq_evt ^ ret_dm;
        for (int i = 0; i < CW; i++) obs_ret ^= ^ret[i];
    end
    assign o_obs = OBS ? (obs_ret ^ obs_pc) : 1'b0;
`define SYN_CORE_PORTS \
        .clk (clk), .rst (rst), .i_dc_rst (i_dc_rst), \
        .i_hart_id (i_hart_id), .i_reset_pc (i_reset_pc), \
        .o_dmem_addr (o_dmem_addr), .o_dmem_ren (o_dmem_ren), \
        .o_dmem_req (o_dmem_req), .o_dmem_rfo (o_dmem_rfo), \
        .o_dmem_dram (o_dmem_dram), .o_dmem_cmo (o_dmem_cmo), \
        .i_dmem_grant (i_dmem_grant), \
        .i_dmem_rdata (i_dmem_rdata), .i_dmem_fill_excl (i_dmem_fill_excl), \
        .o_imemr_addr (o_imemr_addr), .o_imemr_req (o_imemr_req), \
        .o_imemr_dram (o_imemr_dram), .o_imemr_iread (o_imemr_iread), \
        .i_imemr_grant (i_imemr_grant), .i_imemr_rdata (i_imemr_rdata), \
        .o_dmemw_addr (o_dmemw_addr), .o_dmem_wdata (o_dmem_wdata), \
        .o_dmem_wstrb (o_dmem_wstrb), .o_dmem_wen (o_dmem_wen), \
        .o_dmemw_wb (o_dmemw_wb), .o_dmemw_req (o_dmemw_req), \
        .i_dmemw_grant (i_dmemw_grant), \
        .i_probe_v (i_probe_v), .i_probe_addr (i_probe_addr), \
        .i_probe_self (i_probe_self), .o_probe_ack (o_probe_ack), \
        .i_inv_v (i_inv_v), .i_inv_addr (i_inv_addr), \
        .i_inv2_v (i_inv2_v), .i_inv2_addr (i_inv2_addr), \
        .i_irq_timer_m (i_irq_timer_m), .i_irq_sw_m (i_irq_sw_m), \
        .i_irq_ext_m (i_irq_ext_m), .i_irq_ext_s (i_irq_ext_s), \
        .i_mtime (i_mtime), \
        .o_retire (ret), .o_irq_evt (irq_evt), .o_retire_dm (ret_dm), \
        .i_dm_haltreq (i_dm_haltreq), .i_dm_halt_pc (i_dm_halt_pc), \
        .i_dm_exc_pc (i_dm_exc_pc), .o_dm_stoptime (o_dm_stoptime), \
        .i_dm_hartreset (i_dm_hartreset), .o_dm_quiet (o_dm_quiet), \
        .i_dbg_retire_limit_en (lim_en), .i_dbg_retire_limit (lim), \
        .i_dbg_irq_mask (irq_mask), .i_dbg_irq_allow (irq_allow), \
        .o_perf (perf), .o_chk (chk)
    if (W4) begin : g_w4
        heliodor___core_types__cfg_w4::CorePerf perf;
        heliodor___core_types__cfg_w4::CoreChk  chk;
        assign obs_pc = ^perf ^ ^chk;
        heliodor_heliodor_core_w4 #(
            .PMA_N       (heliodor_tb_platform_pkg::MAP_BOOT_N),
            .PMA_REGIONS (heliodor_tb_platform_pkg::MAP_BOOT)
        ) u_core (`SYN_CORE_PORTS);
    end else begin : g_w2
        heliodor___core_types__cfg_w2::CorePerf perf;
        heliodor___core_types__cfg_w2::CoreChk  chk;
        assign obs_pc = ^perf ^ ^chk;
        heliodor_heliodor_core_w2 #(
            .PMA_N       (heliodor_tb_platform_pkg::MAP_BOOT_N),
            .PMA_REGIONS (heliodor_tb_platform_pkg::MAP_BOOT)
        ) u_core (`SYN_CORE_PORTS);
    end
`undef SYN_CORE_PORTS
endmodule
