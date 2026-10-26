// s32_board.sv — everything below the MiSTer shell: the System 32 chipset
// (s32_sys, which has plain memory ports) plus the memory system that stands
// in for the board's ROMs and RAMs: the SDRAM controller with its caches and
// the DDR3 sprite frame buffer.
//
// SDRAM byte map: 0x000000 V60 ROM (2MB), 0x200000 tile ROM (4MB),
// 0x600000 sprite ROM (16MB), 0x1800000 Z80 sound ROM (4MB), 0x1C00000 V25
// ROM (64KB). The tilemap VRAM is also kept in SDRAM (s32_vramcache).
//
// SDRAM read ports (16-byte bursts):
//   0  sprite ROM, through a one-burst cache
//   1  V60 data reads from the program ROM
//   2  unused (the sprite frame buffer is in DDR3)
//   3  tile ROM, through a one-burst cache
//   4  V60 instruction fetch
//   5  Z80 sound ROM, V25 ROM and tilemap VRAM fills
// The single-word write port carries the VRAM write-through. The burst-write
// port loads the ROM image while the core is held in reset (S32.sv drives
// it).

module s32_board (
    input  logic        clk,
    input  logic        rst_core,     // core reset (held during load)
    input  logic        rst_ctrl,     // controller/pin reset

    // ---- DDR3 port for the sprite frame buffers. The ROM loader uses DDR3
    // only while rst_core is held, so S32.sv muxes the two -- but only once
    // fbddr_quiet says the frame buffer side has finished the transaction it
    // was in when rst_core arrived (s32_fbddr header).
    input  logic        fbddr_go,
    output logic        fbddr_quiet,
    input  logic        ddr_busy,
    output logic        ddr_rd,
    output logic        ddr_we,
    output logic [28:0] ddr_addr,
    output logic [7:0]  ddr_burstcnt,
    output logic [63:0] ddr_din,
    output logic [7:0]  ddr_be,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready,

    // ---- ROM load stream (byte writes into the SDRAM map)
    input  logic        ld_wr,
    input  logic [24:0] ld_addr,
    input  logic [7:0]  ld_data,
    output logic        ld_rdy,

    // ---- video out
    output logic        de,
    output logic [14:0] rgb,
    output logic        hs,
    output logic        vs,
    output logic        ce_pix,
    output logic        vid_wide,     // 416-pixel frame (s32_video `wide`)
    output logic        hblank,
    output logic        vblank,

    // ---- audio out
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,

    // ---- inputs
    input  logic [7:0]  in_p1,
    input  logic [7:0]  in_p2,
    input  logic [7:0]  in_portc,
    input  logic [7:0]  in_service12,
    input  logic [3:0]  in_sw1_dips,
    input  logic [2:0]  in_service34,
    input  logic [7:0]  in_extra1,
    input  logic [7:0]  in_extra2,
    input  logic [7:0]  in_extra3,
    // cabinet vertical mirror (S32.sv board descriptor bit 1, Holosseum) —
    // see s32_video's cab_vmirror port
    input  logic        cab_vmirror,
    // protection V25 opcode table (S32.sv board descriptor bit 2) — see
    // s32_v25's dec_arf
    input  logic        prot_arf,
    // Burning Rival's FD1149 model (S32.sv board descriptor bit 4) — see
    // s32_v60bus
    input  logic        prot_brival,

    // ---- EEPROM image
    output logic [15:0] ee_dump_data,
    input  logic [5:0]  ee_dump_addr,
    input  logic        ee_init_wen,
    input  logic [5:0]  ee_init_addr,
    input  logic [15:0] ee_init_data,
    // Z80 work RAM save/restore (battery-backed on the real board)
    input  logic        zram_nv_sel,
    input  logic        zram_nv_we,
    input  logic [12:0] zram_nv_addr,
    input  logic [7:0]  zram_nv_wdata,
    output logic [7:0]  zram_nv_rdata,

    // ---- SDRAM pins
    output logic        sd_cke,
    output logic        sd_cs_n,
    output logic        sd_ras_n,
    output logic        sd_cas_n,
    output logic        sd_we_n,
    output logic [1:0]  sd_ba,
    output logic [12:0] sd_a,
    output logic [1:0]  sd_dqm,
    inout  wire  [15:0] sd_dq,

    output logic        unused_ok
);
    assign unused_ok = 1'b0;

    // -------------------------------------------------------- chipset
    logic        frf_req;
    logic [20:4] frf_line;
    logic [127:0] frf_data;
    logic        frf_done;
    logic        drf_req;
    logic [20:4] drf_line;
    logic [127:0] drf_data;
    logic        drf_done;
    logic        trom_re;
    logic [18:0] trom_addr;
    logic [63:0] trom_data;
    logic        trom_ack;      // tile row served (pattern streamer)
    logic        srom_re;
    logic [21:0] srom_addr;
    logic [31:0] srom_data;
    logic        fb_we, fb_bank, fb_shadow, fb_erase_w, fb_disp_bank;
    logic        fbr_re;
    logic [8:0]  fb_x, fbr_x;
    logic [7:0]  fb_y, fbr_line;
    logic [7:0]  fb_top_line;     // FB line read at raster line 0 (s32_sys)
    logic [15:0] fb_wdata, fbr_data;
    logic        cen_ren, cen_spr;

    // Tilemap VRAM client (s32_vramcache inside s32_video): fills on SDRAM
    // read port 5, write-through on the single-word write port.
    logic        vram_rf_req;   logic [24:1] vram_rf_addr;
    logic [127:0] vram_rf_data; logic        vram_rf_done;
    logic        vram_rf_cont;  logic        vram_rf_stb;
    logic        vram_rf_ack;   logic        vram_rf_urg;
    logic        vram_wr_req;   logic [24:1] vram_wr_addr;
    logic [15:0] vram_wr_data;  logic [1:0]  vram_wr_dqm;
    logic        vram_wr_done;

    s32_sys u_sys (
        .clk(clk), .rst(rst_core), .cen_ren(cen_ren),
        .cen_spr(cen_spr),
        .frf_req(frf_req), .frf_line(frf_line),
        .frf_data(frf_data), .frf_done(frf_done),
        .drf_req(drf_req), .drf_line(drf_line),
        .drf_data(drf_data), .drf_done(drf_done),
        .trom_re(trom_re), .trom_addr(trom_addr), .trom_data(trom_data),
        .trom_ack(trom_ack),
        .srom_re(srom_re), .srom_addr(srom_addr), .srom_data(srom_data),
        .zrom_addr(zc_addr), .zrom_rd(zc_rd),
        .zrom_data(zc_data), .zrom_hold(zc_hold),
        .mrom_addr(mc_addr), .mrom_rd(mc_rd),
        .mrom_data(mc_data), .mrom_hold(mc_hold),
        .fb_we(fb_we), .fb_bank(fb_bank), .fb_x(fb_x), .fb_y(fb_y),
        .fb_wdata(fb_wdata), .fb_shadow(fb_shadow),
        .fb_erase(fb_erase_w),
        .fb_disp_bank(fb_disp_bank),
        .fbr_re(fbr_re), .fbr_x(fbr_x), .fbr_line(fbr_line),
        .fbr_data(fbr_data), .fb_top_line(fb_top_line),
        .cab_vmirror(cab_vmirror), .prot_arf(prot_arf),
        .prot_brival(prot_brival),
        .de(de), .rgb(rgb), .hblank(hblank), .vblank(vblank),
        .hs(hs), .vs(vs), .ce_pix(ce_pix), .vid_wide(vid_wide),
        .audio_l(audio_l), .audio_r(audio_r),
        .in_p1(in_p1), .in_p2(in_p2), .in_portc(in_portc),
        .in_service12(in_service12), .in_sw1_dips(in_sw1_dips),
        .in_service34(in_service34),
        .in_extra1(in_extra1), .in_extra2(in_extra2),
        .in_extra3(in_extra3),
        .ee_init_wen(ee_init_wen), .ee_init_addr(ee_init_addr),
        .ee_init_data(ee_init_data),
        .ee_dump_addr(ee_dump_addr), .ee_dump_data(ee_dump_data),
        .zram_nv_sel(zram_nv_sel), .zram_nv_we(zram_nv_we),
        .zram_nv_addr(zram_nv_addr), .zram_nv_wdata(zram_nv_wdata),
        .zram_nv_rdata(zram_nv_rdata)
        , .vram_go(sdr_ready && !rst_core),
        .vram_rf_req(vram_rf_req), .vram_rf_addr(vram_rf_addr),
        .vram_rf_cont(vram_rf_cont), .vram_rf_urg(vram_rf_urg),
        .vram_rf_data(vram_rf_data), .vram_rf_done(vram_rf_done),
        .vram_rf_stb(vram_rf_stb), .vram_rf_ack(vram_rf_ack),
        .vram_wr_req(vram_wr_req), .vram_wr_addr(vram_wr_addr),
        .vram_wr_data(vram_wr_data), .vram_wr_dqm(vram_wr_dqm),
        .vram_wr_done(vram_wr_done)
    );

    // ------------------------------------------------------ controller
    logic        sdr_ready;
    logic        rreq  [0:5];
    logic [24:1] raddr [0:5];
    logic [127:0] rdata;
    logic        rdone [0:5];
    logic        rcont [0:5];
    logic        rstb  [0:5];
    logic        rack  [0:5];
    logic        rcont5_q;   // registered in the p5 owner-mux block below
    // read-chain continuation: only the VRAM fill (port 5) chains bursts
    always_comb begin
        for (int rc = 0; rc < 6; rc++) rcont[rc] = 1'b0;
        rcont[5] = rcont5_q;
    end
    logic        wreq;
    logic        wurgent;
    logic [24:1] waddr;
    logic [15:0] wdata;
    logic [1:0]  wdqm;
    logic        wdone;
    logic        wbreq;
    logic [24:1] wbaddr;
    logic [127:0] wbdata;
    logic        wbdone;

    // VRAM fill urgency (set by the port-5 owner mux below): when the
    // renderer is stalled on a VRAM fill, the fill is served right after the
    // tile-ROM and sprite-ROM deadline ports instead of waiting its turn in
    // the round-robin pool.
    logic p5_urgent;
    logic vram_pending;   // a demand fill wants the bus (experimental; tied 0 by default)
    logic vram_pf;        // port 5 holds a speculative prefetch (experimental; tied 0 by default)

    s32_sdram u_sdr (
        .clk(clk), .rst(rst_ctrl), .ready(sdr_ready),
        .rreq(rreq), .raddr(raddr), .rdata(rdata), .rdone(rdone),
        .rcont(rcont), .rstb(rstb), .rack(rack),
        .vram_urgent(p5_urgent), .vram_pending(vram_pending),
        .vram_pf(vram_pf),
        .wreq(wreq), .waddr(waddr), .wdata(wdata), .wdqm(wdqm),
        .wurgent(wurgent),
        .wdone(wdone),
        .wbreq(wbreq), .wbaddr(wbaddr), .wbdata(wbdata),
        .wbdone(wbdone),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_ba(sd_ba),
        .sd_a(sd_a), .sd_dqm(sd_dqm), .sd_dq(sd_dq)
    );

    // SDRAM byte-map bases (word addresses [24:1])
    localparam logic [24:1] B_V60  = 24'h000000;
    localparam logic [24:1] B_TILE = 24'h100000;   // byte 0x200000
    localparam logic [24:1] B_SPR  = 24'h300000;   // byte 0x600000
    localparam logic [24:1] B_FB   = 24'hB00000;   // byte 0x1600000

    // ------------------------------------------------ port adapters
    // ---- V60 ROM line caches (s32_romlc header, 2026-10-21): the fetch
    //      and data-read adapters refill from a 4 KB line cache, and only
    //      its misses reach SDRAM. The real EPROMs cost only the bus
    //      cycles v60_bcu models; an SDRAM round trip per jump does not.
    logic         frf_dn_req, frf_dn_done;
    logic [20:4]  frf_dn_line;
    s32_romlc u_frf_lc (
        .clk(clk), .rst(rst_core),
        .up_req(frf_req), .up_line(frf_line),
        .up_data(frf_data), .up_done(frf_done),
        .dn_req(frf_dn_req), .dn_line(frf_dn_line),
        .dn_data(rdata), .dn_done(frf_dn_done)
    );
    logic         drf_dn_req, drf_dn_done;
    logic [20:4]  drf_dn_line;
    s32_romlc u_drf_lc (
        .clk(clk), .rst(rst_core),
        .up_req(drf_req), .up_line(drf_line),
        .up_data(drf_data), .up_done(drf_done),
        .dn_req(drf_dn_req), .dn_line(drf_dn_line),
        .dn_data(rdata), .dn_done(drf_dn_done)
    );

    // ---- port 4: V60 instruction fetch — the fetch cache's misses
    //      (V60 ROM base is word 0)
    assign rreq[4]  = frf_dn_req;
    assign raddr[4] = {4'd0, frf_dn_line, 3'b000};
    assign frf_dn_done = rdone[4];

    // =============================================== tile ROM cache
    // One burst = 16 bytes = two 8-byte pattern rows. The served row is
    // registered per request, so a later refill cannot change a row the
    // pixel pipeline is still using.
    logic [127:0] tc_data;
    logic [17:0]  tc_tag;             // trom_addr[18:1]
    logic         tc_v;
    logic         tc_hit;
    assign tc_hit = tc_v && (tc_tag == trom_addr[18:1]);

    // The request is registered (trom_addr comes out of deep renderer logic
    // and would otherwise feed the arbiter's address mux directly) and held,
    // with its row in t_row, until the fill completes. trom_addr can jump
    // mid-fill at a line boundary; tagging the fill with the row actually
    // fetched means the data and its tag always agree, and the new row
    // simply misses and refills.
    logic        t_busy;
    logic [17:0] t_row;
    always_ff @(posedge clk) begin
        if (rst_ctrl) begin
            rreq[3] <= 1'b0;
            t_busy  <= 1'b0;
        end else if (!t_busy) begin
            rreq[3]  <= trom_re && !tc_hit;
            t_row    <= trom_addr[18:1];
            // ADD, not OR: the 4MB tile region at byte 0x200000 is not
            // naturally aligned, so OR would alias its upper half.
            raddr[3] <= B_TILE + {3'd0, trom_addr[18:1], 3'b000};
            if (trom_re && !tc_hit) t_busy <= 1'b1;
        end else if (rdone[3]) begin
            rreq[3] <= 1'b0;
            t_busy  <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst_core) tc_v <= 1'b0;
        else if (rdone[3]) begin
            tc_data <= rdata;
            tc_tag  <= t_row;             // the row actually fetched
            tc_v    <= 1'b1;
        end
    end

    // row bytes are big-endian on the port (byte j at [63-8j])
    logic [63:0] tc_row;
    always_comb
        for (int j = 0; j < 8; j++)
            tc_row[63 - 8*j -: 8] =
                tc_data[8 * ({1'b0, trom_addr[0], 3'b000} + 5'(j)) +: 8];

    // One client, the video pattern streamer, with a request/ack protocol:
    // a request is served when its row is resident, and trom_ack is
    // registered with the data so the streamer samples trom_data the cycle
    // after it sees the ack.
    always_ff @(posedge clk) begin
        if (trom_re && tc_hit) trom_data <= tc_row;
        trom_ack <= trom_re && tc_hit && !rst_core;
    end

    // ============================================ sprite ROM cache
    // one burst = four 32-bit big-endian dwords
    logic [127:0] sc_data;
    logic [19:0]  sc_tag;             // srom_addr[21:2]
    logic         sc_v;
    logic         sc_hit;
    assign sc_hit = sc_v && (sc_tag == srom_addr[21:2]);

    // held for the life of the fill like the tile pair: the sprite
    // engine's watchdog can reset a job, moving srom_addr mid-fill
    logic        s_busy;
    logic [19:0] s_row;
    always_ff @(posedge clk) begin
        if (rst_ctrl) begin
            rreq[0] <= 1'b0;
            s_busy  <= 1'b0;
        end else if (!s_busy) begin
            rreq[0]  <= srom_re && !sc_hit;
            s_row    <= srom_addr[21:2];
            // ADD, not OR: sprite ROM offsets span 16MB, overlapping
            // B_SPR's own set bits.
            raddr[0] <= B_SPR + {1'd0, srom_addr[21:2], 3'b000};
            if (srom_re && !sc_hit) s_busy <= 1'b1;
        end else if (rdone[0]) begin
            rreq[0] <= 1'b0;
            s_busy  <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst_core) sc_v <= 1'b0;
        else if (rdone[0]) begin
            sc_data <= rdata;
            sc_tag  <= s_row;             // the line actually fetched
            sc_v    <= 1'b1;
        end
    end

    logic [31:0] sc_dword;
    always_comb
        for (int j = 0; j < 4; j++)
            sc_dword[31 - 8*j -: 8] =
                sc_data[8 * ({1'b0, srom_addr[1:0], 2'b00} + 5'(j)) +: 8];

    always_ff @(posedge clk)
        if (cen_spr && srom_re) srom_data <= sc_dword;

    function automatic logic [24:1] fb_word
        (input logic bank, input logic [7:0] y, input logic [8:0] x);
        fb_word = B_FB | {6'd0, bank, y, x};
    endfunction

    // ================================= sprite frame buffer in DDR3
    logic         fbddr_wok;
    logic         fbddr_req, fbddr_bank, fbddr_stb, fbddr_done;
    logic [7:0]   fbddr_line;
    logic [5:0]   fbddr_idx;
    logic [127:0] fbddr_data;

    // (instance below, after cen_spr's terms exist)

    // ========================================= frame buffer line cache
    // Two line buffers, so a whole line is ready before the beam reaches it
    // (a refill takes ~400 clk; the beam needs the line's first pixel within
    // ~100). While one buffer serves line N, the other prefetches the
    // predicted next line (following the last scan direction, so a
    // vertically flipped scan works too). A frame flip invalidates both;
    // a cold start or a misprediction falls back to a reactive fill. A fill's
    // line and bank are latched when it starts, so a completed fill is
    // always tagged with what it fetched. A miss repeats the last pixels
    // rather than stalling the beam. One 128-bit word = 8 pixels.
    (* ramstyle = "MLAB" *) logic [127:0] fbl0 [0:63];
    (* ramstyle = "MLAB" *) logic [127:0] fbl1 [0:63];
    logic [7:0]  fbl_line [0:1];
    logic        fbl_bank [0:1];
    logic        fbl_vv   [0:1];

    logic        fbs_sel, fbs_hit;
    always_comb begin
        fbs_sel = 1'b0; fbs_hit = 1'b0;
        if (fbl_vv[0] && fbl_line[0] == fbr_line
            && fbl_bank[0] == fb_disp_bank) begin
            fbs_sel = 1'b0; fbs_hit = 1'b1;
        end else if (fbl_vv[1] && fbl_line[1] == fbr_line
                     && fbl_bank[1] == fb_disp_bank) begin
            fbs_sel = 1'b1; fbs_hit = 1'b1;
        end
    end
    wire fbl_hit = fbs_hit;

    typedef enum logic [0:0] { PF_IDLE, PF_RUN } pf_e;
    pf_e   pf;
    logic [5:0] pf_burst;             // 40 bursts x 8 words = 320 px
    // 52 bursts (416 px) in the wide mode; vid_wide changes only in vblank
    wire  [5:0] pf_last = vid_wide ? 6'd51 : 6'd39;
    logic       pf_bsel;              // bank being filled
    logic [7:0] pf_line_t;            // fill target line (latched)
    logic       pf_dbank_t;           // fill target display bank (latched)

    // prediction: next line = fbr_line ± 1 (direction = last observed
    // step, wrap taken as its flip-consistent direction)
    logic [7:0] fbr_line_q;
    logic       fbr_dir_dn;
    logic       disp_bank_q;
    wire [7:0] pred_line = fbr_dir_dn
        ? (fbr_line == 8'd0   ? 8'd223 : fbr_line - 8'd1)
        : (fbr_line == 8'd223 ? 8'd0   : fbr_line + 8'd1);
    wire pred_res =
          (fbl_vv[0] && fbl_line[0] == pred_line
           && fbl_bank[0] == fb_disp_bank)
       || (fbl_vv[1] && fbl_line[1] == pred_line
           && fbl_bank[1] == fb_disp_bank);
    wire pf_victim = !fbl_vv[0] ? 1'b0
                   : !fbl_vv[1] ? 1'b1 : 1'b0;   // reactive: spare a valid
    wire pf_nsrv  = ~fbs_sel;                    // the non-serving bank

    // The line comes from DDR3, so SDRAM port 2 is unused (which frees about
    // 12% of SDRAM time per frame).
    assign rreq[2]  = 1'b0;
    assign raddr[2] = 24'd0;
    assign fbddr_req  = (pf == PF_RUN);
    assign fbddr_line = pf_line_t;
    assign fbddr_bank = pf_dbank_t;

    always_ff @(posedge clk) begin
        if (rst_core) begin
            pf <= PF_IDLE;
            fbl_vv[0] <= 1'b0; fbl_vv[1] <= 1'b0;
            fbr_line_q <= 8'd0; fbr_dir_dn <= 1'b0;
            disp_bank_q <= 1'b0;
        end else begin
            if (fbr_line != fbr_line_q) begin
                fbr_line_q <= fbr_line;
                fbr_dir_dn <=
                    (fbr_line == 8'd223 && fbr_line_q == 8'd0) ? 1'b1
                  : (fbr_line == 8'd0 && fbr_line_q == 8'd223) ? 1'b0
                  : (fbr_line < fbr_line_q);
            end
            disp_bank_q <= fb_disp_bank;
            if (fb_disp_bank != disp_bank_q) begin
                fbl_vv[0] <= 1'b0;    // frame flip: both banks stale
                fbl_vv[1] <= 1'b0;
            end
            unique case (pf)
                PF_IDLE:
                    if (!fbs_hit) begin           // reactive (cold/mispredict)
                        pf_bsel   <= pf_victim;
                        pf_line_t <= fbr_line;
                        pf_dbank_t<= fb_disp_bank;
                        pf_burst  <= 6'd0;
                        fbl_vv[pf_victim] <= 1'b0;
                        pf <= PF_RUN;
                    end else if (!pred_res
                                ) begin           // predictive full-line lead
                        pf_bsel   <= pf_nsrv;
                        pf_line_t <= pred_line;
                        pf_dbank_t<= fb_disp_bank;
                        pf_burst  <= 6'd0;
                        fbl_vv[pf_nsrv] <= 1'b0;
                        pf <= PF_RUN;
                    end
                PF_RUN:
                    if (fbddr_done) begin
                        fbl_line[pf_bsel] <= pf_line_t;
                        fbl_bank[pf_bsel] <= pf_dbank_t;
                        fbl_vv[pf_bsel]   <= 1'b1;
                        pf <= PF_IDLE;
                    end
                default: pf <= PF_IDLE;
            endcase
        end
    end

    // one always block per array, or Quartus 17 builds both from registers
    always_ff @(posedge clk)
        if (fbddr_stb && !pf_bsel) fbl0[fbddr_idx] <= fbddr_data;
    always_ff @(posedge clk)
        if (fbddr_stb &&  pf_bsel) fbl1[fbddr_idx] <= fbddr_data;

    // Serve side: both buffers are read into registers and muxed AFTER the
    // registered read; a mux inside the read expression makes Quartus 17
    // build both arrays from registers. A fill always writes the buffer the
    // beam is not reading, so a read and a write never meet at one address.
    logic [127:0] fbl_q0, fbl_q1;
    logic         fbs_sel_q;
    logic [2:0]   fbr_xl_q;
    always_ff @(posedge clk)
        if (fbr_re && fbs_hit) begin
            fbl_q0    <= fbl0[fbr_x[8:3]];
            fbl_q1    <= fbl1[fbr_x[8:3]];
            fbs_sel_q <= fbs_sel;
            fbr_xl_q  <= fbr_x[2:0];
        end
    wire [127:0] fbl_q = fbs_sel_q ? fbl_q1 : fbl_q0;
    // ---- Top-line buffer, written through by the sprite engine.
    //
    // The frame flip lands 1-2 clk before the first line is served, too late
    // for any fetch, and the two-entry cache above cannot keep a top line
    // fetched during vblank. So the first line the beam reads is kept in its
    // own buffer, written by the engine's own writes: it always mirrors that
    // line of both banks and is correct at the instant of the flip.
    //
    // "Top line" is fb_top_line: FB line 0, or line 223 when the scan runs
    // bottom-up (sprite output V-flip XOR the cabinet mirror; Holosseum sets
    // the V-flip). 1024 x 16 bits = 2 M10K, addressed {bank, x}. If
    // fb_top_line changes, one frame is served from the old line's copy.
    //
    // A shadow write (fb_shadow) carries no data: it clears bit 15 of the
    // stored word (MAME render_one_sprite `dest &= 0x7fff`; s32_fbddr does it
    // by read-modify-write). The copy keeps that as a 1-bit flag beside the
    // word, set by a shadow write and cleared by a pixel write, and applied
    // on the read. (It used to store the shadow write's don't-care data:
    // Burning Rival's floor shadows on line 0 then showed sprite colours,
    // board bench FBSTALE line0 = 948 at frame 729.)
    (* ramstyle = "M10K" *) logic [15:0] l0buf [0:1023];
    (* ramstyle = "M10K" *) logic        l0sh  [0:1023];
    always_ff @(posedge clk)
        if (fb_we && !fb_shadow && fb_y == fb_top_line)
            l0buf[{fb_bank, fb_x}] <= fb_wdata;
    always_ff @(posedge clk)
        if (fb_we && fb_y == fb_top_line) l0sh[{fb_bank, fb_x}] <= fb_shadow;

    // Registered on fbr_re alone, not on a cache hit: this path cannot miss.
    // l0_sel_q rides the same stage so the select stays aligned with the data.
    logic [15:0] l0q;
    logic        l0shq;
    logic        l0_sel_q;
    always_ff @(posedge clk)
        if (fbr_re) begin
            l0q      <= l0buf[{fb_disp_bank, fbr_x}];
            l0_sel_q <= (fbr_line == fb_top_line);
        end
    always_ff @(posedge clk)
        if (fbr_re) l0shq <= l0sh[{fb_disp_bank, fbr_x}];
    wire [15:0] l0_word = {l0q[15] & ~l0shq, l0q[14:0]};
    assign fbr_data = l0_sel_q ? l0_word : fbl_q[16 * fbr_xl_q +: 16];

    // ============================== frame buffer write path in SDRAM
    // Used only when the frame buffer is kept in SDRAM; with the DDR3 frame
    // buffer (s32_fbddr) nothing is fed in, so fwq stays empty and dr idle.
    //
    // Writes are posted through a 16-deep in-order FIFO so the sprite engine
    // does not wait an arbiter round-trip per pixel (the real 315-5386 has a
    // dedicated frame buffer). Erase writes are gathered into full 8-word
    // bursts. Erase and render writes never interleave, and shadow
    // read-modify-writes leave the FIFO in order, so a shadow read can never
    // pass a queued write to the same word. No per-beat DQM masking: on this
    // board DQM misses the chip's sampling edge (see s32_sdram.sv).
    typedef enum logic [1:0] { DR_IDLE, DR_WR, DR_RMW_RD, DR_RMW_WR } dr_e;
    dr_e dr;

    // accept side: erase line collector
    logic [127:0] er_buf;
    logic [2:0]   er_cnt;
    logic [24:1]  er_base;
    // posted erase burst slot
    logic [127:0] erq_data;
    logic [24:1]  erq_base;
    logic         erq_v;

    // write FIFO: {shadow, word addr, data}
    localparam FWQ_AW = 4;                       // 16 deep
    logic [40:0] fwq [0:(1<<FWQ_AW)-1];
    logic [FWQ_AW:0] fwq_wp, fwq_rp;
    logic [FWQ_AW:0] fwq_used;
    logic fwq_full, fwq_empty;
    assign fwq_used  = fwq_wp - fwq_rp;
    assign fwq_full  = fwq_used[FWQ_AW];
    assign fwq_empty = (fwq_wp == fwq_rp);

    // Once 12 of 16 entries are used, the drain is urgent until only four
    // remain. s32_sdram caps a same-row chain at eight writes and keeps the
    // tile/sprite-ROM reads above it, so urgency cannot hog the SDRAM.
    always_ff @(posedge clk) begin
        if (rst_core) wurgent <= 1'b0;
        else if (fwq_used >= 5'd12) wurgent <= 1'b1;
        else if (fwq_used <= 5'd4)  wurgent <= 1'b0;
    end

    // drain-side working regs
    logic [24:1] dr_addr;
    logic [15:0] dr_data;

    // the engine stalls ONLY on backpressure: render write into a
    // full FIFO, an erase line completing while the previous erase
    // burst is still posted, or the FIRST erase pixel while queued
    // render writes are still draining (boundary order: a leftover
    // render write to line L must land BEFORE the erase burst that
    // clears L — see the pop-hold below for the reverse direction).
    // er_cnt==0 fires per 8-px group but the FIFO is empty mid-sweep,
    // so the boundary check costs nothing after the first line.
    logic fbw_ok;
    // DDR3 frame buffer: backpressure comes from s32_fbddr, and the SDRAM
    // write path below is never fed.
    assign fbw_ok = fbddr_wok;

    // ---- accept: never blocks the engine except via fbw_ok above
    always_ff @(posedge clk) begin
        if (rst_core) begin
            er_cnt <= 3'd0;
            erq_v  <= 1'b0;
            fwq_wp <= '0;
        end else begin
            if (1'b0) begin                 // FB writes go to DDR3
                if (fb_erase_w) begin
                    er_buf[16*er_cnt +: 16] <= fb_wdata;
                    if (er_cnt == 3'd0)
                        er_base <= fb_word(fb_bank, fb_y, fb_x);
                    if (er_cnt == 3'd7) begin
                        // post the completed line (fbw_ok guaranteed
                        // erq_v clear on this cycle)
                        erq_data <= {fb_wdata, er_buf[111:0]};
                        erq_base <= er_base;
                        erq_v    <= 1'b1;
                        er_cnt   <= 3'd0;
                    end else
                        er_cnt <= er_cnt + 3'd1;
                end else begin
                    fwq[fwq_wp[FWQ_AW-1:0]] <=
                        {fb_shadow, fb_word(fb_bank, fb_y, fb_x), fb_wdata};
                    fwq_wp <= fwq_wp + 1'b1;
                end
            end
            // (this branch only runs with rst_core low, so the burst
            // port's wbdone here is always the erase slot's own — the
            // loader owns the port exclusively during held reset)
            if (erq_v && wbdone)
                erq_v <= 1'b0;
        end
    end

    // ---- drain: pops in order; RMW blocks only the DRAIN, not the
    // engine (order vs queued writes is preserved by the FIFO). Pops
    // hold while an erase burst is posted so the burst lands before
    // any subsequent render write (erase and render writes never
    // interleave — the hold only acts at the phase boundary).
    logic        drq_shadow;
    logic [24:1] drq_addr;
    logic [15:0] drq_data;
    assign {drq_shadow, drq_addr, drq_data} = fwq[fwq_rp[FWQ_AW-1:0]];

    // Single-write-port owner flag (set in the owner mux below), declared
    // here so the drain only consumes its OWN wdone: a VRAM write-through
    // can hold the port while dr waits in DR_WR.
    logic vram_w_own;

    always_ff @(posedge clk) begin
        if (rst_core) begin
            dr <= DR_IDLE;
            fwq_rp <= '0;
        end else begin
            unique case (dr)
                DR_IDLE:
                    if (!fwq_empty && !erq_v) begin
                        dr_addr <= drq_addr;
                        dr_data <= drq_data;
                        fwq_rp  <= fwq_rp + 1'b1;
                        dr <= drq_shadow ? DR_RMW_RD : DR_WR;
                    end

                DR_WR:
                    if (wdone
                        // only our own completion (see vram_w_own)
                        && !vram_w_own
                       ) begin
                        // pop the next plain write without dropping
                        // wreq, so the controller chains it onto the
                        // open row (one FB line = one SDRAM row). Shadow
                        // RMWs and the erase boundary go through DR_IDLE,
                        // which closes the row first.
                        if (!fwq_empty && !erq_v && !drq_shadow) begin
                            dr_addr <= drq_addr;
                            dr_data <= drq_data;
                            fwq_rp  <= fwq_rp + 1'b1;
                        end else
                            dr <= DR_IDLE;
                    end

                DR_RMW_RD:
                    if (rdone[1] && p1_owner == 2'd1) begin
                        // extract the word, clear bit 15, write back
                        dr_data <= rdata[16 * dr_addr[3:1] +: 16]
                                   & 16'h7FFF;
                        dr <= DR_RMW_WR;
                    end

                DR_RMW_WR:
                    if (wdone
                        && !vram_w_own
                       ) dr <= DR_IDLE;

                default: dr <= DR_IDLE;
            endcase
        end
    end

    // port 1 is shared between the FB shadow-RMW reads and the V60
    // data-line client. A grant OWNER register keeps request, data
    // and done attribution unambiguous (RMW has priority when both
    // arrive; the loser's level request simply waits).
    logic [1:0] p1_owner;             // 0 none, 1 rmw, 2 data
    logic       p1_rmw_want;
    assign p1_rmw_want = (dr == DR_RMW_RD);

    always_ff @(posedge clk) begin
        if (rst_ctrl)
            p1_owner <= 2'd0;
        else if (p1_owner == 2'd0) begin
            if (p1_rmw_want)   p1_owner <= 2'd1;
            // Port 1 is pure V60 (rmw/drf). The VRAM fill client lives on
            // the near-idle port 5 (see the p5_owner mux below): on port 1
            // it would wait out the V60's in-flight, NON-PREEMPTIBLE
            // transaction before it could even bid.
            else if (drf_dn_req)  p1_owner <= 2'd2;
        end else if (rdone[1])
            p1_owner <= 2'd0;
    end

    // pick()'s urgent slot is driven by the port-5 fill owner (below).
    // Nothing on port 1 is ever "urgent".

    // registered like the tile/sprite pairs: the owner mux fed the
    // arbiter's g_addr capture directly (fit-stage path)
    always_ff @(posedge clk) begin
        rreq[1]  <= ((p1_owner == 2'd1) ? 1'b1
                   : (p1_owner == 2'd2) ? drf_dn_req
                   : 1'b0) && !rst_ctrl;
        raddr[1] <= (p1_owner == 2'd1) ? {dr_addr[24:4], 3'b000}
                                       : {4'd0, drf_dn_line, 3'b000};
    end
    assign drf_dn_done = rdone[1] && (p1_owner == 2'd2);
    assign vram_rf_data = rdata;   // shared read bus, port-independent

    // ============================================ ROM load + wb mux
    // during held core reset the loader owns the burst-write port;
    // afterwards it belongs to the erase path. The load stream is
    // byte-sequential and every region is 16-byte aligned, so lines
    // always fill completely.
    logic [127:0] ld_buf;
    logic [24:4]  ld_line;
    logic [3:0]   ld_fill;
    logic         ld_flush;

    always_ff @(posedge clk) begin
        if (rst_ctrl) begin
            ld_fill <= 4'd0;
            ld_flush <= 1'b0;
        end else begin
            if (ld_wr && !ld_flush) begin
                ld_buf[8 * ld_addr[3:0] +: 8] <= ld_data;
                ld_line <= ld_addr[24:4];
                if (ld_addr[3:0] == 4'hF) ld_flush <= 1'b1;
            end
            if (ld_flush && wbdone) ld_flush <= 1'b0;
        end
    end
    assign ld_rdy = sdr_ready && !ld_flush;

    // wb port mux
    assign wbreq  = rst_core ? ld_flush : erq_v;
    assign wbaddr = rst_core ? {ld_line, 3'b000} : erq_base;
    assign wbdata = rst_core ? ld_buf : erq_data;

    // single-write port: engine pixels + RMW writeback, and the VRAM
    // write-through as the lowest-priority owner.
    wire        other_w = (dr == DR_WR) || (dr == DR_RMW_WR);
    always_ff @(posedge clk) begin
        if (rst_ctrl)                                    vram_w_own <= 1'b0;
        else if (vram_w_own && wdone)                    vram_w_own <= 1'b0;
        else if (!vram_w_own && vram_wr_req && !other_w) vram_w_own <= 1'b1;
    end
    assign wreq  = other_w || (vram_w_own && vram_wr_req);
    assign waddr = vram_w_own ? vram_wr_addr : dr_addr;
    assign wdata = vram_w_own ? vram_wr_data : dr_data;
    assign wdqm  = vram_w_own ? vram_wr_dqm  : 2'b00;
    assign vram_wr_done = wdone && vram_w_own;

    // ================================================= freeze fabric
    logic trom_ok, srom_ok, fbl_ok;
    assign trom_ok = !(trom_re && !tc_hit);
    assign srom_ok = !(srom_re && !sc_hit);
    assign fbl_ok  = !(fbr_re && !fbl_hit);

    // The live pipeline renders from buffers filled ahead of the beam: the
    // pattern streamer waits on trom_ack and the frame buffer line is always
    // resident, so cen_ren only waits for the SDRAM to be ready.
    assign cen_ren = sdr_ready && !rst_core;
    assign cen_spr = srom_ok && fbw_ok && sdr_ready && !rst_core;

    s32_fbddr u_fbddr (
        .clk(clk), .rst(rst_core), .go(fbddr_go),
        .fb_we(fb_we), .cen_ok(srom_ok && sdr_ready && !rst_core),
        .fb_bank(fb_bank),
        .fb_x(fb_x), .fb_y(fb_y), .fb_wdata(fb_wdata),
        .fb_shadow(fb_shadow), .fbw_ok(fbddr_wok),
        .rf_req(fbddr_req), .rf_line(fbddr_line), .rf_bank(fbddr_bank),
        .rf_wide(vid_wide),
        .rf_stb(fbddr_stb), .rf_idx(fbddr_idx), .rf_data(fbddr_data),
        .rf_done(fbddr_done),
        .ddr_busy(ddr_busy), .ddr_rd(ddr_rd), .ddr_we(ddr_we),
        .ddr_addr(ddr_addr), .ddr_burstcnt(ddr_burstcnt),
        .ddr_din(ddr_din), .ddr_be(ddr_be),
        .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready),
        .quiet(fbddr_quiet)
    );

    // ---- Z80 sound-ROM cache, on SDRAM read port 5. zc_hold stalls only
    // the Z80 (inside s32_sys).
    logic [21:0]  zc_addr;
    logic         zc_rd;
    logic [7:0]   zc_data;
    logic         zc_hold;

    logic zc_req, mc_req;
    logic [24:1] zc_rfa, mc_rfa;
    logic zc_done, mc_done;

    s32_zromcache u_zc (
        .clk(clk), .rst(rst_core),
        .go(sdr_ready && !rst_core),
        .zaddr(zc_addr), .zrd(zc_rd),
        .zdata(zc_data), .zhold(zc_hold),
        .rf_req(zc_req), .rf_addr(zc_rfa),
        .rf_data(rdata), .rf_done(zc_done)
    );

    // ---- V25 MCU ROM cache: shares port 5 with the Z80 cache via a
    // grant-owner register (same pattern as p1_owner; Z80 priority)
    logic [15:0]  mc_addr;
    logic         mc_rd;
    logic [7:0]   mc_data;
    logic         mc_hold;

    s32_mromcache u_mc (
        .clk(clk), .rst(rst_core),
        .maddr(mc_addr), .mrd(mc_rd),
        .mdata(mc_data), .mhold(mc_hold),
        .rf_req(mc_req), .rf_addr(mc_rfa),
        .rf_data(rdata), .rf_done(mc_done)
    );

    // SDRAM read port 5: the Z80 sound-ROM cache, the V25 ROM cache and
    // the VRAM fill. Both CPU caches take the port first: real
    // hardware gives both CPUs dedicated zero-wait ROMs, so any starvation
    // here is an accuracy deviation. Once the VRAM fill owns the port it
    // bids at high priority in pick() via p5_urgent.
    logic [2:0] p5_owner;             // 0 none, 1 z80, 2 v25, 4 VRAM fill
    always_ff @(posedge clk) begin
        if (rst_ctrl)
            p5_owner <= 3'd0;
        else if (p5_owner == 3'd0) begin
            if (zc_req)              p5_owner <= 3'd1;
            else if (mc_req)         p5_owner <= 3'd2;
            else if (vram_rf_req)    p5_owner <= 3'd4;
        end else if (rdone[5])
            p5_owner <= 3'd0;
    end

    always_ff @(posedge clk) begin    // registered like the p1 pair
        rreq[5]  <= ((p5_owner == 3'd1) ? zc_req
                   : (p5_owner == 3'd2) ? mc_req
                   : (p5_owner == 3'd4) ? vram_rf_req
                   : 1'b0) && !rst_ctrl;
        raddr[5] <=
                    (p5_owner == 3'd4) ? vram_rf_addr :
                    (p5_owner == 3'd2) ? mc_rfa : zc_rfa;
        // chain-continue only for the VRAM fill owner (the sole chaining
        // client); registered like raddr so it is stable at the grant.
        rcont5_q <= (p5_owner == 3'd4) && vram_rf_cont && !rst_ctrl;
    end
    assign zc_done  = rdone[5] && (p5_owner == 3'd1);
    assign mc_done  = rdone[5] && (p5_owner == 3'd2);
    // VRAM fill completion + chain beat/ack ride port 5 (owner 4).
    assign vram_rf_done = rdone[5] && (p5_owner == 3'd4);
    assign vram_rf_stb  = rstb[5]  && (p5_owner == 3'd4);
    assign vram_rf_ack  = rack[5]  && (p5_owner == 3'd4);
    // pick()'s urgent slot: the fill owns port 5 and is walk-stalled.
    assign p5_urgent    = (p5_owner == 3'd4) && vram_rf_urg;
    assign vram_pf      = 1'b0;
    assign vram_pending = 1'b0;

endmodule
