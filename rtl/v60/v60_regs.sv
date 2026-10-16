// v60_regs.sv — NEC V60 register file: general registers, banked stack
// pointer, PSW, and privileged registers.
//
// Architecture (NEC manual ch.2; banking behavior cross-checked against
// MAME v60.cpp v60SaveStack/v60ReloadStack):
//   - R0..R31 general registers; R29=AP, R30=FP by convention (plain GPRs).
//   - R31 (SP) is a *view* onto one of five physical stack registers,
//     selected by PSW: ISP when PSW.IS (bit 28) is set, else L0SP..L3SP
//     indexed by PSW.EL (bits 25:24). This module stores SP only in the
//     bank registers and muxes combinationally — equivalent to the
//     manual's save/reload description, without sequencing hazards.
//   - Privileged registers for ldpr/stpr: ISP, L0SP..L3SP, SBR, TR, SYCW,
//     TKCW, PIR, PSW2 (numbering per ldpr/stpr operand, matching the
//     architecture's privileged register file).
//   - PSW[3:0] = {CY,OV,S,Z} flag nibble is updated either by full PSW
//     writes or by the dedicated flags port (per-instruction updates).
//
// Reset values per manual: PSW = 0x10000000 (IS set, level 0, interrupts
// masked), SYCW = 0x00000070, PIR = processor ID.
//
// Two combinational read ports + one write port cover the microcode
// datapath (one uop reads up to two registers, writes one).

module v60_regs (
    input  logic        clk,
    input  logic        rst,

    // general register ports (R31 resolves to the active stack bank)
    input  logic [4:0]  raddr_a,
    output logic [31:0] rdata_a,
    input  logic [4:0]  raddr_b,
    output logic [31:0] rdata_b,
    input  logic        wen,
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata,

    // PSW access
    output logic [31:0] psw,
    input  logic        psw_wen,      // full write (updpsw/retis/trap entry)
    input  logic [31:0] psw_wdata,
    input  logic        flags_wen,    // flag-nibble-only update from datapath
    input  logic [3:0]  flags_wdata,  // {CY,OV,S,Z}

    // privileged register access (ldpr/stpr), valid range 0..15
    input  logic [3:0]  preg_sel,
    output logic [31:0] preg_rdata,
    input  logic        preg_wen,
    input  logic [31:0] preg_wdata
);

    // privileged register numbering (stpr/ldpr operand values)
    localparam int PR_ISP  = 0,
                   PR_L0SP = 1, PR_L1SP = 2, PR_L2SP = 3, PR_L3SP = 4,
                   PR_SBR  = 5, PR_TR   = 6, PR_SYCW = 7, PR_TKCW = 8,
                   PR_PIR  = 9, PR_PSW2 = 10;

    logic [31:0] gpr [0:30];         // R0..R30 (R31 lives in the banks)
    logic [31:0] sbank [0:4];        // ISP, L0SP..L3SP
    logic [31:0] psw_q;
    logic [31:0] sbr, tr, sycw, tkcw, pir, psw2;

    // active stack bank: ISP when PSW.IS, else L0SP+EL
    logic [2:0] sp_sel;
    assign sp_sel = psw_q[28] ? 3'd0 : (3'd1 + {1'b0, psw_q[25:24]});

    logic [31:0] sp_view;
    assign sp_view = sbank[sp_sel];

    assign rdata_a = (raddr_a == 5'd31) ? sp_view : gpr[raddr_a];
    assign rdata_b = (raddr_b == 5'd31) ? sp_view : gpr[raddr_b];
    assign psw = psw_q;

    always_comb begin
        unique case (preg_sel)
            PR_ISP:  preg_rdata = sbank[0];
            PR_L0SP: preg_rdata = sbank[1];
            PR_L1SP: preg_rdata = sbank[2];
            PR_L2SP: preg_rdata = sbank[3];
            PR_L3SP: preg_rdata = sbank[4];
            PR_SBR:  preg_rdata = sbr;
            PR_TR:   preg_rdata = tr;
            PR_SYCW: preg_rdata = sycw;
            PR_TKCW: preg_rdata = tkcw;
            PR_PIR:  preg_rdata = pir;
            PR_PSW2: preg_rdata = psw2;
            default: preg_rdata = 32'd0;
        endcase
    end

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 31; i = i + 1) gpr[i] <= 32'd0;
            for (i = 0; i < 5; i = i + 1) sbank[i] <= 32'd0;
            psw_q <= 32'h1000_0000;   // IS=1, EL=0, flags clear
            sycw  <= 32'h0000_0070;
            sbr   <= 32'd0;
            tr    <= 32'd0;
            tkcw  <= 32'd0;
            pir   <= 32'd0;           // processor ID: confirm on hardware
            psw2  <= 32'd0;
        end else begin
            if (wen) begin
                if (waddr == 5'd31)
                    sbank[sp_sel] <= wdata;
                else
                    gpr[waddr] <= wdata;
            end
            if (psw_wen)
                psw_q <= psw_wdata;
            else if (flags_wen)
                psw_q[3:0] <= flags_wdata;
            if (preg_wen) begin
                unique case (preg_sel)
                    PR_ISP:  sbank[0] <= preg_wdata;
                    PR_L0SP: sbank[1] <= preg_wdata;
                    PR_L1SP: sbank[2] <= preg_wdata;
                    PR_L2SP: sbank[3] <= preg_wdata;
                    PR_L3SP: sbank[4] <= preg_wdata;
                    PR_SBR:  sbr  <= preg_wdata;
                    PR_TR:   tr   <= preg_wdata;
                    PR_SYCW: sycw <= preg_wdata;
                    PR_TKCW: tkcw <= preg_wdata;
                    PR_PIR:  pir  <= preg_wdata;
                    PR_PSW2: psw2 <= preg_wdata;
                    default: ;
                endcase
            end
        end
    end

endmodule
