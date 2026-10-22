// s32_sprite.sv — 315-5386A sprite generator: the render engine.
//
// References: s32tech (315-5386A) and MAME segas32_v.cpp
// (sprite_render_list, draw_one_sprite).
//
// Walks the command list in sprite RAM (16-byte packets from offset 0):
// render (direct / indirect / inline palettes, 4bpp and 8bpp, flips,
// centering, global offsets, end codes), clip (inclusive + exclusive,
// sext-12 fields), jump (+global offsets), abort. The walk is BOUNDED
// at 8192 commands exactly like MAME sprite_render_list (segas32_v.cpp
// 1566, `numentries++ < 0x20000/16`). The bound and `abort` input keep
// malformed/cyclic lists finite. Pattern data comes from sprite RAM (little-endian 32-bit pairs) or sprite ROM (32_BE dwords,
// bank = 2 bits of packet word 3). Zoom: 16.16 accumulators,
// hzoom = (src_px << 16)/dstw, vzoom = (srch << 16)/dsth via an
// iterative divider at sprite setup; vertical row skip multiplies
// srcw by the accumulated carry (shrink can skip several source rows
// per destination row). Framebuffer writes are one pixel per cycle;
// fb_shadow marks a bit-15-clear read-modify-write (shadow pen) for
// the memory controller. Erase, swap and trigger sequencing live in
// s32_sprite_top; `start` here renders one full list.
//
// Clipped work is skipped, not walked (OPEN-QUESTIONS Q40, 2026-10-19).
// Pixels are exactly MAME draw_one_sprite's; only the time differs.
//   - A sprite whose destination box misses the clip-in window entirely
//     draws nothing and costs only its decode, divide and S_CLIP.
//   - The trailing span past the clip edge is never walked: xtarget is
//     clamped to it, exactly as MAME does.
//   - The leading span before the clip edge is jumped. After k clipped
//     destination pixels the zoom DDA sits at nibble floor(k*hzoom/2^16)
//     with xacc = k*hzoom mod 2^16. That is one multiply per sprite
//     (S_SKIPMUL). Each source word passed over entirely costs one read,
//     to test its end code (S_SCAN; MAME ends the row there too). The row
//     then resumes at the clip edge.
// Rows outside the window already cost 2 ticks (S_ROW/S_ROW_NEXT).
//
// The source step rides the emitting tick (Q40, 2026-10-19). When a
// destination pixel's xacc += hzoom crosses one source pixel inside a word,
// S_PIX steps nib_i in that same tick instead of spending a second one. A
// 1:1 or magnified sprite therefore costs one tick per destination pixel,
// plus one at each word's last pixel (where the end-code test and the next
// word fetch happen) and the word reads. Shrinks that cross several source
// pixels still take one tick per extra source pixel. svf's goal replays are
// ~190k visible px of mostly 1:1 sprites: at two ticks per pixel they cost
// 1.14-1.18 frames on zero-wait memories even after the clip skip.
//
// Pattern words are prefetched (Q40, 2026-10-19, same day). While a sprite-
// ROM word is being drawn, S_PIX reads the next one (pf_issue: one read for
// curaddr+1, when at least two destination pixels remain); at the word's
// last pixel the end-code test and the switch to the prefetched word happen
// in the emitting tick. A 1:1 sprite is then exactly one tick per
// destination pixel; without the prefetch each word cost S_WORD_RD +
// S_WORD_WAIT + an unfused last-pixel step (3 ticks per 8 px at 4bpp, per
// 4 px at 8bpp). svf's "GOAL!!" banner (~3x overdraw of 1:1 ROM sprites,
// 8bpp flags) needed 98-99% of a frame on zero-wait memories with that
// overhead, and two frames on the board. Sprite-RAM patterns (two 16-bit
// reads per word) and the leading-span scan keep the S_WORD_RD path. A
// prefetch issued for a word the row then never uses costs one extra read.
// Super Visual Football is the reason: its match and replay lists place
// huge sprites wholly or mostly off screen (a 675x178 stand at x = -893
// and x = 681, every frame), 48-79% of all destination pixels. Walking them
// one tick each cost up to 2.2 frames of 25 MHz engine time (a replay, on
// zero-wait memories), which the real board evidently does not spend:
// the game runs at full rate. docs/svf-bringup.md section 6.5.

