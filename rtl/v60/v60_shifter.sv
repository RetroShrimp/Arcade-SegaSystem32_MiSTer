// v60_shifter.sv — NEC V60 shift/rotate unit with PSW flag generation.
//
// Checked against MAME 0.288 single-step results from Golden Axe code.
// Count is the signed low byte of the
// source operand: positive = left, negative = right, zero = special case
// (result unchanged; CY/OV cleared; S/Z still evaluated from the value).
//
// Flags ({CY,OV,S,Z} = PSW[3:0]):
//   shl : CY = last bit shifted out, OV = 0
//   sha : left  — CY = last bit out; OV = 1 if any bit shifted through the
//                 sign position differed from the original sign
//         right — CY = last bit out; OV = 0; sign-fills
//   rot : CY = bit rotated into the far end (LSB after left / MSB after
//         right rotate), OV = 0
//   rotc: (width+1)-bit rotate through carry, OV = 0
//
// CY is architecturally undefined for |count| > width; the MAME
// comparison only covers |count| <= width.
//
// Purely combinational, built from a few wide funnel shifts shared by all
// modes (one shifter per operation would cost several thousand ALMs):
//   - rot  = funnel over the value replicated across 64 bits
//   - rotc = funnel over the (width+1)-bit vector {CY, value} replicated
//            across 66 bits, rotate count mod (width+1)
//   - shl/sha share one 64-bit left shift and one 64-bit right funnel
//     (CY falls out of the funnel's boundary bit in both directions)
//   - sha-left OV = reduction over (value XOR sign) under the top-n mask

