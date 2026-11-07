`timescale 1 ps / 1 ps
// pll_vid - CLK_VIDEO source (2026-11-06, GitHub issue #1: Direct Video).
// See pll_vid/pll_vid_0002.v for the counter settings and S32.sv for the
// run-time reconfiguration between 50 MHz (320 mode) and 64.431818 MHz (416).
module pll_vid (
		input  wire        refclk,            //  refclk.clk
		input  wire        rst,               //   reset.reset
		output wire        outclk_0,          // outclk0.clk  CLK_VIDEO
		output wire        locked,            //  locked.export
		input  wire [63:0] reconfig_to_pll,   // reconfig_to_pll
		output wire [63:0] reconfig_from_pll  // reconfig_from_pll
	);

	pll_vid_0002 pll_vid_inst (
		.refclk            (refclk),
		.rst               (rst),
		.outclk_0          (outclk_0),
		.locked            (locked),
		.reconfig_to_pll   (reconfig_to_pll),
		.reconfig_from_pll (reconfig_from_pll)
	);

endmodule