module s32_sprite (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,          // engine enable (freeze on 0)

    // latched control bits ($500008/$0A low 2 bits, $0C width)
    input  logic [1:0]  ctl08,
    input  logic [1:0]  ctl0a,
    input  logic        fb416,

    input  logic        start,        // render the command list once
    input  logic        abort,        // stop the walk now (watchdog)
    output logic        busy,

    // sprite RAM read port (64K x 16, 1-cycle latency)
    output logic        sr_re,
    output logic [15:0] sr_addr,
    input  logic [15:0] sr_rdata,

    // sprite ROM read port (dword address, 32-bit big-endian data)
    output logic        rom_re,
    output logic [21:0] rom_addr,
    input  logic [31:0] rom_rdata,

    // framebuffer write port
    output logic        fb_we,
    output logic [8:0]  fb_x,
    output logic [7:0]  fb_y,
    output logic [15:0] fb_wdata,
    output logic        fb_shadow     // 1 = clear bit 15 at (x,y)
);

    // MAME transparency_masks[ctl08][ctl0a]
    function automatic logic [15:0] tmask (input logic [1:0] a,
                                           input logic [1:0] b);
        unique case ({a, b})
            4'h0: tmask = 16'h7FFF; 4'h1: tmask = 16'h3FFF;
            4'h2: tmask = 16'h1FFF; 4'h3: tmask = 16'h0FFF;
            4'h4: tmask = 16'h3FFF; 4'h5: tmask = 16'h1FFF;
            4'h6: tmask = 16'h0FFF; 4'h7: tmask = 16'h07FF;
            4'h8: tmask = 16'h3FFF; 4'h9: tmask = 16'h1FFF;
            4'hA: tmask = 16'h0FFF; 4'hB: tmask = 16'h07FF;
            4'hC: tmask = 16'h1FFF; 4'hD: tmask = 16'h0FFF;
            4'hE: tmask = 16'h07FF; default: tmask = 16'h03FF;
        endcase
    endfunction

    function automatic logic signed [12:0] sext12 (input logic [15:0] v);
        sext12 = {v[11], v[11:0]};
    endfunction

    typedef enum logic [3:0] {
        S_IDLE, S_PKT_RD, S_PKT_LAST, S_DECODE,
        S_LUT_RD, S_LUT_LAST, S_DIV, S_SETUP,
        S_ROW, S_WORD_RD, S_WORD_WAIT, S_PIX, S_ROW_NEXT,
        S_CLIP, S_SKIPMUL, S_SCAN
    } state_e;
    state_e state;

    // packet buffer / list state
    logic [15:0] pkt [0:7];
    logic [3:0]  pkt_i;
    logic [12:0] pc;
    logic [13:0] ent_cnt;             // commands walked (MAME 8192 cap)

    // clip + global offsets
    logic signed [12:0] cin_l, cin_t, cin_r, cin_b;
    logic signed [12:0] cout_l, cout_t, cout_r, cout_b;
    logic               cout_en;
    logic signed [12:0] gxofs, gyofs;

    // decoded render command
    logic        ind, indloc, shadow, fromram, bpp8, flipx, flipy;
    logic [7:0]  transp;
    logic [7:0]  srch;
    logic [5:0]  srcw;
    logic [9:0]  dsth, dstw;
    logic [1:0]  bank;
    logic signed [12:0] xpos, ypos;
    logic [19:0] addr0;
    logic [15:0] color;
    logic [15:0] transmask;
    logic [15:0] indtable [0:15];
    logic [4:0]  lut_i;

    // divider: (num << 16) / den — num up to 1008 (10 bits) -> 26 bits
    logic [25:0] dnum, dquo;
    logic [10:0] drem;
    logic [9:0]  dden;
    logic [4:0]  dcnt;
    logic        div_second;          // 0 = hzoom pass, 1 = vzoom pass
    logic [25:0] hzoom, vzoom;

    logic [11:0] dtry;
    assign dtry = {drem[10:0], dnum[25]};

    // per-sprite working state
    logic signed [12:0] x, y, xtarget, ytarget;
    logic signed [12:0] xstep, ystep;
    logic [25:0] xacc;
    logic [15:0] yfrac;
    logic [19:0] rowaddr, curaddr;
    logic [31:0] word_q;
    logic [15:0] word_lo;
    logic        word_half;
    logic [2:0]  nib_i;
    logic [7:0]  pix;

    // leading-span skip (see the header): per sprite, k clipped destination
    // pixels -> skip_words whole source words, starting nibble skip_nib0 and
    // DDA remainder skip_xacc; per row, scan_left words still to scan
    logic [9:0]  skip_k;
    logic [19:0] skip_words;
    logic [2:0]  skip_nib0;
    logic [15:0] skip_xacc;
    logic signed [12:0] skip_x;
    logic [19:0] scan_left;
    logic        first_word;          // next S_WORD_WAIT starts at skip_nib0

    // pattern-word prefetch (header): pf_have = rom_rdata holds curaddr+1
    logic        pf_have;
    logic        pf_issue;

    always_comb begin
        if (bpp8)
            pix = word_q[31 - 8 * {1'b0, nib_i[1:0]} -: 8];
        else
            pix = {4'd0, word_q[31 - 4 * nib_i -: 4]};
    end

    logic last_pos, first_pos;
    assign first_pos = bpp8 ? (nib_i[1:0] == 2'd0) : (nib_i == 3'd0);
    assign last_pos  = bpp8 ? (nib_i[1:0] == 2'd3) : (nib_i == 3'd7);

    logic [7:0] trans_here;
    assign trans_here = (first_pos || last_pos) ? transp : 8'd0;

    logic in_clipin, in_clipout;
    always_comb begin
        in_clipin = (x >= cin_l) && (x <= cin_r) &&
                    (y >= cin_t) && (y <= cin_b);
        in_clipout = cout_en &&
                     (y >= cout_t) && (y <= cout_b) &&
                     (x >= cout_l) && (x <= cout_r);
    end

    logic [15:0] indpix;
    assign indpix = bpp8
        ? (indtable[pix[7:4]] | {12'd0, pix[3:0]})
        : indtable[pix[3:0]];

    // source row skip amount (srcw * carry rows, carry <= 1023)
    logic [25:0] ysum;
    assign ysum = {10'd0, yfrac} + vzoom;
    logic [15:0] yskip_words;
    assign yskip_words = 16'({10'd0, srcw} * ysum[25:16]);

    // ------------------------------------------------------ memory ports
    assign sr_re = (state == S_PKT_RD) || (state == S_LUT_RD) ||
                   ((state == S_WORD_RD) && fromram);
    always_comb begin
        sr_addr = {pc, 3'd0} + {12'd0, pkt_i};
        if (state == S_LUT_RD)
            sr_addr = (indloc ? ({pc, 3'd0} + 16'd8)
                              : {pkt[7][12:0], 3'd0})
                      + {11'd0, lut_i};
        if (state == S_WORD_RD)
            sr_addr = {curaddr[14:0], 1'b0} + {15'd0, word_half};
    end

    // one prefetch per word, on an emitting tick with two or more
    // destination pixels left in the row
    assign pf_issue = (state == S_PIX) && !fromram && !pf_have
                   && (xacc < 26'h10000) && (x != xtarget)
                   && (x + xstep != xtarget);
    assign rom_re = ((state == S_WORD_RD) && !fromram) || pf_issue;
    assign rom_addr = {bank, pf_issue ? (curaddr + 20'd1) : curaddr};

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            busy <= 1'b0;
        end else if (cen) begin
            fb_we <= 1'b0;
            if (abort) begin
                // watchdog (s32_sprite_top): stop a runaway walk here.
                // A list changed while being walked can hold garbage
                // packets of up to ~229k cycles each, which the 8192-
                // command cap does not bound in time. All per-sprite
                // state is rebuilt on the next start.
                busy  <= 1'b0;
                state <= S_IDLE;
            end else unique case (state)
                S_IDLE: if (start) begin
                    pc <= 13'd0;
                    pkt_i <= 4'd0;
                    ent_cnt <= 14'd0;
                    gxofs <= 13'sd0;
                    gyofs <= 13'sd0;
                    cin_l <= 13'sd0;
                    cin_t <= 13'sd0;
                    cin_r <= fb416 ? 13'sd415 : 13'sd319;
                    cin_b <= 13'sd223;
                    cout_en <= 1'b0;
                    busy <= 1'b1;
                    state <= S_PKT_RD;
                end

                // read 8 packet words (issue at pkt_i, data lands next)
                S_PKT_RD: begin
                    pkt_i <= pkt_i + 4'd1;
                    if (pkt_i != 4'd0)
                        pkt[pkt_i[2:0] - 3'd1] <= sr_rdata;
                    if (pkt_i == 4'd7) state <= S_PKT_LAST;
                end
                S_PKT_LAST: begin
                    pkt[7] <= sr_rdata;
                    pkt_i <= 4'd0;
                    state <= S_DECODE;
                end

                S_DECODE: begin
                    // walk bound as in MAME: sprite_render_list stops
                    // after 0x20000/16 = 8192 commands whatever the
                    // jumps. A list the game rewrites while it is being
                    // walked can contain a half-written jump that closes
                    // a loop; without the cap the walk would never end
                    // and the display would stay frozen.
                    ent_cnt <= ent_cnt + 14'd1;
                    if (ent_cnt == 14'd8192) begin
                        busy <= 1'b0;
                        state <= S_IDLE;
                    end else unique casez (pkt[0][15:13])
                        3'b11?: begin           // abort
                            busy <= 1'b0;
                            state <= S_IDLE;
                        end
                        3'b10?: begin           // jump (+offsets)
                            if (pkt[0][13]) begin
                                gyofs <= sext12(pkt[1]);
                                gxofs <= sext12(pkt[2]);
                            end
                            pc <= pkt[0][12:0];
                            state <= S_PKT_RD;
                        end
                        3'b01?: begin           // clip / no-op
                            if (pkt[0][12]) begin
                                // clamp the clip-in window to the
                                // drawable area (0..319/415 x 0..223), as
                                // MAME does (clipin &= outerclip).
                                // Otherwise an out-of-range clip lets
                                // sprites draw at x = 320..511, which
                                // the erase sweep never clears.
                                cin_t <= sext12(pkt[0]) > 13'sd0
                                       ? sext12(pkt[0]) : 13'sd0;
                                cin_b <= sext12(pkt[1]) < 13'sd223
                                       ? sext12(pkt[1]) : 13'sd223;
                                cin_l <= sext12(pkt[2]) > 13'sd0
                                       ? sext12(pkt[2]) : 13'sd0;
                                cin_r <= sext12(pkt[3])
                                          < (fb416 ? 13'sd415 : 13'sd319)
                                       ? sext12(pkt[3])
                                       : (fb416 ? 13'sd415 : 13'sd319);
                            end
                            if (pkt[0][13]) begin
                                cout_t <= sext12(pkt[4]);
                                cout_b <= sext12(pkt[5]);
                                cout_l <= sext12(pkt[6]);
                                cout_r <= sext12(pkt[7]);
                                cout_en <= 1'b1;
                            end
                            pc <= pc + 13'd1;
                            state <= S_PKT_RD;
                        end
                        default: begin          // render
                            ind     <= pkt[0][13];
                            indloc  <= pkt[0][13] && pkt[0][12];
                            shadow  <= pkt[0][11] && ctl0a[0];
                            fromram <= pkt[0][10];
                            bpp8    <= pkt[0][9];
                            transp  <= pkt[0][8] ? 8'd0
                                     : (pkt[0][9] ? 8'hFF : 8'h0F);
                            flipy   <= pkt[0][7];
                            flipx   <= pkt[0][6];
                            srch    <= pkt[1][15:8];
                            srcw    <= pkt[0][9] ? pkt[1][5:0]
                                                 : pkt[1][6:1];
                            dsth    <= pkt[2][9:0];
                            dstw    <= pkt[3][9:0];
                            bank    <= {pkt[3][14], pkt[3][11]};
                            ypos    <= sext12(pkt[4])
                                     + (pkt[0][5] ? gyofs : 13'sd0);
                            xpos    <= sext12(pkt[5])
                                     + (pkt[0][4] ? gxofs : 13'sd0);
                            addr0   <= {pkt[2][15:12], pkt[6]};
                            color   <= 16'h8000 |
                                       (pkt[7] & (pkt[0][9] ? 16'h7F00
                                                            : 16'h7FF0));
                            transmask <= tmask(ctl08, ctl0a)
                                       & (pkt[0][9] ? 16'hFFF0
                                                    : 16'hFFFF);
                            lut_i <= 5'd0;
                            if ((pkt[1][15:8] == 8'd0) ||
                                ((pkt[0][9] ? pkt[1][5:0]
                                            : pkt[1][6:1]) == 6'd0) ||
                                (pkt[2][9:0] == 10'd0) ||
                                (pkt[3][9:0] == 10'd0)) begin
                                pc <= pc + ((pkt[0][13] && pkt[0][12])
                                            ? 13'd3 : 13'd1);
                                state <= S_PKT_RD;
                            end else if (pkt[0][13])
                                state <= S_LUT_RD;
                            else begin
                                div_second <= 1'b0;
                                dnum <= {10'((pkt[0][9] ? 10'd4 : 10'd8)
                                         * {4'd0, (pkt[0][9]
                                                   ? pkt[1][5:0]
                                                   : pkt[1][6:1])}),
                                         16'd0};
                                drem <= 11'd0;
                                dden <= pkt[3][9:0];
                                dquo <= 26'd0;
                                dcnt <= 5'd25;
                                state <= S_DIV;
                            end
                        end
                    endcase
                end

                S_LUT_RD: begin
                    lut_i <= lut_i + 5'd1;
                    if (lut_i != 5'd0)
                        indtable[lut_i[3:0] - 4'd1] <=
                            (sr_rdata & (bpp8 ? 16'hFFF0 : 16'hFFFF))
                            | (ctl0a[0] ? 16'h8000 : 16'h0000);
                    if (lut_i == 5'd15) state <= S_LUT_LAST;
                end
                S_LUT_LAST: begin
                    indtable[15] <= (sr_rdata &
                                     (bpp8 ? 16'hFFF0 : 16'hFFFF))
                                  | (ctl0a[0] ? 16'h8000 : 16'h0000);
                    div_second <= 1'b0;
                    dnum <= {10'((bpp8 ? 10'd4 : 10'd8)
                                 * {4'd0, srcw}), 16'd0};
                    drem <= 11'd0;
                    dden <= dstw;
                    dquo <= 26'd0;
                    dcnt <= 5'd25;
                    state <= S_DIV;
                end

                S_DIV: begin
                    if (dtry >= {2'd0, dden}) begin
                        drem <= 11'(dtry - {2'd0, dden});
                        dquo <= {dquo[24:0], 1'b1};
                    end else begin
                        drem <= dtry[10:0];
                        dquo <= {dquo[24:0], 1'b0};
                    end
                    dnum <= {dnum[24:0], 1'b0};
                    if (dcnt == 5'd0) begin
                        if (!div_second) begin
                            hzoom <= {dquo[24:0],
                                      (dtry >= {2'd0, dden})};
                            div_second <= 1'b1;
                            dnum <= {2'd0, srch, 16'd0};
                            drem <= 11'd0;
                            dden <= dsth;
                            dquo <= 26'd0;
                            dcnt <= 5'd25;
                        end else begin
                            vzoom <= {dquo[24:0],
                                      (dtry >= {2'd0, dden})};
                            state <= S_SETUP;
                        end
                    end else
                        dcnt <= dcnt - 5'd1;
                end

                S_SETUP: begin
                    logic signed [12:0] xp, yp;
                    xp = xpos;
                    yp = ypos;
                    unique case (pkt[0][3:2])
                        2'd0, 2'd3: yp = yp - 13'((dsth - 10'd1) >> 1);
                        2'd1:       yp = yp - 13'(dsth - 10'd1);
                        default: ;
                    endcase
                    unique case (pkt[0][1:0])
                        2'd0, 2'd3: xp = xp - 13'((dstw - 10'd1) >> 1);
                        2'd1:       xp = xp - 13'(dstw - 10'd1);
                        default: ;
                    endcase
                    // Targets are final HERE (MAME: target = pos + delta*dst).
                    // Setting them to the flip-adjusted START and correcting
                    // them in S_ROW does not work: S_ROW's first cycle tests
                    // y == ytarget against the stale value, so y == start ==
                    // target and a vertically flipped sprite ends before
                    // drawing a row. Golden Axe has none; Holosseum's whole
                    // attract screen is one (a 288x203 vertically flipped
                    // sprite).
                    if (flipx) begin
                        xp = xp + 13'(dstw) - 13'sd1;
                        xstep <= -13'sd1;
                        xtarget <= xp - 13'(dstw);
                    end else begin
                        xstep <= 13'sd1;
                        xtarget <= xp + 13'(dstw);
                    end
                    if (flipy) begin
                        yp = yp + 13'(dsth) - 13'sd1;
                        ystep <= -13'sd1;
                        ytarget <= yp - 13'(dsth);
                    end else begin
                        ystep <= 13'sd1;
                        ytarget <= yp + 13'(dsth);
                    end
                    xpos <= xp;
                    ypos <= yp;
                    y <= yp;
                    yfrac <= 16'd0;
                    rowaddr <= addr0;
                    state <= S_CLIP;
                end

                // Whole-sprite reject, trailing clamp, leading-span length.
                // Box (inclusive): x from xpos to xtarget - xstep, y from
                // ypos to ytarget - ystep. The visible window is the clip-in
                // rectangle (already clamped to the drawable area).
                S_CLIP: begin
                    logic signed [12:0] xa, xb, ya, yb;
                    xa = (xstep > 0) ? xpos : (xtarget + 13'sd1);
                    xb = (xstep > 0) ? (xtarget - 13'sd1) : xpos;
                    ya = (ystep > 0) ? ypos : (ytarget + 13'sd1);
                    yb = (ystep > 0) ? (ytarget - 13'sd1) : ypos;
                    if (xb < cin_l || xa > cin_r || yb < cin_t || ya > cin_b
                        || yb < 13'sd0 || ya > 13'sd223) begin
                        pc <= pc + (indloc ? 13'd3 : 13'd1);
                        state <= S_PKT_RD;
                    end else begin
                        // MAME: clamp the far end to the clip edge
                        if (xstep > 0 && xtarget > cin_r + 13'sd1)
                            xtarget <= cin_r + 13'sd1;
                        if (xstep < 0 && xtarget < cin_l - 13'sd1)
                            xtarget <= cin_l - 13'sd1;
                        // leading clipped destination pixels
                        if (xstep > 0 && xpos < cin_l) begin
                            skip_k <= 10'(cin_l - xpos);
                            skip_x <= cin_l;
                        end else if (xstep < 0 && xpos > cin_r) begin
                            skip_k <= 10'(xpos - cin_r);
                            skip_x <= cin_r;
                        end else begin
                            skip_k <= 10'd0;
                            skip_x <= xpos;
                        end
                        state <= S_SKIPMUL;
                    end
                end

                // k * hzoom: the DDA position after the leading span
                S_SKIPMUL: begin
                    logic [35:0] prod;
                    prod = {26'd0, skip_k} * {10'd0, hzoom};
                    skip_xacc  <= prod[15:0];
                    skip_words <= bpp8 ? 20'(prod[35:18]) : 20'(prod[35:19]);
                    skip_nib0  <= bpp8 ? {1'b0, prod[17:16]} : prod[18:16];
                    state <= S_ROW;
                end

                S_ROW: begin
                    if (y == ytarget) begin
                        pc <= pc + (indloc ? 13'd3 : 13'd1);
                        state <= S_PKT_RD;
                    end else if (y >= cin_t && y <= cin_b &&
                                 y >= 13'sd0 && y <= 13'sd223) begin
                        x <= skip_x;
                        xacc <= {10'd0, skip_xacc};
                        word_half <= 1'b0;
                        first_word <= 1'b1;
                        pf_have <= 1'b0;
                        if (transp != 8'd0 && skip_words != 20'd0) begin
                            // end codes are live: test each skipped word
                            curaddr <= rowaddr;
                            scan_left <= skip_words;
                        end else begin
                            curaddr <= rowaddr + skip_words;
                            scan_left <= 20'd0;
                        end
                        state <= S_WORD_RD;
                    end else
                        state <= S_ROW_NEXT;
                end

                S_WORD_RD: begin
                    if (fromram && !word_half)
                        word_half <= 1'b1;
                    else begin
                        word_half <= 1'b0;
                        state <= S_WORD_WAIT;
                    end
                    if (fromram && word_half)
                        word_lo <= sr_rdata;    // low half arrived
                end
                S_WORD_WAIT: begin
                    // patterns from sprite RAM stream the lowest CPU-address
                    // byte first (MSB), matching MAME's spriteram_w dword
                    // {byte0,byte1,byte2,byte3}. word_lo = even word (bytes
                    // 0,1), sr_rdata = odd word (bytes 2,3); 16-bit words
                    // are little-endian, so [7:0] is the low byte. ROM
                    // patterns already arrive big-endian (rom_rdata).
                    word_q <= fromram
                        ? {word_lo[7:0], word_lo[15:8],
                           sr_rdata[7:0], sr_rdata[15:8]}
                        : rom_rdata;
                    pf_have <= 1'b0;
                    if (scan_left != 20'd0)
                        state <= S_SCAN;
                    else begin
                        nib_i <= first_word ? skip_nib0 : 3'd0;
                        first_word <= 1'b0;
                        state <= S_PIX;
                    end
                end

                // a source word wholly inside the leading clipped span: only
                // its end code matters (MAME tests the word's last pixel)
                S_SCAN: begin
                    if (transp != 8'd0 &&
                        (bpp8 ? (word_q[7:0] == 8'hFF) : (word_q[3:0] == 4'hF)))
                        state <= S_ROW_NEXT;
                    else begin
                        scan_left <= scan_left - 20'd1;
                        curaddr <= curaddr + 20'd1;
                        state <= S_WORD_RD;
                    end
                end

                S_PIX: begin
                    logic [25:0] xn;
                    xn = xacc + hzoom;
                    if (xacc < 26'h10000 && x != xtarget) begin
                        if (in_clipin && !in_clipout &&
                            pix != trans_here &&
                            x >= 13'sd0 && x <= 13'sd511) begin
                            if (!ind) begin
                                if (pix != 8'd0) begin
                                    fb_we <= 1'b1;
                                    fb_x <= x[8:0];
                                    fb_y <= y[7:0];
                                    fb_wdata <= color | {8'd0, pix};
                                    fb_shadow <= shadow;
                                end
                            end else if ((indpix & transmask)
                                         != transmask) begin
                                fb_we <= 1'b1;
                                fb_x <= x[8:0];
                                fb_y <= y[7:0];
                                fb_wdata <= indpix;
                                fb_shadow <= shadow;
                            end
                        end
                        x <= x + xstep;
                        if (pf_issue) pf_have <= 1'b1;
                        // fused source step (header): one source pixel
                        // crossed, not the word's last -> step now
                        if (xn >= 26'h10000 && !last_pos) begin
                            xacc  <= xn - 26'h10000;
                            nib_i <= nib_i + 3'd1;
                        end else if (xn >= 26'h10000 && last_pos && pf_have) begin
                            // the word's last pixel, next word prefetched:
                            // the consume step's checks, in this tick
                            if (transp != 8'd0 &&
                                pix == (bpp8 ? 8'hFF : 8'h0F))
                                state <= S_ROW_NEXT;    // end code
                            else if (x + xstep == xtarget)
                                state <= S_ROW_NEXT;
                            else begin
                                xacc    <= xn - 26'h10000;
                                word_q  <= rom_rdata;
                                nib_i   <= 3'd0;
                                curaddr <= curaddr + 20'd1;
                                pf_have <= 1'b0;
                            end
                        end else
                            xacc <= xn;
                    end else if (xacc >= 26'h10000) begin
                        xacc <= xacc - 26'h10000;
                        if (last_pos) begin
                            if (transp != 8'd0 &&
                                pix == (bpp8 ? 8'hFF : 8'h0F))
                                state <= S_ROW_NEXT;    // end code
                            else if (x == xtarget)
                                state <= S_ROW_NEXT;
                            else if (pf_have) begin
                                word_q  <= rom_rdata;
                                nib_i   <= 3'd0;
                                curaddr <= curaddr + 20'd1;
                                pf_have <= 1'b0;
                            end else begin
                                curaddr <= curaddr + 20'd1;
                                state <= S_WORD_RD;
                            end
                        end else
                            nib_i <= nib_i + 3'd1;
                    end else begin
                        // x reached target with xacc < 0x10000
                        state <= S_ROW_NEXT;
                    end
                end

                S_ROW_NEXT: begin
                    yfrac <= ysum[15:0];
                    rowaddr <= rowaddr + {4'd0, yskip_words};
                    y <= y + ystep;
                    state <= S_ROW;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
