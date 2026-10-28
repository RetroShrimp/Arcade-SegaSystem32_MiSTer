// s32_v25.sv — NEC V25 subset core for the System 32 V25 protection
// modules: Golden Axe's 315-5533-02 and Arabian Fight's (MAME builds both
// as SEGA_S32_V25_DEVICE; only the V25's opcode table differs). Executes
// the original mcu ROM: the ROM address-line scramble is undone
// combinationally on the fetch address and the per-instruction opcode
// encryption through a 256-entry LUT, exactly as the real module does
// (MAME decrypt_protrom + ga2_opcode_table / arf_opcode_table, selected
// by dec_arf). The implemented subset is the union of what the two tables
// define (28 + 32 entries, 32 distinct opcodes counting the 26 prefix;
// arf adds 03, 73, 74 and BA): an encrypted byte outside the selected
// table cannot be executed by this module at all.
//
// Timing (2026-10-25, for Arabian Fight, whose program serves the V60
// every frame, so its speed decides which V60 reads see a stale record;
// docs/arabfgt-scoping.md §5.2 and §10, OPEN-QUESTIONS Q44). Two NEC
// manuals: the V25/V35 hardware manual (U13030EJ) and the instruction
// manual (U12120EJ3V0UM00; local copies in docs_ref/).
//   * Clocks. cen is fX, the oscillator (10 MHz, MAME's V25 device
//     clock). The system clock fCLK = fX/2, /4 or /8 by PRC.PCK (hardware
//     ch.8.2); PRC resets to 4EH (/8) and is shadowed from the program's
//     own SFR write (FFFEB). Every count below is in fCLK ticks.
//   * Bus unit (BIU). One external bus cycle at a time: T1, TW x n, T2
//     (hardware ch.5, Fig.5-3), n from the 2-bit WTC field of the 128KB
//     block (blocks 6/7 share one): 00/01/10/11 = 0/1/2/2 waits (11 =
//     READY control; with PMC1 bit 7 clear READY reads as "always two
//     waits"). WTC resets to FFFFH and is shadowed from FFFE8/9. Internal
//     RAM is never waited (hardware A.3.2). Words are two byte cycles (an
//     8-bit bus). Read data is taken at T2.
//   * Prefetch queue (instruction manual C.2). 6 bytes; the BIU prefetches
//     whenever a byte is free and the bus is idle. An execution-unit data
//     access goes first, except that while the queue holds 2 bytes or
//     fewer a prefetch is forced ahead of it until 3 or more are queued.
//     A branch, call or return to a non-contiguous address clears the
//     queue and fetching restarts at the target; a prefetch already on
//     the bus completes and is discarded.
//   * Execution unit (EXU). Decoding takes bytes from the queue and waits
//     only when the queue is empty: the manual's clock table "does not
//     include prefetch time, predecode time" (2.2 (1)(a)), so decode adds
//     no clocks of its own. Execution then lasts the instruction's
//     Table 2-8 count (V25 columns, internal-RAM-enabled or -disabled by
//     PRC.RAMEN), during which its own data cycles run through the BIU; it
//     ends when that count has elapsed AND its data cycles are done
//     (Appendix C: an EXU stage waits for a slower bus stage). The queue
//     is cleared at the END of a taken transfer's count, because the
//     count excludes prefetch time (a pessimistic reading: the real
//     part may restart fetching earlier inside it).
//   * NOT modelled, because the manuals do not give it: the exact clock
//     inside the count at which each data cycle starts (all are issued as
//     soon as the decode completes, in program order), and pipeline-stage
//     granularity beyond "count vs bus" (NEC: desk calculation is
//     "extremely difficult"; measure with an in-circuit emulator).
//     ga2's program runs once at boot, so it never depended on any of this.
// Memory decode:
//   linear 0xxxx / F0000-FFDFF  ROM (swizzled, via the rom port)
//   1xxxx                       dpram left port (offset & 0x7FF)
//   FFE00-FFFFF                 512B internal RAM (SFR writes land
//                               here; no side effects needed)

