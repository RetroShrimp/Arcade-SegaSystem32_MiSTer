// s32_pllrc.sv — minimal run-time reconfiguration of pll_vid (one C counter
// and the fractional K), replacing sys/pll_cfg's general altera_pll_reconfig
// core for this one job.
//
// Not a board function: it serves the CLK_VIDEO output stage (GitHub
// MiSTer-devel/Arcade-SegaSystem32_MiSTer issue #1; s32_vidout.sv header).
//
// Why (2026-11-06): the stock core (sys/pll_cfg/altera_pll_reconfig_core.v)
// holds a register set for all 18 C counters, M, N, bandwidth, charge pump,
// VCO divider, manual DPRIO and dynamic phase shift; its counter index comes
// through dont-touch LUTs, so synthesis cannot prune it even when every write
// is a constant. It cost 555 ALMs on a 93 %-full device, and twelve fitter
// seeds then missed the HDMI clock (ascal) by 0.011-0.892 ns
// (core/archive/publish_sweep_vidout*.out).
//
// What it does: on `go` (taken only while `busy` is low) it performs, on the
// PLL's DPRIO port, EXACTLY the transaction sequence the stock core performs
// for the register writes {mode 0, C counter {c_hi, c_lo, c_bypass, c_odd,
// sel 0}, DSM K, start}: the C divider write, the read-modify-write of the
// counter's bypass and odd-division bits, the K-ready read, K-ready = 0, K
// low/high words, K-ready = 1, then the wait for lock. The state machine
// below is a transcription of altera_pll_reconfig_core's ONE..TEN states for
// those two operations, cycle for cycle; sim/s32_pllrc compares the two
// cores' reconfig_to_pll buses bit for bit, every cycle, for both FPLL
// placements and several physical counter indices.
//
// What it keeps from the stock core, unchanged and with the same instance
// names (all from the framework's library pll_cfg, which is why files.qip
// compiles this file into that library): the power-up self_reset and
// fpll_dprio_init sequences, dprio_mux, the 3-flop lock synchronizer, and the
// dont-touch LUTs the Fitter rewrites for the PLL's placement: lcell_fpll_0_1
// (FPLL_0 or FPLL_1 address map), lcell_dprio_read, and dyn_phase_shift's
// five lcell_cnt_sel LUTs (logical -> physical counter index; their input is
// the preserved usr_cnt_sel register, always 0 = logical C0, as the stock
// core's is after a C-counter write with select 0).
//
// Avalon handshake replaced by go/busy: busy is high from go until the
// sequence has finished and the PLL reports lock, and whenever the PLL is not
// locked or the DPRIO init has not finished (the stock core's waitrequest
// conditions).

