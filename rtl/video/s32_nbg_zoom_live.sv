// s32_nbg_zoom_live.sv — 315-5387 NBG0/NBG1, the zooming tilemap layers.
//
// Once per frame, `init` computes the zoom steps (restoring divider ->
// sxstep/systep, 12.20 fixed point) and start values. Per line:
//
//  - row_start (ROW_XFER_HCNT of the line before): take vy from the
//    vertical source position (srcy) and step it for the next line, then
//    walk the 64-word name row for vy (2 pages x 32 tile columns, whatever
//    the zoom) out of VRAM (while the arbiter grants it: vr_ok) into the
//    private `nrow` buffer.
//  - line_start (start of the beam stream): srcx <= srcx0; each cen_pix
//    adds sxstep_eff to the fractional srcx (with zoom, the source column
//    is not a simple function of the screen column). The name word comes
//    from the registered nrow read nq (1 clk), the tile ROM row from the
//    pattern buffer, and the pen is combinational off the ROM word.
//
// The beam reads only nrow during the line, so a CPU VRAM write after the
// row transfer shows from the next line. The beam never waits; only the
// walk can pause (vr_ok low).

module s32_nbg_zoom_live (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_pix,      // one pulse per displayed dot (6.25 MHz)

    // per-frame zoom setup
    input  logic        init,          // compute DDA parameters (per frame)
    input  logic [6:0]  page_a,
    input  logic [6:0]  page_b,
    input  logic [6:0]  page_c,
    input  logic [6:0]  page_d,
    input  logic [11:0] dstxstep,
    input  logic [11:0] dstystep,
    input  logic [15:0] hscr_i,
    input  logic [15:0] hscr_f,
    input  logic [15:0] vscr_i,
    input  logic [15:0] vscr_f,
    input  logic [15:0] center_x,
    input  logic [15:0] center_y,
    input  logic [1:0]  bank,
    input  logic        flip,
    // cabinet vertical mirror (s32_video cab_vmirror): the beam presents the
    // lines in reverse order, so the srcy DDA must run bottom-up — the Y half
    // of the global-flip formula, without the X half. Latched at init.
    input  logic        vmirror,
    output logic        ready,         // init complete

    // per-line control
    input  logic [7:0]  line,          // walk target line (selects the bank)
    input  logic        row_start,     // ROW_XFER pulse: latch vy, step DDA, walk
    input  logic        line_start,    // beam stream start (HBLANK, BF_FSTART)

    // row-transfer walk port (shared VRAM port B, granted by the arbiter)
    input  logic        vr_ok,         // walk grant, not paused
    output logic        vr_busy,
    output logic        vr_re,         // = vr_busy
    output logic [15:0] vr_addr,
    input  logic [15:0] vr_rdata,      // 1-clk registered read

    // tile ROM row: rom_rdata is this core's pattern buffer read (s32_video);
    // rom_re/rom_addr are unused
    output logic        rom_re,
    output logic [18:0] rom_addr,
    input  logic [63:0] rom_rdata,

    // Pattern prefetch cursor: replays this line's tile columns in beam
    // order for the pattern streamer (s32_video), which fetches each
    // column's tile ROM row into the pattern buffer ahead of the beam. The
    // cursor has its own nrow read (snq), so the ROM address math stays in
    // this core. Columns are presented only once this line's walk is done,
    // and the sequence is the beam's own (same srcx0/sxstep_eff, 319
    // steps), so exactly the columns the beam will use are fetched.
    output logic        pf_vld,       // pf_col/pf_addr present a column
    output logic [5:0]  pf_col,       // canvas column presented
    output logic [18:0] pf_addr,      // its tile-ROM row address
    input  logic        pf_next,      // consume: advance to next column
    output logic        pf_done,      // line's column sequence exhausted
    output logic [5:0]  col,          // BEAM's current canvas column

    // beam pixel output ({color[8:0], pen[3:0]}, 0 = transparent)
    output logic [12:0] pix,
    output logic        pix_valid
);

    typedef enum logic [2:0] {
        Z_IDLE, Z_DIVX, Z_DIVY, Z_SETUP, Z_READY, Z_RUN
    } state_e;
    state_e state;

    logic [6:0]  pg [0:3];
    logic [1:0]  bank_q;
    logic        flip_q;
    logic        yflip_q;              // flip ^ vmirror: Y DDA direction
    logic [31:0] sxstep, systep;       // unsigned step magnitudes (12.20)
    logic [31:0] srcx0;                // per-line X start
    logic [31:0] srcy_acc;             // accumulated Y (per line)

    // divider workspace: (0x200 << 20) / den, 30-bit numerator
    logic [29:0] dnum;
    logic [12:0] drem;
    logic [29:0] dquo;
    logic [11:0] dden;
    logic [4:0]  dcnt;
    logic [12:0] dtry;
    assign dtry = {drem[11:0], dnum[29]};

    // sign-extended centers (10 bits when zoomed, 9 otherwise)
    logic signed [10:0] cx_s, cy_s;
    always_comb begin
        cx_s = (dstxstep != 12'h200)
             ? {center_x[9], center_x[9:0]}
             : {{2{center_x[8]}}, center_x[8:0]};
        cy_s = (dstystep != 12'h200)
             ? {center_y[9], center_y[9:0]}
             : {{2{center_y[8]}}, center_y[8:0]};
    end

    logic signed [43:0] cx_prod, cy_prod;
    assign cx_prod = cx_s * $signed({1'b0, sxstep});
    assign cy_prod = cy_s * $signed({1'b0, systep});

    logic [31:0] scroll_x0, scroll_y0;
    assign scroll_x0 = ({22'd0, hscr_i[9:0]} << 20)
                     + (({24'd0, hscr_f[15:8]}) << 12);
    assign scroll_y0 = ({23'd0, vscr_i[8:0]} << 20)
                     + (({25'd0, vscr_f[15:9]}) << 13);

    logic [31:0] sxstep_eff, systep_eff;
    assign sxstep_eff = flip_q ? (~sxstep + 32'd1) : sxstep;
    assign systep_eff = yflip_q ? (~systep + 32'd1) : systep;

    // ---- beam pixel path: srcx accumulates per dot, vy is the line DDA.
    logic [31:0] srcx;                 // canvas x accumulator (12.20)
    logic [8:0]  vy;                   // canvas y for this line
    logic [8:0]  pixctr;               // 0..319 (visible range + pix_valid)
    logic [9:0]  vx;
    assign vx = srcx[29:20];

    // ------------------------------------------------ row-transfer walk
    // the full 64-word name row for vy: {pg[{vy[8], k[5]}], vy[7:4], k[4:0]}
    // for k = 0..63. 64 granted cycles; each word is stored on the very next
    // clk (st_p/st_idx pipe) whether or not vr_ok is high then: that is the
    // one moment vr_rdata is sure to hold it (a pause could change it later).
    // Two banks: the walk fills walk_bank (the next line) while the beam and
    // the cursor read show_bank (the current line).
    logic walk_bank, show_bank;
    always_ff @(posedge clk) begin
        if (rst) begin walk_bank <= 1'b0; show_bank <= 1'b0; end
        else begin
            if (row_start)  walk_bank <= line[0];
            if (line_start) show_bank <= walk_bank;
        end
    end
    (* ramstyle = "MLAB" *) logic [15:0] nrow [0:127];
    // a copy of nrow for the prefetch cursor's read, written by the same
    // store pipe (two reads of one array crash Quartus 17, which would
    // duplicate the MLAB anyway)
    (* ramstyle = "MLAB" *) logic [15:0] nrow_pf [0:127];
    logic [6:0] widx;                  // 0..63 (store completes via st pipe)
    logic       st_p;                  // word consumed last clk: store NOW
    logic [5:0] st_idx;
    logic       walking;
    wire  [5:0] wstep = widx[5:0];

    assign vr_busy = walking;
    assign vr_re   = walking;
    assign vr_addr = {pg[{vy[8], wstep[5]}], vy[7:4], wstep[4:0]};

    always_ff @(posedge clk) begin
        if (rst) begin
            walking <= 1'b0; st_p <= 1'b0;
        end else begin
            st_p <= 1'b0;
            if (st_p) nrow[{walk_bank, st_idx}] <= vr_rdata;
            if (row_start && (state == Z_READY || state == Z_RUN)) begin
                widx    <= 7'd0;
                walking <= 1'b1;
            end else if (walking && vr_ok) begin
                st_idx <= wstep;
                st_p   <= 1'b1;
                if (widx == 7'd63) walking <= 1'b0;
                else widx <= widx + 7'd1;
            end
        end
    end

    // ------------------------------------------------- prefetch cursor
    // Replays the beam's steps (same srcx0 / sxstep_eff, 319 steps) and
    // presents each distinct tile column once, in beam order, so the
    // fetched columns are exactly the ones the beam uses, zoom and flip
    // included. snq is the nrow copy's read for that column; pf_addr is
    // rom_addr's math on snq. Columns are presented once the walk is done.
    logic [31:0] pf_srcx;
    logic [8:0]  pf_dot;               // beam steps replayed (0..319)
    logic        pf_run, pf_adv, pf_done_r, pf_ok_q;
    logic [5:0]  pf_from;
    wire  [5:0]  pf_ccol = pf_srcx[29:24];   // canvas column of the replica
    logic [15:0] snq;

    always_ff @(posedge clk) begin
        if (rst) begin
            pf_run <= 1'b0; pf_adv <= 1'b0; pf_done_r <= 1'b1;
        end else if (row_start && (state == Z_READY || state == Z_RUN)) begin
            pf_srcx   <= srcx0;
            pf_dot    <= 9'd0;
            pf_run    <= 1'b1;
            pf_adv    <= 1'b0;
            pf_done_r <= 1'b0;
        end else if (pf_run && pf_adv) begin
            if (pf_ccol != pf_from) pf_adv <= 1'b0;          // landed
            else if (pf_dot == 9'd319) begin                 // sequence done
                pf_adv <= 1'b0; pf_done_r <= 1'b1;
            end else begin
                pf_srcx <= pf_srcx + sxstep_eff;
                pf_dot  <= pf_dot + 9'd1;
            end
        end else if (pf_run && pf_next && !pf_done_r) begin
            pf_from <= pf_ccol;
            pf_adv  <= 1'b1;
        end
    end

    // the copy's write has its own always block (one array per block, or
    // Quartus 17 builds it from registers); same data, same edge
    always_ff @(posedge clk)
        if (st_p) nrow_pf[{walk_bank, st_idx}] <= vr_rdata;

    always_ff @(posedge clk) begin
        snq     <= nrow_pf[{walk_bank, pf_ccol}];  // pf prefetches the WALK line
        pf_ok_q <= pf_run && !walking;   // the snq read edge was walk-free
    end

    assign pf_vld  = pf_run && !pf_done_r && !pf_adv && !walking && pf_ok_q;
    assign pf_col  = pf_ccol;
    // tile kept out of the concat (Quartus 17 mishandles nested
    // operator/concat shapes)
    wire [14:0] pf_tile = {bank_q, snq[12:0]};
    // The cursor prefetches the walked (next) line's patterns, so it uses
    // that line's vy from the bank (stable for two lines): vy itself
    // changes at the next row_start, which a slow cursor can overrun.
    wire [8:0] pf_vy = vy_bk[walk_bank];
    assign pf_addr = {pf_tile, snq[15] ? ~pf_vy[3:0] : pf_vy[3:0]};
    assign pf_done = pf_done_r;
    assign col     = {vx[9], vx[8:4]};

    // ---- name word: registered nrow read (1 clk)
    logic [15:0] nq;
    always_ff @(posedge clk) nq <= nrow[{show_bank, vx[9], vx[8:4]}];

    // name fields (combinational off the settled name read)
    logic [14:0] name_tile;
    logic [8:0]  name_color;
    logic        name_fx, name_fy;
    assign name_tile  = {bank_q, nq[12:0]};
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

    assign rom_re   = (state == Z_RUN);
    // the beam reads vy from a bank keyed like nrow, so it always matches
    // the name row it reads (vy itself already belongs to the next line)
    logic [8:0] vy_bk [0:1];
    wire  [8:0] vy_beam = vy_bk[show_bank];
    assign rom_addr = {name_tile, name_fy ? ~vy_beam[3:0] : vy_beam[3:0]};

    logic [63:0] row_sh;
    logic [3:0]  pen;
    always_comb begin
        row_sh = rom_rdata << {swz(name_fx ? ~vx[3:0] : vx[3:0]), 2'b00};
        pen    = row_sh[63:60];
    end

    assign pix       = (pen == 4'd0) ? 13'd0 : {name_color, pen};
    assign pix_valid = (state == Z_RUN);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= Z_IDLE;
            ready <= 1'b0;
        end else if (init) begin
            pg[0] <= page_a; pg[1] <= page_b;
            pg[2] <= page_c; pg[3] <= page_d;
            bank_q <= bank;
            flip_q <= flip;
            yflip_q <= flip ^ vmirror;
            ready  <= 1'b0;
            dden <= (dstxstep < 12'h80) ? 12'h80 : dstxstep;
            dnum <= 30'h2000_0000;
            drem <= 13'd0;
            dcnt <= 5'd29;
            state <= Z_DIVX;
        end else begin
            unique case (state)
                Z_IDLE: ;

                Z_DIVX, Z_DIVY: begin
                    if (dtry >= {1'b0, dden}) begin
                        drem <= dtry - {1'b0, dden};
                        dquo <= {dquo[28:0], 1'b1};
                    end else begin
                        drem <= dtry;
                        dquo <= {dquo[28:0], 1'b0};
                    end
                    dnum <= {dnum[28:0], 1'b0};
                    if (dcnt == 5'd0) begin
                        if (state == Z_DIVX) begin
                            dden <= (dstystep < 12'h80) ? 12'h80 : dstystep;
                            dnum <= 30'h2000_0000;
                            drem <= 13'd0;
                            dcnt <= 5'd29;
                            state <= Z_DIVY;
                        end else
                            state <= Z_SETUP;
                    end else
                        dcnt <= dcnt - 5'd1;
                end

                Z_SETUP: begin
                    state <= Z_READY;
                    ready <= 1'b1;
                    // X and Y start independently: yflip_q also carries
                    // the cabinet mirror
                    srcx0    <= scroll_x0 - cx_prod[31:0]
                              + (flip_q ? 32'd319 * sxstep : 32'd0);
                    srcy_acc <= scroll_y0 - cy_prod[31:0]
                              + (yflip_q ? 32'd223 * systep : 32'd0);
                end

                // per line: row_start (before the walk) latches vy and
                // steps srcy for the next line; line_start (the later start
                // of the beam stream) loads srcx and starts the run.
                Z_READY, Z_RUN: begin
                    if (row_start) begin
                        vy       <= srcy_acc[28:20];
                        srcy_acc <= srcy_acc + systep_eff;
                        // store the target line's vy in the bank the walk fills
                        // (line[0]), so the beam reads it via show_bank.
                        vy_bk[line[0]] <= srcy_acc[28:20];
                    end
                    if (line_start) begin
                        srcx     <= srcx0;
                        pixctr   <= 9'd0;
                        state    <= Z_RUN;
                    end else if (state == Z_RUN) begin
                        if (cen_pix && pixctr != 9'd319) begin
                            srcx   <= srcx + sxstep_eff;
                            pixctr <= pixctr + 9'd1;
                        end
                    end
                end

                default: state <= Z_IDLE;
            endcase

            // divider quotient capture (final step result), registered so
            // Z_SETUP sees the final values
            if (state == Z_DIVX && dcnt == 5'd0)
                sxstep <= {2'd0, (dtry >= {1'b0, dden})
                           ? {dquo[28:0], 1'b1} : {dquo[28:0], 1'b0}};
            if (state == Z_DIVY && dcnt == 5'd0)
                systep <= {2'd0, (dtry >= {1'b0, dden})
                           ? {dquo[28:0], 1'b1} : {dquo[28:0], 1'b0}};
        end
    end

endmodule
