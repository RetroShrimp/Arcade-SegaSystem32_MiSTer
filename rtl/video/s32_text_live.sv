// s32_text_live.sv — 315-5387 text layer.
//
// At row_start (ROW_XFER_HCNT of the line before) the core latches the line
// and walks all 40 tile columns (52 in the 416-pixel mode), name word then
// both pattern words per tile, out of VRAM (while the arbiter grants it:
// vr_ok) into a private row store {color, packed row}. The beam then reads only the
// store, so a CPU write to a name or pattern after the row transfer shows
// from the next line.
//
// Tile pairs are pipelined: N(i) N(i+1) P0(i) P1(i) P0(i+1) P1(i+1), 3
// granted cycles per tile, 120 per line (156 when wide). Every address is a registered
// function of state, and every word is captured on the clk after it is
// read, whether or not the walk is paused then (see the walk block).
//
// Addressing, packing and pens:
//   name word  = palette[15:9] | tile[8:0]
//   tile index = {r5c[2:0], name.tile[8:0]}          (12 bits)
//   name addr  = {r5c[8:4], ty, tx}                  ty=line/8, tx=col
//   pat addr   = {tile, py, {0,1}}                   py=line%8, 2 words/row
//   pack_row   = {lo[7:0],lo[15:8],hi[7:0],hi[15:8]} (LE VRAM, hi-nib=left)
//   pen        = (nib==0) ? 0 : {color[6:0], nib}    0 = transparent
//
// The beam reads the store through a registered read (tbq_*, 1 clk) so it
// maps to MLAB; the shift within a tile is combinational off the beam dot.
// The beam never waits; only the walk can pause (vr_ok low).

