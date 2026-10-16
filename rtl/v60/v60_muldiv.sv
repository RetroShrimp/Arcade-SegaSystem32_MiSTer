// v60_muldiv.sv — NEC V60 multiply/divide unit (sequential).
//
// Checked against MAME 0.288 single-step results from Golden Axe code.
// Flags ({CY,OV,S,Z} = PSW[3:0]):
//   mul  : result = low <width> bits of signed product;
//          OV = product not representable in <width> (NEC manual; MAME
//          tests the high half != 0, which mis-flags e.g. -1 * n)
//          CY preserved; S/Z from result
//   mulu : as mul but unsigned product
//   div  : signed truncating quotient; OV only for <min>/-1 (dst unchanged);
//          divisor 0 leaves dst unchanged (the real CPU raises a Zero
//          Divide exception; that would be the sequencer's job);
//          CY preserved; S/Z from dst afterwards
//   divu : unsigned quotient; OV = 0; divisor 0 leaves dst unchanged;
//          CY preserved; S/Z from dst afterwards
//
// Iterative: shift-add multiply / restoring divide, one bit per cycle,
// <width>+2 cycles, like a sequential unit of the period (a 32-bit op is
// about 34 cycles plus the sequencer's overhead). The real uPD70616's
// multiply/divide timing is not documented, so this is an estimate; byte
// and halfword operations are cheaper, as on real sequential units.

