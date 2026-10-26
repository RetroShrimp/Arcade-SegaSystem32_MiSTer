// s32_bitmap_live.sv — 315-5387 bitmap layer.
//
// The 315-5387 reads a line's source data out of VRAM's serial ports
// during the line before (s32tech, row transfer); the pixel pipeline then
// reads that private copy as the beam advances, so a CPU VRAM write after
// the row transfer shows from the next line.
//
//  - row_start (ROW_XFER_HCNT of the line before): latch srcy for `line`,
//    then walk the source row span it needs out of VRAM (while the arbiter
//    grants it: vr_ok) into the private `row` buffer, one word per granted
//    clk. The address holds while the walk is paused, so a repeated store
//    is harmless. Span = 161 words (8bpp) / 81 (4bpp): the 320 visible
//    dots (209 / 105 for 416) plus one word for an unaligned scroll, stored
//    at their absolute
//    row positions so the beam needs no wrap arithmetic.
//  - line_start (start of the beam stream): reset the beam column; each
//    cen_pix advances one dot. The pen is combinational off the registered
//    row read rq (1 clk), with effx_q selecting within the word.
//
// Addressing and pens:
//   4bpp: 128 words/row, addr {srcy, effx[8:2]}, pen = nibble effx[1:0]
//   8bpp: 256 words/row, addr {srcy[7:0], effx[8:1]}, pen = byte effx[0]
//   effx = beam_x + xscroll (wraps at 512); srcy = line + yscroll
//   pix  = pen ? (cbase + pen) : 0   (0 = transparent), cbase per $31FF8C
//
// The beam never waits; only the walk can pause (vr_ok low). A walk that
// cannot finish in time leaves stale row entries.

