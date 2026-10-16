// mb8421.sv — Fujitsu MB8421 2K x 8 dual-port RAM (315-5533-02
// module mailbox: left = V25, right = V60 byte lane at A00000+2n).
//
// True dual-port, synchronous reads on both sides (one M10K).
//
// Datasheet behaviour (MB8421-12L, the grade fitted to the Golden Axe
// protection board): when both ports access one address at once, the
// first wins and the other's access is inhibited with its active-low /BUSY
// asserted; for simultaneous requests the LEFT port wins. /BUSY is
// open-drain, meant to drive a CPU READY input. The part's timings (120 ns
// access, 60 ns /BUSY, 25 ns arbitration setup) are all longer than a clk
// period, so here every same-cycle, same-address collision counts as
// simultaneous and the priority port wins.
//
// The board wires the V25 to the left (priority) port: V25 -> l_*, V60 ->
// r_*, LEFT_WINS=1.
//
// /BUSY is generated but not connected (whether it drives the V25's READY
// is not known), so the losing access is dropped rather than retried.
// Golden Axe never has both sides access one address in the same cycle,
// so this never happens in practice.

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

    // Intel true-dual-port template, one read/write port per side. On a
    // collision only the winner writes (the loser is gated by !*_lose), so
    // the two ports never write one address in the same cycle. The loser
    // reads the old data (on the real part it would retry after /BUSY).
    always_ff @(posedge clk) begin        // left port: V25
        if (l_sel && l_we && !l_lose) begin
            ram[l_addr] <= l_wdata;
            l_rdata     <= l_wdata;
        end else
            l_rdata     <= ram[l_addr];
    end
    always_ff @(posedge clk) begin        // right port: V60
        if (r_sel && r_we && !r_lose) begin
            ram[r_addr] <= r_wdata;
            r_rdata     <= r_wdata;
        end else
            r_rdata     <= ram[r_addr];
    end

endmodule
