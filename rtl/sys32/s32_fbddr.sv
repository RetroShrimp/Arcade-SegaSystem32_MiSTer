// s32_fbddr.sv — the sprite frame buffers, kept in the DE10-Nano's DDR3.
//
// The 315-5386A has its own frame buffer bus. Sharing the SDRAM instead
// would cost about a quarter of every frame's SDRAM time (display reads,
// the erase sweep and pixel writes), so the frame buffers live in DDR3
// behind the MiSTer DDRAM port (64-bit Avalon-MM, clocked at clk_sys). The
// whole workload is about 21 MB/s, a few percent of that port.
//
// DDR3 latency is safe because the display side fetches a whole line ahead
// (s32_board's line cache), so a fetch has a full 4,123-clk line to land;
// a DDR3 round trip is a few hundred clk. If this path ever starves, the
// beam does not stall: it shows stale frame buffer words. Look for that in
// the picture, not in stall counters.
//
// Three operations over one write coalescer:
//   read_line   one 80-beat burst per scanline, returned as 40 128-bit line
//               cache entries. Highest priority; ordered against pending
//               writes by a bank compare.
//   write_run   sprite pixels and the erase sweep. Both write in ascending x,
//               so one coalescer serves both: 4 pixels per 64-bit beat,
//               consecutive beats gathered into one burst.
//   shadow_rmw  clears bit 15 of a stored pixel. It needs the stored word, so
//               it is a full barrier plus a DDR round trip.
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
// other drains. The drainer only touches a sealed buffer (wsel != fill), and
// fbw_ok refuses a write that would need a seal while the other buffer is
// still busy.
//
// Avalon-MM protocol (through f2sdram_safe_terminator, DATA=64 BURST=8):
//   read : rd + burstcnt + addr, held until a !busy cycle takes it; beats
//          return with dout_ready (busy stalls the request, not the beats).
//   write: we + burstcnt + addr; the address is sampled on the first beat;
//          one beat per !busy cycle; we held for all beats.
//   busy is waitrequest, sampled the same cycle as the request, so every
//   request is held until a !busy cycle takes it.

module s32_fbddr #(
    // byte 0x31000000 as a 64-bit-word address (the loader owns 0x30000000)
    parameter logic [28:0] FB_BASE = 29'h06200000,
    // RUNMAX is 16: at 64 Quartus builds the gather buffers from registers
    // and the design no longer fits. 16 beats is still 64 pixels per burst.
    parameter int          RUNMAX  = 16,       // beats per burst (64 px)
    parameter int          LBEATS  = 80        // beats per scanline (320 px)
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
    output logic         rf_stb,     // one 128-bit fbl entry valid this cycle
    output logic [5:0]   rf_idx,     // which entry (0..LBEATS/2-1)
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
    input  logic         ddr_dout_ready
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
    (* ramstyle = "MLAB" *) logic [63:0] run_d0  [0:RUNMAX-1];
    (* ramstyle = "MLAB" *) logic [63:0] run_d1  [0:RUNMAX-1];
    (* ramstyle = "MLAB" *) logic [7:0]  run_be0 [0:RUNMAX-1];
    (* ramstyle = "MLAB" *) logic [7:0]  run_be1 [0:RUNMAX-1];
    logic [15:0] run_base [0:1];
    logic [7:0]  run_n    [0:1];
    logic        run_rdy  [0:1];              // sealed, waiting for the bus
    logic        run_bank [0:1];

    logic        sh_pend;
    logic [15:0] sh_a;
    logic [1:0]  sh_lane;
    logic [63:0] sh_word;
    logic        sh_word_v;

    // ------------------------------------------------- accept-side decode
    // Pure combinational classification of this cycle's write; the always_ff
    // below applies it directly (no tasks: non-blocking assignments inside
    // tasks let the push and the seal race on run_n).
    wire other_free = !run_rdy[~fill] && (run_n[~fill] == 8'd0);
    wire w_px_raw   = fb_we && cen_ok && !fb_shadow;
    wire w_sh_raw   = fb_we && cen_ok &&  fb_shadow;

    wire same_beat  = acc_v && (w_a == acc_a);
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
    assign fbw_ok = go && !sh_pend && !(need_seal && !other_free)
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
    typedef enum logic [2:0] {
        D_IDLE, D_RD, D_RDW, D_WR, D_SHRD, D_SHW, D_SHWR
    } dst_e;
    dst_e dst;

    logic [6:0] rbeat;                        // 0..LBEATS-1
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
                ddr_burstcnt = 8'(LBEATS);
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
                ddr_be       = 8'h03 << (2 * sh_lane);
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

        if (rst) begin
            dst       <= D_IDLE;
            acc_v     <= 1'b0;
            fill      <= 1'b0;
            wsel      <= 1'b0;
            sh_pend   <= 1'b0;
            sh_word_v <= 1'b0;
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
            if (do_accept && fb_shadow) begin
                // Barrier. Retire whatever is gathering so the RMW cannot pass
                // an older write to the same word, then block until it lands.
                sh_pend <= 1'b1;
                sh_a    <= w_a;
                sh_lane <= w_lane;
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
                acc_be <= 64'(2'b11)    << ( 2 * w_lane);
            end

            // ====================================================== FSM
            unique case (dst)
                D_IDLE: begin
                    if (go && rf_go && !scan_conflict) begin
                        rbeat <= 7'd0;
                        dst   <= D_RD;
                    end
                    else if (go && sh_pend && all_quiet && !have_run) begin
                        sh_word_v <= 1'b0;
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
                        if (rbeat == 7'(LBEATS - 1)) begin
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
                        sh_word   <= ddr_dout & ~(64'h8000 << (16 * sh_lane));
                        sh_word_v <= 1'b1;
                        dst       <= D_SHWR;
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
