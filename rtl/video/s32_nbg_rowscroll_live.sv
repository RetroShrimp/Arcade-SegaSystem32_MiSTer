// s32_nbg_rowscroll_live.sv — 315-5387 NBG2/NBG3, the tilemap layers with
// per-line scroll tables.
//
// References: s32tech (315-5387, $31FF04 line scroll control; table layout
// in bytes $0000/$0200/$0400/$0600 = NBG2-H/NBG3-H/NBG2-V/NBG3-V) and MAME
// segas32_v.cpp update_tilemap_rowscroll. NBG2/3 have no zoom and integer
// scroll only:
//   xscroll = (H int & 0x3FF) - (center_x & 0x1FF)
//   yscroll = V int & 0x1FF
//   rowscroll (enable r04[bg-2]): srcx += Htable[ylookup] & 0x3FF
//   rowselect (enable r04[bg]):   srcy  = (yscroll + Vtable[ylookup]) & 0x1FF
//   inhibit  (r04[bg+2]) turns both off; table base = (r04 >> 10) * 0x400
//   flipy: ylookup = 223 - line; flip: srcx runs right to left
//
// Line windows (MAME after 0.288, mamedev/mame#16038, compute_clipping_
// extents): when the inhibit bit is set (r04[4] NBG2 / r04[5] NBG3), the two
// table groups stop being scroll values and become, per scanline, the LEFT
// (H group) and RIGHT (V group) X edges of clip window 2 (NBG2's table) or
// 3 (NBG3's). A $FFFF word means no window on that line; edges are & $1FF,
// right inclusive, left > right is empty; the table line follows the global
// flip only. Golden Axe's stage-2 cave torches are drawn this way. This core
// only exports the edges (win_*); s32_clip applies them to every layer that
// selects that window. Its own pixels are never gated by them.
//
// At row_start (ROW_XFER_HCNT of the line before) the core latches its
// per-line state, reads the table words, then walks the 64-word name row
// for its source line (2 pages x 32 tile columns) out of VRAM (while the
// arbiter grants it: vr_ok) into the private `nrow` buffer. The beam reads
// only nrow during the line, so a CPU VRAM write after the row transfer
// shows from the next line.
//
// Each name word is stored on the clk after it is read (st_p/st_idx pipe),
// whether or not vr_ok is high then: that is the one moment vr_rdata is
// sure to hold it, since a pause can change vr_rdata afterwards. The table
// reads hold their address in a wait state until the word is registered
// (TH->THW, TV->TVW).
//
// Beam path: srcx is a simple function of the screen column (+-1 per dot);
// the name word comes from the registered nrow read nq (1 clk), the tile
// ROM row from the pattern buffer, and the pen is combinational off the
// ROM word. The beam never waits; only the walk can pause.

