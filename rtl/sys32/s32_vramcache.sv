// s32_vramcache.sv — the 315-5387's 64K x 16 VRAM, kept in SDRAM behind a
// two-way set-associative line cache (8 words per line).
//
// The VRAM is the largest RAM in the video system (about 100 M10K blocks),
// so it lives in SDRAM. The real VRAM is DRAM too, reached through a
// wait-stated random-access port and a serial row-transfer port, and the
// cache has the same two ports:
//
//   Port A, CPU: V60 reads and writes, wait-stated through cpu_hold. A read
//     miss fills one line. A write is accepted into a 16-deep posted-write
//     queue and drained to SDRAM in the background (byte-masked, no
//     read-modify-write); when it drains, any cached copy of the line is
//     updated in place.
//   Port B, render: the row-transfer walk that loads each line's tilemap
//     rows. It streams one word per clk from a row latch, with the next
//     sequential line staged and a two-entry file of recently used rows, so
//     line boundaries and A/B interleaves cost no extra cycles. A word with
//     a queued write waits until the write drains, so the next row
//     transfer always sees it.
//
// The walk must finish inside the ~721 clk between the row transfer and the
// start of pixel fetch, even on a heavy frame. What makes it fit:
//   1. Row chains: a miss fetches the whole aligned 64-word row under one
//      SDRAM activate (rf_cont/rf_ack/rf_stb) instead of 8 separate fills.
//   2. Boundary pre-stage and previous-row file (above).
//   3. A set index with the tag bits XOR-folded in, so page-aligned
//      structures of different layers do not fight over the same sets.
//   4. Two ways per set with a fill-LRU victim, so two hot rows in one set
//      both stay resident.
//   5. A span/stride predictor per 4K-word page: rows that are never reused
//      (row-select scrolling, the bitmap layer) are predicted and fetched in
//      the gaps between walks and during vblank.
//
// Fitting it in Quartus 17:
//   - Every store is a RAM block read through registered addresses only. One
//     asynchronous read pushes the store out of M10K, and register-array
//     tags with their probe muxes alone would cost ~22k ALUTs. So data and
//     metadata {valid, epoch, tag} are per-way RAMs with one copy per read
//     port, and every residency decision uses qa/qb while the port is
//     parked on the line in question (c_addr_l outside C_IDLE, r_addr_l
//     outside R_STREAM).
//   - Fills write the LRU victim way. Refilling a resident line can briefly
//     duplicate it, which is harmless: both copies match SDRAM.
//   - RAM cannot be cleared at reset, so the metadata carries a 6-bit epoch
//     that advances when reset is released, invalidating every older line.
//   - The per-set LRU bit is the one non-RAM store (an MLAB, one read site).
//   - No size casts on loop variables and no module-scope reads inside
//     automatic functions: Quartus 17 miscompiles both silently.
//
// SDRAM side: one burst-read client (fills; render before CPU) and one
// single-word write client (the queue drain), each with a four-phase
// handshake (need, serve, done, release). A request is held until its done
// pulse and never abandoned in flight.