module v60_shifter (
    input  logic [3:0]  op,        // 10 shl, 11 sha, 12 rot, 13 rotc
    input  logic [1:0]  width,     // 0 byte, 1 half, 2 word
    input  logic [31:0] a,
    input  logic [7:0]  count_in,  // signed
    input  logic [3:0]  flags_in,  // {CY,OV,S,Z}
    output logic [31:0] result,
    output logic [3:0]  flags_out
);

    localparam logic [3:0] OP_SHL = 4'd10, OP_SHA = 4'd11,
                           OP_ROT = 4'd12, OP_ROTC = 4'd13;

    logic signed [7:0] count_s;
    logic [5:0]  n;              // |count|, clamped to 0..63
    logic        left;
    logic [5:0]  bits;           // operation width in bits
    logic [31:0] mask, am;
    logic [5:0]  msb;
    logic        sign;
    logic        cy, ov, s, z;
    logic [31:0] res;

    // shared funnels
    logic [63:0] lsh;            // {0, am} << n
    logic [63:0] rsh;            // {am, 0} >> n
    logic [31:0] nmask;          // mask >> n (0 when n >= bits)
    logic [63:0] rep;            // am replicated to 64 bits (width-wise)
    logic [5:0]  rot_r;          // right-rotate amount, 0..bits-1
    logic [31:0] rot_res;
    logic [65:0] crep;           // {CY, am} pair replicated (rotc)
    logic [6:0]  cbits;          // bits + 1
    logic [5:0]  crot_r;         // right-rotate amount mod (bits+1)
    logic [32:0] crot;           // rotated (width+1)-bit vector
    logic [5:0]  nmod;

    always_comb begin
        unique case (width)
            2'd0:    begin mask = 32'h0000_00FF; bits = 6'd8;  msb = 6'd7;  end
            2'd1:    begin mask = 32'h0000_FFFF; bits = 6'd16; msb = 6'd15; end
            default: begin mask = 32'hFFFF_FFFF; bits = 6'd32; msb = 6'd31; end
        endcase
        am      = a & mask;
        sign    = am[msb];
        count_s = count_in;
        left    = ~count_s[7];
        n       = left ? count_s[5:0] : (~count_s[5:0] + 6'd1);
        if (count_s == -8'sd64) n = 6'd63;   // clamp pathological case

        // ------------------------------------------------ shared funnels
        lsh   = {32'd0, am} << n;
        rsh   = {am, 32'd0} >> n;
        nmask = (n >= bits) ? 32'd0 : (mask >> n);

        // value replicated across 64 bits at the operation width
        unique case (width)
            2'd0:    rep = {8{am[7:0]}};
            2'd1:    rep = {4{am[15:0]}};
            default: rep = {2{am}};
        endcase

        // rot: right-rotate amount (left rotate = bits - r); bits is a
        // power of two so mod is a mask
        nmod  = n & (bits - 6'd1);
        rot_r = left ? ((bits - nmod) & (bits - 6'd1)) : nmod;
        rot_res = 32'((rep >> rot_r)) & mask;

        // rotc: (bits+1)-bit vector {CY, am}, rotate count mod (bits+1)
        cbits  = {1'b0, bits} + 7'd1;
        crot_r = 6'((({1'b0, n} >= 2*cbits) ? ({1'b0, n} - 2*cbits)
                   : ({1'b0, n} >= cbits)   ? ({1'b0, n} - cbits)
                   :                          {1'b0, n})); // n<=63 < 3*(bits+1) for bits>=32;
                                                           // for 8/16 widths see below
        // for width 8 (cbits 9) n<=63 can exceed 3*9: reduce fully
        if (bits == 6'd8) begin
            crot_r = n;
            repeat (7) if (crot_r >= 6'd9) crot_r = crot_r - 6'd9;
        end else if (bits == 6'd16) begin
            crot_r = n;
            repeat (3) if (crot_r >= 6'd17) crot_r = crot_r - 6'd17;
        end
        if (!left) begin
            // right rotc by r == left-equivalent handled via right funnel
        end else begin
            // left rotc by r == right rotc by (cbits - r) mod cbits
            crot_r = (crot_r == 6'd0) ? 6'd0 : (6'(cbits) - crot_r);
        end

        // replicate the (bits+1)-bit vector {CY, am} twice and funnel
        unique case (width)
            2'd0:    crep = {30'd0, {4{flags_in[3], am[7:0]}}};
            2'd1:    crep = {32'd0, {2{flags_in[3], am[15:0]}}};
            default: crep = {flags_in[3], am, flags_in[3], am};
        endcase
        crot = 33'(crep >> crot_r);

        // ------------------------------------------------------- results
        res = am;
        cy  = flags_in[3];
        ov  = 1'b0;

        if (count_s == 8'sd0) begin
            // destination unchanged; CY/OV cleared; S/Z from current value
            cy = 1'b0;
            ov = 1'b0;
        end else begin
            unique case (op)
                OP_SHL: begin
                    if (left) begin
                        cy  = lsh[bits];            // am[bits-n], 0 if n>bits
                        res = lsh[31:0] & mask;     // 0 naturally when n>=bits
                    end else begin
                        cy  = (n <= bits) ? rsh[31] : 1'b0;  // am[n-1]
                        res = rsh[63:32] & mask;    // 0 naturally when n>=bits
                    end
                end
                OP_SHA: begin
                    if (left) begin
                        // OV: any of the top min(n,bits) bits differ from sign
                        ov  = |((am ^ (sign ? mask : 32'd0)) & mask & ~nmask);
                        cy  = lsh[bits];
                        res = lsh[31:0] & mask;
                    end else begin
                        cy  = (n <= bits) ? rsh[31] : sign;
                        res = ((rsh[63:32]) | (sign ? (mask & ~nmask) : 32'd0))
                              & mask;
                    end
                end
                OP_ROT: begin
                    res = rot_res;
                    cy  = left ? res[0] : res[msb];
                end
                default: begin // OP_ROTC
                    res = crot[31:0] & mask;
                    cy  = crot[bits];
                end
            endcase
        end

        s = res[msb];
        z = (res == 32'd0);
        result = res;
        flags_out = {cy, ov, s, z};
    end

endmodule
