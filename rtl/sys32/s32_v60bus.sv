// s32_v60bus.sv — the V60's bus fabric: address decode and the paths to
// every memory and chip on the bus.
//
// Each bus cycle arrives from the bus unit (v60_bcu) as a one-cycle
// mem_re/mem_we strobe; bus_hold stays high until mem_rdata is ready.
// Narrow chip ports are served one lane at a time: 16-bit lanes for the
// video, sprite-control and sprite-RAM ports, byte lanes for shared RAM,
// the V25 mailbox, the I/O chips and the interrupt controller. A byte write
// to a 16-bit RAM port is a read-merge-write.
//
// Map (MAME system32_map; mirrors per s32tech "Memory map"):
//   000000-1FFFFF / F00000+  program ROM
//   200000-2FFFFF  work RAM, 64KB (16K x 32, dual-port so an unaligned
//                  access can read a word and the next one together)
//   300000-3FFFFF + 600000-6FFFFF  s32_video 16-bit CPU port (the
//                  6xxxxx palette/mixer pair mirrors every 128KB; the
//                  fabric folds the address to 60xxxx/61xxxx)
//   400000-4FFFFF  sprite list RAM (64K x 16, inside this module)
//   500000-5FFFFF  sprite control (16-bit; the whole megabyte decodes to
//                  the one register block, as in MAME; the real sub-decode
//                  is not documented)
//   700000-7FFFFF  Z80 shared RAM (8-bit)
//   A00000-A7FFFF  V25 mailbox RAM (8-bit, even bytes; the 4KB window
//                  repeats every 2048 words, per s32tech)
//   C00000-CFFFFF  I/O chips, repeating every 0x80: offsets 00-1F
//                  315-5296, 60-67 i8255 (whether 68-6F alias the i8255 is
//                  not documented; they read as open bus here)
//   D00000-D7FFFF  interrupt controller (8-bit)
//   D80000-DFFFFF  random number generator: free-running 16-bit LFSR,
//                  a write seeds it (the real generator is not documented)
//   E00000-E0000F  315-5385 memory timing registers
//
// Burning Rival's FD1149 protection module (prot_brival): see the
// "FD1149 flag words" block below. Dark Edge's (prot_darkedge): the
// "FD1149 vblank writes" block, which F1 Super Lap's (prot_f1lap) shares
// in its own four states. SegaSonic's (prot_sonic): the "FD1149
// level load" block. Dragon Ball Z: V.R. V.S.'s (prot_dbz): the "FD1149
// state copy" block. SegaSonic's trackball board (trk_board): uPD4701A
// counters at I/O offsets 40-57 (R_TRK; s32_upd4701). Rad Mobile's A/D
// board (adc_board): an MSM6253 at I/O offsets 50-57 (R_ADC; s32_msm6253).
// F1 Exhaust Note's bridge board (brg_board): the "bridge board" block, the
// $810000-$81FFFF window (R_BRG).