module s32_vramcache #(
    parameter logic [24:0] VBASE = 25'h1D00000,  // byte base in SDRAM (128KB
                                                 // after the V25 ROM)
    parameter int          LINES = 1024          // sets: 1024 x 2 ways x 8
                                                 // words = 32KB cached
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         go,           // SDRAM ready + VRAM content loaded

    // ---- CPU random port (A): V60 R/W, wait-stated
    input  logic         cpu_sel,      // request valid (held until !cpu_hold)
    input  logic         cpu_we,
    input  logic [15:0]  cpu_addr,     // WORD address (0..65535)
    input  logic [15:0]  cpu_wdata,
    input  logic [1:0]   cpu_bsel,     // 1 = write this byte lane (RMW mask)
    output logic [15:0]  cpu_rdata,
    output logic         cpu_hold,     // 1 => stall the V60 this access

    // ---- render serial port (B): the row-transfer walk
    input  logic         rnd_re,       // read strobe (1 word/clk walk)
    input  logic [15:0]  rnd_addr,     // WORD address
    output logic [15:0]  rnd_rdata,
    output logic         rnd_hold,     // 1 => stall the WALK (never the beam)

    // ---- SDRAM burst-read client (8 x 16 bits = 16 bytes per burst).
    // Holding rf_cont high asks the controller to keep the row open and read
    // further lines of it back to back. Each rf_ack pulse means "address
    // taken, present the next line on rf_addr"; each rf_stb pulse delivers
    // one 128-bit line in rf_data, valid only that cycle. rf_done ends the
    // grant.
    output logic         rf_req,
    output logic [24:1]  rf_addr,
    output logic         rf_cont,
    output logic         rf_urgent,    // the walk is stalled on this fill:
                                       // the controller serves it right
                                       // after the tile/sprite-ROM ports
    input  logic [127:0] rf_data,
    input  logic         rf_done,
    input  logic         rf_stb,
    input  logic         rf_ack,

    // ---- SDRAM single-word write client (byte-masked)
    output logic         wr_req,
    output logic [24:1]  wr_addr,
    output logic [15:0]  wr_data,
    output logic [1:0]   wr_dqm,       // 1 => MASK (do not write) this byte
    input  logic         wr_done
);

    localparam logic [24:1] VW   = VBASE[24:1];       // word base in SDRAM
    localparam int          LB   = $clog2(LINES);
    localparam int          TAGW = 16 - 3 - LB;       // upper tag bits
    localparam int          EPW  = 6;                 // reset epoch bits
    // ways per set
    localparam int          WAYS = 2;
    localparam int          WB   = (WAYS <= 2) ? 1 : $clog2(WAYS);

    function automatic logic [LB-1:0]   f_line(input logic [15:0] a);
        // set index with the tag bits XOR-folded into its top bits. A plain
        // index puts the same screen band of every layer's name table (each
        // page-aligned) in the same sets, and the layers then evict each
        // other within a single walk. The fold is a bijection per tag, so
        // the tag compare is unchanged.
        logic [LB-1:0] ix;
        ix = a[3 +: LB];
        ix[LB-1 -: TAGW] = ix[LB-1 -: TAGW] ^ a[3+LB +: TAGW];
        f_line = ix;
    endfunction
    function automatic logic [TAGW-1:0] f_tag(input logic [15:0] a);
        f_tag = a[3+LB +: TAGW];
    endfunction

    // --------------------------------------- cache storage (2 ways, 2R1W)
    // The victim is the way NOT last filled (per-set fill-LRU), so two hot
    // lines in one set settle one per way and stay. The data store uses the
    // explicit byte-enabled RAM wrapper s32_sdp_be (end of this file):
    // written as a masked-lane array, Quartus 17 builds the 32KB store from
    // registers. Four instances, one per way per read port, with the writes
    // mirrored.
    (* ramstyle = "MLAB" *) logic [WB-1:0] clru [0:LINES-1];

    logic [EPW-1:0]  cur_ep;           // bumps at reset release: flash-
    logic            rst_q;            // invalidates every older line

    logic [WAYS-1:0] cw_we;            // fill write (data + meta valid)
    logic [WAYS-1:0] mw_we;            // invalidate write (meta only)
    logic [LB-1:0]   cw_line;
    logic [127:0]    cw_data;
    logic [TAGW-1:0] cw_tag;

    // Every drained CPU write is broadcast so the render port's row latches
    // can drop their copies of that row, including rows no longer resident
    // in the cache (the games rewrite scroll and clip tables every line).
    logic            cwr_stb;          // write-through completed this cycle
    logic [12:0]     cwr_row;          // its word-row address [15:3]

    logic [LB-1:0]   ra_line, rb_line;
    logic [127:0]      qa  [0:WAYS-1], qb  [0:WAYS-1];
    logic [EPW+TAGW:0] qam [0:WAYS-1], qbm [0:WAYS-1];

    // byte-lane enables: fills write all 16 lanes; a drained CPU write
    // updates its two lanes of a resident line in place. (Invalidating the
    // line instead would turn every table write into a walk miss.)
    logic [15:0] cw_ben;
    // genvar is declared outside the loop: Quartus 17 rejects the inline
    // `for (genvar w = ...)` form.
    genvar w;
    generate
        for (w = 0; w < WAYS; w++) begin : g_way
            // Metadata is one s32_sdp instance per read port, like the data.
            // A single array read at both ports is built from registers by
            // Quartus 17 (~21k ALMs). Each instance is 1024 x 10 bits, one
            // M10K. A read of an address written in the same cycle is
            // undefined; the guards below never use one. A fill (cw_we)
            // outranks an invalidate (mw_we).
            wire              meta_we = cw_we[w] | mw_we[w];
            wire [EPW+TAGW:0] meta_d  = cw_we[w] ? {1'b1, cur_ep, cw_tag}
                                                 : '0;
            s32_sdp_be #(.AW(LB), .DW(128)) u_da (
                .clk(clk), .we(cw_we[w]), .waddr(cw_line), .d(cw_data),
                .be(cw_ben), .raddr(ra_line), .q(qa[w]));
            s32_sdp_be #(.AW(LB), .DW(128)) u_db (
                .clk(clk), .we(cw_we[w]), .waddr(cw_line), .d(cw_data),
                .be(cw_ben), .raddr(rb_line), .q(qb[w]));
            s32_sdp #(.AW(LB), .NW(LINES), .DW(EPW+TAGW+1), .MAXDEPTH(LINES))
                u_ma (.clk(clk), .we(meta_we), .waddr(cw_line), .d(meta_d),
                      .raddr(ra_line), .q(qam[w]));
            s32_sdp #(.AW(LB), .NW(LINES), .DW(EPW+TAGW+1), .MAXDEPTH(LINES))
                u_mb (.clk(clk), .we(meta_we), .waddr(cw_line), .d(meta_d),
                      .raddr(rb_line), .q(qbm[w]));
        end
    endgenerate
    always_ff @(posedge clk) begin       // fill-LRU (MLAB, 1 async read site)
        for (int w = 0; w < WAYS; w++)
            if (cw_we[w]) clru[cw_line] <= WB'(w);
    end
    always_ff @(posedge clk) begin
        rst_q <= rst;
        if (rst_q && !rst) cur_ep <= cur_ep + 1'b1;   // leaving reset
    end

    // metadata hit unpack helpers (pure-argument functions)
    function automatic logic f_mhit(input logic [EPW+TAGW:0] m,
                                    input logic [EPW-1:0]    ep,
                                    input logic [TAGW-1:0]   tg);
        f_mhit = m[EPW+TAGW] && (m[TAGW +: EPW] == ep)
                             && (m[TAGW-1:0]    == tg);
    endfunction

    logic wr_any;                       // any cache write this cycle
    assign wr_any = (|cw_we) || (|mw_we);

    // ------------------------------------------------- CPU engine (port A)
    //
    // Posted writes. Waiting for each SDRAM write would stall the V60 far
    // longer than the real chip's wait states, and the games' per-frame table
    // updates would no longer fit in vblank. So a write is accepted in a few
    // cycles into a 16-deep queue, and the mem FSM drains the queue to SDRAM
    // in the background (M_WR). Ordering:
    //   - A CPU read of a word with a queued write waits in C_LOOK until
    //     the write drains.
    //   - A fill of a line with queued writes is deferred and the drain
    //     runs instead, so fill data never predates a queued write.
    //   - At the accept (C_WACK) port A is parked on the written line, so
    //     the entry records which ways hold it; the drain updates those
    //     ways. If that residency read collided with a cache write, both
    //     ways are invalidated instead (inv_pend, done by the mem FSM).
    typedef enum logic [2:0] {C_IDLE, C_LOOK, C_MISS, C_WR, C_WACK} cst_e;
    cst_e cst;
    logic [15:0] c_addr_l, c_wdata_l; logic [1:0] c_wbsel_l;

    localparam int PWQ_N = 16;
    logic [15:0] pwq_a [0:PWQ_N-1];
    // ramstyle logic on d/b/w: the queue is searched across every entry
    // (pwq_m_*, the merge at capture), so it is registers anyway; without
    // the attribute Quartus also built M10K copies of d/b/w for the one
    // drain read, 4 blocks for 320 bits (docs/corertlcleanup.md B1)
    (* ramstyle = "logic" *) logic [15:0] pwq_d [0:PWQ_N-1];
    (* ramstyle = "logic" *) logic [1:0]  pwq_b [0:PWQ_N-1];
    logic        pwq_v [0:PWQ_N-1];
    (* ramstyle = "logic" *) logic [WAYS-1:0] pwq_w [0:PWQ_N-1];  // ways the line was resident in at
                                      // the accept capture: the drain UPDATES
                                      // those ways in place (write-
                                      // update; the fill gating pins
                                      // residency stable until the drain)
    logic [4:0]  pwq_wp, pwq_rp;
    wire  [4:0]  pwq_used = pwq_wp - pwq_rp;
    wire         pwq_full  = pwq_used[4];
    wire         pwq_empty = (pwq_wp == pwq_rp);

    // pending-write match flags (computed near the mem arbiter, where
    // every compared address is in scope)
    logic pwq_m_cword;               // CPU read word has a pending write
    logic pwq_m_rword;               // render read word has one too: the
                                     // walk waits for the drain, so a row
                                     // transfer never reads the old word
    logic pwq_m_rline, pwq_m_pline, pwq_m_cline;  // fill-line matches
    logic pwq_m_capline;             // the line a fill COMMITS this cycle has
                                     // one — see the chain capture guard at
                                     // the mem FSM

    // accept-side invalidate request (1-deep; mem FSM services at idle)
    logic        inv_pend;
    logic [WAYS-1:0] inv_w;          // ways to invalidate
    logic [LB-1:0]   inv_line;
    logic [TAGW-1:0] inv_tag;

    // push handshake: the push goes through the mem FSM's idle state
    // (aw_gnt fires only in M_IDLE, and no fill is granted that cycle), so
    // no fill can be in flight for the written line or slip in beside the
    // push. Otherwise a fill could install pre-write data after the accept
    // had already recorded the line as absent, and it would stay stale.
    logic        aw_req, aw_gnt;

    // The parked read ports usually sit on exactly the set being written, so
    // most fills and invalidates would read and write one address in the
    // same cycle. The guards below already discard such reads, but on the
    // FPGA the collision can also corrupt the stored word. So for that one
    // cycle the read index is moved to a neighbouring set; the guards treat
    // the cycle as invalid anyway.
    logic [LB-1:0] ra_line_q, rb_line_q;   // requested (pre-diversion)
    assign ra_line = (wr_any && (cw_line == ra_line_q))
                     ? (ra_line_q ^ {{LB-1{1'b0}}, 1'b1}) : ra_line_q;
    assign rb_line = (wr_any && (cw_line == rb_line_q))
                     ? (rb_line_q ^ {{LB-1{1'b0}}, 1'b1}) : rb_line_q;

    assign ra_line_q = (cst==C_IDLE) ? f_line(cpu_addr) : f_line(c_addr_l);
    logic [WAYS-1:0] ca_hitw;
    logic ca_hit;
    always_comb
        for (int w = 0; w < WAYS; w++)
            ca_hitw[w] = f_mhit(qam[w], cur_ep, f_tag(c_addr_l));
    assign ca_hit = |ca_hitw;
    logic [127:0] qa_sel;
    always_comb begin
        qa_sel = qa[0];
        for (int w = 0; w < WAYS; w++) if (ca_hitw[w]) qa_sel = qa[w];
    end
    assign cpu_rdata = qa_sel[16*c_addr_l[2:0] +: 16];

    logic        cpu_need_fill, cpu_fill_done;
    logic        inv_clr;            // mem-FSM strobe into the CPU block
    logic        pwq_pop_now;        // drain completes this cycle; comb,
                                     // so the CPU block clears the valid
                                     // at the read pointer before it moves
    logic        cpu_ready;          // access complete this cycle (read hit
                                     // delivers data; write is accepted)
    // qa consume guard: the port-A read a hit uses was issued on the
    // previous edge. If a cache write hit the same set on that edge or this
    // one, qa may be stale (or undefined on the FPGA), so wait one cycle
    // and use the fresh read.
    logic        qa_wcol_q;
    logic        qa_wcol_now;
    assign qa_wcol_now = wr_any && (cw_line == f_line(c_addr_l));
    always_ff @(posedge clk)
        // compare the REQUESTED index (pre-diversion): on a diversion
        // cycle the port read a neighbor set instead of colliding, and
        // that capture must be discarded exactly like a collision
        qa_wcol_q <= rst ? 1'b0 : (wr_any && (cw_line == ra_line_q));
    assign cpu_ready = ((cst==C_LOOK) && ca_hit && !qa_wcol_q && !qa_wcol_now
                        && !pwq_m_cword)
                       || (cst==C_WACK);
    // cpu_hold rides the FSM state, NOT the (possibly 1-cycle) cpu_sel strobe:
    // the V60 bus asserts vid_sel for one A_SUB cycle, so once an access is
    // accepted the hold must persist through the miss fill / write until the
    // data is delivered. High at accept (C_IDLE + strobe) and all the way
    // through processing until cpu_ready.
    assign cpu_hold  = (cpu_sel && cst==C_IDLE) || ((cst != C_IDLE) && !cpu_ready);

    always_ff @(posedge clk) begin
        if (rst) begin
            cst <= C_IDLE; cpu_need_fill <= 1'b0;
            pwq_wp <= '0;
            inv_pend <= 1'b0; aw_req <= 1'b0;
            for (int i = 0; i < PWQ_N; i++) pwq_v[i] <= 1'b0;
        end else begin
            unique case (cst)
                C_IDLE:
                    if (cpu_sel) begin
                        c_addr_l  <= cpu_addr;
                        c_wdata_l <= cpu_wdata; c_wbsel_l <= cpu_bsel;
                        if (cpu_we) cst <= C_WR;   // C_WR = wait-for-slot
                        else        cst <= C_LOOK;
                    end
                C_LOOK:
                    if (ca_hit) begin
                        if (!qa_wcol_q && !qa_wcol_now && !pwq_m_cword)
                            cst <= C_IDLE;          // deliver (cpu_ready)
                        // else: linger — a collided qa re-reads clean; a
                        // pending-queued write to this word drains shortly
                    end else begin
                        cpu_need_fill <= 1'b1; cst <= C_MISS;
                    end
                C_MISS:
                    if (cpu_fill_done) begin cpu_need_fill <= 1'b0; cst <= C_LOOK; end
                C_WR: begin
                    // posted accept: request the push slot; the mem FSM
                    // grants it from M_IDLE only (fills serialized out).
                    // Common case = FSM idle: the write costs ~3 edges.
                    aw_req <= (!pwq_full && !inv_pend);
                    if (aw_gnt) begin
                        aw_req <= 1'b0;
                        pwq_a[pwq_wp[3:0]] <= c_addr_l;
                        pwq_d[pwq_wp[3:0]] <= c_wdata_l;
                        pwq_b[pwq_wp[3:0]] <= c_wbsel_l;
                        pwq_v[pwq_wp[3:0]] <= 1'b1;
                        pwq_wp <= pwq_wp + 5'd1;
                        cst <= C_WACK;
                    end
                end
                C_WACK: begin
                    // port A has been parked on the written line since the
                    // accept, so qam is its residency now. Record the
                    // resident ways in the pushed entry; the drain updates
                    // them in place. If the read collided with a write,
                    // fall back to invalidating both ways.
                    if (qa_wcol_q || qa_wcol_now) begin
                        pwq_w[pwq_wp[3:0] - 4'd1] <= '0;
                        inv_pend <= 1'b1;
                        inv_line <= f_line(c_addr_l);
                        inv_tag  <= f_tag(c_addr_l);
                        inv_w <= '1;
                    end else begin
                        pwq_w[pwq_wp[3:0] - 4'd1] <= ca_hitw;
                    end
                    cst <= C_IDLE;             // cpu_ready this cycle
                end
                default: cst <= C_IDLE;
            endcase
            if (inv_clr) inv_pend <= 1'b0;
            if (pwq_pop_now) pwq_v[pwq_rp[3:0]] <= 1'b0;
        end
    end

    // ------------------------------------------------- render engine (port B)
    // Serial-port model: a row latch streams one word per clk within a cache
    // line and touches the cache only at line boundaries (every 8 words),
    // like the real 315-5387's serial port.
    typedef enum logic [1:0] {R_STREAM, R_LOAD, R_FILL} rst_e;
    // the row-stream context (one; the per-walk-core contexts of E6_MSTREAM
    // were retired 2026-10-28, docs/cleanup.md #7)
    rst_e            rstt;
    logic [127:0]    rline;
    logic [TAGW-1:0] rltag;
    logic [LB-1:0]   rlidx;
    logic            rlval;
    logic [12:0]     rladdr;
    logic [15:0]     r_addr_l;

    logic [15:0]     r_a;
    assign r_a = (rstt==R_STREAM) ? rnd_addr : r_addr_l;
    logic [LB-1:0]   req_line; assign req_line = f_line(r_a);
    logic [TAGW-1:0] req_tag;  assign req_tag  = f_tag(r_a);
    logic            rline_hit;
    assign rline_hit = rlval && (rlidx==req_line) && (rltag==req_tag);

    // ---- boundary pre-stage. Going through R_LOAD at every 8-word boundary
    // would cost 2 cycles per line, too slow for a 672-word worst-case walk.
    // While a row streams, port B is idle, so the next sequential line is
    // read into a second latch and swapped in at the boundary with no dead
    // cycle. A write to the staged line drops the copy.
    logic [127:0]    rline_nx;
    logic [TAGW-1:0] nxtag; logic [LB-1:0] nxidx; logic nxval;
    logic [12:0]     nxaddr;            // staged line's word address [15:3]
    logic            nx_ld_q;
    logic [15:0]     nx_wa_q;
    wire             nx_sid_ok = 1'b1;
    logic            nx_hit;
    assign nx_hit = nxval && (nxidx == req_line) && (nxtag == req_tag);
    logic [15:0]     nx_wa;             // next sequential line after current
    assign nx_wa = {(rladdr + 13'd1), 3'b000};

    // previous-row file: the walks interleave reads from other rows (scroll
    // table entries, name/pattern alternation). Every row leaving the latch
    // retires into this file, and a boundary that matches an entry swaps
    // with it, so going back and forth costs nothing. Two entries, because
    // the text layer's walk visits two pattern rows between name-row reads.
    localparam int   PVN = 2;
    localparam int   PVB = (PVN <= 2) ? 1 : $clog2(PVN);
    logic [127:0]    rline_pv [0:PVN-1];
    logic [TAGW-1:0] pvtag [0:PVN-1]; logic [LB-1:0] pvidx [0:PVN-1];
    logic            pvval [0:PVN-1];
    logic [12:0]     pvaddr [0:PVN-1];
    logic [PVB-1:0]  pv_lru;          // next retire victim (round-robin)
    logic [PVN-1:0]  pv_hitv;
    logic            pv_hit;
    logic [PVB-1:0]  pvk;             // which entry hit (valid when pv_hit)
    always_comb
        for (int i = 0; i < PVN; i++)
            pv_hitv[i] = pvval[i] && (pvidx[i]==req_line) && (pvtag[i]==req_tag);
    assign pv_hit = |pv_hitv;
    always_comb begin
        pvk = '0;
        for (int i = 0; i < PVN; i++) if (pv_hitv[i]) pvk = PVB'(i);
    end
    logic [PVN-1:0]  pv_whitv;
    always_comb
        for (int i = 0; i < PVN; i++)
            pv_whitv[i] = cwr_stb && pvval[i] && (cwr_row == pvaddr[i]);

    assign rb_line_q = (rstt==R_STREAM && rnd_re && rline_hit)
                       ? f_line(nx_wa)                 // stage the next line
                       : req_line;                     // cache read = req line

    // serve-on-R_LOAD: the array read for an unstaged boundary was issued
    // at the boundary cycle, so on a clean hit the word is served in R_LOAD
    // while the FSM captures the row: an unstaged boundary costs one cycle.
    // The guards are the FSM's capture guards.
    logic [WAYS-1:0] rb_hw, nx_hw;
    logic rb_h0, rb_h1;   // rb_h0 = "resident in SOME way"; rb_h1 retired
    logic rb_ld_ok;
    logic rnd_need_fill, rnd_fill_done;
    logic [15:0] rnd_rdata_mem;
    assign rnd_rdata_mem = (rstt==R_LOAD && rb_sid_ok)
                       ? qb_sel[16*r_a[2:0] +: 16]
                     : (rstt==R_STREAM && !rline_hit && nx_hit)
                       ? rline_nx[16*r_a[2:0] +: 16]   // boundary word: staged
                     : (rstt==R_STREAM && !rline_hit && pv_hit)
                       ? rline_pv[pvk][16*r_a[2:0] +: 16] // boundary: prev file
                       : rline[16*r_a[2:0] +: 16];     // from the row latch
    assign rnd_rdata = rnd_rdata_mem;
    // rnd_hold: the walk waits while the requested word has a queued write
    // (pwq_m_rword), and otherwise until the word is in a latch or the
    // R_LOAD read hits. The FSM may still load or fill while it waits.
    assign rnd_hold  = rnd_re
                       && (
                           pwq_m_rword ||
                           // the drain edge pops the queue (pwq_m_rword
                           // falls) and raises cwr_stb, but the latch
                           // valid bits it clears drop one edge LATER, so
                           // for this one cycle a latch hit on the written
                           // row is the pre-write copy (rb_ld_ok carries
                           // the same guard). Found by the render-read
                           // BIST on SegaSonic's boot: $31FF7E read back
                           // 0000 the cycle after its 00DF drained
                           // (docs/sonic-bringup.md §6.3).
                           (cwr_stb && (cwr_row == r_a[15:3])) ||
                           !((rstt==R_STREAM
                                 && (rline_hit || nx_hit || pv_hit))
                                || rb_ld_ok));

    // port-B way hits (registered read of EVERY way at rb_line)
    always_comb
        for (int w = 0; w < WAYS; w++) begin
            rb_hw[w] = f_mhit(qbm[w], cur_ep, req_tag);
            nx_hw[w] = f_mhit(qbm[w], cur_ep, f_tag(nx_wa_q));
        end
    assign rb_h0 = |rb_hw;
    assign rb_h1 = 1'b0;   // keeps every (rb_h0 || rb_h1) idiom correct
    logic nx_h0, nx_h1;
    assign nx_h0 = |nx_hw;
    assign nx_h1 = 1'b0;
    // way-selected port-B data
    logic [127:0] qb_sel, qbnx_sel;
    always_comb begin
        qb_sel = qb[0]; qbnx_sel = qb[0];
        for (int w = 0; w < WAYS; w++) begin
            if (rb_hw[w]) qb_sel   = qb[w];
            if (nx_hw[w]) qbnx_sel = qb[w];
        end
    end

    // -------- row latch invalidation. A drained CPU write (cwr_stb, with
    // its row) clears any latch holding that row: current, staged or
    // previous, whether or not the line is still in the cache. Fills do
    // not clear latches: a refill carries the same data, and a fill with
    // newer data always follows the write's own cwr_stb. A boundary branch
    // that moves a latch on the same edge applies the clear itself.
    logic rl_whit, nx_whit;
    assign rl_whit  = cwr_stb && rlval && (cwr_row == rladdr);
    assign nx_whit  = cwr_stb && nxval && (cwr_row == nxaddr);
    // capture guards: an array read used at edge T was issued at edge T-1.
    // A write to the same set at either edge makes it stale (or undefined
    // on the FPGA). The registered flags cover T-1, the inline terms T; a
    // guarded capture waits one cycle and uses the fresh read.
    logic nx_wcol_q, rb_wcol_q;
    wire  rb_wcol_use = rb_wcol_q;
    // R_LOAD retarget settle: the cycle after a retarget, qb still holds
    // the old line's read and could false-hit, so it is skipped. (A normal
    // R_LOAD entry issued its read at the boundary and needs no settle.)
    logic rl_ret_q;
    // serve-on-R_LOAD = the FSM capture guards, plus the live request must
    // still be the parked one (rnd_addr == r_addr_l): after a hand-over the
    // next walk core may already present a different word. A mismatch
    // retargets the load (see R_LOAD below).
    wire rb_sid_ok = 1'b1;
    assign rb_ld_ok = (rstt==R_LOAD) && (rb_h0 || rb_h1) && rb_sid_ok
                      && (rnd_addr == r_addr_l) && !rl_ret_q
                      && !rb_wcol_use
                      && !(wr_any  && (cw_line == req_line))
                      && !(cwr_stb && (cwr_row == r_addr_l[15:3]));

    always_ff @(posedge clk) begin
        if (rst) begin
            rstt <= R_STREAM; rlval <= 1'b0;
            rnd_need_fill <= 1'b0;
            nxval <= 1'b0; nx_ld_q <= 1'b0;
            for (int i = 0; i < PVN; i++) pvval[i] <= 1'b0;
            pv_lru <= '0;
            nx_wcol_q <= 1'b0; rb_wcol_q <= 1'b0;
            rl_ret_q <= 1'b0;
        end else begin
            // latch invalidation first: a branch below that moves a latch
            // on this edge sets its own validity
            if (rl_whit)  rlval <= 1'b0;
            if (nx_whit)  nxval <= 1'b0;
            for (int i = 0; i < PVN; i++) if (pv_whitv[i]) pvval[i] <= 1'b0;
            // capture-collision pipeline flags (read edge = T-1 of consume)
            nx_wcol_q <= (wr_any  && (cw_line == f_line(nx_wa)))
                      || (cwr_stb && (cwr_row == nx_wa[15:3]));
            rb_wcol_q <= (wr_any  && (cw_line == f_line(r_a)))
                      || (cwr_stb && (cwr_row == r_a[15:3]));
            // pre-stage pipeline: rb_line was steered at the staged target
            // last cycle, so qb0/qb1 hold it now — capture if resident AND
            // no write touched the staged set at the read or capture edge
            nx_ld_q <= (rstt==R_STREAM) && rnd_re && rline_hit;
            nx_wa_q <= nx_wa;
            if (nx_ld_q && !nx_wcol_q && (nx_h0 || nx_h1) && nx_sid_ok
                && !(wr_any  && (cw_line == f_line(nx_wa_q)))
                && !(cwr_stb && (cwr_row == nx_wa_q[15:3]))) begin
                rline_nx <= qbnx_sel;
                nxidx <= f_line(nx_wa_q); nxtag <= f_tag(nx_wa_q);
                nxaddr <= nx_wa_q[15:3];
                nxval <= 1'b1;
            end
            unique case (rstt)
                R_STREAM:                              // 1 word/clk while in row
                    if (rnd_re && !rline_hit) begin
                        if (nx_hit) begin
                            // free boundary: consume the staged line (this
                            // cycle's word is served from rline_nx by the
                            // rnd_rdata mux above); the outgoing row
                            // retires into the previous-row file's LRU
                            // slot. A write superseding either copy THIS
                            // edge lands in the incoming validity (whit
                            // terms = the old identities being moved).
                            rline <= rline_nx;
                            rlidx <= nxidx; rltag <= nxtag;
                            rlval <= !nx_whit;
                            rladdr <= nxaddr;
                            nxval <= 1'b0;
                            rline_pv[pv_lru] <= rline;
                            pvidx[pv_lru] <= rlidx;
                            pvtag[pv_lru] <= rltag;
                            pvaddr[pv_lru] <= rladdr;
                            pvval[pv_lru] <= rlval && !rl_whit;
                            pv_lru <= (pv_lru == PVB'(PVN-1)) ? '0
                                                             : pv_lru + PVB'(1);
                        end else if (pv_hit) begin
                            // free boundary: EXCHANGE with the hit entry
                            // (A/B interleave ping-pong); the untouched
                            // entry becomes the next retire victim
                            rline <= rline_pv[pvk]; rlidx <= pvidx[pvk];
                            rltag <= pvtag[pvk]; rladdr <= pvaddr[pvk];
                            rlval <= !pv_whitv[pvk];
                            rline_pv[pvk] <= rline; pvidx[pvk] <= rlidx;
                            pvtag[pvk] <= rltag; pvaddr[pvk] <= rladdr;
                            pvval[pvk] <= rlval && !rl_whit;
                            pv_lru <= (pvk == PVB'(PVN-1)) ? '0 : pvk + PVB'(1);
                        end else begin
                            r_addr_l <= rnd_addr; rstt <= R_LOAD;
                        end
                    end
                R_LOAD:                                // qb* = way reads
                    if (rnd_re && rnd_addr != r_addr_l) begin
                        // the requester moved on while the load was
                        // parked (a hand-over to another walk core):
                        // retarget to the live request and re-read.
                        // Without this the FSM would wait forever for an
                        // address match that never comes.
                        r_addr_l <= rnd_addr;
                        rl_ret_q <= 1'b1;
                    end else if (rl_ret_q) begin
                        // settle: the re-steered array read launches this
                        // cycle (r_addr_l just updated); qb is still the
                        // old line's — no hit/fill decision on it
                        rl_ret_q <= 1'b0;
                    end else if (!rb_sid_ok) begin
                        // qb belongs to another stream: settle, re-read
                    end else if (rb_h0 || rb_h1) begin
                        if (rb_ld_ok)
                        begin
                            // hit clean: the word is being SERVED this
                            // cycle by the rnd_rdata R_LOAD arm (serve-on-
                            // R_LOAD) while the row lands in the latch
                            rline <= qb_sel;
                            rlidx <= req_line; rltag <= req_tag;
                            rladdr <= r_addr_l[15:3];
                            rlval <= 1'b1; rstt <= R_STREAM;
                            rline_pv[pv_lru] <= rline;
                            pvidx[pv_lru] <= rlidx;
                            pvtag[pv_lru] <= rltag;
                            pvaddr[pv_lru] <= rladdr;
                            pvval[pv_lru] <= rlval && !rl_whit;
                            pv_lru <= (pv_lru == PVB'(PVN-1)) ? '0
                                                             : pv_lru + PVB'(1);
                        end
                        // else: a write touched this set, so qb may be
                        // stale; wait for the fresh read (a line that was
                        // just invalidated then misses and fills)
                    end else begin
                        rnd_need_fill <= 1'b1; rstt <= R_FILL;
                    end
                R_FILL:
                    if (rnd_fill_done) begin
                        rnd_need_fill <= 1'b0; rstt <= R_LOAD;  // re-read cache
                    end
                default: rstt <= R_STREAM;
            endcase
            // (the write supersede lives at the TOP of the block — the
            // whit terms also cover rline and non-resident writes)
        end
    end

    // -------------------------------------------- prefetch / predictor
    logic        pf_need, pf_fill_done;
    logic [15:0] pf_addr;
    logic        vpu_go;     // pulse from the mem FSM: demand chain granted
    logic [3:0]  vpu_page;   // its page (a[15:12]) — stride-predictor key
    logic [12:0] vpu_base;   // its line base (a[15:3])
    // Span/stride predictor, one slot per 4K-word page. Layers whose rows
    // are never reused from line to line (row-select scrolling, the bitmap)
    // miss on every line. The predictor learns where each page's misses
    // start and how far that start moves per walk, and fetches the
    // predicted span as background chains in the gap between walks (~3,400
    // idle clks) and, for the frame's first walk, during vblank. A page the
    // walk still reads advances its prediction by the stride and stays
    // armed; a page the walk left is dropped after one walk.
    logic [12:0] vpp_start [0:15];   // span start (line a[15:3]) per page
    logic [12:0] vpp_str   [0:15];   // walk-to-walk span-start stride
    logic [2:0]  vpp_len   [0:15];   // span length in blocks (max 7);
                                     // never shrinks, or a well-covered
                                     // span would teach itself shorter
    logic [2:0]  vpp_run   [0:15];   // this walk's observed chain count
    logic [15:0] vpp_seen;           // page demanded during this walk
    logic [15:0] vpp_v;              // prediction armed
    logic [15:0] vpp_conf;           // the same stride was seen twice in
                                     // a row; no prediction without it
                                     // (row-select layers jump around)
    logic [15:0] vpp_live;           // page was read during this walk;
                                     // re-arming needs the predicted
                                     // target's page to be live
    logic [15:0] pf_ran;             // this gap: slot's prediction fetched
    logic [3:0]  pf_slot;            // slot that issued pf_addr (a span
                                     // can run into the next page)
    // fs_*/vli_*: read and written at one index in one block; ramstyle
    // logic keeps each out of a whole M10K (docs/corertlcleanup.md B1)
    (* ramstyle = "logic" *) logic [12:0] fs_start  [0:15];   // frame-first walk's spans (snapshot)
    logic [2:0]  fs_len    [0:15];
    logic [15:0] fs_v;
    // Last span issued per page: an unchanged span is not issued again.
    // Refilling a resident line writes the victim way and evicts an
    // unrelated live line, so repeated predictions would churn the cache.
    // A span is issued again only when its target moved (stride advance)
    // or a demand miss in its page shows something is missing.
    (* ramstyle = "logic" *) logic [12:0] vli_start [0:15];
    (* ramstyle = "logic" *) logic [2:0]  vli_len   [0:15];
    logic [15:0] vli_v;
    logic        ff_learn;           // this walk is the frame's first
    logic        vpp_fs;             // scan source: frame snapshot
    logic [4:0]  vpp_scan;           // page scan position (16 = idle)
    logic [2:0]  vpp_sub;            // block within the predicted span
    integer      vps_gap;            // cycles since last render activity
    logic [12:0] vadv;               // walk-start advance temp (blocking;
                                     // cast-free for the Quartus-17 parser)
    logic [12:0] vsk;                // scan-issue span base temp (blocking)
    always_ff @(posedge clk) begin
        if (rst) begin
            pf_need <= 1'b0; vpp_v <= '0; vpp_seen <= '0; fs_v <= '0;
            pf_ran <= '0; ff_learn <= 1'b0; vpp_fs <= 1'b0;
            vpp_scan <= 5'd16; vpp_sub <= 3'd0; vps_gap <= 0;
            vpp_live <= '0; vpp_conf <= '0; vli_v <= '0;
            for (int p = 0; p < 16; p++) begin
                vpp_len[p] <= 3'd0; vpp_run[p] <= 3'd0;
            end
        end else begin
            if (rnd_re) vpp_live[rnd_addr[15:12]] <= 1'b1;
            if (rnd_re) vps_gap <= 0;
            else        vps_gap <= vps_gap + 1;
            if (pf_fill_done) pf_need <= 1'b0;
            // a prediction that actually pulled data marks its SLOT live
            if (pf_fill_done) pf_ran[pf_slot] <= 1'b1;
            // predictor update: the first demand chain in a page this walk
            // sets the span start (and the stride from last walk's start);
            // later chains extend the span length
            if (vpu_go) begin
                // a demand miss here: let the next gap issue the span again
                vli_v[vpu_page] <= 1'b0;
                if (!vpp_seen[vpu_page]) begin
                    vpp_conf [vpu_page] <=
                        ((vpu_base - vpp_start[vpu_page]) == vpp_str[vpu_page]);
                    vpp_str  [vpu_page] <= vpu_base - vpp_start[vpu_page];
                    vpp_start[vpu_page] <= vpu_base;
                    vpp_run  [vpu_page] <= 3'd1;
                    if (vpp_len[vpu_page] == 3'd0)
                        vpp_len[vpu_page] <= 3'd1;
                    vpp_seen [vpu_page] <= 1'b1;
                    vpp_v    [vpu_page] <= 1'b1;
                end else begin
                    if (vpp_run[vpu_page] != 3'd7)
                        vpp_run[vpu_page] <= vpp_run[vpu_page] + 3'd1;
                    if (vpp_run[vpu_page] + 3'd1 > vpp_len[vpu_page]
                        && vpp_len[vpu_page] != 3'd7)
                        vpp_len[vpu_page] <= vpp_run[vpu_page] + 3'd1;
                end
                if (ff_learn) begin
                    // mirror into the frame-start snapshot
                    if (!vpp_seen[vpu_page]) begin
                        fs_start[vpu_page] <= vpu_base;
                        fs_len  [vpu_page] <= 3'd1;
                        fs_v    [vpu_page] <= 1'b1;
                    end else if (fs_len[vpu_page] != 3'd7)
                        fs_len[vpu_page] <= fs_len[vpu_page] + 3'd1;
                end
            end
            // a walk begins: stop issuing (demand fills own the SDRAM).
            // Pages whose predictions were fetched advance and stay armed,
            // since full coverage produces no demands to re-arm them. A
            // walk after a frame-length gap relearns the frame-start
            // snapshot.
            if (rnd_re && vps_gap > 1000) begin
                vpp_scan <= 5'd16; vpp_sub <= 3'd0; vpp_seen <= '0;
                for (int p = 0; p < 16; p++) begin
                    vadv = vpp_start[p] + vpp_str[p];
                    if (pf_ran[p] && vpp_live[vadv[12:9]]) begin
                        vpp_start[p] <= vadv;
                        vpp_v[p] <= 1'b1;
                    end
                end
                pf_ran <= '0; vpp_live <= '0;
                if (vps_gap > 20000) begin
                    ff_learn <= 1'b1; fs_v <= '0;
                end
            end
            // walk ended (one-shot): predict the NEXT walk's spans into the
            // inter-walk gap, where chains run uncontested
            if (vps_gap == 200) begin
                vpp_scan <= 5'd0; vpp_sub <= 3'd0; vpp_fs <= 1'b0;
                ff_learn <= 1'b0;
            end
            // vblank (one-shot): pre-warm the frame-first walk's spans
            if (vps_gap == 20000) begin
                vpp_scan <= 5'd0; vpp_sub <= 3'd0; vpp_fs <= 1'b1;
            end
            if (vpp_scan < 5'd16) begin
                vsk = vpp_fs ? fs_start[vpp_scan]
                             : (vpp_start[vpp_scan] + vpp_str[vpp_scan]);
                if (!(vpp_fs ? fs_v[vpp_scan]
                             : (vpp_v[vpp_scan] && vpp_conf[vpp_scan]))) begin
                    vpp_scan <= vpp_scan + 5'd1; vpp_sub <= 3'd0;
                end else if (vpp_sub == 3'd0 && vli_v[vpp_scan]
                             && vli_start[vpp_scan] == vsk
                             && vli_len[vpp_scan]
                                == (vpp_fs ? fs_len[vpp_scan]
                                           : vpp_len[vpp_scan])) begin
                    // this exact span was already issued and nothing has
                    // moved it since (see vli_*)
                    vpp_scan <= vpp_scan + 5'd1;
                end else if (!pf_need && !pf_fill_done) begin
                    pf_addr <= {(vsk + {7'd0, vpp_sub, 3'b000}), 3'b000};
                    pf_slot <= vpp_scan[3:0];
                    pf_need <= 1'b1;
                    // issue len+1 blocks: a span whose start drifts within a
                    // block now and then needs one block more
                    if (vpp_sub
                        >= (vpp_fs ? fs_len[vpp_scan] : vpp_len[vpp_scan]))
                    begin
                        vpp_sub <= 3'd0;
                        // disarm on issue (pf_ran or the next walk's
                        // demands re-arm it; the frame snapshot stays
                        // armed) and record the span
                        vli_start[vpp_scan] <= vsk;
                        vli_len  [vpp_scan] <= vpp_fs ? fs_len[vpp_scan]
                                                      : vpp_len[vpp_scan];
                        vli_v    [vpp_scan] <= 1'b1;
                        if (!vpp_fs) vpp_v[vpp_scan] <= 1'b0;
                        vpp_scan <= vpp_scan + 5'd1;
                    end else
                        vpp_sub <= vpp_sub + 3'd1;
                end
            end
        end
    end

    // ------------------------------------------------- SDRAM mem arbiter
    // 4-phase handshakes: need/go (requestor) <-> done (this FSM). done is set
    // on completion and cleared when the requestor drops its need/go, so a
    // requestor can never miss a single-cycle grant window.
    typedef enum logic [2:0] {M_IDLE, M_FILL, M_SET, M_WR, M_CHFIN,
                              M_VFY} mst_e;
    mst_e mst;
    logic rf_urg;                 // current rf grant is a render demand
    assign rf_urgent = rf_req && rf_urg;
    logic [1:0]  serve_kind;      // 0=cpu 1=render-demand 2=prefetch
    logic [15:0] fill_a;

    // ---- Row chain. A demand or prefetch miss fetches the whole aligned
    // 64-word row in one grant, starting at the missed line and wrapping
    // mod 8, so lines arrive about as fast as the walk uses them. The chain
    // stops early if the walk misses outside this row. CPU fills are
    // single bursts.
    localparam bit CHAIN_EN = 1'b1;
    logic        m_chain;         // current grant runs the chain protocol
    logic [15:0] ch_base;         // aligned 64-word row base (word addr)
    logic [2:0]  ch_start;        // first line index within the row
    logic [3:0]  ch_iss;          // lines issued (acked) this grant
    logic [3:0]  ch_cap;          // lines captured (strobed) this grant
    // posted-write update lane enables: word offset -> its two byte
    // lanes, masked by bsel (explicit args only)
    function automatic logic [15:0] f_wben(input logic [2:0] off,
                                           input logic [1:0] bsel);
        f_wben = '0;
        f_wben[{off, 1'b0}] = bsel[0];
        f_wben[{off, 1'b1}] = bsel[1];
    endfunction
    // chain line-k address: explicit args only (no module-scope reads
    // inside functions for Quartus 17)
    function automatic logic [15:0] f_chaddr(input logic [3:0]  k,
                                             input logic [15:0] cb,
                                             input logic [2:0]  cs);
        logic [2:0] li;
        li = cs + k[2:0];              // wraps mod 8 within the row
        f_chaddr = {cb[15:6], li, 3'b000};
    endfunction
    // demand line already resident (a previous chain brought it in): serve
    // without a grant. Consumed only while the walk is parked in
    // R_FILL/R_LOAD, where port B is held at r_addr_l — so the registered
    // qb metadata IS this line's residency (no separate probe).
    logic dem_resident;
    assign dem_resident = (rstt != R_STREAM) && (rb_h0 || rb_h1);

    assign pwq_pop_now = (mst == M_WR) && wr_done;

    // ---- line a fill installs this cycle: fill_a for a single burst, the
    // current chain member for a chain
    logic [15:0] cap_la;
    always_comb
        cap_la = m_chain ? f_chaddr(ch_cap, ch_base, ch_start) : fill_a;

    // pending-write matches: a fill of a line with a queued write waits for
    // the drain (its data would predate the write); a CPU read of a queued
    // word waits in C_LOOK.

    always_comb begin
        pwq_m_cword = 1'b0; pwq_m_rword = 1'b0;
        pwq_m_rline = 1'b0; pwq_m_pline = 1'b0; pwq_m_cline = 1'b0;
        pwq_m_capline = 1'b0;
        for (int i = 0; i < PWQ_N; i++) begin
            if (pwq_v[i] && pwq_a[i] == c_addr_l)
                pwq_m_cword = 1'b1;
            if (pwq_v[i] && pwq_a[i] == r_a)
                pwq_m_rword = 1'b1;
            if (pwq_v[i] && pwq_a[i][15:3] == r_addr_l[15:3])
                pwq_m_rline = 1'b1;
            if (pwq_v[i] && pwq_a[i][15:3] == pf_addr[15:3])
                pwq_m_pline = 1'b1;
            if (pwq_v[i] && pwq_a[i][15:3] == c_addr_l[15:3])
                pwq_m_cline = 1'b1;
            if (pwq_v[i] && pwq_a[i][15:3] == cap_la[15:3])
                pwq_m_capline = 1'b1;
        end
    end

    // ---- Chain vs queued writes. The guards above test only the line a
    // grant was issued for, but a chain fills the whole 64-word row. A
    // chain member whose line has a queued write would install the old
    // data, and the drain would never patch it (the line was not resident
    // at the accept). So a chain member with a queued write is simply not
    // installed: the line stays absent and is refilled on a later miss,
    // after the drain. The burst is already in flight, so this costs no
    // SDRAM time, and the rest of the chain is unaffected. (Prefetch chains
    // can never meet a queued write: the drain outranks prefetch in
    // M_IDLE.)
    wire pw_cap_skip = pwq_m_capline;

    // fill-way pick: the per-set LRU victim (one MLAB read site). A refill
    // of a resident line may briefly duplicate it; both copies match SDRAM,
    // and a drained write updates every way it was resident in.
    logic [15:0] w_tgt;
    always_comb
        w_tgt = (m_chain && rf_stb)    ? f_chaddr(ch_cap, ch_base, ch_start)
                                       : fill_a;
    // victim = the way after the last-filled one (with two ways: the other)
    logic [WB-1:0] w_way;
    assign w_way = clru[f_line(w_tgt)] + WB'(1);

    always_ff @(posedge clk) begin
        cw_we <= '0; mw_we <= '0;
        vpu_go <= 1'b0;
        cwr_stb <= 1'b0;
        inv_clr <= 1'b0; aw_gnt <= 1'b0;
        if (rst) begin
            mst <= M_IDLE;
            cpu_fill_done <= 1'b0; rnd_fill_done <= 1'b0;
            pf_fill_done <= 1'b0;
            m_chain <= 1'b0; rf_cont <= 1'b0; rf_urg <= 1'b0;
            pwq_rp <= '0;
            if (rf_done || !rf_req) rf_req <= 1'b0;
            if (wr_done || !wr_req) wr_req <= 1'b0;
        end else begin
            // clear completion flags once the requestor releases
            if (!cpu_need_fill) cpu_fill_done <= 1'b0;
            if (!rnd_need_fill) rnd_fill_done <= 1'b0;
            if (!pf_need)       pf_fill_done  <= 1'b0;

            unique case (mst)
                M_IDLE: begin
                    // accept-side invalidate: 1 cycle, no port contention
                    // here (fill strobes fire only in M_FILL/M_VFY)
                    if (inv_pend && !inv_clr) begin
                        mw_we  <= inv_w;
                        cw_line <= inv_line;
                        cw_tag  <= inv_tag;
                        inv_clr <= 1'b1;
                    end
                    if (!go) ;
                    else if (aw_req) begin
                        // posted-write push handshake: while aw_req is up
                        // (request through push) NOTHING else is granted,
                        // so no fill can race the push or the accept-side
                        // residency capture
                        if (!aw_gnt) aw_gnt <= 1'b1;
                    end
                    else if (rnd_need_fill && !rnd_fill_done
                             && ((CHAIN_EN && dem_resident)
                                 || !pwq_m_rline)) begin
                        if (CHAIN_EN && dem_resident)
                            // an earlier chain already landed this line
                            rnd_fill_done <= 1'b1;
                        else begin
                            serve_kind <= 2'd1; fill_a <= r_addr_l;
                            rf_addr <= VW + {8'd0, r_addr_l[15:3], 3'b000};
                            rf_req  <= 1'b1; rf_urg <= 1'b1;
                            m_chain <= CHAIN_EN; rf_cont <= CHAIN_EN;
                            ch_base <= {r_addr_l[15:6], 6'b0};
                            ch_start <= r_addr_l[5:3];
                            ch_iss <= 4'd0; ch_cap <= 4'd0;
                            vpu_go   <= 1'b1;             // teach predictor
                            vpu_page <= r_addr_l[15:12];
                            vpu_base <= r_addr_l[15:3];
                            mst <= M_FILL;
                        end
                    end else if (cpu_need_fill && !cpu_fill_done
                                 && !pwq_m_cline) begin
                        serve_kind <= 2'd0; fill_a <= c_addr_l;
                        rf_addr <= VW + {8'd0, c_addr_l[15:3], 3'b000};
                        rf_req  <= 1'b1; rf_urg <= 1'b0;
                        m_chain <= 1'b0; rf_cont <= 1'b0;
                        mst <= M_FILL;
                    end else if (!pwq_empty) begin
                        // drain the queue head. Above prefetch, which
                        // re-arms continuously and would starve the drain
                        // (and with it any walk waiting on pwq_m_rword).
                        // A fill blocked above by a queued write falls
                        // through to here, so it always makes progress.
                        wr_addr <= VW + {8'd0, pwq_a[pwq_rp[3:0]]};
                        wr_data <= pwq_d[pwq_rp[3:0]];
                        wr_dqm  <= ~pwq_b[pwq_rp[3:0]];
                        wr_req  <= 1'b1; mst <= M_WR;
                    end else if (pf_need && !pf_fill_done && !pwq_m_pline) begin
                        // predicted span: a full-row background chain
                        serve_kind <= 2'd2; fill_a <= pf_addr;
                        rf_addr <= VW + {8'd0, pf_addr[15:3], 3'b000};
                        rf_req  <= 1'b1; rf_urg <= 1'b0;
                        m_chain <= CHAIN_EN; rf_cont <= CHAIN_EN;
                        ch_base <= {pf_addr[15:6], 6'b0};
                        ch_start <= pf_addr[5:3];
                        ch_iss <= 4'd0; ch_cap <= 4'd0;
                        mst <= M_FILL;
                    end
                end

                M_FILL: begin
                    // ---- chain protocol
                    if (m_chain && rf_ack) begin
                        // line ch_iss issued; present the next one
                        ch_iss  <= ch_iss + 4'd1;
                        rf_addr <= VW + {8'd0,
                                   f_chaddr(ch_iss + 4'd1, ch_base, ch_start)};
                        if (ch_iss == 4'd7) rf_cont <= 1'b0; // row complete
                    end
                    if (m_chain && rnd_need_fill
                        && r_addr_l[15:6] != ch_base[15:6])
                        rf_cont <= 1'b0;   // walk left this row: stop extending
                    // a pending walk demand completes the moment its line
                    // is resident (continuous residency check — race-free
                    // against any strobe/demand alignment)
                    if (m_chain && rnd_need_fill && !rnd_fill_done
                        && dem_resident)
                        rnd_fill_done <= 1'b1;
                    if (m_chain && rf_stb) begin
                        // one line landed in rf_data: install it this
                        // cycle, unless it has a queued write (see above)
                        cw_we[w_way] <= !pw_cap_skip;
                        cw_ben  <= 16'hFFFF;
                        cw_line <= f_line(f_chaddr(ch_cap, ch_base, ch_start));
                        cw_tag  <= f_tag(f_chaddr(ch_cap, ch_base, ch_start));
                        cw_data <= rf_data;
                        ch_cap <= ch_cap + 4'd1;
                    end
                    if (rf_done) begin
                        rf_cont <= 1'b0;
                        if (!m_chain || (ch_cap == 4'd0 && !rf_stb)) begin
                            // single-burst delivery (non-chain grant, or a
                            // controller without chain support): rf_data IS
                            // the demanded line
                            rf_req <= 1'b0;
                            cw_we[w_way] <= 1'b1;
                            cw_ben  <= 16'hFFFF;
                            cw_line <= f_line(fill_a);
                            cw_data <= rf_data;
                            cw_tag  <= f_tag(fill_a);
                            mst <= M_SET;
                        end else begin
                            rf_req <= 1'b0;
                            mst <= M_CHFIN;
                        end
                    end
                end

                M_CHFIN: begin
                    // chain closed. Line valids landed WITH the data+meta
                    // writes; a pending demand completed through the
                    // continuous residency check.
                    m_chain <= 1'b0;
                    if (serve_kind == 2'd2) pf_fill_done <= 1'b1;
                    mst <= M_IDLE;
                end

                M_SET: begin
                    // (valid landed with the fill write; this state just
                    // paces the done pulse one cycle after it, preserving
                    // the original fill->ready spacing)
                    m_chain <= 1'b0;
                    unique case (serve_kind)
                        2'd1:    rnd_fill_done <= 1'b1;
                        2'd2:    pf_fill_done  <= 1'b1;
                        default: cpu_fill_done <= 1'b1;
                    endcase
                    mst <= M_IDLE;
                end

                M_WR:
                    // queue drain completion: the write is in SDRAM.
                    // Broadcast it so the row latches drop their copies.
                    if (wr_done) begin
                        wr_req <= 1'b0;
                        // update the written byte lanes in every way the
                        // line was resident in at the accept (fills of
                        // this line were held off since then)
                        if (|pwq_w[pwq_rp[3:0]]) begin
                            cw_we <= pwq_w[pwq_rp[3:0]];
                            cw_line <= f_line(pwq_a[pwq_rp[3:0]]);
                            cw_tag  <= f_tag(pwq_a[pwq_rp[3:0]]);
                            cw_data <= {8{pwq_d[pwq_rp[3:0]]}};
                            cw_ben  <= f_wben(pwq_a[pwq_rp[3:0]][2:0],
                                              pwq_b[pwq_rp[3:0]]);
                        end
                        cwr_stb <= 1'b1;
                        cwr_row <= pwq_a[pwq_rp[3:0]][15:3];
                        pwq_rp  <= pwq_rp + 5'd1;
                        mst <= M_IDLE;
                    end
                default: mst <= M_IDLE;
            endcase
        end
    end

endmodule

// ---------------------------------------------------------------------
// s32_sdp_be — byte-enabled RAM, one write port and one read port, as an
// explicit altsyncram (Quartus 17 does not infer it; see the storage note in
// s32_vramcache). A read of the address being written is undefined; the
// cache's guards never use one. Read latency 1 clk.
module s32_sdp_be #(
    parameter AW = 10,
    parameter DW = 128
) (
    input  logic            clk,
    input  logic            we,
    input  logic [AW-1:0]   waddr,
    input  logic [DW-1:0]   d,
    input  logic [DW/8-1:0] be,
    input  logic [AW-1:0]   raddr,
    output logic [DW-1:0]   q
);

    altsyncram #(
        .operation_mode("DUAL_PORT"),
        .width_a(DW), .widthad_a(AW), .numwords_a(2**AW),
        .width_b(DW), .widthad_b(AW), .numwords_b(2**AW),
        .address_reg_b("CLOCK0"),
        .outdata_reg_b("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("DONT_CARE"),
        .width_byteena_a(DW/8),
        .ram_block_type("M10K"),
        .lpm_type("altsyncram")
    ) u_ram (
        .clock0(clk), .clock1(1'b1),
        .wren_a(we), .address_a(waddr), .data_a(d), .byteena_a(be),
        .address_b(raddr), .q_b(q),
        .q_a(), .wren_b(1'b0), .data_b({DW{1'b0}}),
        .byteena_b(1'b1), .rden_a(1'b1), .rden_b(1'b1),
        .aclr0(1'b0), .aclr1(1'b0),
        .addressstall_a(1'b0), .addressstall_b(1'b0),
        .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1),
        .eccstatus()
    );

endmodule
