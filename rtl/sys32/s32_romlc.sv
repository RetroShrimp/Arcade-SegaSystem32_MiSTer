// s32_romlc.sv — program ROM line cache between a V60 ROM adapter's refill
// port (s32_v60fetch rf_*) and its SDRAM line port, on the board only.
//
// Why (docs/svf-bringup.md 6.11, 2026-10-21): s32_v60fetch buffers just the
// current and next 16-byte line, so every jump outside that pair (call,
// return, a loop back to an earlier line) refills from SDRAM. The real board
// reads its EPROMs in the V60's own bus cycles, which v60_bcu already
// models, and has no refill at all. The ideal-memory machine (sim/s32_sys)
// answers a refill in one cycle; the board took an SDRAM round trip. In
// svf's replay transition the board's V60 spent 38% of its cycles waiting on
// fetch refills (s32_sys: 5%), so the game ran its black phase ~30 frames
// long against s32_sys's ~20, and a one-frame garbage sprite list reached the
// banner's fade-in. Over the whole attract: 9% against 1%.
//
// Direct-mapped, 2^IDXW lines of 16 bytes. One M10K array holds
// {valid, tag, data}; a hit answers rf_done the cycle after rf_req rises,
// the ideal bench's latency. A miss runs one SDRAM line read and fills.
// ROM changes only while the core is held in reset (download), so reset
// clears the valid bits with a sweep (2^IDXW cycles). A fill in flight when
// reset arrives completes first, so no SDRAM read is abandoned mid-burst
// and no late done can be taken for another line.
//
// RAM inference (AGENTS.md): one array, one write port, one registered read
// enabled only in C_IDLE; writes happen only in C_CLR and C_FILL, so the two
// ports never touch the array in the same cycle (no_rw_check states that).

module s32_romlc #(
    parameter int IDXW = 8
) (
    input  logic         clk,
    input  logic         rst,

    // requester: s32_v60fetch refill port
    input  logic         up_req,       // level until up_done
    input  logic [20:4]  up_line,
    output logic [127:0] up_data,
    output logic         up_done,      // 1-cycle

    // SDRAM line read port (same handshake)
    output logic         dn_req,
    output logic [20:4]  dn_line,
    input  logic [127:0] dn_data,
    input  logic         dn_done
);

    localparam int TW = 17 - IDXW;            // tag bits
    localparam int W  = 1 + TW + 128;         // {valid, tag, data}

    (* ramstyle = "M10K, no_rw_check" *) logic [W-1:0] mem [0:(1<<IDXW)-1];

    typedef enum logic [2:0] { C_CLR, C_IDLE, C_LOOK, C_FILL, C_RESP } cstate_e;
    cstate_e st = C_CLR;

    logic [IDXW-1:0] clr_i = '0;
    logic [20:4]     line_q;
    logic            clr_pend = 1'b0;
    logic [W-1:0]    q;
    logic [127:0]    fill_q;

    // read: only in C_IDLE, at the requested line's index
    always_ff @(posedge clk)
        if (st == C_IDLE) q <= mem[up_line[IDXW+3:4]];

    // write: the clear sweep, or a completed fill
    logic            we;
    logic [IDXW-1:0] widx;
    logic [W-1:0]    wdata;
    always_comb begin
        we    = (st == C_CLR) || (st == C_FILL && dn_done && !clr_pend && !rst);
        widx  = (st == C_CLR) ? clr_i : line_q[IDXW+3:4];
        wdata = (st == C_CLR) ? '0 : {1'b1, line_q[20:IDXW+4], dn_data};
    end
    always_ff @(posedge clk)
        if (we) mem[widx] <= wdata;

    logic hit;
    assign hit = q[W-1] && (q[W-2 -: TW] == line_q[20:IDXW+4]);

    assign up_done = !rst && !clr_pend &&
                     ((st == C_LOOK && hit) || st == C_RESP);
    assign up_data = (st == C_RESP) ? fill_q : q[127:0];
    assign dn_req  = (st == C_FILL);
    assign dn_line = line_q;

    always_ff @(posedge clk) begin
        if (rst) clr_pend <= 1'b1;
        unique case (st)
            C_CLR: begin
                clr_i <= clr_i + 1'b1;
                if (&clr_i) st <= C_IDLE;      // re-enters C_CLR if still in reset
            end
            C_IDLE:
                if (rst || clr_pend) begin
                    st       <= C_CLR;
                    clr_i    <= '0;
                    clr_pend <= 1'b0;
                end else if (up_req) begin
                    line_q <= up_line;
                    st     <= C_LOOK;
                end
            C_LOOK:
                if (rst || clr_pend || hit) st <= C_IDLE;
                else                        st <= C_FILL;
            C_FILL:
                // never abandoned: a reset here waits for the burst to end
                if (dn_done) begin
                    fill_q <= dn_data;
                    st     <= C_RESP;
                end
            C_RESP: st <= C_IDLE;
            default: st <= C_IDLE;
        endcase
    end

endmodule
