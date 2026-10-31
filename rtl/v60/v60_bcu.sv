// v60_bcu.sv — V60 bus control unit.
//
// References: the NEC V60 information sheet (pins and block diagram: the
// "Bus Control" unit drives ST2-ST0, /MRQ, DL1-DL0, R//W, /BCY, /UBE, /FAS,
// /DS; /READY extends cycles; A0 and /UBE steer bytes) and the NEC uPD71613
// bus controller datasheet (bus states from CLK rise to CLK rise; Table 1,
// the ST2-ST0 cycle types, with separate instruction-prefetch and demand-
// fetch cycles). A bus cycle is three clocks, T1-T2-T3; where exactly
// /READY is sampled is not documented, so waits extend T3 here.
//
// The unit sits between the core's transaction port ({addr, size 1/2/4
// bytes, any alignment}) and the s32_v60bus fabric. It splits every
// transaction into the real 16-bit bus cycles (size <= 2, aligned, low or
// high byte lane) and spaces them at least three cen16 ticks apart (T1, T2,
// T3 at 16.10795 MHz). A fabric that takes longer extends T3, like /READY.
//
// Two clients share the bus: the core's DATA transactions
// (c_*) and the PFU's instruction FETCH (pf_*, aligned 16-bit reads).
// Data always wins: a fetch is accepted only when the core has no data
// request and the unit is idle (the prefetch queue fills "during idle bus
// periods", per the V60 documentation). A fetch overlaps execution (busy
// stays low unless the core wants data); data takes the next bus cycle,
// never interrupting one. Split (little-endian, low byte first; the real
// order of the halves has not been measured):
//   size 1          : (A,   1)
//   size 2, A even  : (A,   2)
//   size 2, A odd   : (A,   1) (A+1, 1)
//   size 4, A even  : (A,   2) (A+2, 2)
//   size 4, A odd   : (A,   1) (A+1, 2) (A+3, 1)
// Reads are assembled right-aligned, with $FF in bytes not read; writes
// take c_wdata right-aligned per cycle.
//
// Core side: the core's strobe is a one-cycle output in its cen16 issue
// slot. The unit latches the transaction on the cen16 edge where the core
// moves to its consume state, then holds the core (busy) until the last
// cycle's T3 ends; the core steps again on that edge with c_rdata valid.
// One bus cycle therefore costs the issue slot plus 3 cen16 ticks (the
// real CPU overlaps the issue slot with its pipeline, so this is slightly
// slower). A strobe from a consume-and-issue state is latched on the
// finishing edge, with the previous read's c_rdata kept through its
// consume slot.
//
// Fabric side: every output comes from a register. f_re/f_we pulse for
// one clk per bus cycle, only while the fabric is idle (f_hold low), so
// the fabric sees each cycle exactly once; completion is f_hold rising
// then falling (the fabric always leaves A_IDLE for at least one clk).

