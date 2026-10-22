// s32_sprite_top.sv — 315-5386A control wrapper: $500000-$50000F
// register interface, double-framebuffer sequencing (erase / swap /
// render triggers, auto and manual modes), control-latch semantics and
// the flip IN -> TEMP -> OUT delay chain.
//
// References: s32tech, 315-5386A (trigger values 01/02/03, status bits,
// flip delay over two swaps, auto mode renders at vblank-out at 60 or
// 30 Hz, register read-back shows only the live low bits). The render
// engine itself is s32_sprite.sv.
//
// The frame buffers are external (2 x 512 wide x 224 x 16 bits, in DDR3
// via s32_board): this wrapper selects the bank to draw into, sends erase
// sweeps and the engine's pixel writes through one write port, and tells
// the display side which bank to show. The OUT-stage flip bits go to the
// display side, which reverses its scan direction (as MAME does in its
// mix loop).
//
// The erase sweep covers the buffer width x 224 at one pixel per cycle.
// The real chip's erase and draw times are not documented; status reads 1
// (normal), or 2 while the engine is still busy at the next trigger.
//
// Manual mode: a trigger that finds the previous render still running ends
// it (2026-10-20, docs/svf-bringup.md 6.10, OPEN-QUESTIONS Q41). s32tech's
// $500002 status 2 is "rendering time is over but end-of-list command not
// read yet": the real chip renders inside a time window and stops when it
// closes; it does not carry a list into the next frame. MAME renders each
// trigger's list in full, instantly. Before this, the trigger swapped and
// erased while the old walk kept running (its start for the new list was
// ignored by the busy engine), so svf's one-frame garbage list (a cleared
// list buffer that runs on into a data table, ~912k pixels) cascaded over
// four triggers and showed as stripes and an empty frame in the replay
// banner's fade-in. Auto mode keeps its own policy below (skip one tick,
// then the watchdog), which only ever triggers from W_IDLE.

