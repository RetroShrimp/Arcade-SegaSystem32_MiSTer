// v60.sv — NEC V60 core: sequencer wiring fetch/decode (v60_ldec), operand
// resolution (v60_ea), register file (v60_regs) and the verified datapath
// (v60_alu, v60_shifter, v60_muldiv) into an executing CPU.
//
// It implements the instructions the supported games execute, plus
// external interrupts and NMI. An instruction it does not implement stops
// the core in S_TRAP with `trap` set and the opcode on trap_op.
//
// Instruction bytes arrive as a 14-byte window at fetch_pc (from the
// prefetch queue, v60_pfu). Data accesses are transactions of 1, 2 or 4
// bytes at any alignment: a one-cycle mem_re/mem_we strobe in an issue
// state, with the data used in the next state. The bus unit (v60_bcu)
// turns them into the real CPU's 16-bit bus cycles. wait_hold freezes the
// core.

module v60 (
    input  logic         clk,
    input  logic         rst,

    output logic [31:0]  fetch_pc,
    input  logic [111:0] fetch_bytes,

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
        S_TRAP
    } state_e;
    state_e state;

    logic [31:0] pc;
    logic [111:0] iw;
    logic [5:0]  len_q;
    logic [7:0]  exec_q;
    logic [3:0]  ft_q;
    logic [1:0]  s1_q, s2_q;
    logic [4:0]  l1_q, l2_q;

    // ---------------------------------------------------------------- decode
    logic [5:0] ilen;
    logic [3:0] ftype;
    logic [1:0] s1, s2;
    logic [4:0] am1l, am2l;
    logic       ldec_valid;

    v60_ldec u_ldec (
        .bytes_in(iw), .length(ilen), .ftype(ftype),
        .opsize1(s1), .opsize2(s2), .am1_len(am1l), .am2_len(am2l),
        .valid(ldec_valid)
    );

    logic [7:0] b0, b1;
    assign b0 = iw[111:104];
    assign b1 = iw[103:96];

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
        op1_off = 6'd2; op2_off = 6'd2;
        op1_m = b1[6]; op2_m = b1[5];
        wb_to_op1 = 1'b0;
        unique case (ft_q)
            4'd0: begin                       // F1
                if (b1[5]) begin
                    op1_d = OD_AM;  op1_off = 6'd2; op1_m = b1[6];
                    op2_d = OD_REG;
                end else begin
                    op1_d = OD_REG;
                    op2_d = OD_AM;  op2_off = 6'd2; op2_m = b1[6];
                end
            end
            4'd1, 4'd8, 4'd9, 4'd10: begin    // F2 / F7 family
                op1_d = OD_AM; op1_off = 6'd2;               op1_m = b1[6];
                op2_d = OD_AM; op2_off = 6'd2 + 6'(l1_q);    op2_m = b1[5];
                if (ft_q != 4'd1)
                    op2_off = 6'd3 + 6'(l1_q);               // skip ext byte
            end
            4'd3: begin                       // F3
                op1_d = OD_AM; op1_off = 6'd1; op1_m = b0[0];
                wb_to_op1 = 1'b1;
            end
            default: ;                        // F4/F5/F6: handled in EXEC
        endcase
    end

    // ---------------------------------------------------------------- regs
    logic [4:0]  ra_a, ra_b, waddr;
    logic [31:0] rd_a, rd_b, wdata;
    logic        wen;
    logic [31:0] psw;
    logic        psw_wen, flags_wen;
    logic [31:0] psw_wdata;
    logic [3:0]  flags_wdata;
    logic [31:0] preg_rdata, preg_wdata;
    logic        preg_wen;
    logic [3:0]  preg_sel_core;
    assign preg_sel_core = (exec_q == 8'd30) ? op1_val[3:0]
                         : (exec_q == 8'd53) ? 4'd5      // trap: SBR
                         : (state == S_XCP_SBR) ? 4'd5   // irq: SBR
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
        .preg_wen(preg_wen_m), .preg_wdata(preg_wdata_m)
    );

    // ---------------------------------------------------------------- EA
    logic [79:0] ea_bytes;
    logic        ea_m;
    logic [1:0]  ea_size;
    logic [31:0] ea_out, ea_wb, ea_defidx;
    logic [4:0]  ea_regsel, ea_idxsel;
    logic [2:0]  ea_kind;
    logic        ea_wen;
    logic [5:0]  cur_off;             // AM offset for the active operand

    // AM window extraction: bytes at cur_off .. cur_off+9
    logic [111:0] iw_sh;
    assign iw_sh = iw << ({4'b0, cur_off} * 8);
    assign ea_bytes = iw_sh[111:32];

    v60_ea u_ea (
        .am_bytes(ea_bytes), .m(ea_m), .opsize(ea_size),
        .reg_val(rd_b), .idx_val(rd_a), .pc(pc),
        .reg_sel(ea_regsel), .idx_sel(ea_idxsel),
        .ea(ea_out), .ea_kind(ea_kind),
        .base_wb(ea_wb), .base_wen(ea_wen),
        .def_idxoff(ea_defidx)
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

    logic        md_start, md_busy, md_done;
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

    // Both extended forms pass a real opcode (divux -> OP_DIVU, divx ->
    // OP_DIV) rather than exec_q[4:0], so the unit can tell signed from
    // unsigned extended divide; mode_dvx alone cannot express that.
    assign md_op = (exec_q == 8'd56) ? 5'd16     // rem  -> signed divide
                 : (exec_q == 8'd57) ? 5'd17     // remu -> unsigned divide
                 : (exec_q == 8'd54) ? 5'd17     // divux
                 : (exec_q == 8'd60) ? 5'd16     // divx
                 : exec_q[4:0];
    v60_muldiv u_md (
        .clk(clk), .rst(rst), .start(md_start),
        .op(md_op), .width(exec_width),
        .a(op2_val), .b(op1_val), .flags_in(psw[3:0]),
        // dvx pair high: register form reads Rn+1 on port A; memory form
        // has the high dword on mem_rdata (read issued in S_DVX_RD)
        .a_hi(op2_isreg ? rd_a : mem_rdata), .mode_dvx(is_dvx_op),
        .mode_rem(exec_q == 8'd56 || exec_q == 8'd57),
        .busy(md_busy), .done(md_done),
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
        (exec_q == 8'd61);                       // cmpc: src string address

    // op2 old value needed from MEMORY (RMW, bit ops, xch, updpsw, test1);
    // register destinations always read via the port (width merge), which
    // is why this term must NOT include the registered op2_isreg flag
    logic op2_need_val;
    assign op2_need_val =
        is_alu || is_shift || is_md ||
        (exec_q >= 8'd33 && exec_q <= 8'd36) ||
        (exec_q == 8'd41) || (exec_q == 8'd43) ||
        (exec_q == 8'd52);                          // skpcu: char value

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
    logic [2:0]  xcp_vecq;
    logic        dvx_ph;              // divux mem writeback phase (0=quot)

    // string-op working registers (movcu/movcd/skpcu/schcu/cmpc)
    logic [1:0]  str_mode;            // 0 = up-copy, 1 = down-copy, 2 = scan,
                                      // 3 = compare (cmpc)
    logic [31:0] str_c1;              // cmpc: src element awaiting its dst
    logic        str_search;          // scan polarity: 0 = skip (stop on !=),
                                      // 1 = search (stop on ==)  [schcu]
    logic [31:0] str_base1, str_base2;
    logic [31:0] str_i;               // element index
    logic [31:0] str_cnt, str_len2;   // len1 (element count) and len2
    logic [31:0] str_dest;            // min(len1,len2) for copies
    logic [31:0] str_elem;            // element size in bytes
    logic [7:0]  ext1_b, ext2_b;      // F7a length extension bytes

    // element addresses per mode (down-copy walks high-to-low)
    logic [31:0] str_a1, str_a2;
    always_comb begin
        if (str_mode == 2'd1) begin
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
        ? {{24{iw[103]}}, iw[103:96]}
        : {{16{iw[95]}}, iw[95:88], iw[103:96]};
    assign disp_f6 = {{16{iw[87]}}, iw[87:80], iw[95:88]};

    // F7a length-extension bytes: at 2+l1 and 3+l1+l2
    logic [111:0] iw_e1, iw_e2;
    assign iw_e1 = iw << ((6'd2 + {1'b0, l1_q}) * 8);
    assign iw_e2 = iw << ((6'd3 + {1'b0, l1_q} + {1'b0, l2_q}) * 8);
    assign ext1_b = iw_e1[111:104];
    assign ext2_b = iw_e2[111:104];

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
                if (exec_q == 8'd27) begin          // rsr: pop PC
                    mem_re = 1'b1; mem_addr = rd_a; mem_size = 3'd4;
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
                if (is_dvx_op && op2_ismem) begin
                    // divx/divux memory form: read dividend low dword
                    mem_re = 1'b1; mem_addr = op2_ea_q; mem_size = 3'd4;
                end
            end
            S_DVX_RD: begin
                // dividend high dword; lands on mem_rdata during the
                // muldiv start cycle (a_hi mux above)
                mem_re = 1'b1; mem_addr = op2_ea_q + 32'd4; mem_size = 3'd4;
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
            S_XCP_P1: begin
                ra_a = 5'd31;
                mem_we = 1'b1; mem_addr = rd_a - 32'd4; mem_size = 3'd4;
                mem_wdata = xcp_irq ? xcp_oldpsw : xcp_code;
            end
            S_XCP_P2: begin
                ra_a = 5'd31;
                mem_we = 1'b1; mem_addr = rd_a - 32'd8; mem_size = 3'd4;
                mem_wdata = xcp_irq ? pc : xcp_oldpsw;
            end
            S_XCP_P3: begin
                ra_a = 5'd31;
                mem_we = 1'b1; mem_addr = rd_a - 32'd12; mem_size = 3'd4;
                mem_wdata = pc + {26'd0, len_q};
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
    logic       wb_isreg, wb_ismem;
    logic [4:0] wb_reg;
    logic [31:0] wb_old;
    assign wb_isreg = wb_to_op1 ? op1_isreg : op2_isreg;
    assign wb_ismem = wb_to_op1 ? op1_ismem : op2_ismem;
    assign wb_reg   = wb_to_op1 ? op1_reg_q : op2_reg_q;
    assign wb_old   = wb_to_op1 ? op1_val   : op2_val;

    always_ff @(posedge clk) begin
        wen <= 1'b0; psw_wen <= 1'b0; flags_wen <= 1'b0;
        preg_wen <= 1'b0; md_start <= 1'b0;

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
                    op1_ea_q <= mem_rdata + ea_defidx +
                        (def_has_d2(ea_bytes, op1_m) ? def_disp2(ea_bytes)
                                                     : 32'd0);
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
                        (def_has_d2(ea_bytes, op2_m) ? def_disp2(ea_bytes)
                                                     : 32'd0);
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
                            8'd54, 8'd60: begin     // divux / divx
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
                            8'd50, 8'd51, 8'd52, 8'd55, 8'd61: begin
                                // movcu/movcd/skpcu/schcu — schcu (55) is
                                // the skip scan with inverted match
                                // polarity (stop on ==, not !=); identical
                                // operand form and R27/R28/Z contract
                                // (MAME opSEARCHUB/UH, op7a.hxx:437).
                                // cmpc (61) walks both strings upward like
                                // movcu, reading instead of writing the dst
                                // (mode 3, S_STR_RD2/S_STR_CMP).
                                str_mode <= (exec_q == 8'd50) ? 2'd0
                                          : (exec_q == 8'd51) ? 2'd1
                                          : (exec_q == 8'd61) ? 2'd3 : 2'd2;
                                str_search <= (exec_q == 8'd55);
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
                            8'd46: begin                // retis
                                nmi_busy <= 1'b0;       // NMI window
                                state <= S_RETIS1;      // reopens
                            end
                            8'd44, 8'd45: begin
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
                        if (is_dvx_op) begin
                            if (op2_isreg) begin
                                wen <= 1'b1; waddr <= op2_reg_q;
                                wdata <= md_res;    // quotient -> Rn
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
                    psw_wen <= 1'b1; psw_wdata <= mem_rdata;
                    wen <= 1'b1; waddr <= 5'd31;
                    wdata <= rd_a + 32'd8 + op1_val;
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
                    wen <= 1'b1; waddr <= 5'd31;    // SP -= 12
                    wdata <= rd_a - 32'd12;
                    pc <= xcp_tgt;
                    state <= S_FETCH;
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
                            state <= S_STR_END1;
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
                        state <= (str_i + 32'd1 == str_dest) ? S_STR_END1
                                                             : S_STR_RD;
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
                S_STR_END1: begin                   // R28 = final src pointer
                    wen <= 1'b1; waddr <= 5'd28;
                    unique case (str_mode)
                        2'd0: wdata <= str_base1 + str_i * str_elem;
                        2'd1: wdata <= str_base1
                            + (str_cnt - str_i - 32'd1) * str_elem;
                        default: wdata <= str_base1 + str_i * str_elem;
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
                        default: wdata <= str_i;    // skpcu: element index
                    endcase
                    pc <= next_seq_pc; state <= S_FETCH;
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
