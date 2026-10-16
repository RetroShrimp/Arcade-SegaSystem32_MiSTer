// v60_ea.sv — NEC V60 effective-address computation (all addressing modes;
// deferred modes output the stage-1 pointer, deferred-indexed additionally
// report the scaled index via def_idxoff for the sequencer's stage 2).
//
// Computes the operand address for one addressing-mode field, given the AM
// bytes, the AM-class bit (m, from the format's second byte), the operand
// size, and the values of the referenced base register and PC. The register
// number the mode byte names is exported (reg_sel) so the datapath performs
// the regfile lookup; base_wb/base_wen implement the auto-increment /
// auto-decrement side effect.
//
// Mode coverage (NEC manual ch.3; encodings as decoded by v60_ldec.sv;
// behaviour checked against the accesses MAME makes):
//   m=0: disp8/16/32[Rn], [Rn], [disp8/16/32[Rn]]*, mode-7 subs:
//        immediate-quick*, PC disp, /addr, immediate*, deferred*, PC dbl*
//   m=1: dbl-disp*, Rn (register direct*), [Rn+], [-Rn], indexed forms*
//   (*) = no simple EA or requires a memory fetch: flagged via ea_kind for
//   the sequencer; deferred modes output the stage-1 pointer address.
//
// ea_kind: 0 = memory EA valid, 1 = register direct (no EA), 2 = immediate
// (quick or sized; value extraction is the decoder's job), 3 = deferred
// (ea = pointer address; sequencer must read memory and finish), 4 = illegal.

