// s32_fbddr.sv — the sprite frame buffers, kept in the DE10-Nano's DDR3.
//
// The 315-5386A has its own frame buffer bus. Sharing the SDRAM instead
// would cost about a quarter of every frame's SDRAM time (display reads,
// the erase sweep and pixel writes), so the frame buffers live in DDR3
// behind the MiSTer DDRAM port (64-bit Avalon-MM, clocked at clk_sys). The
// whole workload is about 21 MB/s, a few percent of that port.
//
// DDR3 latency is safe because the display side fetches a whole line ahead
// (s32_board's line cache), so a fetch has a full 4,123-clk line (4,096 in
// the 416-pixel mode) to land;
// a DDR3 round trip is a few hundred clk. If this path ever starves, the
// beam does not stall: it shows stale frame buffer words. Look for that in
// the picture, not in stall counters.
//
// Three operations over one write coalescer:
//   read_line   one 80-beat burst per scanline (104 in the 416-pixel mode),
//               returned as 40 (52) 128-bit line cache entries. Highest priority; ordered against pending
//               writes by a bank compare.
//   write_run   sprite pixels and the erase sweep. Both write in ascending x,
//               so one coalescer serves both: 4 pixels per 64-bit beat,
//               consecutive beats gathered into one burst.
//   shadow_rmw  clears bit 15 of stored pixels. It needs the stored word, so
//               it is a full barrier plus a DDR round trip. Shadow writes to
//               the same 64-bit beat merge into one RMW while it is still
//               pending (sh_mask), so a shadow sprite's row costs one round
//               trip per 4 pixels, not per pixel (Burning Rival's floor
//               shadows: ~3,000 shadow pixels a frame overran the sprite
//               frame budget at one RMW each, board bench SPRDEADLINE).
//
// Ordering: the scan reads the displayed bank while the engine draws the
// hidden one, so they normally cannot conflict. Two cases can, and one rule
// covers both (scan_conflict: flush anything pending for the bank being
// read):
//   - command 02 (trig_erase_shown) erases the displayed buffer;
//   - at a swap, the old hidden bank becomes displayed while its last writes
//     may still be in the coalescer.
//
// Two gather buffers, so the engine can keep writing into one while the
// other drains. The drainer only touches a sealed buffer, and fbw_ok refuses
// a write that would need a seal while the other buffer is still busy. One
// exception to "wsel != fill": a shadow barrier is accepted even when the
// other buffer is busy. It seals the filling buffer and flips `fill` onto
// the one draining, but sh_pend then blocks every write until both buffers
// have drained, so nothing is pushed into a draining buffer. svf's match mode
// does this constantly (shadowed players); the invariant asserted below is
// therefore "no push into the draining buffer", not "fill != wsel".
//
// Avalon-MM protocol (through f2sdram_safe_terminator, DATA=64 BURST=8):
//   read : rd + burstcnt + addr, held until a !busy cycle takes it; beats
//          return with dout_ready (busy stalls the request, not the beats).
//   write: we + burstcnt + addr; the address is sampled on the first beat;
//          one beat per !busy cycle; we held for all beats.
//   busy is waitrequest, sampled the same cycle as the request, so every
//   request is held until a !busy cycle takes it.
//
// Reset never cuts a transaction. The f2sdram port has no reset of its own:
// a write burst abandoned with beats still owed leaves it waiting for them
// until the DE10 is power-cycled (the framework's f2sdram_safe_terminator
// covers only the system reset, not rst_core). rst_core fires on OSD reset,
// on every ROM download and on chk_busy, so on 2026-10-19 an OSD reset left
// a gray/white screen, and every later ROM load hung on its DDR3 read with
// no video at all. So rst only takes effect once the FSM is back in D_IDLE:
// a burst in flight finishes first (a write with its own, valid data; a read
// takes all its beats, so no stray beat can misalign the next line read),
// and `quiet` tells S32.sv when the DDR3 loader may take the port.