module s32_sprite_top (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,          // engine/sequencer enable (freeze on 0)

    // CPU register port ($500000-$50000F, word offsets 0-7)
    input  logic        cpu_sel,
    input  logic        cpu_we,
    input  logic [3:1]  cpu_addr,
    input  logic [15:0] cpu_wdata,
    input  logic [1:0]  cpu_bsel,    // byte strobes: every control
                                     // field is in the low byte, so a
                                     // write to the high byte alone
                                     // fires no trigger and latches
                                     // nothing
    output logic [15:0] cpu_rdata,

    // frame sync (auto mode trigger point)
    input  logic        ev_vblank_out,

    // sprite RAM read port (passed through from the engine)
    output logic        sr_re,
    output logic [15:0] sr_addr,
    input  logic [15:0] sr_rdata,

    // sprite ROM read port (passed through from the engine)
    output logic        rom_re,
    output logic [21:0] rom_addr,
    input  logic [31:0] rom_rdata,

    // framebuffer write port (render bank implied by fb_bank)
    output logic        fb_we,
    output logic        fb_bank,      // bank being RENDERED (hidden)
    output logic [8:0]  fb_x,
    output logic [7:0]  fb_y,
    output logic [15:0] fb_wdata,
    output logic        fb_shadow,    // bit-15-clear RMW
    output logic        fb_erase,     // write is part of an erase sweep

    // display-side status
    output logic        disp_bank,    // bank being DISPLAYED
    output logic [1:0]  flip_out,     // OUT-stage {V, H} for the scanner
    output logic        render_busy
);

    // ------------------------------------------------------ registers
    logic [1:0] r04_in, r04_tmp, r04_out;     // flip IN/TEMP/OUT
    logic [1:0] r06, r08, r0a;                // mode, transparency selects
    logic       r0c;                          // fb width (416)
    logic [1:0] l08, l0a;                     // latched at swap
    logic       l0c;
    logic       shown;                        // displayed bank
    logic       hz30_phase;
    logic [1:0] mcmd;                         // manual command awaiting vblank-out

    assign disp_bank = shown;
    assign flip_out = r04_out;

    // ------------------------------------------------------ sequencer
    typedef enum logic [1:0] { W_IDLE, W_ERASE, W_RENDER } wstate_e;
    wstate_e wst;

    logic        eng_start, eng_busy, eng_abort;
    logic        er_pend;              // erase after swap
    logic [8:0]  er_x;
    logic [7:0]  er_y;
    logic [8:0]  er_w;
    logic        er_disp;              // erase DISPLAYED buffer (cmd 02)
    logic        ovr_hold;             // one auto tick already skipped busy
    logic        restart_pend;         // manual time-out: start after abort

    assign render_busy = (wst != W_IDLE) || eng_busy;

    // engine instance (latched control bits)
    logic        e_we;
    logic [8:0]  e_x;
    logic [7:0]  e_y;
    logic [15:0] e_wdata;
    logic        e_shadow;
    s32_sprite u_eng (
        .clk(clk), .rst(rst), .cen(cen),
        .ctl08(l08), .ctl0a(l0a), .fb416(l0c),
        .start(eng_start), .abort(eng_abort), .busy(eng_busy),
        .sr_re(sr_re), .sr_addr(sr_addr), .sr_rdata(sr_rdata),
        .rom_re(rom_re), .rom_addr(rom_addr), .rom_rdata(rom_rdata),
        .fb_we(e_we), .fb_x(e_x), .fb_y(e_y),
        .fb_wdata(e_wdata), .fb_shadow(e_shadow)
    );

    // framebuffer write mux: erase sweep or engine pixels
    always_comb begin
        fb_erase = (wst == W_ERASE);
        if (wst == W_ERASE) begin
            fb_we = 1'b1;
            fb_x = er_x;
            fb_y = er_y;
            fb_wdata = 16'hFFFF;
            fb_shadow = 1'b0;
            fb_bank = er_disp ? shown : ~shown;
        end else begin
            fb_we = e_we;
            fb_x = e_x;
            fb_y = e_y;
            fb_wdata = e_wdata;
            fb_shadow = e_shadow;
            fb_bank = ~shown;          // render to the hidden buffer
        end
    end

    // trigger decode: combinational, so a frame swap happens in the same
    // cycle as vblank-out; pulses that arrive while cen is low are caught
    // in pending latches and act on the first active cycle.
    logic trig_now, trig_swap_now, trig_es_now, trig_eh_now, wd_now;
    always_comb begin
        trig_now = 1'b0;
        trig_swap_now = 1'b0;
        trig_es_now = 1'b0;
        trig_eh_now = 1'b0;
        wd_now = 1'b0;
        if (r06[1]) begin
            // manual mode: the command latched from the last $500000 write
            // (mcmd) acts at vblank-out, where the automatic mode swaps too,
            // never mid-frame. Acting on the CPU write itself would let
            // Holosseum flip the displayed bank in the middle of a frame.
            // s32tech gives the command values but not their timing; MAME
            // (segas32_v.cpp update_sprites) acts at the end of vblank, and
            // Sega's VDP1 manual gives the same rule for its manual mode
            // ("change in next field", ST-013-R3 p.39). Golden Axe and
            // Spider-Man never use manual mode.
            if (ev_vblank_out) begin
                unique case (mcmd)
                    2'd1: begin trig_now = 1'b1; trig_swap_now = 1'b1; end
                    2'd2: trig_es_now = 1'b1;
                    2'd3: begin
                        trig_now = 1'b1; trig_swap_now = 1'b1;
                        trig_eh_now = 1'b1;
                    end
                    default: ;
                endcase
            end
        end else begin
            // auto mode: swap + erase + render at vblank-out (60 Hz) or
            // every other frame (30 Hz), but only once the previous frame's
            // render has finished (wst == W_IDLE). If a scene overruns its
            // frame, skip this tick and keep showing the last complete frame
            // instead of the half-drawn one; the render finishes and is
            // swapped in at the next vblank (a dropped frame), much as MAME
            // and the real chip's pacing behave.
            //
            // Watchdog: still busy at a second tick in a row means the job
            // is more than a frame old. Abort it, erase, and render the
            // current list again, without a swap, so the display keeps the
            // last complete frame. A single overrun still finishes and is
            // swapped in.
            if (ev_vblank_out && (!r06[0] || hz30_phase)) begin
                if (wst == W_IDLE) begin
                    trig_now = 1'b1; trig_swap_now = 1'b1;
                    trig_eh_now = 1'b1;
                end else if (ovr_hold)
                    wd_now = 1'b1;
            end
        end
    end

    logic trig_p, trig_swap_p, trig_es_p, trig_eh_p, wd_p;

    always_ff @(posedge clk) begin
        if (rst) begin
            r04_in <= 2'd0; r06 <= 2'd0; r08 <= 2'd0; r0a <= 2'd0;
            r0c <= 1'b0;
            hz30_phase <= 1'b0;
            mcmd <= 2'd0;
            ovr_hold <= 1'b0;
            trig_p <= 1'b0; trig_swap_p <= 1'b0;
            trig_es_p <= 1'b0; trig_eh_p <= 1'b0;
            wd_p <= 1'b0;
        end else begin
            // register writes (live latches; engine set latched at swap)
            if (cpu_sel && cpu_we && cpu_bsel[0]) begin
                unique case (cpu_addr)
                    3'd2: r04_in <= cpu_wdata[1:0];
                    3'd3: r06 <= cpu_wdata[1:0];
                    3'd4: r08 <= cpu_wdata[1:0];
                    3'd5: r0a <= cpu_wdata[1:0];
                    3'd6: r0c <= cpu_wdata[0];
                    default: ;
                endcase
            end

            if (ev_vblank_out) hz30_phase <= ~hz30_phase;

            // manual command latch: cleared at every vblank-out, as MAME
            // clears m_sprite_control[0] after each update; a $500000 write
            // in the same cycle wins (it applies at the next vblank-out).
            // Latched in both modes like MAME's register, but acted on only
            // in manual mode. (In auto mode MAME would also run a written
            // command on a 30 Hz off-frame; none of the supported games
            // writes one in auto mode.)
            if (ev_vblank_out) mcmd <= 2'd0;
            if (cpu_sel && cpu_we && cpu_addr == 3'd0 && cpu_bsel[0])
                mcmd <= cpu_wdata[1:0];

            // watchdog arm (not gated by cen, like hz30_phase; wst holds
            // while cen is low): an auto tick that finds the render busy
            // arms it, a second busy tick in a row fires wd_now above, and
            // an idle tick clears it. Uses the same hz30_phase as the
            // trigger decode this cycle.
            if (ev_vblank_out && !r06[1] && (!r06[0] || hz30_phase))
                ovr_hold <= (wst != W_IDLE) && !ovr_hold;

            // catch pulses only while frozen; clear on the first
            // active cycle (the FSM acts on them that same cycle)
            if (!cen) begin
                if (trig_now)      trig_p <= 1'b1;
                if (trig_swap_now) trig_swap_p <= 1'b1;
                if (trig_es_now)   trig_es_p <= 1'b1;
                if (trig_eh_now)   trig_eh_p <= 1'b1;
                if (wd_now)        wd_p <= 1'b1;
            end else begin
                trig_p <= 1'b0; trig_swap_p <= 1'b0;
                trig_es_p <= 1'b0; trig_eh_p <= 1'b0;
                wd_p <= 1'b0;
            end
        end
    end

    logic trig, trig_swap, trig_erase_shown, trig_erase_hidden, trig_wd;
    assign trig              = (trig_now && cen) || trig_p;
    assign trig_swap         = (trig_swap_now && cen) || trig_swap_p;
    assign trig_erase_shown  = (trig_es_now && cen) || trig_es_p;
    assign trig_erase_hidden = (trig_eh_now && cen) || trig_eh_p;
    assign trig_wd           = (wd_now && cen) || wd_p;

    always_ff @(posedge clk) begin
        if (rst) begin
            r04_tmp <= 2'd0; r04_out <= 2'd0;
            l08 <= 2'd0; l0a <= 2'd0; l0c <= 1'b0;
            shown <= 1'b0;
            wst <= W_IDLE;
            er_pend <= 1'b0;
            eng_start <= 1'b0;
            eng_abort <= 1'b0;
            restart_pend <= 1'b0;
        end else if (cen) begin
            eng_start <= 1'b0;
            eng_abort <= 1'b0;
            restart_pend <= 1'b0;

            // triggers
            if (trig_swap) begin
                shown <= ~shown;
                r04_out <= r04_tmp;    // flip pipeline advances at swap
                r04_tmp <= r04_in;
                l08 <= r08;            // control latch set
                l0a <= r0a;
                l0c <= r0c;
            end
            if (restart_pend) eng_start <= 1'b1;   // engine idle now
            if (trig) begin
                // manual time-out (header): only a manual trigger can find
                // the engine busy, since auto triggers need W_IDLE. The
                // engine honors abort before start, so a render that needs
                // no erase starts on the next cycle.
                if (eng_busy) eng_abort <= 1'b1;
                er_pend <= trig_erase_hidden;
                er_x <= 9'd0;
                er_y <= 8'd0;
                er_w <= r0c ? 9'd415 : 9'd319;
                er_disp <= 1'b0;
                if (trig_erase_hidden) wst <= W_ERASE;
                else if (eng_busy) begin
                    restart_pend <= 1'b1;
                    wst <= W_RENDER;
                end else begin
                    eng_start <= 1'b1;
                    wst <= W_RENDER;
                end
            end else if (trig_wd) begin
                // watchdog: abort the job, erase the hidden bank it was
                // drawing, and render the current list again. No swap,
                // no flip advance and no latch update (the aborted bank
                // is never shown). The engine drops busy during the
                // erase, well before eng_start.
                eng_abort <= 1'b1;
                er_pend <= 1'b0;
                er_x <= 9'd0;
                er_y <= 8'd0;
                er_w <= r0c ? 9'd415 : 9'd319;
                er_disp <= 1'b0;
                wst <= W_ERASE;
            end else if (trig_erase_shown && wst == W_IDLE) begin
                er_x <= 9'd0;
                er_y <= 8'd0;
                er_w <= r0c ? 9'd415 : 9'd319;
                er_disp <= 1'b1;
                er_pend <= 1'b0;
                wst <= W_ERASE;
            end

            // erase sweep
            if (wst == W_ERASE) begin
                if (er_x == er_w) begin
                    er_x <= 9'd0;
                    if (er_y == 8'd223) begin
                        if (er_disp)
                            wst <= W_IDLE;      // cmd 02: no render
                        else begin
                            eng_start <= 1'b1;
                            wst <= W_RENDER;
                        end
                    end else
                        er_y <= er_y + 8'd1;
                end else
                    er_x <= er_x + 9'd1;
            end

            // render completion
            if (wst == W_RENDER && !eng_busy && !eng_start && !restart_pend)
                wst <= W_IDLE;
        end
    end

    // ---------------------------------------------------- register reads
    // fixed-1 bit patterns per s32tech; only documented bits are live
    always_comb begin
        cpu_rdata = 16'hFFFF;
        if (cpu_sel && !cpu_we) begin
            unique case (cpu_addr)
                3'd0: cpu_rdata = {14'h3FFF,
                                   (wst == W_ERASE), shown};
                3'd1: cpu_rdata = {14'h3FFF,
                                   render_busy ? 2'd2 : 2'd1};
                3'd2: cpu_rdata = {14'h3FFF, r04_tmp};
                3'd3: cpu_rdata = {14'h3FFF, r06};
                3'd4: cpu_rdata = {14'h3FFF, r08};
                3'd5: cpu_rdata = {14'h3FFF, r0a};
                3'd6: cpu_rdata = {14'h3FFF, 1'b0, l0c};  // latched at the swap, not live r0c (MAME m_sprite_control_latched[6])
                default: cpu_rdata = 16'hFFFC;
            endcase
        end
    end

endmodule
