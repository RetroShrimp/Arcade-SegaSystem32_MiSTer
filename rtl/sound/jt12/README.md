# jt12 — YM2612/YM3438 FM synthesis core

Source: https://github.com/jotego/jt12
Commit: eaab7e1de6594982a299bc9101dc882384b85685 (2026-01-30)
License: GPL-3.0-or-later (see LICENSE; headers in each file)
Author: Jose Tejada (@topapate)

Subset used by the System 32 core: jt12.v top (YM2612 defaults — the
jt12_acc accumulator implements the YM3438-style continuous sum, which
is the chip fitted on System 32) plus its dependency tree, and
jt10_adpcm_div.v (divider reused by jt12_pcm_interpol). The ADPCM
blocks proper are not elaborated (use_adpcm=0).

Verified in sim/s32_sound: the full 132,390-write MAME write-stream
lockstep passes with both jt12 instances live (status/busy/timer
behavior compatible with the game's polling loops).
