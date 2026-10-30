// v60.sv — NEC V60 core: sequencer wiring fetch/decode (v60_ldec), operand
// resolution (v60_ea), register file (v60_regs) and the verified datapath
// (v60_alu, v60_shifter, v60_muldiv) into an executing CPU.
//
// It implements the instructions the supported games execute, plus
// external interrupts and NMI. An instruction it does not implement stops
// the core in S_TRAP with `trap` set and the opcode on trap_op.
//
// Instruction bytes arrive as a 22-byte window at fetch_pc (from the
// prefetch queue, v60_pfu): the longest V60 instruction, two 9-byte
// double-displacement operands plus opcode, format and extension bytes. Data accesses are transactions of 1, 2 or 4
// bytes at any alignment: a one-cycle mem_re/mem_we strobe in an issue
// state, with the data used in the next state. The bus unit (v60_bcu)
// turns them into the real CPU's 16-bit bus cycles. wait_hold freezes the
// core.

module v60 (
    input  logic         clk,
    input  logic         rst,

    output logic [31:0]  fetch_pc,
    input  logic [175:0] fetch_bytes,
    output logic [5:0]   fetch_len,    // decoded length of the instruction
                                       // at fetch_bytes (s32_sys fetch_hold)

    output logic         mem_re,
    output logic         mem_we,
    output logic [31:0]  mem_addr,
    output logic [2:0]   mem_size,     // 1, 2 or 4 bytes
    output logic [31:0]  mem_wdata,
    input  logic [31:0]  mem_rdata,    // read data, right-aligned

    // external interrupt (315-5385): level + vector, sampled at
    // instruction boundaries when PSW.IE (bit 18) is set
    input  logic         irq,
    input  logic [2:0]   irq_vector,

    // non-maskable interrupt: the schematic (sheet 7) wires the MB3771
    // power monitor to NMI, and there is no arcade supply to watch, so
    // s32_sys ties it off; the entry path is implemented. Edge-triggered
    // (MAME v60.cpp
    // execute_set_input), fixed vector table slot 2 (v60_do_irq(2)),
    // taken regardless of PSW.IE; further NMIs are held off until
    // RETIS (NEC manual ch.8: "another NMI will not be acknowledged
    // until ... RETIS").
    input  logic         nmi,

    output logic         trap,
    output logic [7:0]   trap_op,

    // bus wait: freezes the FSM exactly where it is (state and all
    // registers preserved) until released — the memory fabric's hold
    input  logic         wait_hold
);

    `include "v60_optab.svh"

    // ---------------------------------------------------------------- state
    typedef enum logic [5:0] {
        S_FETCH, S_DECODE,
        S_OP1_EA, S_OP1_DEF, S_OP1_RD,
        S_OP2_EA, S_OP2_DEF, S_OP2_RD,
        S_EXEC, S_MD_WAIT, S_POP_RD,
        S_RETIS1, S_RETIS2,
        S_WB, S_WB2,
        S_PUSHM, S_POPM, S_POPM_CONSUME,
        S_STR_LEN1, S_STR_LEN2, S_STR_SETUP, S_STR_RD, S_STR_WR,
        S_STR_RD2, S_STR_CMP,
        S_STR_END1, S_STR_END2,
        S_XCP_SBR, S_XCP_VEC, S_XCP_P1, S_XCP_P2, S_XCP_P3,
        S_DVX_RD, S_DVX_WB,
        S_TRAP,
        // appended AFTER S_TRAP so every pre-existing state keeps its
        // encoding (HUD/bench prints of dut.u_v60.state stay comparable)
        S_STR_FILL,
        S_CALL2,                      // call: push next PC, SP -= 8, jump
        S_RET3,                       // ret: SP += 8 + num (after PC, AP pops)
        // movbsu/movbsd (bit-string move, one bit a cycle)
        S_BS_LEN, S_BS_ADDR, S_BS_NEXT, S_BS_CAPS, S_BS_CAPD, S_BS_BIT,
        S_BS_FLUSH, S_BS_END1, S_BS_END2,
        // bit fields (extbf*/insbf*) and the upward bit search (sch*bsu)
        S_BF_LEN, S_BF_RD, S_BF_CAP, S_BF_WR, S_SB_RD, S_SB_CAP, S_SB_BIT,
        // ldtask / sttask TCB walk, and chlvl's fourth (parameter) push
        S_TK_RD, S_TK_CONSUME, S_TK_WR, S_XCP_P4
    } state_e;
    state_e state;

    logic [31:0] pc;
    logic [175:0] iw;
    logic [5:0]  len_q;
    logic [7:0]  exec_q;
    logic [3:0]  ft_q;
    logic [1:0]  s1_q, s2_q;
    logic [4:0]  l1_q, l2_q;

    // ---------------------------------------------------------------- decode
    // ONE length decoder, on the fetch window. Its length is also fetch_len,
    // which s32_sys compares with the prefetch queue's fill (fetch_hold), and
    // its outputs are registered together with iw at the S_FETCH latch, so
    // S_DECODE sees exactly the decode of iw it saw when this decoder sat on
    // iw. Until 2026-10-28 s32_sys ran a second copy on the same window for
    // the length alone (~210 ALMs; docs/corertlcleanup.md C4).
    logic [5:0] f_ilen;
    logic [3:0] f_ftype;
    logic [1:0] f_s1, f_s2;
    logic [4:0] f_am1l, f_am2l;
    logic       f_valid;

    v60_ldec u_ldec (
        .bytes_in(fetch_bytes), .length(f_ilen), .ftype(f_ftype),
        .opsize1(f_s1), .opsize2(f_s2), .am1_len(f_am1l), .am2_len(f_am2l),
        .valid(f_valid)
    );
    assign fetch_len = f_ilen;

    // decode(iw), latched with iw in S_FETCH
    logic [5:0] ilen;
    logic [3:0] ftype;
    logic [1:0] s1, s2;
    logic [4:0] am1l, am2l;
    logic       ldec_valid;

    logic [7:0] b0, b1;
    assign b0 = iw[175:168];
    assign b1 = iw[167:160];

    logic [7:0] execop;
    always_comb begin
        execop = v60_exectab(b0);
        if (execop == 8'hFE) begin
            unique case (b0)
                8'h58: execop = v60_exectab_58(b1[4:0]);
                8'h59: execop = v60_exectab_59(b1[4:0]);
                8'h5A: execop = v60_exectab_5A(b1[4:0]);
                8'h5B: execop = v60_exectab_5B(b1[4:0]);
                8'h5C: execop = v60_exectab_5C(b1[4:0]);
                8'h5D: execop = v60_exectab_5D(b1[4:0]);
                8'h5E: execop = v60_exectab_5E(b1[4:0]);
                8'h5F: execop = v60_exectab_5F(b1[4:0]);
                8'hC6: execop = v60_exectab_C6({2'b0, b1[7:5]});
                default: execop = v60_exectab_C7({2'b0, b1[7:5]});
            endcase
        end
    end

    // operand plan, computed at S_DECODE from the latched window:
    //   F1 (b1[7]=0): b1[5]=0 -> op1 = reg field, op2 = AM@2
    //                 b1[5]=1 -> op1 = AM@2,     op2 = reg field
    //   F2: op1 = AM@2 (m=b1[6]); op2 = AM@(2+l1) (m=b1[5])
    //   F3: op1 = AM@1 (m=b0[0]); writeback (if any) targets op1
    //   F4/F5/F6: no AM operands (disp/reg fields read in S_EXEC)
    typedef enum logic [1:0] { OD_NONE, OD_REG, OD_AM } od_e;
    od_e        op1_d, op2_d;
    logic [4:0] op1_regf, op2_regf;
    logic [5:0] op1_off, op2_off;
    logic       op1_m, op2_m;
    logic       wb_to_op1;            // F3 unary/pop: writeback hits op1

    always_comb begin
        op1_d = OD_NONE; op2_d = OD_NONE;
        op1_regf = b1[4:0]; op2_regf = b1[4:0];
        wb_to_op1 = 1'b0;
        unique case (ft_q)
            4'd0: begin                       // F1
                if (b1[5]) begin
                    op1_d = OD_AM;  op2_d = OD_REG;
                end else begin
                    op1_d = OD_REG; op2_d = OD_AM;
                end
            end
            4'd1, 4'd8, 4'd9, 4'd10: begin    // F2 / F7 family
                op1_d = OD_AM; op2_d = OD_AM;
            end
            4'd3: begin                       // F3
                op1_d = OD_AM;
                wb_to_op1 = 1'b1;
            end
            default: ;                        // F4/F5/F6: handled in EXEC
        endcase
    end

    // Each operand's AM offset and m bit, from the decoder's own outputs
    // and latched at S_DECODE (op1_off_q...). They select the AM window
    // (iw_sh), the head of the V60's critical path (offset -> window ->
    // index register -> DSP multiply -> adders -> v60_bcu q1_a, ~30 ns of
    // the 31 ns core period); decoding them from ft_q/l1_q in the operand
    // states put three LUT levels in front of it (STA 2026-10-27, Rad
    // Mobile build: core -0.011 / -0.189 at seeds 1 / 7). iw only changes
    // in S_FETCH, so the latched values equal the old combinational ones
    // for the whole instruction.
    logic [5:0] dec_op1_off, dec_op2_off, op1_off_q, op2_off_q;
    logic       dec_op1_m, dec_op2_m, op1_m_q, op2_m_q;

    always_comb begin
        dec_op1_off = 6'd2; dec_op2_off = 6'd2;
        dec_op1_m = b1[6]; dec_op2_m = b1[5];
        unique case (ftype)
            4'd0:                             // F1: AM op2 (b1[5]=0) is m=b1[6]
                if (!b1[5]) dec_op2_m = b1[6];
            4'd1, 4'd8, 4'd9, 4'd10: begin    // F2 / F7 family
                dec_op2_off = 6'd2 + 6'(am1l);
                // F7a/F7b put an extension byte between the operands; F7c
                // puts its one extension byte after both (MAME
                // F7cDecodeOperands; radmu's `insbfr #1, R11@[R17], #1` is
                // 5D B8 | E1 | CB 71 | 01)
                if (ftype == 4'd8 || ftype == 4'd9)
                    dec_op2_off = 6'd3 + 6'(am1l);           // skip ext byte
            end
            4'd3: begin                       // F3
                dec_op1_off = 6'd1; dec_op1_m = b0[0];
            end
            default: ;
        endcase
    end

    assign op1_off = op1_off_q; assign op2_off = op2_off_q;
    assign op1_m = op1_m_q;     assign op2_m = op2_m_q;

    // ---------------------------------------------------------------- regs
    logic [4:0]  ra_a, ra_b, waddr;
    logic [31:0] rd_a, rd_b, wdata;
    logic        wen;
    logic [31:0] psw;
    logic        psw_wen, flags_wen;
    logic [31:0] psw_wdata;
    logic [3:0]  flags_wdata;
    // ldtask (78) / sttask (79) TCB walk (NEC V60 manual section 5, p.5-1
    // to 5-3; LDTASK p.7-53, STTASK p.7-104). The TCB holds, at ascending
    // addresses from TR: TKCW, then the level stack pointers SYCW.SPSI
    // selects (bit 8 L0SP .. bit 11 L3SP), then the general registers the
    // list operand selects (bit 0 R0 .. bit 30 R30; bit 31 is RFU), so one
    // 36-slot mask walks it: slot 0 TKCW, 1-4 L0SP-L3SP, 5-35 R0-R30. The
    // area table registers are stored only in virtual mode (SYCW.VM), which
    // nothing on System 32 uses.
    logic [35:0] tk_mask;
    logic [5:0]  tk_idx;
    logic [31:0] tk_ptr;
    logic [31:0] sycw;                // v60_regs SYCW view
    // A privileged-register write is registered (preg_wen lands one cycle
    // after it is set), so a write whose register is not the ldpr operand
    // carries its select in pw_sel_q (ldtask's TR, TKCW and stack pointers)
    logic        pw_ovr_q;
    logic [3:0]  pw_sel_q;
    function automatic logic [3:0] tk_psel (input logic [5:0] slot);
        tk_psel = (slot == 6'd0) ? 4'd8 : slot[3:0];   // TKCW, L0SP..L3SP
    endfunction

    logic [31:0] preg_rdata, preg_wdata;
    logic        preg_wen;
    logic [3:0]  preg_sel_core;
    // Order matters. A registered task-switch write (pw_ovr_q) and the
    // sttask walk's reads come first; then S_XCP_SBR, which must not lose
    // to a stale exec_q: an interrupt is taken in S_FETCH with the PREVIOUS
    // instruction's exec_q still latched, so after an stpr (30) the vector
    // read used to address stpr's register instead of SBR.
    assign preg_sel_core = pw_ovr_q ? pw_sel_q              // ldtask writes
                         : (state == S_TK_WR) ? tk_psel(tk_idx)  // sttask
                         : (state == S_XCP_SBR) ? 4'd5   // irq: SBR
                         : (exec_q == 8'd30) ? op1_val[3:0]
                         : (exec_q == 8'd53 || exec_q == 8'd77)
                                               ? 4'd5    // trap/chlvl: SBR
                         : (exec_q == 8'd79) ? 4'd6      // sttask: TR
                         : op2_val[3:0];
    logic [3:0]  preg_sel;
    logic        preg_wen_m;
    logic [31:0] preg_wdata_m;
    assign preg_sel = preg_sel_core;
    assign preg_wen_m = preg_wen;
    assign preg_wdata_m = preg_wdata;

    logic       rf_wen;
    logic [4:0] rf_waddr, rf_ra_a;
    logic [31:0] rf_wdata;
    logic       rf_psw_wen;
    logic [31:0] rf_psw_wdata;
    assign rf_wen   = wen;
    assign rf_waddr = waddr;
    assign rf_wdata = wdata;
    assign rf_ra_a  = ra_a;
    assign rf_psw_wen   = psw_wen;
    assign rf_psw_wdata = psw_wdata;

    v60_regs u_regs (
        .clk(clk), .rst(rst),
        .raddr_a(rf_ra_a), .rdata_a(rd_a),
        .raddr_b(ra_b), .rdata_b(rd_b),
        .wen(rf_wen), .waddr(rf_waddr), .wdata(rf_wdata),
        .psw(psw), .psw_wen(rf_psw_wen), .psw_wdata(rf_psw_wdata),
        .flags_wen(flags_wen), .flags_wdata(flags_wdata),
        .preg_sel(preg_sel), .preg_rdata(preg_rdata),
        .preg_wen(preg_wen_m), .preg_wdata(preg_wdata_m),
        .sycw_o(sycw)
    );

    // movbsu (65) / movbsd (66): Format VIIb bit-string operands, resolved
    // in bit-addressing mode (v60_ea header)
    logic is_bs;
    assign is_bs = (exec_q == 8'd65) || (exec_q == 8'd66);
    // extbfs/z/l (67-69): operand 1 is a bit address, operand 2 the word
    // destination. insbfr/l (70/71): operand 1 the word source, operand 2 a
    // bit address. sch0bsu/sch1bsu (72/73): as extbf. adddc/subdc/subrdc
    // (74-76): byte operands, no bit addressing.
    logic is_bf_ext, is_bf_ins, is_sb, is_dc;
    assign is_bf_ext = (exec_q >= 8'd67) && (exec_q <= 8'd69);
    assign is_bf_ins = (exec_q == 8'd70) || (exec_q == 8'd71);
    assign is_sb     = (exec_q == 8'd72) || (exec_q == 8'd73);
    assign is_dc     = (exec_q >= 8'd74) && (exec_q <= 8'd76);
    // which operand is resolved in bit-addressing mode
    logic bit_op1, bit_op2, ea_bitmode;
    assign bit_op1 = is_bs || is_bf_ext || is_sb;
    assign bit_op2 = is_bs || is_bf_ins;
    assign ea_bitmode = (state == S_OP2_EA || state == S_OP2_DEF) ? bit_op2
                                                                  : bit_op1;

    // ---------------------------------------------------------------- EA
    logic [79:0] ea_bytes;
    logic        ea_m;
    logic [1:0]  ea_size;
    logic [31:0] ea_out, ea_wb, ea_defidx, ea_bitoff;
    logic [4:0]  ea_regsel, ea_idxsel;
    logic [2:0]  ea_kind;
    logic        ea_wen;
    logic [5:0]  cur_off;             // AM offset for the active operand

    // AM window extraction: bytes at cur_off .. cur_off+9
    logic [175:0] iw_sh;
    assign iw_sh = iw << ({4'b0, cur_off} * 8);
    assign ea_bytes = iw_sh[175:96];

    v60_ea u_ea (
        .am_bytes(ea_bytes), .m(ea_m), .opsize(ea_size),
        .reg_val(rd_b), .idx_val(rd_a), .pc(pc), .bitmode(ea_bitmode),
        .reg_sel(ea_regsel), .idx_sel(ea_idxsel),
        .ea(ea_out), .ea_kind(ea_kind),
        .base_wb(ea_wb), .base_wen(ea_wen),
        .def_idxoff(ea_defidx), .bit_off(ea_bitoff)
    );

    // ---------------------------------------------------------------- ops
    logic [31:0] op1_val, op2_val;
    logic [31:0] op1_ea_q, op2_ea_q;
    logic        op1_ismem, op2_ismem;
    logic [4:0]  op1_reg_q, op2_reg_q;
    logic        op1_isreg, op2_isreg;

    // ---------------------------------------------------------------- exec
    logic [1:0] exec_width;
    assign exec_width = s2_q;

    logic [31:0] alu_a;
    // unary F3 ops use op1; not/neg (exec 7/6) are two-operand with
    // unary semantics — dst = op(SRC) — so the ALU a-input must be the
    // source even when writeback goes to op2
    assign alu_a = (wb_to_op1 || exec_q == 8'd6 || exec_q == 8'd7)
                 ? op1_val : op2_val;

    logic [31:0] alu_res, sh_res;
    logic [3:0]  alu_fo, sh_fo;

    // addc/subc (exec 58/59) live above the shifter's 10-13 range, so
    // they can't ride exec_q[3:0]; mux them onto ALU ops 10/11
    logic [3:0] alu_op;
    assign alu_op = (exec_q == 8'd58) ? 4'd10
                  : (exec_q == 8'd59) ? 4'd11 : exec_q[3:0];
    v60_alu u_alu (
        .op(alu_op), .width(exec_width),
        .a(alu_a), .b(op1_val),
        .flags_in(psw[3:0]), .result(alu_res), .flags_out(alu_fo)
    );

    v60_shifter u_sh (
        .op(exec_q[3:0]), .width(exec_width),
        .a(op2_val), .count_in(op1_val[7:0]),
        .flags_in(psw[3:0]), .result(sh_res), .flags_out(sh_fo)
    );

    logic        md_start, md_busy;
    logic [31:0] md_res;
    logic [3:0]  md_fo;

    logic [31:0] md_rem;
    // rem/remu (exec 56/57, opcodes 50-55) ride the div/divu iteration
    // with mode_rem selecting the remainder output (the coin/start
    // path's credit formatter at 064874 is Golden Axe's first rem.b)
    logic [4:0] md_op;
    // Extended (64-bit) divide family: 54 = divux (unsigned), 55 = divx
    // (signed; Spider-Man's Venom fight uses it). Both use the same 64-bit
    // dividend, the same S_DVX_* states and the same two-destination
    // writeback; only the sign differs, and it travels as a REAL opr.
    logic is_dvx_op;
    assign is_dvx_op = (exec_q == 8'd54) || (exec_q == 8'd60);
    // mulx (80) / mulux (81), NEC manual p.7-67/68: dst.d <- dst.w * src.w,
    // the 64-bit product to Rn (low) and Rn+1 (high), or EA / EA+4. They
    // share divx/divux's two-destination writeback (S_MD_WAIT, S_DVX_WB),
    // but read only the low dword of a memory destination: the multiplicand
    // is a word, so there is no S_DVX_RD high read.
    logic is_mlx_op, is_pair_op;
    assign is_mlx_op  = (exec_q == 8'd80) || (exec_q == 8'd81);
    assign is_pair_op = is_dvx_op || is_mlx_op;

    // Both extended forms pass a real opcode (divux -> OP_DIVU, divx ->
    // OP_DIV) rather than exec_q[4:0], so the unit can tell signed from
    // unsigned extended divide; mode_dvx alone cannot express that.
    assign md_op = (exec_q == 8'd56) ? 5'd16     // rem  -> signed divide
                 : (exec_q == 8'd57) ? 5'd17     // remu -> unsigned divide
                 : (exec_q == 8'd54) ? 5'd17     // divux
                 : (exec_q == 8'd60) ? 5'd16     // divx
                 : (exec_q == 8'd80) ? 5'd14     // mulx  -> signed multiply
                 : (exec_q == 8'd81) ? 5'd15     // mulux -> unsigned multiply
                 : exec_q[4:0];
    v60_muldiv u_md (
        .clk(clk), .rst(rst), .start(md_start),
        .op(md_op), .width(exec_width),
        .a(op2_val), .b(op1_val), .flags_in(psw[3:0]),
        // dvx pair high: register form reads Rn+1 on port A; memory form
        // has the high dword on mem_rdata (read issued in S_DVX_RD)
        .a_hi(op2_isreg ? rd_a : mem_rdata), .mode_dvx(is_dvx_op),
        .mode_rem(exec_q == 8'd56 || exec_q == 8'd57),
        .mode_mlx(is_mlx_op),
        .busy(md_busy), .done(),
        .result(md_res), .rem_out(md_rem), .flags_out(md_fo)
    );

    // ------------------------------------------------------------- helpers
    function automatic logic [31:0] wmask (input logic [1:0] w);
        wmask = (w == 2'd0) ? 32'h0000_00FF
              : (w == 2'd1) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
    endfunction

    function automatic logic [31:0] sext (input logic [31:0] v,
                                          input logic [1:0] w);
        unique case (w)
            2'd0: sext = {{24{v[7]}}, v[7:0]};
            2'd1: sext = {{16{v[15]}}, v[15:0]};
            default: sext = v;
        endcase
    endfunction

    function automatic logic cond (input logic [3:0] cc, input logic [3:0] f);
        logic z, s, ov, cy;
        begin
            z = f[0]; s = f[1]; ov = f[2]; cy = f[3];
            unique case (cc)
                4'h0: cond = ov;
                4'h1: cond = !ov;
                4'h2: cond = cy;
                4'h3: cond = !cy;
                4'h4: cond = z;
                4'h5: cond = !z;
                4'h6: cond = cy | z;
                4'h7: cond = !(cy | z);
                4'h8: cond = s;
                4'h9: cond = !s;
                4'hA: cond = 1'b1;
                // cc 0xB is F = constant FALSE on a real V60 (the TRAP site
                // guards it locally as well). Golden Axe uses `setf #B` to
                // store 0; treating 0xB as GT makes it store 1 when GT is true
                // and freezes a boss fight. MAME agrees: setf #B stores 0
                // even with GT-true flags.
                4'hB: cond = 1'b0;
                4'hC: cond = s ^ ov;
                4'hD: cond = !(s ^ ov);
                4'hE: cond = (s ^ ov) | z;
                default: cond = !((s ^ ov) | z);
            endcase
        end
    endfunction

    // second displacement of double-displacement AM (window at mode byte)
    function automatic logic [31:0] def_disp2 (input logic [79:0] amb);
        unique case (amb[79:77])
            3'd0: def_disp2 = {{24{amb[63]}}, amb[63:56]};
            3'd1: def_disp2 = {{16{amb[47]}}, amb[47:40], amb[55:48]};
            default:
                def_disp2 = {amb[15:8], amb[23:16], amb[31:24], amb[39:32]};
        endcase
    endfunction

    // does this deferred mode add a second displacement after the fetch?
    function automatic logic def_has_d2 (input logic [79:0] amb,
                                         input logic m);
        if (m) def_has_d2 = (amb[79:77] <= 3'd2);            // dbl disp
        else   def_has_d2 = (amb[79:77] == 3'd7) &&
                            (amb[76:72] >= 5'd28);           // PC dbl disp
    endfunction

    // immediates: quick (mode 7 sub 0..15) or sized (sub 20)
    function automatic logic [31:0] am_imm (input logic [79:0] amb,
                                            input logic [1:0] w);
        if (!amb[76])  am_imm = {28'd0, amb[75:72]};         // quick 0..15
        else unique case (w)
            2'd0: am_imm = {24'd0, amb[71:64]};
            2'd1: am_imm = {16'd0, amb[63:56], amb[71:64]};
            default:
                am_imm = {amb[47:40], amb[55:48], amb[63:56], amb[71:64]};
        endcase
    endfunction

    // PSW field mask for updpsw.h/.w (selected by opcode byte)
    function automatic logic [31:0] pswm2 (input logic [7:0] op);
        pswm2 = (op == 8'h4A) ? 32'h0000_FFFF : 32'h00FF_FFFF;
    endfunction

    // exec classification
    logic is_alu, is_shift, is_md, is_bcc, is_dbcc;
    assign is_alu   = (exec_q <= 8'd9)
                   || (exec_q == 8'd58) || (exec_q == 8'd59);  // addc/subc
    assign is_shift = (exec_q >= 8'd10) && (exec_q <= 8'd13);
    assign is_md    = (exec_q >= 8'd14) && (exec_q <= 8'd17);
    assign is_bcc   = (exec_q[7:4] == 4'h8);
    assign is_dbcc  = (exec_q[7:4] == 4'h9);

    // op1 wants the address, not the value (movea/jmp/jsr)
    logic op1_addr_only;
    assign op1_addr_only =
        (exec_q == 8'd19) || (exec_q == 8'd25) || (exec_q == 8'd26) ||
        (exec_q >= 8'd50 && exec_q <= 8'd52) ||  // movcu/movcd/skpcu
        (exec_q == 8'd64) ||                     // skpcd: src string address
        (exec_q == 8'd61) ||                     // cmpc: src string address
        (exec_q == 8'd62) ||                     // movcfu: src string address
        (exec_q == 8'd63) ||                     // call: target address (op2,
                                                 // the arg list, is address-
                                                 // only via !op2_need_val)
        bit_op1;                                 // movbs/extbf/sch: bit base

    // op2 old value needed from MEMORY (RMW, bit ops, xch, updpsw, test1);
    // register destinations always read via the port (width merge), which
    // is why this term must NOT include the registered op2_isreg flag
    logic op2_need_val;
    assign op2_need_val =
        is_alu || is_shift || is_md ||
        (exec_q >= 8'd33 && exec_q <= 8'd36) ||
        (exec_q == 8'd41) || (exec_q == 8'd43) ||
        (exec_q == 8'd52) || (exec_q == 8'd64) ||   // skpcu/skpcd: char value
        (exec_q == 8'd77) ||                        // chlvl: arg.b.r
        (exec_q == 8'd78) ||                        // ldtask: TCBptr.w.r
        is_dc;                                      // adddc/subdc: dst digits

    // adddc/subdc/subrdc (NEC V60 manual ADDDC p.7-6, SUBDC p.7-107, SUBRDC; MAME
    // opADDDC/opSUBDC/opSUBRDC, op7a.hxx): two packed-BCD digits per byte.
    // dst <- dst + src + CY, dst - src - CY, or src - dst - CY, wrapping at
    // 100 with CY as the carry/borrow. The mask pattern (extension byte) is
    // ignored, as MAME ignores it: Rad Mobile passes #0, which masks nothing.
    // Invalid digits raise a Decimal Format exception on the real CPU; like
    // MAME, this computes with them instead (docs/radm-bringup.md §4).
    function automatic logic [7:0] bcd_val (input logic [7:0] b);
        bcd_val = 8'(b[7:4]) * 8'd10 + 8'(b[3:0]);
    endfunction
    logic [8:0]  dc_sum;              // signed 9-bit work value
    logic [7:0]  dc_bin, dc_res;
    logic        dc_cy;
    always_comb begin
        unique case (exec_q)
            8'd74:   dc_sum = 9'(bcd_val(op1_val[7:0])) + 9'(bcd_val(op2_val[7:0]))
                              + 9'(psw[3]);
            8'd76:   dc_sum = 9'(bcd_val(op1_val[7:0])) - 9'(bcd_val(op2_val[7:0]))
                              - 9'(psw[3]);
            default: dc_sum = 9'(bcd_val(op2_val[7:0])) - 9'(bcd_val(op1_val[7:0]))
                              - 9'(psw[3]);
        endcase
        if (exec_q == 8'd74) begin
            dc_cy  = (dc_sum >= 9'd100);
            dc_bin = dc_cy ? 8'(dc_sum - 9'd100) : dc_sum[7:0];
        end else begin
            dc_cy  = dc_sum[8];                     // negative: borrow
            dc_bin = dc_cy ? 8'(dc_sum + 9'd100) : dc_sum[7:0];
        end
        dc_res = {4'(dc_bin / 8'd10), 4'(dc_bin % 8'd10)};
    end

    // combinational execute result + flags
    logic [31:0] exec_res;
    logic [3:0]  exec_flags;
    logic        exec_setflags, exec_wb;
    logic [31:0] tv;

    always_comb begin
        exec_res = op1_val;
        exec_flags = psw[3:0];
        exec_setflags = 1'b0;
        exec_wb = 1'b1;
        tv = 32'd0;
        if (is_alu) begin
            exec_res = alu_res; exec_flags = alu_fo;
            exec_setflags = 1'b1;
            exec_wb = (exec_q != 8'd2);                     // cmp: no wb
        end else if (is_shift) begin
            exec_res = sh_res; exec_flags = sh_fo; exec_setflags = 1'b1;
        end else if (is_md) begin
            exec_res = md_res; exec_flags = md_fo; exec_setflags = 1'b1;
        end else begin
            unique case (exec_q)
                8'd18: exec_res = op1_val;                  // mov
                8'd19: exec_res = op1_ea_q;                 // movea
                8'd20: exec_res = op1_val & wmask(s1_q);    // movz
                8'd21: exec_res = sext(op1_val, s1_q);      // movs
                8'd22: exec_res = op1_val;                  // movt
                8'd23: exec_res = {op1_val[7:0], op1_val[15:8],
                                   op1_val[23:16], op1_val[31:24]}; // rvbyt
                8'd30: exec_res = preg_rdata;               // stpr
                8'd32: begin                                // test
                    tv = op1_val & wmask(s1_q);
                    exec_flags = {2'b00,
                                  (s1_q == 2'd0) ? tv[7]
                                : (s1_q == 2'd1) ? tv[15] : tv[31],
                                  tv == 32'd0};
                    exec_setflags = 1'b1;
                    exec_wb = 1'b0;
                end
                8'd33: begin                                // test1
                    exec_flags = {op2_val[op1_val[4:0]], psw[2],
                                  psw[1], ~op2_val[op1_val[4:0]]};
                    exec_setflags = 1'b1;
                    exec_wb = 1'b0;
                end
                8'd34: begin                                // set1
                    exec_res = op2_val | (32'd1 << op1_val[4:0]);
                    exec_flags = {op2_val[op1_val[4:0]], psw[2],
                                  psw[1], ~op2_val[op1_val[4:0]]};
                    exec_setflags = 1'b1;
                end
                8'd35: begin                                // clr1
                    exec_res = op2_val & ~(32'd1 << op1_val[4:0]);
                    exec_flags = {op2_val[op1_val[4:0]], psw[2],
                                  psw[1], ~op2_val[op1_val[4:0]]};
                    exec_setflags = 1'b1;
                end
                8'd36: begin                                // not1
                    exec_res = op2_val ^ (32'd1 << op1_val[4:0]);
                    exec_flags = {op2_val[op1_val[4:0]], psw[2],
                                  psw[1], ~op2_val[op1_val[4:0]]};
                    exec_setflags = 1'b1;
                end
                8'd42: exec_res = {31'd0, cond(op1_val[3:0], psw[3:0])};
                8'd74, 8'd75, 8'd76: begin                  // adddc/subdc/subrdc
                    exec_res = {24'd0, dc_res};
                    // CY = carry/borrow; Z cleared by a non-zero result or a
                    // carry, otherwise unchanged; OV, S unchanged
                    exec_flags = {dc_cy, psw[2], psw[1],
                                  psw[0] & (dc_res == 8'd0) & !dc_cy};
                    exec_setflags = 1'b1;
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------ FSM regs
    logic [31:0] wb_res_q;            // result captured for WB states
    logic [31:0] mask_q;              // pushm/popm register mask
    logic [5:0]  mask_idx;
    logic [31:0] sp_shadow;           // SP tracker across pushm/popm

    // NMI edge detect + pend/busy
    logic nmi_q, nmi_pend, nmi_busy;
    logic xcp_nmi;                    // this entry is the NMI

    // exception dispatch working registers
    logic [31:0] xcp_oldpsw, xcp_vecaddr, xcp_tgt;
    logic [31:0] xcp_code;
    logic        xcp_irq;             // 1 = external interrupt entry
    logic        xcp_parm;            // chlvl: an exception parameter word
    logic [31:0] xcp_parw;            // is pushed above the code word
    logic [2:0]  xcp_vecq;
    logic        dvx_ph;              // divux mem writeback phase (0=quot)

    // string-op working registers (movcu/movcd/skpcu/schcu/cmpc)
    logic [1:0]  str_mode;            // 0 = up-copy, 1 = down-copy, 2 = scan,
                                      // 3 = compare (cmpc)
    logic        str_fill;            // movcfu: up-copy, then fill the rest
                                      // of dst with R26 (S_STR_FILL)
    logic [31:0] str_c1;              // cmpc: src element awaiting its dst
    logic        str_search;          // scan polarity: 0 = skip (stop on !=),
                                      // 1 = search (stop on ==)  [schcu]
    logic        str_down;            // scan from the tail (skpcd)
    logic [31:0] str_base1, str_base2;
    logic [31:0] str_i;               // element index
    logic [31:0] str_cnt, str_len2;   // len1 (element count) and len2
    logic [31:0] str_dest;            // min(len1,len2) for copies
    logic [31:0] str_elem;            // element size in bytes
    logic [7:0]  ext1_b, ext2_b;      // F7a length extension bytes

    // bit-string (movbsu/movbsd) working registers. Each operand resolves to
    // a byte base (op1/op2_ea_q) plus a signed bit offset (bs_off1/2); the
    // loop keeps the current source and destination bytes cached, as MAME's
    // opMOVBSU/D (op7a.hxx) does, and moves one bit per cycle.
    logic [31:0] bs_off1, bs_off2;    // signed bit offsets from the bases
    logic [31:0] bs_len, bs_i;
    logic [31:0] bs_sa, bs_da, bs_wa; // src byte, dst byte, dst byte to write
    logic [2:0]  bs_sb, bs_db;        // bit positions within them
    logic [7:0]  bs_sd, bs_dd;        // cached src / dst bytes
    logic        bs_needs, bs_needd, bs_wpend;
    logic        bs_down;
    logic [31:0] bs_o1, bs_o2;        // offsets moved to the starting bit
    assign bs_o1 = bs_off1 + (bs_down ? bs_len - 32'd1 : 32'd0);
    assign bs_o2 = bs_off2 + (bs_down ? bs_len - 32'd1 : 32'd0);

    // bit fields (extbfs/z/l, insbfr/l; NEC V60 manual EXTBF p.7-41 and INSBF
    // p.7-49; MAME opEXTBF*/opINSBF*, op7a.hxx). The field is blen bits at
    // bit (offset & 7) of the unaligned dword at base + (offset >>> 3); the
    // manual requires offset + length <= 32 (else an Illegal Data Field
    // exception), so one dword access holds every legal field. Flags
    // unchanged. The working registers are movbs's: bs_len = blen,
    // bs_sa = the dword's (or, for sch*bsu, the current byte's) address,
    // bs_sb = the bit, bs_sd = the cached byte, bs_i = the bit count.
    logic [31:0] bf_mask, bf_fld, bf_res, bf_src, bf_ins;
    logic [5:0]  bf_n;                // blen clipped to 32
    always_comb begin
        bf_n    = (bs_len > 32'd32) ? 6'd32 : bs_len[5:0];
        bf_mask = (bf_n == 6'd32) ? 32'hFFFF_FFFF : ((32'd1 << bf_n) - 32'd1);
        bf_fld  = (mem_rdata >> bs_sb) & bf_mask;
        unique case (exec_q)
            8'd67: bf_res = bf_fld | ((bf_n != 6'd0 && bf_fld[bf_n - 6'd1])
                                      ? ~bf_mask : 32'd0);   // sign extend
            8'd69: bf_res = (bf_n == 6'd0) ? 32'd0
                                           : bf_fld << (6'd32 - bf_n); // left
            default: bf_res = bf_fld;                         // zero extend
        endcase
        // insbfl takes the field from the top of the source word
        bf_src = (exec_q == 8'd71) ? (op1_val >> (6'd32 - bf_n)) : op1_val;
        bf_ins = (mem_rdata & ~(bf_mask << bs_sb))
               | ((bf_src & bf_mask) << bs_sb);
    end

    // element addresses per mode (down-copy and the downward scan walk
    // high-to-low; a scan's str_dest is its length)
    logic [31:0] str_a1, str_a2;
    always_comb begin
        if (str_mode == 2'd1 || str_down) begin
            str_a1 = str_base1 + (str_dest - 32'd1 - str_i) * str_elem;
            str_a2 = str_base2 + (str_dest - 32'd1 - str_i) * str_elem;
        end else begin
            str_a1 = str_base1 + str_i * str_elem;
            str_a2 = str_base2 + str_i * str_elem;
        end
    end

    // branch displacement (F4a/F4b at byte 1); F6 disp16 at byte 2
    logic [31:0] disp_f4, disp_f6;
    assign disp_f4 = (ft_q == 4'd4)
        ? {{24{iw[167]}}, iw[167:160]}
        : {{16{iw[159]}}, iw[159:152], iw[167:160]};
    assign disp_f6 = {{16{iw[151]}}, iw[151:144], iw[159:152]};

    // F7a length-extension bytes: at 2+l1 and 3+l1+l2
    logic [175:0] iw_e1, iw_e2;
    assign iw_e1 = iw << ((6'd2 + {1'b0, l1_q}) * 8);
    assign iw_e2 = iw << ((6'd3 + {1'b0, l1_q} + {1'b0, l2_q}) * 8);
    assign ext1_b = iw_e1[175:168];
    assign ext2_b = iw_e2[175:168];
    // F7c's one extension byte follows both operands (2+l1+l2): insbf's blen
    logic [175:0] iw_e3;
    logic [7:0]   ext3_b, bf_ext;
    assign iw_e3 = iw << ((6'd2 + {1'b0, l1_q} + {1'b0, l2_q}) * 8);
    assign ext3_b = iw_e3[175:168];
    assign bf_ext = is_bf_ins ? ext3_b : ext1_b;

    assign fetch_pc = pc;

    // ---------------------------------------------------- comb port drive
    // mem/reg port routing per state
    always_comb begin
        mem_re = 1'b0; mem_we = 1'b0;
        mem_addr = 32'd0; mem_size = 3'd4; mem_wdata = 32'd0;
        ra_a = 5'd0;
        ra_b = ea_regsel;
        if (state == S_OP1_EA || state == S_OP2_EA ||
            state == S_OP1_DEF || state == S_OP2_DEF)
            ra_a = ea_idxsel;             // index register (indexed modes;
                                          // deferred-indexed needs it at
                                          // stage 2 for *ptr + Rx*size)
        if (state == S_OP1_EA && op1_d == OD_REG) ra_b = op1_regf;
        if (state == S_OP2_EA && op2_d == OD_REG) ra_b = op2_regf;
        cur_off = op1_off; ea_m = op1_m; ea_size = s1_q;

        unique case (state)
            S_OP1_EA: begin
                cur_off = op1_off; ea_m = op1_m; ea_size = s1_q;
                // reads only when operand 1 really is an AM field — with a
                // register-field operand the EA unit is looking at operand
                // 2's bytes and must not touch the bus (MMIO side effects)
                if (op1_d == OD_AM) begin
                    if (ea_kind == 3'd0 && !op1_addr_only) begin
                        mem_re = 1'b1; mem_addr = ea_out;
                        mem_size = 3'(1 << s1_q);
                    end else if (ea_kind == 3'd3) begin
                        mem_re = 1'b1; mem_addr = ea_out; mem_size = 3'd4;
                    end
                end
            end
            S_OP1_DEF: begin
                cur_off = op1_off; ea_m = op1_m; ea_size = s1_q;
                if (!op1_addr_only) begin
                    mem_re = 1'b1; mem_size = 3'(1 << s1_q);
                    mem_addr = mem_rdata + ea_defidx +
                        (def_has_d2(ea_bytes, op1_m) ? def_disp2(ea_bytes) : 32'd0);
                end
            end
            S_OP2_EA: begin
                cur_off = op2_off; ea_m = op2_m; ea_size = s2_q;
                if (op2_d == OD_AM) begin
                    if (ea_kind == 3'd0 && op2_need_val) begin
                        mem_re = 1'b1; mem_addr = ea_out;
                        mem_size = 3'(1 << s2_q);
                    end else if (ea_kind == 3'd3) begin
                        mem_re = 1'b1; mem_addr = ea_out; mem_size = 3'd4;
                    end
                end
            end
            S_OP2_DEF: begin
                cur_off = op2_off; ea_m = op2_m; ea_size = s2_q;
                if (op2_need_val) begin
                    mem_re = 1'b1; mem_size = 3'(1 << s2_q);
                    mem_addr = mem_rdata + ea_defidx +
                        (def_has_d2(ea_bytes, op2_m) ? def_disp2(ea_bytes) : 32'd0);
                end
            end
            S_EXEC: begin
                ra_a = 5'd31;                       // SP for push/rsr/bsr
                if (is_dbcc || exec_q == 8'h31) ra_a = b1[4:0];
                if (is_dvx_op) ra_a = op2_reg_q + 5'd1;  // pair high
                if (exec_q == 8'd46) begin          // retis: pop PC
                    mem_re = 1'b1; mem_addr = rd_a; mem_size = 3'd4;
                end
                if (exec_q == 8'd27 || exec_q == 8'd45) begin
                    // rsr / ret: pop PC (ret then pops AP via S_RETIS1/2)
                    mem_re = 1'b1; mem_addr = rd_a; mem_size = 3'd4;
                end
                if (exec_q == 8'd63) begin          // call: [-SP] <- AP
                    ra_b = 5'd29;
                    mem_we = 1'b1; mem_addr = rd_a - 32'd4; mem_size = 3'd4;
                    mem_wdata = rd_b;
                end
                if (exec_q == 8'd38) begin          // pop: read [SP]
                    mem_re = 1'b1; mem_addr = rd_a; mem_size = 3'd4;
                end
                if (exec_q == 8'd37 || exec_q == 8'd24 || exec_q == 8'd26) begin
                    // push / bsr / jsr: write word at SP-4
                    mem_we = 1'b1; mem_addr = rd_a - 32'd4; mem_size = 3'd4;
                    mem_wdata = (exec_q == 8'd37) ? op1_val
                                                  : pc + {26'd0, len_q};
                end
                if (is_pair_op && op2_ismem) begin
                    // divx/divux memory form: read dividend low dword;
                    // mulx/mulux: the multiplicand word
                    mem_re = 1'b1; mem_addr = op2_ea_q; mem_size = 3'd4;
                end
            end
            S_DVX_RD: begin
                // dividend high dword; lands on mem_rdata during the
                // muldiv start cycle (a_hi mux above). Not for mulx/mulux,
                // whose memory destination is only read for its low word.
                if (is_dvx_op) begin
                    mem_re = 1'b1; mem_addr = op2_ea_q + 32'd4; mem_size = 3'd4;
                end
            end
            S_DVX_WB: begin
                if (op2_ismem) begin
                    // quotient at EA, remainder at EA+4 (MAME opDIVUX)
                    mem_we = 1'b1; mem_size = 3'd4;
                    mem_addr  = dvx_ph ? op2_ea_q + 32'd4 : op2_ea_q;
                    mem_wdata = dvx_ph ? md_rem : md_res;
                end
            end
            S_MD_WAIT: begin
                // divx/divux: muldiv captures operands on its start cycle,
                // which lands here - keep the pair-high register on port A
                if (is_dvx_op) ra_a = op2_reg_q + 5'd1;
            end
            S_RETIS1: begin
                ra_a = 5'd31;                       // pop PSW at SP+4
                mem_re = 1'b1; mem_addr = rd_a + 32'd4; mem_size = 3'd4;
            end
            S_RETIS2: ra_a = 5'd31;                 // SP += 8 + adj needs SP
            S_CALL2: begin                          // call: [-SP] <- next PC
                ra_a = 5'd31;                       // (SP not yet written)
                mem_we = 1'b1; mem_addr = rd_a - 32'd8; mem_size = 3'd4;
                mem_wdata = pc + {26'd0, len_q};
            end
            S_RET3: ra_a = 5'd31;                   // ret: SP += 8 + num
            S_WB: begin
                if ((wb_to_op1 ? op1_ismem : op2_ismem)) begin
                    mem_we = 1'b1;
                    mem_addr = wb_to_op1 ? op1_ea_q : op2_ea_q;
                    // destination size follows the destination operand
                    // (pop is F3: dest = op1 word, but s2 = byte)
                    mem_size = 3'(1 << (wb_to_op1 ? s1_q : s2_q));
                    mem_wdata = wb_res_q;
                end
            end
            S_WB2: begin                            // xch second write
                if (op1_ismem) begin
                    mem_we = 1'b1; mem_addr = op1_ea_q;
                    mem_size = 3'(1 << s1_q);
                    mem_wdata = op2_val;
                end
            end
            S_XCP_VEC: begin
                mem_re = 1'b1; mem_addr = xcp_vecaddr; mem_size = 3'd4;
            end
            // Exception frame (NEC manual Fig. 8-3, Table p.8-17), from the
            // top: [parameter,] code|count, PSW, PC. chlvl's parameter sits
            // above the code word, so its other three pushes move down 4.
            S_XCP_P1: begin
                ra_a = 5'd31;
                mem_we = 1'b1; mem_size = 3'd4;
                mem_addr = rd_a - 32'd4 - (xcp_parm ? 32'd4 : 32'd0);
                mem_wdata = xcp_irq ? xcp_oldpsw : xcp_code;
            end
            S_XCP_P2: begin
                ra_a = 5'd31;
                mem_we = 1'b1; mem_size = 3'd4;
                mem_addr = rd_a - 32'd8 - (xcp_parm ? 32'd4 : 32'd0);
                mem_wdata = xcp_irq ? pc : xcp_oldpsw;
            end
            S_XCP_P3: begin
                ra_a = 5'd31;
                mem_we = 1'b1; mem_size = 3'd4;
                mem_addr = rd_a - 32'd12 - (xcp_parm ? 32'd4 : 32'd0);
                mem_wdata = pc + {26'd0, len_q};
            end
            S_XCP_P4: begin                         // chlvl parameter
                ra_a = 5'd31;
                mem_we = 1'b1; mem_addr = rd_a - 32'd4; mem_size = 3'd4;
                mem_wdata = xcp_parw;
            end
            S_TK_RD: begin                          // ldtask: next TCB word
                if (tk_idx < 6'd36 && tk_mask[tk_idx]) begin
                    mem_re = 1'b1; mem_addr = tk_ptr; mem_size = 3'd4;
                end
            end
            S_TK_WR: begin                          // sttask: next TCB word
                ra_a = 5'(tk_idx - 6'd5);
                if (tk_idx < 6'd36 && tk_mask[tk_idx]) begin
                    mem_we = 1'b1; mem_addr = tk_ptr; mem_size = 3'd4;
                    mem_wdata = (tk_idx < 6'd5) ? preg_rdata : rd_a;
                end
            end
            S_STR_LEN1: if (ext1_b[7]) ra_a = ext1_b[4:0];
            S_STR_LEN2: if (ext2_b[7]) ra_a = ext2_b[4:0];
            S_STR_RD: begin
                mem_re = 1'b1; mem_addr = str_a1;
                mem_size = str_elem[2:0];
            end
            S_STR_WR: begin
                if (!str_mode[1]) begin             // copies only (0/1)
                    mem_we = 1'b1; mem_addr = str_a2;
                    mem_size = str_elem[2:0]; mem_wdata = mem_rdata;
                end
            end
            S_STR_RD2: begin                        // cmpc: dst element
                mem_re = 1'b1; mem_addr = str_a2;
                mem_size = str_elem[2:0];
            end
            S_STR_FILL: begin                       // movcfu: dst[i] = R26
                ra_a = 5'd26;
                mem_we = 1'b1; mem_addr = str_a2;
                mem_size = str_elem[2:0]; mem_wdata = rd_a;
            end
            S_BS_LEN: if (ext1_b[7]) ra_a = ext1_b[4:0];
            S_BS_NEXT: begin
                // priority: a new source byte, then the finished destination
                // byte, then the new destination byte (MAME's order within
                // one bit: src refill first, then dst write + refill)
                if (bs_needs) begin
                    mem_re = 1'b1; mem_addr = bs_sa; mem_size = 3'd1;
                end else if (bs_wpend) begin
                    mem_we = 1'b1; mem_addr = bs_wa; mem_size = 3'd1;
                    mem_wdata = {24'd0, bs_dd};
                end else if (bs_needd) begin
                    mem_re = 1'b1; mem_addr = bs_da; mem_size = 3'd1;
                end
            end
            S_BS_FLUSH: begin
                mem_we = 1'b1; mem_addr = bs_da; mem_size = 3'd1;
                mem_wdata = {24'd0, bs_dd};
            end
            S_BF_LEN: if (bf_ext[7]) ra_a = bf_ext[4:0];
            S_BF_RD: begin                          // the field's dword
                mem_re = 1'b1; mem_addr = bs_sa; mem_size = 3'd4;
            end
            S_BF_WR: begin                          // insbf: merged dword
                mem_we = 1'b1; mem_addr = bs_sa; mem_size = 3'd4;
                mem_wdata = wb_res_q;
            end
            S_SB_RD: begin                          // sch*bsu: next byte
                mem_re = 1'b1; mem_addr = bs_sa; mem_size = 3'd1;
            end
            S_PUSHM: begin
                ra_a = mask_idx[4:0];
                if (mask_q != 32'd0 && mask_q[mask_idx[4:0]]) begin
                    mem_we = 1'b1; mem_addr = sp_shadow - 32'd4;
                    mem_size = 3'd4;
                    mem_wdata = (mask_idx == 6'd31) ? psw : rd_a;
                end
            end
            S_POPM: begin
                if (mask_q != 32'd0 && mask_q[mask_idx[4:0]]) begin
                    mem_re = 1'b1; mem_addr = sp_shadow;
                    mem_size = (mask_idx == 6'd31) ? 3'd2 : 3'd4;
                end
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------- FSM (clocked)
    logic [31:0] next_seq_pc;
    assign next_seq_pc = pc + {26'd0, len_q};

    // writeback helper values
    logic       wb_isreg;
    logic [4:0] wb_reg;
    logic [31:0] wb_old;
    assign wb_isreg = wb_to_op1 ? op1_isreg : op2_isreg;
    assign wb_reg   = wb_to_op1 ? op1_reg_q : op2_reg_q;
    assign wb_old   = wb_to_op1 ? op1_val   : op2_val;

    always_ff @(posedge clk) begin
        wen <= 1'b0; psw_wen <= 1'b0; flags_wen <= 1'b0;
        preg_wen <= 1'b0; md_start <= 1'b0; pw_ovr_q <= 1'b0;

        nmi_q <= nmi;
        if (nmi && !nmi_q) nmi_pend <= 1'b1;      // edge latch (any state)

        if (rst) begin
            pc <= 32'h00FF_FFF0;                  // reset vector 0xFFFFF0
            state <= S_FETCH;
            trap <= 1'b0;
            nmi_q <= 1'b0;
            nmi_pend <= 1'b0;
            nmi_busy <= 1'b0;
            xcp_nmi <= 1'b0;
            xcp_parm <= 1'b0;
        end else if (wait_hold) begin
            // bus wait: everything stays exactly as-is (the one-shot
            // strobes wen/psw_wen/... already cleared above)
        end else begin
            unique case (state)
                // ------------------------------------------------ fetch
                S_FETCH: begin
                    if (nmi_pend && !nmi_busy) begin
                        // non-maskable entry: same frame as
                        // an external interrupt, fixed vector slot 2,
                        // PSW.IE ignored; locked out until RETIS
                        nmi_pend <= 1'b0;
                        nmi_busy <= 1'b1;
                        xcp_nmi <= 1'b1;
                        xcp_irq <= 1'b1;
                        xcp_oldpsw <= psw;
                        psw_wen <= 1'b1;
                        psw_wdata <= (psw & ~32'h2B07_0000)
                                   | 32'h8000_0000 | 32'h1000_0000;
                        state <= S_XCP_SBR;
                    end else if (irq && psw[18]) begin
                        // external interrupt: dispatch instead of executing;
                        // return PC is the interrupted instruction
                        xcp_nmi <= 1'b0;
                        xcp_irq <= 1'b1;
                        xcp_vecq <= irq_vector;
                        xcp_oldpsw <= psw;
                        // EL=0; clear EM,TP,IE,AE,TE; set ASA and IS
                        psw_wen <= 1'b1;
                        psw_wdata <= (psw & ~32'h2B07_0000)
                                   | 32'h8000_0000 | 32'h1000_0000;
                        state <= S_XCP_SBR;
                    end else begin
                        iw <= fetch_bytes;
                        ilen <= f_ilen;   ftype <= f_ftype;
                        s1 <= f_s1;       s2 <= f_s2;
                        am1l <= f_am1l;   am2l <= f_am2l;
                        ldec_valid <= f_valid;
                        state <= S_DECODE;
                    end
                end

                S_XCP_SBR: begin
                    // preg mux presents SBR in this state. External IRQs
                    // use the bus-supplied vector: the 315-5385 drives
                    // 0x40 + n during IACK (MAME update_irq_state), so
                    // the table slot is 64 + n, not n. The NMI uses the
                    // FIXED architectural slot 2 (MAME v60_do_irq(2)).
                    xcp_vecaddr <= (preg_rdata & ~32'hFFF)
                                 + (xcp_nmi ? 32'd8
                                    : ((32'd64 + {29'd0, xcp_vecq}) << 2));
                    state <= S_XCP_VEC;
                end

                // ----------------------------------------------- decode
                S_DECODE: begin
                    len_q <= ilen; exec_q <= execop; ft_q <= ftype;
                    s1_q <= s1; s2_q <= s2; l1_q <= am1l; l2_q <= am2l;
                    op1_off_q <= dec_op1_off; op2_off_q <= dec_op2_off;
                    op1_m_q <= dec_op1_m;     op2_m_q <= dec_op2_m;
                    op1_isreg <= 1'b0; op2_isreg <= 1'b0;
                    op1_ismem <= 1'b0; op2_ismem <= 1'b0;
                    if (!ldec_valid || execop == 8'hFF) begin
                        trap <= 1'b1; trap_op <= execop; state <= S_TRAP;
                    end else if (execop == 8'd39 || execop == 8'd40) begin
                        state <= S_OP1_EA;          // pushm/popm: mask op
                    end else if (ftype <= 4'd1 || ftype == 4'd3 ||
                                 ftype >= 4'd8) begin
                        state <= S_OP1_EA;
                    end else begin
                        state <= S_EXEC;            // F4/F5/F6
                    end
                end

                // ------------------------------------------- operand 1
                S_OP1_EA: begin
                    unique case (op1_d)
                        OD_REG: begin
                            // register field: value through port B
                            op1_val <= rd_b;
                            op1_isreg <= 1'b1; op1_reg_q <= op1_regf;
                            state <= (op2_d == OD_NONE) ? S_EXEC : S_OP2_EA;
                        end
                        default: begin              // OD_AM
                            unique case (ea_kind)
                                3'd1: begin         // register direct
                                    op1_val <= rd_b;
                                    op1_isreg <= 1'b1;
                                    op1_reg_q <= ea_regsel;
                                    state <= (op2_d == OD_NONE) ? S_EXEC
                                                                : S_OP2_EA;
                                end
                                3'd2: begin         // immediate
                                    op1_val <= am_imm(ea_bytes, s1_q);
                                    state <= (op2_d == OD_NONE) ? S_EXEC
                                                                : S_OP2_EA;
                                end
                                3'd0: begin         // memory
                                    op1_ea_q <= ea_out; op1_ismem <= 1'b1;
                                    bs_off1 <= ea_bitoff;
                                    if (ea_wen) begin
                                        wen <= 1'b1; waddr <= ea_regsel;
                                        wdata <= ea_wb;
                                    end
                                    state <= op1_addr_only
                                        ? ((op2_d == OD_NONE) ? S_EXEC
                                                              : S_OP2_EA)
                                        : S_OP1_RD;
                                end
                                3'd3: state <= S_OP1_DEF;
                                default: begin
                                    trap <= 1'b1; trap_op <= 8'hF0;
                                    state <= S_TRAP;
                                end
                            endcase
                        end
                    endcase
                end
                S_OP1_DEF: begin
                    // bit mode: the second displacement (or the index, via
                    // ea_bitoff) is a bit offset from the fetched pointer
                    op1_ea_q <= mem_rdata + ea_defidx +
                        ((def_has_d2(ea_bytes, op1_m) && !bit_op1)
                            ? def_disp2(ea_bytes) : 32'd0);
                    bs_off1 <= def_has_d2(ea_bytes, op1_m) ? def_disp2(ea_bytes)
                                                           : ea_bitoff;
                    op1_ismem <= 1'b1;
                    state <= op1_addr_only
                        ? ((op2_d == OD_NONE) ? S_EXEC : S_OP2_EA)
                        : S_OP1_RD;
                end
                S_OP1_RD: begin
                    op1_val <= mem_rdata;
                    state <= (op2_d == OD_NONE) ? S_EXEC : S_OP2_EA;
                end

                // ------------------------------------------- operand 2
                S_OP2_EA: begin
                    unique case (op2_d)
                        OD_REG: begin
                            op2_val <= rd_b;
                            op2_isreg <= 1'b1; op2_reg_q <= op2_regf;
                            state <= S_EXEC;
                        end
                        default: begin
                            unique case (ea_kind)
                                3'd1: begin
                                    op2_val <= rd_b;
                                    op2_isreg <= 1'b1;
                                    op2_reg_q <= ea_regsel;
                                    state <= S_EXEC;
                                end
                                3'd2: begin         // imm as dst: ldpr idx
                                    op2_val <= am_imm(ea_bytes, s2_q);
                                    state <= S_EXEC;
                                end
                                3'd0: begin
                                    op2_ea_q <= ea_out; op2_ismem <= 1'b1;
                                    bs_off2 <= ea_bitoff;
                                    if (ea_wen) begin
                                        wen <= 1'b1; waddr <= ea_regsel;
                                        wdata <= ea_wb;
                                    end
                                    state <= op2_need_val ? S_OP2_RD : S_EXEC;
                                end
                                3'd3: state <= S_OP2_DEF;
                                default: begin
                                    trap <= 1'b1; trap_op <= 8'hF1;
                                    state <= S_TRAP;
                                end
                            endcase
                        end
                    endcase
                end
                S_OP2_DEF: begin
                    op2_ea_q <= mem_rdata + ea_defidx +
                        ((def_has_d2(ea_bytes, op2_m) && !bit_op2)
                            ? def_disp2(ea_bytes) : 32'd0);
                    bs_off2 <= def_has_d2(ea_bytes, op2_m) ? def_disp2(ea_bytes)
                                                           : ea_bitoff;
                    op2_ismem <= 1'b1;
                    state <= op2_need_val ? S_OP2_RD : S_EXEC;
                end
                S_OP2_RD: begin
                    op2_val <= mem_rdata;
                    state <= S_EXEC;
                end

                // --------------------------------------------- execute
                S_EXEC: begin
                    if (is_bcc) begin
                        pc <= cond(b0[3:0], psw[3:0])
                            ? pc + disp_f4 : next_seq_pc;
                        state <= S_FETCH;
                    end else if (is_dbcc) begin
                        wen <= 1'b1; waddr <= b1[4:0];
                        wdata <= rd_a - 32'd1;
                        pc <= ((rd_a - 32'd1 != 32'd0) &&
                               cond(exec_q[3:0], psw[3:0]))
                            ? pc + disp_f6 : next_seq_pc;
                        state <= S_FETCH;
                    end else if (exec_q == 8'h31) begin   // tb
                        pc <= (rd_a == 32'd0) ? pc + disp_f6 : next_seq_pc;
                        state <= S_FETCH;
                    end else begin
                        unique case (exec_q)
                            8'd14, 8'd15, 8'd16, 8'd17,
                            8'd56, 8'd57: begin     // mul/div + rem/remu
                                md_start <= 1'b1; state <= S_MD_WAIT;
                            end
                            8'd54, 8'd60, 8'd80, 8'd81: begin
                                // divux / divx / mulx / mulux
                                if (!op2_isreg)     // memory form: pair in
                                    state <= S_DVX_RD;  // memory (low read
                                                        // issued comb)
                                else begin
                                    md_start <= 1'b1; state <= S_MD_WAIT;
                                end
                            end
                            8'd24: begin            // bsr (disp16)
                                wen <= 1'b1; waddr <= 5'd31;
                                wdata <= rd_a - 32'd4;
                                pc <= pc + disp_f4;
                                state <= S_FETCH;
                            end
                            8'd25: begin            // jmp
                                pc <= op1_ea_q; state <= S_FETCH;
                            end
                            8'd26: begin            // jsr
                                wen <= 1'b1; waddr <= 5'd31;
                                wdata <= rd_a - 32'd4;
                                pc <= op1_ea_q; state <= S_FETCH;
                            end
                            8'd27: begin            // rsr
                                wen <= 1'b1; waddr <= 5'd31;
                                wdata <= rd_a + 32'd4;
                                state <= S_POP_RD;  // consume PC next cycle
                            end
                            8'd28: begin            // nop
                                pc <= next_seq_pc; state <= S_FETCH;
                            end
                            8'd29: begin            // ldpr
                                preg_wdata <= op1_val;
                                preg_wen <= 1'b1;
                                pc <= next_seq_pc; state <= S_FETCH;
                            end
                            8'd30: begin            // stpr: route via WB
                                wb_res_q <= preg_rdata;
                                state <= S_WB;
                            end
                            8'd37: begin            // push (mem write comb)
                                wen <= 1'b1; waddr <= 5'd31;
                                wdata <= rd_a - 32'd4;
                                pc <= next_seq_pc; state <= S_FETCH;
                            end
                            8'd38: begin            // pop: read issued comb
                                wen <= 1'b1; waddr <= 5'd31;
                                wdata <= rd_a + 32'd4;
                                state <= S_POP_RD;
                            end
                            8'd39: begin            // pushm
                                mask_q <= op1_val; mask_idx <= 6'd31;
                                sp_shadow <= rd_a;  // SP
                                state <= S_PUSHM;
                            end
                            8'd40: begin            // popm
                                mask_q <= op1_val; mask_idx <= 6'd0;
                                sp_shadow <= rd_a;
                                state <= S_POPM;
                            end
                            8'd41: begin            // xch: two writebacks
                                wb_res_q <= op1_val;
                                state <= S_WB;
                            end
                            8'd43: begin            // updpsw.h/.w
                                // width from the opcode byte (4A = .h),
                                // not the size fields (both are word)
                                psw_wen <= 1'b1;
                                psw_wdata <= (psw & ~(op2_val & pswm2(b0)))
                                    | (op1_val & op2_val & pswm2(b0));
                                pc <= next_seq_pc; state <= S_FETCH;
                            end
                            8'd50, 8'd51, 8'd52, 8'd55, 8'd61, 8'd62,
                            8'd64: begin
                                // movcu/movcd/skpcu/schcu — schcu (55) is
                                // the skip scan with inverted match
                                // polarity (stop on ==, not !=); identical
                                // operand form and R27/R28/Z contract
                                // (MAME opSEARCHUB/UH, op7a.hxx:437).
                                // cmpc (61) walks both strings upward like
                                // movcu, reading instead of writing the dst
                                // (mode 3, S_STR_RD2/S_STR_CMP).
                                // movcfu (62) is movcu plus a fill phase:
                                // mode 0 with str_fill (S_STR_FILL).
                                // skpcd (64) is skpcu scanning from the
                                // tail (str_down; see S_STR_END1/END2).
                                str_mode <= (exec_q == 8'd50 ||
                                             exec_q == 8'd62) ? 2'd0
                                          : (exec_q == 8'd51) ? 2'd1
                                          : (exec_q == 8'd61) ? 2'd3 : 2'd2;
                                str_search <= (exec_q == 8'd55);
                                str_down <= (exec_q == 8'd64);
                                str_fill <= (exec_q == 8'd62);
                                str_base1 <= op1_ea_q;
                                str_base2 <= op2_ea_q;
                                str_elem <= (s2_q == 2'd1) ? 32'd2 : 32'd1;
                                str_i <= 32'd0;
                                state <= S_STR_LEN1;
                            end
                            8'd53: begin            // trap cc:vector
                                // cc 11 is "never" in the TRAP condition
                                // table (unlike Bcc, where 0xB is unused)
                                if (op1_val[7:4] != 4'hB &&
                                    cond(op1_val[7:4], psw[3:0])) begin
                                    // exception entry (NEC manual; matches
                                    // MAME update_psw_for_exception): EL=0,
                                    // clear EM,TP,IE,AE,TE; IS unchanged
                                    xcp_oldpsw <= psw;
                                    psw_wen <= 1'b1;
                                    psw_wdata <= (psw & ~32'h2B07_0000)
                                               | 32'h8000_0000;   // PSW.ASA
                                    xcp_vecaddr <= (preg_rdata & ~32'hFFF)
                                        + ((32'd48 + {28'd0, op1_val[3:0]}) << 2);
                                    // exception code word: (0x3000+0x100*n)<<16 | 4
                                    xcp_code <= {4'h3, op1_val[3:0], 8'd0, 16'd4};
                                    xcp_irq <= 1'b0;
                                    state <= S_XCP_VEC;
                                end else begin
                                    pc <= next_seq_pc; state <= S_FETCH;
                                end
                            end
                            8'd77: begin                // chlvl
                                // NEC manual CHLVL p.7-18, change-level
                                // exceptions p.8-11, exception processing
                                // p.8-3. The new level must be 0-3 and not
                                // less privileged than the current one,
                                // else Illegal Data Field, which the core
                                // does not model: it stops (S_TRAP, op F2)
                                // rather than run on wrongly.
                                if (op1_val[7:0] > 8'd3 ||
                                    op1_val[1:0] > psw[25:24]) begin
                                    trap <= 1'b1; trap_op <= 8'hF2;
                                    state <= S_TRAP;
                                end else begin
                                    // EL <- level; EM, TP, AE, TE cleared;
                                    // ASA set; IE and IS UNCHANGED (p.8-3:
                                    // only interrupts clear IE, and an
                                    // exception taken on the interrupt
                                    // stack stays on it, Note 4). So the
                                    // frame lands on L<level>SP, or on the
                                    // ISP when IS is set. MAME's
                                    // update_psw_for_exception also clears
                                    // IE here; the manual is followed
                                    // (docs/OPEN-QUESTIONS.md Q52).
                                    xcp_oldpsw <= psw;
                                    psw_wen <= 1'b1;
                                    psw_wdata <= (psw & ~32'h2B03_0000)
                                               | {6'd0, op1_val[1:0], 24'd0}
                                               | 32'h8000_0000;   // PSW.ASA
                                    xcp_vecaddr <= (preg_rdata & ~32'hFFF)
                                        + ((32'd24 + {30'd0, op1_val[1:0]}) << 2);
                                    // code word (0x1800 + 0x100*level)<<16,
                                    // parameter count 8 (Table 8-1, p.8-17)
                                    xcp_code <= {6'b000110, op1_val[1:0],
                                                 8'd0, 16'd8};
                                    // the arg, zero-extended to a word
                                    xcp_parm <= 1'b1;
                                    xcp_parw <= {24'd0, op2_val[7:0]};
                                    xcp_irq <= 1'b0;
                                    state <= S_XCP_VEC;
                                end
                            end
                            8'd78: begin                // ldtask
                                // list = op1, TCB pointer = op2 (a value:
                                // "TCBptr.w.r", p.7-53). TR <- pointer;
                                // PSW.IS cleared, so L0SP (or the EL's
                                // stack) is the stack again ("if the
                                // current context is using the interrupt
                                // stack, L0SP will become the new stack
                                // pointer"); then TKCW, the SPSI stacks and
                                // the listed registers are loaded.
                                psw_wen <= 1'b1;
                                psw_wdata <= psw & ~32'h1000_0000;
                                preg_wen <= 1'b1; preg_wdata <= op2_val;
                                pw_ovr_q <= 1'b1; pw_sel_q <= 4'd6;    // TR
                                tk_mask <= {op1_val[30:0], sycw[11:8], 1'b1};
                                tk_idx <= 6'd0; tk_ptr <= op2_val;
                                state <= S_TK_RD;
                            end
                            8'd79: begin                // sttask
                                // Saves the context to the TCB at TR
                                // (preg port: TR in this state). "The ISP
                                // becomes the current stack pointer during
                                // the execution of the STTASK instruction"
                                // (p.7-104): PSW.IS is set, and stays set
                                // until the ldtask that follows clears it
                                // (MAME opSTTASK does the same).
                                psw_wen <= 1'b1;
                                psw_wdata <= psw | 32'h1000_0000;
                                tk_mask <= {op1_val[30:0], sycw[11:8], 1'b1};
                                tk_idx <= 6'd0; tk_ptr <= preg_rdata;
                                state <= S_TK_WR;
                            end
                            8'd46: begin                // retis
                                nmi_busy <= 1'b0;       // NMI window
                                state <= S_RETIS1;      // reopens
                            end
                            8'd45: begin                // ret: [SP] read comb;
                                state <= S_RETIS1;      // shares retis's pops,
                            end                         // AP in place of PSW
                            8'd63: begin
                                // call (NEC V60 manual p.7-15; MAME opCALL):
                                // [-SP] <- AP (write comb), AP <- EA(arg),
                                // then S_CALL2 pushes next PC and jumps.
                                // Arabian Fight, PC FFCB19.
                                wen <= 1'b1; waddr <= 5'd29;
                                wdata <= op2_ea_q;
                                state <= S_CALL2;
                            end
                            8'd65, 8'd66: begin
                                // movbsu / movbsd (NEC V60 manual p.7-55,
                                // MOVBS): copy blen bits from bsrc to bdst,
                                // upward or downward; CY/OV/S/Z unchanged.
                                // SegaSonic runs movbsd in its attract demo
                                // (sonic 098FCE, sonicp 0897C0).
                                bs_down <= (exec_q == 8'd66);
                                state <= S_BS_LEN;
                            end
                            8'd67, 8'd68, 8'd69, 8'd70, 8'd71,
                            8'd72, 8'd73: begin
                                // extbf* / insbf* / sch*bsu (Rad Mobile's
                                // bit-stream decompressor): S_BF_LEN reads
                                // blen, then the field or the search
                                state <= S_BF_LEN;
                            end
                            8'd44: begin                // halt
                                trap <= 1'b1; trap_op <= exec_q;
                                state <= S_TRAP;
                            end
                            default: begin          // datapath + mov family
                                if (exec_setflags) begin
                                    flags_wen <= 1'b1;
                                    flags_wdata <= exec_flags;
                                end
                                if (exec_wb) begin
                                    wb_res_q <= exec_res;
                                    state <= S_WB;
                                end else begin
                                    pc <= next_seq_pc; state <= S_FETCH;
                                end
                            end
                        endcase
                    end
                end

                S_DVX_RD: begin                     // divux mem: consume low
                    op2_val <= mem_rdata;           // dword (muldiv 'a');
                    md_start <= 1'b1;               // high read in flight
                    state <= S_MD_WAIT;
                end
                S_MD_WAIT: begin
                    // Wait on the busy LEVEL, not the one-cycle done pulse:
                    // u_md runs on every clk while this FSM is held between
                    // cen16 steps, so the pulse can fall entirely inside a
                    // held cycle and be missed, leaving the core stuck here.
                    // !md_start covers the one cycle before busy rises; the
                    // result and flags stay registered in u_md until the
                    // next start.
                    if (!md_busy && !md_start) begin
                        flags_wen <= 1'b1; flags_wdata <= md_fo;
                        if (is_pair_op) begin
                            if (op2_isreg) begin
                                wen <= 1'b1; waddr <= op2_reg_q;
                                wdata <= md_res;    // quotient/low -> Rn
                            end
                            dvx_ph <= 1'b0;
                            state <= S_DVX_WB;
                        end else begin
                            wb_res_q <= md_res;
                            state <= S_WB;
                        end
                    end
                end
                S_DVX_WB: begin
                    if (op2_isreg) begin
                        wen <= 1'b1; waddr <= op2_reg_q + 5'd1;
                        wdata <= md_rem;            // remainder -> Rn+1
                        pc <= next_seq_pc; state <= S_FETCH;
                    end else if (!dvx_ph)           // mem: quotient write
                        dvx_ph <= 1'b1;             // this cycle (comb),
                    else begin                      // remainder next
                        dvx_ph <= 1'b0;
                        pc <= next_seq_pc; state <= S_FETCH;
                    end
                end

                S_RETIS1: begin                     // consume popped PC
                    pc <= mem_rdata;
                    state <= S_RETIS2;
                end
                S_RETIS2: begin                     // consume popped PSW
                    if (exec_q == 8'd45) begin
                        // ret (NEC V60 manual p.7-86; MAME opRET): the
                        // second word is AP (R29), not the PSW. One write
                        // port, so SP follows in S_RET3.
                        wen <= 1'b1; waddr <= 5'd29;
                        wdata <= mem_rdata;
                        state <= S_RET3;
                    end else begin
                        psw_wen <= 1'b1; psw_wdata <= mem_rdata;
                        wen <= 1'b1; waddr <= 5'd31;
                        wdata <= rd_a + 32'd8 + op1_val;
                        state <= S_FETCH;
                    end
                end
                S_RET3: begin                       // ret: discard num bytes
                    wen <= 1'b1; waddr <= 5'd31;
                    wdata <= rd_a + 32'd8 + op1_val;
                    state <= S_FETCH;
                end
                S_CALL2: begin                      // call: next PC pushed
                    wen <= 1'b1; waddr <= 5'd31;    // comb; SP -= 8, jump
                    wdata <= rd_a - 32'd8;
                    pc <= op1_ea_q;
                    state <= S_FETCH;
                end

                S_POP_RD: begin                     // rsr / pop consume
                    if (exec_q == 8'd27) begin
                        pc <= mem_rdata; state <= S_FETCH;
                    end else begin
                        wb_res_q <= mem_rdata; state <= S_WB;
                    end
                end

                // -------------------------------------------- writeback
                S_WB: begin
                    if (wb_isreg) begin
                        wen <= 1'b1; waddr <= wb_reg;
                        wdata <= (wb_old & ~wmask(wb_to_op1 ? s1_q : s2_q))
                               | (wb_res_q & wmask(wb_to_op1 ? s1_q : s2_q));
                    end
                    // memory write driven combinationally this state
                    if (exec_q == 8'd41) state <= S_WB2;
                    else begin pc <= next_seq_pc; state <= S_FETCH; end
                end
                S_WB2: begin                        // xch second half
                    if (op1_isreg) begin
                        wen <= 1'b1; waddr <= op1_reg_q;
                        wdata <= (op1_val & ~wmask(s1_q))
                               | (op2_val & wmask(s1_q));
                    end
                    pc <= next_seq_pc; state <= S_FETCH;
                end

                // -------------------------------------------- string ops
                S_XCP_VEC: state <= S_XCP_P1;       // vector read in flight
                S_XCP_P1: begin                     // consume vector word
                    xcp_tgt <= mem_rdata;           // (pushes drive comb)
                    state <= S_XCP_P2;
                end
                S_XCP_P2: begin
                    if (xcp_irq) begin
                        wen <= 1'b1; waddr <= 5'd31;   // SP -= 8
                        wdata <= rd_a - 32'd8;
                        pc <= xcp_tgt;
                        state <= S_FETCH;
                    end else
                        state <= S_XCP_P3;
                end
                S_XCP_P3: begin
                    if (xcp_parm)                   // chlvl: one more push
                        state <= S_XCP_P4;
                    else begin
                        wen <= 1'b1; waddr <= 5'd31;    // SP -= 12
                        wdata <= rd_a - 32'd12;
                        pc <= xcp_tgt;
                        state <= S_FETCH;
                    end
                end
                S_XCP_P4: begin                     // parameter pushed
                    wen <= 1'b1; waddr <= 5'd31;    // (comb): SP -= 16
                    wdata <= rd_a - 32'd16;
                    xcp_parm <= 1'b0;
                    pc <= xcp_tgt;
                    state <= S_FETCH;
                end

                // ------------------------------------- ldtask / sttask
                S_TK_RD: begin
                    if (tk_mask == 36'd0) begin
                        pc <= next_seq_pc; state <= S_FETCH;
                    end else if (tk_mask[tk_idx])
                        state <= S_TK_CONSUME;      // read in flight
                    else
                        tk_idx <= tk_idx + 6'd1;
                end
                S_TK_CONSUME: begin
                    if (tk_idx < 6'd5) begin        // TKCW or a stack
                        preg_wen <= 1'b1; preg_wdata <= mem_rdata;
                        pw_ovr_q <= 1'b1; pw_sel_q <= tk_psel(tk_idx);
                    end else begin                  // R0..R30
                        wen <= 1'b1; waddr <= 5'(tk_idx - 6'd5);
                        wdata <= mem_rdata;
                    end
                    tk_mask[tk_idx] <= 1'b0;
                    tk_ptr <= tk_ptr + 32'd4;
                    tk_idx <= tk_idx + 6'd1;
                    state <= S_TK_RD;
                end
                S_TK_WR: begin
                    if (tk_mask == 36'd0) begin
                        pc <= next_seq_pc; state <= S_FETCH;
                    end else begin
                        if (tk_mask[tk_idx]) begin  // written this cycle
                            tk_mask[tk_idx] <= 1'b0;    // (comb): advance
                            tk_ptr <= tk_ptr + 32'd4;
                        end
                        tk_idx <= tk_idx + 6'd1;
                    end
                end

                S_STR_LEN1: begin
                    str_cnt <= ext1_b[7] ? rd_a : {25'd0, ext1_b[6:0]};
                    state <= (str_mode == 2'd2) ? S_STR_SETUP : S_STR_LEN2;
                end
                S_STR_LEN2: begin
                    str_len2 <= ext2_b[7] ? rd_a : {25'd0, ext2_b[6:0]};
                    state <= S_STR_SETUP;
                end
                S_STR_SETUP: begin
                    // latch dest before any read: the down-copy's first
                    // address depends on it
                    if (str_mode == 2'd2) begin
                        str_dest <= str_cnt;
                        if (str_cnt == 32'd0) begin
                            flags_wen <= 1'b1;      // empty scan: Z = 1
                            flags_wdata <= {psw[3:1], 1'b1};
                            state <= S_STR_END1;
                        end else
                            state <= S_STR_RD;
                    end else begin
                        str_dest <= (str_len2 < str_cnt) ? str_len2 : str_cnt;
                        if (((str_len2 < str_cnt) ? str_len2 : str_cnt)
                            == 32'd0) begin
                            if (str_mode == 2'd3) begin
                                // cmpc with an empty string has "reached the
                                // end": S = src longer, Z = equal length
                                flags_wen <= 1'b1;
                                flags_wdata <= {psw[3:2], str_cnt > str_len2,
                                                str_cnt == str_len2};
                            end
                            // movcfu with nothing to copy can still have
                            // a whole dst to fill (svf's boot RAM clear is
                            // exactly that: slen 0, dlen 0x7FFE)
                            state <= (str_fill && str_cnt < str_len2)
                                     ? S_STR_FILL : S_STR_END1;
                        end else
                            state <= S_STR_RD;
                    end
                end
                S_STR_RD: state <= S_STR_WR;
                S_STR_WR: begin
                    if (str_mode == 2'd2) begin
                        // scan: skip stops at the first element != char
                        // (op2); search (schcu) at the first element ==
                        if ((((mem_rdata & wmask(s2_q))
                              != (op2_val & wmask(s2_q)))) ^ str_search) begin
                            flags_wen <= 1'b1;
                            flags_wdata <= {psw[3:1], 1'b0};   // Z = 0
                            state <= S_STR_END1;
                        end else if (str_i + 32'd1 == str_cnt) begin
                            str_i <= str_i + 32'd1;
                            flags_wen <= 1'b1;
                            flags_wdata <= {psw[3:1], 1'b1};   // Z = 1
                            state <= S_STR_END1;
                        end else begin
                            str_i <= str_i + 32'd1;
                            state <= S_STR_RD;
                        end
                    end else if (str_mode == 2'd3) begin
                        // cmpc: hold the src element, fetch the dst one
                        str_c1 <= mem_rdata & wmask(s2_q);
                        state <= S_STR_RD2;
                    end else begin
                        // copy: write happened combinationally this cycle
                        str_i <= str_i + 32'd1;
                        state <= (str_i + 32'd1 != str_dest) ? S_STR_RD
                               : (str_fill && str_cnt < str_len2)
                                 ? S_STR_FILL : S_STR_END1;
                    end
                end
                S_STR_RD2: state <= S_STR_CMP;
                S_STR_CMP: begin
                    // cmpc (NEC V60 manual p.7-24, Compare Character): stop
                    // at the first disagreement (S = src > dst unsigned,
                    // Z = 0, R28/R27 left ON the disagreeing elements) or at
                    // the end of the shorter string (S = src longer, Z =
                    // equal length, R28/R27 just past the compared span).
                    // CY/OV unchanged. MAME opCMPSTRB/H (op7a.hxx) agrees on
                    // the flags but writes R28/R27 = LENGTH + i, not the
                    // addresses the manual specifies; this follows the
                    // manual, as the core's movcu/skpcu already do for the
                    // same registers.
                    if (str_c1 != (mem_rdata & wmask(s2_q))) begin
                        flags_wen <= 1'b1;
                        flags_wdata <= {psw[3:2],
                                        str_c1 > (mem_rdata & wmask(s2_q)),
                                        1'b0};
                        state <= S_STR_END1;
                    end else if (str_i + 32'd1 == str_dest) begin
                        str_i <= str_i + 32'd1;
                        flags_wen <= 1'b1;
                        flags_wdata <= {psw[3:2], str_cnt > str_len2,
                                        str_cnt == str_len2};
                        state <= S_STR_END1;
                    end else begin
                        str_i <= str_i + 32'd1;
                        state <= S_STR_RD;
                    end
                end
                S_STR_FILL: begin
                    // MOVCF (NEC V60 manual p.7-57, Move Character with
                    // Filler): positions min(slen,dlen)..dlen-1 of dst get
                    // the fill character in R26 (its low byte/halfword);
                    // flags unchanged. Write happened combinationally this
                    // cycle. MAME opMOVSTRUB/UH(bFill=1, bStop=0),
                    // op7a.hxx, agrees: fill only when slen < dlen.
                    str_i <= str_i + 32'd1;
                    if (str_i + 32'd1 == str_len2) state <= S_STR_END1;
                end
                S_STR_END1: begin                   // R28 = final src pointer
                    wen <= 1'b1; waddr <= 5'd28;
                    unique case (str_mode)
                        // movcfu: str_i has run on through the fill, but
                        // R28 is the next SOURCE element = src + min*elem
                        // (manual "address of the next logical character";
                        // MAME R28 = m_op1 + i taken before the fill loop)
                        2'd0: wdata <= str_base1
                            + (str_fill ? str_dest : str_i) * str_elem;
                        2'd1: wdata <= str_base1
                            + (str_cnt - str_i - 32'd1) * str_elem;
                        // skpcd (NEC V60 manual p.7-102, SKPC): the
                        // element that ended the scan, counted from the
                        // tail; if none did, the one past the string in
                        // the scan direction, src - elem (str_i = cnt).
                        // MAME opSEARCHDB/DH agree on R28.
                        default: wdata <= str_down
                            ? str_base1 + (str_cnt - str_i - 32'd1) * str_elem
                            : str_base1 + str_i * str_elem;
                    endcase
                    state <= S_STR_END2;
                end
                S_STR_END2: begin                   // R27 = dst pointer / index
                    wen <= 1'b1; waddr <= 5'd27;
                    unique case (str_mode)
                        2'd0: wdata <= str_base2 + str_i * str_elem;
                        2'd1: wdata <= str_base2
                            + (str_len2 - str_i - 32'd1) * str_elem;
                        2'd3: wdata <= str_base2 + str_i * str_elem; // cmpc
                        // skpcu/skpcd: "the number of characters
                        // (offset) from the start position to the skip
                        // end position" (manual p.7-102). For skpcd the
                        // start is the tail, so this is NOT the element's
                        // index from the head, which MAME writes
                        // (opSEARCHDH R27 = i); docs/OPEN-QUESTIONS.md Q47.
                        default: wdata <= str_i;
                    endcase
                    pc <= next_seq_pc; state <= S_FETCH;
                end

                // ------------------------------------------ bit strings
                S_BS_LEN: begin                     // blen: Rn or 7-bit imm
                    bs_len <= ext1_b[7] ? rd_a : {25'd0, ext1_b[6:0]};
                    state <= S_BS_ADDR;
                end
                S_BS_ADDR: begin
                    // the downward form starts at the LAST bit of each
                    // string (offset + len - 1, as MAME's opMOVBSD); a bit
                    // address is byte (offset >>> 3), bit (offset & 7)
                    bs_sa <= op1_ea_q + {{3{bs_o1[31]}}, bs_o1[31:3]};
                    bs_sb <= bs_o1[2:0];
                    bs_da <= op2_ea_q + {{3{bs_o2[31]}}, bs_o2[31:3]};
                    bs_db <= bs_o2[2:0];
                    bs_i <= 32'd0;
                    bs_needs <= 1'b1; bs_needd <= 1'b1; bs_wpend <= 1'b0;
                    if (bs_len == 32'd0) begin      // nothing to move: no
                        pc <= next_seq_pc;          // accesses, R27/R28 kept
                        state <= S_FETCH;
                    end else
                        state <= S_BS_NEXT;
                end
                S_BS_NEXT: begin                    // access issued comb
                    if (bs_needs) state <= S_BS_CAPS;
                    else if (bs_wpend) bs_wpend <= 1'b0;
                    else if (bs_needd) state <= S_BS_CAPD;
                    else state <= S_BS_BIT;
                end
                S_BS_CAPS: begin
                    bs_sd <= mem_rdata[7:0]; bs_needs <= 1'b0;
                    state <= S_BS_NEXT;
                end
                S_BS_CAPD: begin
                    bs_dd <= mem_rdata[7:0]; bs_needd <= 1'b0;
                    state <= S_BS_NEXT;
                end
                S_BS_BIT: begin
                    bs_dd[bs_db] <= bs_sd[bs_sb];
                    bs_i <= bs_i + 32'd1;
                    if (bs_i + 32'd1 == bs_len)
                        state <= S_BS_FLUSH;        // R27/R28 stay on the
                    else begin                      // bytes of this last bit
                        if (bs_sb == (bs_down ? 3'd0 : 3'd7)) begin
                            bs_sa <= bs_down ? bs_sa - 32'd1 : bs_sa + 32'd1;
                            bs_needs <= 1'b1;
                        end
                        if (bs_db == (bs_down ? 3'd0 : 3'd7)) begin
                            bs_wa <= bs_da;
                            bs_da <= bs_down ? bs_da - 32'd1 : bs_da + 32'd1;
                            bs_wpend <= 1'b1; bs_needd <= 1'b1;
                        end
                        bs_sb <= bs_down ? bs_sb - 3'd1 : bs_sb + 3'd1;
                        bs_db <= bs_down ? bs_db - 3'd1 : bs_db + 3'd1;
                        state <= (bs_sb == (bs_down ? 3'd0 : 3'd7) ||
                                  bs_db == (bs_down ? 3'd0 : 3'd7))
                                 ? S_BS_NEXT : S_BS_BIT;
                    end
                end
                S_BS_FLUSH: state <= S_BS_END1;     // last dst byte (comb)
                S_BS_END1: begin
                    // NEC manual: afterwards R28/R27 hold the addresses of
                    // the bytes containing the final bit of each string
                    wen <= 1'b1; waddr <= 5'd28; wdata <= bs_sa;
                    state <= S_BS_END2;
                end
                S_BS_END2: begin
                    wen <= 1'b1; waddr <= 5'd27; wdata <= bs_da;
                    pc <= next_seq_pc; state <= S_FETCH;
                end

                // ------------------------------------------ bit fields
                S_BF_LEN: begin : bf_len_st
                    // blen: Rn or a 7-bit immediate; the byte holding the
                    // field (or the search's first bit) is base + offset >>> 3
                    logic [31:0] base, off, n;
                    base = is_bf_ins ? op2_ea_q : op1_ea_q;
                    off  = is_bf_ins ? bs_off2  : bs_off1;
                    n    = bf_ext[7] ? rd_a : {25'd0, bf_ext[6:0]};
                    bs_len <= n;
                    bs_sa <= base + {{3{off[31]}}, off[31:3]};
                    bs_sb <= off[2:0];
                    bs_i  <= 32'd0;
                    if (is_sb && n == 32'd0) begin
                        // empty search: Z = 1, dst = 0, R28 untouched (MAME's
                        // loop never runs)
                        flags_wen <= 1'b1;
                        flags_wdata <= {psw[3:1], 1'b1};
                        wb_res_q <= 32'd0;
                        state <= S_WB;
                    end else
                        state <= is_sb ? S_SB_RD : S_BF_RD;
                end
                S_BF_RD: state <= S_BF_CAP;          // dword read (comb)
                S_BF_CAP: begin
                    if (is_bf_ins) begin
                        wb_res_q <= bf_ins;
                        state <= S_BF_WR;
                    end else begin
                        wb_res_q <= bf_res;          // extbf: to dst via WB
                        state <= S_WB;
                    end
                end
                S_BF_WR: begin                       // write issued comb
                    pc <= next_seq_pc; state <= S_FETCH;
                end

                // sch0bsu / sch1bsu (NEC V60 manual SCH0BS p.7-94 / SCH1BS p.7-95; MAME
                // opSCHBS, op7a.hxx): scan upward for the first 0 (or 1) bit;
                // dst = its offset from the string start (Z = 0), or blen
                // when none (Z = 1); R28 = the byte holding the detected or
                // final bit; CY/OV/S unchanged. The offset is relative to the
                // start, as MAME writes it and as radmu's decoder needs (it
                // adds dst + 1 to its own bit cursor, 07FD2E).
                S_SB_RD: state <= S_SB_CAP;          // byte read (comb)
                S_SB_CAP: begin
                    bs_sd <= mem_rdata[7:0];
                    state <= S_SB_BIT;
                end
                S_SB_BIT: begin
                    if (bs_sd[bs_sb] == (exec_q == 8'd73)) begin
                        wen <= 1'b1; waddr <= 5'd28; wdata <= bs_sa;
                        flags_wen <= 1'b1;
                        flags_wdata <= {psw[3:1], 1'b0};
                        wb_res_q <= bs_i;
                        state <= S_WB;
                    end else if (bs_i + 32'd1 == bs_len) begin
                        wen <= 1'b1; waddr <= 5'd28; wdata <= bs_sa;
                        flags_wen <= 1'b1;
                        flags_wdata <= {psw[3:1], 1'b1};
                        wb_res_q <= bs_len;
                        state <= S_WB;
                    end else begin
                        bs_i <= bs_i + 32'd1;
                        bs_sb <= bs_sb + 3'd1;
                        if (bs_sb == 3'd7) begin
                            bs_sa <= bs_sa + 32'd1;
                            state <= S_SB_RD;
                        end
                    end
                end

                // ------------------------------------------ pushm/popm
                S_PUSHM: begin
                    if (mask_q == 32'd0) begin
                        wen <= 1'b1; waddr <= 5'd31; wdata <= sp_shadow;
                        pc <= next_seq_pc; state <= S_FETCH;
                    end else if (mask_q[mask_idx[4:0]]) begin
                        // wrote this cycle (comb): advance
                        mask_q[mask_idx[4:0]] <= 1'b0;
                        sp_shadow <= sp_shadow - 32'd4;
                        mask_idx <= mask_idx - 6'd1;
                    end else
                        mask_idx <= mask_idx - 6'd1;
                end
                S_POPM: begin
                    if (mask_q == 32'd0) begin
                        wen <= 1'b1; waddr <= 5'd31; wdata <= sp_shadow;
                        pc <= next_seq_pc; state <= S_FETCH;
                    end else if (mask_q[mask_idx[4:0]]) begin
                        state <= S_POPM_CONSUME;
                    end else
                        mask_idx <= mask_idx + 6'd1;
                end
                S_POPM_CONSUME: begin
                    if (mask_idx == 6'd31) begin
                        psw_wen <= 1'b1;
                        psw_wdata <= {psw[31:16], mem_rdata[15:0]};
                    end else begin
                        wen <= 1'b1; waddr <= mask_idx[4:0];
                        wdata <= mem_rdata;
                    end
                    mask_q[mask_idx[4:0]] <= 1'b0;
                    sp_shadow <= sp_shadow + 32'd4;
                    mask_idx <= mask_idx + 6'd1;
                    state <= S_POPM;
                end

                S_TRAP: ;                           // unimplemented: stop

                default: state <= S_FETCH;
            endcase
        end
    end

endmodule
