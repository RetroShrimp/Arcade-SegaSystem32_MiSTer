// v60_pfu.sv — V60 prefetch unit (instruction queue).
//
// References: the NEC V60 information sheet (the prefetch unit is a 16-byte
// queue that fills "during idle bus periods"; fetch latency is "reduced to
// zero if the instruction is found in the pre-fetch queue"), the uPD71613
// bus controller datasheet (Table 1: instruction prefetch is its own bus
// cycle type) and the V60 programmer's reference (p27: data cycles take
// priority over queue fills).
//
// The queue follows the core's pc (drain on sequential advance, flush on a
// jump), tracks how many bytes are valid, and fills through 16-bit fetch
// bus cycles that compete with data cycles in the bus unit (pf_req/
// pf_grant), so instruction fetch costs bus time as on the real CPU.
//
// Decode readiness lives in the core: the PFU presents `window` (22
// bytes at pc, MSB-first) + `fq_count` (valid bytes AT pc); the core's
// v60_ldec computes ilen and proceeds when fq_count >= ilen. That is safe:
// a length decoder only reads bytes inside the instruction it sizes, so if
// ilen <= count every byte it used was valid. The core ORs
// `fq_count < ilen` into fetch_hold.
//
// Queue depth. The real queue is 16 bytes (information sheet), and its
// decoder consumes an instruction's bytes as they arrive, so an instruction
// longer than the queue streams through it. This model instead needs the
// whole instruction in the window before the core decodes it, and V60
// instructions run to 22 bytes (opcode, sub-op or format byte, two
// double-displacement operands of 9 bytes, extension bytes): Slip Stream's
// task entry at $0879D9 is `mov.b 1A[3830[R15]], 1E[3830[R15]]`, 20 bytes,
// and with a 16-byte queue the core waited for it forever (2026-10-28,
// docs/slipstrm-bringup.md §5). So the fill policy is the 16-byte queue's
// (fill while count <= 14) EXCEPT while the instruction at pc is longer than
// 16 bytes (`long_q`, below): then the queue fills on to 24, as many bytes
// as the real decoder would have pulled through its queue. Every
// instruction of 16 bytes or fewer sees exactly the old fill behaviour.
//
// The long-instruction hint is decoded here, by its own v60_ldec, from a
// SNAPSHOT of the window. Decoding straight off the window is the rotation
// plus the length decoder, ~20 ns (STA, 2026-10-28, seed 11: -4.9 ns on the
// 15.5 ns clk_sys period); the core's own copy of that path has two periods
// (S32.sdc, -to v60), but a register here does not. So win_q/cnt_q load on
// every other clock (hph) and long_q loads on the same clocks from the
// PREVIOUS snapshot: every win_q/cnt_q -> long_q path has two periods by
// construction, which is what the S32.sdc multicycle for it claims. The
// hint lags pc by up to four clocks. It is only acted on once the queue
// sits at the 16-byte cap (count 15 or 16) with the core waiting on a
// longer instruction, when the window does not change; and it is only
// believed when the snapshot held at least 15 valid bytes (the window is
// zero past fq_count), which covers every byte a length decoder reads to
// size an instruction longer than 16 bytes (its mode bytes sit below 15).
//
// Circular buffer: byte at address (base+k), 0<=k<count, lives at
// buf[(head+k)&31]. The window/count are presented RELATIVE TO pc via
// a combinational offset (delta = pc-base) so they are correct the same
// cycle pc moves; the registered drain/flush makes base=pc one cycle
// later. On a jump (delta out of [0,count]) the presented count is 0 →
// the core holds → the queue flushes and refills (the branch penalty).
//
// Fill: aligned 16-bit word fetches at (base+count)&~1. An even fill
// appends 2 bytes; an odd fill (only right after an odd-target flush)
// appends 1 usable byte — the real odd-target realign cost. A fetch in
// flight when a flush occurs (this cycle or an earlier one) is dropped.
//
// ROM bytes arrive on pf_rdata from the bus fabric.