module s32_nbg_rowscroll_live (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_pix,      // one pulse per displayed dot (6.25 MHz)
    // 416-pixel mode (s32_video, stable for the frame): 416 dots a line, and
    // the X flip starts at column 415 (MAME draw_bg_layer: srcx =
    // cliprect.right() + xscroll when flipped). Latched at row_start.
    input  logic        wide,
    input  logic        line_start,   // beam stream start (HBLANK, BF_FSTART)
    input  logic [7:0]  line,         // upcoming visible line (sampled at row_start)

    // decoded configuration
    input  logic        bg3,           // 0 = NBG2, 1 = NBG3
    input  logic [6:0]  page_a,
    input  logic [6:0]  page_b,
    input  logic [6:0]  page_c,
    input  logic [6:0]  page_d,
    input  logic [15:0] hscr_i,        // $31FF22/2A
    input  logic [15:0] vscr_i,        // $31FF26/2E
    input  logic [15:0] center_x,      // $31FF38/3C
    input  logic [15:0] r04,           // $31FF04 (table base + enables)
    input  logic [1:0]  bank,
    input  logic        flip,          // X flip: layer flip XOR global flip
    // Y flip: global flip XOR (layer flip unless $31FF00 bit 8 prohibits
    // the per-layer Y flip) — MAME master compute_tilemap_flips; svf's
    // match mode runs NBG2 with $31FF00 = 0104 (X-only layer flip)
    input  logic        flipy,
    input  logic        gflip,         // $31FF00 bit 9 (line-window table index)

    // row-transfer walk port (shared VRAM port B, granted by the arbiter)
    input  logic        row_start,
    // walk_en = this layer is enabled (s32_video lay_en). When 0 the VRAM
    // walk and the pattern prefetch are skipped (their data can never
    // reach the screen), but every per-line latch still runs on
    // row_start, so the layer resumes exactly when re-enabled
    // (2026-10-19, docs/svf-bringup.md section 6.8).
    input  logic        walk_en,
    input  logic        vr_ok,        // walk grant, not paused
    output logic        vr_busy,
    output logic        vr_re,        // = vr_busy
    output logic [15:0] vr_addr,
    input  logic [15:0] vr_rdata,     // 1-clk registered read

    // tile ROM row port (1-cycle latency)
    output logic        rom_re,
    output logic [18:0] rom_addr,      // {tile[14:0], row[3:0]}
    input  logic [63:0] rom_rdata,     // row bytes, byte 0 in [63:56]

    // pattern prefetch cursor (see s32_nbg_zoom_live): replays
    // this line's canvas-column sequence in beam order (integer ±1 walk
    // off srcx0, 319 or 415 steps) for the pattern streamer. snq is a second
    // nrow read; pf_addr mirrors rom_addr's math off snq. Presentation
    // gates on the walk being finished — srcx0/srcy land mid-walk (W_SET),
    // so the cursor loads its position when the walk returns to W_IDLE.
    output logic        pf_vld,       // pf_col/pf_addr present a column
    output logic [5:0]  pf_col,       // canvas column presented
    output logic [18:0] pf_addr,      // its tile-ROM row address
    input  logic        pf_next,      // consume: advance to next column
    output logic        pf_done,      // line's column sequence exhausted
    output logic [5:0]  col,          // BEAM's current canvas column

    // this layer's line window edges for the beam line (see the header):
    // win_mode = armed (inhibit bit); win_active = this line has a window
    // (no $FFFF word); win_lo/win_hi = inclusive X edges. s32_clip uses them
    // as window 2's (NBG2) or window 3's (NBG3) X range.
    output logic        win_mode,
    output logic        win_active,
    output logic [9:0]  win_lo,
    output logic [9:0]  win_hi,

    // beam pixel output ({color[8:0], pen[3:0]}, 0 = transparent)
    output logic [12:0] pix,
    output logic        pix_valid
);

    // ---- config decode
    logic [6:0]  pg [0:3];
    logic [7:0]  ylookup;
    logic        wide_q;               // the walked line's width
    wire  [8:0]  pixlast = wide_q ? 9'd415 : 9'd319;
    logic [9:0]  srcx0;                // per-line canvas x start
    logic [8:0]  srcy;                 // per-line canvas y
    logic [9:0]  h_saved;

    logic        inhibit, rowscroll_en, rowselect_en;
    logic        h_en_raw, v_en_raw, win_en, read_h, read_v;
    logic [9:0]  win_l, win_r;          // per-line window edges
    logic        h_none, win_none;      // $FFFF H word / either word
    logic [7:0]  tlookup;               // table line index
    assign inhibit      = bg3 ? r04[5] : r04[4];
    assign h_en_raw     = bg3 ? r04[1] : r04[0];
    assign v_en_raw     = bg3 ? r04[3] : r04[2];
    assign rowscroll_en = h_en_raw && !inhibit;
    assign rowselect_en = v_en_raw && !inhibit;
    // line window mode, armed by the inhibit bit alone (#16038): no
    // enable bit is involved, and a zero word pair is a 1-pixel window at
    // x=0, not "no window"
    assign win_en = inhibit;
    assign read_h = rowscroll_en || win_en;
    assign read_v = rowselect_en || win_en;

    logic [15:0] tbase;
    assign tbase = {r04[15:10], 10'd0};

    logic [9:0] xscroll_base;
    assign xscroll_base = hscr_i[9:0] - {1'b0, center_x[8:0]};
    logic [8:0] yscroll;
    assign yscroll = vscr_i[8:0];

    // ------------------------------------------------ row-transfer walk
    // TH/THW = rowscroll table read + capture, TV/TVW = rowselect table
    // read + capture, SET = land srcx0/srcy, NAMES = the 64-word name row
    // (65 granted cycles, pipelined store).
    typedef enum logic [2:0] {
        W_IDLE, W_TH, W_THW, W_TV, W_TVW, W_SET, W_NAMES
    } wst_e;
    wst_e wst;

    // two banks: the walk fills walk_bank (the next line) while the beam and
    // the cursor read show_bank (the current line)
    logic walk_bank, show_bank;
    always_ff @(posedge clk) begin
        if (rst) begin walk_bank <= 1'b0; show_bank <= 1'b0; end
        else begin
            if (row_start)  walk_bank <= line[0];
            if (line_start) show_bank <= walk_bank;
        end
    end
    (* ramstyle = "MLAB" *) logic [15:0] nrow [0:127];
    // a copy of nrow for the prefetch cursor's read (see s32_nbg_zoom_live)
    (* ramstyle = "MLAB" *) logic [15:0] nrow_pf [0:127];
    logic [6:0] widx;                  // 0..63 (store completes via st pipe)
    logic       st_p;                  // word consumed last clk: store NOW
    logic [5:0] st_idx;
    wire  [5:0] wstep = widx[5:0];

    assign vr_busy = (wst != W_IDLE);
    assign vr_re   = vr_busy;
    always_comb begin
        vr_addr = 16'd0;
        unique case (wst)
            W_TH, W_THW: vr_addr = tbase + {7'd0, bg3, tlookup};
            W_TV, W_TVW: vr_addr = tbase + 16'h200 + {7'd0, bg3, tlookup};
            W_NAMES:     vr_addr = {pg[{srcy[8], wstep[5]}], srcy[7:4], wstep[4:0]};
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            wst <= W_IDLE; st_p <= 1'b0;
        end else begin
            // store pipe: the word read in the last vr_ok cycle is in
            // vr_rdata now, so store it, vr_ok or not (see the header). The
            // last store lands one clk after busy drops; vr_rdata still
            // holds the word then.
            st_p <= 1'b0;
            if (st_p) nrow[{walk_bank, st_idx}] <= vr_rdata;
            if (row_start) begin
                pg[0] <= page_a; pg[1] <= page_b;
                pg[2] <= page_c; pg[3] <= page_d;
                ylookup <= flipy ? (8'd223 - line) : line;
                wide_q  <= wide;
                // window mode indexes the table by the GLOBAL flip only
                // (MAME `line = flip ? visarea.max_y - y : y`)
                tlookup <= (win_en ? gflip : flipy) ? (8'd223 - line) : line;
                wst     <= !walk_en ? W_IDLE
                         : read_h ? W_TH
                         : read_v ? W_TV : W_SET;
            end else if (vr_ok) begin
                unique case (wst)
                    W_TH:  wst <= W_THW;           // H read in flight, hold addr
                    W_THW: begin                   // H word valid (held addr)
                        h_saved <= vr_rdata[9:0];
                        h_none  <= (vr_rdata == 16'hFFFF);
                        wst <= read_v ? W_TV : W_SET;
                    end
                    W_TV:  wst <= W_TVW;           // V read in flight, hold addr
                    W_TVW: begin                   // V word valid (held addr)
                        // window mode: the V group is the RIGHT edge, not a
                        // rowselect replacement, so srcy is left to W_SET.
                        if (win_en) begin
                            win_r    <= {1'b0, vr_rdata[8:0]};
                            win_none <= h_none || (vr_rdata == 16'hFFFF);
                        end else
                            srcy  <= yscroll + vr_rdata[8:0];
                        wst  <= W_SET;
                    end
                    W_SET: begin
                        // h_saved is captured at W_THW whenever rowscroll_en
                        // (with or without rowselect), so it is the rowscroll
                        // term in both table configurations.
                        srcx0 <= xscroll_base
                               + (flip ? {1'b0, pixlast} : 10'd0)
                               + (rowscroll_en ? h_saved : 10'd0);
                        if (!rowselect_en)
                            srcy <= yscroll + {1'b0, ylookup};
                        // window mode: H group = left edge (V edge landed at
                        // W_TVW). Scroll stays at the layer base above, since
                        // rowscroll_en/rowselect_en are both 0 when win_en.
                        if (win_en) win_l <= {1'b0, h_saved[8:0]};
                        widx <= 7'd0;
                        wst  <= W_NAMES;
                        // snapshot this line's final geometry into the bank
                        // the walk is filling (walk_bank stable = line[0]), so
                        // the beam reads it via show_bank alongside nrow.
                        srcx0_bk[walk_bank] <= xscroll_base
                               + (flip ? {1'b0, pixlast} : 10'd0)
                               + (rowscroll_en ? h_saved : 10'd0);
                        srcy_bk[walk_bank] <= (!rowselect_en)
                               ? (yscroll + {1'b0, ylookup})
                               : srcy;   // rowselect: srcy came from W_TVW
                        // the window edges are per-line geometry too, so they
                        // ride the same bank as srcx0/srcy or they would be
                        // applied one line out of step with the names.
                        win_l_bk[walk_bank]    <= {1'b0, h_saved[8:0]};
                        win_r_bk[walk_bank]    <= win_r;
                        win_none_bk[walk_bank] <= win_none;
                    end
                    W_NAMES: begin
                        st_idx <= wstep;
                        st_p   <= 1'b1;
                        if (widx == 7'd63) wst <= W_IDLE;
                        else widx <= widx + 7'd1;
                    end
                    default: wst <= W_IDLE;
                endcase
            end
        end
    end

    // ---- beam position and canvas x (combinational, no accumulator)
    logic [8:0] pixctr;               // 0..pixlast
    logic       running;
    logic [9:0] srcx;                 // canvas x for this dot, wraps at 1024
    // the beam reads its per-line values from a bank keyed like nrow, so
    // they always match the name row it reads
    logic [9:0] srcx0_bk [0:1]; logic [8:0] srcy_bk [0:1];
    logic [9:0] win_l_bk [0:1]; logic [9:0] win_r_bk [0:1];
    logic       win_none_bk [0:1];
    wire [9:0] srcx0_beam = srcx0_bk[show_bank];
    wire [8:0] srcy_beam  = srcy_bk[show_bank];
    wire [9:0] win_l_beam = win_l_bk[show_bank];
    wire [9:0] win_r_beam = win_r_bk[show_bank];
    wire       win_none_beam = win_none_bk[show_bank];
    assign srcx = flip ? (srcx0_beam - {1'b0, pixctr})
                       : (srcx0_beam + {1'b0, pixctr});

    // ------------------------------------------------- prefetch cursor
    // Integer replica of the beam walk: pf_x starts at srcx0 and steps
    // ±1 per replayed dot (flip-aware), presenting each distinct canvas
    // column once in beam order. Loaded when the walk returns to W_IDLE
    // (srcx0/srcy are walk products); pf_pend carries the arm across.
    logic [9:0] pf_x;
    logic [8:0] pf_dot;                // beam steps replayed (0..pixlast)
    logic       pf_run, pf_adv, pf_done_r, pf_ok_q, pf_pend;
    logic [5:0] pf_from;
    wire  [5:0] pf_ccol = pf_x[9:4];   // canvas column of the replica
    logic [15:0] snq;

    always_ff @(posedge clk) begin
        if (rst) begin
            pf_run <= 1'b0; pf_adv <= 1'b0;
            pf_done_r <= 1'b1; pf_pend <= 1'b0;
        end else if (row_start) begin
            pf_pend   <= walk_en;     // no prefetch for a disabled layer
            pf_run    <= 1'b0;
            pf_adv    <= 1'b0;
            pf_done_r <= !walk_en;
        end else if (pf_pend && wst == W_IDLE) begin
            pf_x    <= srcx0;
            pf_dot  <= 9'd0;
            pf_pend <= 1'b0;
            pf_run  <= 1'b1;
        end else if (pf_run && pf_adv) begin
            if (pf_ccol != pf_from) pf_adv <= 1'b0;          // landed
            else if (pf_dot == pixlast) begin                // sequence done
                pf_adv <= 1'b0; pf_done_r <= 1'b1;
            end else begin
                pf_x   <= flip ? (pf_x - 10'd1) : (pf_x + 10'd1);
                pf_dot <= pf_dot + 9'd1;
            end
        end else if (pf_run && pf_next && !pf_done_r) begin
            pf_from <= pf_ccol;
            pf_adv  <= 1'b1;
        end
    end

    // copy written in its own block (Quartus 17: one array per
    // block, else it falls to registers); same store pipe, same edge.
    always_ff @(posedge clk)
        if (st_p) nrow_pf[{walk_bank, st_idx}] <= vr_rdata;

    always_ff @(posedge clk) begin
        snq     <= nrow_pf[{walk_bank, pf_ccol}];  // pf prefetches the WALK line
        // ... and store-free: the walk's last word is written one edge
        // after wst returns to W_IDLE, so a read on that edge is stale for
        // column 63 (s32_nbg_zoom_live, the same race; docs/sonic-bringup.md
        // §6)
        pf_ok_q <= pf_run && (wst == W_IDLE) && !st_p;
    end

    assign pf_vld  = pf_run && !pf_done_r && !pf_adv
                     && (wst == W_IDLE) && pf_ok_q;
    assign pf_col  = pf_ccol;
    // tile kept out of the concat (Quartus 17 front-end
    // fragility with nested operator/concat shapes)
    wire [14:0] pf_tile = {bank, snq[12:0]};
    assign pf_addr = {pf_tile, snq[15] ? ~srcy[3:0] : srcy[3:0]};  // WALK line
    assign pf_done = pf_done_r;
    assign col     = {srcx[9], srcx[8:4]};

    // ---- name word: registered nrow read (1 clk)
    logic [15:0] nq;
    always_ff @(posedge clk) nq <= nrow[{show_bank, srcx[9], srcx[8:4]}];

    // ---- name fields (combinational off the settled name read)
    logic [14:0] name_tile;
    logic [8:0]  name_color;
    logic        name_fx, name_fy;
    assign name_tile  = {bank, nq[12:0]};
    assign name_color = nq[12:4];
    assign name_fx    = nq[14];
    assign name_fy    = nq[15];

    function automatic logic [3:0] swz (input logic [3:0] x);
        unique case (x)
            4'd0:  swz = 4'd0;  4'd1:  swz = 4'd1;
            4'd2:  swz = 4'd4;  4'd3:  swz = 4'd5;
            4'd4:  swz = 4'd2;  4'd5:  swz = 4'd3;
            4'd6:  swz = 4'd6;  4'd7:  swz = 4'd7;
            4'd8:  swz = 4'd8;  4'd9:  swz = 4'd9;
            4'd10: swz = 4'd12; 4'd11: swz = 4'd13;
            4'd12: swz = 4'd10; 4'd13: swz = 4'd11;
            4'd14: swz = 4'd14; default: swz = 4'd15;
        endcase
    endfunction

    // ---- tile-ROM port: the ROW for the tile named at (srcx,srcy). Chained
    // off the name read, so its address settles one name-latency after srcx.
    assign rom_re   = running;
    assign rom_addr = {name_tile, name_fy ? ~srcy_beam[3:0] : srcy_beam[3:0]};

    // ---- pen for the current dot (swizzled row nibble, transparent at 0)
    logic [63:0] row_sh;
    logic [3:0]  pen;
    always_comb begin
        row_sh = rom_rdata << {swz(name_fx ? ~srcx[3:0] : srcx[3:0]), 2'b00};
        pen    = row_sh[63:60];
    end

    // the window does not gate this layer's pixels; s32_clip applies
    // the edges to clip window 2/3. A $FFFF word = no window on the line.
    assign win_mode   = win_en;
    assign win_active = win_en && !win_none_beam;
    assign win_lo     = win_l_beam;
    assign win_hi     = win_r_beam;

    assign pix       = (pen == 4'd0) ? 13'd0 : {name_color, pen};
    assign pix_valid = running;

    always_ff @(posedge clk) begin
        if (rst) begin
            running <= 1'b0;
            pixctr  <= 9'd0;
        end else if (line_start) begin
            pixctr  <= 9'd0;
            running <= 1'b1;
        end else if (cen_pix && pixctr != pixlast)
            pixctr <= pixctr + 9'd1;
    end

endmodule
