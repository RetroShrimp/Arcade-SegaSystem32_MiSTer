// s32_v60fetch.sv — program ROM line adapter: presents a 14-byte window
// at fetch_pc from SDRAM. Two aligned 16-byte line buffers (current and
// next) serve the window combinationally; on a miss fetch_hold stalls the
// requester while a line refills (one 16-byte SDRAM burst).
//
// Sequential flow rarely stalls: when fetch_pc crosses into the next line,
// L0 <= L1 and the following line refills in the background. The requester
// waits only if it runs ahead of the refill or jumps outside the buffered
// pair.
//
// The F00000+ mirror (ROM offset 0, 1MB window) is folded here so
// the refill port sees plain ROM byte addresses.

module s32_v60fetch (
    input  logic         clk,
    input  logic         rst,

    // core side
    input  logic [23:0]  fetch_pc,
    output logic [111:0] fetch_bytes,
    output logic         fetch_hold,   // freeze the core (OR into wait_hold)

    // refill port: one 16-byte line per request/done handshake (the
    // SDRAM burst-read port shape)
    output logic         rf_req,       // level until rf_done
    output logic [20:4]  rf_line,      // line address
    input  logic [127:0] rf_data,
    input  logic         rf_done       // 1-cycle
);

    // ROM byte index with the F00000+ mirror folded
    logic [20:0] pcb;
    assign pcb = (fetch_pc[23:20] == 4'hF) ? {1'b0, fetch_pc[19:0]}
                                           : fetch_pc[20:0];

    logic [16:0] line_of;              // 16-byte line index
    logic [3:0]  off;
    assign line_of = pcb[20:4];
    assign off    = pcb[3:0];

    // ------------------------------------------------- line buffers
    logic [127:0] l0, l1;
    logic [16:0]  l0_tag, l1_tag;
    logic         l0_v, l1_v;

    // 32-byte view; the window is a 14-byte slice starting at off
    logic [255:0] pair;
    assign pair = {l1, l0};

    integer bi;
    always_comb begin
        // byte i of the window = pair byte (off + i); fetch_bytes is
        // MSB-first (byte 0 in [111:104])
        for (bi = 0; bi < 14; bi = bi + 1)
            fetch_bytes[111 - bi*8 -: 8] =
                pair[({4'd0, off} + bi[7:0]) * 8 +: 8];
    end

    // window valid: current line buffered and, if the window spills
    // into the next line (off > 2), that one too
    logic hit;
    assign hit = l0_v && (l0_tag == line_of) &&
                 (off <= 4'd2 || (l1_v && l1_tag == line_of + 17'd1));

    assign fetch_hold = !hit;

    // ---------------------------------------------------- refill FSM
    typedef enum logic [1:0] { F_IDLE, F_REQ } fstate_e;
    fstate_e fst;
    logic        fill_l1;              // target: 0 = l0, 1 = l1
    logic [16:0] fill_tag;

    assign rf_req  = (fst == F_REQ);
    assign rf_line = fill_tag;

    always_ff @(posedge clk) begin
        if (rst) begin
            l0_v <= 1'b0;
            l1_v <= 1'b0;
            fst  <= F_IDLE;
        end else begin
            unique case (fst)
                F_IDLE: begin
                    if (l0_v && l0_tag == line_of &&
                        !(l1_v && l1_tag == line_of + 17'd1)) begin
                        // background prefetch of the next line
                        fill_l1  <= 1'b1;
                        fill_tag <= line_of + 17'd1;
                        fst  <= F_REQ;
                    end else if (!l0_v || l0_tag != line_of) begin
                        if (l1_v && l1_tag == line_of) begin
                            // sequential advance: promote L1
                            l0     <= l1;
                            l0_tag <= l1_tag;
                            l0_v   <= 1'b1;
                            l1_v   <= 1'b0;
                        end else begin
                            // jump: refill the current line first
                            fill_l1  <= 1'b0;
                            fill_tag <= line_of;
                            fst  <= F_REQ;
                            l0_v <= 1'b0;
                            l1_v <= 1'b0;
                        end
                    end
                end

                F_REQ: if (rf_done) begin
                    if (fill_l1) begin
                        l1     <= rf_data;
                        l1_tag <= fill_tag;
                        l1_v   <= 1'b1;
                    end else begin
                        l0     <= rf_data;
                        l0_tag <= fill_tag;
                        l0_v   <= 1'b1;
                    end
                    fst <= F_IDLE;
                end

                default: fst <= F_IDLE;
            endcase
        end
    end

endmodule
