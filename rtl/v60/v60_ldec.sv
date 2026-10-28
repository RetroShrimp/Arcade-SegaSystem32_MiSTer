// v60_ldec.sv — NEC V60 instruction length/format decoder.
//
// Given the first 14 bytes of an instruction stream, produces the total
// instruction length, format class, and operand-size fields. Implements the
// NEC manual's Formats I-VII (ch.6) with addressing-mode extension sizes;
// the per-opcode table is v60_optab.svh. Checked against every distinct
// instruction Golden Axe executes.
//
// This combinational block is the front half of the decode stage: the
// microcode sequencer consumes {ftype, opsizes, length} plus the raw bytes.
//
// ftype codes: 0 F1, 1 F2, 2 F1F2, 3 F3, 4 F4a, 5 F4b,
// 6 F5, 7 F6, 8 F7a, 9 F7b, 10 F7c, 13 ext group 58-5F, 14 loop group C6/C7,
// 15 unhandled.

module v60_ldec (
    input  logic [111:0] bytes_in,   // byte0 = [111:104] ... byte13 = [7:0]
    output logic [5:0]   length,     // total instruction bytes (1..20)
    output logic [3:0]   ftype,      // resolved format (F1F2 -> F1 or F2)
    output logic [1:0]   opsize1,
    output logic [1:0]   opsize2,
    output logic [4:0]   am1_len,    // first AM field length (F1/F2/F3/F7)
    output logic [4:0]   am2_len,    // second AM field length (F2/F7)
    output logic         valid       // 0 = unhandled/illegal encoding
);

    `include "v60_optab.svh"

    // addressing-mode field length; w = 10 bytes starting at the mode byte
    // returns AM field length in bytes; 0 = illegal encoding
    function automatic logic [4:0] am_len (
        input logic [79:0] w,        // mode byte = w[79:72], next = w[71:64]
        input logic        m,
        input logic [1:0]  opsize
    );
        logic [7:0] mod, nxt;
        logic [2:0] top, t2;
        logic [4:0] sub, sub2;
        begin
            mod = w[79:72];
            nxt = w[71:64];
            top = mod[7:5];
            t2  = nxt[7:5];
            sub = mod[4:0];
            sub2 = nxt[4:0];
            am_len = 5'd1;
            if (m) begin
                unique case (top)
                    3'd0: am_len = 5'd3;                 // double disp 8
                    3'd1: am_len = 5'd5;                 // double disp 16
                    3'd2: am_len = 5'd9;                 // double disp 32
                    3'd3, 3'd4, 3'd5: am_len = 5'd1;     // Rn / [Rn+] / [-Rn]
                    3'd6: begin                          // indexed forms
                        unique case (t2)
                            3'd0: am_len = 5'd3;         // disp8 idx
                            3'd1: am_len = 5'd4;         // disp16 idx
                            3'd2: am_len = 5'd6;         // disp32 idx
                            3'd3: am_len = 5'd2;         // [Rn](Rx)
                            3'd4: am_len = 5'd3;         // disp8 indirect idx
                            3'd5: am_len = 5'd4;
                            3'd6: am_len = 5'd6;
                            default: begin               // t2 == 7
                                unique case (sub2)
                                    5'd16, 5'd24: am_len = 5'd3;  // PC disp 8 (ind) idx
                                    5'd17, 5'd25: am_len = 5'd4;  // 16
                                    5'd18, 5'd26,
                                    5'd19, 5'd27: am_len = 5'd6;  // 32 / /addr
                                    default: am_len = 5'd0;
                                endcase
                            end
                        endcase
                    end
                    default: am_len = 5'd0;              // top == 7 illegal
                endcase
            end else begin
                unique case (top)
                    3'd0: am_len = 5'd2;                 // disp8
                    3'd1: am_len = 5'd3;                 // disp16
                    3'd2: am_len = 5'd5;                 // disp32
                    3'd3: am_len = 5'd1;                 // [Rn]
                    3'd4: am_len = 5'd2;                 // disp8 indirect
                    3'd5: am_len = 5'd3;
                    3'd6: am_len = 5'd5;
                    default: begin                       // top == 7
                        unique casez (sub)
                            5'b0????: am_len = 5'd1;     // immediate quick
                            5'd16, 5'd24: am_len = 5'd2; // PC disp 8 (ind)
                            5'd17, 5'd25: am_len = 5'd3;
                            5'd18, 5'd26,
                            5'd19, 5'd27: am_len = 5'd5; // 32 / /addr (def)
                            5'd20: begin                 // sized immediate
                                unique case (opsize)
                                    2'd0: am_len = 5'd2;
                                    2'd1: am_len = 5'd3;
                                    2'd2: am_len = 5'd5;
                                    default: am_len = 5'd0;
                                endcase
                            end
                            5'd28: am_len = 5'd3;        // PC dbl disp 8
                            5'd29: am_len = 5'd5;
                            5'd30: am_len = 5'd9;
                            default: am_len = 5'd0;
                        endcase
                    end
                endcase
            end
        end
    endfunction

    logic [7:0]  b0, b1;
    logic [7:0]  ent;
    logic [3:0]  ft;
    logic [1:0]  s1, s2;
    logic [79:0]  w1, w1f3;
    logic [111:0] sh2;
    logic [4:0]   l1, l2;
    logic [5:0]   p2;                // byte position of the second AM field

    always_comb begin
        b0  = bytes_in[111:104];
        b1  = bytes_in[103:96];
        ent = v60_optab(b0);
        ft  = ent[7:4];
        s1  = ent[3:2];
        s2  = ent[1:0];

        // extended (58-5F, second-byte low 5 bits) and loop (C6/C7,
        // second-byte top 3 bits) groups resolve through sub-tables
        if (ft == 4'd13) begin
            unique case (b0[2:0])
                3'd0: ent = v60_optab_58({b1[4:0]});
                3'd1: ent = v60_optab_59({b1[4:0]});
                3'd2: ent = v60_optab_5A({b1[4:0]});
                3'd3: ent = v60_optab_5B({b1[4:0]});
                3'd4: ent = v60_optab_5C({b1[4:0]});
                3'd5: ent = v60_optab_5D({b1[4:0]});
                3'd6: ent = v60_optab_5E({b1[4:0]});
                default: ent = v60_optab_5F({b1[4:0]});
            endcase
            ft = ent[7:4];
            s1 = ent[3:2];
            s2 = ent[1:0];
        end else if (ft == 4'd14) begin
            ent = b0[0] ? v60_optab_C7({2'b0, b1[7:5]})
                        : v60_optab_C6({2'b0, b1[7:5]});
            ft = ent[7:4];
            s1 = ent[3:2];
            s2 = ent[1:0];
        end

        // resolve F1F2 by the second byte's top bit
        if (ft == 4'd2)
            ft = b1[7] ? 4'd1 : 4'd0;

        // first AM window: F3 reads the AM at byte1, everything else byte2
        w1   = bytes_in[95:16];      // bytes 2..11
        w1f3 = bytes_in[103:24];     // bytes 1..10
        l1   = 5'd0;
        l2   = 5'd0;
        p2   = 6'd0;
        sh2  = 112'd0;
        length = 6'd1;
        valid  = 1'b1;

        unique case (ft)
            4'd0: begin                                    // F1
                l1 = am_len(w1, b1[6], s1);
                length = 6'd2 + 6'(l1);
            end
            4'd1, 4'd8, 4'd9, 4'd10: begin                 // F2 / F7a/b/c
                l1 = am_len(w1, b1[6], s1);
                // second AM position: F2 at 2+l1; F7a/F7b at 3+l1 (skips
                // the string-length/extension byte); F7c at 2+l1, its one
                // extension byte following both AMs (MAME
                // F7cDecodeOperands; 2026-10-27, Rad Mobile's subdc/insbfr,
                // the first F7c instructions the core executes)
                p2 = (ft == 4'd1 || ft == 4'd10) ? (6'd2 + 6'(l1))
                                                 : (6'd3 + 6'(l1));
                sh2 = bytes_in << ({4'b0, p2} * 8);        // window at byte p2
                l2 = am_len(sh2[111:32], b1[5], s2);
                unique case (ft)
                    4'd1:    length = 6'd2 + 6'(l1) + 6'(l2);
                    4'd8:    length = 6'd4 + 6'(l1) + 6'(l2);
                    default: length = 6'd3 + 6'(l1) + 6'(l2);
                endcase
            end
            4'd3: begin                                    // F3
                l1 = am_len(w1f3, b0[0], s1);
                length = 6'd1 + 6'(l1);
            end
            4'd4: length = 6'd2;                           // F4a
            4'd5: length = 6'd3;                           // F4b
            4'd6: length = 6'd1;                           // F5
            4'd7: length = 6'd4;                           // F6
            default: valid = 1'b0;                         // unhandled
        endcase

        // sentinel 0 from am_len marks an illegal encoding
        if ((ft <= 4'd1 || ft == 4'd3 || ft >= 4'd8) && l1 == 5'd0) valid = 1'b0;
        if ((ft == 4'd1 || ft >= 4'd8) && l2 == 5'd0) valid = 1'b0;

        ftype   = ft;
        opsize1 = s1;
        opsize2 = s2;
        am1_len = l1;
        am2_len = l2;
    end

endmodule
