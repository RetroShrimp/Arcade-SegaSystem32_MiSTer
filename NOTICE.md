# NOTICE — third-party components and attributions

This core is distributed under **GPL-3.0-or-later** (see `LICENSE`). It
includes the third-party components below. Each one keeps its original file
headers.

## Components compiled into the core

| Component | Author(s) | Licence | Location |
|---|---|---|---|
| MiSTer framework (`sys_top`, `hps_io`, `ascal`, `osd`, `video_freak`, …) | Till Harbaum, Alexey Melnikov (Sorgelig) and the MiSTer-devel contributors | GPL-2.0-or-later / GPL-3.0-or-later (per-file headers) | `sys/`: vendored unchanged from Template_MiSTer commit `3ea1134` (2026-08-26). 57 files; SHA-256 of all file contents concatenated in path order (`find sys -type f \| LC_ALL=C sort \| xargs cat \| sha256sum`): `8f3623f8af25cf7325c815fa7161d2434da47ebaac2138eca514ad04809c1970` |
| **jt12**, the YM2612/YM3438 FM synthesiser | Jose Tejada (jotego) | GPL-3.0-or-later | `rtl/sound/jt12/`: the subset this core uses, from github.com/jotego/jt12 commit `eaab7e1de6594982a299bc9101dc882384b85685`, unchanged, with its `LICENSE` and a provenance `README.md` |
| **tv80**, the Z80 core | Guy Hutchison, based on Daniel Wallner's T80 | MIT-style (permission notice in each file header) | `rtl/sound/tv80/`. `tv80s.v` is modified: a clock-enable input replaces the constant enable, and the strobe registers advance on that enable; the changes are marked `S32` in the file |
| **CRT Adjust**, analog picture-geometry stage | Umberto Parisi (rmonic79) | GPL-3.0-or-later | `rtl/video/crt_adjust.sv`: from github.com/rmonic79/MiSTer-CRT-Adjust commit `c682de9`, with four marked adaptations listed in its header (line-buffer size parameter, no RAM initialiser, a sign-extension fix, a vertical-blank alignment parameter). `rtl/video/s32_crt_adjust.sv`, the glue around it, is original to this project |
| Intel PLL megafunction (50 MHz → 64.4318 MHz system clock and SDRAM clock) | Intel Corporation (generated IP) | Intel FPGA IP licence, as generated | `rtl/pll.v`, `rtl/pll.qip`, `rtl/pll/` |

All of these licences are compatible with distributing the combined work
under GPL-3.0-or-later. Everything else in `rtl/`, `S32.sv`, `S32.sdc`,
`S32.qsf` and `files.qip` is original to this project.

## Data taken from MAME

MAME (BSD-3-Clause; Aaron Giles and the MAME contributors) served as the
functional reference and produced every simulation comparison. No MAME
source is compiled into this core. Two pieces of data in the RTL come from
MAME's `segas32` driver: the protection module's opcode-decryption table and
its ROM address-line scramble (`rtl/sys32/s32_v25.sv`, from
`segas32_m.cpp`), both of which describe the original module.

## Trademarks and content

This repository contains no ROM data, no artwork, no manuals and no schematic
scans. *Golden Axe*, *Holosseum*, *Super Visual Football*, *Super Visual
Soccer*, *Arabian Fight*, *Burning Rival*, *Dark Edge*, *SegaSonic The Hedgehog*,
*Sonic the Hedgehog*, *Rad Mobile* and *System 32* are
trademarks of
SEGA;
*Spider-Man* is a trademark of Marvel. This is an unaffiliated
hardware-preservation project. Use it only with ROMs you are legally entitled
to.
