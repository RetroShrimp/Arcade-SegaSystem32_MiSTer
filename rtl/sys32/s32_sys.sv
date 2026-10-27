// s32_sys.sv — the System 32 chipset: CPUs, custom chips, I/O and sound
// wired together, with plain memory ports for the ROMs and the sprite frame
// buffer (s32_board connects those to SDRAM and DDR3).
//
// Clocking: one clk (64.4318 MHz = 2x the 32.2159 MHz board crystal) with
// clock enables: cen16 = clk/4 = 16.108 MHz exactly (V60 and its bus unit),
// cen_z80 = clk/8 = 8.054 MHz exactly (Z80 and both YM3438s), and
// fractional accumulators for the 50 MHz crystal's family: cen_pcm ~12.5
// MHz, cen_pix ~6.25 MHz, and the V25 at 10 MHz. Running everything in one
// clock keeps the order of events between the chips deterministic.

module s32_sys (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_ren,      // video render enable (memory ready)
    input  logic        cen_spr,      // sprite engine enable (memory ready)

    // ---- V60 program ROM: instruction fetch line port (16 bytes
    //      per request/done — the SDRAM burst-read shape)
    output logic        frf_req,
    output logic [20:4] frf_line,
    input  logic [127:0] frf_data,
    input  logic        frf_done,
    //      data-side read line port (same shape)
    output logic        drf_req,
    output logic [20:4] drf_line,
    input  logic [127:0] drf_data,
    input  logic        drf_done,

    // ---- tile ROM (request/ack: the video pattern streamer holds trom_re
    // until trom_ack)
    output logic        trom_re,
    output logic [18:0] trom_addr,
    input  logic [63:0] trom_data,
    input  logic        trom_ack,

    // ---- sprite ROM (1-cycle)
    output logic        srom_re,
    output logic [21:0] srom_addr,
    input  logic [31:0] srom_data,

    // ---- sound ROM (data valid by the next cen_z80 pulse; on a cache miss
    // the board raises zrom_hold, which stalls only the Z80 while FM and PCM
    // keep playing, like a wait state)
    output logic [21:0] zrom_addr,
    output logic        zrom_rd,
    input  logic [7:0]  zrom_data,
    input  logic        zrom_hold,

    // ---- V25 MCU ROM (1-cycle contract on hits; the board holds
    // mrom_hold on a cache miss, freezing the V25's FSM)
    output logic [15:0] mrom_addr,
    output logic        mrom_rd,
    input  logic [7:0]  mrom_data,
    input  logic        mrom_hold,

    // ---- sprite frame buffer (external: DDR3 via s32_board)
    output logic        fb_we,
    output logic        fb_bank,
    output logic [8:0]  fb_x,
    output logic [7:0]  fb_y,
    output logic [15:0] fb_wdata,
    output logic        fb_shadow,
    output logic        fb_erase,
    output logic        fb_disp_bank,
    output logic        fbr_re,
    output logic [8:0]  fbr_x,
    output logic [7:0]  fbr_line,
    input  logic [15:0] fbr_data,
    // the FB line the beam reads first each frame: 223 when the scan runs
    // bottom-up (sprite output V-flip XOR the cabinet mirror), else 0.
    // s32_board's top-line buffer keys on it.
    output logic [7:0]  fb_top_line,

    // ---- cabinet vertical mirror (from the .mra, not a board signal; see
    // s32_video). 1 only for Holosseum.
    input  logic        cab_vmirror,
    // ---- protection V25 opcode table (from the .mra's board descriptor
    // bit 2): 0 = ga2's, 1 = Arabian Fight's. See s32_v25's dec_arf.
    input  logic        prot_arf,
    // ---- Burning Rival's FD1149 protection model (board descriptor bit 4).
    // See s32_v60bus's "FD1149 flag words".
    input  logic        prot_brival,
    // ---- Dark Edge's FD1149 protection model (board descriptor bit 5).
    // See s32_v60bus's "FD1149 vblank writes".
    input  logic        prot_darkedge,
    // ---- SegaSonic's 837-8685 trackball I/O board (board descriptor bit
    // 6): three uPD4701A counters at $C00040/48/50 (s32_upd4701). trk_stb[n]
    // adds the signed 12-bit steps trk_dx/dy[12n +: 12] to counter n.
    input  logic        trk_board,
    input  logic [2:0]  trk_stb,
    input  logic [35:0] trk_dx,
    input  logic [35:0] trk_dy,
    // ---- SegaSonic's FD1149 protection model (board descriptor bit 7).
    // See s32_v60bus's "FD1149 level load".
    input  logic        prot_sonic,

    // ---- video out
    output logic        de,
    output logic [14:0] rgb,
    output logic        hblank,
    output logic        vblank,
    output logic        hs,
    output logic        vs,
    output logic        ce_pix,       // cen_pix export for the shell
    output logic        vid_wide,     // 416-pixel frame (s32_video `wide`)

    // ---- audio out
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,

    // ---- inputs (active-low idle FF)
    input  logic [7:0]  in_p1,        // io chip port A
    input  logic [7:0]  in_p2,        // port B
    input  logic [7:0]  in_portc,     // port C
    input  logic [7:0]  in_service12, // port E
    input  logic [3:0]  in_sw1_dips,  // port F low nibble
    input  logic [2:0]  in_service34, // port F bits 4-6
    input  logic [7:0]  in_extra1,    // PPI port A
    input  logic [7:0]  in_extra2,    // PPI port B
    input  logic [7:0]  in_extra3,    // PPI port C

    // ---- EEPROM image preload (HPS)
    output logic [15:0] ee_dump_data,
    input  logic [5:0]  ee_dump_addr,
    input  logic        ee_init_wen,
    input  logic [5:0]  ee_init_addr,
    input  logic [15:0] ee_init_data,

    // Z80 work RAM save/restore port (the battery-backed RAM; S32.sv maps
    // it into the NVRAM file after the EEPROM)
    input  logic        zram_nv_sel,
    input  logic        zram_nv_we,
    input  logic [12:0] zram_nv_addr,
    input  logic [7:0]  zram_nv_wdata,
    output logic [7:0]  zram_nv_rdata
    // tilemap VRAM kept in SDRAM (s32_vramcache inside s32_video); s32_board
    // puts it on an SDRAM read port and the write port
    , input  logic        vram_go,
    output logic         vram_rf_req,
    output logic         vram_rf_urg,   // render-demand fill (walk stalled)
    output logic [24:1]  vram_rf_addr,
    output logic         vram_rf_cont,
    input  logic [127:0] vram_rf_data,
    input  logic         vram_rf_done,
    input  logic         vram_rf_stb,
    input  logic         vram_rf_ack,
    output logic         vram_wr_req,
    output logic [24:1]  vram_wr_addr,
    output logic [15:0]  vram_wr_data,
    output logic [1:0]   vram_wr_dqm,
    input  logic         vram_wr_done
);

    // -------------------------------------------------------- cen gen
    logic [2:0] div8;
    logic       cen_z80;
    always_ff @(posedge clk) begin
        div8 <= div8 + 3'd1;
        cen_z80 <= (div8 == 3'd7);
    end

    // fractional enables: target/clk ratios in 1/65536 steps
    // 12.5/64.4318 = 0.19401 -> 12715 ; 6.25/64.4318 = 0.09700 -> 6357
    // The 416-pixel mode's dot is the 315-5387's 8.053975 MHz (32.2159 MHz
    // / 4, s32tech / segas32_v.cpp), exactly clk / 8 -> 8192. s32_video
    // switches `wide` once per frame, in vblank.
    logic [16:0] acc_pcm, acc_pix;
    logic        cen_pcm, cen_pix;
    always_ff @(posedge clk) begin
        acc_pcm <= {1'b0, acc_pcm[15:0]} + 17'd12715;
        cen_pcm <= acc_pcm[16];
        acc_pix <= {1'b0, acc_pix[15:0]} + (vid_wide ? 17'd8192 : 17'd6357);
        cen_pix <= acc_pix[16];
        ce_pix <= acc_pix[16];
    end

    // ------------------------------------------------------------ V60
    logic [31:0]  fetch_pc;
    logic [111:0] v_fetch_bytes;
    logic         mem_re, mem_we;
    logic [31:0]  mem_addr, mem_wdata;
    logic [2:0]   mem_size;
    logic [31:0]  mem_rdata;
    logic         trap;
    logic [7:0]   trap_op;
    logic         irq;
    logic [2:0]   irq_vector;
    logic         bus_hold;
    logic         fetch_hold;
    // The core's mem_* transactions go to the bus unit (v60_bcu.sv); the
    // rest of the machine sees the real part's 16-bit T1-T3 bus cycles on
    // the b60_* wires.
    logic         bcu_busy;
    logic         bcu_pend;      // bus unit has a strobe queued (FD1149 model)
    logic         b60_re, b60_we;
    logic [31:0]  b60_addr, b60_wdata, b60_rdata;
    logic [2:0]   b60_size;

    // Prefetch queue (v60_pfu): follows fetch_pc, presents a 14-byte
    // window plus fq_count, and fills through 16-bit fetch bus cycles in the
    // bus unit, so instruction fetch costs bus time as on the real CPU.
    // Fetch cycles (marked by f_fetch) read the program ROM through their own
    // prefetching adapter (u_fetch, SDRAM port 4); data reads from ROM use a
    // second one (u_dfetch, port 1), so a busy SDRAM cannot delay fetch.
    logic        pf_req, pf_grant, pf_done;
    logic [23:0] pf_addr;
    logic [15:0] pf_rdata;
    logic [4:0]  fq_count;
    logic        b60_fetch;
    v60_pfu u_pfu (
        .clk(clk), .rst(rst),
        .pc(fetch_pc[23:0]), .window(v_fetch_bytes), .fq_count(fq_count),
        .pf_req(pf_req), .pf_addr(pf_addr), .pf_grant(pf_grant),
        .pf_rdata(pf_rdata), .pf_done(pf_done)
    );
    // Length decode on the presented window: the core proceeds (fetch_hold
    // low) only once the queue holds the whole instruction. A length decoded
    // from a partly filled window is still valid if it fits in fq_count,
    // because then every byte it looked at was valid. Unknown encodings
    // fall through to the core's own trap.
    logic [5:0] live_len;
    v60_ldec u_flen (
        .bytes_in(v_fetch_bytes), .length(live_len),
        .ftype(), .opsize1(), .opsize2(),
        .am1_len(), .am2_len(), .valid()
    );
    assign fetch_hold = ({1'b0, fq_count} < live_len);

    // Fetch ROM adapter: the bus fabric drives romf_pc and reads back the
    // prefetched window. Its two-line background prefetch keeps fetch a cache
    // hit, so a fetch bus cycle costs about what a work-RAM read does.
    logic [23:0]  romf_pc;
    logic [111:0] romf_bytes;
    logic         romf_hold;
    s32_v60fetch u_fetch (
        .clk(clk), .rst(rst),
        .fetch_pc(romf_pc), .fetch_bytes(romf_bytes),
        .fetch_hold(romf_hold),
        .rf_req(frf_req), .rf_line(frf_line), .rf_data(frf_data),
        .rf_done(frf_done)
    );

    // data-side ROM adapter: same module, driven by the bus fabric's ROM
    // read path
    logic [23:0]  romd_pc;
    logic [111:0] romd_bytes;
    logic         romd_hold;
    s32_v60fetch u_dfetch (
        .clk(clk), .rst(rst),
        .fetch_pc(romd_pc), .fetch_bytes(romd_bytes),
        .fetch_hold(romd_hold),
        .rf_req(drf_req), .rf_line(drf_line), .rf_data(drf_data),
        .rf_done(drf_done)
    );

    v60 u_v60 (
        .clk(clk), .rst(rst),
        .fetch_pc(fetch_pc), .fetch_bytes(v_fetch_bytes),
        .mem_re(mem_re), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_size(mem_size),
        .mem_rdata(mem_rdata),
        .trap(trap), .trap_op(trap_op),
        // NMI tied off: the schematic (sheet 7) wires the MB3771 power
        // monitor here, and there is no arcade supply to watch
        .nmi(1'b0),
        .irq(irq), .irq_vector(irq_vector),
        // The core steps on cen16 (the real 16.108 MHz clock) and waits
        // while the bus unit runs a bus cycle or the prefetch queue is
        // short. No NEC document gives per-instruction cycle counts, so
        // execution timing is not calibrated against the real part.
        .wait_hold(bcu_busy || fetch_hold || !cen16)
    );

    // Bus control unit: splits the core's transactions into the real
    // part's 16-bit T1-T2-T3 bus cycles (see the v60_bcu.sv header)
    v60_bcu u_bcu (
        .clk(clk), .rst(rst), .cen16(cen16),
        .c_re(mem_re), .c_we(mem_we), .c_addr(mem_addr),
        .c_wdata(mem_wdata), .c_size(mem_size),
        .c_rdata(mem_rdata), .busy(bcu_busy),
        .pf_req(pf_req), .pf_addr(pf_addr), .pf_grant(pf_grant),
        .pf_rdata(pf_rdata), .pf_done(pf_done),
        .f_re(b60_re), .f_we(b60_we), .f_addr(b60_addr),
        .f_wdata(b60_wdata), .f_size(b60_size), .f_fetch(b60_fetch),
        .f_rdata(b60_rdata), .f_hold(bus_hold), .f_pend(bcu_pend)
    );

    // ------------------------------------------------------ bus fabric
    logic        ev_vbin, ev_vbout;   // vblank in/out events (s32_video);
                                      // the fabric's FD1149 model uses ev_vbin
    logic        vid_sel, vid_we;
    logic        vram_cpu_hold;   // VRAM cache wait -> V60 bus vid_hold
    logic [23:1] vid_addr;
    logic [15:0] vid_wdata, vid_rdata;
    logic [1:0]  vid_bsel;
    logic        sc_sel, sc_we;
    logic [3:1]  sc_addr;
    logic [15:0] sc_wdata, sc_rdata;
    logic [1:0]  sc_bsel;
    logic        sr_re;
    logic [15:0] sr_raddr, sr_rdata;
    logic        spr_rdw_collision, spr_rdw_collision_q;
    logic        spr_cen;
    logic        shm_sel, shm_we;
    logic [12:0] shm_addr;
    logic [7:0]  shm_wdata, shm_rdata;
    logic        dpr_sel, dpr_we;
    logic [10:0] dpr_addr;
    logic [7:0]  dpr_wdata, dpr_rdata;
    logic        io_sel, io_we;
    logic [5:0]  io_offset;
    logic [7:0]  io_wdata, io_rdata;
    logic        ppi_sel, ppi_we;
    logic [1:0]  ppi_offset;
    logic [7:0]  ppi_wdata, ppi_rdata;
    logic        ic_sel, ic_we;
    logic [3:0]  ic_addr;
    logic [7:0]  ic_wdata, ic_rdata;

    // V60 clock: cen16 = clk/4 = the real 16.10795 MHz CPU clock (the
    // 32.2159 MHz crystal / 2). The core steps only on cen16, so its
    // outputs have four clk periods to settle (S32.sdc relies on this). The
    // bus unit registers everything the fabric sees, so the fabric's
    // v60_ph phase input is tied 1.
    logic [1:0] c16cnt;
    logic       cen16;
    always_ff @(posedge clk) begin
        if (rst) c16cnt <= 2'd0;
        else     c16cnt <= c16cnt + 2'd1;
    end
    assign cen16 = (c16cnt == 2'd3);

    s32_v60bus u_bus (
        .v60_ph(1'b1),
        .clk(clk), .rst(rst),
        .mem_re(b60_re), .mem_we(b60_we), .mem_addr(b60_addr),
        .mem_wdata(b60_wdata), .mem_size(b60_size), .mem_fetch(b60_fetch),
        .mem_rdata(b60_rdata), .bus_hold(bus_hold),
        .romd_pc(romd_pc), .romd_bytes(romd_bytes),
        .romd_hold(romd_hold),
        .romf_pc(romf_pc), .romf_bytes(romf_bytes), .romf_hold(romf_hold),
        .vid_sel(vid_sel), .vid_we(vid_we), .vid_addr(vid_addr),
        .vid_wdata(vid_wdata), .vid_bsel(vid_bsel), .vid_rdata(vid_rdata),
        .sc_sel(sc_sel), .sc_we(sc_we), .sc_addr(sc_addr),
        .sc_wdata(sc_wdata), .sc_bsel(sc_bsel), .sc_rdata(sc_rdata),
        .sr_re(sr_re), .sr_raddr(sr_raddr), .sr_rdata(sr_rdata),
        .spr_rdw_collision(spr_rdw_collision),
        .shm_sel(shm_sel), .shm_we(shm_we), .shm_addr(shm_addr),
        .shm_wdata(shm_wdata), .shm_rdata(shm_rdata),
        .dp_sel(dpr_sel), .dp_we(dpr_we), .dp_addr(dpr_addr),
        .dp_wdata(dpr_wdata), .dp_rdata(dpr_rdata),
        .io_sel(io_sel), .io_we(io_we), .io_offset(io_offset),
        .io_wdata(io_wdata), .io_rdata(io_rdata),
        .ppi_sel(ppi_sel), .ppi_we(ppi_we), .ppi_offset(ppi_offset),
        .ppi_wdata(ppi_wdata), .ppi_rdata(ppi_rdata),
        .ic_sel(ic_sel), .ic_we(ic_we), .ic_addr(ic_addr),
        .ic_wdata(ic_wdata), .ic_rdata(ic_rdata),
        .prot_brival(prot_brival),
        .prot_darkedge(prot_darkedge), .fd_vbl(ev_vbin),
        .bcu_pend(bcu_pend),
        .trk_board(trk_board), .trk_sel(trk_sel), .trk_we(trk_we),
        .trk_offset(trk_offset), .trk_rdata(trk_rdata),
        .prot_sonic(prot_sonic)
        , .vid_hold(vram_cpu_hold)
    );

    // --------------------------------------------- interrupt controller
    logic z80_int_pulse;
    logic v60_irq_pulse;

    // timer enables per MAME rates: A = 16.108M/2048, B = 3.125M/256
    // (12.21 kHz). From 64.43 MHz: A = /8192, B = /5277.
    logic [12:0] cta;
    logic [12:0] ctb;
    logic cen_ta, cen_tb;
    always_ff @(posedge clk) begin
        cen_ta <= 1'b0; cen_tb <= 1'b0;
        cta <= cta + 13'd1;
        if (cta == 13'd8191) begin cta <= '0; cen_ta <= 1'b1; end
        ctb <= ctb + 13'd1;
        if (ctb == 13'd5276) begin ctb <= '0; cen_tb <= 1'b1; end
    end

    s32_intctl u_ic (
        .clk(clk), .rst(rst),
        .sel(ic_sel), .we(ic_we), .addr(ic_addr),
        .wdata(ic_wdata), .rdata(ic_rdata),
        .ev_vblank_in(ev_vbin), .ev_vblank_out(ev_vbout),
        .ev_z80_comm(v60_irq_pulse),
        .cen_timer_a(cen_ta), .cen_timer_b(cen_tb),
        .irq(irq), .irq_vector(irq_vector), .irq_ack(1'b0),
        .z80_int_pulse(z80_int_pulse)
    );

    // ------------------------------------------------ io chips + EEPROM
    logic ee_cs, ee_sclk, ee_di, ee_do;

    eeprom_93c46 u_ee (
        .clk(clk), .rst(rst),
        .cs(ee_cs), .sclk(ee_sclk), .di(ee_di), .do_out(ee_do),
        .init_wen(ee_init_wen), .init_addr(ee_init_addr),
        .init_data(ee_init_data),
        .dump_addr(ee_dump_addr), .dump_data(ee_dump_data)
    );

    logic [63:0] io_in;
    logic [63:0] io_out;
    assign io_in[7:0]   = in_p1;
    assign io_in[15:8]  = in_p2;
    assign io_in[23:16] = in_portc;
    assign io_in[31:24] = 8'hFF;
    assign io_in[39:32] = in_service12;
    assign io_in[47:40] = {ee_cs ? ee_do : 1'b1, in_service34,
                           in_sw1_dips};
    assign io_in[63:48] = 16'hFFFF;

    logic [7:0] io_cnt;
    s32_io5296 u_io (
        .clk(clk), .rst(rst),
        .sel(io_sel), .we(io_we), .offset(io_offset),
        .wdata(io_wdata), .rdata(io_rdata),
        .in_ports(io_in), .out_latches(io_out), .dir(), .cnt(io_cnt)
    );

    // port D latch drives the EEPROM
    assign ee_di   = io_out[31];
    assign ee_sclk = io_out[30];
    assign ee_cs   = io_out[29];

    // trackball board: three uPD4701A, selected by trk_offset[3:2]
    logic        trk_sel, trk_we;
    logic [3:0]  trk_offset;
    logic [7:0]  trk_rdata;
    logic [7:0]  trk_rd [0:2];
    // (explicit generate + genvar: Quartus 17.0 rejects the bare
    // `for (genvar ...)` form)
    genvar gt;
    generate
        for (gt = 0; gt < 3; gt = gt + 1) begin : g_trk
            s32_upd4701 u_upd (
                .clk(clk), .rst(rst),
                .cnt_stb(trk_stb[gt]),
                .dx(trk_dx[12*gt +: 12]), .dy(trk_dy[12*gt +: 12]),
                .sel(trk_sel && trk_offset[3:2] == gt), .we(trk_we),
                .offset(trk_offset[1:0]), .rdata(trk_rd[gt])
            );
        end
    endgenerate
    assign trk_rdata = (trk_offset[3:2] == 2'd0) ? trk_rd[0]
                     : (trk_offset[3:2] == 2'd1) ? trk_rd[1] : trk_rd[2];

    s32_i8255 u_ppi (
        .clk(clk), .rst(rst),
        .sel(ppi_sel), .we(ppi_we), .offset(ppi_offset),
        .wdata(ppi_wdata), .rdata(ppi_rdata),
        .in_a(in_extra1), .in_b(in_extra2), .in_c(in_extra3),
        .out_a(), .out_b(), .out_c(), .ctrl()
    );

    // -------------------------------------------------- V25 protection
    logic        mcu_dp_sel, mcu_dp_we;
    logic [10:0] mcu_dp_addr;
    logic [7:0]  mcu_dp_wdata, mcu_dp_rdata;

    // The V25 runs at 10 MHz like the real part (its mailbox replies are
    // visible to the V60). Fractional accumulator: 100000/644318 =
    // 10/64.4318 exactly.
    logic [19:0] v25_acc;
    logic        v25_cen;
    always_ff @(posedge clk) begin
        if (rst) begin
            v25_acc <= '0;
            v25_cen <= 1'b0;
        end else if (v25_acc + 20'd100000 >= 20'd644318) begin
            v25_acc <= v25_acc + 20'd100000 - 20'd644318;
            v25_cen <= 1'b1;
        end else begin
            v25_acc <= v25_acc + 20'd100000;
            v25_cen <= 1'b0;
        end
    end

    s32_v25 u_v25 (
        .clk(clk), .rst(rst), .cen(v25_cen), .hold(mrom_hold),
        .dec_arf(prot_arf),
        .rom_addr(mrom_addr), .rom_data(mrom_data), .rom_rd(mrom_rd),
        .dp_sel(mcu_dp_sel), .dp_we(mcu_dp_we), .dp_addr(mcu_dp_addr),
        .dp_wdata(mcu_dp_wdata), .dp_rdata(mcu_dp_rdata)
    );

    // The MB8421's /BUSY outputs are generated but not connected: whether
    // the board wires them to the V25's READY is not known. Golden Axe never
    // has both sides access one address at once, so nothing would stall.
    mb8421 u_dpram (
        .clk(clk),
        .l_sel(mcu_dp_sel), .l_we(mcu_dp_we), .l_addr(mcu_dp_addr),
        .l_wdata(mcu_dp_wdata), .l_rdata(mcu_dp_rdata), .l_busy_n(),
        .r_sel(dpr_sel), .r_we(dpr_we), .r_addr(dpr_addr),
        .r_wdata(dpr_wdata), .r_rdata(dpr_rdata), .r_busy_n()
    );

    // ------------------------------------------------------- sound
    // z80_int_pulse (1 clk) stretched to guarantee the sndint sees it
    // even while the Z80 side idles between cens
    logic [3:0] cmd_stretch;
    always_ff @(posedge clk) begin
        if (rst)                cmd_stretch <= '0;
        else if (z80_int_pulse) cmd_stretch <= 4'd8;
        else if (cmd_stretch != 0) cmd_stretch <= cmd_stretch - 4'd1;
    end

    // 315-5296 CNT bit 2 = SRES: resets the Z80, both YM3438s (/IC) and
    // the RF5C105 PCM chip (schematic sheets 6 and 8; MAME out_cnt2 ->
    // sound_reset). CNT is 0 after reset, so the whole sound section stays
    // in reset until the game releases it, and a sound reset issued by the
    // game (test mode, soft reset) resets it again.
    wire snd_rst = rst | ~io_cnt[2];
    s32_soundtop u_snd (
        .clk(clk), .rst(snd_rst),
        .cen_z80(cen_z80 && !zrom_hold), .cen_fm(cen_z80),
        .cen_pcm(cen_pcm),
        .rom_addr(zrom_addr), .rom_data(zrom_data), .rom_rd(zrom_rd),
        .shm_sel(shm_sel), .shm_we(shm_we), .shm_addr(shm_addr),
        .shm_wdata(shm_wdata), .shm_rdata(shm_rdata),
        .nv_sel(zram_nv_sel), .nv_we(zram_nv_we), .nv_addr(zram_nv_addr),
        .nv_wdata(zram_nv_wdata), .nv_rdata(zram_nv_rdata),
        .v60_cmd(|cmd_stretch), .v60_irq_pulse(v60_irq_pulse),
        .audio_l(audio_l), .audio_r(audio_r)
    );

    // ------------------------------------------------------- video
    logic [1:0] spr_flip;
    assign fb_top_line = (spr_flip[1] ^ cab_vmirror) ? 8'd223 : 8'd0;

    // 315-5296 CNT bit 1 = display enable (MAME io_chip.out_cnt1 ->
    // display_enable_w; segas32_v.cpp:2098 shows black while it is clear).
    // The game clears it for a few frames across scene changes, so the
    // screen goes black instead of showing the scene being torn down.
    // s32_video applies it at its output (disp_en).
    logic [14:0] vid_rgb;
    assign rgb = vid_rgb;

    s32_video u_vid (
        .clk(clk), .rst(rst), .cen_pix(cen_pix),
        .cen_ren(cen_ren),
        .cpu_sel(vid_sel), .cpu_we(vid_we),
        .cpu_addr(vid_addr),
        .cpu_wdata(vid_wdata), .cpu_bsel(vid_bsel), .cpu_rdata(vid_rdata),
        // io5296 port H bit 0 = external tilebank latch (bank bit 1)
        .tilebank_ext(io_out[56]),
        .rom_re(trom_re), .rom_addr(trom_addr), .rom_rdata(trom_data),
        .rom_ack(trom_ack),
        .spr_re(fbr_re), .spr_x(fbr_x), .spr_line(fbr_line),
        .spr_rdata(fbr_data), .spr_flip(spr_flip),
        .cab_vmirror(cab_vmirror),
        .disp_en(io_cnt[1]),          // CNT1 display enable
        .de(de), .rgb(vid_rgb), .hblank(hblank), .vblank(vblank),
        .hs(hs), .vs(vs), .wide(vid_wide),
        .ev_vblank_in(ev_vbin), .ev_vblank_out(ev_vbout)
        , .vram_go(vram_go), .vram_cpu_hold(vram_cpu_hold),
        .vram_rf_req(vram_rf_req), .vram_rf_addr(vram_rf_addr),
        .vram_rf_cont(vram_rf_cont), .vram_rf_urg(vram_rf_urg),
        .vram_rf_data(vram_rf_data), .vram_rf_done(vram_rf_done),
        .vram_rf_stb(vram_rf_stb), .vram_rf_ack(vram_rf_ack),
        .vram_wr_req(vram_wr_req), .vram_wr_addr(vram_wr_addr),
        .vram_wr_data(vram_wr_data), .vram_wr_dqm(vram_wr_dqm),
        .vram_wr_done(vram_wr_done)
    );

    // The sprite list RAM is a true dual-port M10K. Golden Axe changes the
    // packet-1 sublist jump at the vblank-out handoff (the technique
    // described in s32tech, 315-5386A), exactly when the engine may read it.
    // A same-address write on port A and read on port B returns undefined
    // data on the FPGA (simulation returns the old data). So the engine is
    // frozen on the collision cycle and one more, letting port B re-read
    // the address before the engine uses it.
    always_ff @(posedge clk) begin
        if (rst) spr_rdw_collision_q <= 1'b0;
        else     spr_rdw_collision_q <= spr_rdw_collision;
    end
    // The real 315-5386 sprite engine runs at 25 MHz, but its fill rate per
    // operation is not documented. The engine here runs at the full clk rate
    // whenever cen_spr allows (it waits only for a sprite-ROM miss or frame
    // buffer backpressure), so a scene never runs out of time and loses
    // sprites.
    assign spr_cen = cen_spr && !spr_rdw_collision
                   && !spr_rdw_collision_q;

    s32_sprite_top u_spr (
        .clk(clk), .rst(rst), .cen(spr_cen),
        .cpu_sel(sc_sel), .cpu_we(sc_we), .cpu_addr(sc_addr),
        .cpu_wdata(sc_wdata), .cpu_bsel(sc_bsel), .cpu_rdata(sc_rdata),
        .ev_vblank_out(ev_vbout),
        .sr_re(sr_re), .sr_addr(sr_raddr), .sr_rdata(sr_rdata),
        .rom_re(srom_re), .rom_addr(srom_addr), .rom_rdata(srom_data),
        .fb_we(fb_we), .fb_bank(fb_bank), .fb_x(fb_x), .fb_y(fb_y),
        .fb_wdata(fb_wdata), .fb_shadow(fb_shadow),
        .fb_erase(fb_erase),
        .disp_bank(fb_disp_bank), .flip_out(spr_flip),
        .render_busy(spr_busy)
    );
    logic       spr_busy;

endmodule
