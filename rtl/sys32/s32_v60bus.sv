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
// "FD1149 vblank writes" block. SegaSonic's (prot_sonic): the "FD1149
// level load" block. SegaSonic's trackball board (trk_board): uPD4701A
// counters at I/O offsets 40-57 (R_TRK; s32_upd4701). Rad Mobile's A/D
// board (adc_board): an MSM6253 at I/O offsets 50-57 (R_ADC; s32_msm6253).

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
    input  logic        prot_sonic
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
    logic [15:0] spm_addr;
    logic [15:0] spm_wdata, spm_rdata;
    logic [15:0] sprram [0:65535];

    // Intel true-dual-port template: port A = CPU read/write, port B =
    // sprite engine read.
    always_ff @(posedge clk) begin        // port A: fabric
        if (spm_sel && spm_we) begin
            sprram[spm_addr] <= spm_wdata;
            spm_rdata <= spm_wdata;
        end else
            spm_rdata <= sprram[spm_addr];
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
            sr_rdata <= sprram[sr_addr_used];
    end

    // ------------------------------------------------- region decode
    logic [23:0] p;
    assign p = mem_addr[23:0];

    typedef enum logic [3:0] {
        R_ROM, R_WRAM, R_VID, R_SPRRAM, R_SPRCTL, R_SHM,
        R_DPRAM, R_IO, R_PPI, R_IC, R_RNG, R_ETMG, R_OPEN, R_TRK, R_ADC
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
        // Dark Edge's FD1149 answers the mailbox window instead: reads
        // $FFFF, writes ignored (MAME darkedge_protection_r/_w)
        else if (a[23:19] == 5'b10100 && prot_darkedge) region_of = R_OPEN;
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
    // "Memory timing": 0 = moderate, 1 = short, 2 = moderate, 3 = long wait).
    // How many clocks each setting means is not documented, so the values
    // are stored and read back but add no wait states (as in MAME).
    (* ramstyle = "logic" *) logic [1:0] etmg [0:15];  // 32 bits: not an M10K (corertlcleanup B1)
    initial begin
        // s32tech default: 00 00 03 02 02 00 00 02 00 00 00 00 03 02 00 00
        etmg[0]='d0; etmg[1]='d0; etmg[2]='d3; etmg[3]='d2;
        etmg[4]='d2; etmg[5]='d0; etmg[6]='d0; etmg[7]='d2;
        etmg[8]='d0; etmg[9]='d0; etmg[10]='d0; etmg[11]='d0;
        etmg[12]='d3; etmg[13]='d2; etmg[14]='d0; etmg[15]='d0;
    end

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
        A_SN0, A_SN1, A_SN2, A_SN3, A_SN4, A_SN5, A_SN6
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
                       (q_reg == R_SPRRAM);

    // Register-class word ports read back something other than what was
    // written (mixer registers read $FFFF, sprite control reads live
    // status), so their byte writes carry byte strobes (o_bsel) instead of
    // a read-merge-write, which would rewrite the other byte; on sprite
    // control that could re-fire a trigger bit. RAM-class targets (VRAM,
    // palette, sprite RAM) use read-merge-write.
    logic       reg_class;
    assign reg_class = (q_reg == R_SPRCTL)
                     || (q_reg == R_VID && q_addr[23:16] == 8'h61);

    // Odd-address word/dword accesses to word ports go byte by byte, as
    // the real V60 splits unaligned cycles into byte-enabled halves.
    // Aligned accesses walk 16-bit lanes.
    logic       byte_lanes;
    assign byte_lanes = word_port && (q_size == 3'd1 || q_addr[0]);

    // byte write to a RAM-class 16-bit port = read-modify-write;
    // pass 1 reads the old word (we suppressed), pass 2 writes the
    // merged word. Register-class byte writes skip RMW entirely.
    logic       rmw_req;
    assign rmw_req = q_we && byte_lanes && !reg_class;
    logic       rmw_rd;              // in the read pass right now
    assign rmw_rd = rmw_req && !rmw_done;

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
            wr_word = reg_class ? {2{wr_byte}}
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
    logic [1:0]  o_bsel;    // byte strobes to reg-class word ports
                            // (2'b11 for word/RMW-merged writes)
    logic        o_we;      // effective we (RMW pass 1 reads: 0)
    logic        o_stb;     // 1 exactly during A_SUB

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
        ic_addr = o_addr[3:0]; ic_wdata = o_wbyte;
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
                default: ;
            endcase
        end
    end

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
            if (fd_vbl && prot_darkedge) fd_pend <= 1'b1;
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
                    ast <= A_FD0;

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
                        ast <= sn_trig ? A_SN0 : A_IDLE;
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
                    // byte strobes only for register-class byte
                    // lanes; merged RAM writes are full words
                    o_bsel  <= (byte_lanes && reg_class)
                               ? (sub_a[0] ? 2'b10 : 2'b01)
                               : 2'b11;
                    o_we    <= q_we && !rmw_rd;
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
