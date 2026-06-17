// SystemVerilog wrapper to cross-check the P11-H5.2b hypervisor guest-Linux boot
// on an independent SV simulator with standard NBA semantics — the companion to
// tb_soc_linux_boot.sv etc. for the V=1 hypervisor path. cc and cranelift share
// the Veryl front-end, so this fully independent flow guards against Veryl-sim
// artifacts (it was instrumental in confirming the blocker-1 two-stage o_fault
// hazard was real RTL, not a sim quirk).
//
// The harness loads test/hv/{hvfw.hex,hv_dram.hex} itself ($readmemh) and echoes
// the guest/hypervisor UART ($write), so the result is read straight from the
// console: a healthy boot prints the kernel banner, reaches userspace, and ends
// with "[HV] guest issued SBI system_reset (shutdown)" -> pass (x3==0xAA).
//
// Build/run from the project root (so the $readmemh paths resolve) with the same
// recipe the other tb_soc_*_boot.sv wrappers use (CLAUDE.md, section "Running
// Tests on Verilator"; set --top-module tb_soc_hvlinux). Build the DRAM image
// first:  make -C test/hv GUEST=Image GUEST_DTB=guest.dtb

`timescale 1ns/1ps

module tb_soc_hvlinux;
    logic        clk;
    logic        rst;
    logic        pass;
    logic [63:0] r3;
    logic [31:0] cy;

    heliodor_test_soc_hvlinux_harness dut (
        .clk   (clk),
        .rst   (rst),
        .o_pass(pass),
        .o_r3  (r3),
        .o_cy  (cy)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    localparam longint unsigned MAX_CY = 40_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;
        for (longint unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass) break;
            if (i % 2_000_000 == 0)
                $display("  [verilator hvlinux] cy=%0d r3=%h", cy, r3);
        end
        $display("[tb_soc_hvlinux] pass=%0b r3=%h cy=%0d", pass, r3, cy);
        if (pass)
            $display("HV GUEST BOOT PASSED on Verilator (guest SBI shutdown, x3==0xAA)");
        else
            $display("HV guest did NOT reach SBI shutdown within %0d cy", MAX_CY);
        $finish;
    end
endmodule
