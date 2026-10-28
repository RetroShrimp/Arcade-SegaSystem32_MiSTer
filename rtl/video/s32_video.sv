// s32_video.sv — the System 32 video system: the 315-5387 tilemap chip
// (text layer, four tilemap layers NBG0-NBG3, bitmap layer, clip windows),
// the 315-5388 mixer and palette, and the video timing.
//
// References: s32tech (Charles MacDonald's System 32 notes) and MAME
// segas32_v.cpp. The output was compared pixel by pixel with MAME frames.
//
// How a line is drawn:
//  - VRAM (64K x 16, at $300000-$3FFFFF, mirrored every 128KB) is kept in
//    SDRAM behind s32_vramcache. Its register block ($31FF00-$31FFFF) is
//    also copied into registers (vregs), so the layers can read their
//    settings at any time.
//  - Row transfer: during the line before each visible line, each layer
//    core in turn ("walks") copies what it needs for that line (name table
//    row, scroll tables, bitmap pixels) from VRAM into its own small
//    buffer. This models the 315-5387's serial row-transfer port: a CPU
//    write to VRAM shows from the next transfer on.
//  - The pattern streamer fetches the tile ROM rows those names point to
//    into per-layer pattern buffers, ahead of the beam.
//  - The beam-fetch FSM (bf_*) then steps every layer core once per
//    displayed dot. The mixer combines the layers and the sprite frame
//    buffer pixel at the same pace, and the result goes into a one-line
//    buffer (bf_lbuf) a few dots ahead of scanout.
//  - The palette is kept twice (pal_a, pal_b), one copy per mixer read
//    tap; the CPU writes both.
//  - Timing: 6.25 MHz pixel enable (cen_pix), 320 x 224 visible, 400 x 262
//    total. Vblank events at lines 224 and 0 go to the interrupt
//    controller.