module v60_bcu (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen16,       // 16.10795 MHz enable (clk_sys/4)

    // ---- core (sequencer) side: the v60 mem_* transaction port
    input  logic        c_re,
    input  logic        c_we,
    input  logic [31:0] c_addr,
    input  logic [31:0] c_wdata,
    input  logic [2:0]  c_size,      // bytes: 1 / 2 / 4
    output logic [31:0] c_rdata,
    output logic        busy,        // freezes the core (wait_hold term)

    // ---- fetch client: the prefetch queue (v60_pfu). Data always wins;
    //      a fetch is always an aligned 16-bit read.
    input  logic        pf_req,
    input  logic [23:0] pf_addr,     // aligned word byte-address (A0=0)
    output logic        pf_grant,    // a fetch cycle started this edge
    output logic [15:0] pf_rdata,
    output logic        pf_done,     // fetch cycle complete (1-clk pulse)

    // ---- fabric side: s32_v60bus mem_* port, size<=2 aligned only
    output logic        f_re,
    output logic        f_we,
    // this bus cycle is an instruction fetch: the fabric reads it through
    // the prefetching fetch adapter instead of the data adapter
    output logic        f_fetch,
    output logic [31:0] f_addr,
    output logic [31:0] f_wdata,
    output logic [2:0]  f_size,
    input  logic [31:0] f_rdata,
    input  logic        f_hold,
    // a strobe is queued: it goes out on the first clk f_hold is low. Lets
    // another bus master (Dark Edge's FD1149 model in s32_v60bus) take the
    // bus without racing a strobe: with f_pend low there is none this edge.
    output logic        f_pend,

    // ---- status for the clock's wait-debt recovery (s32_sys): a
    //      transaction is in flight; this cen16 slot is a T3 wait (TW);
    //      the current bus cycle's fabric service is complete
    output logic        st_run,
    output logic        st_tw,
    output logic        st_done
);

    // ----------------------------------------------------- client select
    // The transaction being planned/latched is the core's data access
    // when it has one, else the PFU fetch (a size-2 aligned read).
    wire        d_req   = c_re || c_we;
    wire [31:0] s_addr  = d_req ? c_addr  : {8'h00, pf_addr};
    wire [2:0]  s_size  = d_req ? c_size  : 3'd2;
    wire        s_we    = d_req ? c_we    : 1'b0;
    wire [31:0] s_wdata = d_req ? c_wdata : 32'd0;

    // ------------------------------------------------------- cycle plan
    // combinational, from the SELECTED transaction. Cycle 0 is
    // (s_addr, pl0_sz, off 0); cycles 1/2 exist per the table above.
    wire        ae     = !s_addr[0];
    wire [1:0]  pl_n   = (s_size == 3'd1) ? 2'd0
                       : (s_size == 3'd2) ? (ae ? 2'd0 : 2'd1)
                       :                    (ae ? 2'd1 : 2'd2);
    wire [1:0]  pl0_sz = (s_size != 3'd1 && ae) ? 2'd2 : 2'd1;
    wire [31:0] pl1_a  = ae ? (s_addr + 32'd2) : (s_addr + 32'd1);
    wire [1:0]  pl1_sz = (s_size == 3'd4) ? 2'd2 : 2'd1;
    wire [1:0]  pl1_of = ae ? 2'd2 : 2'd1;
    wire [31:0] pl2_a  = s_addr + 32'd3;    // size4-odd only: (A+3,1,3)

    // ------------------------------------------------------------ state
    localparam [1:0] T1 = 2'd0, T2 = 2'd1, T3 = 2'd2;
    logic        run;                        // a transaction is in flight
    logic [1:0]  tst;
    logic [1:0]  n_cyc, ci;
    logic [31:0] q1_a, q2_a;
    logic [1:0]  q1_sz, q1_of;
    logic        t_we;
    logic [31:0] t_wdata;
    logic        serving_fetch;              // the in-flight txn is a fetch

    // current / next cycle parameters (cycle 0 lives in f_addr/f_size
    // directly at latch; the muxes below serve capture and relaunch)
    wire [1:0]  cur_sz = (ci == 2'd0) ? f_size[1:0]
                       : (ci == 2'd1) ? q1_sz : 2'd1;
    wire [1:0]  cur_of = (ci == 2'd0) ? 2'd0
                       : (ci == 2'd1) ? q1_of : 2'd3;
    wire [31:0] nxt_a  = (ci == 2'd0) ? q1_a  : q2_a;
    wire [1:0]  nxt_sz = (ci == 2'd0) ? q1_sz : 2'd1;
    wire [1:0]  nxt_of = (ci == 2'd0) ? q1_of : 2'd3;

    logic        pend_stb;                   // pulse f strobe when idle
    logic        issued, seen_hold;
    logic        f_stb;
    // Deferred $FF fill for back-to-back reads: at a finishing-edge
    // accept, the PREVIOUS read's c_rdata is being consumed by the
    // core during the very next slot — filling at the accept edge
    // would clobber it. Fill one cen16 later instead (the core's
    // consume window has closed; the new transaction's first capture
    // is >= 2 slots later than that).
    logic        fill_pend;

    // fabric completion for the CURRENT bus cycle: strobe consumed
    // (f_hold rose) and service finished (f_hold back low)
    wire cyc_done = issued && seen_hold && !f_hold;
    // Registered completion: c_rdata is captured at the first cyc_done
    // edge and done_q set with it, so the core is released only once the
    // data is a full clk old. (Releasing on the combinational cyc_done
    // could hand the core stale data when the fabric finished exactly on
    // the T3 edge.)
    logic done_q;

    // final-T3 completion this cen16 slot -> release the core AT the
    // slot's step edge (busy low during the cen16-high cycle)
    wire finishing = run && (tst == T3) && (ci == n_cyc)
                     && done_q && cen16;

    // Accept DATA at a cen16 step edge while idle — OR at the finishing
    // edge itself: a consume-and-issue state's strobe is visible during
    // the release cycle and must be latched then (the core's data path,
    // unchanged from the single-client BCU). Accept FETCH only when
    // FULLY idle (!run, never at the finishing edge): the PFU clears its
    // `inflight` one edge after pf_done, so granting a new fetch at the
    // finishing edge would desync the BCU (thinks it started one) from
    // the PFU (didn't grant). One idle cen16 between fetch words is
    // correct — the PFU re-arbitrates, and data can seize the slot.
    wire accept_data  = d_req && cen16 && (!run || finishing);
    wire accept_fetch = !d_req && pf_req && cen16 && !run;
    wire accept       = accept_data || accept_fetch;

    // Core freeze. The core issues mem_re/we as a one-cycle pulse and
    // advances on the edge the unit accepts it. A fetch may be using the
    // bus, so the pulse must be held until accepted:
    //   - d_req (issue state, mem_re/we asserted): freeze UNLESS the BCU
    //     accepts the data this edge (accept_data). If a fetch owns the
    //     bus, accept_data is 0 → the core stays in the issue state and
    //     re-presents mem_re next edge (a fixed point — mem_re is comb
    //     from the frozen state) until the fetch finishes and accept_data
    //     fires (its `finishing` term). At that edge busy drops for one
    //     step so the core advances into its consume/wait state.
    //   - otherwise (consume/wait state, or executing): freeze only while
    //     a DATA cycle is in flight and not finishing. Executing during a
    //     background fetch is NOT frozen (serving_fetch → busy 0), so
    //     fetch overlaps execution as on the real CPU.
    assign busy = d_req ? !accept_data
                        : (run && !serving_fetch && !finishing);

    assign pf_grant = accept_fetch;
    assign pf_done  = finishing && serving_fetch;

    assign f_pend = pend_stb;
    assign st_run  = run;
    assign st_tw   = run && cen16 && (tst == T3) && !done_q;
    assign st_done = done_q;
    assign f_re = f_stb && !t_we;
    assign f_we = f_stb && t_we;
    assign f_fetch = serving_fetch;   // valid while run (the fabric samples
                                      // it during the R_ROM read)

    // per-cycle right-aligned write slice (fabric q_wdata convention)
    function automatic logic [31:0] wslice
        (input logic [31:0] w, input logic [1:0] off, input logic [1:0] sz);
        logic [31:0] r;
        begin
            r = 32'h0000_0000;
            if (sz == 2'd2) r[15:0] = 16'(w >> (8 * off));
            else            r[7:0]  = 8'(w >> (8 * off));
            wslice = r;
        end
    endfunction

    always_ff @(posedge clk) begin
        f_stb <= 1'b0;
        if (rst) begin
            run <= 1'b0; pend_stb <= 1'b0;
            issued <= 1'b0; seen_hold <= 1'b0;
            tst <= T1; ci <= 2'd0; n_cyc <= 2'd0;
            t_we <= 1'b0; fill_pend <= 1'b0;
            done_q <= 1'b0; serving_fetch <= 1'b0;
        end else begin
            if (fill_pend && cen16) begin
                c_rdata   <= 32'hFFFF_FFFF;
                fill_pend <= 1'b0;
            end

            // strobe the fabric exactly once per bus cycle, only while
            // it is idle (its A_IDLE arm consumes on level)
            if (pend_stb && !f_hold && !f_stb) begin
                f_stb    <= 1'b1;
                pend_stb <= 1'b0;
                issued   <= 1'b1;
            end
            if (issued && f_hold) seen_hold <= 1'b1;

            // capture read data at the FIRST completion edge (done_q
            // marks it; release/relaunch happen >= 1 clk later). A fetch
            // is a single word cycle → its result goes to pf_rdata; a
            // core data read composes into c_rdata per lane.
            if (run && cyc_done && !done_q) begin
                done_q <= 1'b1;
                if (serving_fetch)
                    pf_rdata <= f_rdata[15:0];
                else if (!t_we) begin
                    if (cur_sz == 2'd2)
                        c_rdata[8*cur_of +: 16] <= f_rdata[15:0];
                    else
                        c_rdata[8*cur_of +: 8]  <= f_rdata[7:0];
                end
            end

            if (accept) begin
                run           <= 1'b1;
                tst           <= T1;
                ci            <= 2'd0;
                n_cyc         <= pl_n;
                q1_a          <= pl1_a;
                q1_sz         <= pl1_sz;
                q1_of         <= pl1_of;
                q2_a          <= pl2_a;
                t_we          <= s_we;
                t_wdata       <= s_wdata;
                serving_fetch <= accept_fetch;
                // $FF fill only for CORE data reads (fetch → pf_rdata)
                if (!s_we && !accept_fetch) begin
                    if (finishing) fill_pend <= 1'b1;  // deferred (see decl)
                    else           c_rdata   <= 32'hFFFF_FFFF;
                end
                // launch cycle 0 (registered fabric outputs)
                f_addr    <= s_addr;
                f_size    <= {1'b0, pl0_sz};
                f_wdata   <= wslice(s_wdata, 2'd0, pl0_sz);
                pend_stb  <= 1'b1;
                issued    <= 1'b0;
                seen_hold <= 1'b0;
                done_q    <= 1'b0;
`ifndef SYNTHESIS
                if (d_req && c_size != 3'd1 && c_size != 3'd2
                    && c_size != 3'd4)
                    $display("v60_bcu: ILLEGAL size %0d at %h",
                             c_size, c_addr);
`endif
            end else if (run && cen16) begin
                case (tst)
                    T1: tst <= T2;
                    T2: tst <= T3;
                    default:                           // T3
                        if (done_q) begin
                            if (ci == n_cyc)
                                run <= 1'b0;           // finishing slot
                            else begin
                                ci  <= ci + 2'd1;
                                tst <= T1;
                                f_addr    <= nxt_a;
                                f_size    <= {1'b0, nxt_sz};
                                f_wdata   <= wslice(t_wdata, nxt_of, nxt_sz);
                                pend_stb  <= 1'b1;
                                issued    <= 1'b0;
                                seen_hold <= 1'b0;
                                done_q    <= 1'b0;
                            end
                        end
                        // else: TW — T3 extends until the fabric is done
                endcase
            end
        end
    end

endmodule
