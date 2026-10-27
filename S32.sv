//============================================================================
//  Sega System 32 — MiSTer top level.
//
//  clk_sys = 64.4318 MHz (2x the 32.2159 MHz board master); everything
//  below runs on clock enables derived inside s32_sys. The 32 MB SDRAM
//  holds the program, sound, tile and sprite ROMs and the tilemap VRAM
//  (arbitrated by s32_sdram); the sprite frame buffers live in DDR3.
//
//  ROM image as the .mra delivers it (download index 0):
//    0x0000000 +2MB  maincpu  -> SDRAM 0x0000000 (V60 program)
//    0x0200000 +4MB  soundcpu -> SDRAM 0x1800000 (Z80, via s32_zromcache)
//    0x0600000 +64KB mcu      -> SDRAM 0x1C00000 (V25, via s32_mromcache)
//    0x0610000 +4MB  tiles    -> SDRAM 0x0200000
//    0x0A10000 +16MB sprites  -> SDRAM 0x0600000
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM: the fast ROM loader (s32_ddrload) owns it while the ROM image is
// being pulled, and the sprite frame buffers (s32_fbddr) own it afterwards.
// The loader runs only while rst_core is held, so the two never overlap and a
// plain mux is enough; an arbiter would add a grant that could hang if a
// request were dropped before its done pulse.
assign DDRAM_CLK = clk_sys;
assign DDRAM_BURSTCNT = ddr_busy_l ? ld_ddr_burstcnt : fb_ddr_burstcnt;
assign DDRAM_ADDR     = ddr_busy_l ? ld_ddr_addr     : fb_ddr_addr;
assign DDRAM_RD       = ddr_busy_l ? ld_ddr_rd       : fb_ddr_rd;
assign DDRAM_DIN      = ddr_busy_l ? 64'd0           : fb_ddr_din;
assign DDRAM_BE       = ddr_busy_l ?  8'd0           : fb_ddr_be;
assign DDRAM_WE       = ddr_busy_l ?  1'b0           : fb_ddr_we;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;               // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// Aspect ratio (O[122:121]). VIDEO_ARX/ARY are driven by the video_freak
// instance in the video section, which starts from these ratios and replaces
// them with an exact pixel size in the integer Scale modes. "Original" is 4:3:
// every supported game is a horizontal cabinet and the 320x224 raster fills a
// 4:3 tube. `ar == 0` is spelled out rather than `!ar` (a logical NOT of a
// 2-bit field is a Verilator WIDTHTRUNC).
wire  [1:0] ar  = status[122:121];
wire [11:0] arx = (ar == 2'd0) ? 12'd4 : 12'(ar - 1'd1);
wire [11:0] ary = (ar == 2'd0) ? 12'd3 : 12'd0;

// CRT Adjust (O[35] + the three amounts), rmonic79's MiSTer-CRT-Adjust,
// core-side variant: rtl/video/s32_crt_adjust.sv has the raster numbers and
// why H-Position is a content shift. Every amount is plain two's complement,
// so each list is 0,+1..+max then -min..-1. Off is a bit-exact bypass. H1
// hides the amounts whenever the stage is not running (`crt_enable`). The
// lines are in CONF_STR below.

`include "build_id.v"
localparam CONF_STR = {
	"S32;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:33],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer;",
	"-;",
	"P1,CRT Adjust;",
	"P1-,Analog/direct video - HDMI uses Scale;",
	"P1O[35],CRT Adjust,Off,On;",
	"H1P1O[40:36],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[47:41],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,+49,+50,+51,+52,+53,+54,+55,+56,+57,+58,+59,+60,+61,+62,+63,-64,-63,-62,-61,-60,-59,-58,-57,-56,-55,-54,-53,-52,-51,-50,-49,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[53:48],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"O[10],Service,Off,On;",
	"-;",
	"T[0],Reset;",
	"J1,Attack,Jump,Magic,Start,Coin,Service,Test,Button 4,Button 5,Button 6;",
	"jn,A,B,X,Start,R,L,Select;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
// CRT Adjust master enable; status_menumask reads it too, so the menu never
// offers an amount the stage is ignoring. The forced-scandoubler term is
// upstream's integration rule: the stage fits a native 15 kHz raster.
wire crt_enable;
wire   [1:0] buttons;
wire [127:0] status;
wire  [31:0] joystick_0, joystick_1, joystick_2, joystick_3;
wire  [15:0] stick_0, stick_1, stick_2;   // left analog: [7:0] X, [15:8] Y
wire  [24:0] ps2_mouse;                   // [24] toggles per packet
assign crt_enable = status[35] & ~forced_scandoubler;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire        ioctl_upload;
wire  [7:0] ioctl_din;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, ~crt_enable, 1'b0}),   // H1 = CRT Adjust amounts

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(dump_req),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.joystick_l_analog_0(stick_0),
	.joystick_l_analog_1(stick_1),
	.joystick_l_analog_2(stick_2),
	.ps2_mouse(ps2_mouse)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_sdram, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys),               // 64.4318 MHz
	.outclk_1(clk_sdram),             // 64.4318 MHz, -90 deg
	.locked(pll_locked)
);

///////////////////////   RESETS   ///////////////////////////////

// rst_ctrl releases the SDRAM controller as soon as the PLL locks;
// rst_core holds the machine through ROM download and for a short
// tail so the loader's last burst drains (the board's erase/load
// path runs only while rst_core is asserted).
wire reset_req = RESET | status[0] | buttons[1];


reg  rst_ctrl_r = 1;
always @(posedge clk_sys) rst_ctrl_r <= ~pll_locked | RESET;

// ld_wait: a DDR3 fast load is pending, waiting for the frame buffer side
// to go quiet (see ddr_start_pend below); keep the core in reset meanwhile
wire ld_wait;
reg  [15:0] core_hold = 16'hFFFF;
always @(posedge clk_sys) begin
	if (reset_req | ioctl_download | rst_ctrl_r | ddr_busy_l | ld_wait)
		core_hold <= 16'hFFFF;
	else if (core_hold != 0)
		core_hold <= core_hold - 1'd1;
end
wire rst_core = (core_hold != 0);

//////////////////////   ROM LOADING   ///////////////////////////

// ROM image offsets -> SDRAM byte addresses
reg         ld_wr = 0;
reg  [24:0] ld_addr;
reg   [7:0] ld_data;
wire        ld_rdy;

// One map serves both byte sources: the hps_io download stream and the
// DDR3 fast loader.
wire [26:0] ld_src_a = ddr_busy_l ? ddr_offs : ioctl_addr[26:0];
reg        ld_map_v;
reg [24:0] ld_map;
always @(*) begin
	ld_map_v = 1;
	ld_map = 25'h0;
	if (ld_src_a < 27'h0200000)                              // V60
		ld_map = ld_src_a[24:0];
	else if (ld_src_a < 27'h0600000)                         // Z80
		ld_map = 25'h1800000 + (ld_src_a[24:0] - 25'h0200000);
	else if (ld_src_a < 27'h0610000)                         // V25
		ld_map = 25'h1C00000 + {9'd0, ld_src_a[15:0]};
	else if (ld_src_a < 27'h0A10000)                         // tiles
		ld_map = 25'h0200000 + (ld_src_a[24:0] - 25'h0610000);
	else if (ld_src_a < 27'h1A10000)                         // sprites
		ld_map = 25'h0600000 + (ld_src_a[24:0] - 25'h0A10000);
	else
		ld_map_v = 0;
end

// Skid buffer: the board accepts a byte only while ld_rdy (it drops writes
// during a line flush), and hps_io's ioctl_wait acts one byte late. Each byte
// therefore waits in a pending register and is issued only under ld_rdy,
// with one idle cycle after each issue so a flush started by an
// addr[3:0]==F byte is visible before the next one.
reg        ld_pend = 0;
reg        ld_gap = 0;
reg [24:0] ld_pa;
reg  [7:0] ld_pd;
// The DDR3 loader offers a byte with dv and advances when the skid is free,
// the same one-byte-in-flight rule ioctl_wait gives the hps_io stream.
wire ddr_take = ddr_dv && !ld_pend && !ld_wr;
always @(posedge clk_sys) begin
	ld_wr <= 0;
	ld_gap <= ld_wr;
	if ((ioctl_wr && ioctl_download && ioctl_index == 0 && ld_map_v)
	    || (ddr_take && ld_map_v)) begin
		ld_pend <= 1;
		ld_pa <= ld_map;
		ld_pd <= ddr_busy_l ? ddr_byte : ioctl_dout;
	end else if (ld_pend && ld_rdy && !ld_wr && !ld_gap) begin
		ld_addr <= ld_pa;
		ld_data <= ld_pd;
		ld_wr <= 1;
		ld_pend <= 0;
	end
end

// hold the HPS off while a byte is pending or the board can't take
// one (ld_rdy also covers SDRAM-controller init)
assign ioctl_wait = ioctl_download && (ld_pend || ld_wr || !ld_rdy);

// ---- Fast ROM load through DDR3: the .mra carries address="0x30000000",
// so the MiSTer firmware copies the image into DDR3 itself and sends an
// empty index-0 download (start, seek to the length, end; no data). Detect
// that and pull the image over DDRAM_*. A download that carries data still
// takes the byte-by-byte path.
reg [26:0] dl_bytes = 0;
always @(posedge clk_sys) begin
	if (ioctl_download && !dl_q)
		dl_bytes <= 0;                       // download start
	else if (ioctl_wr && ioctl_download && ioctl_index == 0)
		dl_bytes <= dl_bytes + 1'd1;
end
// hps_io bumps ioctl_addr once at download end, so the firmware's "seek to
// the length, then end" arrives as length+1; an empty download with no seek
// arrives as 1 and must not trigger.
wire ddr_start = dl_q && !ioctl_download && ioctl_index == 0
                 && dl_bytes == 0 && ioctl_addr > 27'd1;
// The loader takes the shared DDRAM port only once the sprite frame buffer
// side has finished the transaction it was in when the download reset it
// (s32_fbddr header: a half-finished burst wedges f2sdram until power-off).
// rst_core is already held from the download's start, so this waits a few
// hundred clk at most.
wire fbddr_quiet;
reg  ddr_start_pend = 0;
reg [26:0] ddr_len_q = 0;
always @(posedge clk_sys) begin
	if (rst_ctrl_r)
		ddr_start_pend <= 0;
	else if (ddr_start) begin
		ddr_start_pend <= 1;
		ddr_len_q      <= ioctl_addr[26:0] - 27'd1;
	end else if (ddr_start_pend && fbddr_quiet)
		ddr_start_pend <= 0;
end
wire        ddr_go_ld  = ddr_start_pend && fbddr_quiet;
assign ld_wait = ddr_start_pend;
wire [26:0] ddr_len_ld = ddr_len_q;

// loader-side DDRAM signals, muxed onto the pins above
wire  [7:0] ld_ddr_burstcnt;
wire [28:0] ld_ddr_addr;
wire        ld_ddr_rd;
// sprite frame buffer side
wire  [7:0] fb_ddr_burstcnt, fb_ddr_be;
wire [28:0] fb_ddr_addr;
wire [63:0] fb_ddr_din;
wire        fb_ddr_rd, fb_ddr_we;
wire        ddr_busy_l, ddr_done, ddr_dv;
wire [26:0] ddr_offs;
wire  [7:0] ddr_byte;
s32_ddrload ddrload (
	.clk(clk_sys), .rst(rst_ctrl_r),
	.start(ddr_go_ld), .length(ddr_len_ld),
	.busy(ddr_busy_l), .done(ddr_done),
	.dv(ddr_dv), .doffs(ddr_offs), .dbyte(ddr_byte),
	.stall(ld_pend || ld_wr),
	.ddr_busy(DDRAM_BUSY), .ddr_burstcnt(ld_ddr_burstcnt),
	.ddr_addr(ld_ddr_addr), .ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY && ddr_busy_l), .ddr_rd(ld_ddr_rd)
);

reg dl_q = 0;
always @(posedge clk_sys) dl_q <= ioctl_download;


// ---- NVRAM file (.mra <nvram index="2" size="8320">):
//   0-127     93C46 EEPROM (64 x 16 bits, little-endian bytes)
//   128-8319  Z80 work RAM (battery-backed on the real board)
// The file is restored while the machine is held in reset, before the Z80
// starts, so the sound program wakes up to the saved contents as it would
// on a board with a battery. Saving while the game runs reads the Z80 RAM
// in the sound CPU's idle cycles. A 128-byte file restores the EEPROM only.
reg        ee_init_wen = 0;
reg  [5:0] ee_init_addr;
reg [15:0] ee_init_data;
reg  [7:0] ee_lo;
reg        zram_nv_wr = 0;
reg [12:0] zram_nv_wa;
reg  [7:0] zram_nv_wd;
always @(posedge clk_sys) begin
	ee_init_wen <= 0;
	zram_nv_wr <= 0;
	if (ioctl_wr && ioctl_download && ioctl_index == 2) begin
		if (ioctl_addr < 27'd128) begin
			if (!ioctl_addr[0])
				ee_lo <= ioctl_dout;
			else begin
				ee_init_wen  <= 1;
				ee_init_addr <= ioctl_addr[6:1];
				ee_init_data <= {ioctl_dout, ee_lo};
			end
		end else if (ioctl_addr < 27'd8320) begin
			zram_nv_wr <= 1;
			zram_nv_wa <= 13'(ioctl_addr - 27'd128);
			zram_nv_wd <= ioctl_dout;
		end
	end
end
wire        zram_up = ioctl_upload && ioctl_addr >= 27'd128
                      && ioctl_addr < 27'd8320;
wire        zram_nv_sel  = zram_nv_wr || zram_up;
wire [12:0] zram_nv_addr = zram_nv_wr ? zram_nv_wa
                                      : 13'(ioctl_addr - 27'd128);
wire  [7:0] zram_nv_rdata;

wire [15:0] ee_dump_data;
// The release OSD has no "Save NVRAM" entry: opening the OSD requests the
// save instead (the moment a Save NVRAM press would have happened anyway).
// Bytes 0-127 = EEPROM, 128-8319 = Z80 work RAM.
reg  osd_q;
always @(posedge clk_sys) osd_q <= OSD_STATUS;
wire dump_req = OSD_STATUS & ~osd_q;
assign ioctl_din = (ioctl_addr >= 27'd128) ? zram_nv_rdata
                 : ioctl_addr[0] ? ee_dump_data[15:8]
                                 : ee_dump_data[7:0];

//////////////////////   BOARD DESCRIPTOR   //////////////////////

// One byte delivered by the .mra as `<rom index="1">` that describes how the
// game's cabinet is wired. Index 0 is the ROM image and index 2 the NVRAM, so
// index 1 is free. rst_core is held for the whole download, so the byte is
// latched before the machine runs, and selecting another .mra reloads the
// core, so a stale value cannot carry over.
//
//   bit 0  coin wiring: 0 = World/Japan (JAMMA edge), 1 = US 4-player cabinet
//   bit 1  vertical mirror: 1 = Holosseum's cabinet, which shows the monitor
//          through a mirror (MAME ORIENTATION_FLIP_Y). The board's output is
//          not flipped; s32_video presents the lines in reverse order.
//   bit 2  protection V25 opcode table: 0 = Golden Axe's, 1 = Arabian
//          Fight's. The table is masked into the V25 part on the protection
//          module, so it is board build, not wiring, but it is just as fixed
//          per game (MAME sega_system32_ga2 vs sega_system32_arf).
//   bit 3  two-player six-button harness (Burning Rival): buttons 4-6 of
//          players 1 and 2 arrive on the 4-player I/O board's EXTRA2 port
//          and EXTRA1/EXTRA3 are unused (MAME INPUT_PORTS_START(brival)).
//   bit 4  FD1149 protection module 317-0212 (Burning Rival): s32_v60bus's
//          flag-word rule (MAME init_brival). Board build, like bit 2.
//   bit 5  FD1149 protection module 317-0204 (Dark Edge): s32_v60bus's
//          vblank writes and $A00000 window (MAME init_darkedge)
//   bit 6  837-8685 trackball I/O board (SegaSonic): three uPD4701A at
//          $C00040/48/50, and the game's one-button, three-player harness
//          (MAME sega_system32_track, INPUT_PORTS_START(sonic))
//   bit 7  FD1149 protection module 317-0213 (SegaSonic rev C): s32_v60bus's
//          level load on a write to $20E5C4 (MAME init_sonic)
// The byte is now full: a further board needs a second descriptor byte.
//
// These describe how the game's board and cabinet are built, not operator
// settings, so they live in the .mra rather than the OSD.
reg [7:0] board_cfg = 8'h00;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_download && ioctl_index == 1 && ioctl_addr == 0)
		board_cfg <= ioctl_dout;

//////////////////////   INPUTS   ////////////////////////////////

// MAME segas32.cpp system32_generic + the 4-player extras, all active low:
// P1/P2/EXTRA1/EXTRA2: bit0 B1  bit1 B2  bit2 B3  bit4 DOWN
//                      bit5 UP  bit6 RIGHT  bit7 LEFT
// SERVICE12: bit0 SERVICE  bit1 TEST  bit2 COIN1
//            bit3 COIN2  bit4 START1  bit5 START2   (ga2u: bit2/3 = COIN4/COIN3)
// SERVICE34[2:0] -> board bits [6:4]: {unknown, test push, service push}
// EXTRA3: bit0 START3, bit1 START4   (ga2u: bit2/3 = COIN2/COIN1)
// MiSTer joystick: [0]R [1]L [2]D [3]U, J1 buttons from [4]:
// [4]Attack [5]Jump [6]Magic [7]Start [8]Coin [9]Service [10]Test
// [11]Button 4 [12]Button 5 [13]Button 6 (Burning Rival's kicks; appended
// after Test so every earlier .mra keeps its bit positions)
function [7:0] pad (input [31:0] j);
	pad = ~{j[1], j[0], j[3], j[2], 1'b0, j[6], j[5], j[4]};
endfunction

// Trackball harness (board_cfg[6], SegaSonic): each player has one button,
// P1's on P1_A bit 0, P2's on P2_A bit 0 and P3's on P1_A bit 2; every
// other bit of both ports is unused and reads high (MAME
// INPUT_PORTS_START(sonic)). Coin 3 / Start 3 are SERVICE12 bits 6/7.
wire trk_board = board_cfg[6];
wire [7:0] in_p1 = trk_board ? ~{5'd0, joystick_2[4], 1'b0, joystick_0[4]}
                             : pad(joystick_0);
wire [7:0] in_p2 = trk_board ? ~{7'd0, joystick_1[4]} : pad(joystick_1);
// Six-button harness (board_cfg[3], Burning Rival): EXTRA2 carries buttons
// 4-6 of players 1 and 2 in MAME INPUT_PORTS_START(brival)'s bit order,
// bits 3 and 6 unknown (read high); EXTRA1 and EXTRA3 are unused.
wire six_btn = board_cfg[3];
wire [7:0] in_extra2_6b = ~{joystick_0[13], 1'b0, joystick_0[11],
	joystick_0[12], 1'b0, joystick_1[13], joystick_1[12], joystick_1[11]};
wire [7:0] in_extra1 = six_btn ? 8'hFF : pad(joystick_2);
wire [7:0] in_extra2 = six_btn ? in_extra2_6b : pad(joystick_3);
// Coin wiring, selected by board_cfg[0] (above). The World/Japan programs
// read COIN1/COIN2 on the JAMMA edge through the 315-5296 (SERVICE12 bits
// 2/3). The US programs are built for the dedicated 4-player cabinet, whose
// coin switches 1/2 arrive on the 4-player I/O board (EXTRA3 bits 3/2), and
// the JAMMA-edge bits become COIN4/COIN3 (MAME segas32.cpp
// INPUT_PORTS_START(ga2u)). With the wrong wiring, coins register for the
// wrong player and START1 does nothing.
wire us_cab = board_cfg[0];
wire [7:0] in_extra3 = six_btn ? 8'hFF : {4'b1111,
	~(us_cab & joystick_0[8]),                    // bit3 COIN1 (US cabinet)
	~(us_cab & joystick_1[8]),                    // bit2 COIN2 (US cabinet)
	~joystick_3[7], ~joystick_2[7]};              // bit1 START4, bit0 START3
// The cabinet's TEST button (SERVICE12 bit1) is momentary, and the games act
// on its press: a press at any time opens the service menu, and inside it
// TEST selects the item SERVICE points at. A switch held down from power-on
// never opens the menu in Golden Axe or Spider-Man, and leaves TEST unable to
// select in Holosseum (checked in MAME 0.288), so the line is never latched.
//
// The OSD "Service" switch (O[10]) therefore does not hold the line. Turning
// it On gives one ~130 ms press (2^23 clk_sys cycles, several frames), which
// opens the service menu; the pad's TEST button then still selects in it.
// The game ignores a press in its first frames (MAME: frame 2 ignored,
// frame 30 accepted), so the switch is only armed ~2 s (2^27 clk_sys) after
// rst_core releases: a switch already On at load opens the menu once the
// game is running.
reg [26:0] run_cnt = 0;
always @(posedge clk_sys)
	if (rst_core)        run_cnt <= 0;
	else if (~&run_cnt)  run_cnt <= run_cnt + 1'd1;
wire svc_arm = status[10] & &run_cnt;
reg        svc_arm_q = 0;
reg [22:0] osd_test_cnt = 0;
always @(posedge clk_sys) begin
	svc_arm_q <= svc_arm;
	if (svc_arm & ~svc_arm_q)   osd_test_cnt <= '1;
	else if (|osd_test_cnt)     osd_test_cnt <= osd_test_cnt - 1'd1;
end
wire test_btn = |osd_test_cnt | joystick_0[10] | joystick_1[10];

wire [7:0] in_service12 = ~{
	trk_board & joystick_2[7],                    // START3 (trackball board)
	trk_board & joystick_2[8],                    // COIN3  (trackball board)
	joystick_1[7], joystick_0[7],                 // START2, START1
	us_cab ? joystick_2[8] : joystick_1[8],       // COIN2 (World) / COIN3 (US)
	us_cab ? joystick_3[8] : joystick_0[8],       // COIN1 (World) / COIN4 (US)
	test_btn,                                     // TEST
	joystick_0[9] | joystick_1[9]};               // SERVICE (service credit)
// The PCB's own push switches SW1/SW2 (MAME "Push SW1 (Service)" / "Push SW2
// (Test)") follow the same two buttons.
wire [2:0] in_service34 = {1'b1,
	~(joystick_0[10] | joystick_1[10]),           // push SW2 (test)
	~(joystick_0[9]  | joystick_1[9])};           // push SW1 (service)

// Trackball counts (board_cfg[6]). A real ball turns two optical encoders,
// and the uPD4701A counts their edges continuously; here every source adds
// steps as they arrive, never once a frame (docs/sonic-bringup.md §3):
//   - P1: the PS/2 mouse, one count per mouse count (MAME's sensitivity
//     100), and the left analog stick of pad 1;
//   - P2 / P3: the left analog sticks of pads 2 / 3.
// A stick is a rate: every 2^15 clk_sys (~1.97 kHz) its signed deflection
// is added to an accumulator and whole 1/128ths are emitted, so a full
// deflection rolls ~1,950 counts a second (MAME's keyboard speed is 30 a
// frame, 1,800 a second); |deflection| < 8 is a dead zone.
// Directions follow MAME's ports: the X counter runs DOWN as the ball rolls
// right (PORT_REVERSE on TRACKX), the Y counter up as it rolls toward the
// player (screen down). PS/2 Y is positive up, MiSTer stick Y positive down.
// The input scale is a usability setting, not hardware.
reg [14:0] trk_tick_cnt = 0;
always @(posedge clk_sys) trk_tick_cnt <= trk_tick_cnt + 1'd1;
wire trk_tick = &trk_tick_cnt;

function automatic [7:0] stick_dz (input [7:0] v);
	stick_dz = ($signed(v) > 8'sd7 || $signed(v) < -8'sd7) ? v : 8'd0;
endfunction

reg  [12:0] trk_acc [0:5];                     // {P1x,P1y,P2x,P2y,P3x,P3y}
reg  [11:0] trk_step [0:5];
reg   [2:0] trk_stb;
reg         mouse_tg = 0;
wire        mouse_ev = ps2_mouse[24] ^ mouse_tg;
wire  [8:0] mouse_dx = {ps2_mouse[4], ps2_mouse[15:8]};
wire  [8:0] mouse_dy = {ps2_mouse[5], ps2_mouse[23:16]};
wire [15:0] trk_stick [0:2];
assign trk_stick[0] = stick_0;
assign trk_stick[1] = stick_1;
assign trk_stick[2] = stick_2;
always @(posedge clk_sys) begin
	mouse_tg <= ps2_mouse[24];
	trk_stb <= 3'd0;
	for (int n = 0; n < 6; n++) begin
		logic [12:0] sum;
		logic [7:0]  dfl;
		logic [11:0] st;
		// X from bits 7:0 (reversed), Y from bits 15:8
		dfl = stick_dz(n[0] ? trk_stick[n/2][15:8] : trk_stick[n/2][7:0]);
		sum = trk_acc[n] + (n[0] ? {{5{dfl[7]}}, dfl} : -{{5{dfl[7]}}, dfl});
		st  = trk_tick ? {{6{sum[12]}}, sum[12:7]} : 12'd0;
		if (trk_tick) trk_acc[n] <= sum - {st[5:0], 7'd0};
		// the mouse adds to P1 only
		if (n < 2 && mouse_ev)
			st = st + (n == 0 ? -{{3{mouse_dx[8]}}, mouse_dx}
			                  : -{{3{mouse_dy[8]}}, mouse_dy});
		trk_step[n] <= st;
	end
	trk_stb <= {3{trk_tick}} | {2'b00, mouse_ev};
	if (rst_core) for (int n = 0; n < 6; n++) trk_acc[n] <= 13'd0;
end

//////////////////////   THE MACHINE   ///////////////////////////

wire        de, hblank, vblank, hs, vs, ce_pix;
wire        vid_wide;                         // 416-pixel frame (Burning Rival)
wire [14:0] rgb;
wire signed [15:0] audio_l, audio_r;

s32_board board
(
	.clk(clk_sys),
	.rst_core(rst_core),
	.rst_ctrl(rst_ctrl_r),

	.ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data),
	.ld_rdy(ld_rdy),

	.de(de), .rgb(rgb), .hblank(hblank), .vblank(vblank),
	.hs(hs), .vs(vs), .ce_pix(ce_pix), .vid_wide(vid_wide),
	.audio_l(audio_l), .audio_r(audio_r),

	.in_p1(in_p1), .in_p2(in_p2), .in_portc(8'hFF),
	.in_service12(in_service12), .in_sw1_dips(4'hF),
	.in_service34(in_service34),
	.in_extra1(in_extra1), .in_extra2(in_extra2),
	.in_extra3(in_extra3),
	.cab_vmirror(board_cfg[1]),
	.prot_arf(board_cfg[2]),
	.prot_brival(board_cfg[4]),
	.prot_darkedge(board_cfg[5]),
	.trk_board(trk_board),
	.trk_stb(trk_stb & {3{trk_board}}),
	.trk_dx({trk_step[4], trk_step[2], trk_step[0]}),
	.trk_dy({trk_step[5], trk_step[3], trk_step[1]}),
	.prot_sonic(board_cfg[7]),

	.ee_init_wen(ee_init_wen), .ee_init_addr(ee_init_addr),
	.ee_init_data(ee_init_data),
	.ee_dump_addr(ioctl_addr[6:1]), .ee_dump_data(ee_dump_data),
	.zram_nv_sel(zram_nv_sel), .zram_nv_we(zram_nv_wr),
	.zram_nv_addr(zram_nv_addr), .zram_nv_wdata(zram_nv_wd),
	.zram_nv_rdata(zram_nv_rdata),

	.sd_cke(SDRAM_CKE), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
	.sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE), .sd_ba(SDRAM_BA),
	.sd_a(SDRAM_A), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
	// The sprite frame buffers' DDR3 port. `go` waits for the loader to
	// release DDR3 and for the core to leave reset.
	.fbddr_go(!ddr_busy_l && !rst_core),
	.fbddr_quiet(fbddr_quiet),
	.ddr_busy(DDRAM_BUSY || ddr_busy_l),
	.ddr_rd(fb_ddr_rd), .ddr_we(fb_ddr_we),
	.ddr_addr(fb_ddr_addr), .ddr_burstcnt(fb_ddr_burstcnt),
	.ddr_din(fb_ddr_din), .ddr_be(fb_ddr_be),
	.ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY && !ddr_busy_l),
	.sd_dq(SDRAM_DQ),

	.unused_ok()
);

assign SDRAM_CLK = clk_sdram;

//////////////////////   VIDEO / AUDIO   /////////////////////////

assign CLK_VIDEO = clk_sys;

// The board's composed picture (HUD overlay included in debug builds), 8 bits
// per channel. It goes to VGA_* through the CRT Adjust stage at the end of
// this section.
wire [7:0] av_r, av_g, av_b;

// rgb is {b,g,r} 5:5:5 (the 315-5388 DAC shifts left 3)
assign av_r = {rgb[4:0],   rgb[4:2]};
assign av_g = {rgb[9:5],   rgb[9:7]};
assign av_b = {rgb[14:10], rgb[14:12]};

// CRT Adjust (H-Size / H-Position / V-Shift), rtl/video/s32_crt_adjust.sv.
// Analog geometry only: nothing the game can observe changes. With the stage
// On the output pixel rate is its read enable, not ce_pix, so CE_PIXEL and
// the scaler's DE follow it; with it Off (`crt_act` = 0) every pin below is
// the native stream exactly as before the stage existed. The engine's own
// bypass is never used for that, because it would add two pixels of latency.
// The stage is built for the 320-mode raster (400 dots, the 6.25 MHz rate
// table); a 416-pixel frame (vid_wide, Burning Rival) is passed through
// native, with the setting kept for the next 320-mode frame.
wire       crt_act, crt_hs, crt_vs, crt_de, crt_ce;
wire [7:0] crt_r, crt_g, crt_b;

s32_crt_adjust crt_adjust
(
	.clk(clk_sys), .ce_pix(ce_pix),
	.osd_on(crt_enable & ~vid_wide),
	.osd_hsize(status[40:36]), .osd_hpos(status[47:41]), .osd_vshift(status[53:48]),
	.r_in(av_r), .g_in(av_g), .b_in(av_b),
	.hs_in(hs), .vs_in(vs), .de_in(de), .vblank_in(vblank),
	.active(crt_act),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .de_out(crt_de),
	.ce_out(crt_ce)
);

assign CE_PIXEL = crt_act ? crt_ce : ce_pix;
assign VGA_R    = crt_act ? crt_r  : av_r;
assign VGA_G    = crt_act ? crt_g  : av_g;
assign VGA_B    = crt_act ? crt_b  : av_b;
assign VGA_HS   = crt_act ? crt_hs : hs;
assign VGA_VS   = crt_act ? crt_vs : vs;

// Scale (O[34:33]) onto video_freak's SCALE code (sys/video_freak.sv: 0
// normal, 1 V-integer, 2 HV-Integer-, 3 HV-Integer+, 4 HV-Integer). Menu
// order and code differ on purpose: "HV-Integer" is 4, "Narrower" is 2 — the
// same four choices, in the same order, as the family's other cores.
// CROP is not exposed. With no crop video_freak's vertical window is every
// line, so VGA_DE equals the DE handed in, in every Scale mode; the integer
// modes act on VIDEO_ARX/ARY (the HDMI scaler's target size) only.
wire [2:0] scale_sel = (status[34:33] == 2'd0) ? 3'd0 :   // Normal
                       (status[34:33] == 2'd1) ? 3'd1 :   // V-Integer
                       (status[34:33] == 2'd2) ? 3'd4 :   // HV-Integer
                                                 3'd2;    // Narrower HV-Integer

video_freak video_freak
(
	.CLK_VIDEO  (CLK_VIDEO),
	.CE_PIXEL   (CE_PIXEL),
	.VGA_VS     (VGA_VS),
	.HDMI_WIDTH (HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE     (VGA_DE),
	.VIDEO_ARX  (VIDEO_ARX),
	.VIDEO_ARY  (VIDEO_ARY),
	.VGA_DE_IN  (crt_act ? crt_de : de),
	.ARX        (arx),
	.ARY        (ary),
	.CROP_SIZE  (12'd0),
	.CROP_OFF   (5'd0),
	.SCALE      (scale_sel)
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

endmodule