module v60_muldiv (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [4:0]  op,        // 14 mul, 15 mulu, 16 div, 17 divu
                                   // (5 bits: 16/17 do not fit in 4)
    input  logic [1:0]  width,     // 0 byte, 1 half, 2 word
    input  logic [31:0] a,         // destination (multiplicand / dividend)
    input  logic [31:0] b,         // source (multiplier / divisor)
    input  logic [31:0] a_hi,      // divux: dividend high word
    input  logic        mode_dvx,  // divux: unsigned 64/32 with remainder
    input  logic        mode_rem,  // rem/remu: result = remainder of the
                                   // div/divu iteration (sign of the
                                   // DIVIDEND when signed; MAME opREM*)
    input  logic [3:0]  flags_in,  // {CY,OV,S,Z}
    output logic        busy,
    output logic        done,      // 1-cycle pulse, outputs valid
    output logic [31:0] result,
    output logic [31:0] rem_out,   // divux remainder
    output logic [3:0]  flags_out
);

    localparam logic [4:0] OP_MUL = 5'd14, OP_MULU = 5'd15,
                           OP_DIV = 5'd16, OP_DIVU = 5'd17;

    typedef enum logic [1:0] { S_IDLE, S_INIT, S_RUN, S_FIN } state_e;
    state_e state;

    // captured operation
    logic [4:0]  opr;
    logic [1:0]  wr;
    logic [3:0]  fin;
    logic        dvx, remr;
    logic [31:0] a_in, b_in, ahi_in;

    // decode of captured width
    logic [5:0]  bits, msb;
    logic [31:0] mask;
    logic        is_div, is_signed;
    always_comb begin
        unique case (wr)
            2'd0:    begin mask = 32'h0000_00FF; bits = 6'd8;  msb = 6'd7;  end
            2'd1:    begin mask = 32'h0000_FFFF; bits = 6'd16; msb = 6'd15; end
            default: begin mask = 32'hFFFF_FFFF; bits = 6'd32; msb = 6'd31; end
        endcase
        is_div    = (opr == OP_DIV) || (opr == OP_DIVU) || dvx;
        // The extended form is not unconditionally unsigned: divx (0xA6,
        // exec 55) is the signed sibling of divux, so the sequencer drives a
        // real OP_DIV/OP_DIVU and the sign comes from opr as it does for
        // every other divide.
        is_signed = (opr == OP_MUL) || (opr == OP_DIV);
    end

    // working registers
    logic        neg_res, neg_rem;
    logic [5:0]  cnt;
    logic [63:0] acc;      // mul: product accumulator | div: {remainder, quotient}
    logic [31:0] opa, opb; // |multiplicand|/|dividend|, |multiplier|/|divisor|

    // combinational helpers
    logic [31:0] au, bu;
    logic        div0, ov_case;
    logic [63:0] sh, prod, sres;
    logic [33:0] diff;
    logic [31:0] quo, r, remv;
    // dividend sign: for the 64-bit extended form it lives in the HIGH word,
    // not in au[msb] — that is the whole difference between divx and divux.
    logic        dvd_sgn;

    always_comb begin
        au = a_in & mask;
        bu = b_in & mask;
        div0    = is_div && (bu == 32'd0);
        // The <min>/-1 overflow case is a 32-bit test; it must not fire on
        // the extended form, whose dividend is 64-bit. Gating with !dvx keeps
        // divux bit-identical to before and stops divx taking a bogus OV
        // path (MAME's DIVX leaves CY/OV untouched entirely).
        ov_case = (opr == OP_DIV) && !dvx
                  && (au == (32'h1 << msb)) && (bu == mask);
        dvd_sgn = is_signed && (dvx ? ahi_in[31] : au[msb]);
    end

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
            busy  <= 1'b0;
        end else begin
            unique case (state)
                S_IDLE: if (start) begin
                    opr   <= op;
                    wr    <= width;
                    fin   <= flags_in;
                    a_in  <= a;
                    b_in  <= b;
                    ahi_in <= a_hi;
                    dvx   <= mode_dvx;
                    remr  <= mode_rem;
                    busy  <= 1'b1;
                    state <= S_INIT;
                end

                S_INIT: begin
                    // rem of <min>/-1 is 0, not an overflow: let it run
                    // the iteration (|min| % 1 = 0). MAME's .b/.h REM
                    // agree via C int promotion; .w would #DE in MAME
                    // (same class as the divux quotient-overflow crash)
                    // so 0 here is the mathematical answer (MAME cannot
                    // be compared).
                    if (div0 || (ov_case && !remr)) begin
                        // dst unchanged; OV per case; S/Z from unchanged dst
                        result    <= au;
                        flags_out <= {fin[3], ov_case, au[msb], au == 32'd0};
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        neg_res <= dvd_sgn ^ (is_signed && bu[msb]);
                        neg_rem <= dvd_sgn;               // rem: dividend sign
                        opa <= (is_signed && au[msb]) ? ((~au + 32'd1) & mask) : au;
                        opb <= (is_signed && bu[msb]) ? ((~bu + 32'd1) & mask) : bu;
                        acc <= 64'd0;   // divide path loads dividend below
                        if (dvx)
                            // |dividend| over the FULL 64 bits (divx); for
                            // divux dvd_sgn is 0 so this is the old load
                            acc <= dvd_sgn ? (~{ahi_in, au} + 64'd1)
                                           : {ahi_in, au};
                        else if (is_div)
                            // left-justify the dividend so one bit enters
                            // the acc[63:32] subtract window per iteration
                            // — with the raw load, .b/.h dividends never
                            // reach the window inside `bits` iterations
                            // and narrow div/rem return 0
                            acc <= {32'd0,
                                    ((is_signed && au[msb])
                                     ? ((~au + 32'd1) & mask) : au)
                                    << (6'd32 - bits)};
                        cnt   <= 6'd1;
                        state <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (is_div) begin
                        // restoring division, MSB-first. The shifted-out
                        // acc[63] is part of the partial remainder: in
                        // 64/32 mode (divux) it reaches 2^32 mid-run when
                        // the remainder exceeds 2^31 before a shift (e.g.
                        // divisors with bit 31 set) — 34-bit subtract.
                        sh   = {acc[62:0], 1'b0};
                        diff = {1'b0, acc[63], sh[63:32]} - {2'b00, opb};
                        acc <= diff[33] ? sh : {diff[31:0], sh[31:1], 1'b1};
                    end else begin
                        // shift-add multiply, LSB-first
                        acc <= acc + (opb[cnt-1] ?
                                      ({32'd0, opa} << (cnt - 6'd1)) : 64'd0);
                    end
                    if (cnt == bits) state <= S_FIN;
                    cnt <= cnt + 6'd1;
                end

                S_FIN: begin
                    if (dvx) begin
                        // divx/divux: quotient in acc[31:0], remainder in
                        // acc[63:32], both magnitudes. Signed form restores
                        // the signs — quotient = dividend^divisor, remainder
                        // = dividend (C-style truncation, as MAME's
                        // div_64x32_rem). divux leaves both neg_* clear, so
                        // this is bit-identical to the previous behaviour.
                        quo  = acc[31:0];
                        remv = acc[63:32];
                        if (neg_res) quo  = ~quo  + 32'd1;
                        if (neg_rem) remv = ~remv + 32'd1;
                        r = quo;
                        rem_out <= remv;
                        // S/Z from the quotient; CY/OV preserved (MAME opDIVX
                        // sets only _S and _Z)
                        flags_out <= {fin[3], fin[2], r[31], r == 32'd0};
                    end else if (is_div) begin
                        if (remr) begin
                            // rem/remu: the restoring divide leaves the
                            // remainder of |a|/|b| in acc[63:32]; sign
                            // follows the dividend (MAME opREM*). OV=0.
                            quo = acc[63:32] & mask;
                            if (neg_rem) quo = (~quo + 32'd1) & mask;
                        end else begin
                            quo = acc[31:0] & mask;
                            if (neg_res) quo = (~quo + 32'd1) & mask;
                        end
                        r = quo;
                        flags_out <= {fin[3], 1'b0, r[msb], r == 32'd0};
                    end else begin
                        prod = neg_res ? (~acc + 64'd1) : acc;
                        r = prod[31:0] & mask;
                        // OV per NEC manual: double-length product not
                        // representable at width. Signed: full product must
                        // equal the sign extension of the width result;
                        // unsigned: high half must be zero. (MAME instead
                        // uses high-half != 0 for both, which mis-flags
                        // signed cases like -1*n)
                        sres = {32'd0, r};
                        if ((opr == OP_MUL) && r[msb])
                            sres = sres | (~64'd0 << bits);
                        flags_out <= {fin[3], prod != sres, r[msb], r == 32'd0};
                    end
                    result <= r;
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    state  <= S_IDLE;
                end
            endcase
        end
    end

endmodule
