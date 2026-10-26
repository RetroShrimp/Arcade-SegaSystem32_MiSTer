// s32_clip.sv — 315-5387 clip-window evaluation (one layer).
//
// References: s32tech, 315-5387 ($31FF60-$31FF7E window rects,
// $31FF02 enable/in-out bits, $31FF06 window assignment; only the GLOBAL
// flip bit repositions windows; left == right draws a 1-pixel column —
// hardware bug the encoding of max = right+1 reproduces naturally;
// right < left or bottom < top shows nothing); MAME segas32_v.cpp
// compute_clipping_extents, evaluated per pixel.
//
// Pure combinational: s32_video uses `draw` to make clipped pixels
// transparent. The layer
// is visible inside (clip-in) or outside (clip-out) the union of its
// assigned windows; no assigned windows = empty union.
//
// Per-line windows (MAME compute_clipping_extents after 0.288,
// mamedev/mame#16038): when lw_arm[w] is set, window w keeps its register
// Y range but its X range on this line is REPLACED by the line table's span.
// The caller evaluates the span once per window (flip mirroring, $FFFF =
// no window) and passes the verdict for this x in lw_in[w]. Only windows 2
// and 3 have tables; callers tie lw_arm[0/1] (and lw_arm entirely where no
// line window reaches) to 0.

module s32_clip (
    input  logic [8:0]  x,            // screen x 0..sw-1
    input  logic [7:0]  y,            // screen line 0..223
    input  logic        clipen,       // $31FF02 bit 11+n
    input  logic        clipout,      // $31FF02 bit 6+n (1 = outside)
    input  logic [3:0]  winmask,      // $31FF06 nibble for this layer
    input  logic        gflip,        // $31FF00 bit 9 only
    // visible width, 320 or 416: the flip mirrors the windows over it
    // (MAME: visarea.right() + 1)
    input  logic [9:0]  sw,
    // raw window registers ($31FF60 + 8*w ..)
    input  logic [15:0] win_l [0:3],
    input  logic [15:0] win_t [0:3],
    input  logic [15:0] win_r [0:3],
    input  logic [15:0] win_b [0:3],
    input  logic [3:0]  lw_arm,       // window w's X comes from the line table
    input  logic [3:0]  lw_in,        // x is inside window w's span this line
    output logic        draw
);

    localparam logic [8:0] SH = 9'd224;

    logic in_win;
    always_comb begin
        in_win = 1'b0;
        for (int w = 0; w < 4; w++) begin
            logic [9:0] l, r;
            logic [8:0] t, b;
            l = {1'b0, win_l[w][8:0]};
            r = {1'b0, win_r[w][8:0]} + 10'd1;
            t = {1'b0, win_t[w][7:0]};
            b = {1'b0, win_b[w][7:0]} + 9'd1;
            if (gflip) begin
                logic [9:0] l2;
                logic [8:0] t2;
                l2 = (sw >= r) ? sw - r : 10'd0;
                r  = (sw >= l) ? sw - l : 10'd0;
                l  = l2;
                t2 = (SH >= b) ? SH - b : 9'd0;
                b  = (SH >= t) ? SH - t : 9'd0;
                t  = t2;
            end
            if (winmask[w] &&
                (lw_arm[w] ? lw_in[w] : ({1'b0, x} >= l && {1'b0, x} < r)) &&
                {1'b0, y} >= t && {1'b0, y} < b)
                in_win = 1'b1;
        end
        draw = !clipen ? 1'b1 : (clipout ? !in_win : in_win);
    end

endmodule