module s32_v25 (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,          // fX, the oscillator (10 MHz from
                                      // s32_sys); time runs on fCLK =
                                      // fX / PCK ticks (see the header)
    input  logic        hold,         // freeze (ROM line refill in flight)
    input  logic        dec_arf,      // opcode table: 0 = ga2, 1 = Arabian
                                      // Fight (static per game: the .mra's
                                      // board descriptor bit 2)

    // original-dump ROM (64KB; combinational or 1-cycle registered)
    output logic [15:0] rom_addr,
    input  logic [7:0]  rom_data,
    output logic        rom_rd,       // current bus access targets ROM

    // dpram left port
    output logic        dp_sel,
    output logic        dp_we,
    output logic [10:0] dp_addr,
    output logic [7:0]  dp_wdata,
    input  logic [7:0]  dp_rdata
);

    // ---------------------------------------------- opcode decryption
    // ga2_opcode_table / arf_opcode_table (segas32_m.cpp); FF = an entry
    // the table leaves undefined (MAME decrypts those to 00, but neither
    // program executes one: tools/v25_trace_census.py). Both case lists
    // are checked against MAME's source by sim/s32_v25/check_tables.py.
    function automatic logic [7:0] decrypt (input logic [7:0] e,
                                            input logic arf);
        if (arf) case (e)
            8'h02: decrypt = 8'h43;  8'h06: decrypt = 8'h83;
            8'h0A: decrypt = 8'hEA;  8'h0D: decrypt = 8'hBC;
            8'h0E: decrypt = 8'h73;  8'h20: decrypt = 8'h3A;
            8'h23: decrypt = 8'hBE;  8'h2E: decrypt = 8'h80;
            8'h31: decrypt = 8'hB5;  8'h37: decrypt = 8'h26;
            8'h4B: decrypt = 8'hE8;  8'h4C: decrypt = 8'h8D;
            8'h4E: decrypt = 8'h8B;  8'h53: decrypt = 8'hFA;
            8'h55: decrypt = 8'h8A;  8'h77: decrypt = 8'hBA;
            8'h78: decrypt = 8'h88;  8'h97: decrypt = 8'hBB;
            8'hAD: decrypt = 8'h75;  8'hAF: decrypt = 8'hBF;
            8'hB8: decrypt = 8'h03;  8'hB9: decrypt = 8'h3B;
            8'hBA: decrypt = 8'h8E;  8'hBB: decrypt = 8'h74;
            8'hBE: decrypt = 8'h81;  8'hC3: decrypt = 8'hC3;
            8'hD7: decrypt = 8'hB9;  8'hD8: decrypt = 8'hB2;
            8'hDD: decrypt = 8'h49;  8'hE8: decrypt = 8'hEB;
            8'hFE: decrypt = 8'h02;  8'hFF: decrypt = 8'hB8;
            default: decrypt = 8'hFF;
        endcase
        else case (e)
            8'h02: decrypt = 8'hEA;  8'h05: decrypt = 8'h8B;
            8'h1F: decrypt = 8'hFA;  8'h2A: decrypt = 8'h3B;
            8'h2C: decrypt = 8'h49;  8'h35: decrypt = 8'hE8;
            8'h38: decrypt = 8'h75;  8'h3D: decrypt = 8'h3A;
            8'h44: decrypt = 8'h8D;  8'h4C: decrypt = 8'hBF;
            8'h4E: decrypt = 8'h88;  8'h53: decrypt = 8'h81;
            8'h70: decrypt = 8'h02;  8'h7F: decrypt = 8'hBC;
            8'h83: decrypt = 8'h8A;  8'h8A: decrypt = 8'h83;
            8'h9D: decrypt = 8'hB8;  8'h9E: decrypt = 8'h26;
            8'hAD: decrypt = 8'hB5;  8'hAF: decrypt = 8'hEB;
            8'hBB: decrypt = 8'hB2;  8'hC3: decrypt = 8'hC3;
            8'hD8: decrypt = 8'hB9;  8'hD9: decrypt = 8'hBB;
            8'hDB: decrypt = 8'h43;  8'hF2: decrypt = 8'h8E;
            8'hFB: decrypt = 8'hBE;  8'hFD: decrypt = 8'h80;
            default: decrypt = 8'hFF;
        endcase
    endfunction

    // ROM address-line descramble (MAME decrypt_protrom bitswap<16>)
    function automatic logic [15:0] swizzle (input logic [15:0] i);
        swizzle = {i[14], i[11], i[15], i[12], i[13], i[4], i[3],
                   i[7],  i[5],  i[10], i[2],  i[8],  i[9], i[6],
                   i[1],  i[0]};
    endfunction

    // ------------------------------------------------- architectural
    logic [15:0] reg16 [0:7];    // AW CW DW BW SP BP IX(SI) IY(DI)
    logic [15:0] sreg  [0:3];    // ES CS SS DS (8086 sreg encoding)
    logic [15:0] ip;             // EXU: IP of the next byte decoded
    // fl_s is kept up to date by every flag writer, but no instruction in
    // the implemented subset reads it yet (no JS/JNS/PUSHF in the programs
    // the core runs), so synthesis prunes it. Kept so the next branch on S
    // does not have to rebuild the flag logic.
    logic        fl_z, fl_s, fl_c;

    localparam AX = 3'd0, CX = 3'd1, DX = 3'd2, BX = 3'd3,
               SP = 3'd4, BP = 3'd5, SI = 3'd6, DI = 3'd7;
    localparam SEG_ES = 2'd0, SEG_CS = 2'd1, SEG_SS = 2'd2,
               SEG_DS = 2'd3;

    logic [7:0] iram [0:511];    // internal RAM/SFR page FFE00-FFFFF

    // ------------------------------------------------------ bus port
    // one shared byte port, owned by the BIU
    logic [19:0] bus_addr;
    logic        bus_we;
    logic [7:0]  bus_wdata;

    assign rom_addr = swizzle(bus_addr[15:0]);
    assign dp_sel   = (bus_addr[19:16] == 4'h1);
    assign dp_addr  = bus_addr[10:0];
    assign dp_wdata = bus_wdata;

    // the V25 internal RAM/SFR page overlays the top of memory for
    // DATA accesses only — instruction fetches always go external
    // (the reset vector at FFFF0 is fetched from ROM)
    logic is_fetch;
    logic in_iram, in_rom;
    assign in_iram = (bus_addr >= 20'hFFE00) && !is_fetch;
    assign in_rom  = (bus_addr[19:16] == 4'h0) ||
                     (bus_addr[19:16] == 4'hF && !in_iram);
    assign rom_rd = in_rom;

    logic [7:0] iram_q;
    logic       dp_we_r;
    assign dp_we = dp_we_r;

    wire  [7:0] bus_rd = in_rom ? rom_data : dp_sel ? dp_rdata : iram_q;

    // ------------------------------------------------- decode state
    logic        es_ovr;
    logic [7:0]  opc;
    logic [7:0]  mrm;
    logic [15:0] disp, imm;
    logic [15:0] ea_off;
    logic [1:0]  ea_seg;
    logic [15:0] rmval;          // memory/register operand value
    logic [15:0] wr_val;         // value being stored (memory path)
    logic [19:0] wr_lin;         // linear address for stores

    wire [1:0] mrm_mod = mrm[7:6];
    wire [2:0] mrm_reg = mrm[5:3];
    wire [2:0] mrm_rm  = mrm[2:0];

    // 8-bit register file view (8086: 0-3 = low bytes, 4-7 = high)
    function automatic logic [7:0] r8_get (input logic [2:0] n);
        r8_get = n[2] ? reg16[{1'b0, n[1:0]}][15:8]
                      : reg16[{1'b0, n[1:0]}][7:0];
    endfunction

    task automatic r8_set (input logic [2:0] n, input logic [7:0] v);
        if (n[2]) reg16[{1'b0, n[1:0]}][15:8] <= v;
        else      reg16[{1'b0, n[1:0]}][7:0]  <= v;
    endtask

    // modrm EA offset from current regs + disp
    function automatic logic [15:0] ea_base (input logic [2:0] rm);
        case (rm)
            3'd0: ea_base = reg16[BX] + reg16[SI];
            3'd1: ea_base = reg16[BX] + reg16[DI];
            3'd2: ea_base = reg16[BP] + reg16[SI];
            3'd3: ea_base = reg16[BP] + reg16[DI];
            3'd4: ea_base = reg16[SI];
            3'd5: ea_base = reg16[DI];
            3'd6: ea_base = reg16[BP];
            3'd7: ea_base = reg16[BX];
        endcase
    endfunction

    function automatic logic [1:0] ea_defseg (input logic [1:0] mod,
                                              input logic [2:0] rm);
        // BP-based forms default to SS ([disp16] mod=00 rm=6 is DS)
        if (rm == 3'd2 || rm == 3'd3 || (rm == 3'd6 && mod != 2'd0))
            ea_defseg = SEG_SS;
        else
            ea_defseg = SEG_DS;
    endfunction

    // immediate-group ALU (80/81/83 reg field, and the cmp/add ops)
    function automatic logic [17:0] grp_alu   // {c, z_ignore, res16}
        (input logic [2:0] sel, input logic [15:0] a,
         input logic [15:0] b, input logic wide);
        logic [16:0] r;
        case (sel)
            3'd0: r = {1'b0, a} + {1'b0, b};              // add
            3'd1: r = {1'b0, a | b};                       // or
            3'd2: r = {1'b0, a} + {1'b0, b} + {16'd0, fl_c}; // adc
            3'd3: r = {1'b0, a} - {1'b0, b} - {16'd0, fl_c}; // sbb
            3'd4: r = {1'b0, a & b};                       // and
            3'd5: r = {1'b0, a} - {1'b0, b};               // sub
            3'd6: r = {1'b0, a ^ b};                       // xor
            3'd7: r = {1'b0, a} - {1'b0, b};               // cmp
        endcase
        if (!wide)
            grp_alu = {r[8], 1'b0, 8'd0, r[7:0]};
        else
            grp_alu = {r[16], 1'b0, r[15:0]};
    endfunction

    task automatic set_zs (input logic [15:0] v, input logic wide);
        fl_z <= wide ? (v == 16'd0) : (v[7:0] == 8'd0);
        fl_s <= wide ? v[15] : v[7];
    endtask

    // --------------------------------------------------------- FSM
    // S_OP..S_I4 take one byte each from the prefetch queue (decode);
    // S_RD/S_WR/S_PUSH/S_POP hand one data request (a byte, or a word as
    // two back-to-back byte cycles) to the BIU and wait for it; S_FIN
    // waits out the instruction's Table 2-8 count.
    typedef enum logic [4:0] {
        S_OP, S_MOD, S_D1, S_D2, S_I1, S_I2, S_I3, S_I4,
        S_RD, S_RD_W, S_EXEC, S_WR, S_WR_W,
        S_PUSH, S_PUSH_W, S_POP, S_POP_W,
        S_FIN, S_HALT
    } state_e;
    state_e st;

    function automatic logic is_pop (input state_e s);
        is_pop = (s == S_OP) || (s == S_MOD) || (s == S_D1) ||
                 (s == S_D2) || (s == S_I1)  || (s == S_I2) ||
                 (s == S_I3) || (s == S_I4);
    endfunction

    // instruction classification (on the DECRYPTED opcode)
    function automatic logic has_modrm (input logic [7:0] o);
        has_modrm = (o == 8'h8B) || (o == 8'h8A) || (o == 8'h88) ||
                    (o == 8'h8D) || (o == 8'h8E) || (o == 8'h3B) ||
                    (o == 8'h3A) || (o == 8'h02) || (o == 8'h03) ||
                    (o == 8'h80) || (o == 8'h81) || (o == 8'h83);
    endfunction

    function automatic logic op_wide (input logic [7:0] o);
        op_wide = (o == 8'h8B) || (o == 8'h8D) || (o == 8'h8E) ||
                  (o == 8'h3B) || (o == 8'h03) || (o == 8'h81) ||
                  (o == 8'h83);
    endfunction

    // memory operand needed (loads; 88 is a pure store, 8D pure EA)
    function automatic logic op_loads (input logic [7:0] o);
        op_loads = (o == 8'h8B) || (o == 8'h8A) || (o == 8'h8E) ||
                   (o == 8'h3B) || (o == 8'h3A) || (o == 8'h02) ||
                   (o == 8'h03) || (o == 8'h80) || (o == 8'h81) ||
                   (o == 8'h83);
    endfunction

    logic [19:0] lin_ea;
    assign lin_ea = ({4'd0, sreg[ea_seg]} << 4) + {4'd0, ea_off};
    wire  [19:0] lin_sp = ({4'd0, sreg[SEG_SS]} << 4) + {4'd0, reg16[SP]};

    // gr: block-local ALU result, assigned with '=' and consumed in the same
    // clocked pass (never state; Verilator BLKSEQ is benign here)
    logic [17:0] gr;
    logic [15:0] pushv;

    // ------------------------------------- clock divider and bus waits
    logic [7:0]  prc;            // PRC shadow (FFFEB): [1:0] = PCK,
                                 // [6] = RAMEN
    logic [15:0] wtc;            // WTC shadow (FFFE9:FFFE8)
    logic [2:0]  cdiv;           // fX ticks within one fCLK
    wire  [2:0]  cdiv_last = (prc[1:0] == 2'b00) ? 3'd1     // fX/2
                           : (prc[1:0] == 2'b01) ? 3'd3     // fX/4
                           :                       3'd7;    // fX/8
    wire         ct = cen && !hold && (cdiv == cdiv_last);  // one fCLK

    // waits of an address (WTC block field; internal RAM 0)
    function automatic logic [1:0] waits (input logic [19:0] a,
                                          input logic internal);
        logic [1:0] f;
        if (internal) waits = 2'd0;
        else begin
            unique case (a[19:17])
                3'd0: f = wtc[1:0];   3'd1: f = wtc[3:2];
                3'd2: f = wtc[5:4];   3'd3: f = wtc[7:6];
                3'd4: f = wtc[9:8];   3'd5: f = wtc[11:10];
                default: f = wtc[13:12];                  // blocks 6 and 7
            endcase
            waits = (f == 2'b11) ? 2'd2 : f;
        end
    endfunction

    // data-cycle waits: the internal RAM page is never waited
    function automatic logic [1:0] dwaits (input logic [19:0] a);
        dwaits = waits(a, a >= 20'hFFE00);
    endfunction

    // Table 2-8 execution clocks (instruction manual pp.202-211, V25
    // columns), for the opcodes this module runs. ea = 3 for mod 00/01
    // (incl. direct), 4 for mod 10 (note (g)); t = the operand's waits.
    function automatic logic [5:0] exu_clocks
        (input logic [7:0] o, input logic [1:0] mod, input logic [2:0] rg,
         input logic [1:0] t, input logic taken, input logic ramen);
        logic [5:0] ea, t1, t2, t4;
        logic       mem;
        ea  = (mod == 2'b10) ? 6'd4 : 6'd3;
        t1  = {4'd0, t};
        t2  = {3'd0, t, 1'b0};
        t4  = {2'd0, t, 2'b0};
        mem = (mod != 2'b11);
        if (o[7:3] == 5'b10110)      exu_clocks = 6'd5;     // MOV r8,imm
        else if (o[7:3] == 5'b10111) exu_clocks = 6'd6;     // MOV r16,imm
        else case (o)
            8'h43, 8'h49: exu_clocks = 6'd2;                // INC/DEC r16
            8'hFA:        exu_clocks = 6'd4;                // DI
            8'hEB:        exu_clocks = 6'd12;               // BR short
            8'hEA:        exu_clocks = 6'd15;               // BR far
            8'h73, 8'h74, 8'h75:                            // Bcc short
                          exu_clocks = taken ? 6'd15 : 6'd8;
            8'hE8:        exu_clocks = ramen ? 6'd22 + t2   // CALL near
                                             : 6'd18 + t2;
            8'hC3:        exu_clocks = 6'd20 + t2;          // RET
            8'h8D:        exu_clocks = ea + 6'd2;           // LDEA
            8'h8E:        exu_clocks = mem ? ea + 6'd10 + t2 : 6'd4;
            8'h8B, 8'h3B, 8'h03:                            // word r,rm
                          exu_clocks = mem ? ea + 6'd8 + t2 : 6'd2;
            8'h8A, 8'h3A, 8'h02:                            // byte r,rm
                          exu_clocks = mem ? ea + 6'd6 + t1 : 6'd2;
            8'h88:        exu_clocks = !mem ? 6'd2          // MOV rm8,r8
                                     : ramen ? ea + 6'd4 + t1 : ea + 6'd2;
            8'h80:        exu_clocks = !mem ? 6'd5          // grp rm8,imm
                                     : (rg == 3'd7) ? ea + 6'd7 + t1
                                     : ramen ? ea + 6'd9 + t2
                                             : ea + 6'd7 + t2;
            8'h81, 8'h83: exu_clocks = !mem ? 6'd6          // grp rm16,imm
                                     : (rg == 3'd7) ? ea + 6'd10 + t2
                                     : ramen ? ea + 6'd14 + t4
                                             : ea + 6'd10 + t4;
            default:      exu_clocks = 6'd2;
        endcase
    endfunction

    // ------------------------------------------------ prefetch queue
    (* ramstyle = "logic" *) logic [7:0]  q [0:7];  // 6 used; 3-bit pointers wrap at 8 (64 bits: not an M10K)
    logic [2:0]  q_rd, q_wr;
    logic [2:0]  q_cnt;          // 0..6
    logic [15:0] f_ip;           // BIU: IP of the next byte to prefetch
    wire  [7:0]  q_head = q[q_rd];

    // BIU cycle in flight
    localparam logic [1:0] B_FETCH = 2'd0, B_READ = 2'd1, B_WRITE = 2'd2;
    logic        b_busy;
    logic [1:0]  b_kind;
    logic [1:0]  b_left;         // TW ticks still to run before T2
    logic        b_drop;         // fetch result discarded (queue cleared)
    wire         b_t2 = ct && b_busy && (b_left == 2'd0);

    // EXU data request (one at a time). A word is one request: the BIU
    // runs its two byte cycles (low byte first, ascending address) back to
    // back, as one bus-unit operation, with no prefetch between them.
    logic        x_req, x_we, x_word;
    logic [19:0] x_addr;
    logic [15:0] x_wdata, x_q;
    logic        x_done;         // the request's last T2 has passed
    logic        b_hi;           // the cycle in flight is a word's high byte
    logic        b_more;         // a word's high byte is due next

    // read completion tick, for benches (the dpram read is taken here)
    wire         rd_done = b_t2 && (b_kind == B_READ);

    // execution count
    logic [5:0]  e_el, e_need;
    logic        e_flush;        // clear the queue at S_FIN
    logic        halted;

    // the instruction ends this clk and clears the queue: no prefetch may
    // start on it (it would fetch at the old address into the new queue)
    wire         fin_flush = (st == S_FIN) && (e_el >= e_need) && e_flush;

    always_ff @(posedge clk) begin
        if (rst)
            cdiv <= 3'd0;
        else if (cen && !hold)
            cdiv <= (cdiv == cdiv_last) ? 3'd0 : cdiv + 3'd1;
    end

    always_ff @(posedge clk) begin
        logic       push, pop, flush;
        logic [7:0] pb;
        push = 1'b0; pop = 1'b0; flush = 1'b0; pb = 8'h00;

        // default bus: strobes last one clk
        bus_we   <= 1'b0;
        dp_we_r  <= 1'b0;
        iram_q   <= iram[bus_addr[8:0]];
        if (in_iram && bus_we) begin
            iram[bus_addr[8:0]] <= bus_wdata;
            unique case (bus_addr[8:0])                   // SFR shadows
                9'h1E8: wtc[7:0]  <= bus_wdata;
                9'h1E9: wtc[15:8] <= bus_wdata;
                9'h1EB: prc       <= bus_wdata;
                default: ;
            endcase
        end

        if (rst) begin
            st <= S_OP;
            ip <= 16'hFFF0;                 // V25 reset: CS:IP = F000:FFF0
            f_ip <= 16'hFFF0;
            sreg[SEG_CS] <= 16'hF000;       // reset fetch at FFFF0
            sreg[SEG_ES] <= 16'd0;
            sreg[SEG_SS] <= 16'd0;
            sreg[SEG_DS] <= 16'd0;
            es_ovr <= 1'b0;
            fl_z <= 1'b0; fl_s <= 1'b0; fl_c <= 1'b0;
            bus_addr <= 20'hFFFF0;
            is_fetch <= 1'b1;
            prc <= 8'h4E;                   // reset values (hardware
            wtc <= 16'hFFFF;                // manual ch.8.2, ch.5.1)
            q_rd <= 3'd0; q_wr <= 3'd0; q_cnt <= 3'd0;
            b_busy <= 1'b0; b_kind <= B_FETCH; b_left <= 2'd0;
            b_drop <= 1'b0;
            x_req <= 1'b0; x_we <= 1'b0; x_word <= 1'b0; x_done <= 1'b0;
            b_hi <= 1'b0; b_more <= 1'b0;
            e_el <= 6'd0; e_need <= 6'd0; e_flush <= 1'b0;
            halted <= 1'b0;
        end else if (!hold) begin
            // =============================================== BIU
            // T2 of the cycle in flight
            if (b_t2) begin
                b_busy <= 1'b0;
                unique case (b_kind)
                    B_FETCH: if (!b_drop) begin push = 1'b1; pb = bus_rd; end
                    B_READ: begin
                        if (b_hi) x_q[15:8] <= bus_rd;
                        else      x_q[7:0]  <= bus_rd;
                        if (x_word && !b_hi) b_more <= 1'b1;
                        else                 x_done <= 1'b1;
                    end
                    default:                               // write
                        if (x_word && !b_hi) b_more <= 1'b1;
                        else                 x_done <= 1'b1;
                endcase
            end else if (ct && b_busy)
                b_left <= b_left - 2'd1;                    // TW
            // T1 of the next cycle (the tick after a T2 at the earliest)
            else if (ct && !b_busy) begin
                logic fetch_ok, do_data, do_fetch;
                fetch_ok = (q_cnt < 3'd6) && !halted;
                do_data  = x_req && !(fetch_ok && q_cnt <= 3'd2);
                do_fetch = fetch_ok && !do_data && !fin_flush && !b_more;
                if (b_more) begin                   // a word's high byte
                    bus_addr <= x_addr + 20'd1;
                    b_left   <= dwaits(x_addr + 20'd1);
                    b_busy   <= 1'b1;
                    b_hi     <= 1'b1;
                    b_more   <= 1'b0;
                    if (x_we) begin
                        bus_wdata <= x_wdata[15:8];
                        bus_we    <= 1'b1;
                        dp_we_r   <= ((x_addr + 20'd1) >> 16 == 20'h1);
                    end
                end else if (do_data) begin
                    bus_addr <= x_addr;
                    is_fetch <= 1'b0;
                    b_kind   <= x_we ? B_WRITE : B_READ;
                    b_left   <= dwaits(x_addr);
                    b_busy   <= 1'b1;
                    b_hi     <= 1'b0;
                    x_req    <= 1'b0;
                    if (x_we) begin
                        bus_wdata <= x_wdata[7:0];
                        bus_we    <= 1'b1;
                        dp_we_r   <= (x_addr[19:16] == 4'h1);
                    end
                end else if (do_fetch) begin
                    bus_addr <= ({4'd0, sreg[SEG_CS]} << 4) + {4'd0, f_ip};
                    is_fetch <= 1'b1;
                    b_kind   <= B_FETCH;
                    b_left   <= waits(({4'd0, sreg[SEG_CS]} << 4)
                                      + {4'd0, f_ip}, 1'b0);
                    b_busy   <= 1'b1;
                    b_drop   <= 1'b0;
                    f_ip     <= f_ip + 16'd1;
                end
            end

            // =============================================== EXU
            // the count runs from the end of decode, one per fCLK
            if (is_pop(st))
                e_el <= 6'd0;
            else if (ct && e_el != 6'h3F)
                e_el <= e_el + 6'd1;

            unique case (st)
                // ------------------------------------ opcode
                S_OP: if (q_cnt != 3'd0) begin
                    logic [7:0] o;
                    pop = 1'b1;
                    o = decrypt(q_head, dec_arf);
                    ip <= ip + 16'd1;
                    if (o == 8'h26) begin
                        es_ovr <= 1'b1;            // DS1: prefix, 2 clocks
                        e_need <= 6'd2; e_flush <= 1'b0;
                        st <= S_FIN;
                    end else if (o == 8'hFF) begin
                        halted <= 1'b1;
                        st <= S_HALT;
                    end else begin
                        opc <= o;
                        disp <= 16'd0;
                        mrm <= 8'hC0;              // register form unless
                                                   // a modrm follows
                        if (has_modrm(o))              st <= S_MOD;
                        else if (o[7:3] == 5'b10111)   st <= S_I1; // mov r16,imm
                        else if (o[7:3] == 5'b10110)   st <= S_I1; // mov r8,imm
                        else if (o == 8'hE8)           st <= S_I1;
                        else if (o == 8'hEB || o == 8'h75 ||
                                 o == 8'h74 || o == 8'h73) st <= S_I1;
                        else if (o == 8'hEA)           st <= S_I1;
                        else                           st <= S_EXEC;
                    end
                end

                // ------------------------------------------ modrm
                S_MOD: if (q_cnt != 3'd0) begin
                    logic [7:0] m;
                    pop = 1'b1;
                    m = q_head;
                    mrm <= m;
                    ip <= ip + 16'd1;
                    if (m[7:6] == 2'b00 && m[2:0] == 3'd6)
                        st <= S_D1;                    // disp16 direct
                    else if (m[7:6] == 2'b01)
                        st <= S_D1;                    // disp8
                    else if (m[7:6] == 2'b10)
                        st <= S_D1;                    // disp16
                    else begin
                        // no displacement
                        ea_off <= ea_base(m[2:0]);
                        ea_seg <= es_ovr ? SEG_ES
                                         : ea_defseg(m[7:6], m[2:0]);
                        st <= after_ea(m[7:6]);
                    end
                end
                S_D1: if (q_cnt != 3'd0) begin
                    logic [7:0] d;
                    pop = 1'b1;
                    d = q_head;
                    ip <= ip + 16'd1;
                    if (mrm_mod == 2'b01) begin        // disp8 sext
                        disp <= {{8{d[7]}}, d};
                        ea_off <= ea_base(mrm_rm) + {{8{d[7]}}, d};
                        ea_seg <= es_ovr ? SEG_ES
                                         : ea_defseg(mrm_mod, mrm_rm);
                        st <= after_ea(mrm_mod);
                    end else begin                     // low of disp16
                        disp[7:0] <= d;
                        st <= S_D2;
                    end
                end
                S_D2: if (q_cnt != 3'd0) begin
                    logic [15:0] d16;
                    pop = 1'b1;
                    d16 = {q_head, disp[7:0]};
                    disp <= d16;
                    ip <= ip + 16'd1;
                    if (mrm_mod == 2'b00)              // [disp16]
                        ea_off <= d16;
                    else                               // base+disp16
                        ea_off <= ea_base(mrm_rm) + d16;
                    ea_seg <= es_ovr ? SEG_ES
                                     : ea_defseg(mrm_mod, mrm_rm);
                    st <= after_ea(mrm_mod);
                end

                // ------------------------------------- immediates
                S_I1: if (q_cnt != 3'd0) begin
                    pop = 1'b1;
                    imm[7:0] <= q_head;
                    ip <= ip + 16'd1;
                    if (imm_len2())
                        st <= S_I2;
                    else if ((opc == 8'h80 || opc == 8'h83) &&
                             mrm_mod != 2'b11)
                        st <= S_RD;    // group RMW: fetch old value
                    else
                        st <= S_EXEC;
                end
                S_I2: if (q_cnt != 3'd0) begin
                    pop = 1'b1;
                    imm[15:8] <= q_head;
                    ip <= ip + 16'd1;
                    if (opc == 8'hEA)
                        st <= S_I3;                    // segment word
                    else if (opc == 8'h81 && mrm_mod != 2'b11)
                        st <= S_RD;    // group RMW: fetch old value
                    else
                        st <= S_EXEC;
                end
                S_I3: if (q_cnt != 3'd0) begin
                    pop = 1'b1;
                    disp[7:0] <= q_head;
                    ip <= ip + 16'd1;
                    st <= S_I4;
                end
                S_I4: if (q_cnt != 3'd0) begin
                    pop = 1'b1;
                    disp[15:8] <= q_head;
                    ip <= ip + 16'd1;
                    st <= S_EXEC;
                end

                // ------------------------------- memory operand read
                S_RD: begin
                    x_req <= 1'b1; x_we <= 1'b0; x_addr <= lin_ea;
                    x_word <= op_wide(opc); x_done <= 1'b0;
                    st <= S_RD_W;
                end
                S_RD_W: if (x_done) begin
                    if (x_word) rmval      <= x_q;
                    else        rmval[7:0] <= x_q[7:0];
                    st <= S_EXEC;
                end

                // ------------------------------------------ execute
                S_EXEC: begin
                    logic taken;
                    taken = 1'b0;
                    st <= S_FIN;                       // default next
                    es_ovr <= 1'b0;
                    if (opc[7:3] == 5'b10111)
                        reg16[opc[2:0]] <= imm;        // mov r16,imm
                    else if (opc[7:3] == 5'b10110)
                        r8_set(opc[2:0], imm[7:0]);    // mov r8,imm
                    else case (opc)
                        8'hFA: ;                       // di
                        8'h43: begin
                            reg16[BX] <= reg16[BX] + 16'd1;
                            set_zs(reg16[BX] + 16'd1, 1'b1);
                        end
                        8'h49: begin
                            reg16[CX] <= reg16[CX] - 16'd1;
                            set_zs(reg16[CX] - 16'd1, 1'b1);
                        end
                        8'hEB: begin
                            ip <= ip + {{8{imm[7]}}, imm[7:0]};
                            taken = 1'b1;
                        end
                        8'h75: if (!fl_z) begin
                            ip <= ip + {{8{imm[7]}}, imm[7:0]};
                            taken = 1'b1;
                        end
                        8'h74: if (fl_z) begin         // be / jz (arf)
                            ip <= ip + {{8{imm[7]}}, imm[7:0]};
                            taken = 1'b1;
                        end
                        8'h73: if (!fl_c) begin        // bnc / jnc (arf,
                            ip <= ip + {{8{imm[7]}}, imm[7:0]}; // dead code)
                            taken = 1'b1;
                        end
                        8'hEA: begin
                            ip <= imm;
                            sreg[SEG_CS] <= disp;
                            taken = 1'b1;
                        end
                        8'hE8: begin
                            pushv <= ip;               // return address
                            ip <= ip + imm;
                            taken = 1'b1;
                            st <= S_PUSH;
                        end
                        8'hC3: begin
                            taken = 1'b1;
                            st <= S_POP;
                        end
                        8'h8D: reg16[mrm_reg] <= ea_off;
                        8'h8E: sreg[mrm_reg[1:0]] <=
                                   (mrm_mod == 2'b11)
                                       ? reg16[mrm_rm] : rmval;
                        8'h8B: reg16[mrm_reg] <=
                                   (mrm_mod == 2'b11)
                                       ? reg16[mrm_rm] : rmval;
                        8'h8A: r8_set(mrm_reg,
                                   (mrm_mod == 2'b11)
                                       ? r8_get(mrm_rm) : rmval[7:0]);
                        8'h88: begin                   // mov rm8, r8
                            if (mrm_mod == 2'b11)
                                r8_set(mrm_rm, r8_get(mrm_reg));
                            else begin
                                wr_val <= {8'd0, r8_get(mrm_reg)};
                                wr_lin <= lin_ea;
                                st <= S_WR;
                            end
                        end
                        8'h3B: begin
                            gr = grp_alu(3'd7, reg16[mrm_reg],
                                         (mrm_mod == 2'b11)
                                             ? reg16[mrm_rm] : rmval,
                                         1'b1);
                            fl_c <= gr[17]; set_zs(gr[15:0], 1'b1);
                        end
                        8'h3A: begin
                            gr = grp_alu(3'd7,
                                         {8'd0, r8_get(mrm_reg)},
                                         {8'd0, (mrm_mod == 2'b11)
                                             ? r8_get(mrm_rm)
                                             : rmval[7:0]}, 1'b0);
                            fl_c <= gr[17]; set_zs(gr[15:0], 1'b0);
                        end
                        8'h03: begin                   // add r16, rm16 (arf)
                            gr = grp_alu(3'd0, reg16[mrm_reg],
                                         (mrm_mod == 2'b11)
                                             ? reg16[mrm_rm] : rmval,
                                         1'b1);
                            fl_c <= gr[17]; set_zs(gr[15:0], 1'b1);
                            reg16[mrm_reg] <= gr[15:0];
                        end
                        8'h02: begin                   // add r8, rm8
                            gr = grp_alu(3'd0,
                                         {8'd0, r8_get(mrm_reg)},
                                         {8'd0, (mrm_mod == 2'b11)
                                             ? r8_get(mrm_rm)
                                             : rmval[7:0]}, 1'b0);
                            fl_c <= gr[17]; set_zs(gr[15:0], 1'b0);
                            r8_set(mrm_reg, gr[7:0]);
                        end
                        8'h80, 8'h81, 8'h83: begin
                            logic [15:0] b;
                            logic wide;
                            wide = (opc != 8'h80);
                            b = (opc == 8'h81) ? imm
                              : (opc == 8'h83) ? {{8{imm[7]}}, imm[7:0]}
                              :                  {8'd0, imm[7:0]};
                            gr = grp_alu(mrm_reg,
                                         (mrm_mod == 2'b11)
                                             ? (wide ? reg16[mrm_rm]
                                                : {8'd0, r8_get(mrm_rm)})
                                             : rmval,
                                         b, wide);
                            fl_c <= gr[17]; set_zs(gr[15:0], wide);
                            if (mrm_reg != 3'd7) begin // not cmp
                                if (mrm_mod == 2'b11) begin
                                    if (wide)
                                        reg16[mrm_rm] <= gr[15:0];
                                    else
                                        r8_set(mrm_rm, gr[7:0]);
                                end else begin
                                    wr_val <= gr[15:0];
                                    wr_lin <= lin_ea;
                                    st <= S_WR;
                                end
                            end
                        end
                        default: begin
                            halted <= 1'b1;
                            st <= S_HALT;
                        end
                    endcase
                    // the instruction's count; a stack operand's waits
                    // for CALL/RET, the memory operand's otherwise
                    e_need  <= exu_clocks(opc, mrm_mod, mrm_reg,
                                          (opc == 8'hE8 || opc == 8'hC3)
                                              ? dwaits(lin_sp)
                                              : dwaits(lin_ea),
                                          taken, prc[6]);
                    e_flush <= taken;
                end

                // ----------------------------------- memory writes
                S_WR: begin
                    x_req <= 1'b1; x_we <= 1'b1; x_addr <= wr_lin;
                    x_word <= op_wide(opc); x_wdata <= wr_val;
                    x_done <= 1'b0;
                    st <= S_WR_W;
                end
                S_WR_W: if (x_done) st <= S_FIN;

                // ---------------------------------------- push/pop
                // A word on the 8-bit bus goes out low byte first, at the
                // ascending address, as MAME's write stream shows (golden
                // sim/golden/arf_v25). The order is observable: the stack
                // sits on the MB8421's $7FE/$7FF interrupt flags (Q44).
                S_PUSH: begin
                    x_req <= 1'b1; x_we <= 1'b1; x_word <= 1'b1;
                    x_addr <= ({4'd0, sreg[SEG_SS]} << 4)
                            + {4'd0, reg16[SP] - 16'd2};
                    x_wdata <= pushv; x_done <= 1'b0;
                    st <= S_PUSH_W;
                end
                S_PUSH_W: if (x_done) begin
                    reg16[SP] <= reg16[SP] - 16'd2;
                    st <= S_FIN;
                end
                S_POP: begin
                    x_req <= 1'b1; x_we <= 1'b0; x_word <= 1'b1;
                    x_addr <= lin_sp; x_done <= 1'b0;
                    st <= S_POP_W;
                end
                S_POP_W: if (x_done) begin
                    ip <= x_q;
                    reg16[SP] <= reg16[SP] + 16'd2;
                    st <= S_FIN;
                end

                // ------------------------------- end of instruction
                // the count has run out and every data cycle is done; a
                // taken transfer clears the queue and refetches at ip
                S_FIN: if (e_el >= e_need) begin
                    if (fin_flush) begin
                        flush = 1'b1;
                        f_ip <= ip;
                        if (b_busy && b_kind == B_FETCH)
                            b_drop <= 1'b1;    // its T2 is still to come
                    end
                    e_flush <= 1'b0;
                    st <= S_OP;
                end

                S_HALT: ;                              // parked

                default: st <= S_HALT;
            endcase

            // ======================================= queue update
            if (flush) begin
                q_rd <= 3'd0; q_wr <= 3'd0; q_cnt <= 3'd0;
            end else begin
                if (push) begin
                    q[q_wr] <= pb;
                    q_wr <= q_wr + 3'd1;
                end
                if (pop) q_rd <= q_rd + 3'd1;
                q_cnt <= q_cnt + {2'd0, push} - {2'd0, pop};
            end
        end
    end

    // next state after EA resolution: loads go through memory read,
    // register forms and pure stores (88) / lea go straight to EXEC;
    // 80/81/83 need their immediate first
    function automatic state_e after_ea (input logic [1:0] mod);
        if (opc == 8'h80 || opc == 8'h81 || opc == 8'h83)
            after_ea = S_I1;         // immediate; memory read follows
        else if (mod != 2'b11 && op_loads(opc))
            after_ea = S_RD;
        else
            after_ea = S_EXEC;
    endfunction

    // immediate sizing: 16-bit for mov r16 / call / far-jmp offset /
    // 81-group; 8-bit otherwise
    function automatic logic imm_len2 ();
        imm_len2 = (opc[7:3] == 5'b10111) || (opc == 8'hE8) ||
                   (opc == 8'hEA) || (opc == 8'h81);
    endfunction

endmodule