module v60_pfu (
    input  logic         clk,
    input  logic         rst,

    // ---- core side (v60.sv sees window + fetch_hold, unchanged shape)
    input  logic [23:0]  pc,          // current instruction pointer
    output logic [175:0] window,      // 22 bytes at pc, MSB-first (byte0=[175:168])
    output logic [4:0]   fq_count,    // valid bytes available AT pc (0..26)

    // ---- bus side: a second BCU client (data always wins)
    output logic         pf_req,      // want a fetch word
    output logic [23:0]  pf_addr,     // aligned word byte-address (A0=0)
    input  logic         pf_grant,    // BCU starts a fetch cycle this slot
    input  logic [15:0]  pf_rdata,    // {high@addr+1, low@addr}
    input  logic         pf_done      // fetch cycle complete (1 cycle)
);

    // ------------------------------------------------------------ state
    // Buffer is a PACKED 256-bit vector (not a memory array): byte at
    // circular slot s lives at bufv[8*s +: 8]. Packed storage keeps the
    // combinational window portable — a memory read inside comb logic
    // does not retrigger on content change under iverilog; a vector part
    // -select does. Reads use indexed part-selects (assign context);
    // writes compose bufv via mask+shift (no variable part-select LHS).
    logic [255:0] bufv;
    logic [23:0] base;                 // address of the head byte
    logic [4:0]  head;
    logic [4:0]  count;                // valid bytes 0..16 (0..26 long)
    logic        inflight;             // a fetch cycle is running
    logic        flushed;              // flush seen since grant → drop word
    logic        long_q;               // the instruction at pc is > 16 bytes
    logic        hph;                  // snapshot phase (every other clock)
    logic [175:0] win_q;               // window snapshot
    logic [4:0]  cnt_q;                // fq_count snapshot
    logic [5:0]  hint_len;

    // ------------------------------------------------- pc-relative view
    // delta = pc - base; valid sequential position iff delta<=count
    // (24-bit unsigned: a backward or far-forward jump wraps huge → out
    // of range → presented count 0 → core holds → flush next edge).
    logic [23:0] delta_u;
    logic        in_range, this_flush;
    assign delta_u    = pc - base;
    assign in_range   = (delta_u <= {19'd0, count});
    assign this_flush = (delta_u != 24'd0) && !in_range;

    wire [4:0] avail = in_range ? (count - delta_u[4:0]) : 5'd0;
    assign fq_count = avail;

    // Window = the buffer rotated so the byte at logical position `delta`
    // (slot head+delta) becomes byte 0, sliced to 22 bytes, MSB-first,
    // masked past `avail`. Implemented as a whole-vector barrel rotate
    // (a doubled-vector variable right shift) + CONSTANT part-selects —
    // the one construction iverilog-12 handles portably (memory reads do
    // not retrigger comb; variable indexed part-selects hit its "sorry").
    wire [4:0]   rot  = (head + delta_u[4:0]) & 5'h1F;
    wire [511:0] dblv = {bufv, bufv} >> ({4'd0, rot} << 3);   // rotate rot*8
    wire [255:0] rotv = dblv[255:0];
    assign window = {
        (5'd0  < avail) ? rotv[7:0]     : 8'h00,   // logical byte 0 → MSB
        (5'd1  < avail) ? rotv[15:8]    : 8'h00,
        (5'd2  < avail) ? rotv[23:16]   : 8'h00,
        (5'd3  < avail) ? rotv[31:24]   : 8'h00,
        (5'd4  < avail) ? rotv[39:32]   : 8'h00,
        (5'd5  < avail) ? rotv[47:40]   : 8'h00,
        (5'd6  < avail) ? rotv[55:48]   : 8'h00,
        (5'd7  < avail) ? rotv[63:56]   : 8'h00,
        (5'd8  < avail) ? rotv[71:64]   : 8'h00,
        (5'd9  < avail) ? rotv[79:72]   : 8'h00,
        (5'd10 < avail) ? rotv[87:80]   : 8'h00,
        (5'd11 < avail) ? rotv[95:88]   : 8'h00,
        (5'd12 < avail) ? rotv[103:96]  : 8'h00,
        (5'd13 < avail) ? rotv[111:104] : 8'h00,
        (5'd14 < avail) ? rotv[119:112] : 8'h00,
        (5'd15 < avail) ? rotv[127:120] : 8'h00,
        (5'd16 < avail) ? rotv[135:128] : 8'h00,
        (5'd17 < avail) ? rotv[143:136] : 8'h00,
        (5'd18 < avail) ? rotv[151:144] : 8'h00,
        (5'd19 < avail) ? rotv[159:152] : 8'h00,
        (5'd20 < avail) ? rotv[167:160] : 8'h00,
        (5'd21 < avail) ? rotv[175:168] : 8'h00
    };

    // ---------------------------------------- long-instruction hint
    v60_ldec u_hint (
        .bytes_in(win_q), .length(hint_len), .ftype(), .opsize1(),
        .opsize2(), .am1_len(), .am2_len(), .valid()
    );

    // ------------------------------------------------------ fill target
    wire [23:0] fill_a   = base + {19'd0, count};   // next byte to fetch
    wire        fill_odd = fill_a[0];
    wire [23:0] fill_wa  = {fill_a[23:1], 1'b0};     // aligned word address
    wire        want_fill = ((count <= 5'd14) || (long_q && count <= 5'd22))
                            && !inflight;
    assign pf_req  = want_fill;
    assign pf_addr = fill_wa;

    // ---------------------------------------------- next-state (single)
    // drain/flush and append compose into ONE count/head/base update.
    logic [4:0]  count_pd;             // count after drain, before append
    logic [4:0]  head_pd;
    logic [23:0] base_pd;
    always_comb begin
        if (delta_u == 24'd0) begin
            count_pd = count;
            head_pd = head;    base_pd = base;
        end else if (in_range) begin
            count_pd = count - delta_u[4:0];
            head_pd = (head + delta_u[4:0]) & 5'h1F; base_pd = pc;
        end else begin                 // flush
            count_pd = 5'd0;
            head_pd = 5'd0;    base_pd = pc;
        end
    end

    // fetch bookkeeping. `granting` starts a cycle this edge; `retire`
    // ends the current one. A completing word is committed only if the
    // stream did not change while it was in flight (flushed / this-cycle
    // flush). Because a drain preserves base+count, fill_odd/fill_wa are
    // invariant from grant to done absent a flush — so appending by the
    // current fill_odd at the current tail is correct.
    wire granting  = pf_req && pf_grant && !inflight;
    wire retire    = inflight && pf_done;
    wire do_append = retire && !flushed && !this_flush;
    wire [4:0] tail  = (head_pd + count_pd) & 5'h1F;
    wire [4:0] tail1 = (tail + 5'd1) & 5'h1F;

    // next-bufv: append at the tail slot(s) via mask+shift (no variable
    // part-select LHS). Odd fill writes 1 byte (the high byte, at/after
    // the odd fill address); even fill writes 2.
    logic [255:0] bufv_next;
    always @(*) begin
        bufv_next = bufv;
        if (do_append) begin
            if (fill_odd) begin
                bufv_next = (bufv_next & ~(256'hFF << (8*tail)))
                          | ({248'd0, pf_rdata[15:8]} << (8*tail));
            end else begin
                bufv_next = (bufv_next & ~(256'hFF << (8*tail)))
                          | ({248'd0, pf_rdata[7:0]}  << (8*tail));
                bufv_next = (bufv_next & ~(256'hFF << (8*tail1)))
                          | ({248'd0, pf_rdata[15:8]} << (8*tail1));
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            base <= 24'd0; head <= 5'd0; count <= 5'd0;
            inflight <= 1'b0; flushed <= 1'b0; bufv <= 256'd0;
            long_q <= 1'b0; hph <= 1'b0; win_q <= 176'd0; cnt_q <= 5'd0;
        end else begin
            hph <= ~hph;
            if (hph) begin
                long_q <= (cnt_q >= 5'd15) && (hint_len > 6'd16);
                win_q  <= window;
                cnt_q  <= avail;
            end
            base  <= base_pd;
            head  <= head_pd;
            count <= count_pd + (do_append ? (fill_odd ? 5'd1 : 5'd2) : 5'd0);
            bufv  <= bufv_next;

            if (granting)    inflight <= 1'b1;
            else if (retire) inflight <= 1'b0;

            // flushed protects the in-flight (or just-granted) fetch;
            // covers grant-and-flush the same cycle; cleared at retire
            // (every granted cycle completes) and whenever nothing is in
            // flight, so it can never stick.
            if (this_flush && (inflight || granting))
                flushed <= 1'b1;
            else if (retire || (!inflight && !granting))
                flushed <= 1'b0;
        end
    end

endmodule
