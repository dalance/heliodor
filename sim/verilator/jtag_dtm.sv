// Testbench-only JTAG Debug Transport Module (Debug Spec 1.0, section 6) in
// front of the SoC's APB DMI port. Not part of the design: the integrator
// supplies its own DTM.
//
// The JTAG pins come from rbb_dpi.c (OpenOCD remote_bitbang) one pin write
// per clk cycle, so a TCK edge is a clk cycle and TCK runs at half the clk
// frequency at most. As in spike's jtag_dtm, TMS and TDI are sampled and the
// TAP state advances on the rising edge of TCK, and TDO, Capture-DR,
// Update-DR and Update-IR act on the falling edge.
//
// IR is 5 bits: IDCODE 0x01, DTMCS 0x10, DMI 0x11, BYPASS 0x1f (and every
// other value). dtmcs reports version 1 (1.0), abits 7 and idle IDLE_HINT.
// A DMI read or write runs as one APB transfer; a DMI scan captured while it
// is in flight returns busy (op 3) and makes dmistat sticky busy until
// dtmcs.dmireset or dmihardreset. pslverr reports op 2 (failed).

`timescale 1ns/1ps

module jtag_dtm #(
    parameter logic [31:0] IDCODE    = 32'h1000_0a03,
    parameter int unsigned IDLE_HINT = 1
) (
    input  logic        clk,
    input  logic        rst_n,
    // JTAG pins (levels, updated at most once per clk cycle)
    input  logic        tck,
    input  logic        tms,
    input  logic        tdi,
    input  logic        trst,
    output logic        tdo,
    // APB4 master to the DMI port
    output logic        psel,
    output logic        penable,
    output logic        pwrite,
    output logic [8:0]  paddr,
    output logic [31:0] pwdata,
    output logic [3:0]  pstrb,
    input  logic        pready,
    input  logic [31:0] prdata,
    input  logic        pslverr,
    // DMI accesses completed, for the wrapper's statistics
    output logic [63:0] dmi_n
);
    localparam int ABITS = 7;
    localparam int DMI_W = ABITS + 34;

    typedef enum logic [3:0] {
        TLR, RTI, SEL_DR, CAP_DR, SH_DR, EX1_DR, PA_DR, EX2_DR, UPD_DR,
        SEL_IR, CAP_IR, SH_IR, EX1_IR, PA_IR, EX2_IR, UPD_IR
    } tap_e;

    localparam logic [4:0] IR_IDCODE = 5'h01;
    localparam logic [4:0] IR_DTMCS  = 5'h10;
    localparam logic [4:0] IR_DMI    = 5'h11;

    tap_e             st;
    logic             tck_q;
    logic [4:0]       ir, ir_sh;
    logic [DMI_W-1:0] dr;
    logic [5:0]       dr_len;
    logic             tdo_q;
    logic [1:0]       sticky;    // dmistat: 0 ok, 2 failed, 3 busy
    logic [DMI_W-1:0] dmi_res;   // {addr, data, op status} of the last access

    // APB master
    typedef enum logic [1:0] { A_IDLE, A_SETUP, A_ACCESS } apb_e;
    apb_e        ast;
    logic        a_wr;
    logic [6:0]  a_addr;
    logic [31:0] a_data;

    wire rise = tck && !tck_q;
    wire fall = !tck && tck_q;
    wire busy = ast != A_IDLE;

    function automatic tap_e next_st(tap_e s, logic m);
        case (s)
            TLR:    return m ? TLR    : RTI;
            RTI:    return m ? SEL_DR : RTI;
            SEL_DR: return m ? SEL_IR : CAP_DR;
            CAP_DR: return m ? EX1_DR : SH_DR;
            SH_DR:  return m ? EX1_DR : SH_DR;
            EX1_DR: return m ? UPD_DR : PA_DR;
            PA_DR:  return m ? EX2_DR : PA_DR;
            EX2_DR: return m ? UPD_DR : SH_DR;
            UPD_DR: return m ? SEL_DR : RTI;
            SEL_IR: return m ? TLR    : CAP_IR;
            CAP_IR: return m ? EX1_IR : SH_IR;
            SH_IR:  return m ? EX1_IR : SH_IR;
            EX1_IR: return m ? UPD_IR : PA_IR;
            PA_IR:  return m ? EX2_IR : PA_IR;
            EX2_IR: return m ? UPD_IR : SH_IR;
            default: return m ? SEL_DR : RTI;   // UPD_IR
        endcase
    endfunction

    wire [31:0] dtmcs = {14'd0, 3'(IDLE_HINT), sticky, 6'(ABITS), 4'd1};

    assign tdo = tdo_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= TLR;
            tck_q   <= 1'b0;
            ir      <= IR_IDCODE;
            ir_sh   <= 5'd0;
            dr      <= '0;
            dr_len  <= 6'd1;
            tdo_q   <= 1'b0;
            sticky  <= 2'd0;
            dmi_res <= '0;
            ast     <= A_IDLE;
            a_wr    <= 1'b0;
            a_addr  <= 7'd0;
            a_data  <= 32'd0;
            psel    <= 1'b0;
            penable <= 1'b0;
            dmi_n   <= 64'd0;
        end else begin
            tck_q <= tck;

            // APB: SETUP for one cycle, then ACCESS until pready.
            case (ast)
                A_SETUP: begin
                    penable <= 1'b1;
                    ast     <= A_ACCESS;
                end
                A_ACCESS: if (pready) begin
                    psel    <= 1'b0;
                    penable <= 1'b0;
                    ast     <= A_IDLE;
                    dmi_n   <= dmi_n + 64'd1;
                    dmi_res[1:0] <= pslverr ? 2'd2 : 2'd0;
                    if (!a_wr) dmi_res[33:2] <= prdata;
                    if (pslverr && sticky == 2'd0) sticky <= 2'd2;
                end
                default: ;
            endcase

            if (trst) begin
                st <= TLR;
                ir <= IR_IDCODE;
            end else if (rise) begin
                case (st)
                    SH_DR: dr <= (dr >> 1) | (DMI_W'(tdi) << (dr_len - 6'd1));
                    CAP_IR: ir_sh <= 5'b00001;
                    SH_IR: ir_sh <= {tdi, ir_sh[4:1]};
                    default: ;
                endcase
                st <= next_st(st, tms);
            end else if (fall) begin
                case (st)
                    TLR: ir <= IR_IDCODE;
                    CAP_DR: begin
                        case (ir)
                            IR_IDCODE: begin dr <= DMI_W'(IDCODE); dr_len <= 6'd32; end
                            IR_DTMCS:  begin dr <= DMI_W'(dtmcs);  dr_len <= 6'd32; end
                            IR_DMI: begin
                                dr_len <= 6'(DMI_W);
                                if (busy || sticky == 2'd3) begin
                                    dr     <= DMI_W'(3);
                                    sticky <= 2'd3;
                                end else begin
                                    dr <= dmi_res;
                                end
                            end
                            default: begin dr <= '0; dr_len <= 6'd1; end
                        endcase
                    end
                    SH_DR: tdo_q <= dr[0];
                    SH_IR: tdo_q <= ir_sh[0];
                    UPD_IR: ir <= ir_sh;
                    UPD_DR: begin
                        if (ir == IR_DTMCS) begin
                            if (dr[16] || dr[17]) sticky <= 2'd0;
                        end else if (ir == IR_DMI && !busy && sticky != 2'd3) begin
                            dmi_res <= {dr[DMI_W-1:2], 2'd0};
                            if (dr[1:0] == 2'd1 || dr[1:0] == 2'd2) begin
                                a_wr   <= dr[1:0] == 2'd2;
                                a_addr <= dr[DMI_W-1:34];
                                a_data <= dr[33:2];
                                psel   <= 1'b1;
                                ast    <= A_SETUP;
                            end
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    assign pwrite = a_wr;
    assign paddr  = {a_addr, 2'b00};
    assign pwdata = a_data;
    assign pstrb  = 4'hf;
endmodule
