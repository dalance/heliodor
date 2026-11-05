// SystemVerilog wrapper to run the hypervisor guest-Linux boot on the new
// core (CORE = W4) on an external SV simulator. Drives heliodor_boot_soc_harness
// as the native test_w4_hvlinux does; polls o_pass (guest SBI shutdown,
// x3==0xAA) and o_fail (checker or failure). Build test/hv/hv_dram.hex first
// (make -C test/hv GUEST=Image GUEST_DTB=guest.dtb).
// See CLAUDE.md "Running Tests on Verilator" for the build/run commands.

`timescale 1ns/1ps

module tb_soc_hvlinux_w4;
    logic        clk;
    logic        rst;
    logic        pass;
    logic        fail;
    logic [63:0] x3;
    logic [63:0] cycles;
    logic [63:0] instret;

    heliodor_boot_soc_harness #(
        .FW_HEX  ("test/hv/hvfw.hex"),
        .DRAM_HEX("test/hv/hv_dram.hex"),
        .CORE    (heliodor_soc_pkg::CoreSel_W4)
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

    localparam longint unsigned MAX_CY = 60_000_000;

    initial begin
        rst = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b1;
        for (longint unsigned i = 0; i < MAX_CY; i++) begin
            @(posedge clk);
            if (pass || fail) break;
            if (i % 2_000_000 == 0)
                $display("  [W4 hvlinux] cy=%0d instret=%0d x3=%h", cycles, instret, x3);
        end
        $display("[tb_soc_hvlinux_w4] pass=%0b fail=%0b x3=%h cy=%0d instret=%0d", pass, fail, x3, cycles, instret);
        if (pass)
            $display("W4 HV GUEST BOOT PASSED on Verilator (guest SBI shutdown, x3==0xAA)");
        else
            $display("W4 HV guest did NOT pass within %0d cy (fail=%0b)", MAX_CY, fail);
        $finish;
    end
endmodule
