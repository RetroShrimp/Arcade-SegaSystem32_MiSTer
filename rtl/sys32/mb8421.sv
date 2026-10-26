// mb8421.sv — Fujitsu MB8421 2K x 8 dual-port RAM (the V25 protection
// module mailbox: left = V25, right = V60 byte lane at A00000+2n).
//
// True dual-port, synchronous reads on both sides (one M10K).
//
// Datasheet behaviour (MB8421-12L, the grade fitted to the Golden Axe
// protection board): when both ports access one address at once, the
// first wins and the other's active-low /BUSY asserts; for simultaneous
// requests the LEFT port wins. /BUSY is open-drain, meant to drive a CPU
// READY input. The part's timings (120 ns access, 60 ns /BUSY, 25 ns
// arbitration setup) are all longer than a clk period, so here every
// same-cycle, same-address collision counts as simultaneous. The board
// wires the V25 to the left (priority) port: V25 -> l_*, V60 -> r_*,
// LEFT_WINS=1.
//
// Collisions (2026-10-24, for Arabian Fight; docs/arabfgt-scoping.md §5.1,
// OPEN-QUESTIONS Q44). ga2's V25 writes once at boot, so it never collided.
// Arabian Fight's V25 rewrites the result records continuously while the
// V60 reads them, and polls the index bytes while the V60 writes them:
//   * READ vs WRITE, same address, same cycle: resolved WRITE FIRST. The
//     write always lands and the reader gets the newly written byte through
//     a bypass register. That is a real outcome for two asynchronous CPUs
//     (the reader's access starting just after the write), it never drops a
//     write (MAME's atomic accesses never do), and it keeps the M10K's
//     mixed-port read-during-write — DONT_CARE, i.e. garbage on silicon,
//     whatever the behavioral model says (AGENTS.md, board-design.md §9.7)
//     — out of every value either CPU sees. Before this change the V60's
//     colliding write was dropped and its colliding read was the raw array
//     output.
//   * WRITE vs WRITE, same address, same cycle: the priority port's write
//     lands and the other is dropped (the datasheet's inhibited loser with
//     /BUSY unwired). Neither ga2 nor Arabian Fight writes a byte the other
//     side writes, so this never happens.
// /BUSY is generated but not connected: whether it reaches either CPU's
// READY on the real boards is Q44.

module mb8421 #(
    parameter bit LEFT_WINS = 1'b1     // l_* (V25) port wins ties
) (
    input  logic        clk,

    // left port (V25)
    input  logic        l_sel,
    input  logic        l_we,
    input  logic [10:0] l_addr,
    input  logic [7:0]  l_wdata,
    output logic [7:0]  l_rdata,
    output logic        l_busy_n,      // active-low /BUSY (open-drain on part)

    // right port (V60)
    input  logic        r_sel,
    input  logic        r_we,
    input  logic [10:0] r_addr,
    input  logic [7:0]  r_wdata,
    output logic [7:0]  r_rdata,
    output logic        r_busy_n
);

    logic [7:0] ram [0:2047];

    // --- arbitration (combinational; see the header)
    // A collision needs arbitration only when both ports select the
    // same address in the same cycle AND at least one writes: a pure
    // read/read pair reads consistent old data on both sides and never
    // asserts /BUSY (no data hazard, the part lets both through).
    wire same_addr = l_sel && r_sel && (l_addr == r_addr);
    wire coll      = same_addr && (l_we || r_we);
    wire l_lose    = coll && !LEFT_WINS;   // left loses only if it is not the priority port
    wire r_lose    = coll &&  LEFT_WINS;   // right loses when left has priority

    assign l_busy_n = ~l_lose;             // /BUSY asserts (low) on the losing side
    assign r_busy_n = ~r_lose;

    // writes: only a write/write collision drops one (the loser's)
    wire ww    = same_addr && l_we && r_we;
    wire l_wr  = l_sel && l_we && !(ww && !LEFT_WINS);
    wire r_wr  = r_sel && r_we && !(ww &&  LEFT_WINS);

    // bypass: a read of the byte the other port writes this cycle returns
    // the written byte, never the array output (garbage on silicon)
    wire l_byp_d = r_wr && (r_addr == l_addr) && !(l_sel && l_we);
    wire r_byp_d = l_wr && (l_addr == r_addr) && !(r_sel && r_we);

    logic [7:0] l_q, r_q, l_bypd, r_bypd;
    logic       l_byp, r_byp;

    // Intel true-dual-port template, one read/write port per side; the two
    // ports never write one address in the same cycle (ww gating above).
    always_ff @(posedge clk) begin        // left port: V25
        if (l_wr) begin
            ram[l_addr] <= l_wdata;
            l_q         <= l_wdata;        // new-data on same-port write
        end else
            l_q         <= ram[l_addr];
    end
    always_ff @(posedge clk) begin        // right port: V60
        if (r_wr) begin
            ram[r_addr] <= r_wdata;
            r_q         <= r_wdata;
        end else
            r_q         <= ram[r_addr];
    end

    always_ff @(posedge clk) begin
        l_byp <= l_byp_d; l_bypd <= r_wdata;
        r_byp <= r_byp_d; r_bypd <= l_wdata;
    end
    assign l_rdata = l_byp ? l_bypd : l_q;
    assign r_rdata = r_byp ? r_bypd : r_q;

endmodule
