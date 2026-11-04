// s32_soundtop.sv — complete System 32 sound stack: s32_sound (Z80 +
// banking + int ctl) + two jt12 YM3438 + s32_pcm RF5C68, mixed to a
// signed 16-bit stereo pair.
//
// Output = the board's stereo line out (CN, schematic sheet 8/9),
// modelled by s32_lineout: the FM 7.2 kHz pole, the PCM 33 Hz high-pass
// and 3rd-order ~14 kHz reconstruction low-pass, the shared 36 kHz
// line-out pole, and PCM's opposite polarity to FM. Passband levels are
// MAME segas32.cpp's (ym1/ym2 0.30, rf5c68 0.40; 77/256 and 102/256),
// because the schematic gives topology and component values but not the
// DACs' volts per code (OPEN-QUESTIONS Q23).
//
// `define S32_AUDIO_RAW restores the unfiltered mix,
// (fm1*77 + fm2*77 + pcm*102) >>> 8 saturated, bit-exact with the core
// before 2026-11-04 — for A/Bs against MAME, which models no analog
// stage (the gnome-era captures were taken that way).
//
// YM3438 vs YM2612 DAC: jt12 models no YM2612 DAC "ladder" effect (its
// accumulator is clean, full resolution), so the FM output already matches
// the YM3438's DAC that the board carries.
//
// Clocking: one clock domain. cen_fm paces both jt12 (8.054 MHz =
// 32.2159 / 4; jt12's own /6 prescaler gives the 55.9 kHz sample rate),
// cen_pcm the RF5C68's tick divider (12.5 MHz, from the board's separate
// 50 MHz crystal), and cen_z80 the Z80 (see s32_sound).

module s32_soundtop (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_z80,      // Z80 enable (stalled on ROM misses)
    input  logic        cen_fm,       // 8.054 MHz enable
    input  logic        cen_pcm,      // 12.5 MHz enable

    // sound ROM region (4MB)
    output logic [21:0] rom_addr,
    input  logic [7:0]  rom_data,
    output logic        rom_rd,

    // V60-side shared RAM port + command/interrupt handshake
    input  logic        shm_sel,
    input  logic        shm_we,
    input  logic [12:0] shm_addr,
    input  logic [7:0]  shm_wdata,
    output logic [7:0]  shm_rdata,
    // Z80 work RAM save/restore port (see s32_sound)
    input  logic        nv_sel,
    input  logic        nv_we,
    input  logic [12:0] nv_addr,
    input  logic [7:0]  nv_wdata,
    output logic [7:0]  nv_rdata,
    input  logic        v60_cmd,
    output logic        v60_irq_pulse,

    // mixed audio
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r
);

    // ------------------------------------------------------ subsystem
    logic        pcm_sel, pcm_we;
    logic [12:0] pcm_addr;
    logic [7:0]  pcm_wdata, pcm_rdata;
    logic        ym1_cs, ym2_cs, ym_we;
    logic [1:0]  ym_a;
    logic [7:0]  ym_wdata, ym1_rdata, ym2_rdata;
    logic        ym_irq;

    s32_sound u_sound (
        .clk(clk), .rst(rst), .cen(cen_z80),
        .rom_addr(rom_addr), .rom_data(rom_data), .rom_rd(rom_rd),
        .pcm_sel(pcm_sel), .pcm_we(pcm_we), .pcm_addr(pcm_addr),
        .pcm_wdata(pcm_wdata), .pcm_rdata(pcm_rdata),
        .ym1_cs(ym1_cs), .ym2_cs(ym2_cs), .ym_we(ym_we), .ym_a(ym_a),
        .ym_wdata(ym_wdata), .ym1_rdata(ym1_rdata),
        .ym2_rdata(ym2_rdata), .ym_irq(ym_irq),
        .shm_sel(shm_sel), .shm_we(shm_we), .shm_addr(shm_addr),
        .shm_wdata(shm_wdata), .shm_rdata(shm_rdata),
        .nv_sel(nv_sel), .nv_we(nv_we), .nv_addr(nv_addr),
        .nv_wdata(nv_wdata), .nv_rdata(nv_rdata),
        .v60_cmd(v60_cmd), .v60_irq_pulse(v60_irq_pulse)
    );

    // ------------------------------------------------------- FM pair
    logic signed [15:0] fm1_l, fm1_r, fm2_l, fm2_r;
    logic ym1_irq_n, ym2_irq_n;

    jt12 u_ym1 (
        .rst(rst), .clk(clk), .cen(cen_fm),
        .din(ym_wdata), .addr(ym_a),
        .cs_n(!ym1_cs), .wr_n(!ym_we),
        .dout(ym1_rdata), .irq_n(ym1_irq_n),
        .en_hifi_pcm(1'b0),
        .snd_left(fm1_l), .snd_right(fm1_r), .snd_sample()
    );

    jt12 u_ym2 (
        .rst(rst), .clk(clk), .cen(cen_fm),
        .din(ym_wdata), .addr(ym_a),
        .cs_n(!ym2_cs), .wr_n(!ym_we),
        .dout(ym2_rdata), .irq_n(ym2_irq_n),
        .en_hifi_pcm(1'b0),
        .snd_left(fm2_l), .snd_right(fm2_r), .snd_sample()
    );

    assign ym_irq = !ym1_irq_n;   // only chip 1's /IRQ is connected

    // ---------------------------------------------------------- PCM
    logic signed [15:0] pcm_l, pcm_r;

    s32_pcm u_pcm (
        .clk(clk), .rst(rst), .cen_pcm(cen_pcm),
        .sel(pcm_sel), .we(pcm_we), .addr(pcm_addr),
        .wdata(pcm_wdata), .rdata(pcm_rdata),
        .out_l(pcm_l), .out_r(pcm_r)
    );

    // ------------------------------------------------ board line out
    // The filter runs at clk/256: cen_fm is exactly clk/8 in s32_sys
    // (cen_z80), so one tick per 32 cen_fm. s32_lineout's coefficients
    // assume that rate (tools/s32_audio_filter.py).
    logic [4:0] lo_div;
    logic       lo_tick;
    always_ff @(posedge clk)
        if (rst) begin
            lo_div  <= '0;
            lo_tick <= 1'b0;
        end else begin
            lo_tick <= cen_fm && lo_div == 5'd31;
            if (cen_fm) lo_div <= lo_div + 5'd1;
        end

    s32_lineout u_lineout (
        .clk(clk), .rst(rst), .tick(lo_tick),
        .fm_l(17'(fm1_l) + 17'(fm2_l)), .fm_r(17'(fm1_r) + 17'(fm2_r)),
        .pcm_l(pcm_l), .pcm_r(pcm_r),
        .out_l(audio_l), .out_r(audio_r)
    );

endmodule