module s32_video (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_pix,      // pixel enable: clk_sys x 6357/65536
                                      // (6.25 MHz) at 320 wide, x 8192/65536
                                      // at 416 (s32_sys acc_pix)
    input  logic        cen_ren,      // render-side enable (memory ready);
                                      // never stops raster, scanout or CPU

    // external tilebank latch (315-5296 I/O chip port H bit 0 —
    // segas32.cpp tilebank_external_w). The tile bank is two bits:
    // {this, $31FF00 bit 10} (segas32_v.cpp get_tilemaps). Golden Axe's
    // attract fire scene uses the upper 2MB of tile ROM.
    input  logic        tilebank_ext,

    // CPU slave port (word addressed, 16-bit)
    input  logic        cpu_sel,      // strobe, one access per pulse
    input  logic        cpu_we,
    input  logic [1:0]  cpu_bsel,     // byte strobes: only the mixer
                                      // registers use them; RAM writes
                                      // arrive as merged full words
    input  logic [23:1] cpu_addr,     // V60 byte address >> 1
    input  logic [15:0] cpu_wdata,
    output logic [15:0] cpu_rdata,

    // VRAM in SDRAM (s32_vramcache): vram_cpu_hold makes the V60 wait on a
    // cache miss; s32_board puts the SDRAM client on a shared port. vram_go
    // holds the cache until the SDRAM is ready.
    input  logic        vram_go,
    output logic        vram_cpu_hold,
    output logic        vram_rf_req,
    output logic        vram_rf_urg,   // the walk is stalled on this fill
    output logic [24:1] vram_rf_addr,
    output logic        vram_rf_cont,
    input  logic [127:0] vram_rf_data,
    input  logic        vram_rf_done,
    input  logic        vram_rf_stb,
    input  logic        vram_rf_ack,
    output logic        vram_wr_req,
    output logic [24:1] vram_wr_addr,
    output logic [15:0] vram_wr_data,
    output logic [1:0]  vram_wr_dqm,
    input  logic        vram_wr_done,

    // tile ROM row port, request/ack: the pattern streamer holds rom_re
    // until rom_ack marks rom_rdata as the served row. Its lead over the
    // beam absorbs the variable latency.
    output logic        rom_re,
    output logic [18:0] rom_addr,
    input  logic [63:0] rom_rdata,
    input  logic        rom_ack,

    // sprite frame buffer read port (the displayed bank, served by
    // s32_board; 1-cycle latency; tie spr_rdata to 16'hFFFF for no
    // sprites)
    output logic        spr_re,
    output logic [8:0]  spr_x,
    output logic [7:0]  spr_line,
    input  logic [15:0] spr_rdata,
    input  logic [1:0]  spr_flip,     // OUT-stage flip (scan direction)

    // Cabinet vertical mirror (from the .mra; Holosseum only, MAME
    // ORIENTATION_FLIP_Y). Not a board function: Holosseum's cabinet shows
    // the monitor through a mirror, so the viewer sees board line 223 at the
    // top. The lines are drawn in reverse order (raster line u shows board
    // line 223-u, bf_up_line below) while timing, vblank and interrupts stay
    // on the physical raster. Exact whenever the picture does not change
    // during the frame; a mid-frame change tears at a different screen line
    // than on the real cabinet. The NBG0/1 zoom cores step their vertical
    // source position once per line, so they also take the mirror and step
    // bottom-up (.vmirror). Tie 0 for every other game.
    input  logic        cab_vmirror,

    // 315-5296 CNT1 display enable (TVKL), applied at this module's output
    // (s32tech routes TVKL into the tilemap chip). The games use it to black
    // out whole frames across scene changes. Whether it also stops the tile
    // fetch is not known.
    input  logic        disp_en,

    // video output
    output logic        de,           // display enable (visible pixel)
    output logic [14:0] rgb,          // {b,g,r} 5:5:5 (DAC does << 3)
    output logic        hblank,
    output logic        vblank,
    output logic        hs,
    output logic        vs,
    // 416-pixel mode for this frame ($31FF00 bit 15, latched once per frame;
    // see `wide` below). s32_sys takes its pixel enable from it (clk_sys / 8
    // when set), s32_board its frame-buffer line length.
    output logic        wide,

    // interrupt controller events (single-cycle pulses)
    output logic        ev_vblank_in, // entering vblank (line 224)
    output logic        ev_vblank_out // leaving vblank (line 0)
);

    // ------------------------------------------------------------ timing
    // Raster geometry. Real boards have not been measured; the totals match
    // the Sega boards of the period that MAME documents (400 x 262 on the
    // same 50 MHz / 8 dot clock), and a character-clocked CRTC needs a
    // multiple of 8. Every number is a named constant so a measurement is a
    // one-line change.
    localparam int HTOTAL = 400, HVIS = 320;   // 320 mode: 6.25 MHz dot
    localparam int VTOTAL = 262, VVIS = 224;
    // sync position and width are not documented (s32tech is silent); these
    // sit inside the blanking windows
    localparam int HS_BEG = 340, HS_END = 372;  // ~5.1 us hsync
    localparam int VS_BEG = 236, VS_END = 239;  // 3-line vsync
    // 416 mode ($31FF00 bit 15, Burning Rival): 8.053975 MHz dot (32.2159 MHz
    // / 4, clk_sys / 8 exactly; s32_sys takes `wide` for its pixel enable).
    // 512 x 262 total. The line takes 4,096 clk_sys against 4,123 in 320
    // mode, so every per-line budget below keeps its margin. Sync again sits
    // inside the blanking, on 8-dot boundaries: front porch 24, sync 40, back
    // porch 32 (s32tech is silent on both modes).
    localparam int HTOTAL_416 = 512, HVIS_416 = 416;
    localparam int HS_BEG_416 = 440, HS_END_416 = 480;
    // `wide` selects the mode for a whole frame: it is taken from $31FF00
    // bit 15 at the last dot of line VVIS-1, as MAME samples the bit once per
    // frame at the screen update (segas32_v.cpp screen_update_system32).
    // When the real 315-5387 samples it is not documented (Q46). The latch
    // block sits after the register decode (r00) below.
    wire  [8:0] htot = wide ? 9'(HTOTAL_416 - 1) : 9'(HTOTAL - 1);  // last dot
    wire  [8:0] hvis = wide ? 9'(HVIS_416) : 9'(HVIS);
    wire  [8:0] hlast = hvis - 9'd1;                 // last visible column
    // Row transfer: the 315-5387 is taken to latch each line's tilemap data
    // during the line before it, so a CPU VRAM write after the transfer
    // shows from the following line. The exact dot is not documented, hence
    // a named constant.
    // The walk starts at dot 64 of the preceding line, which gives it most
    // of a line period (~2,560 clk) to wait out VRAM cache fills. Each core
    // double-buffers its row data: the walk fills the next line's bank
    // while the beam reads the current line's.
    localparam int ROW_XFER_HCNT = 64;
    wire  [8:0] row_xfer_hcnt = 9'(ROW_XFER_HCNT);

    logic [8:0] hcnt;
    logic [8:0] vcnt;
    always_ff @(posedge clk) begin
        ev_vblank_in <= 1'b0;
        ev_vblank_out <= 1'b0;
        if (rst) begin
            hcnt <= 9'd0;
            vcnt <= 9'd0;
        end else if (cen_pix) begin
            if (hcnt == htot) begin
                hcnt <= 9'd0;
                if (vcnt == 9'(VTOTAL - 1)) begin
                    vcnt <= 9'd0;
                    ev_vblank_out <= 1'b1;
                end else begin
                    vcnt <= vcnt + 9'd1;
                    if (vcnt == 9'(VVIS - 1)) ev_vblank_in <= 1'b1;
                end
            end else
                hcnt <= hcnt + 9'd1;
        end
    end

    assign hblank = hcnt >= hvis;
    assign vblank = vcnt >= 9'(VVIS);
    // sync inside the blanking windows (see HS_BEG above)
    assign hs = wide ? (hcnt >= 9'(HS_BEG_416) && hcnt < 9'(HS_END_416))
                     : (hcnt >= 9'(HS_BEG) && hcnt < 9'(HS_END));
    assign vs = vcnt >= 9'(VS_BEG) && vcnt < 9'(VS_END);

    // ------------------------------------------------------- CPU decode
    // $300000-$3FFFFF VRAM (128KB mirror), $600000-$61FFFF palette/mixer
    logic sel_vram, sel_pal;
    assign sel_vram  = cpu_sel && cpu_addr[23:20] == 4'h3;
    assign sel_pal   = cpu_sel && cpu_addr[23:16] == 8'h60;

    // Every CPU access is registered here before it touches a RAM or
    // register, so correct storage never depends on a one-cycle route from
    // the bus fabric. The registered request does the access one clock
    // later (the fabric's A_SUB_W): read data still arrives in time for
    // the fabric's capture at A_SUB_L, and writes finish a clock before it.
    // Register retiming is off in S32.qsf, so this stage stays.
    logic        cpu_req_q, cpu_we_q;
    logic [23:1] cpu_addr_q;
    logic [15:0] cpu_wdata_q;
    logic [1:0]  cpu_bsel_q;
    logic        q_sel_vram, q_sel_pal, q_sel_mixer;

    always_ff @(posedge clk) begin
        if (rst) begin
            cpu_req_q   <= 1'b0;
            cpu_we_q    <= 1'b0;
            cpu_addr_q  <= '0;
            cpu_wdata_q <= '0;
        end else begin
            cpu_req_q <= cpu_sel;
            if (cpu_sel) begin
                cpu_we_q    <= cpu_we;
                cpu_addr_q  <= cpu_addr;
                cpu_wdata_q <= cpu_wdata;
                cpu_bsel_q  <= cpu_bsel;
            end
        end
    end

    assign q_sel_vram  = cpu_req_q && cpu_addr_q[23:20] == 4'h3;
    assign q_sel_pal   = cpu_req_q && cpu_addr_q[23:16] == 8'h60;
    assign q_sel_mixer = cpu_req_q && cpu_addr_q[23:16] == 8'h61;

    // ------------------------------------------------------------- VRAM
    logic [15:0] vram_q_cpu, vram_q_rnd;
    logic        rnd_re;
    logic [15:0] rnd_addr;

    // VRAM in SDRAM behind s32_vramcache. The CPU port waits on a miss
    // (vram_cpu_hold); the render port serves the row-transfer walks. The
    // cache's render data is combinational, so it is registered into
    // vram_q_rnd (a 1-cycle read, like a RAM port); the CPU data is already
    // registered. Walk grants are gated on !rnd_stall (below).
    logic        vc_rnd_hold;
    logic [15:0] vc_rnd_rdata, vc_cpu_rdata;
    // cache size: 1024 sets (32KB)
    s32_vramcache u_vram (
        .clk(clk), .rst(rst), .go(vram_go),
        .cpu_sel(q_sel_vram), .cpu_we(cpu_we_q),
        .cpu_addr(cpu_addr_q[16:1]), .cpu_wdata(cpu_wdata_q),
        .cpu_bsel(cpu_bsel_q), .cpu_rdata(vc_cpu_rdata),
        .cpu_hold(vram_cpu_hold),
        .rnd_re(rnd_re), .rnd_addr(rnd_addr),
        .rnd_rdata(vc_rnd_rdata), .rnd_hold(vc_rnd_hold),
        .rf_req(vram_rf_req), .rf_addr(vram_rf_addr),
        .rf_cont(vram_rf_cont), .rf_urgent(vram_rf_urg),
        .rf_data(vram_rf_data), .rf_done(vram_rf_done),
        .rf_stb(vram_rf_stb), .rf_ack(vram_rf_ack),
        .wr_req(vram_wr_req), .wr_addr(vram_wr_addr),
        .wr_data(vram_wr_data), .wr_dqm(vram_wr_dqm), .wr_done(vram_wr_done)
    );
    assign vram_q_cpu = vc_cpu_rdata;
    // Capture only when the cache actually served the word: its render data
    // is meaningless while rnd_hold is high, and the cores compute their
    // next address from vram_q_rnd, so a stall must not overwrite the last
    // valid word.
    always_ff @(posedge clk) if (!vc_rnd_hold) vram_q_rnd <= vc_rnd_rdata;

    // render walk stall from the VRAM cache
    logic rnd_stall;
    assign rnd_stall = vc_rnd_hold;

    // register shadow ($31FF00-$31FFFF = word index 16'hFF80 | [6:0]).
    // Read only at constant offsets via vreg() below. Do not add a
    // variable-indexed read: Quartus 17 then treats vregs as a RAM and
    // crashes on the vreg() calls in port connections.
    logic [15:0] vregs [0:127];
    always_ff @(posedge clk)
        if (q_sel_vram && cpu_we_q && cpu_addr_q[16:8] == 9'h1FF)
            vregs[cpu_addr_q[7:1]] <= cpu_wdata_q;

    function automatic logic [15:0] vreg (input logic [7:0] off);
        vreg = vregs[off[7:1]];
    endfunction

    // ---------------------------------------------------------- palette
    // Two palette copies, both written by the CPU: port A = CPU read/write,
    // port B = one mixer tap each. No port is shared between the CPU and a
    // mixer tap, because sharing one RAM that way corrupted colours on the
    // FPGA. The second 16K x 16 copy costs ~32 M10K blocks, affordable
    // because VRAM lives in SDRAM.
    //
    // A CPU write to a palette entry while the same entry is being read on
    // that copy's port B would return undefined data. How that is avoided
    // is described at the mixer tap capture below.
    logic [15:0] pal_q_cpu;
    logic [13:0] paa, pab;
    logic [15:0] prda, prdb;  // driven by the bypass assigns below
    logic        cpu_write_hold;
    logic        cen_r;              // render enable after CPU-write hold

    // cpu_write_hold: from the receive edge through the registered write
    // edge of a CPU palette write. It pauses the row-transfer walks (cen_r).
    // VRAM writes do not pause anything: s32_vramcache orders them itself
    // (posted queue, latch invalidation, and a walk waits on exactly the
    // word being written), as the real chip's row transfer never pauses
    // for CPU writes. Pausing the walks for every write would stall them
    // through the games' bursts of 150-250 table writes.
    assign cpu_write_hold = cpu_we && sel_pal || cpu_we_q && q_sel_pal;
    assign cen_r = cen_ren && !cpu_write_hold;

    logic [13:0] paa_e, pab_e;
    assign paa_e = paa;
    assign pab_e = pab;

    // ---- $608000-$60FFFF palette 4-4-4 window ----
    // The palette is ONE physical 16K store exposed through TWO byte
    // windows (schematic sheet 5). $600000-$607FFF is native
    // "sbbbbbgggggrrrr" (5-5-5); $608000-$60FFFF (byte-addr bit 15 set =
    // cpu_addr_q[15]) is "sBGRbbbbggggrrrr" (4-4-4 + per-channel MSB).
    // The RAM is indexed by cpu_addr_q[14:1], so without conversion
    // writes through the upper window would store the 4-4-4 bits RAW as
    // 5-5-5. Golden Axe's INSERT COIN fire portrait loads its palette through
    // this window (byte $609000/$60A000+ = words 0x0800/0x1000). So writes
    // are converted window->native and CPU reads native->window, keyed on
    // the window bit. The mixer always reads native data, and a byte-write
    // read-merge-write through the window works unchanged (it reads in
    // window format and writes back through the conversion). Mapping from
    // MAME segas32.cpp: the single B/G/R bits (w[14]/w[13]/w[12]) are each
    // channel's LSB, not its MSB; w[11:8]/w[7:4]/w[3:0] are the high four
    // bits.
    function automatic logic [15:0] cram_w2n (input logic [15:0] w);
        // xBGRBBBBGGGGRRRR -> xBBBBBGGGGGRRRRR
        // blue5={w[11:8],w[14]}  green5={w[7:4],w[13]}  red5={w[3:0],w[12]}
        cram_w2n = {w[15], w[11:8], w[14], w[7:4], w[13], w[3:0], w[12]};
    endfunction
    function automatic logic [15:0] cram_n2w (input logic [15:0] n);
        // xBBBBBGGGGGRRRRR -> xBGRBBBBGGGGRRRR
        // w[14:12]={b[0],g[0],r[0]}  w[11:8]=b[4:1] w[7:4]=g[4:1] w[3:0]=r[4:1]
        cram_n2w = {n[15], n[10], n[5], n[0], n[14:11], n[9:6], n[4:1]};
    endfunction
    logic [15:0] pal_wdata;   // CPU write data, converted for the window
    assign pal_wdata = cpu_addr_q[15] ? cram_w2n(cpu_wdata_q) : cpu_wdata_q;

    logic [15:0] pal_a_qa, pal_a_qb;

    // pal_a port A: CPU read/write. Its read address must be the same plain
    // signal as the write address: an address mux here makes Quartus 17
    // build the RAM from registers, which does not fit.
    //
    // OREGB=1: the mixer reads a new entry every pixel, at addresses that
    // jump all over the 16K RAM, so its read uses the M10K's own output
    // register (see s32_tdp). The CPU port's address is held stable and
    // needs no output register.
    s32_tdp #(.AW(14), .DW(16), .OREGB(1)) u_pal_a (
        .clk(clk),
        .we_a(q_sel_pal && cpu_we_q), .addr_a(cpu_addr_q[14:1]),
        .d_a(pal_wdata), .q_a(pal_a_qa),
        .we_b(1'b0), .addr_b(paa_e), .d_b(16'd0), .q_b(pal_a_qb)
    );
    // CPU read returns the window format for $608000+ (native for $600000)
    assign pal_q_cpu = cpu_addr_q[15] ? cram_n2w(pal_a_qa) : pal_a_qa;

    // pal_b: the second mixer tap (blend / second-layer palette), the same
    // shape as pal_a. Port A = CPU write (q_a unused); port B = mixer read.
    logic [15:0] pal_b_qb;
    s32_tdp #(.AW(14), .DW(16), .OREGB(1)) u_pal_b (
        .clk(clk),
        .we_a(q_sel_pal && cpu_we_q), .addr_a(cpu_addr_q[14:1]),
        .d_a(pal_wdata), .q_a(),
        .we_b(1'b0), .addr_b(pab_e), .d_b(16'd0), .q_b(pal_b_qb)
    );

    // ------------------------------------------- mixer palette tap capture
    logic [15:0] prda_r, prdb_r;
    // The mixer runs at cen_mix = bf_cen, once per displayed dot (~10 clk).
    // The palette word for the address the mixer issues at its s0 stage is
    // captured on cen_mix and piped two mixer ticks, so it meets that pixel
    // at s1 (s0 -> s0r -> s1). The 2-clk registered read has long settled
    // by then.
    //
    // CPU palette writes: the beam-paced mixer cannot pause, so a CPU write
    // to the very entry being read on the one edge that feeds this capture
    // would return undefined data. That collision is detected (pcol_*),
    // and the written word is used instead of the RAM output: the pixel
    // shows the new colour at once, as in MAME. (The real 315-5388 makes
    // the CPU wait instead, so the pixel would show the old colour.)
    // pal_byp_hits counts these.
    logic [15:0] pcap_a, pcap_b;
    logic        pcol_a_d1, pcol_a_d2, pcol_b_d1, pcol_b_d2;
    logic [15:0] pwd_d1, pwd_d2;
    logic [15:0] pal_byp_hits;
    wire pal_we_now = q_sel_pal && cpu_we_q;
    always_ff @(posedge clk) begin
        pcol_a_d1 <= pal_we_now && (cpu_addr_q[14:1] == paa_e);
        pcol_b_d1 <= pal_we_now && (cpu_addr_q[14:1] == pab_e);
        pcol_a_d2 <= pcol_a_d1;
        pcol_b_d2 <= pcol_b_d1;
        pwd_d1    <= pal_wdata;
        pwd_d2    <= pwd_d1;
        if (rst) pal_byp_hits <= 16'd0;
        else if (cen_mix && (pcol_a_d2 || pcol_b_d2)
                 && pal_byp_hits != 16'hFFFF)
            pal_byp_hits <= pal_byp_hits + 16'd1;
        if (cen_mix) begin
            pcap_a <= pcol_a_d2 ? pwd_d2 : pal_a_qb; prda_r <= pcap_a;
            pcap_b <= pcol_b_d2 ? pwd_d2 : pal_b_qb; prdb_r <= pcap_b;
        end
    end
    assign prda = prda_r;
    assign prdb = prdb_r;

    // CPU read mux. Keyed on the address region, not on cpu_sel: the
    // fabric asserts cpu_sel only in A_SUB but captures the data two cycles
    // later (A_SUB_L), holding the address stable meanwhile. (Every byte
    // write to VRAM reads the old word for its read-merge-write, so this
    // matters.)
    always_comb begin
        cpu_rdata = 16'hFFFF;
        if (cpu_addr[23:20] == 4'h3  && !cpu_we) cpu_rdata = vram_q_cpu;
        if (cpu_addr[23:16] == 8'h60 && !cpu_we) cpu_rdata = pal_q_cpu;
    end

    // ------------------------------------------------------- renderers
    logic [15:0] r00, r02, r8e;
    assign r00 = vreg(8'h00);
    assign r02 = vreg(8'h02);
    assign r8e = vreg(8'h8E);

    // the frame's width (see the timing block): $31FF00 bit 15 at the last
    // dot of the last visible line, so the raster switches during vblank and
    // the per-frame zoom set-up (bf_zinit, the first dot of line VVIS) sees
    // the new width. Reset: 320, as MAME's screen is until the first update.
    always_ff @(posedge clk)
        if (rst) wide <= 1'b0;
        else if (cen_pix && hcnt == htot && vcnt == 9'(VVIS - 1))
            wide <= r00[15];

    logic [5:0] lay_en;
    always_comb begin
        lay_en[0] = !r02[4] && !r8e[0];
        for (int l = 0; l < 4; l++)
            lay_en[1 + l] = !r02[l] && !r8e[1 + l];
        // $31FF00 bits 12/13 disable NBG2/NBG3 (their VRAM bandwidth goes
        // to the NBG0/1 zoom; the S2ON/S3ON pins between the 315-5387 and
        // 315-5388; s32tech and MAME agree). The wider NBG0/1 zoom range
        // the same bits allow is not modelled.
        lay_en[3] &= !r00[12];
        lay_en[4] &= !r00[13];
        lay_en[5] = !r02[5] && !r8e[5];
    end

    // shared render-port users
    // beam-fetch and row-transfer control (driven by the bf_ FSM and the
    // row arbiter below; declared here, before their first use)
    logic       bf_pix, bf_ls, bf_zinit, bf_cen;
    logic [7:0] bf_line;
    logic [8:0] bf_col;
    logic       row_start;             // ROW_XFER pulse to all live cores
    logic [5:0] row_gnt;               // one-hot walk grant: t,z0,z1,r2,r3,bm
    logic       row_active;            // a row transfer is in flight
    logic [7:0] row_line;              // the upcoming visible line (walk target)
    // per-core walk ports into the shared render port B
    logic        tw_busy;
    logic [15:0] tw_vaddr;
    logic        zw_busy [0:1], rw_busy [0:1], bw_busy;
    logic [15:0] zw_vaddr [0:1], rw_vaddr [0:1], bw_vaddr;
    // declared before its first use: Quartus 17 rejects a forward
    // reference to an initialized wire
    wire [5:0] row_busy_v = {bw_busy, rw_busy[1], rw_busy[0],
                             zw_busy[1], zw_busy[0], tw_busy};
    // Per-core prefetch cursors and pattern buffers: the visible line is
    // drawn from buffers the pattern streamer (below) fills ahead of the
    // beam, so the beam never waits on the tile ROM. Index: 0/1 = NBG0/1
    // zoom, 2/3 = NBG2/3 rowscroll.
    logic        pfc_vld  [0:3], pfc_next [0:3];
    logic [5:0]  pfc_col  [0:3];
    logic [18:0] pfc_addr [0:3];
    logic [5:0]  beam_col [0:3];
    // Pattern rows, one buffer per NBG core, indexed by tile column. pq
    // must stay a whole-element connection (Quartus 17 crashes on an
    // array-element part-select in a generate-indexed port). MLAB, because
    // the M10K blocks are all in use. Double-buffered like the cores' row
    // data: the streamer fills the walk line's bank while the beam reads
    // the displayed line's bank (pb_wbank / pb_rbank).
    // the bank is the walk target line's parity (row_line[0]), the same
    // source every core uses, so all of a line's data lands in one bank
    logic pb_wbank, pb_rbank;
    wire  pb_wbank_nx = row_line[0];
    always_ff @(posedge clk) begin
        if (rst) begin pb_wbank <= 1'b0; pb_rbank <= 1'b0; end
        else begin
            if (row_start) pb_wbank <= pb_wbank_nx;
            if (bf_ls)     pb_rbank <= pb_wbank;
        end
    end
    (* ramstyle = "MLAB" *) logic [63:0] pb0 [0:127];
    (* ramstyle = "MLAB" *) logic [63:0] pb1 [0:127];
    (* ramstyle = "MLAB" *) logic [63:0] pb2 [0:127];
    (* ramstyle = "MLAB" *) logic [63:0] pb3 [0:127];
    logic [63:0] pq  [0:3];            // registered beam-column reads
    wire [63:0] pq_use [0:3];
    assign pq_use[0] = pq[0]; assign pq_use[1] = pq[1];
    assign pq_use[2] = pq[2]; assign pq_use[3] = pq[3];

    // ---- text layer (s32_text_live): its walk copies all 40 (52) tiles of the
    // line (names and patterns) into a private row store; the beam then
    // reads from that store. vr_ok = walk grant, no palette write, no cache
    // stall.
    logic [10:0] tl_pix;
    s32_text_live u_text_live (
        .clk(clk), .rst(rst),
        .cen_pix(bf_pix), .wide(wide),
        .line_start(bf_ls), .line(row_line), .r5c(vreg(8'h5C)),
        .row_start(row_start), .walk_en(lay_en[0]),
        .vr_ok(row_gnt[0] && cen_r && !rnd_stall),
        .vr_busy(tw_busy), .vr_re(),
        .vr_addr(tw_vaddr), .vr_rdata(vram_q_rnd),
        .pix(tl_pix), .pix_valid(),
        .prefetch_ready()
    );

    // The render port belongs to the row-transfer walks: the arbiter grants
    // one walking core at a time, and nothing else uses the port (the beam
    // reads only the cores' private buffers).
    always_comb begin
        // the cache's render port is request-based
        // Request only while the granted core is busy: during a hand-over
        // the address mux shows an idle core's address, which the cache
        // must not see.
        rnd_re   = row_active && (|(row_gnt & row_busy_v));
        rnd_addr = tw_vaddr;
        if (row_gnt[1]) rnd_addr = zw_vaddr[0];
        if (row_gnt[2]) rnd_addr = zw_vaddr[1];
        if (row_gnt[3]) rnd_addr = rw_vaddr[0];
        if (row_gnt[4]) rnd_addr = rw_vaddr[1];
        if (row_gnt[5]) rnd_addr = bw_vaddr;
    end

    // ---- pattern streamer. The four tilemap cores' prefetch cursors
    // present this line's tile columns in beam order; the streamer takes
    // the cores in turn, fetches each column's ROM row through the tile
    // ROM port (holding the request until rom_ack: unlike the beam, it can
    // wait for an SDRAM fill), and stores it in that core's pattern buffer.
    // ROM content never changes, so fetching early has no effect on what
    // is shown; names and scroll values are still sampled by the walks.
    //
    // Worst case (both zoom layers fully shrunk, 64 columns each, plus both
    // rowscroll layers): ~172 rows x ~19 clk = ~3.3k clk, within the ~4k
    // clk from each layer's walk to the end of its line. A per-layer
    // {addr, data} register skips the fetch for a repeated tile, which is
    // the common case.
    typedef enum logic [1:0] { PS_SCAN, PS_REQ, PS_STORE } ps_e;
    ps_e         ps;
    logic [1:0]  ps_lay;
    logic [5:0]  ps_col;
    logic [18:0] ps_addr_q;
    // ramstyle logic: 332 bits Quartus otherwise puts in 4 M10K (the
    // same-cycle feed-through it infers keeps them out of MLAB);
    // docs/corertlcleanup.md B1
    (* ramstyle = "logic" *) logic [18:0] ps_last_a [0:3];  // per-layer dedup: last served row
    (* ramstyle = "logic" *) logic [63:0] ps_last_d [0:3];
    logic        ps_last_v [0:3];
    logic        pbw_we;               // pattern-buffer store port
    logic [1:0]  pbw_lay;
    logic [5:0]  pbw_col;
    logic [63:0] pbw_data;

    assign rom_re   = (ps == PS_REQ);
    assign rom_addr = ps_addr_q;

    // never store into the column the beam is reading this cycle (a
    // same-address read and write); hold the store until the beam moves on.
    // With double buffering the streamer and the beam use different banks,
    // so this only applies when the banks are equal.
    wire pbw_clash = (bf_st == BF_STREAM)
                     && (pbw_col == beam_col[pbw_lay])
                     && (pb_wbank == pb_rbank)
                     ;

    always_ff @(posedge clk) begin
        if (rst) begin
            ps <= PS_SCAN; ps_lay <= 2'd0; pbw_we <= 1'b0;
            for (int l = 0; l < 4; l++) begin
                pfc_next[l]  <= 1'b0;
                ps_last_v[l] <= 1'b0;
            end
        end else begin
            for (int l = 0; l < 4; l++) pfc_next[l] <= 1'b0;
            if (row_start) begin
                // new line: reset the repeat registers and abandon any
                // fetch or store in flight, which would otherwise land a
                // row of the old line in the new line's buffer. A tile ROM
                // fill already running completes harmlessly.
                for (int l = 0; l < 4; l++)
                    ps_last_v[l] <= 1'b0; // new row context: dedup resets
                pbw_we <= 1'b0;
                ps     <= PS_SCAN;
            end else begin
            if (pbw_we && !pbw_clash) begin
                unique case (pbw_lay)
                    2'd0: begin
                        pb0[{pb_wbank, pbw_col}]    <= pbw_data;
                    end
                    2'd1: begin
                        pb1[{pb_wbank, pbw_col}]    <= pbw_data;
                    end
                    2'd2: begin
                        pb2[{pb_wbank, pbw_col}]    <= pbw_data;
                    end
                    2'd3: begin
                        pb3[{pb_wbank, pbw_col}]    <= pbw_data;
                    end
                endcase
                pbw_we <= 1'b0;
            end
            unique case (ps)
                PS_SCAN:
                    if (!pbw_we) begin          // store port free
                        if (pfc_vld[ps_lay]) begin
                            ps_col           <= pfc_col[ps_lay];
                            ps_addr_q        <= pfc_addr[ps_lay];
                            pfc_next[ps_lay] <= 1'b1;
                            if (ps_last_v[ps_lay]
                                && ps_last_a[ps_lay] == pfc_addr[ps_lay])
                            begin               // repeated tile: no fetch
                                pbw_lay  <= ps_lay;
                                pbw_col  <= pfc_col[ps_lay];
                                pbw_data <= ps_last_d[ps_lay];
                                pbw_we   <= 1'b1;
                                ps_lay   <= ps_lay + 2'd1;
                            end else
                                ps <= PS_REQ;
                        end else
                            ps_lay <= ps_lay + 2'd1;
                    end
                PS_REQ:
                    if (rom_ack) ps <= PS_STORE;
                PS_STORE: begin
                    pbw_lay  <= ps_lay;
                    pbw_col  <= ps_col;
                    pbw_data <= rom_rdata;
                    pbw_we   <= 1'b1;
                    ps_last_a[ps_lay] <= ps_addr_q;
                    ps_last_d[ps_lay] <= rom_rdata;
                    ps_last_v[ps_lay] <= 1'b1;
                    ps_lay <= ps_lay + 2'd1;
                    ps     <= PS_SCAN;
                end
                default: ps <= PS_SCAN;
            endcase
            end
        end
    end

    // beam-column pattern reads (1-clk registered, like the cores' own
    // row buffer reads)
    always_ff @(posedge clk) begin
        pq[0] <= pb0[{pb_rbank, beam_col[0]}];
        pq[1] <= pb1[{pb_rbank, beam_col[1]}];
        pq[2] <= pb2[{pb_rbank, beam_col[2]}];
        pq[3] <= pb3[{pb_rbank, beam_col[3]}];
    end

    // -------------------------------------------------- clip evaluation
    logic [15:0] wl [0:3], wt [0:3], wr_ [0:3], wb [0:3];
    always_comb
        for (int w = 0; w < 4; w++) begin
            wl[w] = vreg(8'h60 + 8'(8 * w));
            wt[w] = vreg(8'h62 + 8'(8 * w));
            wr_[w] = vreg(8'h64 + 8'(8 * w));
            wb[w] = vreg(8'h66 + 8'(8 * w));
        end
    logic [15:0] w4l [0:3], w4t [0:3], w4r [0:3], w4b [0:3];
    always_comb begin
        w4l[0] = vreg(8'h80); w4t[0] = vreg(8'h82);
        w4r[0] = vreg(8'h84); w4b[0] = vreg(8'h86);
        for (int w = 1; w < 4; w++) begin
            w4l[w] = 16'd0; w4t[w] = 16'd0;
            w4r[w] = 16'd0; w4b[w] = 16'd0;
        end
    end

    // =================================================================
    // Layer cores. Each is stepped by the beam (bf_pix, once per displayed
    // dot). At ROW_XFER_HCNT of the line before each visible line, every
    // core walks its own row snapshot out of VRAM (zoom/rowscroll: the
    // 64-word name row and tables; text: 40 tiles of names and patterns;
    // bitmap: the pixel-row span it needs), one core at a time through the
    // row arbiter below, into small private buffers. During the visible
    // line the beam reads only those buffers, so:
    //  - a CPU VRAM write during a line shows from the next row transfer;
    //  - the beam never touches a RAM the CPU writes, so it never pauses;
    //  - a walk that cannot finish in time (heavy CPU writes, SDRAM
    //    stalls) leaves stale row data rather than stalling the beam.
    // One dot is ~10.3 clk, so each core's name -> pattern -> pen path
    // settles well between dot strobes.

    // ---- NBG0/1 zoom layers
    logic zl_ready [0:1];
    logic [12:0] zl_pix [0:1];
    genvar zli;
    generate
        for (zli = 0; zli < 2; zli = zli + 1) begin : gzl
            s32_nbg_zoom_live u_zl (
                .clk(clk), .rst(rst), .cen_pix(bf_pix), .wide(wide),
                .line(row_line),   // walk-target line; its parity picks the bank
                .init(bf_zinit), .ready(zl_ready[zli]),
                .page_a(7'(vreg(8'h40 + 8'(4*zli)) & 16'h7F)),
                .page_b(7'((vreg(8'h40 + 8'(4*zli)) >> 8) & 16'h7F)),
                .page_c(7'(vreg(8'h42 + 8'(4*zli)) & 16'h7F)),
                .page_d(7'((vreg(8'h42 + 8'(4*zli)) >> 8) & 16'h7F)),
                .dstxstep(12'(vreg(8'h50 + 8'(4*zli)) & 16'hFFF)),
                .dstystep(r00[14]
                          ? 12'(vreg(8'h52 + 8'(4*zli)) & 16'hFFF)
                          : 12'(vreg(8'h50 + 8'(4*zli)) & 16'hFFF)),
                .hscr_i(vreg(8'h12 + 8'(8*zli))),
                .hscr_f(vreg(8'h10 + 8'(8*zli))),
                .vscr_i(vreg(8'h16 + 8'(8*zli))),
                .vscr_f(vreg(8'h14 + 8'(8*zli))),
                .center_x(vreg(8'h30 + 8'(4*zli))),
                .center_y(vreg(8'h32 + 8'(4*zli))),
                .bank({tilebank_ext, r00[10]}), .flip(r00[9] ^ r00[zli]),
                .flipy(r00[9] ^ (r00[zli] & ~r00[8])),
                .vmirror(cab_vmirror),
                .row_start(row_start), .walk_en(lay_en[1 + zli]),
                .line_start(bf_ls),
                .vr_ok(row_gnt[1 + zli] && cen_r && !rnd_stall),
                .vr_busy(zw_busy[zli]), .vr_re(),
                .vr_addr(zw_vaddr[zli]), .vr_rdata(vram_q_rnd),
                .rom_re(), .rom_addr(),
                .rom_rdata(pq_use[zli]),
                .pf_vld(pfc_vld[zli]), .pf_col(pfc_col[zli]),
                .pf_addr(pfc_addr[zli]), .pf_next(pfc_next[zli]),
                .pf_done(), .col(beam_col[zli]),
                .pix(zl_pix[zli])
            );
        end
    endgenerate

    // ---- NBG2/3 rowscroll layers
    logic [12:0] rl_pix [0:1];
    genvar rli;
    // per-line window mode and edges from each rowscroll core
    logic       rl_win_mode [0:1];
    logic       rl_win_act [0:1];
    logic [9:0] rl_win_lo  [0:1];
    logic [9:0] rl_win_hi  [0:1];
    generate
        for (rli = 0; rli < 2; rli = rli + 1) begin : grl
            s32_nbg_rowscroll_live u_rl (
                .clk(clk), .rst(rst), .cen_pix(bf_pix), .wide(wide),
                .line_start(bf_ls), .line(row_line), .bg3(1'(rli)),
                .page_a(7'(vreg(8'h48 + 8'(4*rli)) & 16'h7F)),
                .page_b(7'((vreg(8'h48 + 8'(4*rli)) >> 8) & 16'h7F)),
                .page_c(7'(vreg(8'h4A + 8'(4*rli)) & 16'h7F)),
                .page_d(7'((vreg(8'h4A + 8'(4*rli)) >> 8) & 16'h7F)),
                .hscr_i(vreg(8'h22 + 8'(8*rli))),
                .vscr_i(vreg(8'h26 + 8'(8*rli))),
                .center_x(vreg(8'h38 + 8'(4*rli))),
                .r04(vreg(8'h04)),
                .bank({tilebank_ext, r00[10]}), .flip(r00[9] ^ r00[2 + rli]),
                .flipy(r00[9] ^ (r00[2 + rli] & ~r00[8])),
                .gflip(r00[9]),
                .row_start(row_start), .walk_en(lay_en[3 + rli]),
                .vr_ok(row_gnt[3 + rli] && cen_r && !rnd_stall),
                .vr_busy(rw_busy[rli]), .vr_re(),
                .vr_addr(rw_vaddr[rli]), .vr_rdata(vram_q_rnd),
                .rom_re(), .rom_addr(),
                .rom_rdata(pq_use[2 + rli]),
                .pf_vld(pfc_vld[2 + rli]), .pf_col(pfc_col[2 + rli]),
                .pf_addr(pfc_addr[2 + rli]), .pf_next(pfc_next[2 + rli]),
                .pf_done(), .col(beam_col[2 + rli]),
                .win_mode(rl_win_mode[rli]),
                .win_active(rl_win_act[rli]),
                .win_lo(rl_win_lo[rli]), .win_hi(rl_win_hi[rli]),
                .pix(rl_pix[rli])
            );
        end
    endgenerate

    // ---- bitmap layer (pixels come from VRAM; no ROM)
    logic [13:0] bl_pix;
    s32_bitmap_live u_bml (
        .clk(clk), .rst(rst), .cen_pix(bf_pix), .wide(wide),
        .line_start(bf_ls), .line(row_line), .bpp8(r00[11]),
        .r88(vreg(8'h88)), .r8a(vreg(8'h8A)), .r8c(vreg(8'h8C)),
        // A disabled bitmap layer is not walked (2026-10-19). Its rows can
        // never reach the screen (lay_en[5] masks it in the mixer, as MAME's
        // enableb does), but its walk is the heaviest VRAM reader and it took
        // the VRAM-over-SDRAM bandwidth the visible layers need: svf's match
        // mode ($31FF02 = 6320, bitmap off) failed ROWWALK and PBWITNESS
        // with the bitmap walk the straggler on every late line. The enable
        // is sampled at the walk (the line before display), so a bitmap
        // turned ON mid-frame would show one stale row; no supported game
        // does that (docs/svf-bringup.md section 6.6).
        .row_start(row_start && lay_en[5]),
        .vr_ok(row_gnt[5] && cen_r && !rnd_stall),
        .vr_busy(bw_busy), .vr_re(),
        .vr_addr(bw_vaddr), .vr_rdata(vram_q_rnd),
        .pix(bl_pix), .pix_valid()
    );

    // ---- live clip evaluators, at the beam column/line
    //
    // clip_x is bf_col minus one: the pen the mixer latches on a cen_mix
    // belongs to the previous beam column, so clipping at bf_col itself
    // would put every clip edge one pixel to the left. (Checked by
    // programming a known rectangle, L=100 R=200: exactly columns 100..200
    // are clipped.)
    //
    // It also saturates at the last column (319, or 415 in the wide mode):
    // bf_col runs past the line while the mixer pipeline drains, and the
    // last screen column is taken during the drain, so without the limit a
    // rectangle with R = $13F would not clip column 319 (MAME clips it).
    wire [8:0] clip_x;
    wire [7:0] clip_ln;
    assign clip_x  = (bf_col == 9'd0)   ? 9'd0
                   : (bf_col > hvis)    ? hlast
                   : (bf_col - 9'd1);
    assign clip_ln = bf_line;

    // ---- per-line clip windows (MAME compute_clipping_extents after
    // 0.288, mamedev/mame#16038). $31FF04 bit 4 replaces clip
    // window 2's X range, line by line, with NBG2's table (+000 left, +200
    // right); bit 5 does the same for window 3 from NBG3's table (+100/+300).
    // The window keeps its register Y range, and EVERY layer whose $31FF06
    // nibble selects it sees the substituted span, with its ordinary clip-IN/
    // OUT polarity. Edges are inclusive; a $FFFF word = no window on the line;
    // left > right = empty. Under global flip the span mirrors like the
    // rects: x is in [W-1-right, W-1-left] <=> left <= W-1-x <= right, W
    // the visible width (MAME mirrors over visarea.right()).
    wire [8:0] lw_x = r00[9] ? (hlast - clip_x) : clip_x;
    wire [3:0] lw_arm = {rl_win_mode[1], rl_win_mode[0], 2'b00};
    wire lw_in2 = rl_win_act[0] && ({1'b0, lw_x} >= rl_win_lo[0])
                                && ({1'b0, lw_x} <= rl_win_hi[0]);
    wire lw_in3 = rl_win_act[1] && ({1'b0, lw_x} >= rl_win_lo[1])
                                && ({1'b0, lw_x} <= rl_win_hi[1]);
    wire [3:0] lw_in = {lw_in3, lw_in2, 2'b00};
    logic nbg_draw_live [0:3];
    genvar cli;
    generate
        for (cli = 0; cli < 4; cli = cli + 1) begin : gcl
            s32_clip u_cl (
                .x(clip_x), .y(clip_ln),
                .clipen(r02[11 + cli]), .clipout(r02[6 + cli]),
                .winmask(4'(vreg(8'h06) >> (4 * cli))),
                .gflip(r00[9]), .sw({1'b0, hvis}),
                .win_l(wl), .win_t(wt), .win_r(wr_), .win_b(wb),
                .lw_arm(lw_arm), .lw_in(lw_in),
                .draw(nbg_draw_live[cli])
            );
        end
    endgenerate
    logic bm_draw_live;
    s32_clip u_c4l (
        .x(clip_x), .y(clip_ln),
        .clipen(r02[15]), .clipout(r02[10]),
        .winmask(4'b0001), .gflip(r00[9]), .sw({1'b0, hvis}),
        .win_l(w4l), .win_t(w4t), .win_r(w4r), .win_b(w4b),
        .lw_arm(4'd0), .lw_in(4'd0),       // bitmap = window 4, no table
        .draw(bm_draw_live)
    );

    // ====================================================== beam-fetch FSM
    // Three timing rules here must hold together:
    //  1. Palette words are captured on cen_mix (see the tap capture above).
    //  2. The mixer streams a line without gaps, so mix_rgb at bf_col = c is
    //     screen column c - BF_OFF; bf_lbuf is indexed by that directly,
    //     and the FSM runs BF_OFF extra "drain" dots so the last columns
    //     come out.
    //  3. BF_LEAD >= BF_OFF + 2, so column C is written before the beam
    //     reads it (otherwise every line shows the previous line). 10 leaves
    //     a 3-dot margin.
    //
    // Drive the cores straight off the scanout beam: per frame restore
    // the zoom divider (bf_zinit at vblank top); per visible line, at a LEAD
    // point in the preceding HBLANK, pulse bf_ls with bf_line = that line,
    // take one settle dot (the first VRAM word lands), then stream bf_pix
    // once per dot so the cores present pen(bf_col) — the mixer taps that
    // pen the same cycle (bf_cen). The fetch leads the display by BF_LEAD
    // dots so each bf_lbuf[C] is WRITTEN before the beam READS it at
    // hcnt=C. The write for column C lands at hcnt = C + (1 + BF_OFF -
    // BF_LEAD); to keep it ahead of the read (offset <= -1) requires
    // BF_LEAD >= BF_OFF + 2 = 8. HBLANK is 80 dots so the fetch start sits
    // well inside it and clears the prior line's drain (ends ~hcnt 316)
    // before firing.
    localparam int BF_LEAD   = 10;
    localparam int BF_FSTART = HTOTAL - BF_LEAD;     // fetch-start dot (HBLANK)
    // the same lead from the end of a 416-mode line (HBLANK is 96 dots there)
    wire [8:0] bf_fstart = wide ? 9'(HTOTAL_416 - BF_LEAD) : 9'(BF_FSTART);
    // mixer q_* -> mix_rgb latency (5 cen_mix: q_* is read by the mixer's s0
    // stage one tick after capture, then s0 -> s0r -> s1 -> rgb is 4 more) and
    // the bf_col -> screen-column offset. The pen for screen column C is
    // captured at cen_mix bf_col = C+1 (bf_col leads the presented pen by one),
    // so mix_rgb for column C emerges at bf_col = C + BF_OFF. The last visible
    // column therefore needs BF_OFF extra "drain" cen_mix pulses after the
    // 320th fetch — the FSM streams to bf_col = 319 + BF_OFF for that.
    localparam int BF_MIXLAT = 5;
    localparam int BF_OFF    = BF_MIXLAT + 1;        // = 6
    typedef enum logic [1:0] { BF_IDLE, BF_SETTLE, BF_STREAM } bf_e;
    bf_e bf_st;
    wire bf_zrdy = zl_ready[0] && zl_ready[1];
    // the line whose visible period follows this HBLANK, and whether it is
    // an actual display line (0..VVIS-1) rather than a vblank line.
    wire [8:0] bf_up9   = (vcnt == 9'(VTOTAL-1)) ? 9'd0 : (vcnt + 9'd1);
    // the PCB line rendered for that raster line: itself, or 223-it under the
    // cabinet mirror (cab_vmirror, port comment). bf_up_vis stays physical.
    wire [7:0] bf_up_line = cab_vmirror ? (8'(VVIS - 1) - bf_up9[7:0])
                                        : bf_up9[7:0];
    wire       bf_up_vis  = (bf_up9 < 9'(VVIS));
    assign row_line = bf_up_line;      // stable through the whole HBLANK walk

    // ---- row-transfer arbiter. At ROW_XFER_HCNT of the line before each
    // visible line, pulse row_start to all cores (each latches its per-line
    // state and raises its walk busy), then grant the VRAM render port to
    // one walking core at a time in a fixed order (text, NBG0, NBG1, NBG2,
    // NBG3, bitmap) until every walk is done. A walk pauses (vr_ok low) for
    // a CPU palette write or a VRAM cache fill; the beam never does. The
    // walks need ~672 clk in the worst case without stalls.
    wire row_go = cen_pix && (hcnt == row_xfer_hcnt) && bf_zrdy && bf_up_vis;
    always_ff @(posedge clk) begin
        if (rst) begin
            row_start <= 1'b0; row_gnt <= '0; row_active <= 1'b0;
        end else begin
            row_start <= 1'b0;
            if (row_go) begin
                row_start  <= 1'b1;
                row_gnt    <= 6'b000001;
                row_active <= 1'b1;
            end
            else if (row_active && !row_start
                         && !(|(row_gnt & row_busy_v))) begin
                // granted core finished: advance to the next walker (the
                // one-cycle row_start guard lets the cores' busy rise first)
                if (row_gnt[5] || row_gnt == 6'd0) begin
                    row_gnt <= '0; row_active <= 1'b0;
                end else
                    row_gnt <= {row_gnt[4:0], 1'b0};
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bf_zinit <= 1'b0; bf_ls <= 1'b0; bf_pix <= 1'b0; bf_cen <= 1'b0;
            bf_col <= 9'd0; bf_line <= 8'd0; bf_st <= BF_IDLE;
        end else begin
            bf_zinit <= 1'b0; bf_ls <= 1'b0; bf_pix <= 1'b0; bf_cen <= 1'b0;
            if (cen_pix) begin
                if (vcnt == 9'(VVIS) && hcnt == 9'd0) bf_zinit <= 1'b1;
                // fetch fires in the HBLANK preceding each VISIBLE line only:
                // the upcoming line is vcnt+1 (wrapping to 0 at the last raster
                // line). Firing during the 38 vblank lines would over-advance
                // the zoom srcy DDA (one line_start per fetch).
                if (hcnt == bf_fstart && bf_zrdy && bf_up_vis) begin
                    bf_ls   <= 1'b1;
                    bf_line <= bf_up_line;
                    bf_col  <= 9'd0;
                    bf_st   <= BF_SETTLE;
                end else if (bf_st == BF_SETTLE) begin
                    bf_st <= BF_STREAM;              // one dot: first word lands
                end else if (bf_st == BF_STREAM) begin
                    bf_pix <= 1'b1;                  // advance core, present pen(bf_col)
                    bf_cen <= 1'b1;                  // mixer taps / DRAINS that pen
                    // stream the visible columns (bf_col 0..hlast, cores cap
                    // pixctr at hlast during the tail) plus BF_OFF drain
                    // pulses so the last columns flush out of the mixer
                    // pipeline.
                    if (bf_col == hlast + 9'(BF_OFF)) bf_st <= BF_IDLE;
                    else bf_col <= bf_col + 9'd1;
                end
            end
        end
    end

    // registered read stage feeding the mixer
    //
    // Every register feeding the mixer must change only on cen_mix edges,
    // so its value is stable for at least two clk periods before the
    // mixer's next capture. S32.sdc relies on this: it gives the mixer's
    // ~30 ns priority sort two periods. Loading these on any other enable
    // would leave the sort one period on the FPGA, which neither simulation
    // nor timing analysis would show. (Here cen_mix comes once per dot,
    // ~10 clk.)
    logic [8:0]  rd_x;
    logic        rd_v;
    logic        cen_mix;
    assign cen_mix = bf_cen;          // the mixer runs at the beam

    logic [12:0] q_text, q_n0, q_n1, q_n2, q_n3, q_bm;
    always_ff @(posedge clk) if (cen_mix) begin
        // the cores' settled pens for this column, clipped at clip_x;
        // rd_x/rd_v track the beam so the sprite read and px_valid follow
        // the same column
        q_text <= {2'd0, tl_pix};
        q_n0 <= nbg_draw_live[0] ? zl_pix[0] : 13'd0;
        q_n1 <= nbg_draw_live[1] ? zl_pix[1] : 13'd0;
        q_n2 <= nbg_draw_live[2] ? rl_pix[0] : 13'd0;
        q_n3 <= nbg_draw_live[3] ? rl_pix[1] : 13'd0;
        q_bm <= bm_draw_live ? bl_pix[12:0] : 13'd0;
    end
    // rd_x/rd_v/px_valid. rd_x is the sprite frame buffer read column: at
    // the cen_mix that captures the pens
    // for screen column C (bf_col = C+1) it must equal C, i.e. it is clip_x
    // held in a register. px_valid lags one cen_mix so u_mix sees a valid
    // pixel at the edge that consumes q_*.
    //
    // Two edge cases (each lost sprite pixels in columns 0 and 319):
    //  - LINE START. bf_cen fires on the edge that advances bf_col, so the
    //    first capture (column 0) sees bf_col = 1 while rd_x still holds the
    //    previous line's last drain value (325), and the read would miss
    //    the frame buffer. rd_x is loaded with 0 at bf_ls, well before the
    //    first stream dot.
    //  - DRAIN. bf_col runs to 319 + BF_OFF, and screen column 319 is
    //    taken from a drain-phase capture (see clip_x), so rd_x = 320..324
    //    would read past the line. rd_x saturates at 319, as clip_x does.
    // Both also keep spr_x (and hlast - rd_x under flip) inside the visible
    // width, which s32_board's framebuffer line fetch assumes: it prefetches
    // only the bursts of the visible columns (0..39, or 0..51 when wide) and
    // indexes fbl0/fbl1 with fbr_x[8:3]. (In the wide mode the saturation
    // limit is 415.)
    always_ff @(posedge clk) begin
        if (rst) begin rd_x <= 9'd0; rd_v <= 1'b0; px_valid <= 1'b0; end
        else begin
            if (bf_ls) rd_x <= 9'd0;
            else if (cen_mix)
                rd_x <= (bf_col > hlast) ? hlast : bf_col;
            if (cen_mix) begin
                rd_v     <= 1'b1;
                px_valid <= rd_v;
            end
        end
    end

    // sprite framebuffer scan: MAME mix-loop semantics — the latched
    // OUT flip reverses the scan direction, it does not move sprites; the
    // scan starts at the visible width's last column (cliprect.right())
    assign spr_re = rd_v;
    assign spr_x = spr_flip[0] ? (hlast - rd_x) : rd_x;
    // the sprite frame buffer line is the beam's visible line (bf_line)
    assign spr_line = spr_flip[1] ? (8'd223 - bf_line) : bf_line;

    // spr_rdata changes every clk with spr_x, so it is re-registered on
    // cen_mix to give the mixer the same two-period timing as the q_*
    // taps
    logic [15:0] spr_q;
    always_ff @(posedge clk) if (cen_mix) spr_q <= spr_rdata;

    // ------------------------------------------------------------ mixer
    logic        px_valid;
    logic        rgb_valid;
    logic [14:0] mix_rgb;
    s32_mixer u_mix (
        .clk(clk), .rst(rst), .cen(cen_mix),
        .reg_we(q_sel_mixer && cpu_we_q && cpu_addr_q[7:1] < 7'd64),
        .reg_addr(cpu_addr_q[6:1]), .reg_wdata(cpu_wdata_q),
        .reg_bsel(cpu_bsel_q),
        .r5e(vreg(8'h5E)), .lay_en(lay_en),
        // backdrop line index: under the global flip the per-line colour
        // ramp runs bottom-up (MAME master update_background, #16038: line
        // y's colour lands on row max_y - y). s32tech is silent on it.
        .px_valid(px_valid), .line(r00[9] ? (8'd223 - bf_line) : bf_line),
        // tied off: the per-line window masks a layer, it does not shade.
        // The input stays because the 315-5242 DAC has a real /SHADE pin
        // (schematic) whose driver is not known.
        .shade_win(1'b0),
        .pix_text(q_text),
        .pix_nbg0(q_n0), .pix_nbg1(q_n1),
        .pix_nbg2(q_n2), .pix_nbg3(q_n3),
        .pix_bitmap(q_bm),
        .pix_sprite(spr_q),
        .pal_re_a(), .pal_addr_a(paa), .pal_rdata_a(prda),
        .pal_re_b(), .pal_addr_b(pab), .pal_rdata_b(prdb),
        .rgb_valid(rgb_valid), .rgb(mix_rgb)
    );

    // -------------------------------------------------- line sequencer
    // none: the bf_ FSM above is the only render control, and a fetch
    // that cannot complete shows as a stale pen at that dot, never as a
    // stale whole line

    // ---------------------------------------------------------- scanout
    // the line buffer read must stay a plain synchronous read (no mux
    // between the RAM and rgb_scan), or Quartus builds it from registers
    logic [14:0] rgb_scan;
    always_ff @(posedge clk)
        if (cen_pix) begin
            de <= (hcnt < hvis) && (vcnt < 9'(VVIS));
            if (hcnt < hvis)
                rgb_scan <= bf_lbuf[hcnt[8:0]];               // by-column beam line
        end
    // Scanout line buffer: the mixer streams the line without gaps, so the
    // mix_rgb emitted while bf_col = c is screen column c - BF_OFF, and
    // bf_lbuf is indexed by that directly (rd_x would not do: it saturates
    // at 319). The FSM's drain dots write the last columns. One line in
    // MLAB, filled ahead of the beam, which reads bf_lbuf[hcnt].
    logic [8:0] bf_wx;
    logic       bf_lwe;
    assign bf_wx  = bf_col - 9'(BF_OFF);
    assign bf_lwe = cen_mix && rgb_valid && (bf_col >= 9'(BF_OFF))
                    && (bf_wx <= hlast);
    // "no_rw_check": with plain "MLAB" Quartus built this from 6,240
    // registers plus a read mux (Info 276009, unsupported read-during-write;
    // a standalone copy of these two always blocks DOES infer, so it is
    // something in the surrounding netlist, not the coding). The MLAB's
    // same-address write+read returns garbage on silicon, which no bench
    // shows (board-design.md §9.7). Here it cannot happen at all: writes
    // come on cen_mix = bf_cen, which is cen_pix delayed one clk (the BF
    // FSM above sets it under cen_pix and clears it every clk), and the read
    // register loads only on cen_pix, one clk in ~10.3 (320 wide) or 8 (416
    // wide; s32_sys acc_pix), never two in a row -- so a write and a read
    // never share a clk, whatever the addresses. Measured over a whole
    // frame in each mode (s32_video LIVE bench, Rad Mobile 320 and Burning
    // Rival 416): 0 coincidences in 323k/423k writes and 455k/573k reads,
    // writes 1-2 columns ahead of the beam. The assertion below guards it.
    // quartus_map of s32_video with release macros, 2026-10-27: MLAB, Simple
    // Dual Port, 416 deep. §9.6a.
    (* ramstyle = "MLAB, no_rw_check" *) logic [14:0] bf_lbuf [0:415];
    always_ff @(posedge clk)
        if (bf_lwe) bf_lbuf[bf_wx] <= mix_rgb;
    // 315-5296 CNT1 (TVKL) display enable: blank the output. Registered
    // after the scanout register, well away from the mixer's sort logic;
    // updated every clk, so it lags rgb_scan by one clk.
    logic [14:0] rgb_out_q;
    always_ff @(posedge clk) rgb_out_q <= disp_en ? rgb_scan : 15'd0;
    assign rgb = rgb_out_q;

endmodule
