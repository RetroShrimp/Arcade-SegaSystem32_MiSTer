// s32_dsp7725.sv — NEC uPD7725 (the uPD77P25 on Air Rescue's 837-8341 DSP
// board): the 16-bit fixed-point DSP, running its internal program from the
// dumped image (MAME ROM_START(arescue) "d7725.01", 10 KB).
//
// References:
//   MAME latest master a40c1f06196, src/devices/cpu/upd7725/upd7725.cpp
//     (necdsp_device, by byuu and R. Belmont): execute_run (one opcode per
//     clock, the interrupt's NOP + LCALL $100 pair, the multiplier after every
//     instruction), exec_op / exec_rt / exec_jp / exec_ld, data_r / data_w (the
//     host data port's 16-bit DRS sequence), execute_set_input (INT: rising
//     edge, taken only with SR.EI set, which it clears), device_reset (what
//     /RESET clears: PC, SR, the flags, SI/SO acks, a pending interrupt).
//     tools/upd7725_model.py is an instruction-for-instruction Python port of
//     it, and the bench (sim/s32_dsp7725) compares this RTL with that port.
//   NEC uPD77C25/77P25 data sheet: 122 ns instruction cycle at 8.192 MHz, so
//     one instruction per input clock; 2048 x 24 program ROM, 1024 x 16 data
//     ROM, 256 x 16 data RAM; 4-level stack.
//
// Where this core follows the chip rather than MAME's shared 7725/96050 core
// (none of these is reachable from the Air Rescue program, docs/
// arescue-bringup.md §3): PC 11 bits, DP 8 bits, RP 10 bits, a 4-level
// circular stack (MAME: 16-bit registers and 16 levels). The serial ports are
// not wired on the 837-8341 as far as is known: SI reads 0 and SO goes
// nowhere (MAME emulates neither).
//
// Timing: `cen` marks one DSP clock. On that edge the INT pin is sampled and
// the host port strobes act (the board's DMA logic runs on the same clock);
// the instruction then completes over the next four clk edges:
//   ph1  the opcode (prog_q, read continuously at PC) is taken; RAM read at DP
//   ph2  RAM data at DP latched; RAM read at DP|$40 (LD/OP dst 12, KLM)
//   ph3  execute: every register, flag, RAM write and PC change
//   ph4  the multiplier: M, N from the new K, L
// so cen must be at least five clk apart (8 MHz in 64.43 MHz gives 8 or 9).
//
// ROM loading: ld_addr is the byte offset in d7725.01 as MAME's regions slice
// it: $0000-$1FFF the program, 2048 32-bit big-endian words whose top 24 bits
// are the instruction (the low byte is $FF padding); $2000-$27FF the data ROM,
// 1024 16-bit big-endian words. The loader writes only while rst is held.

