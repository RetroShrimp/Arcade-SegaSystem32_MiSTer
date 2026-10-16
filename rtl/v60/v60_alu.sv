// v60_alu.sv — NEC V60 (uPD70616) integer ALU with PSW flag generation.
//
// References: NEC V60 architecture; flag behaviour checked against MAME
// 0.288 single-step results from Golden Axe code.
//
// Flag register nibble matches PSW[3:0]: bit0 Z, bit1 S, bit2 OV, bit3 CY.
// - add/sub/cmp/neg/inc/dec: all four flags computed at operation width.
// - and/or/xor/not: OV cleared, S/Z computed, CY preserved.
// - Result is width-masked; merging into the upper destination bits is the
//   datapath's job (verified preserved on real execution).
//
// Purely combinational: the microcode sequencer registers the outputs.

module v60_alu (
    input  logic [3:0]  op,       // see v60_alu_op_e below
    input  logic [1:0]  width,    // 0 = byte, 1 = half, 2 = word
    input  logic [31:0] a,        // destination operand
    input  logic [31:0] b,        // source operand
    input  logic [3:0]  flags_in, // {CY, OV, S, Z}
    output logic [31:0] result,   // width-masked
    output logic [3:0]  flags_out
);

    // operation encoding shared with the microcode field
    localparam logic [3:0]
        ALU_ADD = 4'd0,
        ALU_SUB = 4'd1,
        ALU_CMP = 4'd2,   // sub, result discarded by datapath
        ALU_AND = 4'd3,
        ALU_OR  = 4'd4,
        ALU_XOR = 4'd5,
        ALU_NEG = 4'd6,   // 0 - a
        ALU_NOT = 4'd7,   // ~a (logic-op flags)
        ALU_INC = 4'd8,   // a + 1
        ALU_DEC = 4'd9,   // a - 1
        // multi-precision carry ops (the stage-load bit-serial
        // decompressor at 1304D5 is Golden Axe's first addc)
        ALU_ADDC = 4'd10, // a + b + CY
        ALU_SUBC = 4'd11; // a - b - CY

    logic [31:0] mask, am, bm;
    logic [5:0]  msb;              // sign bit position for current width
    logic [32:0] sum;              // one spare bit for carry/borrow at word
    logic [31:0] x, y;             // effective adder inputs
    logic        is_sub, is_logic, cin;
    logic        cy, ov, s, z;
    logic [31:0] res;

    always_comb begin
        unique case (width)
            2'd0:    begin mask = 32'h0000_00FF; msb = 6'd7;  end
            2'd1:    begin mask = 32'h0000_FFFF; msb = 6'd15; end
            default: begin mask = 32'hFFFF_FFFF; msb = 6'd31; end
        endcase

        am = a & mask;
        bm = b & mask;

        is_sub   = (op == ALU_SUB) || (op == ALU_CMP) || (op == ALU_NEG) || (op == ALU_DEC)
                || (op == ALU_SUBC);
        is_logic = (op == ALU_AND) || (op == ALU_OR) || (op == ALU_XOR) || (op == ALU_NOT);
        // carry/borrow-in for the multi-precision ops only
        cin = ((op == ALU_ADDC) || (op == ALU_SUBC)) && flags_in[3];

        // adder input selection
        unique case (op)
            ALU_ADD:  begin x = am;    y = bm;    end
            ALU_SUB:  begin x = am;    y = bm;    end
            ALU_CMP:  begin x = am;    y = bm;    end
            ALU_NEG:  begin x = 32'd0; y = am;    end
            ALU_INC:  begin x = am;    y = 32'd1; end
            ALU_DEC:  begin x = am;    y = 32'd1; end
            ALU_ADDC: begin x = am;    y = bm;    end
            ALU_SUBC: begin x = am;    y = bm;    end
            default:  begin x = am;    y = bm;    end
        endcase

        // shared adder/subtractor (borrow-style carry on subtract, as V60 PSW)
        sum = is_sub ? ({1'b0, x} - {1'b0, y} - {32'd0, cin})
                     : ({1'b0, x} + {1'b0, y} + {32'd0, cin});

        unique case (op)
            ALU_AND: res = am & bm;
            ALU_OR:  res = am | bm;
            ALU_XOR: res = am ^ bm;
            ALU_NOT: res = ~am;
            default: res = sum[31:0];
        endcase
        res = res & mask;
        result = res;

        // flags
        z = (res == 32'd0);
        s = res[msb];

        if (is_logic) begin
            ov = 1'b0;
            cy = flags_in[3];        // CY preserved through logic ops
        end else begin
            // carry/borrow out of the operation width (cin = 0 except
            // addc/subc, so the pre-carry-op expressions are unchanged)
            unique case (width)
                2'd0:    cy = is_sub ? ({1'b0,x[7:0]}  < ({1'b0,y[7:0]}  + {8'd0,cin}))
                                     : (({1'b0,x[7:0]}  + {1'b0,y[7:0]}  + {8'd0,cin})  >> 8)  & 1'b1;
                2'd1:    cy = is_sub ? ({1'b0,x[15:0]} < ({1'b0,y[15:0]} + {16'd0,cin}))
                                     : (({1'b0,x[15:0]} + {1'b0,y[15:0]} + {16'd0,cin}) >> 16) & 1'b1;
                default: cy = is_sub ? ({1'b0,x} < ({1'b0,y} + {32'd0,cin}))
                                     : sum[32];
            endcase
            // signed overflow at width:
            //   add: operands same sign, result differs
            //   sub: operands differ in sign, result sign != minuend
            if (is_sub)
                ov = (x[msb] ^ y[msb]) & (x[msb] ^ res[msb]);
            else
                ov = ~(x[msb] ^ y[msb]) & (x[msb] ^ res[msb]);
        end

        flags_out = {cy, ov, s, z};
    end

endmodule
