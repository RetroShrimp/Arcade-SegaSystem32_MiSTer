// s32_sdram.sv — SDR SDRAM controller (clk_sys, 64.43 MHz, CAS latency 2).
//
// Ports:
//   - six burst-read ports, 8 x 16 bits = 16 bytes per burst;
//   - one single-word write port (WRITE + BURST TERMINATE, so the mode
//     register can stay at burst 8). Done pulses at the BST, and further
//     writes to the same row then chain on the open row at 5 cycles each;
//   - one 8-word burst-write port (ROM loading, frame buffer erase).
// Deadline ports first, then round-robin among the rest; AUTO REFRESH every
// ~7.8 us.
//
// Handshake: hold req (with a stable address) until the one-cycle done
// pulse. The request is sampled when the port wins arbitration, so a
// request dropped early is never served.
//
// Init: 100 us NOP -> PRECHARGE ALL -> 2x AUTO REFRESH -> LOAD MODE (CL2,
// sequential, burst 8 for reads and writes) -> ready.

module s32_sdram #(
    parameter INIT_WAIT = 6500,      // ~100 us at 64.43 MHz
    parameter REF_EVERY = 500        // 7.8 us refresh cadence
) (
    input  logic        clk,
    input  logic        rst,
    output logic        ready,

    // burst-read ports (word address; 8 consecutive 16-bit words).
    // Read chains: a port holding rcont high asks to keep reading the same
    // row. The first read then runs without auto-precharge, and further
    // lines are read back to back (one every 8 cycles) from the port's live
    // raddr; rack pulses each time an address is taken, so the client can
    // present the next one early. Each line pulses rstb (rdata valid that
    // cycle); the last pulses rstb and rdone, then the row is precharged.
    // A chain stops when a deadline port (3, 0 or 2) requests, the row would
    // change, or 8 lines have been read.
    input  logic        rreq  [0:5],
    input  logic [24:1] raddr [0:5],
    input  logic        rcont [0:5],
    output logic [127:0] rdata,       // shared assembly register
    output logic        rdone [0:5],
    output logic        rstb  [0:5],
    output logic        rack  [0:5],

    // single-word write port
    input  logic        wreq,
    input  logic [24:1] waddr,
    input  logic [15:0] wdata,
    input  logic [1:0]  wdqm,
    input  logic        vram_urgent, // port 5 holds a VRAM fill the video
                                     // walk is stalled on: raise its
                                     // priority (see pick)
    input  logic        vram_pending,// experimental, tied 0: defer single
                                     // writes while a VRAM fill waits
    input  logic        vram_pf,     // experimental, tied 0: port 5 is a
                                     // VRAM prefetch that yields to the V60
    input  logic        wurgent,     // posted write queue nearly full
    output logic        wdone,

    // burst write port (8 consecutive words)
    input  logic        wbreq,
    input  logic [24:1] wbaddr,
    input  logic [127:0] wbdata,
    output logic        wbdone,

    // SDRAM pins
    output logic        sd_cke,
    output logic        sd_cs_n,
    output logic        sd_ras_n,
    output logic        sd_cas_n,
    output logic        sd_we_n,
    output logic [1:0]  sd_ba,
    output logic [12:0] sd_a,
    output logic [1:0]  sd_dqm,
    inout  wire  [15:0] sd_dq
);

    // address split: word addr [24:1] -> bank[24:23] row[22:10]
    // col[9:1] (13-bit row, 9 column bits: 32MB as 16M x 16)
    function automatic logic [1:0]  a_bank (input logic [24:1] a);
        a_bank = a[24:23];
    endfunction
    function automatic logic [12:0] a_row (input logic [24:1] a);
        a_row = a[22:10];
    endfunction
    function automatic logic [9:0] a_col (input logic [24:1] a);
        a_col = {1'b0, a[9:1]};
    endfunction

    // command encodings {cs,ras,cas,we}
    // (C_BST is used ONLY on non-auto-precharge single writes, where
    // JEDEC permits it. BST on an AP write is prohibited — the real
    // chip continues the burst clocking in floating-bus junk (white
    // FFFF stripes on screen). DQM-masked completion beats do not work
    // on this board either — the DQM pins miss the chip's early
    // sampling edge by one cycle, so beat 1 lands unmasked in word+1
    // (known-answer test, 512 x 5A5A). Hence:
    // non-AP write + BST + explicit PRECHARGE, command pins only.)
    localparam C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD  = 4'b0101,
               C_WR  = 4'b0100, C_PRE = 4'b0010, C_REF = 4'b0001,
               C_LMR = 4'b0000, C_BST = 4'b0110;

    logic [3:0] cmd;
    assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;
    assign sd_cke = 1'b1;

    // dq drive (writes only)
    logic [15:0] dq_out;
    logic        dq_oe;
    assign sd_dq = dq_oe ? dq_out : 16'hzz_zz;

    // read capture: SDRAM_DQ is registered in the I/O cell
    // (FAST_INPUT_REGISTER in the qsf) before it reaches the rdata
    // register; routing the pin straight to the fabric takes most of a
    // clock period.
    logic [15:0] dq_in_q /* synthesis preserve */;
    always_ff @(posedge clk) dq_in_q <= sd_dq;

    // ------------------------------------------------------ scheduler
    typedef enum logic [4:0] {
        S_INIT, S_INIT_PRE, S_INIT_REF1, S_INIT_REF2, S_INIT_LMR,
        S_IDLE, S_REF, S_ACT, S_RCD, S_CAS, S_DATA, S_WR_BST,
        S_WSP, S_WCHK, S_WPRED, S_WTRP,
        S_WR1, S_WB, S_FIN, S_RPRE
    } state_e;
    state_e st;

    integer     wait_cnt;
    integer     ref_cnt;
    logic       ref_due;
    logic [2:0] grant;               // 0-5 read ports, 6 = write
    logic [2:0] rr_last;
    logic [24:1] g_addr;
    logic [15:0] g_wdata;            // request captured atomically
    logic [1:0]  g_wdqm;             //   at grant
    logic [127:0] g_wbdata;
    logic [2:0] beat;
    logic       g_cont;              // granted read port ran rcont at grant
    logic [3:0] c_iss, c_seen;       // chain lines issued / completed

    // ignore a port's req for 2 cycles after its done pulse: the
    // client needs a cycle to withdraw a level-held req, and a stale
    // re-grant must never sample the NEXT request's data
    logic [1:0] cool [0:7];

    // pick among pending requests (cooldown-gated); 0-5 = read ports,
    // 6 = single write, 7 = burst write. The round-robin part rotates the
    // eligibility vector by the last grant, priority-encodes it and rotates
    // back, which is much shallower logic than a modulo scan.
    function automatic logic [3:0] pick (input logic [2:0] last,
                                         input logic       vu,
                                         input logic       vpend);
        logic [7:0]  elig, rot;
        logic [15:0] e2;
        logic [2:0]  enc;
        for (int c = 0; c < 6; c = c + 1)
            elig[c] = rreq[c] && cool[c] == 2'd0;
        // vram_pf (tied 0): a VRAM prefetch yields while the V60 reads
        elig[5] = elig[5] && !(vram_pf && rreq[1]);
        elig[6] = wreq  && cool[6] == 2'd0
        // vpend (tied 0): defer non-urgent single writes while a VRAM fill
        // waits
                          && !(vpend && !wurgent);
        elig[7] = wbreq && cool[7] == 2'd0;
        // Fixed priority first, then round-robin:
        //   3  tile ROM: the video renderer has a hard per-line deadline.
        //   5  only while it holds a VRAM fill the video walk is stalled on
        //      (vu); never above the tile ROM.
        //   0  sprite ROM: rare single bursts, but the sprite engine waits
        //      on each one.
        //   2  frame buffer line fetch when the frame buffer is in SDRAM
        //      (unused here: it is in DDR3).
        //   6  single writes, only while the posted write queue is nearly
        //      full (wurgent), so it cannot back up into a CPU stall.
        // Everything else (V60 fetch and data, Z80 and V25 ROM, VRAM fills,
        // writes, the burst-write port) shares the round-robin.
        if      (elig[3])                  pick = 4'd3;
        else if (vu && elig[5])            pick = 4'd5;
        else if (elig[0])                  pick = 4'd0;
        else if (elig[2])                  pick = 4'd2;
        else if (wurgent && elig[6])       pick = 4'd6;
        else begin
            e2  = {elig, elig} >> ({1'b0, last} + 4'd1);
            rot = e2[7:0];
            enc = 3'd0;
            for (int b = 7; b >= 0; b = b - 1)
                if (rot[b]) enc = 3'(b);
            pick = (rot == 8'd0) ? 4'hF
                 : {1'b0, 3'((int'(last) + 1 + int'(enc)) % 8)};
        end
    endfunction

    // pick is registered, which keeps the request scan off the capture
    // registers' timing path. A request pending before the FSM reaches
    // S_IDLE is granted without extra latency; one arriving while idle
    // waits one cycle. Requests are level-held and cooldowns only count
    // down, so a one-cycle-old pick is still valid.
    logic [3:0] pick_r;
    always_ff @(posedge clk) begin
        if (rst) pick_r <= 4'hF;
        else     pick_r <= pick(rr_last, vram_urgent, vram_pending);
    end

    // write-chain length (see S_WCHK): a chain yields as soon as a
    // deadline read port asks, and is capped at 8 writes so the other
    // clients (V60, Z80) still get turns when the readers are quiet.
    logic [2:0] wchain_cnt;

    integer i;
    always_ff @(posedge clk) begin
        cmd    <= C_NOP;
        dq_oe  <= 1'b0;
        sd_dqm <= 2'b00;
        wdone  <= 1'b0;
        wbdone <= 1'b0;
        for (i = 0; i < 6; i = i + 1) begin
            rdone[i] <= 1'b0;
            rstb[i]  <= 1'b0;
            rack[i]  <= 1'b0;
        end

        if (rst) begin
            st <= S_INIT;
            wait_cnt <= 0;
            ref_cnt <= 0;
            ref_due <= 0;
            ready <= 0;
            rr_last <= 3'd7;
            for (i = 0; i < 8; i = i + 1) cool[i] <= 2'd0;
        end else begin
            for (i = 0; i < 8; i = i + 1)
                if (cool[i] != 2'd0) cool[i] <= cool[i] - 2'd1;
            // refresh cadence
            ref_cnt <= ref_cnt + 1;
            if (ref_cnt >= REF_EVERY) begin
                ref_cnt <= 0;
                ref_due <= 1;
            end

            unique case (st)
                S_INIT: begin
                    wait_cnt <= wait_cnt + 1;
                    if (wait_cnt >= INIT_WAIT) st <= S_INIT_PRE;
                end
                S_INIT_PRE: begin
                    cmd <= C_PRE; sd_a <= 13'h400;    // all banks
                    wait_cnt <= 0;
                    st <= S_INIT_REF1;
                end
                S_INIT_REF1: begin
                    wait_cnt <= wait_cnt + 1;
                    if (wait_cnt == 3) begin
                        cmd <= C_REF;
                        wait_cnt <= 0;
                        st <= S_INIT_REF2;
                    end
                end
                S_INIT_REF2: begin
                    wait_cnt <= wait_cnt + 1;
                    if (wait_cnt == 9) begin
                        cmd <= C_REF;
                        wait_cnt <= 0;
                        st <= S_INIT_LMR;
                    end
                end
                S_INIT_LMR: begin
                    wait_cnt <= wait_cnt + 1;
                    if (wait_cnt == 9) begin
                        cmd <= C_LMR;
                        // CL2, sequential, burst 8 (reads AND writes;
                        // single writes use WRITE + BURST TERMINATE)
                        sd_a <= 13'b0_0_00_010_0_011;
                        st <= S_IDLE;
                        ready <= 1;
                    end
                end

                S_IDLE: begin
                    if (ref_due) begin
                        cmd <= C_REF;
                        ref_due <= 0;
                        wait_cnt <= 0;
                        st <= S_REF;
                    end else begin
                        if (pick_r != 4'hF) begin
                            grant <= pick_r[2:0];
                            // priority grants don't move the round-
                            // robin origin of the elastic clients
                            if (pick_r[2:0] != 3'd2
                                && pick_r[2:0] != 3'd3)
                                rr_last <= pick_r[2:0];
                            // synthesis translate_off
                            // read grants must be 8-word aligned: a
                            // misaligned request would silently fetch the
                            // wrong words, so fail loudly in simulation
                            if (pick_r[2:0] < 3'd6
                                && raddr[pick_r[2:0]][3:1] != 3'd0)
                                $error("s32_sdram: unaligned read grant port %0d addr %x",
                                       pick_r[2:0], raddr[pick_r[2:0]]);
                            // synthesis translate_on
                            g_addr <= (pick_r[2:0] == 3'd6) ? waddr
                                    : (pick_r[2:0] == 3'd7) ? wbaddr
                                    : raddr[pick_r[2:0]];
                            g_cont <= (pick_r[2:0] < 3'd6)
                                      ? rcont[pick_r[2:0]] : 1'b0;
                            g_wdata <= wdata;
                            g_wdqm  <= wdqm;
                            g_wbdata <= wbdata;
                            wchain_cnt <= 3'd0;
                            st <= S_ACT;
                        end
                    end
                end

                S_REF: begin                     // tRC after refresh
                    wait_cnt <= wait_cnt + 1;
                    if (wait_cnt >= 7) st <= S_IDLE;
                end

                S_ACT: begin
                    cmd   <= C_ACT;
                    sd_ba <= a_bank(g_addr);
                    sd_a  <= a_row(g_addr);
                    st <= S_RCD;
                end

                S_RCD: begin                     // tRCD = 2
                    // Drive write data one cycle before the WRITE command,
                    // so DQ is valid a full extra clock before the chip
                    // samples it. Write-data setup with the -90 degree
                    // SDRAM clock is tight, and switching noise on the 16
                    // DQ pins under heavy write traffic corrupted writes
                    // on the FPGA. The bus is free here (the previous
                    // access ended in S_FIN). The column address still goes
                    // out with C_WR in S_CAS.
                    if (grant == 3'd6) begin
                        dq_oe  <= 1'b1;
                        dq_out <= g_wdata;
                    end else if (grant == 3'd7) begin
                        dq_oe  <= 1'b1;
                        dq_out <= g_wbdata[15:0];
                    end
                    st <= S_CAS;
                end

                S_CAS: begin
                    sd_ba <= a_bank(g_addr);
                    sd_a  <= {2'b00, 1'b1, a_col(g_addr)}; // a[10]=1 AP
                    if (grant == 3'd6) begin
                        // single write without auto-precharge. Ending
                        // the burst with DQM-masked beats does not work
                        // on this board: DQM settles one cycle too late
                        // for the chip's sampling edge, so every write
                        // also landed in word+1 (measured). The command
                        // pins do make that edge, so the burst is ended
                        // with BURST TERMINATE (legal on a non-AP write)
                        // plus an explicit PRECHARGE.
                        cmd <= C_WR;
                        sd_a <= {2'b00, 1'b0, a_col(g_addr)}; // no AP
                        dq_oe <= 1'b1;
                        dq_out <= g_wdata;
                        sd_dqm <= g_wdqm;
                        st <= S_WR_BST;
                    end else if (grant == 3'd7) begin
                        cmd <= C_WR;
                        dq_oe <= 1'b1;
                        dq_out <= g_wbdata[15:0];
                        beat <= 3'd1;
                        st <= S_WB;
                    end else if (g_cont) begin
                        // chain-eligible read: NO auto-precharge — the row
                        // stays open for same-row continuation CAS bursts
                        cmd  <= C_RD;
                        sd_a <= {2'b00, 1'b0, a_col(g_addr)};
                        rack[grant] <= 1'b1;    // line 0 consumed: present next
                        c_iss <= 4'd1; c_seen <= 4'd0;
                        beat <= 3'd0;
                        wait_cnt <= 0;
                        st <= S_DATA;
                    end else begin
                        cmd <= C_RD;
                        beat <= 3'd0;
                        wait_cnt <= 0;
                        st <= S_DATA;
                    end
                end

                S_DATA: begin
                    // Read-capture cycle, measured on the DE10-Nano: the
                    // chip's clock (-3879 ps phase plus ~8 ns insertion
                    // delay) samples the READ in the same controller cycle
                    // the command goes out, so word 0 reaches dq_in_q one
                    // cycle earlier than a zero-phase model suggests
                    // (capturing from wait_cnt 4 returned words 1..8).
                    // Simulation models must apply CAS latency one clock
                    // short to match.
                    wait_cnt <= wait_cnt + 1;
                    if (!g_cont) begin
                        // ---- single-burst path
                        if (wait_cnt >= 3) begin
                            rdata[16*beat +: 16] <= dq_in_q;
                            beat <= beat + 3'd1;
                            if (beat == 3'd7) begin
                                rdone[grant] <= 1'b1;
                                // port 2 (SDRAM frame buffer) streams 40
                                // bursts per line back to back, so it has
                                // no cooldown; its client drops rreq[2] on
                                // the last burst's done (s32_board)
                                cool[grant] <= (grant == 3'd2) ? 2'd0
                                                               : 2'd2;
                                st <= S_FIN;
                            end
                        end
                    end else begin
                        // ---- chain path: the next READ goes out 8 cycles
                        // after the last, decided before the current line
                        // finishes (the client presented the address after
                        // rack)
                        if (wait_cnt == 8 * int'(c_iss) - 1) begin
                            // a due refresh does not break the chain: at
                            // most 7 more lines (~1.1 us), then the refresh
                            // runs at S_IDLE, well within refresh slack
                            if (rcont[grant] && rreq[grant]
                                && !rreq[3] && !rreq[0] && !rreq[2]
                                && c_iss != 4'd8
                                && a_bank(raddr[grant]) == a_bank(g_addr)
                                && a_row (raddr[grant]) == a_row (g_addr))
                            begin
                                cmd   <= C_RD;
                                sd_ba <= a_bank(g_addr);
                                sd_a  <= {2'b00, 1'b0,
                                          a_col(raddr[grant])};  // no AP
                                rack[grant] <= 1'b1;
                                c_iss <= c_iss + 4'd1;
                            end
                            // else: stop issuing; in-flight lines drain
                        end
                        if (wait_cnt >= 3) begin
                            rdata[16*beat +: 16] <= dq_in_q;
                            beat <= beat + 3'd1;
                            if (beat == 3'd7) begin
                                if (c_seen + 4'd1 == c_iss) begin
                                    // last issued line: deliver + close row
                                    rstb[grant]  <= 1'b1;
                                    rdone[grant] <= 1'b1;
                                    cool[grant]  <= 2'd2;
                                    st <= S_RPRE;
                                end else begin
                                    rstb[grant] <= 1'b1;
                                    c_seen <= c_seen + 4'd1;
                                end
                            end
                        end
                    end
                end

                S_RPRE: begin
                    // close the chain's open row (its reads ran without
                    // auto-precharge); the last beat was captured last
                    // cycle, so the burst is complete
                    cmd   <= C_PRE;
                    sd_ba <= a_bank(g_addr);
                    sd_a  <= 13'h0;          // a[10]=0: this bank
                    wait_cnt <= 0;
                    st <= S_WTRP;            // shared tRP wait -> S_FIN
                end

                S_WR_BST: begin
                    // BST lands one cycle after the WRITE, ending the
                    // burst before beat 1, so only the addressed word is
                    // written whatever the (slow) DQM pins show.
                    //
                    // done pulses here: the data was committed at the WRITE.
                    // The row stays open and S_WCHK chains a following
                    // same-row write at 5 cycles each, instead of a full
                    // PRECHARGE + ACTIVATE + arbitration per word.
                    cmd <= C_BST;
                    wdone <= 1'b1;
                    st <= S_WSP;
                end

                S_WSP:
                    // spacer: the client sees done and moves to its next
                    // write this cycle, so wreq/waddr at S_WCHK are the
                    // new request (one cycle earlier would repeat the
                    // write just completed)
                    st <= S_WCHK;

                S_WCHK: begin
                    if (wreq && !ref_due
                        && a_bank(waddr) == a_bank(g_addr)
                        && a_row(waddr)  == a_row(g_addr)
                        // yield to the deadline read ports (3, 0, 2),
                        // which can only be granted from S_IDLE; the
                        // length cap leaves turns for the V60 and Z80
                        && !rreq[3] && !rreq[0] && !rreq[2]
                        && wchain_cnt != 3'd7) begin
                        // same open row: chain it (no PRE, no ACT,
                        // no arbiter pass)
                        g_addr  <= waddr;
                        g_wdata <= wdata;
                        wchain_cnt <= wchain_cnt + 3'd1;
                        st <= S_WPRED;
                    end else begin
                        // row done: explicit precharge (the writes ran
                        // without auto-precharge). The last data beat was
                        // >= 3 cycles ago, which covers tWR.
                        cmd   <= C_PRE;
                        sd_ba <= a_bank(g_addr);
                        sd_a  <= 13'h0;          // a[10]=0: this bank
                        wait_cnt <= 0;
                        cool[6] <= 2'd2;
                        st <= S_WTRP;
                    end
                end

                S_WPRED: begin
                    // chained write: drive DQ one cycle early, as in
                    // S_RCD
                    dq_oe  <= 1'b1;
                    dq_out <= g_wdata;
                    st <= S_CAS;
                end

                S_WTRP: begin                    // tRP after the PRE
                    wait_cnt <= wait_cnt + 1;
                    if (wait_cnt >= 2) st <= S_FIN;
                end

                S_WR1: begin                     // burst write tWR + tRP
                    wait_cnt <= wait_cnt + 1;
                    if (wait_cnt >= 3) begin
                        // (only the 8-word burst path ends here; single
                        // writes end through S_WCHK)
                        wbdone <= 1'b1;
                        cool[7] <= 2'd2;
                        // through S_FIN, like the read path: the
                        // registered pick is one cycle stale, and going
                        // straight to S_IDLE could grant this port again
                        // before its cooldown, completing the client's
                        // next write without performing it
                        st <= S_FIN;
                    end
                end

                S_WB: begin                      // burst data 1..7
                    dq_oe <= 1'b1;
                    dq_out <= g_wbdata[16*beat +: 16];
                    beat <= beat + 3'd1;
                    if (beat == 3'd7) begin
                        wait_cnt <= 0;
                        st <= S_WR1;             // tWR + tRP tail
                    end
                end

                S_FIN: st <= S_IDLE;             // tRP after AP

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