module s32_dsp7725 (
    input  logic        clk,
    input  logic        rst,          // /RESET
    input  logic        cen,          // one DSP clock

    input  logic        ld_we,
    input  logic [13:0] ld_addr,
    input  logic [7:0]  ld_data,

    input  logic        int_in,       // INT pin, sampled on cen
    output logic        p0,
    output logic        p1,
    output logic        drq,          // DMA request: SR.RQM & SR.DMA
    output logic        drs,          // SR.DRS: the next host byte is the high one

    // host data port (A0 = 0: DR), one strobe per byte, on a cen edge
    input  logic        host_rd,
    input  logic        host_wr,
    input  logic [7:0]  host_wdata,
    output logic [7:0]  host_rdata
);

    // SR bits
    localparam int RQM = 15, DRS = 12, DMA = 11, DRC = 10, EI = 7;

    // ------------------------------------------------------------ memories
    logic [23:0] prog [0:2047];
    logic [15:0] drom [0:1023];
    logic [15:0] dram [0:255];
    logic [23:0] prog_q;
    logic [15:0] drom_q, dram_q;
    logic [15:0] ld_hold;                 // bytes waiting for their word

    logic [10:0] pc;
    logic [9:0]  rp = '0;
    logic [7:0]  dp = '0;
    logic [2:0]  ph;                      // 0 idle, 1-4 as in the header

    // program ROM: one port, written by the loader (during rst), read at PC
    wire [10:0] prog_a = rst ? ld_addr[12:2] : pc;
    wire        prog_we = ld_we && !ld_addr[13] && ld_addr[1:0] == 2'd2;
    always_ff @(posedge clk) begin
        if (prog_we) prog[prog_a] <= {ld_hold, ld_data};
        prog_q <= prog[prog_a];
    end
    // data ROM
    wire [9:0]  drom_a = rst ? ld_addr[10:1] : rp;
    wire        drom_we = ld_we && ld_addr[13] && ld_addr[0];
    always_ff @(posedge clk) begin
        if (drom_we) drom[drom_a] <= {ld_hold[7:0], ld_data};
        drom_q <= drom[drom_a];
    end
    always_ff @(posedge clk)
        if (ld_we) begin
            if (!ld_addr[13] && ld_addr[1:0] == 2'd0) ld_hold[15:8] <= ld_data;
            if (!ld_addr[13] && ld_addr[1:0] == 2'd1) ld_hold[7:0]  <= ld_data;
            if (ld_addr[13] && !ld_addr[0])           ld_hold[7:0]  <= ld_data;
        end

    // data RAM: one port; read at ph1 (DP) and ph2 (DP | $40), written at ph3
    logic        dram_we;
    logic [15:0] dram_wd;
    wire  [7:0]  dram_a = (ph == 3'd2) ? (dp | 8'h40) : dp;
    always_ff @(posedge clk) begin
        if (dram_we) dram[dram_a] <= dram_wd;
        if (ph == 3'd1 || ph == 3'd2) dram_q <= dram[dram_a];
    end

    // ------------------------------------------------------------ registers
    // power-up values as declaration initialisers (the reset below clears
    // only what MAME's device_reset clears)
    logic [15:0] k = '0, l = '0, m = '0, n = '0, a = '0, b = '0;
    logic [15:0] tr = '0, trb = '0, dr = '0, so = '0, sr;
    logic [5:0]  fa, fb;                  // {s1, s0, c, z, ov1, ov0}
    logic [10:0] stack [0:3];
    logic [1:0]  sp = '0;
    logic        siack, soack;
    logic        irq_prev = 1'b0;
    logic [1:0]  irq_firing;
    logic [23:0] op;
    logic [10:0] pc_seq;                  // PC after this fetch
    logic [15:0] ram_dp, ram_k;           // RAM at DP, at DP | $40

    initial begin
        for (int i = 0; i < 4; i++) stack[i] = 0;
        for (int i = 0; i < 256; i++) dram[i] = 0;
    end

    assign p0  = sr[0];
    assign p1  = sr[1];
    assign drq = sr[RQM] & sr[DMA];
    assign drs = sr[DRS];
    // MAME data_r: 8-bit mode the low byte; 16-bit mode low then high
    assign host_rdata = (!sr[DRC] && sr[DRS]) ? dr[15:8] : dr[7:0];

    localparam int S1 = 5, S0 = 4, C = 3, Z = 2, OV1 = 1, OV0 = 0;

    function automatic logic [15:0] rev16 (input logic [15:0] v);
        for (int i = 0; i < 16; i++) rev16[i] = v[15 - i];
    endfunction

    // ------------------------------------------------------------ execute
    always_ff @(posedge clk) begin
        dram_we <= 1'b0;
        if (rst) begin
            pc <= '0;
            sr <= '0;
            fa <= '0;
            fb <= '0;
            siack <= 1'b0;
            soack <= 1'b0;
            irq_firing <= 2'd0;
            ph <= 3'd0;
        end else begin
            // ---- the DSP clock edge: INT and the host port
            if (cen) begin
                logic [15:0] s;
                s = sr;
                if (int_in && !irq_prev && s[EI]) begin
                    irq_firing <= 2'd1;
                    s[EI] = 1'b0;
                end
                irq_prev <= int_in;
                if (host_wr) begin                         // MAME data_w
                    if (!s[DRC]) begin
                        if (!s[DRS]) begin
                            s[DRS] = 1'b1;
                            dr[7:0] <= host_wdata;
                        end else begin
                            s[RQM] = 1'b0;
                            s[DRS] = 1'b0;
                            dr[15:8] <= host_wdata;
                        end
                    end else begin
                        s[RQM] = 1'b0;
                        dr[7:0] <= host_wdata;
                    end
                end else if (host_rd) begin                // MAME data_r
                    if (!s[DRC]) begin
                        if (!s[DRS]) s[DRS] = 1'b1;
                        else begin s[RQM] = 1'b0; s[DRS] = 1'b0; end
                    end else
                        s[RQM] = 1'b0;
                end
                sr <= s;
                ph <= 3'd1;
            end

            // ---- ph1: take the opcode
            if (ph == 3'd1) begin
                case (irq_firing)
                    2'd0: begin op <= prog_q;   pc_seq <= pc + 11'd1; end
                    2'd1: begin op <= 24'h000000; pc_seq <= pc; irq_firing <= 2'd2; end
                    default: begin op <= 24'hA80400; pc_seq <= pc; irq_firing <= 2'd0; end
                endcase
                ph <= 3'd2;
            end

            if (ph == 3'd2) begin
                ram_dp <= dram_q;
                ph <= 3'd3;
            end

            // ---- ph3: execute
            if (ph == 3'd3) begin
                logic [1:0]  cls, psel, dpl;
                logic [3:0]  alu, dphm, src, dst;
                logic        asl, rpdcr;
                logic [15:0] idb, p, q, r;
                logic [5:0]  f;
                logic        cin;
                logic [15:0] na, nb, ntr, ntrb, nk, nl, nsr, ndr, nso;
                logic [7:0]  ndp;
                logic [9:0]  nrp;
                logic [10:0] npc;
                logic [1:0]  nsp;
                logic        ld_cls, take;
                logic [8:0]  brch;
                logic [10:0] nadr;

                ram_k = dram_q;
                na = a; nb = b; ntr = tr; ntrb = trb; nk = k; nl = l;
                nsr = sr; ndr = dr; nso = so; ndp = dp; nrp = rp;
                npc = pc_seq; nsp = sp;
                cls = op[23:22];
                ld_cls = (cls == 2'd3);

                if (cls == 2'd0 || cls == 2'd1) begin
                    // -------- OP / RT
                    psel  = op[21:20];
                    alu   = op[19:16];
                    asl   = op[15];
                    dpl   = op[14:13];
                    dphm  = op[12:9];
                    rpdcr = op[8];
                    src   = op[7:4];
                    dst   = op[3:0];
                    case (src)
                        4'd0:  idb = trb;
                        4'd1:  idb = a;
                        4'd2:  idb = b;
                        4'd3:  idb = tr;
                        4'd4:  idb = {8'd0, dp};
                        4'd5:  idb = {6'd0, rp};
                        4'd6:  idb = drom_q;
                        4'd7:  idb = 16'h8000 - {15'd0, fa[S1]};
                        4'd8:  begin idb = dr; nsr[RQM] = 1'b1; end
                        4'd9:  idb = dr;
                        4'd10: idb = sr;
                        4'd11: idb = 16'h0000;            // SI
                        4'd12: idb = 16'h0000;            // SI reversed
                        4'd13: idb = k;
                        4'd14: idb = l;
                        default: idb = ram_dp;
                    endcase
                    if (alu != 4'd0) begin
                        case (psel)
                            2'd0: p = ram_dp;
                            2'd1: p = idb;
                            2'd2: p = m;
                            default: p = n;
                        endcase
                        if (!asl) begin q = a; f = fa; cin = fb[C]; end
                        else      begin q = b; f = fb; cin = fa[C]; end
                        case (alu)
                            4'h1: r = q | p;
                            4'h2: r = q & p;
                            4'h3: r = q ^ p;
                            4'h4: r = q - p;
                            4'h5: r = q + p;
                            4'h6: r = q - p - {15'd0, cin};
                            4'h7: r = q + p + {15'd0, cin};
                            4'h8: begin r = q - 16'd1; p = 16'd1; end
                            4'h9: begin r = q + 16'd1; p = 16'd1; end
                            4'hA: r = ~q;
                            4'hB: r = {q[15], q[15:1]};
                            4'hC: r = {q[14:0], cin};
                            4'hD: r = {q[13:0], 2'b11};
                            4'hE: r = {q[11:0], 4'hF};
                            default: r = {q[7:0], q[15:8]};
                        endcase
                        f[S0] = r[15];
                        f[Z]  = (r == 16'd0);
                        if (!f[OV1]) f[S1] = f[S0];
                        case (alu)
                            4'h1, 4'h2, 4'h3, 4'hA, 4'hD, 4'hE, 4'hF: begin
                                f[C] = 1'b0; f[OV0] = 1'b0; f[OV1] = 1'b0;
                            end
                            4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9: begin
                                if (alu[0]) begin
                                    f[OV0] = (q[15] ^ r[15]) & ~(q[15] ^ p[15]);
                                    f[C]   = (r < q);
                                end else begin
                                    f[OV0] = (q[15] ^ r[15]) & (q[15] ^ p[15]);
                                    f[C]   = (r > q);
                                end
                                f[OV1] = (f[OV0] & f[OV1]) ? (f[S1] == f[S0])
                                                           : (f[OV0] | f[OV1]);
                            end
                            4'hB: begin f[C] = q[0];  f[OV0] = 1'b0; f[OV1] = 1'b0; end
                            default: begin f[C] = q[15]; f[OV0] = 1'b0; f[OV1] = 1'b0; end
                        endcase
                        if (!asl) begin na = r; fa <= f; end
                        else      begin nb = r; fb <= f; end
                    end
                end else if (ld_cls) begin
                    idb = op[21:6];
                    dst = op[3:0];
                end else begin
                    idb = 16'h0000;
                    dst = 4'd0;
                end

                // -------- the move (MAME exec_ld), OP/RT and LD
                if (cls != 2'd2) begin
                    case (dst)
                        4'd1:  na = idb;
                        4'd2:  nb = idb;
                        4'd3:  ntr = idb;
                        4'd4:  ndp = idb[7:0];
                        4'd5:  nrp = idb[9:0];
                        4'd6:  begin ndr = idb; nsr[RQM] = 1'b1; end
                        4'd7:  nsr = (nsr & 16'h907C) | (idb & ~16'h907C);
                        4'd8:  begin nso = rev16(idb); soack <= 1'b1; end
                        4'd9:  begin nso = idb; soack <= 1'b1; end
                        4'd10: nk = idb;
                        4'd11: begin nk = idb; nl = drom_q; end
                        4'd12: begin nl = idb; nk = ram_k; end
                        4'd13: nl = idb;
                        4'd14: ntrb = idb;
                        4'd15: begin dram_we <= 1'b1; dram_wd <= idb; end
                        default: ;
                    endcase
                end

                // -------- DP / RP modify (OP and RT only)
                if (cls == 2'd0 || cls == 2'd1) begin
                    if (dst != 4'd4) begin
                        case (dpl)
                            2'd1: ndp = {ndp[7:4], ndp[3:0] + 4'd1};
                            2'd2: ndp = {ndp[7:4], ndp[3:0] - 4'd1};
                            2'd3: ndp = {ndp[7:4], 4'd0};
                            default: ;
                        endcase
                        ndp[7:4] = ndp[7:4] ^ dphm;
                    end
                    if (rpdcr && dst != 4'd5) nrp = nrp - 10'd1;
                end

                // -------- control flow
                if (cls == 2'd1) begin                       // RT
                    nsp = sp - 2'd1;
                    npc = stack[nsp];
                end else if (cls == 2'd2) begin              // JP
                    brch = op[21:13];
                    nadr = op[12:2];
                    case (brch)
                        9'h080: take = !fa[C];   9'h082: take = fa[C];
                        9'h084: take = !fb[C];   9'h086: take = fb[C];
                        9'h088: take = !fa[Z];   9'h08A: take = fa[Z];
                        9'h08C: take = !fb[Z];   9'h08E: take = fb[Z];
                        9'h090: take = !fa[OV0]; 9'h092: take = fa[OV0];
                        9'h094: take = !fb[OV0]; 9'h096: take = fb[OV0];
                        9'h098: take = !fa[OV1]; 9'h09A: take = fa[OV1];
                        9'h09C: take = !fb[OV1]; 9'h09E: take = fb[OV1];
                        9'h0A0: take = !fa[S0];  9'h0A2: take = fa[S0];
                        9'h0A4: take = !fb[S0];  9'h0A6: take = fb[S0];
                        9'h0A8: take = !fa[S1];  9'h0AA: take = fa[S1];
                        9'h0AC: take = !fb[S1];  9'h0AE: take = fb[S1];
                        9'h0B0: take = (dp[3:0] == 4'h0);
                        9'h0B1: take = (dp[3:0] != 4'h0);
                        9'h0B2: take = (dp[3:0] == 4'hF);
                        9'h0B3: take = (dp[3:0] != 4'hF);
                        9'h0B4: take = !siack;   9'h0B6: take = siack;
                        9'h0B8: take = !soack;   9'h0BA: take = soack;
                        9'h0BC: take = !sr[RQM]; 9'h0BE: take = sr[RQM];
                        9'h100, 9'h101: take = 1'b1;           // LJMP / HJMP
                        default: take = 1'b0;
                    endcase
                    if (brch == 9'h000)
                        npc = so[10:0];                         // JMPSO
                    else if (brch == 9'h140 || brch == 9'h141) begin
                        stack[sp] <= pc_seq;                    // LCALL / HCALL
                        nsp = sp + 2'd1;
                        npc = nadr;
                    end else if (take)
                        npc = nadr;
                end

                a <= na; b <= nb; tr <= ntr; trb <= ntrb; k <= nk; l <= nl;
                sr <= nsr; dr <= ndr; so <= nso; dp <= ndp; rp <= nrp;
                pc <= npc; sp <= nsp;
                ph <= 3'd4;
            end

            // ---- ph4: the multiplier (MAME: after every instruction)
            if (ph == 3'd4) begin
                logic signed [31:0] prod;
                prod = $signed(k) * $signed(l);
                m <= prod[30:15];
                n <= {prod[14:0], 1'b0};
                ph <= 3'd0;
            end
        end
    end

endmodule