module s32_bitmap_live (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_pix,      // one pulse per displayed dot (6.25 MHz)
    input  logic        wide,         // 416-pixel mode (s32_video): 416 dots
    input  logic        line_start,   // beam stream start (HBLANK, BF_FSTART)
    input  logic [7:0]  line,         // upcoming visible line (sampled at row_start)

    // decoded configuration
    input  logic        bpp8,         // $31FF00 bit 11
    input  logic [15:0] r88,          // X scroll
    input  logic [15:0] r8a,          // Y scroll
    input  logic [15:0] r8c,          // palette base

    // row-transfer walk port (shared VRAM port B, granted by the arbiter)
    input  logic        row_start,    // ROW_XFER pulse: latch line state, walk
    input  logic        vr_ok,        // walk grant, not paused
    output logic        vr_busy,      // walk in flight (arbiter holds grant)
    output logic        vr_re,        // = vr_busy
    output logic [15:0] vr_addr,
    input  logic [15:0] vr_rdata,     // 1-clk registered read

    // VRAM cache prefetch hint for the next line's source row (experimental;
    // unused here, tied 0). A hint only moves fetches earlier; it never
    // changes what a read returns.
    output logic [15:0] pf_hint_addr,
    output logic        pf_hint_vld,
    input  logic        pf_hint_take,  // s32_vramcache latched pf_hint_addr

    // beam pixel output (pen + color base, 0 = transparent)
    output logic [13:0] pix,
    output logic        pix_valid     // beam word has been fetched
);

    logic [8:0] xscroll, yscroll;
    assign xscroll = r88[8:0];
    assign yscroll = r8a[8:0];

    logic [13:0] cbase;
    assign cbase = 14'({r8c[8:0], 4'd0}) & (bpp8 ? 14'h3F00 : 14'h3FF0);

    // ------------------------------------------------ row-transfer walk
    // touched span: first word = xscroll>>k, count = W>>k + 1, W the visible
    // width (the +1 covers a non-aligned scroll where the last dot's word
    // wraps into one more entry). Words wrap modulo the row width (256 / 128).
    logic [8:0] srcy;
    // two banks: the walk fills walk_bank (the next line) while the beam
    // reads show_bank (the current line)
    logic walk_bank, show_bank;
    always_ff @(posedge clk) begin
        if (rst) begin walk_bank <= 1'b0; show_bank <= 1'b0; end
        else begin
            if (row_start)  walk_bank <= line[0];
            if (line_start) show_bank <= walk_bank;
        end
    end
    (* ramstyle = "MLAB" *) logic [15:0] row [0:511];

    localparam int W8 = 161, W4 = 81;         // real touched words (worst case);
    localparam int W8_416 = 209, W4_416 = 105; // the same for 416 dots
                                              // the walk takes count granted
                                              // cycles (the final word stores
                                              // via the st pipe one clk on)
    logic [7:0] wstart;                        // first touched word (absolute)
    logic [8:0] widx;                          // walk step 0..count-1
    logic       st_p;                          // word consumed last clk:
                                               // store NOW, vr_ok or not
                                               // (waiting for vr_ok would
                                               // store a wrong word after
                                               // every mid-walk pause)
    logic [7:0] st_abs;                        // its absolute store target
    logic       walking;
    logic       wide_q;                        // this walk's width
    wire  [8:0] wcount = bpp8 ? (wide_q ? 9'(W8_416) : 9'(W8))
                              : (wide_q ? 9'(W4_416) : 9'(W4));
    // presented step clamps at the last real word so a stall at the tail
    // re-presents the final entry
    wire  [8:0] wstep  = (widx < wcount - 9'd1) ? widx : (wcount - 9'd1);
    wire  [7:0] wabs   = bpp8 ? 8'(wstart + wstep[7:0])
                              : {1'b0, 7'(wstart[6:0] + wstep[6:0])};
    assign vr_busy = walking;
    assign vr_re   = walking;
    assign vr_addr = bpp8 ? {srcy[7:0], wabs} : {srcy, wabs[6:0]};

    always_ff @(posedge clk) begin
        if (rst) begin
            walking <= 1'b0; st_p <= 1'b0;
        end else begin
            st_p <= 1'b0;
            if (st_p) row[{walk_bank, st_abs}] <= vr_rdata;
            if (row_start) begin
                // MAME bitmap Y: 8bpp masks to 256 rows, 4bpp to 512
                srcy    <= bpp8 ? {1'b0, 8'(line + yscroll[7:0])}
                                : 9'({1'b0, line} + yscroll);
                wstart  <= bpp8 ? xscroll[8:1] : {1'b0, xscroll[8:2]};
                wide_q  <= wide;
                widx    <= 9'd0;
                walking <= 1'b1;
            end else if (walking && vr_ok) begin
                st_abs <= wabs;
                st_p   <= 1'b1;
                if (widx == wcount - 9'd1) walking <= 1'b0;
                else widx <= widx + 9'd1;
            end
        end
    end

    // ------------------------------------------------ prefetch hint
    assign pf_hint_addr = 16'd0;
    assign pf_hint_vld  = 1'b0;

    // ------------------------------------------------------- beam stream
    // srcy latched at row_start; pixctr is the beam column, advanced one
    // dot per cen_pix from line_start. Reads only the private row.
    logic [8:0] pixctr;               // 0..319 (415 when wide)
    wire  [8:0] pixlast = wide ? 9'd415 : 9'd319;
    logic [8:0] effx; assign effx = pixctr + xscroll;   // 9-bit, wraps at 512

    // registered row read (1-clk latency)
    logic [15:0] rq;
    always_ff @(posedge clk)
        rq <= row[{show_bank, (bpp8 ? effx[8:1] : {1'b0, effx[8:2]})}];

    // in-word select uses a REGISTERED copy of effx so the nibble/byte index
    // lines up with the word already in rq (1-cycle read latency).
    logic [8:0] effx_q;
    logic       started;              // a word has been fetched since line_start

    logic [7:0] pen;
    always_comb begin
        if (bpp8)
            pen = effx_q[0] ? rq[15:8] : rq[7:0];
        else
            unique case (effx_q[1:0])
                2'd0: pen = {4'd0, rq[3:0]};
                2'd1: pen = {4'd0, rq[7:4]};
                2'd2: pen = {4'd0, rq[11:8]};
                default: pen = {4'd0, rq[15:12]};
            endcase
    end

    assign pix       = (pen == 8'd0) ? 14'd0 : cbase + {6'd0, pen};
    assign pix_valid = started;

    always_ff @(posedge clk) begin
        if (rst) begin
            pixctr  <= 9'd0;
            effx_q  <= 9'd0;
            started <= 1'b0;
        end else if (line_start) begin
            pixctr  <= 9'd0;
            effx_q  <= xscroll;   // effx at pixctr 0
            started <= 1'b0;
        end else begin
            effx_q  <= effx;      // track the fetched word's effx (1-clk)
            started <= 1'b1;
            if (cen_pix && pixctr != pixlast) pixctr <= pixctr + 9'd1;
        end
    end

endmodule
