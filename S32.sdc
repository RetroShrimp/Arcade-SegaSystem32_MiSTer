derive_pll_clocks
derive_clock_uncertainty

# Core-specific constraints.
#
# Multicycle exceptions are claims about both the launch and the capture
# edge, so each one below is scoped to registers whose timing is known.
# Where two exceptions overlap, this Quartus 17.0 STA applies the LAST
# matching one in the file, so the order of the sections matters.

# ---- Mixer pixel pipeline: 2 clk_sys periods ------------------------------
# The mixer advances only on cen_mix, at most once every other clk_sys, so
# its priority-sort logic has two periods.
#
#   -from: only registers that launch on cen_mix edges: the pixel taps
#   (q_text, q_n0..q_n3, q_bm, spr_q), the palette taps (prda_r, prdb_r),
#   bf_line (loaded once per line in hblank, stable for the whole line) and
#   the mixer's own registers. Named exactly rather than as q_*: s32_video
#   has other q_-prefixed registers that must stay single-cycle.
#
#   -to: only the cen_mix-paced stages (s0_*, s1_*, rgb*). The mixer's
#   register-write path and the cen_mix enable network are single-cycle and
#   must not be covered: a '-to' exception without '-from' would also waive
#   each register's clock-enable path.
#
# There is no '-from mixer -to outside' exception: the mixer's outputs
# feed registers in s32_video that capture on the very next clk_sys edge.
set_multicycle_path -setup 2 \
  -from [get_registers {*|s32_video:u_vid|spr_q* *|s32_video:u_vid|prda_r* *|s32_video:u_vid|prdb_r* *|s32_video:u_vid|bf_line* *|s32_video:u_vid|q_text* *|s32_video:u_vid|q_n0* *|s32_video:u_vid|q_n1* *|s32_video:u_vid|q_n2* *|s32_video:u_vid|q_n3* *|s32_video:u_vid|q_bm* *|s32_mixer:u_mix|*}] \
  -to   [get_registers {*|s32_mixer:u_mix|s0_* *|s32_mixer:u_mix|s1_* *|s32_mixer:u_mix|rgb*}]
set_multicycle_path -hold 1 \
  -from [get_registers {*|s32_video:u_vid|spr_q* *|s32_video:u_vid|prda_r* *|s32_video:u_vid|prdb_r* *|s32_video:u_vid|bf_line* *|s32_video:u_vid|q_text* *|s32_video:u_vid|q_n0* *|s32_video:u_vid|q_n1* *|s32_video:u_vid|q_n2* *|s32_video:u_vid|q_n3* *|s32_video:u_vid|q_bm* *|s32_mixer:u_mix|*}] \
  -to   [get_registers {*|s32_mixer:u_mix|s0_* *|s32_mixer:u_mix|s1_* *|s32_mixer:u_mix|rgb*}]

# ---- V60 CPU: 2 clk_sys periods --------------------------------------------
# The V60 core steps on cen16 (clk_sys / 4 = the real 16.108 MHz CPU clock)
# and is frozen between steps, so every v60:u_v60 register holds for at
# least 4 clk_sys. The bus unit (v60_bcu) registers everything the rest of
# the machine sees.
#
# Setup 2 under-claims the real 4-clock spacing, which is the safe
# direction. Do not relax it further: the prefetch unit's paths are bounded
# by the cen16 spacing at which its state is consumed, not by the full
# 4-clock freeze, and a looser claim lets unsettled fetch data be latched.
set_multicycle_path -setup 2 -from [get_registers {*|v60:u_v60|*}]
set_multicycle_path -hold 1 -from [get_registers {*|v60:u_v60|*}]
set_multicycle_path -setup 2 -to [get_registers {*|v60:u_v60|*}]
set_multicycle_path -hold 1 -to [get_registers {*|v60:u_v60|*}]

# No exception covers the bus fabric. The core never reaches s32_v60bus
# directly (the bus unit sits between them), and the decode from the bus
# unit's registered address is a genuine single-cycle path.

# ---- Video register shadow: 2 periods --------------------------------------
# CPU-written video configuration, changed by the games during vblank. A
# write in the middle of a line can tear one sample, as on the real board.
set_multicycle_path -setup 2 -from [get_registers {*|s32_video:u_vid|vregs*}]
set_multicycle_path -hold 1 -from [get_registers {*|s32_video:u_vid|vregs*}]

# ---- Mixer layer sort: 4 periods -------------------------------------------
# The layer-priority sort is recomputed from slowly changing configuration
# into free-running registers; its 42-stage compare network gets 4 periods.
# This block must stay AFTER the video register rule above: the last
# matching exception wins, and the earlier rule would otherwise clamp the
# vregs -> sorted paths to 2 periods. The sorted registers have no reset or
# enable, so these are their only sources.
set_multicycle_path -setup 4 \
  -from [get_registers {*|s32_video:u_vid|vregs* *|s32_mixer:u_mix|*}] \
  -to   [get_registers {*|s32_mixer:u_mix|sorted?*}]
set_multicycle_path -hold 3 \
  -from [get_registers {*|s32_video:u_vid|vregs* *|s32_mixer:u_mix|*}] \
  -to   [get_registers {*|s32_mixer:u_mix|sorted?*}]

# ---- SDRAM I/O timing (MT48LC16M16 class, CAS latency 2, 64.43 MHz) ------
# SDRAM_CLK is PLL outclk_1 (-3879 ps phase) wired straight to the pin.
# Commands and write data are sampled by the chip on its next edge; read data
# is captured in the SDRAM_DQ I/O-cell register (s32_sdram dq_in_q) on the
# second clk_sys edge after the chip drives it. Delays are datasheet values
# (read tAC 6.0 / tOH 2.5 ns, write tIS 1.5 / tIH 0.8 ns). If the PLL counter
# name below ever stops matching, Quartus only warns and these I/O paths go
# unconstrained. [] in a get_pins filter is a Tcl character class, so literal
# brackets are written as ? wildcards (general?1?).
create_generated_clock -name SDRAM_CLK \
  -source [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general?1?.gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# Read capture: chip data access tAC = 6.0 ns (max), output hold tOH = 2.5 ns
set_input_delay  -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]

# Command/address/data launch: chip input setup tIS = 1.5, hold tIH = 0.8
set_output_delay -clock SDRAM_CLK -max  1.5 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]

# Read capture: SDRAM_CLK edges sit 3.879 ns before clk_sys edges, so by
# default STA would pick a capture edge only 3.879 ns after launch. The I/O
# register really captures on the next clk_sys edge. The output direction's
# default (to the chip's next edge) is already correct.
set_multicycle_path -setup -end 2 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold -end 1 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
