// s32_mromcache.sv — V25 protection ROM cache. (The 64KB ROM as block RAM
// would cost ~64 M10K blocks, more than the device has to spare.)
//
// The ROM dump, still scrambled, is in SDRAM at MBASE. The V25 presents
// already-scrambled addresses (the descramble is in s32_v25), so cache
// lines are contiguous in the dump and can be filled with bursts. Any
// region with fixed i[15], i[14] and i[11] maps onto one window tag
// (maddr[15:13] = {i[14], i[11], i[15]}), so an active program region of up
// to 8KB never has conflict misses.
//
// 8KB direct-mapped window, 16-byte lines, one 3-bit tag + 512 valid
// bits (cleared on a tag switch). A miss raises mhold, which freezes the
// V25 (s32_v25 hold input) with its address held until the line lands. As
// in s32_zromcache, the release waits two cycles so the registered line
// read already shows the new bytes.
//
// No init sweep: rst (rst_core) covers the load window — the V25
// only fetches after the machine starts, by which time the loader
// has filled SDRAM.

module s32_mromcache #(
    parameter logic [24:0] MBASE = 25'h1C00000   // byte base in SDRAM
) (
    input  logic         clk,
    input  logic         rst,          // machine reset (rst_core)

    // V25 side (s32_sys mrom port)
    input  logic [15:0]  maddr,
    input  logic         mrd,
    output logic [7:0]   mdata,
    output logic         mhold,

    // SDRAM burst-read client (shared port; owner-arbitrated outside)
    output logic         rf_req,
    output logic [24:1]  rf_addr,
    input  logic [127:0] rf_data,
    input  logic         rf_done
);

    localparam logic [24:1] MW = MBASE[24:1];    // word base

    logic [127:0] wing [0:511];       // 8KB, one line per word
    logic [127:0] wq;

    logic         wg_we;
    logic [8:0]   wg_waddr;

    always_ff @(posedge clk) begin    // FSM write + V25 read
        if (wg_we) wing[wg_waddr] <= rf_data;
        wq <= wing[maddr[12:4]];
    end

    assign mdata = wq[8 * maddr[3:0] +: 8];

    logic [2:0]   wtag;
    logic         wtag_v;
    logic [511:0] lvalid;

    logic hit;
    assign hit = wtag_v && (wtag == maddr[15:13])
                        && lvalid[maddr[12:4]];

    assign mhold = mrd && !hit;

    typedef enum logic [1:0] { M_IDLE, M_FILL, M_SET1, M_SET2 } mst_e;
    mst_e mst;
    logic [8:0] f_line;

    always_ff @(posedge clk) begin
        wg_we <= 1'b0;
        if (rst) begin
            mst <= M_IDLE;
            wtag_v <= 1'b0;
            lvalid <= '0;
            // hold an in-flight request through reset until its done
            // pulse, or the shared port 5 would hang (as in s32_zromcache)
            if (rf_done || !rf_req) rf_req <= 1'b0;
        end else begin
            unique case (mst)
                M_IDLE: begin
                    // finish a reset-drained request that outlived the
                    // reset window before issuing anything new
                    if (rf_done) rf_req <= 1'b0;
                    if (mrd && !hit && !rf_req) begin
                        if (!wtag_v || wtag != maddr[15:13]) begin
                            wtag <= maddr[15:13];
                            wtag_v <= 1'b1;
                            lvalid <= '0;
                        end
                        f_line <= maddr[12:4];
                        rf_req <= 1'b1;
                        rf_addr <= MW + {5'd0, maddr[15:4], 3'b000};
                        mst <= M_FILL;
                    end
                end

                M_FILL:
                    if (rf_done) begin
                        rf_req <= 1'b0;
                        wg_we <= 1'b1;
                        wg_waddr <= f_line;
                        mst <= M_SET1;
                    end

                M_SET1: mst <= M_SET2;           // BRAM write lands

                M_SET2: begin                    // registered read caught up
                    lvalid[f_line] <= 1'b1;
                    mst <= M_IDLE;
                end

                default: mst <= M_IDLE;
            endcase
        end
    end

endmodule
