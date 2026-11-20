// Synthesis top for costing the PMP checker in isolation. MODE 0: one
// pmp_range_check. MODE 1: three on the same range for read, write and
// execute, as mem_pipe and the PTW instantiate them. MODE 2: GRAN pmp_check
// on consecutive words of one fetch block, as ifu instantiates them.
module syn_pmp #(
    parameter int MODE = 0,
    parameter int GRAN = 4
) (
    input  var logic [63:0]                 i_lo,
    input  var logic [63:0]                 i_hi,
    input  var heliodor_csr_pkg::PrivLevel  i_priv,
    input  var logic [63:0]                 i_pmpcfg [2],
    input  var logic [63:0]                 i_pmpaddr [16],
    output var logic [7:0]                  o_fault
);
    if (MODE == 0) begin : g_one
        heliodor_pmp_range_check u_c (.i_lo (i_lo), .i_hi (i_hi), .i_acc (2'd0),
            .i_priv (i_priv), .i_pmpcfg (i_pmpcfg), .i_pmpaddr (i_pmpaddr), .o_fault (o_fault[0]));
        assign o_fault[7:1] = '0;
    end else if (MODE == 1) begin : g_rwx
        for (genvar a = 0; a < 3; a++) begin : g_a
            heliodor_pmp_range_check u_c (.i_lo (i_lo), .i_hi (i_hi), .i_acc (2'(a)),
                .i_priv (i_priv), .i_pmpcfg (i_pmpcfg), .i_pmpaddr (i_pmpaddr), .o_fault (o_fault[a]));
        end
        assign o_fault[7:3] = '0;
    end else begin : g_gran
        for (genvar g = 0; g < GRAN; g++) begin : g_g
            heliodor_pmp_check u_c (.i_addr ({8'd0, i_lo[55:0]} + 64'(g * 4)), .i_acc (2'd2),
                .i_priv (i_priv), .i_pmpcfg (i_pmpcfg), .i_pmpaddr (i_pmpaddr), .o_fault (o_fault[g]));
        end
        if (GRAN < 8) begin : g_pad
            assign o_fault[7:GRAN] = '0;
        end
    end
endmodule