module s32_pllrc (
    input  wire        mgmt_clk,
    input  wire        go,           // one-clock request (ignored while busy)
    input  wire  [7:0] c_hi,         // C counter high / low count
    input  wire  [7:0] c_lo,
    input  wire        c_bypass,
    input  wire        c_odd,        // odd-division duty correction
    input  wire [31:0] k,            // DSM fractional K
    output wire        busy,
    output wire        ack,          // go taken this clock

    output wire [63:0] reconfig_to_pll,
    input  wire [63:0] reconfig_from_pll
);
    // altera_pll_reconfig_core DPRIO addresses (Cyclone V)
    localparam [5:0] C_CNT_0_DIV_ADDR          = 6'h00;
    localparam [5:0] C_CNT_0_DIV_ADDR_DPRIO_1  = 6'h11;
    localparam [5:0] C_CNT_0_3_BYPASS_EN_ADDR  = 6'h15;
    localparam [5:0] C_CNT_0_3_ODD_DIV_EN_ADDR = 6'h17;
    localparam [5:0] C_CNT_4_17_BYPASS_EN_ADDR = 6'h14;
    localparam [5:0] C_CNT_4_17_ODD_DIV_EN_ADDR= 6'h16;
    localparam [5:0] DSM_K_FRAC_ADDR_0         = 6'h18;
    localparam [5:0] DSM_K_FRAC_ADDR_1         = 6'h19;
    localparam [5:0] DSM_K_READY_ADDR          = 6'h17;
    localparam       DSM_K_READY_BIT           = 11;

    localparam [3:0] DPRIO_IDLE = 4'd0, ONE = 4'd1, TWO = 4'd2, THREE = 4'd3,
                     FOUR = 4'd4, FIVE = 4'd5, SIX = 4'd6, SEVEN = 4'd7,
                     EIGHT = 4'd8, NINE = 4'd9, TEN = 4'd10, DPRIO_DONE = 4'd15;
    localparam       IDLE = 1'b0, WAIT_ON_LOCK = 1'b1;

    wire clk = mgmt_clk;
    wire reset, dprio_init_reset;
    wire locked_orig = reconfig_from_pll[16];
    wire phase_done  = reconfig_from_pll[17];
    wire [15:0] dprio_readdata = reconfig_from_pll[15:0];
    wire locked;

    altera_std_synchronizer #(.depth(3)) altera_std_synchronizer_inst (
        .clk(clk), .reset_n(1'b1), .din(locked_orig), .dout(locked));

    self_reset self_reset_inst (1'b0, clk, reset, dprio_init_reset);

    // ---------------------------------------------------------- main FSM
    reg        current_state;
    reg  [3:0] dprio_cur_state;
    reg  [3:0] dprio_next_state;
    reg        dprio_start;
    reg        dprio_write_done;

    reg  [7:0] usr_c_lo, usr_c_hi;
    reg        usr_c_bypass, usr_c_odd;
    reg [31:0] usr_k;
    reg        c_changed, c_done_q;      // stock: any_c_cnt_changed, all_c_cnt_done_q
    reg        k_changed, k_done_q;      // stock: dsm_k_changed, dsm_k_done_q
    reg [15:0] temp1_q, temp2_q;         // stock: dprio_temp_m_n_c_readdata_{1,2}_q
    reg  [4:0] usr_cnt_sel /*synthesis preserve*/;

    // combinational outputs of the DPRIO sequencer
    reg        avmm_dprio_write, avmm_dprio_read;
    reg  [5:0] avmm_dprio_address;
    reg [15:0] avmm_dprio_writedata;
    reg  [1:0] avmm_dprio_byteen;
    reg        temp_read_1, temp_read_2;
    reg        c_done_d, k_done_d, k_ready_false_done_d;

    wire       dps_done, phase_en, up_dn, dps_changed_valid;
    wire [4:0] cnt_sel;                  // physical counter index (Fitter LUTs)
    wire       fpll_1;                   // FPLL_1 address map (Fitter LUT)
    wire       dprio_init_done;

    reg [15:0] avmm_temp_d1, avmm_temp_d2;
    wire busy_wr  = (locked === 1'b1)
                  ? (((current_state == WAIT_ON_LOCK) & !dprio_write_done) | !dps_done | reset | !dprio_init_done)
                  : 1'b1;                // the stock core's waitrequest
    wire start_ok = !busy_wr && (current_state == IDLE);
    assign ack = go && start_ok;
    assign busy = busy_wr || (current_state != IDLE);

    always @(posedge clk) begin
        if (reset) begin
            current_state   <= IDLE;
            dprio_cur_state <= DPRIO_IDLE;
            dprio_start     <= 1'b0;
            c_changed <= 1'b0; c_done_q <= 1'b0;
            k_changed <= 1'b0; k_done_q <= 1'b0;
            temp1_q <= 16'd0; temp2_q <= 16'd0;
            usr_c_lo <= 8'd0; usr_c_hi <= 8'd0; usr_c_bypass <= 1'b0; usr_c_odd <= 1'b0;
            usr_k <= 32'd0;
            usr_cnt_sel <= 5'd0;
        end else begin
            dprio_cur_state <= dprio_next_state;
            case (current_state)
                IDLE:         if (go && start_ok) current_state <= WAIT_ON_LOCK;
                WAIT_ON_LOCK: if (locked & dps_done & dprio_write_done) current_state <= IDLE;
            endcase

            if (temp_read_1) temp1_q <= avmm_temp_d1;
            if (temp_read_2) temp2_q <= avmm_temp_d2;
            if (k_done_d) k_done_q <= 1'b1;
            if (c_done_d) c_done_q <= 1'b1;
            if (dprio_next_state == ONE) dprio_start <= 1'b0;
            if (dprio_write_done) begin
                c_changed <= 1'b0; c_done_q <= 1'b0;
                k_changed <= 1'b0; k_done_q <= 1'b0;
            end
            if (go && start_ok) begin
                usr_c_lo <= c_lo; usr_c_hi <= c_hi;
                usr_c_bypass <= c_bypass; usr_c_odd <= c_odd;
                usr_k <= k;
                c_changed <= 1'b1; c_done_q <= 1'b0;
                k_changed <= 1'b1; k_done_q <= 1'b0;
                dprio_start <= 1'b1;
            end
        end
    end

    // counter-dependent DPRIO addresses and bit positions (stock core's
    // i < 4 / i > 13 split and FPLL_1 mirror), for physical counter cnt_sel
    wire [5:0] c_div_addr = fpll_1 ? (C_CNT_0_DIV_ADDR + C_CNT_0_DIV_ADDR_DPRIO_1 - {1'b0, cnt_sel})
                                   : (C_CNT_0_DIV_ADDR + {1'b0, cnt_sel});
    wire       c_grp03    = fpll_1 ? (cnt_sel > 5'd13) : (cnt_sel < 5'd4);
    wire [5:0] c_byp_addr = c_grp03 ? C_CNT_0_3_BYPASS_EN_ADDR  : C_CNT_4_17_BYPASS_EN_ADDR;
    wire [5:0] c_odd_addr = c_grp03 ? C_CNT_0_3_ODD_DIV_EN_ADDR : C_CNT_4_17_ODD_DIV_EN_ADDR;
    wire [4:0] c_bit      = fpll_1 ? (c_grp03 ? cnt_sel - 5'd14 : cnt_sel)
                                   : (c_grp03 ? 5'd3 - cnt_sel  : 5'd17 - cnt_sel);

    wire c_pend = c_changed & !c_done_q;
    wire k_pend = k_changed & !k_done_q;

    // Transcription of altera_pll_reconfig_core's sequencer (lines 802-1361)
    // restricted to the C-counter and DSM-K operations.
    always @(*) begin
        temp_read_1 = 1'b0; temp_read_2 = 1'b0;
        avmm_temp_d1 = 16'd0; avmm_temp_d2 = 16'd0;
        dprio_next_state = DPRIO_IDLE;
        avmm_dprio_write = 1'b0; avmm_dprio_read = 1'b0;
        avmm_dprio_address = 6'd0; avmm_dprio_writedata = 16'd0; avmm_dprio_byteen = 2'b00;
        dprio_write_done = 1'b1;
        c_done_d = 1'b0; k_done_d = 1'b0; k_ready_false_done_d = 1'b0;

        if (dprio_start) dprio_write_done = 1'b0;

        if (current_state == WAIT_ON_LOCK) begin
            case (dprio_cur_state)
                ONE: begin
                    if (c_pend) begin
                        dprio_write_done = 1'b0;
                        avmm_dprio_write = 1'b1; avmm_dprio_byteen = 2'b11;
                        dprio_next_state = TWO;
                        avmm_dprio_address = c_div_addr;
                        avmm_dprio_writedata = {usr_c_hi, usr_c_lo};
                    end else if (k_pend) begin
                        dprio_write_done = 1'b0;
                        dprio_next_state = TWO;
                    end else dprio_next_state = DPRIO_IDLE;
                end
                TWO: begin
                    dprio_write_done = 1'b0;
                    dprio_next_state = THREE;
                    avmm_dprio_byteen = 2'b11; avmm_dprio_read = 1'b1;
                    if (c_pend) avmm_dprio_address = c_byp_addr;
                    else if (k_pend) begin
                        avmm_dprio_address = DSM_K_READY_ADDR;
                        dprio_next_state = FOUR;
                    end else dprio_next_state = DPRIO_IDLE;
                end
                THREE: begin
                    dprio_write_done = 1'b0;
                    avmm_dprio_byteen = 2'b11; avmm_dprio_read = 1'b1;
                    dprio_next_state = FOUR;
                    if (c_pend) avmm_dprio_address = c_odd_addr;
                    else dprio_next_state = DPRIO_IDLE;
                end
                FOUR: begin
                    temp_read_1 = 1'b1;
                    dprio_write_done = 1'b0;
                    if (k_changed | c_changed) begin
                        avmm_temp_d1 = dprio_readdata;
                        dprio_next_state = FIVE;
                    end else dprio_next_state = DPRIO_IDLE;
                end
                FIVE: begin
                    dprio_write_done = 1'b0;
                    temp_read_2 = 1'b1;
                    if (k_changed | c_changed) begin
                        avmm_temp_d2 = dprio_readdata;
                        dprio_next_state = SIX;
                    end else dprio_next_state = DPRIO_IDLE;
                end
                SIX: begin
                    dprio_write_done = 1'b0;
                    avmm_dprio_write = 1'b1; avmm_dprio_byteen = 2'b11;
                    dprio_next_state = SEVEN;
                    avmm_dprio_writedata = temp1_q;
                    if (c_pend) begin
                        avmm_dprio_address = c_byp_addr;
                        avmm_dprio_writedata[c_bit] = usr_c_bypass;
                    end else if (k_pend) avmm_dprio_write = 1'b0;
                    else dprio_next_state = DPRIO_IDLE;
                end
                SEVEN: begin
                    dprio_write_done = 1'b0;
                    dprio_next_state = EIGHT;
                    avmm_dprio_write = 1'b1; avmm_dprio_byteen = 2'b11;
                    avmm_dprio_writedata = temp2_q;
                    if (c_pend) begin
                        avmm_dprio_address = c_odd_addr;
                        avmm_dprio_writedata[c_bit] = usr_c_odd;
                        c_done_d = 1'b1;
                    end else if (k_pend) begin
                        avmm_dprio_address = DSM_K_READY_ADDR;
                        avmm_dprio_writedata[DSM_K_READY_BIT] = 1'b0;
                        k_ready_false_done_d = 1'b1;
                    end
                    // stock next-state priority (one counter: done after this write)
                    if (k_changed & !k_ready_false_done_d) dprio_next_state = TWO;
                    else if (k_changed & !k_done_q)         dprio_next_state = EIGHT;
                    else begin
                        dprio_next_state = DPRIO_DONE;
                        dprio_write_done = 1'b1;
                    end
                end
                EIGHT: begin
                    dprio_write_done = 1'b0;
                    dprio_next_state = NINE;
                    avmm_dprio_write = 1'b1; avmm_dprio_byteen = 2'b11;
                    if (k_pend) begin
                        avmm_dprio_address = DSM_K_FRAC_ADDR_0;
                        avmm_dprio_writedata = usr_k[15:0];
                    end
                end
                NINE: begin
                    dprio_write_done = 1'b0;
                    dprio_next_state = TEN;
                    avmm_dprio_write = 1'b1; avmm_dprio_byteen = 2'b11;
                    if (k_pend) begin
                        avmm_dprio_address = DSM_K_FRAC_ADDR_1;
                        avmm_dprio_writedata = usr_k[31:16];
                    end
                end
                TEN: begin
                    dprio_write_done = 1'b0;
                    dprio_next_state = ONE;
                    avmm_dprio_write = 1'b1; avmm_dprio_byteen = 2'b11;
                    if (k_pend) begin
                        avmm_dprio_address = DSM_K_READY_ADDR;
                        avmm_dprio_writedata = temp2_q;
                        avmm_dprio_writedata[DSM_K_READY_BIT] = 1'b1;
                        k_done_d = 1'b1;
                    end
                end
                DPRIO_DONE: begin
                    dprio_write_done = 1'b1;
                    dprio_next_state = dprio_start ? DPRIO_IDLE : DPRIO_DONE;
                end
                DPRIO_IDLE: dprio_next_state = dprio_start ? ONE : DPRIO_IDLE;
                default:    dprio_next_state = DPRIO_IDLE;
            endcase
        end
    end

    // ------------------------------------------- stock pieces, unchanged
    dyn_phase_shift dyn_phase_shift_inst (
        .clk(clk), .reset(reset), .phase_done(phase_done),
        .pll_start_valid(1'b0), .dps_changed(1'b0),
        .dps_changed_valid(dps_changed_valid),
        .dprio_write_done(dprio_write_done),
        .usr_num_shifts(16'd0), .usr_cnt_sel(usr_cnt_sel), .usr_up_dn(1'b0),
        .locked(locked), .dps_done(dps_done), .phase_en(phase_en),
        .up_dn(up_dn), .cnt_sel(cnt_sel));
    defparam dyn_phase_shift_inst.device_family = "Cyclone V";

    wire [5:0]  init_dprio_address;
    wire        init_dprio_read, init_dprio_write;
    wire [1:0]  init_dprio_byteen;
    wire [15:0] init_dprio_writedata;
    wire        init_atpgmode, init_mdio_dis, init_scanen, init_ser_shift_load;
    wire [5:0]  dprio_address;
    wire        dprio_read, dprio_write;
    wire [1:0]  dprio_byteen;
    wire [15:0] dprio_writedata;
    wire        dprio_atpgmode, dprio_mdio_dis, dprio_scanen, dprio_ser_shift_load;

    dprio_mux dprio_mux_inst (
        .init_dprio_address(init_dprio_address), .init_dprio_read(init_dprio_read),
        .init_dprio_byteen(init_dprio_byteen), .init_dprio_write(init_dprio_write),
        .init_dprio_writedata(init_dprio_writedata),
        .init_atpgmode(init_atpgmode), .init_mdio_dis(init_mdio_dis),
        .init_scanen(init_scanen), .init_ser_shift_load(init_ser_shift_load),
        .dprio_init_done(dprio_init_done),
        .avmm_dprio_address(avmm_dprio_address), .avmm_dprio_read(avmm_dprio_read),
        .avmm_dprio_byteen(avmm_dprio_byteen), .avmm_dprio_write(avmm_dprio_write),
        .avmm_dprio_writedata(avmm_dprio_writedata),
        .avmm_atpgmode(1'b0), .avmm_mdio_dis(1'b0), .avmm_scanen(1'b0),
        .avmm_ser_shift_load(1'b0),
        .dprio_address(dprio_address), .dprio_read(dprio_read),
        .dprio_byteen(dprio_byteen), .dprio_write(dprio_write),
        .dprio_writedata(dprio_writedata),
        .atpgmode(dprio_atpgmode), .mdio_dis(dprio_mdio_dis),
        .scanen(dprio_scanen), .ser_shift_load(dprio_ser_shift_load));

    fpll_dprio_init fpll_dprio_init_inst (
        .clk(clk), .reset_n(~reset), .locked(locked),
        .dprio_address(init_dprio_address), .dprio_read(init_dprio_read),
        .dprio_byteen(init_dprio_byteen), .dprio_write(init_dprio_write),
        .dprio_writedata(init_dprio_writedata),
        .atpgmode(init_atpgmode), .mdio_dis(init_mdio_dis),
        .scanen(init_scanen), .ser_shift_load(init_ser_shift_load),
        .dprio_init_done(dprio_init_done));

    generic_lcell_comb lcell_fpll_0_1 (.dataa(1'b0), .combout(fpll_1));
    defparam lcell_fpll_0_1.lut_mask   = 64'hAAAAAAAAAAAAAAAA;
    defparam lcell_fpll_0_1.dont_touch = "on";
    defparam lcell_fpll_0_1.family     = "Cyclone V";

    wire dprio_read_combout;
    generic_lcell_comb lcell_dprio_read (
        .dataa(fpll_1), .datab(dprio_read), .datac(1'b0), .datad(1'b0),
        .datae(1'b0), .dataf(1'b0), .combout(dprio_read_combout));
    defparam lcell_dprio_read.lut_mask   = 64'hCCCCCCCCCCCCCCCC;
    defparam lcell_dprio_read.dont_touch = "on";
    defparam lcell_dprio_read.family     = "Cyclone V";

    assign reconfig_to_pll[0]     = clk;
    assign reconfig_to_pll[1]     = ~dprio_init_reset;
    assign reconfig_to_pll[2]     = dprio_write;
    assign reconfig_to_pll[3]     = dprio_read_combout;
    assign reconfig_to_pll[9:4]   = dprio_address;
    assign reconfig_to_pll[25:10] = dprio_writedata;
    assign reconfig_to_pll[27:26] = dprio_byteen;
    assign reconfig_to_pll[28]    = dprio_ser_shift_load;
    assign reconfig_to_pll[29]    = dprio_mdio_dis;
    assign reconfig_to_pll[30]    = phase_en;
    assign reconfig_to_pll[31]    = up_dn;
    assign reconfig_to_pll[36:32] = cnt_sel;
    assign reconfig_to_pll[37]    = dprio_scanen;
    assign reconfig_to_pll[38]    = dprio_atpgmode;
    assign reconfig_to_pll[63:39] = 25'd0;

endmodule

// s32_vidpll_ctl — picks pll_vid's setting from the screen mode (CLK_50M).
//   320: C 10 (hi 5, lo 5), K 0          -> VCO 500.000 MHz / 10 = 50.000000
//   416: C 8  (hi 4, lo 4), K 1327535135 -> VCO 515.454545 / 8 = 64.431818
// M (10) and N (bypass) are common to both, so only C0 and K are written.
// `vid_wide` comes from clk_sys and changes at most once a frame, in vblank;
// it is taken after two equal samples. `go` is held until s32_pllrc takes it
// (ack), so a request that meets a momentary lock loss is not lost. After the
// sequence, vid_cfg_ok stays low until the PLL has been locked, with the
// sequencer idle, for 2^SETTLE_BITS clocks (1.3 ms): the lock flag can still
// read high for a moment after the K write, before the PLL drops it.
// vid_cfg_ok gates s32_vidout's reader. Power-up is the 416 setting (the
// clk_sys PLL's own counters, pll_vid_0002.v).
module s32_vidpll_ctl #(
    parameter int SETTLE_BITS = 16
) (
    input  wire        clk,          // CLK_50M (the PLL's reference)
    input  wire        vid_wide,     // async: 416-pixel frame
    input  wire        pll_locked,   // async: pll_vid locked
    output reg         vid_cfg_ok,
    output wire [63:0] reconfig_to_pll,
    input  wire [63:0] reconfig_from_pll
);
    reg vw_s1 = 1'b1, vw_s2 = 1'b1, vw_s3 = 1'b1;
    reg lk_s1 = 1'b0, lk_s2 = 1'b0;
    reg vcfg_wide = 1'b1;            // the setting the PLL holds
    reg [1:0] cstate = 2'd0;
    reg go = 1'b0;
    reg [SETTLE_BITS-1:0] settle = '0;
    wire rc_busy, rc_ack;
    initial vid_cfg_ok = 1'b0;

    s32_pllrc u_rc (
        .mgmt_clk(clk), .go(go),
        .c_hi(vcfg_wide ? 8'd4 : 8'd5), .c_lo(vcfg_wide ? 8'd4 : 8'd5),
        .c_bypass(1'b0), .c_odd(1'b0),
        .k(vcfg_wide ? 32'd1327535135 : 32'd0),
        .busy(rc_busy), .ack(rc_ack),
        .reconfig_to_pll(reconfig_to_pll), .reconfig_from_pll(reconfig_from_pll));

    always @(posedge clk) begin
        vw_s1 <= vid_wide; vw_s2 <= vw_s1; vw_s3 <= vw_s2;
        lk_s1 <= pll_locked; lk_s2 <= lk_s1;
        case (cstate)
            2'd0: if (vw_s3 == vw_s2 && vw_s3 != vcfg_wide) begin
                      vcfg_wide <= vw_s3;
                      go        <= 1'b1;
                      cstate    <= 2'd1;
                  end
            2'd1: if (rc_ack) begin
                      go     <= 1'b0;
                      settle <= '0;
                      cstate <= 2'd2;
                  end
            default: begin
                      if (rc_busy || !lk_s2) settle <= '0;
                      else if (&settle)      cstate <= 2'd0;
                      else                   settle <= settle + 1'b1;
                  end
        endcase
        vid_cfg_ok <= (cstate == 2'd0) && lk_s2 && !rc_busy && (vw_s3 == vcfg_wide);
    end
endmodule