module s32_text_live (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_pix,      // one pulse per displayed dot (6.25 MHz)
    input  logic        wide,         // 416-pixel mode: 52 columns (s32_video)
    input  logic        line_start,   // beam stream start (HBLANK, BF_FSTART)
    input  logic [7:0]  line,         // upcoming visible line (sampled at row_start)
    input  logic [15:0] r5c,          // text base regs ($31FF5C), from the top

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

    // beam pixel output ({color[6:0], pen[3:0]}, 0 = transparent)
    output logic [10:0] pix,
    output logic        pix_valid,    // row store valid behind the beam
    output logic        prefetch_ready // whole row fetched
);

    function automatic logic [31:0] pack_row (input logic [15:0] w_lo,
                                              input logic [15:0] w_hi);
        pack_row = {w_lo[7:0], w_lo[15:8], w_hi[7:0], w_hi[15:8]};
    endfunction

    logic [7:0] line_q;
    logic [4:0] ty;  assign ty = line_q[7:3];
    logic [2:0] py;  assign py = line_q[2:0];

    // ---------------------------------------- row store: all 52 tiles
    // Two banks: the walk fills walk_bank (the next line) while the beam
    // reads show_bank (the current line), so the walk can run during the
    // preceding visible line. Bank 1 starts at entry 52 (TB); a 320-mode
    // line fills entries 0..39 of its bank.
    localparam int TB = 52;
    (* ramstyle = "MLAB" *) logic [6:0]  tb_color [0:2*TB-1];
    (* ramstyle = "MLAB" *) logic [31:0] tb_pat   [0:2*TB-1];
    // sim-only: zero the store so the second bank is defined before its
    // first fill (the beam never reads an unfilled bank in steady state; this
    // just keeps 4-state sim from flagging boot-frame X in black regions).
    logic        rv [0:1];             // per-bank "all tiles landed"
    logic        walk_bank, show_bank;
    // the bank the walk is about to fill (from row_start's `line`)
    wire walk_bank_nx = line[0];
    always_ff @(posedge clk) begin
        if (rst) begin walk_bank <= 1'b0; show_bank <= 1'b0; end
        else begin
            if (row_start)  walk_bank <= walk_bank_nx;  // walk fills next line
            if (line_start) show_bank <= walk_bank;      // beam switches to it
        end
    end

    // ------------------------------------------------ row-transfer walk
    // 3 granted cycles per tile. Each read has one clk of latency, which
    // the pair pipeline hides behind the next independent address: both
    // names of a tile pair go out back to back (a pattern address needs
    // its name word registered first), then the four pattern words follow
    // from the two captured tile indices:
    //   N(i) N(i+1) P0(i) P1(i) P0(i+1) P1(i+1) | N(i+2) ...
    // Every address is a registered function of state (never derived
    // combinationally from vr_rdata), so it stays put while the walk is
    // paused.
    //
    // Capture rule (shared with the other layer cores): a word read in a
    // vr_ok cycle is in vr_rdata exactly one clk later, whether or not the
    // walk advances then, so every capture is queued in the cap_* pipe and
    // happens on that next clk regardless of vr_ok. Waiting for the next
    // vr_ok cycle instead would capture whatever a pause put in vr_rdata.
    // The last capture therefore lands one clk after vr_busy drops;
    // vr_rdata still holds the word then.
    typedef enum logic [2:0] {
        W_IDLE, W_N0, W_N1, W_P0A, W_P1A, W_P0B, W_P1B
    } wst_e;
    wst_e        wst;
    typedef enum logic [2:0] {
        C_NONE, C_N0, C_N1, C_LO, C_HIA, C_HIB
    } cap_e;
    cap_e        cap;                 // capture to execute THIS cycle
    logic [5:0]  cap_tx;              // store target for C_HIA/C_HIB
    logic [5:0]  ftx;                 // pair base tile column: 0,2,..,38 (50)
    logic        wide_q;              // this walk's width (latched at row_start)
    wire  [5:0]  ftx_last = wide_q ? 6'd50 : 6'd38;
    logic [6:0]  col0, col1;          // captured colors (pair A/B)
    logic [11:0] til0, til1;          // captured tile indices (pair A/B)
    logic [15:0] f_pat_lo;            // low pattern word of the tile in flight

    assign vr_busy = (wst != W_IDLE);
    assign vr_re   = vr_busy;
    always_comb begin
        vr_addr = 16'd0;
        unique case (wst)
            W_N0:  vr_addr = {r5c[8:4], ty, ftx};
            W_N1:  vr_addr = {r5c[8:4], ty, 6'(ftx + 6'd1)};
            W_P0A: vr_addr = {til0, py, 1'b0};
            W_P1A: vr_addr = {til0, py, 1'b1};
            W_P0B: vr_addr = {til1, py, 1'b0};
            W_P1B: vr_addr = {til1, py, 1'b1};
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            wst       <= W_IDLE;
            cap       <= C_NONE;
            ftx       <= 6'd0;
            rv[0]     <= 1'b0; rv[1] <= 1'b0;
        end else begin
            // capture pipe: executes EVERY clk (see header note)
            unique case (cap)
                C_N0: begin
                    col0 <= vr_rdata[15:9];
                    til0 <= {r5c[2:0], vr_rdata[8:0]};
                end
                C_N1: begin
                    col1 <= vr_rdata[15:9];
                    til1 <= {r5c[2:0], vr_rdata[8:0]};
                end
                C_LO: f_pat_lo <= vr_rdata;
                C_HIA: begin
                    tb_color[(walk_bank ? (7'(TB) + 7'(cap_tx)) : 7'(cap_tx))] <= col0;
                    tb_pat  [(walk_bank ? (7'(TB) + 7'(cap_tx)) : 7'(cap_tx))] <= pack_row(f_pat_lo, vr_rdata);
                end
                C_HIB: begin
                    tb_color[(walk_bank ? (7'(TB) + 7'(cap_tx)) : 7'(cap_tx))] <= col1;
                    tb_pat  [(walk_bank ? (7'(TB) + 7'(cap_tx)) : 7'(cap_tx))] <= pack_row(f_pat_lo, vr_rdata);
                    if (cap_tx == ftx_last + 6'd1) rv[walk_bank] <= 1'b1;
                end
                default: ;
            endcase
            cap <= C_NONE;
            if (row_start) begin
                line_q    <= line;
                wide_q    <= wide;
                ftx       <= 6'd0;
                rv[walk_bank_nx] <= 1'b0;   // the bank being (re)filled
                cap       <= C_NONE;
                wst       <= walk_en ? W_N0 : W_IDLE;  // begin the row transfer
            end else if (vr_ok) begin
                unique case (wst)
                    W_N0:  begin cap <= C_N0;  wst <= W_N1;  end
                    W_N1:  begin cap <= C_N1;  wst <= W_P0A; end
                    W_P0A: begin cap <= C_LO;  wst <= W_P1A; end
                    W_P1A: begin
                        cap <= C_HIA; cap_tx <= ftx;
                        wst <= W_P0B;
                    end
                    W_P0B: begin cap <= C_LO;  wst <= W_P1B; end
                    W_P1B: begin
                        cap <= C_HIB; cap_tx <= 6'(ftx + 6'd1);
                        if (ftx == ftx_last) wst <= W_IDLE;
                        else begin
                            ftx <= ftx + 6'd2;
                            wst <= W_N0;
                        end
                    end
                    default: wst <= W_IDLE;
                endcase
            end
        end
    end

    // ------------------------------------------------------- beam stream
    // beam position: pixctr advances one dot per cen_pix from line_start
    logic [8:0] pixctr;               // 0..319 (415 when wide)
    wire  [8:0] pixlast = wide ? 9'd415 : 9'd319;
    logic [5:0] beam_tx; assign beam_tx = pixctr[8:3];   // tile column
    logic [2:0] beam_px; assign beam_px = pixctr[2:0];   // dot within tile

    always_ff @(posedge clk) begin
        if (rst)
            pixctr <= 9'd0;
        else if (line_start)
            pixctr <= 9'd0;
        else if (cen_pix && pixctr != pixlast)
            pixctr <= pixctr + 9'd1;
    end

    // registered row-store read (1-clk settle; the pen for a new tile
    // column is consumed no earlier than the next dot strobe, ~10 clk on)
    logic [6:0]  tbq_color;
    logic [31:0] tbq_pat;
    always_ff @(posedge clk) begin
        tbq_color <= tb_color[(show_bank ? (7'(TB) + 7'(beam_tx)) : 7'(beam_tx))];
        tbq_pat   <= tb_pat  [(show_bank ? (7'(TB) + 7'(beam_tx)) : 7'(beam_tx))];
    end

    // pixel tap — combinational off the registered tile row
    logic [31:0] row_sh;
    logic [3:0]  nib;
    always_comb begin
        row_sh    = tbq_pat >> {3'd7 - beam_px, 2'b00};
        nib       = row_sh[3:0];
        pix       = (nib == 4'd0) ? 11'd0 : {tbq_color, nib};
        pix_valid = rv[show_bank];
    end

    assign prefetch_ready = rv[show_bank];

endmodule