module v60_ea (
    input  logic [79:0] am_bytes,   // mode byte = [79:72], extensions follow
    input  logic        m,
    input  logic [1:0]  opsize,     // 0 byte, 1 half, 2 word
    input  logic [31:0] reg_val,    // value of register reg_sel
    input  logic [31:0] idx_val,    // value of index register (indexed modes)
    input  logic [31:0] pc,         // instruction start address
    output logic [4:0]  reg_sel,    // register named by the mode byte
    output logic [4:0]  idx_sel,    // index register (indexed modes)
    output logic [31:0] ea,
    output logic [2:0]  ea_kind,
    output logic [31:0] base_wb,    // auto inc/dec writeback value
    output logic        base_wen,
    // deferred-indexed modes: scaled index the sequencer adds to the
    // fetched pointer (EA = *[stage-1] + Rx*size, per MAME am1
    // DisplacementIndirectIndexed / PCDisplacementIndirectIndexed /
    // DirectAddressDeferredIndexed); 0 for every other mode
    output logic [31:0] def_idxoff
);

    localparam logic [2:0] K_MEM = 3'd0, K_REG = 3'd1, K_IMM = 3'd2,
                           K_DEF = 3'd3, K_BAD = 3'd4;

    logic [7:0]  mod, nxt;
    logic [2:0]  top;
    logic [4:0]  sub;
    logic [31:0] d8, d16, d32;      // sign-extended displacement candidates
    logic [31:0] size;

    always_comb begin
        mod = am_bytes[79:72];
        nxt = am_bytes[71:64];
        top = mod[7:5];
        sub = mod[4:0];
        reg_sel = mod[4:0];
        idx_sel = nxt[4:0];

        d8  = {{24{am_bytes[71]}}, am_bytes[71:64]};
        // multi-byte displacements are little-endian in the stream
        d16 = {{16{am_bytes[63]}}, am_bytes[63:56], am_bytes[71:64]};
        d32 = {am_bytes[47:40], am_bytes[55:48], am_bytes[63:56], am_bytes[71:64]};

        size = (opsize == 2'd0) ? 32'd1 : (opsize == 2'd1) ? 32'd2 : 32'd4;

        ea       = 32'd0;
        ea_kind  = K_BAD;
        base_wb  = reg_val;
        base_wen = 1'b0;
        def_idxoff = 32'd0;

        if (!m) begin
            unique case (top)
                3'd0: begin ea = reg_val + d8;  ea_kind = K_MEM; end
                3'd1: begin ea = reg_val + d16; ea_kind = K_MEM; end
                3'd2: begin ea = reg_val + d32; ea_kind = K_MEM; end
                3'd3: begin ea = reg_val;       ea_kind = K_MEM; end
                3'd4: begin ea = reg_val + d8;  ea_kind = K_DEF; end
                3'd5: begin ea = reg_val + d16; ea_kind = K_DEF; end
                3'd6: begin ea = reg_val + d32; ea_kind = K_DEF; end
                default: begin                  // mode 7 subcodes
                    unique casez (sub)
                        5'b0????: ea_kind = K_IMM;               // quick
                        5'd16: begin ea = pc + d8;  ea_kind = K_MEM; end
                        5'd17: begin ea = pc + d16; ea_kind = K_MEM; end
                        5'd18: begin ea = pc + d32; ea_kind = K_MEM; end
                        5'd19: begin ea = d32;      ea_kind = K_MEM; end
                        5'd20: ea_kind = K_IMM;                  // sized imm
                        5'd24: begin ea = pc + d8;  ea_kind = K_DEF; end
                        5'd25: begin ea = pc + d16; ea_kind = K_DEF; end
                        5'd26: begin ea = pc + d32; ea_kind = K_DEF; end
                        5'd27: begin ea = d32;      ea_kind = K_DEF; end
                        // PC double displacement: stage-1 pointer = pc+d
                        5'd28: begin ea = pc + d8;  ea_kind = K_DEF; end
                        5'd29: begin ea = pc + d16; ea_kind = K_DEF; end
                        5'd30: begin ea = pc + d32; ea_kind = K_DEF; end
                        default: ea_kind = K_BAD;
                    endcase
                end
            endcase
        end else begin
            unique case (top)
                // double displacement: stage-1 pointer address = Rn + d1
                3'd0: begin ea = reg_val + d8;  ea_kind = K_DEF; end
                3'd1: begin ea = reg_val + d16; ea_kind = K_DEF; end
                3'd2: begin ea = reg_val + d32; ea_kind = K_DEF; end
                3'd3: ea_kind = K_REG;                     // register direct
                3'd4: begin                                // [Rn+]
                    ea = reg_val;
                    ea_kind = K_MEM;
                    base_wb = reg_val + size;
                    base_wen = 1'b1;
                end
                3'd5: begin                                // [-Rn]
                    ea = reg_val - size;
                    ea_kind = K_MEM;
                    base_wb = reg_val - size;
                    base_wen = 1'b1;
                end
                3'd6: begin
                    // indexed families: EA = base (second byte reg) +
                    // sign-extended displacement + index (mod[4:0]) scaled
                    // by the operand size (verified vs MAME am1 decoders)
                    reg_sel = nxt[4:0];
                    idx_sel = mod[4:0];
                    unique case (nxt[7:5])
                        3'd0: begin                        // disp8[Rn](Rx)
                            ea = reg_val + idx_val * size
                               + {{24{am_bytes[63]}}, am_bytes[63:56]};
                            ea_kind = K_MEM;
                        end
                        3'd1: begin                        // disp16[Rn](Rx)
                            ea = reg_val + idx_val * size
                               + {{16{am_bytes[55]}}, am_bytes[55:48],
                                  am_bytes[63:56]};
                            ea_kind = K_MEM;
                        end
                        3'd2: begin                        // disp32[Rn](Rx)
                            ea = reg_val + idx_val * size
                               + {am_bytes[39:32], am_bytes[47:40],
                                  am_bytes[55:48], am_bytes[63:56]};
                            ea_kind = K_MEM;
                        end
                        3'd3: begin                        // [Rn](Rx)
                            ea = reg_val + idx_val * size;
                            ea_kind = K_MEM;
                        end
                        // deferred indexed: stage-1 pointer = Rn + disp,
                        // final EA = *ptr + Rx*size (added by sequencer)
                        3'd4: begin                        // [disp8[Rn]](Rx)
                            ea = reg_val
                               + {{24{am_bytes[63]}}, am_bytes[63:56]};
                            ea_kind = K_DEF;
                            def_idxoff = idx_val * size;
                        end
                        3'd5: begin                        // [disp16[Rn]](Rx)
                            ea = reg_val
                               + {{16{am_bytes[55]}}, am_bytes[55:48],
                                  am_bytes[63:56]};
                            ea_kind = K_DEF;
                            def_idxoff = idx_val * size;
                        end
                        3'd6: begin                        // [disp32[Rn]](Rx)
                            ea = reg_val
                               + {am_bytes[39:32], am_bytes[47:40],
                                  am_bytes[55:48], am_bytes[63:56]};
                            ea_kind = K_DEF;
                            def_idxoff = idx_val * size;
                        end
                        3'd7: begin
                            // PC-relative / direct-address indexed forms
                            unique case (nxt[4:0])
                                5'd16: begin       // disp8[PC](Rx)
                                    ea = pc + idx_val * size
                                       + {{24{am_bytes[63]}}, am_bytes[63:56]};
                                    ea_kind = K_MEM;
                                end
                                5'd17: begin       // disp16[PC](Rx)
                                    ea = pc + idx_val * size
                                       + {{16{am_bytes[55]}}, am_bytes[55:48],
                                          am_bytes[63:56]};
                                    ea_kind = K_MEM;
                                end
                                5'd18: begin       // disp32[PC](Rx)
                                    ea = pc + idx_val * size
                                       + {am_bytes[39:32], am_bytes[47:40],
                                          am_bytes[55:48], am_bytes[63:56]};
                                    ea_kind = K_MEM;
                                end
                                5'd19: begin       // /addr(Rx)
                                    ea = idx_val * size
                                       + {am_bytes[39:32], am_bytes[47:40],
                                          am_bytes[55:48], am_bytes[63:56]};
                                    ea_kind = K_MEM;
                                end
                                // deferred: stage-1 ptr, then *ptr + Rx*size
                                5'd24: begin       // [disp8[PC]](Rx)
                                    ea = pc
                                       + {{24{am_bytes[63]}}, am_bytes[63:56]};
                                    ea_kind = K_DEF;
                                    def_idxoff = idx_val * size;
                                end
                                5'd25: begin       // [disp16[PC]](Rx)
                                    ea = pc
                                       + {{16{am_bytes[55]}}, am_bytes[55:48],
                                          am_bytes[63:56]};
                                    ea_kind = K_DEF;
                                    def_idxoff = idx_val * size;
                                end
                                5'd26: begin       // [disp32[PC]](Rx)
                                    ea = pc
                                       + {am_bytes[39:32], am_bytes[47:40],
                                          am_bytes[55:48], am_bytes[63:56]};
                                    ea_kind = K_DEF;
                                    def_idxoff = idx_val * size;
                                end
                                5'd27: begin       // [/addr](Rx)
                                    ea = {am_bytes[39:32], am_bytes[47:40],
                                          am_bytes[55:48], am_bytes[63:56]};
                                    ea_kind = K_DEF;
                                    def_idxoff = idx_val * size;
                                end
                                default: ea_kind = K_BAD;
                            endcase
                        end
                        default: ea_kind = K_BAD;
                    endcase
                end
                default: ea_kind = K_BAD;
            endcase
        end
    end

endmodule
