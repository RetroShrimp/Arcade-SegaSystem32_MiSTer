// s32_zromcache.sv — Z80 sound ROM, kept in SDRAM.
//
// The 4MB sound ROM is in SDRAM at byte base ZBASE. The Z80 sees it in two
// parts:
//
//  - Fixed region (ROM address below 0xA000: the Z80's 0000-9FFF plus any
//    banked access that lands there). The whole 40KB is copied from SDRAM
//    into block RAM once after reset (2,560 lines, ~40 M10K) and then read
//    with no wait states, like the board's directly wired EPROM.
//  - Banked window (A000-BFFF -> {bank, A[12:0]}): an 8KB direct-mapped
//    line cache with one window tag (zaddr[21:13]) and a valid bit per
//    line. The music driver selects a bank and walks it; a bank switch
//    clears the valid bits, and each line costs one ~25-clk fill on first
//    use.
//
// zhold stalls only the Z80 (s32_sys gates cen_z80 with it); the FM and
// PCM chips keep running, as during a real wait state. The Z80 samples read
// data at least 8 clks after driving the address, so the registered block
// RAM reads are always in time on a hit.
//
// SDRAM protocol (s32_sdram): req held with the address until the one-cycle
// done pulse; rf_data is the shared read bus, valid at this client's done.

module s32_zromcache #(
    parameter logic [24:0] ZBASE = 25'h1800000   // byte base in SDRAM
) (
    input  logic         clk,
    input  logic         rst,          // machine reset (rst_core)
    input  logic         go,           // SDRAM ready + ROM content loaded

    // Z80 side (s32_sys zrom port)
    input  logic [21:0]  zaddr,
    input  logic         zrd,
    output logic [7:0]   zdata,
    output logic         zhold,

    // SDRAM burst-read client
    output logic         rf_req,
    output logic [24:1]  rf_addr,
    input  logic [127:0] rf_data,
    input  logic         rf_done
);

    localparam logic [24:1] ZW = ZBASE[24:1];    // word base

    // ==================================================== fixed region
    // Preloaded once per reset (see the header): no fills while the game
    // runs, so no wait states.
    // ------------------------------------------------- line memories
    logic [127:0] wing  [0:511];      // 8KB banked window

    logic [127:0] fq, wq;
    logic         is_fixed;
    assign is_fixed = zaddr < 22'h00A000;

    // refill/init write strobes (single writer each: the FSM)
    logic         fx_we, wg_we;
    logic [11:0]  fx_waddr;
    logic [8:0]   wg_waddr;

    // fixed region, 40KB, on the explicit SDP wrapper (40 M10K blocks
    // instead of the 64 that inference uses)
    s32_sdp #(.AW(12), .NW(2560), .DW(128), .MAXDEPTH(256)) u_fixed (
        .clk(clk),
        .we(fx_we), .waddr(fx_waddr), .d(rf_data),
        .raddr(zaddr[15:4]), .q(fq)
    );
    always_ff @(posedge clk) begin    // window: FSM write + Z80 read
        if (wg_we) wing[wg_waddr] <= rf_data;
        wq <= wing[zaddr[12:4]];
    end

    // byte select on the registered line (zaddr is stable across the
    // Z80's read cycle; on a miss the Z80 is frozen until it hits)
    assign zdata = is_fixed ? fq[8 * zaddr[3:0] +: 8]
                            : wq[8 * zaddr[3:0] +: 8];

    // -------------------------------------------------- window tags
    logic [8:0]   wtag;
    logic         wtag_v;
    logic [511:0] lvalid;
    logic         init_done;

    logic hit_w;
    assign hit_w = wtag_v && (wtag == zaddr[21:13])
                          && lvalid[zaddr[12:4]];

    // fixed region NEVER misses after the preload; the window keeps its
    // lazy refill. Hold the Z80 until the preload completes (init_done).
    assign zhold = zrd && (!init_done || (!is_fixed && !hit_w));

    // --------------------------------------------------- init + fill
    // A hit/init release is delayed TWO cycles after the line write
    // (Z_SET1/Z_SET2): the BRAM write lands one edge after the done
    // pulse and the registered read (fq/wq) needs one more edge to
    // pick it up — only then may zhold drop, so the Z80's first
    // ungated cen always samples the new bytes.
    typedef enum logic [3:0] {
        Z_WAIT, Z_INIT, Z_IDLE, Z_FILL, Z_SET1, Z_SET2
    } zst_e;
    zst_e zst;

    logic [11:0] iline;                // preload line counter (0..2559)
    logic [8:0]  f_line;               // window line being filled
    logic        fill_kind;            // 0 = preload finished, 1 = window line

    always_ff @(posedge clk) begin
        fx_we <= 1'b0;
        wg_we <= 1'b0;
        if (rst) begin
            zst <= Z_WAIT;
            init_done <= 1'b0;
            wtag_v <= 1'b0;
            lvalid <= '0;
            iline <= 12'd0;
            // Never abandon an in-flight SDRAM request: s32_board's port-5
            // owner is released only by the done pulse, so dropping rf_req
            // mid-fill would hang the port (and with it a ROM reload). Hold
            // the request until done, discard the data, then park.
            if (rf_done || !rf_req) rf_req <= 1'b0;
        end else begin
            unique case (zst)
                Z_WAIT: begin                    // content not loaded yet
                    // finish a reset-drained request that outlived the reset
                    // window before issuing the preload's first burst
                    if (rf_done) rf_req <= 1'b0;
                    if (go && !rf_req) begin
                        iline <= 12'd0;
                        rf_req <= 1'b1;
                        rf_addr <= ZW + {9'd0, 12'd0, 3'b000};
                        zst <= Z_INIT;
                    end
                end

                Z_INIT:                          // stream 0000-9FFF (2560 lines)
                    if (rf_done) begin
                        fx_we <= 1'b1;
                        fx_waddr <= iline;
                        if (iline == 12'd2559) begin
                            rf_req <= 1'b0;
                            fill_kind <= 1'b0;
                            zst <= Z_SET1;
                        end else begin
                            iline <= iline + 12'd1;
                            rf_addr <= ZW + {9'd0, iline + 12'd1, 3'b000};
                        end
                    end

                Z_IDLE:
                    if (zrd && !is_fixed && !hit_w) begin
                        // bank switch: new window tag, all lines stale
                        if (!wtag_v || wtag != zaddr[21:13]) begin
                            wtag <= zaddr[21:13];
                            wtag_v <= 1'b1;
                            lvalid <= '0;
                        end
                        f_line <= zaddr[12:4];
                        rf_req <= 1'b1;
                        rf_addr <= ZW + {zaddr[21:4], 3'b000};
                        zst <= Z_FILL;
                    end

                Z_FILL:
                    if (rf_done) begin
                        rf_req <= 1'b0;
                        wg_we <= 1'b1;
                        wg_waddr <= f_line;
                        fill_kind <= 1'b1;
                        zst <= Z_SET1;
                    end

                Z_SET1: zst <= Z_SET2;           // BRAM write lands

                Z_SET2: begin                    // registered read caught up
                    if (fill_kind) begin
                        lvalid[f_line] <= 1'b1;
                        zst <= Z_IDLE;
                    end
                    else begin
                        init_done <= 1'b1;
                        zst <= Z_IDLE;
                    end
                end

                default: zst <= Z_IDLE;
            endcase
        end
    end

endmodule
