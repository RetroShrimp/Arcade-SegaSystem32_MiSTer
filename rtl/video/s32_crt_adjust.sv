// s32_crt_adjust.sv — the OSD "CRT Adjust" page: analog-output geometry
// (H-Size, H-Position, V-Shift) for fitting the picture to a 15 kHz CRT.
//
// Not a board function. It sits between the board's video output and the
// framework, after the 315-5242 DAC stage, and changes nothing the game can
// observe: the pixel clock, the raster and every sync rate stay native. The
// engine is rmonic79's crt_adjust (rtl/video/crt_adjust.sv, vendored from
// MiSTer-CRT-Adjust, GPL-3.0-or-later); this file is the glue around it,
// written from that project's examples/core_side_snippet.v and re-derived for
// this core's pixel enable.
//
// Off is a bit-exact bypass at the emu boundary: S32.sv muxes the native
// stream straight through on `active` = 0, so a default build drives VGA_*,
// CE_PIXEL and the scaler's DE exactly as before this stage existed.
//
// ---------------- the read rate: a 17-bit accumulator ----------------------
// Since 2026-11-06 the stage runs on CLK_VIDEO after s32_vidout, where the
// dot is exactly 8 clocks (50 MHz video clock in the 320 mode, GitHub issue
// #1); it used to run on clk_sys, where the 6.25 MHz dot was 10.31 clocks.
// Upstream steps its read period in quarter clocks of a whole-clock pixel;
// this stage keeps its own accumulator form, with a per-setting increment
//
//     rd_inc(h) = round(PIX_INC * 64 / (64 + h))      h = -16 .. +15
//
// PIX_INC = 8192 (one dot = 8 clk = 8192/65536), i.e. a read period of
// (64 + h)/64 native dots: h = 0 is the native rate exactly (every read
// exactly 8 clocks, the same stream as the stage Off), and each click is
// 1/64 = 1.56% of a pixel, the same step the upstream menu promises. The
// table is literal (Quartus 17 constant-folds it either way; a literal
// leaves nothing to elaboration); sim/s32_crt_adjust checks every entry
// against the formula. The accumulator restarts on the rise of the engine's
// hs_ref_out, never the raw HSync (upstream's one wiring rule).
//
// At H-Size 0 every read is exactly 8 clocks, so the stage adds no jitter;
// other H-Size settings are non-integer periods by design.
//
// ---------------- HPOS_MODE: CONTENTSHIFT -----------------------------------
// Raster (s32_video, 320 mode): 400 dots per line, active 0..319, HSync
// 340..371, 262 lines, active 0..223, VSync 236..238. The engine's write
// pointer restarts on the HSync rise, so in buffer coordinates the active
// line is 60..379: a 60-dot lead-in (HSync 32 + back porch 28) and a 20-dot
// run-out before the next HSync. Measured edges (sim/s32_crt_adjust) at
// H-Size 0: +19 is the last setting that keeps every column, and past -60
// the left-hand columns are cut (4 at -64); below about -28 the left edge is
// already inside HSync/back porch, i.e. in the retrace. Enlarging H-Size
// stretches the lead-in too, so the right edge runs off the line from about
// +4; a NEGATIVE H-Position pulls the content earlier and buys that room
// back (+8 needs about -40, +15 needs -58). These are the blanking budget of
// this raster (80 dots), not limits of the engine.
//
// V-Shift moves VSync by whole lines; a positive setting delays it, which
// moves the picture UP on the tube (upstream's comment says down).
// That is why CONTENTSHIFT is built: SYNCSHIFT moves sync and content
// together and cannot change what fits in a line. Both limits are the
// blanking budget of this raster, not of the engine.
//
// ---------------- vertical blank: VB_LATE = 0 --------------------------------
// The engine reads out each buffered line during the line that follows its
// HSync rise. Here HSync comes AFTER the active pixels, so the bank closed at
// the HSync rise of line L holds line L, and the native vblank sampled on
// that rise is already right; upstream's extra one-line delay (for rasters
// whose HSync precedes the active line) blanked the first visible line and
// showed a stale vblank line under the picture. crt_adjust.sv adaptation 4.
//
// ---------------- the DE it hands on ----------------------------------------
// DE follows the picture (~hb_out, which already carries the engine's
// one-line-late vertical blank, so no line is lost). Upstream's anchored
// `de_osd` window assumes the content never starts before the native active,
// which a negative H-Position breaks; the cost of not using it is that the
// MiSTer OSD slides with H-Position while the stage is On.
//
// All three OSD fields are plain two's complement: the CONF_STR lists
// 0,+1..+max then -min..-1 and the decode is a sign extension.

