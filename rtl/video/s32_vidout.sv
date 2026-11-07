// s32_vidout.sv — carries the composed picture from clk_sys into CLK_VIDEO.
//
// Not a board function: it is the output stage between the 315-5242 DAC
// stand-in (8-bit RGB plus sync, composed in S32.sv) and the MiSTer
// framework, and it changes nothing the game can observe.
//
// Why (2026-11-06, GitHub MiSTer-devel/Arcade-SegaSystem32_MiSTer issue #1,
// "Direct video out to RT4K produces an intermittently shaky image"): in
// Direct Video the framework clocks the HDMI transmitter with CLK_VIDEO and
// sends the core's stream unchanged (sys/sys_top.v hdmi_clk_sw). With
// CLK_VIDEO = clk_sys (64.4318 MHz) the 320 mode's 6.25 MHz dot is 10.309
// clocks, so dots were 10 or 11 clocks wide and lines 4,123 or 4,124 clocks
// long in an irregular pattern, which a digital sink sees as a line length
// that will not hold still. The real board draws that mode from its own
// 50 MHz crystal (dot = 50 MHz / 8, s32tech; Q5), so the output now leaves
// on a 50 MHz video clock at exactly 8 clocks a dot: every line is 3,200
// clocks. The 416 mode's dot is clk_sys / 8 (the 32.2159 MHz crystal / 4),
// so for it S32.sv reconfigures the same PLL to clk_sys's exact frequency,
// again 8 clocks a dot. pll_vid/pll_vid_0002.v has the counter settings.
//
// The renderer keeps its own pace in clk_sys (s32_sys acc_pix: exactly
// 6.25 MHz at 320, clk_sys / 8 at 416), so the raster the CPU sees is
// untouched by anything here. Both clocks come from the same 50 MHz pin
// through two PLLs, so the write and read rates are EXACTLY equal on
// average and the buffer's fill only wanders by the 10/11-clock spacing of
// the write side (+-1 entry).
//
// Mechanism: every write-side dot (ce_in) writes one 29-bit word {rgb,
// sync, de, vblank, wide} to a 32-entry dual-clock RAM and advances a Gray
// write pointer. The read side synchronizes that pointer (two flops),
// reads one word every 8 clk_vid and presents it the next clock with
// ce_out. It reads LAG = 8 entries behind the write pointer. When the
// distance leaves [MIN_OCC, MAX_OCC], or vid_ok has been low (the PLL is
// being reconfigured or is not locked), the next read jumps back to
// exactly LAG behind: one torn dot, after which the line and frame
// lengths are again constant. Words are read at least MIN_OCC = 2 entries
// behind the synchronized pointer, i.e. many write-side clocks after they
// were written, and the writer cannot lap the reader (MAX_OCC = 14 < 32),
// so a read and a write never share an address (no read-during-write;
// AGENTS.md mixed-port rule).
//
// resync_cnt counts the jumps (saturating) for benches and the debug HUD:
// in steady state it must not move.

module s32_vidout #(
    parameter int LAG     = 8,
    parameter int MIN_OCC = 2,
    parameter int MAX_OCC = 14
) (
    // write side: the core's composed stream
    input  logic       clk_sys,
    input  logic       ce_in,
    input  logic [7:0] r_in, g_in, b_in,
    input  logic       hs_in, vs_in, de_in, vblank_in, wide_in,

    // read side: CLK_VIDEO
    input  logic       clk_vid,
    input  logic       vid_ok,       // async: PLL locked and configured for the mode
    output logic       ce_out,
    output logic [7:0] r_out, g_out, b_out,
    output logic       hs_out, vs_out, de_out, vblank_out, wide_out,
    output logic [7:0] resync_cnt
);

    localparam int W = 29;

    // ------------------------------------------------------------ write side
    (* ramstyle = "M10K, no_rw_check" *) logic [W-1:0] mem [0:31];
    logic [4:0] wptr  = '0;
    logic [4:0] wgray = '0;
    always_ff @(posedge clk_sys)
        if (ce_in) begin
            mem[wptr] <= {r_in, g_in, b_in, hs_in, vs_in, de_in, vblank_in, wide_in};
            wptr      <= wptr + 5'd1;
            wgray     <= (wptr + 5'd1) ^ ((wptr + 5'd1) >> 1);
        end

    // ------------------------------------------------------------- read side
    logic [4:0] wg_s1 = '0, wg_s2 = '0;      // Gray pointer synchronizer
    logic       ok_s1 = 1'b0, ok_s2 = 1'b0;  // vid_ok synchronizer
    always_ff @(posedge clk_vid) begin
        wg_s1 <= wgray;  wg_s2 <= wg_s1;
        ok_s1 <= vid_ok; ok_s2 <= ok_s1;
    end

    function automatic logic [4:0] gray2bin(input logic [4:0] g);
        gray2bin[4] = g[4];
        for (int i = 3; i >= 0; i--) gray2bin[i] = gray2bin[i+1] ^ g[i];
    endfunction
    wire [4:0] wbin = gray2bin(wg_s2);

    logic [2:0] div8    = '0;
    logic [4:0] rptr    = '0;
    logic       running = 1'b0;
    logic       rd_q    = 1'b0;
    logic [W-1:0] dout;
    wire        tick = (div8 == 3'd7);
    wire  [4:0] occ  = wbin - rptr;
    wire        jump = !running || (occ < 5'(MIN_OCC)) || (occ > 5'(MAX_OCC));
    wire  [4:0] raddr = jump ? (wbin - 5'(LAG)) : rptr;

    logic [7:0] rs_cnt = '0;
    assign resync_cnt = rs_cnt;
    always_ff @(posedge clk_vid) begin
        div8 <= div8 + 3'd1;
        rd_q <= tick && ok_s2;
        if (!ok_s2) running <= 1'b0;
        else if (tick) begin
            dout    <= mem[raddr];
            rptr    <= raddr + 5'd1;
            running <= 1'b1;
            if (jump && rs_cnt != 8'hFF) rs_cnt <= rs_cnt + 8'd1;
        end
    end

    // one clk after the read: present the word with its enable
    always_ff @(posedge clk_vid) begin
        ce_out <= rd_q;
        if (rd_q) {r_out, g_out, b_out, hs_out, vs_out, de_out, vblank_out, wide_out} <= dout;
    end

endmodule