module s32_fbddr #(
    // byte 0x31000000 as a 64-bit-word address (the loader owns 0x30000000)
    parameter logic [28:0] FB_BASE = 29'h06200000,
    // RUNMAX is 16: at 64 Quartus builds the gather buffers from registers
    // and the design no longer fits. 16 beats is still 64 pixels per burst.
    parameter int          RUNMAX  = 16,       // beats per burst (64 px)
    parameter int          LBEATS  = 80,       // beats per scanline (320 px)
    parameter int          LBEATS_W = 104      // the same for 416 px (wide)
) (
    input  logic         clk,
    input  logic         rst,        // rst_core
    input  logic         go,         // DDR free (loader finished)

    // ---- engine write side (s32_sprite_top)
    input  logic         fb_we,
    input  logic         fb_bank,
    input  logic [8:0]   fb_x,
    input  logic [7:0]   fb_y,
    input  logic [15:0]  fb_wdata,
    input  logic         fb_shadow,
    // The engine's clock enable without fbw_ok. Using the fully gated
    // fb_we && cen_spr here would make a combinational loop (fbw_ok ->
    // cen_spr -> fb_we -> fbw_ok).
    input  logic         cen_ok,
    output logic         fbw_ok,     // 0 = backpressure (freezes cen_spr)

    // ---- scan line fill (s32_board's line cache)
    input  logic         rf_req,     // level, held until rf_done
    input  logic [7:0]   rf_line,
    input  logic         rf_bank,
    input  logic         rf_wide,    // 416-pixel mode: LBEATS_W beats a line
    output logic         rf_stb,     // one 128-bit fbl entry valid this cycle
    output logic [5:0]   rf_idx,     // which entry (0..LBEATS/2-1, or LBEATS_W/2-1)
    output logic [127:0] rf_data,
    output logic         rf_done,

    // ---- MiSTer DDRAM master
    input  logic         ddr_busy,
    output logic         ddr_rd,
    output logic         ddr_we,
    output logic [28:0]  ddr_addr,
    output logic [7:0]   ddr_burstcnt,
    output logic [63:0]  ddr_din,
    output logic [7:0]   ddr_be,
    input  logic [63:0]  ddr_dout,
    input  logic         ddr_dout_ready,
    output logic         quiet       // no transaction in flight (dst == D_IDLE)
);

    // ---------------------------------------------------------------- map
    // FB word (16-bit) address = {bank, y[7:0], x[8:0]} = 18 bits = 512 KB.
    // Four pixels per 64-bit beat, so the beat address drops x[1:0] and one
    // scanline = 128 beats = 1 KB, naturally aligned: a line read is one
    // aligned burst with no page-crossing case.
    wire [15:0] w_a    = {fb_bank, fb_y, fb_x[8:2]};
    wire [1:0]  w_lane = fb_x[1:0];

    // ------------------------------------------------------- write gather
    logic        acc_v;
    logic [15:0] acc_a;
    logic [63:0] acc_d;
    logic [7:0]  acc_be;

    localparam int RW = $clog2(RUNMAX);       // gather index width
    logic        fill;                        // buffer currently accepting
    logic        wsel;                        // buffer currently draining
    // MLAB with an asynchronous read (ddr_din/ddr_be read the drained buffer
    // combinationally). Plain "MLAB" left all four as registers plus a read
    // mux (Info 276009: Quartus cannot implement the RTL's same-address
    // read-during-write); "no_rw_check" lets it build the MLAB, which is
    // safe because nothing is ever pushed into the buffer being drained (the
    // invariant asserted at the end of this module; it has never fired in
    // any board-bench run, every game). A same-address collision could only
    // happen in a buffer that is filling, whose read data the D_WR state
    // never uses. Measured 2026-10-27 (quartus_map probe): all four in the
    // RAM Summary as MLAB, ~2,300 registers gone. board-design.md §9.6a.
    (* ramstyle = "MLAB, no_rw_check" *) logic [63:0] run_d0  [0:RUNMAX-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [63:0] run_d1  [0:RUNMAX-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0]  run_be0 [0:RUNMAX-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0]  run_be1 [0:RUNMAX-1];
    logic [15:0] run_base [0:1];
    logic [7:0]  run_n    [0:1];
    logic        run_rdy  [0:1];              // sealed, waiting for the bus
    logic        run_bank [0:1];

    logic        sh_pend;
    logic [15:0] sh_a;
    logic [3:0]  sh_mask;                     // lanes of sh_a to clear
    logic [63:0] sh_word;

    typedef enum logic [2:0] {
        D_IDLE, D_RD, D_RDW, D_WR, D_SHRD, D_SHW, D_SHM, D_SHWR
    } dst_e;
    dst_e dst;
    assign quiet = (dst == D_IDLE);

    // ------------------------------------------------- accept-side decode
    // Pure combinational classification of this cycle's write; the always_ff
    // below applies it directly (no tasks: non-blocking assignments inside
    // tasks let the push and the seal race on run_n).
    wire other_free = !run_rdy[~fill] && (run_n[~fill] == 8'd0);
    wire w_px_raw   = fb_we && cen_ok && !fb_shadow;
    wire w_sh_raw   = fb_we && cen_ok &&  fb_shadow;

    wire same_beat  = acc_v && (w_a == acc_a);
    // a shadow write to the beat of a pending RMW merges into it until the
    // mask is applied: D_SHW captures the raw word, D_SHM applies sh_mask one
    // clk later, so a merge accepted on the capture cycle still counts. Only
    // registered state decides (no path from the DDR handshake into fbw_ok
    // and the engine's clock enable). Nothing else can be written meanwhile:
    // sh_pend blocks pixel writes.
    wire sh_merge   = w_sh_raw && sh_pend && (w_a == sh_a)
                      && (dst != D_SHM) && (dst != D_SHWR);
    wire contig     = acc_v && (w_a == acc_a + 16'd1);
    wire moving     = w_px_raw && acc_v && !same_beat;

    // A run ENDS when the next beat is not contiguous, or the buffer fills.
    //
    // brk_addr must not also require run_n[fill] != 0: with one beat in the
    // accumulator and nothing pushed yet, a jump would then not seal, and the
    // old beat would be written at the next run's base address. (moving
    // implies acc_v, so a one-beat run seals correctly.)
    wire brk_addr   = moving && !contig;
    wire brk_full   = moving && (run_n[fill] + 8'd1 >= 8'(RUNMAX));
    wire need_seal  = brk_addr || brk_full;

    // The engine stalls ONLY when a seal is required and the other buffer is
    // not free, or while a shadow barrier resolves, or before DDR is available.
    assign fbw_ok = go && !rst && (!sh_pend || sh_merge)
                       && !(need_seal && !other_free)
                       && !(w_sh_raw && 1'b0);   // shadows are accepted, then
                                                 // block via sh_pend next cycle

    wire do_accept = fb_we && cen_ok && fbw_ok;
    wire do_push   = do_accept && !fb_shadow && acc_v && !same_beat;

    // Idle time before an unsealed run is flushed. The engine drops fb_we
    // between pixels, so sealing after one idle cycle would send one-beat
    // bursts. The timeout outlasts a normal gap between pixels; it decides
    // only when a partial run leaves, never whether it does.
    localparam int IDLE_SEAL = 16;
    logic [4:0] idle_cnt;
    wire        idle_seal = (idle_cnt >= 5'(IDLE_SEAL));

    // a pending write touches the bank the scan wants -> order them
    wire scan_conflict =
          (sh_pend          && sh_a[15]     == rf_bank)
       || (acc_v            && acc_a[15]    == rf_bank)
       || (run_n[0] != 8'd0 && run_bank[0]  == rf_bank)
       || (run_n[1] != 8'd0 && run_bank[1]  == rf_bank);

    // ---------------------------------------------------- single push port
    // One write site per gather array (Quartus will not build a RAM with the
    // writes spread over several FSM branches). push_now is the union of every
    // case that retires acc into run[fill]; idle_push_cond mirrors the D_IDLE
    // seal condition.
    wire idle_push_cond = (dst == D_IDLE) && !do_accept && other_free
                          && ((rf_go && scan_conflict) || sh_pend
                              || (idle_seal
                                  && (acc_v || run_n[fill] != 8'd0)));
    wire  push_now = acc_v && ((do_accept && fb_shadow)
                            || (do_accept && !fb_shadow && !same_beat)
                            || idle_push_cond);
    wire [RW-1:0] push_i = run_n[fill][RW-1:0];

    always_ff @(posedge clk)
        if (push_now && !fill) begin
            run_d0 [push_i] <= acc_d;
            run_be0[push_i] <= acc_be;
        end
    always_ff @(posedge clk)
        if (push_now && fill) begin
            run_d1 [push_i] <= acc_d;
            run_be1[push_i] <= acc_be;
        end

    // ----------------------------------------------------------- main FSM
    // (the state, dst, is declared above the accept-side decode)

    logic [6:0] rbeat;                        // 0..LBEATS-1 (LBEATS_W-1)
    logic       rd_wide;                      // the line read's width, latched
                                              // when it is issued
    wire  [6:0] rd_last = rd_wide ? 7'(LBEATS_W - 1) : 7'(LBEATS - 1);
    logic [6:0] widx;                         // beat index within a burst
    logic [63:0] rd_lo, rd_hi;

    wire [63:0] run_d_sel  = wsel ? run_d1 [widx[RW-1:0]] : run_d0 [widx[RW-1:0]];
    wire [7:0]  run_be_sel = wsel ? run_be1[widx[RW-1:0]] : run_be0[widx[RW-1:0]];

    // A served line request must not start again while the client still holds
    // it: a second fetch right after rf_done would be taken by the client as
    // its NEXT line.
    logic rf_seen;
    wire  rf_go = rf_req && !rf_seen;

    wire have_run = run_rdy[0] || run_rdy[1];
    wire nxt_run  = run_rdy[0] ? 1'b0 : 1'b1;
    wire all_quiet = !acc_v && (run_n[0] == 8'd0) && (run_n[1] == 8'd0);

    // ------------------------------------------------------- DDR outputs
    always_comb begin
        ddr_rd       = 1'b0;
        ddr_we       = 1'b0;
        ddr_addr     = 29'd0;
        ddr_burstcnt = 8'd0;
        ddr_din      = 64'd0;
        ddr_be       = 8'hFF;
        unique case (dst)
            D_RD: begin
                ddr_rd       = 1'b1;
                ddr_addr     = FB_BASE + {13'd0, rf_bank, rf_line, 7'd0};
                ddr_burstcnt = 8'(rd_last) + 8'd1;
            end
            D_WR: begin
                ddr_we       = 1'b1;
                ddr_addr     = FB_BASE + {13'd0, run_base[wsel]};
                ddr_burstcnt = run_n[wsel];
                ddr_din      = run_d_sel;
                ddr_be       = run_be_sel;
            end
            D_SHRD: begin
                ddr_rd       = 1'b1;
                ddr_addr     = FB_BASE + {13'd0, sh_a};
                ddr_burstcnt = 8'd1;
            end
            D_SHWR: begin
                ddr_we       = 1'b1;
                ddr_addr     = FB_BASE + {13'd0, sh_a};
                ddr_burstcnt = 8'd1;
                ddr_din      = sh_word;
                ddr_be       = {{2{sh_mask[3]}}, {2{sh_mask[2]}},
                                {2{sh_mask[1]}}, {2{sh_mask[0]}}};
            end
            default: ;
        endcase
    end

    // Read beats arrive in pairs -> one 128-bit entry {hi beat, lo beat}. Both
    // halves are registered: rf_stb is registered, and by then ddr_dout has
    // moved on to the next beat.
    assign rf_data = {rd_hi, rd_lo};

    // ------------------------------------------------------------- engine
    integer i;
    always_ff @(posedge clk) begin
        rf_stb  <= 1'b0;
        rf_done <= 1'b0;

        // see the header: a reset waits for the transaction in flight
        if (rst && dst == D_IDLE) begin
            dst       <= D_IDLE;
            acc_v     <= 1'b0;
            fill      <= 1'b0;
            wsel      <= 1'b0;
            sh_pend   <= 1'b0;
            idle_cnt  <= 5'd0;
            rf_seen   <= 1'b0;
            for (i = 0; i < 2; i = i + 1) begin
                run_n[i]   <= 8'd0;
                run_rdy[i] <= 1'b0;
            end
        end else begin

            if (do_accept)                idle_cnt <= 5'd0;
            else if (!idle_seal)          idle_cnt <= idle_cnt + 5'd1;

            if (!rf_req) rf_seen <= 1'b0;

            // =================================================== accept
            if (do_accept && fb_shadow && sh_pend) begin
                // merge into the pending RMW (sh_merge: same beat, not read)
                sh_mask[w_lane] <= 1'b1;
            end else if (do_accept && fb_shadow) begin
                // Barrier. Retire whatever is gathering so the RMW cannot pass
                // an older write to the same word, then block until it lands.
                sh_pend <= 1'b1;
                sh_a    <= w_a;
                sh_mask <= 4'b0001 << w_lane;
                if (acc_v) begin
                    run_n[fill] <= run_n[fill] + 8'd1;   // data: push_now above
                    acc_v       <= 1'b0;
                end
                if (acc_v || run_n[fill] != 8'd0) begin
                    run_rdy[fill] <= 1'b1;
                    fill          <= ~fill;
                end
            end else if (do_accept && same_beat) begin
                // same beat: merge the pixel in (the common case — 4 px/beat)
                acc_d [16 * w_lane +: 16] <= fb_wdata;
                acc_be[ 2 * w_lane +:  2] <= 2'b11;
            end else if (do_accept) begin
                // moving to a new beat (or the very first one)
                if (do_push) run_n[fill] <= run_n[fill] + 8'd1;
                if (need_seal) begin
                    // the pushed beat closed the run; hand the buffer over and
                    // start the new run in the other one
                    run_rdy[fill]   <= 1'b1;
                    fill            <= ~fill;
                    run_base[~fill] <= w_a;
                    run_bank[~fill] <= fb_bank;
                end else if (!acc_v && run_n[fill] == 8'd0) begin
                    // first beat of a fresh run
                    run_base[fill] <= w_a;
                    run_bank[fill] <= fb_bank;
                end
                acc_v  <= 1'b1;
                acc_a  <= w_a;
                // one assignment per variable (rather than a clear plus a
                // part-select write)
                acc_d  <= 64'(fb_wdata) << (16 * w_lane);
                acc_be <= 8'(2'b11)     << ( 2 * w_lane);
            end

            // ====================================================== FSM
            unique case (dst)
                D_IDLE: begin
                    if (go && rf_go && !scan_conflict) begin
                        rbeat   <= 7'd0;
                        rd_wide <= rf_wide;
                        dst     <= D_RD;
                    end
                    else if (go && sh_pend && all_quiet && !have_run) begin
                        dst       <= D_SHRD;
                    end
                    else if (go && have_run) begin
                        wsel <= nxt_run;
                        widx <= 7'd0;
                        dst  <= D_WR;
                    end
                    // Seal on pressure: a scan is blocked behind us, a shadow
                    // barrier is waiting, or the sweep left a partial beat and
                    // has gone quiet (so it always lands).
                    //
                    // Two guards (inside idle_push_cond):
                    //  - !do_accept, or this would race the accept block above
                    //    on run_n/acc_v/fill and push a beat twice;
                    //  - other_free, or the next writes would land in a buffer
                    //    that is draining.
                    else if (idle_push_cond) begin
                        if (acc_v) begin
                            run_n[fill] <= run_n[fill] + 8'd1;
                            acc_v       <= 1'b0;
                        end
                        run_rdy[fill] <= 1'b1;
                        fill          <= ~fill;
                    end
                end

                D_RD:
                    if (!ddr_busy) dst <= D_RDW;      // request taken

                D_RDW:
                    if (ddr_dout_ready) begin
                        if (!rbeat[0])
                            rd_lo <= ddr_dout;
                        else begin
                            rd_hi  <= ddr_dout;
                            rf_stb <= 1'b1;
                            rf_idx <= rbeat[6:1];
                        end
                        if (rbeat == rd_last) begin
                            rf_done <= 1'b1;
                            rf_seen <= 1'b1;
                            dst     <= D_IDLE;
                        end else
                            rbeat <= rbeat + 7'd1;
                    end

                D_WR:
                    if (!ddr_busy) begin
                        if (widx + 7'd1 >= 7'(run_n[wsel])) begin
                            run_n[wsel]   <= 8'd0;
                            run_rdy[wsel] <= 1'b0;
                            dst <= D_IDLE;
                        end else
                            widx <= widx + 7'd1;
                    end

                D_SHRD:
                    if (!ddr_busy) dst <= D_SHW;

                D_SHW:
                    if (ddr_dout_ready) begin
                        sh_word   <= ddr_dout;           // raw; D_SHM masks it
                        dst       <= D_SHM;
                    end

                D_SHM: begin
                    sh_word <= sh_word & ~{sh_mask[3], 15'd0, sh_mask[2], 15'd0,
                                           sh_mask[1], 15'd0, sh_mask[0], 15'd0};
                    dst     <= D_SHWR;
                end

                D_SHWR:
                    if (!ddr_busy) begin
                        sh_pend <= 1'b0;
                        dst <= D_IDLE;
                    end

                default: dst <= D_IDLE;
            endcase
        end
    end

endmodule