module s32_crt_adjust #(
    parameter int H_TOTAL  = 400,     // ce_pix per line (s32_video HTOTAL)
    parameter int V_TOTAL  = 262,     // lines per frame (s32_video VTOTAL)
    parameter int PIX_INC  = 8192     // the dot in 1/65536 clk: exactly 8 clk (s32_vidout)
) (
    input  logic       clk,
    input  logic       ce_pix,

    // OSD
    input  logic       osd_on,        // CRT Adjust Off/On
    input  logic [4:0] osd_hsize,     // CRT H-Size      -16..+15  two's complement
    input  logic [6:0] osd_hpos,      // CRT H-Position  -64..+63  two's complement
    input  logic [5:0] osd_vshift,    // CRT V-Shift     -32..+31  two's complement

    // native stream (de = visible pixel; vblank = true vertical blank)
    input  logic [7:0] r_in, g_in, b_in,
    input  logic       hs_in, vs_in, de_in, vblank_in,

    output logic       active,        // registered osd_on: the S32.sv output mux
    output logic [7:0] r_out, g_out, b_out,
    output logic       hs_out, vs_out, de_out,
    output logic       ce_out         // CE_PIXEL while active
);

    // ---------------- OSD decode ----------------
    // Sampled at ce_pix so a mid-frame menu change lands on a pixel boundary.
    logic signed [4:0] hsize_s;
    logic signed [8:0] hpos_s;
    logic signed [5:0] vshift_s;
    logic        [4:0] hsize_q;

    always_ff @(posedge clk) if (ce_pix) begin
        active   <= osd_on;
        hsize_q  <= osd_hsize;
        hsize_s  <= $signed(osd_hsize);
        hpos_s   <= {{2{osd_hpos[6]}}, osd_hpos};     // sign-extend 7 -> 9
        vshift_s <= $signed(osd_vshift);
    end

    // ---------------- read-rate generator ----------------
    // rd_inc(h) = round(PIX_INC * 64 / (64 + h)); index = the raw 5-bit field
    // (0..15 = +0..+15, 16..31 = -16..-1). See the header.
    logic [16:0] rd_inc;
    always_comb
        case (hsize_q)
            5'd0:  rd_inc = 17'(PIX_INC); 5'd16: rd_inc = 17'd10923;
            5'd1:  rd_inc = 17'd8066;   5'd17: rd_inc = 17'd10700;
            5'd2:  rd_inc = 17'd7944;   5'd18: rd_inc = 17'd10486;
            5'd3:  rd_inc = 17'd7825;   5'd19: rd_inc = 17'd10280;
            5'd4:  rd_inc = 17'd7710;   5'd20: rd_inc = 17'd10082;
            5'd5:  rd_inc = 17'd7598;   5'd21: rd_inc = 17'd9892;
            5'd6:  rd_inc = 17'd7490;   5'd22: rd_inc = 17'd9709;
            5'd7:  rd_inc = 17'd7384;   5'd23: rd_inc = 17'd9533;
            5'd8:  rd_inc = 17'd7282;   5'd24: rd_inc = 17'd9362;
            5'd9:  rd_inc = 17'd7182;   5'd25: rd_inc = 17'd9198;
            5'd10:  rd_inc = 17'd7085;  5'd26: rd_inc = 17'd9039;
            5'd11:  rd_inc = 17'd6991;  5'd27: rd_inc = 17'd8886;
            5'd12:  rd_inc = 17'd6899;  5'd28: rd_inc = 17'd8738;
            5'd13:  rd_inc = 17'd6809;  5'd29: rd_inc = 17'd8595;
            5'd14:  rd_inc = 17'd6722;  5'd30: rd_inc = 17'd8456;
            5'd15:  rd_inc = 17'd6637;  default: rd_inc = 17'd8322;   // 31
        endcase

    wire  hs_ref;
    logic hs_ref_d;
    always_ff @(posedge clk) hs_ref_d <= hs_ref;
    wire  hs_ref_rise = hs_ref & ~hs_ref_d;

    logic [16:0] rd_acc;
    logic        rd_tick;
    always_ff @(posedge clk) begin
        if (hs_ref_rise) begin
            // preset so the first read tick is the very next clock: the line
            // then holds the full 400 ticks at H-Size 0 instead of 399
            rd_acc  <= 17'h10000 - rd_inc;
            rd_tick <= 1'b0;
        end else begin
            rd_acc  <= {1'b0, rd_acc[15:0]} + rd_inc;
            rd_tick <= rd_acc[16];
        end
    end

    // Off: the engine is in its own bypass and runs at ce_pix.
    wire rd_ce = active ? rd_tick : ce_pix;

    // ---------------- the engine ----------------
    wire str_hb;

    crt_adjust #(
        .VTOTAL    (V_TOTAL),
        .HTOTAL    (H_TOTAL),
        .HPOS_MODE (1),               // CONTENTSHIFT, see the header
        .AW        (10),              // 512 per bank >= 400 dots
        .VB_LATE   (0)                // HSync follows the active line, see below
    ) u_crt_adjust (
        .clk        (clk),
        .pxl_cen    (ce_pix),
        .pxl2_cen   (rd_ce),
        .active     (active),
        .hsize      (hsize_s),        // upstream parity; H-Size is rd_inc above
        .hoffset    (hpos_s),
        .voffset    (vshift_s),
        .r_in       (r_in), .g_in (g_in), .b_in (b_in),
        .hs_in      (hs_in),          // NATIVE sync; the engine derives hs_ref
        .vs_in      (vs_in),
        .hb_in      (~de_in),         // de already excludes vblank lines
        .vb_in      (vblank_in),      // TRUE vertical blank, not ~de
        .r_out      (r_out), .g_out (g_out), .b_out (b_out),
        .hs_out     (hs_out), .vs_out (vs_out),
        .hb_out     (str_hb), .vb_out (),
        .hs_ref_out (hs_ref)
    );

    // vb_out (the native write-rate blank) is left open: hb_out is ~pass_q,
    // which the engine already gates with its one-line-late vblank.

    assign de_out = ~str_hb;
    assign ce_out = rd_ce;

endmodule