module s32_v60bus (
    input  logic        clk,
    input  logic        rst,

    // ---- V60 core side
    input  logic        v60_ph,       // V60-outputs-stable phase
    input  logic        mem_re,
    input  logic        mem_we,
    input  logic [31:0] mem_addr,
    input  logic [31:0] mem_wdata,
    input  logic [2:0]  mem_size,      // bytes: 1 / 2 / 4
    // this bus cycle is an instruction fetch: its ROM read uses the
    // prefetching fetch adapter (romf) rather than the data adapter (romd)
    input  logic        mem_fetch,
    output logic [31:0] mem_rdata,
    output logic        bus_hold,
    // the fabric is waiting on a memory the board emulates in SDRAM: a ROM
    // adapter refill (A_ROMW) or the VRAM cache (A_SUB_W). On the real board
    // the EPROMs and VRAM answer inside the bus cycle. s32_sys's V60 clock
    // repays the T3 waits these cause (docs/alien3-bringup.md §6.2).
    output logic        wait_emul,
    // the bus cycle in flight costs the ideal machine one T3 wait slot of
    // its own (a two-pass serialized access): the wait-debt clock in
    // s32_sys charges T3 slots beyond that one (see wait_native below)
    output logic        wait_native,
    // cen16 slots the bus cycle at mem_addr adds to the bus unit's three
    // (the 315-5385 timing table below; v60_bcu inserts them after T2)
    output logic [1:0]  bus_xslots,

    // ---- program ROM data reads: served by a data-side line
    //      adapter (a second s32_v60fetch); the fabric holds until
    //      the window covers the address
    output logic [23:0] romd_pc,
    input  logic [111:0] romd_bytes,
    input  logic         romd_hold,

    // ---- program ROM instruction-fetch reads: the prefetching fetch
    //      adapter. Same shape as romd; used when mem_fetch is set.
    output logic [23:0] romf_pc,
    input  logic [111:0] romf_bytes,
    input  logic         romf_hold,

    // ---- s32_video CPU port (16-bit, 1-cycle read; vid_bsel = byte
    //      strobes for the mixer regfile — RAM targets see 2'b11)
    output logic        vid_sel,
    output logic        vid_we,
    output logic [23:1] vid_addr,
    output logic [15:0] vid_wdata,
    output logic [1:0]  vid_bsel,
    input  logic [15:0] vid_rdata,
    // VRAM lives in SDRAM behind a cache, so a VRAM access can wait (cache
    // miss, write-through). vid_hold is 0 on a hit and for palette/mixer
    // accesses.
    input  logic        vid_hold,

    // ---- sprite control port (16-bit; sc_bsel = byte strobes so a
    //      high-byte-only write cannot re-fire low-byte triggers)
    output logic        sc_sel,
    output logic        sc_we,
    output logic [3:1]  sc_addr,
    output logic [15:0] sc_wdata,
    output logic [1:0]  sc_bsel,
    input  logic [15:0] sc_rdata,

    // ---- sprite list RAM engine-side read port
    input  logic        sr_re,
    input  logic [15:0] sr_raddr,
    output logic [15:0] sr_rdata,
    // A CPU write on port A can hit the word the engine is reading on
    // port B (the game edits the list at the vblank-out handoff, s32tech
    // 315-5386A). An M10K returns undefined data then, so the collision is
    // reported and s32_sys freezes the engine for this cycle and the next.
    output logic        spr_rdw_collision,

    // ---- sound shared RAM (8-bit)
    output logic        shm_sel,
    output logic        shm_we,
    output logic [12:0] shm_addr,
    output logic [7:0]  shm_wdata,
    input  logic [7:0]  shm_rdata,

    // ---- V25 dpram right port (8-bit)
    output logic        dp_sel,
    output logic        dp_we,
    output logic [10:0] dp_addr,
    output logic [7:0]  dp_wdata,
    input  logic [7:0]  dp_rdata,

    // ---- io chip / PPI (8-bit, combinational rdata)
    output logic        io_sel,
    output logic        io_we,
    output logic [5:0]  io_offset,
    output logic [7:0]  io_wdata,
    input  logic [7:0]  io_rdata,
    output logic        ppi_sel,
    output logic        ppi_we,
    output logic [1:0]  ppi_offset,
    output logic [7:0]  ppi_wdata,
    input  logic [7:0]  ppi_rdata,
    // ---- trackball board (SegaSonic's 837-8685, board descriptor bit 6):
    //      three uPD4701A at I/O offsets 40-47 / 48-4F / 50-57, even bytes
    //      (MAME system32_trackball_map). trk_offset = {chip, X/Y, U/L}.
    //      Without the board the window is open bus, as on every other
    //      game (s32tech: "$C00040-$C0007F normally unused")
    input  logic        trk_board,
    output logic        trk_sel,
    output logic        trk_we,
    output logic [3:0]  trk_offset,
    input  logic [7:0]  trk_rdata,
    // ---- A/D board (Rad Mobile's 837-7536, descriptor byte 2 bit 0): one
    //      MSM6253 at I/O offsets 50-57, even bytes (MAME
    //      system32_analog_map). adc_offset = the word offset, which picks
    //      the channel on a write. Open bus without the board
    input  logic        adc_board,
    output logic        adc_sel,
    output logic        adc_we,
    output logic [1:0]  adc_offset,
    input  logic [7:0]  adc_rdata,

    // ---- interrupt controller (8-bit, combinational rdata)
    output logic        ic_sel,
    output logic        ic_we,
    output logic [3:0]  ic_addr,
    output logic [7:0]  ic_wdata,
    output logic        ic_more,     // another byte of this access follows
                                     // (s32_intctl: one 16-bit load)
    input  logic [7:0]  ic_rdata,

    // ---- Burning Rival's FD1149 protection module (from the .mra's board
    //      descriptor bit 4); 0 on every other game
    input  logic        prot_brival,

    // ---- Dark Edge's FD1149 protection module (descriptor bit 5): the
    //      $A00000 window reads $FFFF, and at each vblank-in (fd_vbl, one
    //      clk) the module writes work RAM. bcu_pend is the bus unit's
    //      queued-strobe flag (v60_bcu f_pend): the module takes the bus
    //      only when no V60 cycle is queued (see "FD1149 vblank writes")
    input  logic        prot_darkedge,
    input  logic        fd_vbl,
    input  logic        bcu_pend,

    // ---- SegaSonic's FD1149 protection module (descriptor bit 7): a V60
    //      write to $20E5C4 loads the level (see "FD1149 level load")
    input  logic        prot_sonic,

    // ---- F1 Super Lap's FD1149 protection module (descriptor byte 1
    //      bit 4): at each vblank-in it writes work RAM, as Dark Edge's
    //      does (fd_vbl, bcu_pend; see "FD1149 vblank writes (f1lap)")
    input  logic        prot_f1lap,

    // ---- Dragon Ball Z: V.R. V.S.'s FD1149 protection module (descriptor
    //      byte 1 bit 6): the $A00000 window reads $FFFF, and a V60 write
    //      there copies a work RAM word (see "FD1149 state copy (dbzvrvs)")
    input  logic        prot_dbz,

    // ---- The J.League 1994's FD1149 protection module (descriptor byte 2
    //      bit 0): V60 writes to work RAM $20F700/$20F704 set $20F708 from
    //      a ROM table and $200016 (see "FD1149 browser hook (jleague)")
    input  logic        prot_jleague,

    // ---- F1 Exhaust Note's bridge board (descriptor byte 2 bit 1): the
    //      shared RAM and main/sub register at $810000-$81FFFF, seen from
    //      the main seat with no partner board (see "bridge board")
    input  logic        brg_board,
    // ---- Air Rescue (descriptor byte 2 bit 2): the bridge board as above
    //      plus the absent partner's half of the boot handshake (brg_hs),
    //      and the 837-8341 DSP board at $A00000 (dsp_board, s32_dspbd),
    //      whose program the ROM loader writes through dsp_ld_* while the
    //      core is in reset (see "DSP board")
    input  logic        brg_hs,
    input  logic        dsp_board,
    input  logic        dsp_ld_we,
    input  logic [13:0] dsp_ld_addr,
    input  logic [7:0]  dsp_ld_data
);

    // ------------------------------------------------------ work RAM
    // Four byte-lane RAMs (s32_tdp): port A writes, or reads the aligned
    // word, on one muxed address; port B reads the next word for unaligned
    // access. s32_tdp instantiates the M10K directly because Quartus 17
    // will not infer this shape (it builds it from registers).
    logic [7:0]  wram_qa_l [0:3], wram_qb_l [0:3];
    logic [13:0] wram_aa, wram_ab;
    logic [13:0] wram_waddr [0:3];
    logic [7:0]  wram_wd    [0:3];
    logic [3:0]  wram_wen;

    genvar gl;
    generate
        for (gl = 0; gl < 4; gl = gl + 1) begin : g_wram
            logic [13:0] a_side;
            assign a_side = wram_wen[gl] ? wram_waddr[gl] : wram_aa;
            // OREGA/OREGB=1: use the M10K's own output registers. Without
            // them, a read whose address jumps far across the RAM does not
            // always settle in time on the FPGA. Read latency is 2 clk;
            // the A_WRAM1B wait state absorbs it.
            s32_tdp #(.AW(14), .DW(8), .OREGA(1), .OREGB(1)) u_lane (
                .clk(clk),
                .we_a(wram_wen[gl]), .addr_a(a_side),
                .d_a(wram_wd[gl]), .q_a(wram_qa_l[gl]),
                .we_b(1'b0), .addr_b(wram_ab),
                .d_b(8'd0), .q_b(wram_qb_l[gl])
            );
        end
    endgenerate

    logic [31:0] wram_qa, wram_qb;
    assign wram_qa = {wram_qa_l[3], wram_qa_l[2],
                      wram_qa_l[1], wram_qa_l[0]};
    assign wram_qb = {wram_qb_l[3], wram_qb_l[2],
                      wram_qb_l[1], wram_qb_l[0]};


    // ------------------------------------------------ sprite list RAM
    // a 16-bit "port" so the serializer treats it like the video and
    // sprite-control ports
    logic        spm_sel, spm_we;
    logic [1:0]  spm_bsel;
    logic [15:0] spm_addr;
    logic [15:0] spm_wdata, spm_rdata;
    // Two 8-bit lane arrays: a CPU byte write touches one lane, as on the
    // real board, where the 315-5386 takes BUBE and BA0 on its CPU side
    // and drives two write strobes, RWE0 (BD0-7 pair IC66/IC65) and RWE1
    // (BD8-15 pair IC64/IC63), to its four 64Kx4 dual-port RAMs
    // (schematics sheet 3/9; 2026-10-31, docs/OPEN-QUESTIONS.md Q29).
    // Benches address the lanes as sprram_l / sprram_h.
    logic [7:0]  sprram_l [0:65535];
    logic [7:0]  sprram_h [0:65535];

    // Intel true-dual-port template per lane: port A = CPU read/write
    // with new-data write-through, port B = sprite engine read. Each lane
    // is its own always block in exactly the shape the single 16-bit
    // array had (write and bypass under one condition, read otherwise):
    // one block with lane-conditional writes and an unconditional bypass
    // was NOT inferred as RAM (quartus_map Error 276003, the 64Kx16
    // array turned into registers; 2026-10-31).
    always_ff @(posedge clk) begin        // port A, low lane
        if (spm_sel && spm_we && spm_bsel[0]) begin
            sprram_l[spm_addr] <= spm_wdata[7:0];
            spm_rdata[7:0] <= spm_wdata[7:0];
        end else
            spm_rdata[7:0] <= sprram_l[spm_addr];
    end
    always_ff @(posedge clk) begin        // port A, high lane
        if (spm_sel && spm_we && spm_bsel[1]) begin
            sprram_h[spm_addr] <= spm_wdata[15:8];
            spm_rdata[15:8] <= spm_wdata[15:8];
        end else
            spm_rdata[15:8] <= sprram_h[spm_addr];
    end
    logic [15:0] sr_addr_used;
    logic        sr_re_used;
    assign sr_addr_used = sr_raddr;
    assign sr_re_used   = sr_re;
    assign spr_rdw_collision = spm_sel && spm_we && sr_re_used
                             && (spm_addr == sr_addr_used);

    always_ff @(posedge clk) begin        // port B: sprite engine
        // Do not issue the physically undefined mixed-port read.  The
        // engine is frozen by s32_sys on this edge and for one extra
        // edge; the held address is then re-read cleanly before the
        // engine consumes sr_rdata.
        if (sr_re_used && !spr_rdw_collision)
            sr_rdata <= {sprram_h[sr_addr_used], sprram_l[sr_addr_used]};
    end

    // ------------------------------------------------- bridge board
    // F1 Exhaust Note (brg_board): MAME builds the cabinet as two analog
    // boards, one per seat, and a bridge board "sitting underneath the ROM
    // board bridging 2 PCBs (not a network link)" (segas32.cpp
    // sega_system32_dual_direct). init_f1en() maps, on each board:
    //   $810000-$810FFF  the shared RAM, 2K x 16 (dual_pcb_comms_r/_w;
    //                    filled with $FF at init)
    //   $818000-$818003  main/sub: 0 on the main board, 1 on the sub
    //                    (dual_pcb_mainsub / dual_pcb_sub; read only)
    // and nothing else in $810000-$81FFFF, which reads open bus here.
    //
    // The core is the main seat with no partner (docs/f1en-bringup.md):
    // the register reads 0, and only this board writes the RAM. The boot
    // code takes the main role on bit 0 = 0 (FF6394), times out waiting
    // for the other seat and plays unlinked; on open bus it would take the
    // sub role and wait forever at FF63ED (MAME, tools/mame/f1en_probe.lua).
    // What drives the bit on a real cabinet, and how its RAM powers up, is
    // Q63; the $FF fill is MAME's. Writes to the register and to the open
    // part of the window are dropped.
    //
    // Air Rescue (brg_hs) uses the same board, and its boot needs one thing
    // from the partner seat: at 07DA3C the main board writes $FF to byte
    // $810001 and loops, ANDing it with $AA, until it reads 0; only the sub
    // board's `and.b #$55` (07DA90) can get it there, and $FF on its own
    // sends the main board back to 06000A. With no partner the core applies
    // that AND to every write of byte $810001, which is what the partner
    // does to it within the handshake; MAME with the main board's bridge RAM
    // private and only this answered matches the two-board run
    // pixel for pixel from the coin on (tools/mame/arescue_probe.lua
    // AR_LINK=hs; docs/arescue-bringup.md §4). It stands in for the absent
    // board, so it is the documented exception Q64 records.
    //
    // Two 8-bit lane arrays, as the sprite RAM: a byte write is one lane
    // write, never a read-merge-write. One registered read per lane, one
    // port, so no read can collide with a write to the same address.
    logic        brg_sel, brg_we;
    logic        dsp_sel_p;            // DSP board strobe and read (see
    logic [15:0] dsp_rd, dsp_q;        // "DSP board")
    logic [1:0]  brg_bsel;
    logic [15:1] brg_addr;
    logic [15:0] brg_wdata, brg_q, brg_rdata;
    logic [1:0]  brg_kind;               // 0 RAM, 1 main/sub, 2 open bus
    logic [7:0]  brgram_l [0:2047];
    logic [7:0]  brgram_h [0:2047];
    initial begin
        for (int i = 0; i < 2048; i++) begin
            brgram_l[i] = 8'hFF;
            brgram_h[i] = 8'hFF;
        end
    end
    wire brg_ram = (brg_addr[15:12] == 4'h0);
    always_ff @(posedge clk) begin
        if (brg_sel && brg_we && brg_ram && brg_bsel[0])
            brgram_l[brg_addr[11:1]] <= brg_wdata[7:0];
        brg_q[7:0] <= brgram_l[brg_addr[11:1]];
    end
    always_ff @(posedge clk) begin
        if (brg_sel && brg_we && brg_ram && brg_bsel[1])
            brgram_h[brg_addr[11:1]] <= brg_wdata[15:8]
                & ((brg_hs && brg_addr[11:1] == 11'd0) ? 8'h55 : 8'hFF);
        brg_q[15:8] <= brgram_h[brg_addr[11:1]];
    end
    always_ff @(posedge clk)
        if (brg_sel)
            brg_kind <= brg_ram ? 2'd0
                      : (brg_addr[15:2] == 14'h2000) ? 2'd1 : 2'd2;
    assign brg_rdata = (brg_kind == 2'd0) ? brg_q
                     : (brg_kind == 2'd1) ? 16'h0000 : 16'hFFFF;

    // ------------------------------------------------- region decode
    logic [23:0] p;
    assign p = mem_addr[23:0];

    typedef enum logic [4:0] {
        R_ROM, R_WRAM, R_VID, R_SPRRAM, R_SPRCTL, R_SHM,
        R_DPRAM, R_IO, R_PPI, R_IC, R_RNG, R_ETMG, R_OPEN, R_TRK, R_ADC,
        R_DZ, R_BRG, R_DSP
    } region_e;

    // mirrors (s32tech "Memory map"): the 6xxxxx video pair repeats every
    // 128KB, the mailbox window through A7FFFF, the I/O block every 0x80
    // through CFFFFF
    function automatic region_e region_of (input logic [23:0] a);
        if (a < 24'h200000)                          region_of = R_ROM;
        else if (a >= 24'hF00000)                    region_of = R_ROM;
        else if (a < 24'h300000)                     region_of = R_WRAM;
        else if (a < 24'h400000)                     region_of = R_VID;
        else if (a < 24'h500000)                     region_of = R_SPRRAM;
        else if (a < 24'h600000)                     region_of = R_SPRCTL;
        else if (a[23:20] == 4'h6)                   region_of = R_VID;
        else if (a >= 24'h700000 && a < 24'h800000)  region_of = R_SHM;
        // F1 Exhaust Note's bridge board (MAME init_f1en's handlers)
        else if (a[23:16] == 8'h81 && brg_board)     region_of = R_BRG;
        // Dark Edge's FD1149 answers the mailbox window instead: reads
        // $FFFF, writes ignored (MAME darkedge_protection_r/_w)
        // Air Rescue's DSP board (see "DSP board")
        else if (a[23:19] == 5'b10100 && dsp_board)  region_of = R_DSP;
        else if (a[23:19] == 5'b10100 && prot_darkedge) region_of = R_OPEN;
        // so does Dragon Ball Z's, whose writes trigger its state copy
        else if (a[23:19] == 5'b10100 && prot_dbz)   region_of = R_DZ;
        else if (a[23:19] == 5'b10100)               region_of = R_DPRAM;
        else if (a[23:20] == 4'hC && a[6:0] < 7'h20) region_of = R_IO;
        else if (a[23:20] == 4'hC && trk_board && a[6:3] >= 4'h8
                 && a[6:3] < 4'hB)                   region_of = R_TRK;
        else if (a[23:20] == 4'hC && adc_board && a[6:3] == 4'hA)
                                                     region_of = R_ADC;
        else if (a[23:20] == 4'hC && a[6:3] == 4'b1100)
                                                     region_of = R_PPI;
        else if (a[23:19] == 5'b11010)               region_of = R_IC;
        else if (a[23:19] == 5'b11011)               region_of = R_RNG;
        // 315-5385 per-megabyte timing registers $E00000-0F; the rest of
        // the $E region is open bus
        else if (a[23:20] == 4'hE && a[19:4] == 16'd0) region_of = R_ETMG;
        else                                         region_of = R_OPEN;
    endfunction

    // ---------------------------------------- 315-5385 timing registers
    // Sixteen 2-bit access-delay fields ($E00000-0F), one per address
    // megabyte a[23:20]. Games write a default table at boot (s32tech
    // "Memory timing": 0 = moderate, 1 = short, 2 = moderate, 3 = long;
    // "the length of the wait state portion of a V60 bus access cycle").
    // ga2 and spidman write 00 00 03 02 02 00 00 02 0x 00 00 00 03 02 00 00
    // (latest MAME master, write tap at $E00000, 2026-11-01): no region is
    // ever short. MAME stores the table and ignores it.
    //
    // Bus cycle length (2026-11-01, Q56). The full uPD70616 data sheet
    // (1986-09, "Bus cycle" and the timing diagrams) defines a standard
    // cycle of four clocks, T1-T2-T3-T4, with READY sampled at the falling
    // edge of T3 and wait states TW between T3 and T4, and a short cycle of
    // three clocks, T1-T2-T4, selected by BMODE low at T2, which takes no
    // waits. The 315-5385 drives the V60's BMODE and its wait input from
    // this table; the mapping below is this model's reading of it:
    //   1 (short)            -> short cycle, 3 clocks
    //   0 / 2 (moderate)     -> standard cycle, 4 clocks
    //   3 (long)             -> standard + ETMG_LONG_W waits
    // The ordering is s32tech's; the clock counts are not documented
    // anywhere. Two real ga2 boards on footage run the attract's load
    // segments at 1.7-2.4x MAME's flat 8 clk/instruction, the core with
    // every cycle 3 clocks at 1.25x (docs/OPEN-QUESTIONS.md Q39); with
    // ETMG_LONG_W = 1 the bus-bound LZ decompressor (tools/pcbtests/pt_lz)
    // predicts 2.0x.
    (* ramstyle = "logic" *) logic [1:0] etmg [0:15];  // 32 bits: not an M10K (corertlcleanup B1)
    initial begin
        // s32tech default: 00 00 03 02 02 00 00 02 00 00 00 00 03 02 00 00
        etmg[0]='d0; etmg[1]='d0; etmg[2]='d3; etmg[3]='d2;
        etmg[4]='d2; etmg[5]='d0; etmg[6]='d0; etmg[7]='d2;
        etmg[8]='d0; etmg[9]='d0; etmg[10]='d0; etmg[11]='d0;
        etmg[12]='d3; etmg[13]='d2; etmg[14]='d0; etmg[15]='d0;
    end
    // ETMG_LONG_W_OVR (sim only, 2026-11-06): A/B the long-cycle wait count
    // (Q56) without editing this line; synthesis never defines it
    localparam logic [1:0] ETMG_LONG_W = 2'd1;
    // mem_addr is the bus unit's registered f_addr, stable from T1 on
    function automatic logic [1:0] etmg_xs(input logic [1:0] code);
        etmg_xs = (code == 2'd1) ? 2'd0
                : (code == 2'd3) ? 2'd1 + ETMG_LONG_W : 2'd1;
    endfunction
    assign bus_xslots = etmg_xs(etmg[mem_addr[23:20]]);

    // -------------------------------------------- ROM data window
    // the data-line adapter serves a 14-byte window at romd_pc; the
    // first 4 window bytes (MSB-first) are the little-endian dword
    assign romd_pc = q_addr;
    logic [31:0] romd_dword;
    assign romd_dword = {romd_bytes[87:80],  romd_bytes[95:88],
                         romd_bytes[103:96], romd_bytes[111:104]};
    // fetch ROM window: romf_pc holds the last fetch address, so the fetch
    // adapter keeps prefetching ahead of the instruction stream while data
    // cycles are interleaved
    logic [23:0] romf_pc_r;
    assign romf_pc = romf_pc_r;
    logic [31:0] romf_dword;
    assign romf_dword = {romf_bytes[87:80],  romf_bytes[95:88],
                         romf_bytes[103:96], romf_bytes[111:104]};
    logic q_fetch;                           // latched: current txn is a fetch

    // ------------------------------------------------- request queue
    typedef enum logic [4:0] {
        A_IDLE, A_WRAM1, A_WRAM2, A_SUB, A_SUB_W, A_SUB_L, A_DONE,
        A_ROMW, A_OPENW, A_WRAMX, A_SUB_P, A_WRAM1B,
        A_FD0, A_FD1, A_FD2, A_FD3,
        // appended so every earlier state keeps its encoding (the benches
        // compare ast with 0, 4 and 7)
        A_SN0, A_SN1, A_SN2, A_SN3, A_SN4, A_SN5, A_SN6,
        A_FL0, A_FL1, A_FL2, A_FL3,
        A_DZ0, A_DZ1, A_DZ2, A_DZ3,
        A_JL                         // the 32nd and last 5-bit encoding
    } astate_e;
    astate_e ast;

    logic [23:0] q_addr;
    logic [31:0] q_wdata;
    logic [2:0]  q_size;
    logic        q_we;
    region_e     q_reg;
    logic [2:0]  lane;               // byte offset of current lane
    logic [31:0] acc;
    logic [15:0] rmw_word;
    logic        rmw_done;           // the RMW read pass has completed
                                     // (byte write to a 16-bit port);
                                     // rmw_req below is decoded from
                                     // the registered q_* copies, which
                                     // keeps it off a deep timing path

    assign bus_hold = (ast != A_IDLE);
    assign wait_emul = ((ast == A_ROMW) && (q_fetch ? romf_hold : romd_hold))
                     || ((ast == A_SUB_W) && vid_hold)
                     ;

    // --------------------------------------- FD1149 flag words (brival)
    // Burning Rival carries an FD1149 security module (317-0212) on the ROM
    // board's protection socket. Its program has never been dumped, and no
    // technical description of it is published (docs/brival-bringup.md §2).
    // What the game asks of it is visible in the V60 program: it writes
    // $FFFF to a flag halfword at $20BA00 (boot), $20BA04 (in play) or
    // $20BA06, runs a 32K- or 64K-iteration delay loop, then requires the
    // halfword to read 0, or takes its failure path. The module has bus
    // access, so it presumably clears the word itself. MAME models the
    // result: a 16-bit read of $20BA00, $20BA04 or $20BA06 returns 0, every
    // other read returns work RAM (segas32_m.cpp brival_protection_r; the
    // handler covers exactly $20BA00-$20BA07, no mirror). The core does the
    // same. MAME's V60 runs a 16-bit bus, so the rule applies per halfword:
    // a halfword is forced to 0 only when the access covers both of its
    // bytes (an aligned halfword, or a halfword inside a dword). Byte reads,
    // and halfword reads at an odd address (split into byte cycles), see
    // work RAM.
    //   MAME's other half, brival_protection_w (a write at $A00800-$A0080A
    // copies a 16-byte ROM string into protection RAM), has no V60-visible
    // effect: nothing maps that RAM for reading, and the game's read-back
    // check of it at $A00000/$A00100 is dead code (its enable, $2070EB, is
    // only ever cleared). Writes to $A00xxx land in the mailbox RAM, as on
    // Spider-Man's board, where nothing reads them.
    function automatic logic brival_flag (input logic [23:0] a);
        brival_flag = (a == 24'h20BA00) || (a == 24'h20BA04)
                   || (a == 24'h20BA06);
    endfunction
    logic [31:0] brival_clr;        // byte lanes of the read to force to 0
    always_comb begin
        brival_clr = 32'd0;
        for (int k = 0; k < 3; k = k + 1) begin
            logic [23:0] h;
            h = q_addr + k[23:0];
            if (prot_brival && !h[0] && (k + 2 <= int'(q_size))
                && brival_flag(h))
                brival_clr[8*k +: 16] = 16'hFFFF;
        end
    end

    // ------------------------------------- FD1149 vblank writes (darkedge)
    // Dark Edge carries an FD1149 too (317-0204), as undumped as
    // Burning Rival's (docs/darkedge-bringup.md §2). MAME models it with a hook
    // that runs at every vblank-in (segas32_m.cpp darkedge_fd1149_vblank,
    // called from start_of_vblank_int): word 0 to $20F072 and $20F082, and
    // if byte $20A12C is nonzero it is decremented, with byte $20A12E set
    // to 1 when it reaches 0. The program uses $20F072 as a request flag
    // (set after its write to $A00000, work skipped while it is still set)
    // and $20A12C as a frame countdown.
    //   The module has bus access, so the core does what such a module
    // would: it takes the bus between V60 bus cycles and does the writes.
    // It starts only from A_IDLE with no strobe this clk and none queued in
    // the bus unit (bcu_pend low), so the bus unit cannot strobe at the
    // same edge; bus_hold is high for the four states that follow, which
    // holds the next strobe off. The hook never writes mem_rdata, so a V60
    // read that has finished but is not yet captured keeps its data.
    // MAME runs the hook between V60 instructions; here it can fall
    // between the bus cycles of one instruction. No instruction the
    // program uses on these four bytes is a read-modify-write.
    localparam logic [13:0] FD_W072 = 14'h3C1C;   // $20F072 >> 2, lanes 2-3
    localparam logic [13:0] FD_W082 = 14'h3C20;   // $20F082 >> 2, lanes 2-3
    localparam logic [13:0] FD_W12C = 14'h284B;   // $20A12C >> 2: lane 0 =
                                                  // $A12C, lane 2 = $A12E
    // Four states: A_FD0 writes $F072 and sets up the $A12C read, A_FD1
    // writes $F082, A_FD2 waits, A_FD3 has the byte (A_WRAMX..A_WRAM2's
    // read timing) and writes the countdown back.
    logic fd_pend;                   // a vblank-in is owed its writes

    // ------------------------------- FD1149 vblank writes (f1lap)
    // F1 Super Lap (f1lap, f1lapj) carries FD1149 317-0210 (MAME's header
    // above ROM_START(f1lap)), undumped like the others. MAME's hook, run
    // at every vblank-in (segas32_m.cpp f1lap_fd1149_vblank): byte 0 to
    // $20F7C6, and if byte $20EE81 reads $FF it is set to 0 ("needed to
    // start a game"). The factory-unprotected set f1lapt has no hook and
    // does not get this model (MAME init_f1lapt). The two programs are
    // different builds, not a patch of one another, so unlike SegaSonic's
    // the module's effect is MAME's reading, not one proved from the code
    // (docs/f1lap-bringup.md; Q57).
    //   The module takes the bus exactly as Dark Edge's does (fd_go, the
    // same four-state shape and read timing):
    //   A_FL0  $20F7C6 = 0; set up the read of $20EE80 (lane 1 = $EE81)
    //   A_FL1  BRAM read      A_FL2  OREGA stage
    //   A_FL3  $20EE81 = 0 if it read $FF; release the bus
    // As for Dark Edge, MAME runs the hook between V60 instructions and
    // here it can fall between the bus cycles of one instruction.
    localparam logic [13:0] FL_WF7C4 = 14'h3DF1;  // $20F7C6 >> 2, lane 2
    localparam logic [13:0] FL_WEE80 = 14'h3BA0;  // $20EE81 >> 2, lane 1

    // ----------------------------------- FD1149 state copy (dbzvrvs)
    // Dragon Ball Z: V.R. V.S. carries FD1149 317-0215/0217 (MAME's header
    // above ROM_START(dbzvrvs)), undumped like the others. MAME's handlers
    // on $A00000-$A7FFFF (segas32_m.cpp dbzvrvs_protection_r/_w): a read
    // returns $FFFF, and a write, at any address and of any value, copies
    // the work RAM word at $200044 to $2080C8. What the game does with it
    // (MAME latest master, tools/mame/dbzvrvs_probe.lua;
    // docs/dbzvrvs-bringup.md §5): once a frame, in its vblank handler,
    // it writes $1800 to $A00000 and polls $A00001 until bit 7 reads 1
    // (0A572C: mov.h #1800, A00000 / test.b A00001 / bp), and the main
    // loop dispatches on the word at $2080C8 (08060C), which nothing else
    // writes. $200044 is the state the V60 asks for, so the module is the
    // latch that makes a requested state current. Without the copy the
    // game never leaves state 0 (a blank attract screen). The real
    // module's timing and its reply to the $1800 command are not known
    // (Q60); here, as in MAME, the copy is part of the trigger write and
    // the window always reads ready.
    //   The core runs it as SegaSonic's level load runs: after the V60's
    // write (which goes nowhere: the window has no RAM) it holds the bus
    // for four states, so the V60 cannot read $2080C8 before the copy:
    //   A_DZ0  set up the read of $200044 (lanes 0-1)
    //   A_DZ1  BRAM read      A_DZ2  OREGA stage
    //   A_DZ3  $2080C8/C9 = the word; release the bus
    localparam logic [13:0] DZ_W0044 = 14'h0011;  // $200044 >> 2, lanes 0-1
    localparam logic [13:0] DZ_W80C8 = 14'h2032;  // $2080C8 >> 2, lanes 0-1

    // ---------------------------------------- FD1149 level load (sonic)
    // SegaSonic rev C carries an FD1149, 317-0213 (MAME's comment above
    // ROM_START(sonic)). MAME models it as a write handler on $20E5C4-5
    // (segas32_m.cpp sonic_level_load_protection): the word written there
    // is the count of cleared stages n; the module sets $20F06E to the next
    // stage, 7 for n = 0 and otherwise the BIG-endian halfword at program
    // ROM $263A + 2n - 2, and clears $20F0BC-$20F0BF. The unprotected
    // prototype (sonicp) does exactly these three things in software in the
    // same routine, and rev C is that code with them removed
    // (docs/sonic-bringup.md §5.2), so the effect is settled; how the real
    // module sees the write and where it reads the table are not (Q49).
    //   The core runs it as part of the trigger write: A_WRAMX does the
    // V60's write as usual, then instead of releasing the bus it runs
    // A_SN0-A_SN6, so the V60 cannot read $20F06E before the result is
    // there (the game's first read is a few dozen instructions later, PC
    // 0008D7), matching MAME, where the handler is part of the write.
    //   A_SN0  the write lands; set up the read of the $20E5C4 word (a byte
    //          write still triggers, and MAME then uses the whole word)
    //   A_SN1/2  BRAM read latency (A_WRAM1/1B)
    //   A_SN3  n in hand; n = 0 -> level 7, else point the ROM data
    //          adapter at the table entry (romd_pc follows q_addr)
    //   A_SN4  wait for the ROM window
    //   A_SN5  $20F06E = level, $20F0BC/BD = 0
    //   A_SN6  $20F0BE/BF = 0, release the bus
    localparam logic [23:0] SN_TRIG  = 24'h20E5C4;
    localparam logic [13:0] SN_WE5C4 = 14'h3971;  // $20E5C4 >> 2, lanes 0-1
    localparam logic [13:0] SN_WF06C = 14'h3C1B;  // $20F06E: lanes 2-3
    localparam logic [13:0] SN_WF0BC = 14'h3C2F;  // $20F0BC-BF: lanes 0-3
    localparam logic [23:0] SN_TABLE = 24'h00263A;
    // This V60 write touches $20E5C4/5: its bytes [q_addr, q_addr + q_size)
    // overlap them. With q_size <= 4 that means a start in $20E5C0-7 at
    // byte 4 or 5, or at byte 0-3 running past byte 3. (Written as a 21-bit
    // compare and a 4-bit sum, not two 24-bit adds: the add form tripped a
    // Quartus 17 quartus_map internal error, docs/sonic-bringup.md §6.)
    logic        sn_trig;
    logic [3:0]  sn_end;
    assign sn_end  = {1'b0, q_addr[2:0]} + {1'b0, q_size};
    assign sn_trig = prot_sonic && q_addr[23:3] == SN_TRIG[23:3]
                  && (q_addr[2] ? !q_addr[1] : sn_end > 4'd4);
    logic [15:0] sn_level;

    // ------------------------------------- FD1149 browser hook (jleague)
    // The J.League 1994 (jleague, jleagueo) carries FD1149 317-0222 (MAME's
    // header above ROM_START(jleague); svs's header names the same part and
    // MAME gives svs no hook). Undumped like the others. MAME's write
    // handler on work RAM $20F700-$20F705 (segas32_m.cpp
    // jleague_protection_w) lets the write land, then, with `data` the
    // handler's raw 16-bit argument:
    //   offset 0 ($20F700): byte $20F708 = the low byte of the word at
    //                       program ROM $7BBC0 + 2*data ("map team browser
    //                       selection to opponent browser selection")
    //   offset 2 ($20F704): byte $200016 = data & $FF ("move on to team
    //                       browser")
    // The original release (jleagueo) needs it: START at the mode menu
    // writes 8 to $20F704 (07855C) and the game waits for $200016 to become
    // 8; picking a team writes its number to $20F700 (078AC2) and the
    // opponent browser reads $20F708 (07894C). Rev A (jleague) does both in
    // software (07855F `mov.b #8, 16[R25]`; 078AB6 a byte table at $7BB90),
    // and that table is exactly MAME's rule on jleagueo's word table at
    // $7BBC0 for the 12 teams, so the effect is settled the way SegaSonic's
    // is; how the module sees the write is not (docs/jleague-bringup.md §5,
    // Q62). Rev A reaches the hook only through its boot RAM clear (0601E6),
    // whose next writes overwrite both results with 0.
    //   The bus unit gives the fabric MAME's handler calls one for one: a
    // byte at any address or an even-aligned word (v60_bcu split table).
    // A word's `data` is the word; a byte's is the byte in its own lane
    // (MAME shifts a byte into the lane its address selects), so a byte
    // at $20F701/$20F705 has data = byte << 8.
    //   The core runs it as part of the trigger write, as SegaSonic's:
    //   A_WRAMX  the V60's write lands; offset 2 writes $200016 (lane 2 of
    //            its word, a lane the trigger write never uses, so the same
    //            clk); offset 0 points the ROM data adapter at the table
    //            entry (romd_pc follows q_addr)
    //   A_JL     wait for the ROM window; $20F708 = its first byte (the
    //            low byte of the little-endian word); release the bus
    localparam logic [22:0] JL_T700  = 23'h107B80;  // $20F700 >> 1
    localparam logic [22:0] JL_T704  = 23'h107B82;  // $20F704 >> 1
    localparam logic [13:0] JL_W708  = 14'h3DC2;    // $20F708 >> 2, lane 0
    localparam logic [13:0] JL_W016  = 14'h0005;    // $200016 >> 2, lane 2
    localparam logic [23:0] JL_TABLE = 24'h07BBC0;
    logic        jl_t0, jl_t2;
    logic [15:0] jl_data;
    assign jl_t0 = prot_jleague && q_addr[23:1] == JL_T700;
    assign jl_t2 = prot_jleague && q_addr[23:1] == JL_T704;
    assign jl_data = (q_size != 3'd1) ? q_wdata[15:0]
                   : q_addr[0]        ? {q_wdata[7:0], 8'h00}
                                      : {8'h00, q_wdata[7:0]};

    // wram unaligned assembly (q_addr-based, captured in A_WRAM2)
    logic [63:0] wram_pair;
    assign wram_pair = {wram_qb, wram_qa};
    logic [31:0] wram_bytes;
    always_comb begin
        unique case (q_addr[1:0])
            2'd0: wram_bytes = wram_pair[31:0];
            2'd1: wram_bytes = wram_pair[39:8];
            2'd2: wram_bytes = wram_pair[47:16];
            2'd3: wram_bytes = wram_pair[55:24];
        endcase
    end


    // --------------------------------------------- serialized targets
    logic       word_port;           // 16-bit-lane target
    assign word_port = (q_reg == R_VID) || (q_reg == R_SPRCTL) ||
                       (q_reg == R_SPRRAM) || (q_reg == R_BRG) ||
                       (q_reg == R_DSP);

    // Register-class word ports read back something other than what was
    // written (mixer registers read $FFFF, sprite control reads live
    // status), so their byte writes carry byte strobes (o_bsel) instead of
    // a read-merge-write, which would rewrite the other byte; on sprite
    // control that could re-fire a trigger bit. RAM-class targets (VRAM,
    // palette, sprite RAM) use read-merge-write.
    logic       reg_class;
    assign reg_class = (q_reg == R_SPRCTL) || (q_reg == R_DSP)
                     || (q_reg == R_VID && q_addr[23:16] == 8'h61);

    // Odd-address word/dword accesses to word ports go byte by byte, as
    // the real V60 splits unaligned cycles into byte-enabled halves.
    // Aligned accesses walk 16-bit lanes.
    logic       byte_lanes;
    assign byte_lanes = word_port && (q_size == 3'd1 || q_addr[0]);

    // byte write to a RAM-class 16-bit port = read-modify-write;
    // pass 1 reads the old word (we suppressed), pass 2 writes the
    // merged word. Register-class byte writes skip RMW entirely.
    // VRAM proper ($300000-$3FFFFF) takes byte writes as single lane
    // writes, like the real board: the 315-5387 drives two write strobes
    // to its four 64Kx4 VRAMs, EWR for the DQ0-7 pair and OWR for the
    // DQ8-15 pair (schematics sheet 2/9, IC68-71 /WE nets), and takes the
    // V60's byte enable and A0 on its CPU side, so a byte write is one
    // VRAM cycle with no read. The on-chip VRAM is two 8-bit lane RAMs
    // and the SDRAM VRAM cache is byte-masked, so both honour vid_bsel.
    // The SDRAM mask rides A12:A11 (s32_sdram sd_dqm): until 2026-11-01 it
    // did not, and these lane writes garbled VRAM on silicon.
    // The palette keeps the read-first merge: sheet 5/9 gives the 315-5388
    // one write strobe per 8Kx8 SRAM pair and no byte enable on its CPU
    // side, so a byte write there is not a native lane write (2026-10-31,
    // docs/OPEN-QUESTIONS.md Q56).
    logic       vram_lane;
    assign vram_lane = (q_reg == R_VID) && (q_addr[23:20] == 4'h3);
    // Sprite RAM byte writes are lane writes too: sheet 3/9 gives the
    // 315-5386 BUBE and BA0 on its CPU side and two write strobes
    // (RWE0/RWE1) to its RAM pairs. Alien3 decodes sprite data into it a
    // byte at a time (0A48D0, `mov.b [R10+],[R11+]`) and Rad Rally inserts
    // bit fields there (0F88D6, insbfr), so the lane path is exercised.
    logic       spr_lane;
    assign spr_lane  = (q_reg == R_SPRRAM);
    // The bridge RAM takes byte writes as lane writes as well (MAME's 16-bit
    // handler applies mem_mask: COMBINE_DATA in dual_pcb_comms_w); f1en
    // writes it a byte at a time (FF63CA, FF6431, FE7EFB).
    logic       brg_lane;
    assign brg_lane  = (q_reg == R_BRG);
    logic       rmw_req;
    assign rmw_req = q_we && byte_lanes && !reg_class && !vram_lane && !spr_lane
                   && !brg_lane;
    logic       rmw_rd;              // in the read pass right now
    assign rmw_rd = rmw_req && !rmw_done;

    // A sub-bus access that needs two A_SUB_P passes runs one clk past the
    // V60's T3 sample even with zero-wait memories (strobe at accept+2,
    // five one-clk states per pass, done at accept+8 for one pass and +12
    // for two, against a T3 sample at +12), so the ideal machine pays ONE
    // T3 wait slot on it natively (measured 2026-10-31: exactly one per
    // decompressor VRAM byte write, sim/pt_rom, while VRAM byte writes
    // were still read-first; they are lane writes now, see vram_lane and
    // spr_lane). The reachable two-pass cases are a byte write to the
    // palette (read first) and a 16-bit access to a byte port: the bus
    // unit never hands the fabric more than
    // 16 bits, even-aligned, so q_size is 1 or 2 and nothing takes three
    // passes (if that ever changed, the per-cycle bound in s32_sys's
    // wait-debt clock would loosen by the extra passes). The board's
    // wait-debt clock must not charge that native slot: it charges the T3
    // slots of a cycle beyond wait_native, and only in cycles that saw an
    // emulated hold. Only serialized (sub-bus) targets can take two passes;
    // ROM, work RAM and the open/RNG/ETMG paths never wait natively.
    wire sub_tgt   = !(q_reg == R_ROM || q_reg == R_WRAM || q_reg == R_OPEN
                       || q_reg == R_RNG || q_reg == R_ETMG || q_reg == R_DZ);
    wire sub_multi = rmw_req
                   || ((word_port && !byte_lanes) ? (q_size > 3'd2) : (q_size > 3'd1));
    // (A standard cycle's fourth clock covers the second pass: only a
    // short-cycle region, which none of the games uses, waits natively.)
    assign wait_native = sub_tgt && sub_multi
                      && (etmg_xs(etmg[q_addr[23:20]]) == 2'd0);

    logic [23:0] sub_a;
    assign sub_a = q_addr + {21'd0, lane};

    // byte value of the current write lane
    logic [7:0] wr_byte;
    assign wr_byte = q_wdata[8*lane +: 8];

    // word value of the current write lane: byte lanes merge into the
    // RMW word (RAM-class) or replicate the byte under o_bsel
    // (register-class); aligned lanes take the straight 16-bit slice
    logic [15:0] wr_word;
    always_comb begin
        if (byte_lanes)
            wr_word = (reg_class || vram_lane || spr_lane || brg_lane) ? {2{wr_byte}}
                    : sub_a[0] ? {wr_byte, rmw_word[7:0]}
                               : {rmw_word[15:8], wr_byte};
        else
            wr_word = q_wdata[16*lane[2:1] +: 16];
    end

    // ------------------------------------- registered port outputs
    // Every signal leaving this module for a serialized port comes straight
    // from a register. Driven from the sub_a adder and the wr_word merge
    // logic instead, address and data were corrupted on the FPGA even
    // though timing analysis passed. A_SUB_P loads these registers from
    // the held q_* values, so the A_SUB strobe is a clean register-to-
    // register hop.
    logic [23:0] o_addr;
    logic [15:0] o_wword;
    logic [7:0]  o_wbyte;
    logic [1:0]  o_bsel;    // byte strobes: reg-class, VRAM and sprite RAM
                            // (2'b11 for word/RMW-merged writes)
    logic        o_we;      // effective we (RMW pass 1 reads: 0)
    logic        o_stb;     // 1 exactly during A_SUB
    logic        o_more;    // another byte lane of this access follows
                            // (the 315-5385 sees one bus cycle; Q10)

    // current serialized read byte/word
    logic [7:0]  sub_rd8;
    always_comb begin
        unique case (q_reg)
            R_SHM:   sub_rd8 = shm_rdata;
            R_DPRAM: sub_rd8 = o_addr[0] ? 8'hFF : dp_rdata;
            R_IO:    sub_rd8 = o_addr[0] ? 8'hFF : io_rdata;
            R_PPI:   sub_rd8 = o_addr[0] ? 8'hFF : ppi_rdata;
            R_TRK:   sub_rd8 = o_addr[0] ? 8'hFF : trk_rdata;
            R_ADC:   sub_rd8 = o_addr[0] ? 8'hFF : adc_rdata;
            R_IC:    sub_rd8 = ic_rdata;
            default: sub_rd8 = 8'hFF;
        endcase
    end
    logic [15:0] sub_rd16;
    assign sub_rd16 = (q_reg == R_VID)    ? vid_rdata
                    : (q_reg == R_SPRCTL) ? sc_rdata
                    : (q_reg == R_BRG)    ? brg_rdata
                    : (q_reg == R_DSP)    ? dsp_q
                    :                       spm_rdata;

    // port strobes: asserted for exactly the A_SUB cycle. Every value here
    // is a registered copy (o_*, q_reg); keep it that way (see above).
    always_comb begin
        shm_sel = 1'b0; shm_we = 1'b0;
        shm_addr = o_addr[12:0]; shm_wdata = o_wbyte;
        dp_sel = 1'b0; dp_we = 1'b0;
        dp_addr = o_addr[11:1]; dp_wdata = o_wbyte;
        io_sel = 1'b0; io_we = 1'b0;
        io_offset = o_addr[6:1]; io_wdata = o_wbyte;
        ppi_sel = 1'b0; ppi_we = 1'b0;
        ppi_offset = o_addr[2:1]; ppi_wdata = o_wbyte;
        trk_sel = 1'b0; trk_we = 1'b0;
        trk_offset = {o_addr[4:3], o_addr[2:1]};
        adc_sel = 1'b0; adc_we = 1'b0;
        adc_offset = o_addr[2:1];
        ic_sel = 1'b0; ic_we = 1'b0;
        ic_addr = o_addr[3:0]; ic_wdata = o_wbyte; ic_more = o_more;
        vid_sel = 1'b0; vid_we = 1'b0;
        // 6xxxxx palette/mixer mirrors fold to the base 128KB window:
        // s32_video decodes [23:16] == 60/61, so [19:17] is cleared here
        vid_addr = (o_addr[23:20] == 4'h6)
                   ? {4'h6, 3'b000, o_addr[16:1]}
                   : o_addr[23:1];
        vid_wdata = o_wword;
        vid_bsel = o_bsel;
        sc_sel = 1'b0; sc_we = 1'b0;
        sc_addr = o_addr[3:1]; sc_wdata = o_wword;
        sc_bsel = o_bsel;
        // The sprite RAM is the one exception to the o_* rule: it is
        // inside this module (no long route to protect), and driving it
        // from the registered copies makes Quartus 17 build the 64K x 16
        // array twice, which does not fit. During the strobe these
        // values equal the o_* copies, so the behaviour is the same.
        spm_sel = 1'b0; spm_we = 1'b0;
        spm_addr = sub_a[16:1]; spm_wdata = wr_word;
        spm_bsel = (byte_lanes && spr_lane) ? (sub_a[0] ? 2'b10 : 2'b01) : 2'b11;
        // the bridge RAM, like the sprite RAM, is inside this module
        brg_sel = 1'b0; brg_we = 1'b0;
        brg_addr = sub_a[15:1]; brg_wdata = wr_word;
        brg_bsel = (byte_lanes && brg_lane) ? (sub_a[0] ? 2'b10 : 2'b01) : 2'b11;
        dsp_sel_p = 1'b0;

        if (o_stb) begin
            unique case (q_reg)
                R_SHM:    begin shm_sel = 1'b1; shm_we = o_we; end
                R_DPRAM:  if (!o_addr[0]) begin dp_sel = 1'b1; dp_we = o_we; end
                R_IO:     if (!o_addr[0]) begin io_sel = 1'b1; io_we = o_we; end
                R_PPI:    if (!o_addr[0]) begin ppi_sel = 1'b1; ppi_we = o_we; end
                R_TRK:    if (!o_addr[0]) begin trk_sel = 1'b1; trk_we = o_we; end
                R_ADC:    if (!o_addr[0]) begin adc_sel = 1'b1; adc_we = o_we; end
                R_IC:     begin ic_sel = 1'b1; ic_we = o_we; end
                R_VID:    begin vid_sel = 1'b1; vid_we = o_we; end
                R_SPRCTL: begin sc_sel = 1'b1; sc_we = o_we; end
                R_SPRRAM: begin spm_sel = 1'b1; spm_we = o_we; end
                R_BRG:    begin brg_sel = 1'b1; brg_we = o_we; end
                R_DSP:    dsp_sel_p = 1'b1;
                default: ;
            endcase
        end
    end

    // ------------------------------------------------- DSP board
    // Air Rescue's 837-8341 (dsp_board) sits where the other games'
    // protection parts do, so it takes the $A00000-$A7FFFF window. MAME maps
    // it at $A00000-$A00007 only (init_arescue); the rest of the window
    // reads open bus here, and writes there are dropped. It is a register
    // port: what reads back is not what was written, so a byte write carries
    // its strobe (reg_class), never a read-merge-write. The read is
    // registered at the strobe, as the bridge RAM's.
    logic        dsp_hit;
    assign dsp_hit = (o_addr[18:3] == 16'd0);
    s32_dspbd u_dspbd (
        .clk(clk), .rst(rst || !dsp_board),
        // the load is not gated on dsp_board: the .mra may deliver the ROM
        // before the board descriptor. On other games the V25 program lands
        // in the DSP's RAMs and the DSP stays in reset.
        .ld_we(dsp_ld_we), .ld_addr(dsp_ld_addr),
        .ld_data(dsp_ld_data),
        .sel(dsp_sel_p && dsp_hit), .we(o_we), .woff(o_addr[2:1]),
        .bsel(o_bsel), .wdata(o_wword), .rdata(dsp_rd)
    );
    always_ff @(posedge clk)
        if (dsp_sel_p) dsp_q <= dsp_hit ? dsp_rd : 16'hFFFF;

    // ------------------------------------------------------- main FSM
    // The bus unit raises a one-cycle strobe per bus cycle and waits while
    // bus_hold is high, so every strobe seen in A_IDLE is a new request.
    logic req_new;
    assign req_new = (mem_re || mem_we);
    // the FD1149 takes the bus (see "FD1149 vblank writes")
    wire  fd_go = fd_pend && !req_new && !bcu_pend;

    // ------------------------------------------ random number generator
    // $D80000-$DFFFFF: free-running 16-bit maximal-length Galois LFSR
    // (x^16+x^15+x^13+x^4+1, taps $B400, period 65535), stepped every clk,
    // so it "updates faster than the CPU can read" (s32tech, I/O area).
    // A write seeds it from wdata[15:0] (0 becomes $FFFF, since an all-zero
    // LFSR would lock up). The bus unit splits a dword read into two word
    // cycles, so the CPU sees two successive values. Updated in the FSM
    // below, where a seed write overrides the free run.
    logic [15:0] rng_q = 16'hACE1;
    wire  [15:0] rng_next = {1'b0, rng_q[15:1]}
                            ^ (rng_q[0] ? 16'hB400 : 16'd0);

    always_ff @(posedge clk) begin
        wram_wen <= 4'd0;
        o_stb    <= 1'b0;          // 1 exactly for each A_SUB cycle
        rng_q    <= rng_next;      // free-runs through reset too

        if (rst) begin
            ast <= A_IDLE;
            romf_pc_r <= 24'd0;
            fd_pend <= 1'b0;
        end else begin
            if (fd_vbl && (prot_darkedge || prot_f1lap)) fd_pend <= 1'b1;
            else if (ast == A_IDLE && fd_go) fd_pend <= 1'b0;

            unique case (ast)
                A_IDLE: if (req_new && v60_ph) begin
                    q_addr  <= p;
                    q_wdata <= mem_wdata;
                    q_size  <= mem_size;
                    q_we    <= mem_we;
                    q_reg   <= region_of(p);
                    q_fetch <= mem_fetch;
                    if (mem_fetch) romf_pc_r <= p;        // warm the frf path
                    lane    <= 3'd0;
                    acc     <= 32'hFFFFFFFF;
                    // cleared on every request, not just serialized
                    // ones: gating it on region_of(p) would put the
                    // whole decode on a timing-critical enable
                    rmw_done <= 1'b0;
                    unique case (region_of(p))
                        R_ROM: begin
                            // reads wait for the ROM window. Writes are
                            // dropped but still take the A_OPENW cycle:
                            // the bus unit detects completion as
                            // bus_hold rising then falling, so every
                            // request must leave A_IDLE for at least one
                            // cycle
                            if (!mem_we) ast <= A_ROMW;
                            else         ast <= A_OPENW;
                        end
                        R_OPEN: begin
                            // reads return $FFFF...; writes are dropped.
                            // Both take one cycle (see R_ROM)
                            ast <= A_OPENW;
                        end
                        R_DZ:
                            // reads $FFFF (A_OPENW); a write runs the
                            // FD1149's state copy
                            ast <= mem_we ? A_DZ0 : A_OPENW;
                        R_RNG: begin
                            // read returns the value in A_OPENW; a
                            // write seeds the generator here
                            ast <= A_OPENW;
                            if (mem_we)
                                rng_q <= (mem_wdata[15:0] == 16'd0)
                                         ? 16'hFFFF : mem_wdata[15:0];
                        end
                        R_ETMG: begin
                            // 315-5385 timing register: read in A_OPENW;
                            // a write stores the addressed 2-bit field
                            ast <= A_OPENW;
                            if (mem_we) etmg[p[3:0]] <= mem_wdata[1:0];
                        end
                        R_WRAM:
                            // address setup and the read/write split
                            // happen one state later, from the
                            // registered q_* copies, which keeps the
                            // CPU's address logic off the RAM inputs
                            ast <= A_WRAMX;
                        default:
                            // serialized narrow target; rmw_req
                            // (comb from the q_* copies) decides the
                            // read-first pass. A_SUB_P registers the
                            // port outputs first.
                            ast <= A_SUB_P;
                    endcase
                end else if (fd_go)
                    ast <= prot_f1lap ? A_FL0 : A_FD0;

                // FD1149 vblank writes (Dark Edge): see the block above
                A_FD0: begin                // $20F072 = 0; read $20A12C
                    for (int l = 2; l < 4; l = l + 1) begin
                        wram_wen[l]   <= 1'b1;
                        wram_waddr[l] <= FD_W072;
                        wram_wd[l]    <= 8'd0;
                    end
                    wram_aa <= FD_W12C;     // lane 0 is not written here
                    ast <= A_FD1;
                end
                A_FD1: begin                // $20F082 = 0
                    for (int l = 2; l < 4; l = l + 1) begin
                        wram_wen[l]   <= 1'b1;
                        wram_waddr[l] <= FD_W082;
                        wram_wd[l]    <= 8'd0;
                    end
                    ast <= A_FD2;
                end
                A_FD2: ast <= A_FD3;        // OREGA stage
                A_FD3: begin                // countdown byte in lane 0
                    if (wram_qa[7:0] != 8'd0) begin
                        wram_wen[0]   <= 1'b1;
                        wram_waddr[0] <= FD_W12C;
                        wram_wd[0]    <= wram_qa[7:0] - 8'd1;
                        if (wram_qa[7:0] == 8'd1) begin   // reached 0:
                            wram_wen[2]   <= 1'b1;        // $20A12E = 1
                            wram_waddr[2] <= FD_W12C;
                            wram_wd[2]    <= 8'd1;
                        end
                    end
                    ast <= A_IDLE;
                end

                // FD1149 vblank writes (F1 Super Lap): see the block above
                A_FL0: begin                // $20F7C6 = 0; read $20EE81
                    wram_wen[2]   <= 1'b1;
                    wram_waddr[2] <= FL_WF7C4;
                    wram_wd[2]    <= 8'd0;
                    wram_aa <= FL_WEE80;    // lane 1 is not written here
                    ast <= A_FL1;
                end
                A_FL1: ast <= A_FL2;        // BRAM stage-1 read
                A_FL2: ast <= A_FL3;        // OREGA stage
                A_FL3: begin                // $20EE81 in lane 1
                    if (wram_qa[15:8] == 8'hFF) begin
                        wram_wen[1]   <= 1'b1;
                        wram_waddr[1] <= FL_WEE80;
                        wram_wd[1]    <= 8'd0;
                    end
                    ast <= A_IDLE;
                end

                // FD1149 state copy (Dragon Ball Z): see the block above
                A_DZ0: begin                // read $200044
                    wram_aa <= DZ_W0044;
                    ast <= A_DZ1;
                end
                A_DZ1: ast <= A_DZ2;        // BRAM stage-1 read
                A_DZ2: ast <= A_DZ3;        // OREGA stage
                A_DZ3: begin                // $2080C8 = $200044
                    for (int l = 0; l < 2; l = l + 1) begin
                        wram_wen[l]   <= 1'b1;
                        wram_waddr[l] <= DZ_W80C8;
                        wram_wd[l]    <= wram_qa[8*l +: 8];
                    end
                    ast <= A_IDLE;
                end

                // FD1149 level load (SegaSonic): see the block above
                A_SN0: begin                // trigger write lands now
                    wram_aa <= SN_WE5C4;
                    ast <= A_SN1;
                end
                A_SN1: ast <= A_SN2;        // BRAM stage-1 read
                A_SN2: ast <= A_SN3;        // OREGA stage
                A_SN3: begin
                    if (wram_qa[15:0] == 16'd0) begin
                        sn_level <= 16'd7;
                        ast <= A_SN5;
                    end else begin
                        q_addr <= SN_TABLE + {7'd0, wram_qa[15:0], 1'b0}
                                  - 24'd2;
                        ast <= A_SN4;
                    end
                end
                A_SN4:
                    if (!romd_hold) begin   // big-endian: high byte first
                        sn_level <= {romd_bytes[111:104], romd_bytes[103:96]};
                        ast <= A_SN5;
                    end
                A_SN5: begin
                    wram_wen[2] <= 1'b1; wram_waddr[2] <= SN_WF06C;
                    wram_wd[2] <= sn_level[7:0];
                    wram_wen[3] <= 1'b1; wram_waddr[3] <= SN_WF06C;
                    wram_wd[3] <= sn_level[15:8];
                    for (int l = 0; l < 2; l = l + 1) begin
                        wram_wen[l] <= 1'b1; wram_waddr[l] <= SN_WF0BC;
                        wram_wd[l] <= 8'd0;
                    end
                    ast <= A_SN6;
                end
                A_SN6: begin
                    for (int l = 2; l < 4; l = l + 1) begin
                        wram_wen[l] <= 1'b1; wram_waddr[l] <= SN_WF0BC;
                        wram_wd[l] <= 8'd0;
                    end
                    ast <= A_IDLE;
                end

                // FD1149 browser hook (J.League): see the block above
                A_JL:
                    if (!romd_hold) begin
                        wram_wen[0]   <= 1'b1;
                        wram_waddr[0] <= JL_W708;
                        wram_wd[0]    <= romd_bytes[111:104];
                        ast <= A_IDLE;
                    end

                A_ROMW:
                    // a fetch reads the romf window, a data read the
                    // romd window; wait for the selected adapter
                    if (q_fetch ? !romf_hold : !romd_hold) begin
                        mem_rdata <= q_fetch ? romf_dword : romd_dword;
                        ast <= A_IDLE;
                    end

                A_OPENW: begin
                    // open bus reads FF; the RNG returns its current
                    // value; a timing register returns its 2-bit field
                    mem_rdata <= (q_reg == R_RNG)  ? {2{rng_q}}
                               : (q_reg == R_ETMG) ? {30'd0, etmg[q_addr[3:0]]}
                                                   : 32'hFFFFFFFF;
                    ast <= A_IDLE;
                end

                A_WRAMX:                    // split off registered q_we
                    if (q_we) begin         // write: scatter the bytes
                        // byte i goes to lane (off+i)&3 in word
                        // (off+i)>>2; each lane written at most once
                        // (size <= 4)
                        for (int i = 0; i < 4; i = i + 1) begin
                            logic [2:0] j;
                            j = {1'b0, q_addr[1:0]} + i[2:0];
                            if (i[2:0] < q_size) begin
                                wram_wen[j[1:0]] <= 1'b1;
                                wram_waddr[j[1:0]] <=
                                    q_addr[15:2] + {13'd0, j[2]};
                                wram_wd[j[1:0]] <=
                                    q_wdata[8*i +: 8];
                            end
                        end
                        if (jl_t2) begin    // FD1149 (J.League): $200016
                            wram_wen[2]   <= 1'b1;
                            wram_waddr[2] <= JL_W016;
                            wram_wd[2]    <= jl_data[7:0];
                        end
                        if (jl_t0)          // ... or the table entry
                            q_addr <= JL_TABLE + {7'd0, jl_data, 1'b0};
                        ast <= sn_trig ? A_SN0 : jl_t0 ? A_JL : A_IDLE;
                    end else begin          // read: address setup
                        wram_aa <= q_addr[15:2];
                        wram_ab <= q_addr[15:2] + 14'd1;
                        ast <= A_WRAM1;
                    end

                A_WRAM1:  ast <= A_WRAM1B;  // BRAM stage-1 read lands
                A_WRAM1B: ast <= A_WRAM2;   // OREGA/OREGB output register
                A_WRAM2: begin
                    mem_rdata <= wram_bytes & ~brival_clr;
                    ast <= A_IDLE;
                end

                A_SUB_P: begin             // register the port outputs
                    o_addr  <= sub_a;
                    o_wbyte <= wr_byte;
                    o_wword <= wr_word;
                    // byte strobes for register-class, VRAM and sprite
                    // RAM byte lanes; palette RMW-merged writes are full
                    // words (the 315-5388 has no byte enable, sheet 5/9)
                    o_bsel  <= (byte_lanes && (reg_class || vram_lane || spr_lane))
                               ? (sub_a[0] ? 2'b10 : 2'b01)
                               : 2'b11;
                    o_we    <= q_we && !rmw_rd;
                    o_more  <= ({1'b0, lane} + 4'd1 < {1'b0, q_size});
                    o_stb   <= 1'b1;
                    ast     <= A_SUB;
                end
                A_SUB:   ast <= A_SUB_W;   // strobe cycle
                A_SUB_W:                    // sync data lands
                    // wait here for the VRAM cache (miss fill or
                    // write-through); vid_hold is 0 on a hit
                    if (!vid_hold) ast <= A_SUB_L;
                A_SUB_L: begin
                    if (rmw_rd) begin
                        rmw_word <= sub_rd16;
                        rmw_done <= 1'b1;
                        ast <= A_SUB_P;    // redo lane as the write
                    end else if (word_port && !byte_lanes) begin
                        // aligned word/dword: 16-bit lane walk
                        if (!q_we)
                            acc[16*lane[2:1] +: 16] <= sub_rd16;
                        if (q_size == 3'd4 && lane == 3'd0) begin
                            lane <= 3'd2;
                            ast <= A_SUB_P;
                        end else
                            ast <= A_DONE;
                    end else begin
                        // byte ports, and byte-lane word-port
                        // accesses: collect each addressed byte
                        if (!q_we)
                            acc[8*lane +: 8] <= word_port
                                ? (sub_a[0] ? sub_rd16[15:8]
                                            : sub_rd16[7:0])
                                : sub_rd8;
                        if ({1'b0, lane} + 4'd1 < {1'b0, q_size}) begin
                            lane <= lane + 3'd1;
                            rmw_done <= 1'b0;   // next lane RMWs afresh
                            ast <= A_SUB_P;
                        end else
                            ast <= A_DONE;
                    end
                end

                A_DONE: begin
                    // acc is already right-aligned for every narrow or
                    // unaligned access
                    if (!q_we)
                        mem_rdata <= acc;
                    ast <= A_IDLE;
                end

                default: ast <= A_IDLE;
            endcase
        end
    end


endmodule
