# Sega System 32 for MiSTer

An FPGA recreation of Sega's **System 32** arcade board for the
[MiSTer](https://mister-devel.github.io/MkDocs_MiSTer/) platform, built
around **Golden Axe: The Revenge of Death Adder** (1992). It also runs
**Spider-Man: The Videogame** and **Holosseum**, which use the same board.

This is not a software emulator. The core rebuilds the board chip by chip:
the NEC V60 main CPU, Sega's custom video and system chips, the Z80 sound
system and Golden Axe's protection module, each running at its original
clock. The NEC V60 was written from scratch for this core; as far as we know
it is the first FPGA implementation of that CPU.

## Supported games

| MRA | MAME set | Status |
| --- | --- | --- |
| `Golden Axe - The Revenge of Death Adder.mra` | `ga2` | tested on hardware |
| `Golden Axe - The Revenge of Death Adder (US).mra` | `ga2u` | not yet tested on hardware |
| `Golden Axe - The Revenge of Death Adder (Japan).mra` | `ga2j` | tested on hardware |
| `Spider-Man - The Videogame.mra` | `spidman` | tested on hardware |
| `Spider-Man - The Videogame (US).mra` | `spidmanu` | not yet tested on hardware |
| `Spider-Man - The Videogame (Japan).mra` | `spidmanj` | not yet tested on hardware |
| `Holosseum.mra` | `holo` | runs in simulation; not yet tested on hardware |

The regional sets differ from their parent only in the program ROMs. The US
sets are wired for Sega's dedicated four-player cabinet, which has its own
coin switches. Each MRA tells the core how its cabinet is wired (the US coin
wiring, Holosseum's mirrored monitor), so there is nothing to set by hand.

## Requirements

| Item | Requirement |
| --- | --- |
| Board | DE10-Nano |
| SDRAM | **Required**: a 32 MB module or larger. The tile and sprite graphics are read from it while the game runs. |
| ROMs | MAME 0.288 zips, supplied by you; none are included here |

## Installing

1. Copy `releases/S32_YYYYMMDD.rbf` to `_Arcade/cores/` on the SD card.
2. Copy the `.mra` files in `releases/` to `_Arcade/`, and the folders in
   `releases/_alternatives/` to `_Arcade/_alternatives/`.
3. Put the ROM zips in `games/mame/`: `ga2.zip` (plus `ga2u.zip` or
   `ga2j.zip` for the regional sets), `spidman.zip` (plus `spidmanu.zip` or
   `spidmanj.zip`) and `holo.zip`. Split and merged sets both work.

Loading a game takes about two seconds.

**Keep only one `S32_*.rbf` in `_Arcade/cores/`.** The MRAs ask for the core
by the prefix `S32`, so an older dated release left in that folder can load
instead of the new one. Quote the file name you are running in any bug
report.

## Controls

Golden Axe and Spider-Man take up to four players, Holosseum two. Each player
uses the D-pad or stick plus these buttons. The MRAs map them to a pad by
default, and MiSTer's input mapping can change that:

| Button | Default pad button | Golden Axe | Spider-Man | Holosseum |
| --- | --- | --- | --- | --- |
| 1 | A | Attack | Attack | Punch |
| 2 | B | Jump | Jump | Kick |
| 3 | X | Magic | | |
| Start | Start | Start | Start | Start |
| Coin | R | Coin | Coin | Coin |
| Service | L | adds a service credit; moves the cursor in the service menu | same | same |
| Test | Select | opens the service menu; selects the highlighted item in it | same | same |

Service and Test are the cabinet's two service buttons. Like the real
buttons, they act when pressed, so they work at any time.

## OSD options

| Option | Default | What it does |
| --- | --- | --- |
| Aspect ratio | Original | the usual MiSTer setting |
| Scale | Normal | HDMI scaling: Normal, V-Integer, HV-Integer, Narrower HV-Integer |
| CRT Adjust | Off | a page of analog picture-geometry controls for a 15 kHz CRT (below) |
| Service | Off | switching it On opens the game's service menu |
| Reset | | resets the board |

**CRT Adjust** fits the analog picture to a CRT without touching the game:
the board's timing and sync rates stay native. Switch it On to show three
controls: **H-Size** (wider/narrower in 1.56% steps), **H-Position** and
**V-Shift**. Off is an exact bypass. The horizontal blanking of this raster
is short (80 of 400 dots), so the picture can move about 19 pixels right and
60 left at normal size; when H-Size enlarges the picture, move it left to
keep the right edge on screen. Positive V-Shift moves the picture up.
The engine is rmonic79's [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust).

The OSD **Service** option opens the service menu; it is not the **Service**
button above, which moves the cursor once you are in it.

## Settings and high scores

Game settings (coinage, difficulty and so on) live in the board's EEPROM,
and the bookkeeping and high scores in its battery-backed sound RAM. The
core keeps both in one `.nvm` file in the `nvram` folder. **The file is
written each time you open the OSD**, and restored when the game is next
loaded. To go back to factory settings, delete the `.nvm` file.

To change settings, set the OSD **Service** option to On (or press Test):
the game's own service menu opens. Service moves the cursor and Test
selects; choose EXIT to return to the game. Switch the OSD option back to
Off before you use it again.

## The hardware

| Block | On the board | In the core |
| --- | --- | --- |
| Main CPU | NEC V60 at 16.10795 MHz | written from scratch, microcoded |
| Tilemaps | Sega 315-5387 (four scrolling layers, a text layer and a bitmap layer) | `rtl/video/` |
| Sprites | Sega 315-5386, drawing into a double frame buffer | `rtl/video/s32_sprite*.sv`; the frame buffers live in the DE10's DDR3 |
| Mixer and palette | Sega 315-5388 | `rtl/video/s32_mixer.sv` |
| Bus and interrupts | Sega 315-5385 | `rtl/sys32/` |
| Inputs | Sega 315-5296 I/O chip, plus an i8255 for players 3 and 4 | `rtl/sys32/` |
| Settings | 93C46 serial EEPROM | `rtl/sys32/eeprom_93c46.sv` |
| Sound | Z80, two YM3438 FM chips and an RF5C68-family PCM chip | `rtl/sound/` (FM by jt12, Z80 by tv80) |
| Protection (Golden Axe only) | NEC V25 running an encrypted program, talking to the V60 through an MB8421 dual-port RAM | `rtl/sys32/s32_v25.sv` |

In the games' 320-pixel mode the picture is 400 × 262 dots at a 6.25 MHz
pixel clock, 59.64 Hz.

## Accuracy

Reference authority, in order: the original Sega schematics, Charles
MacDonald's System 32 hardware notes, then MAME 0.288 as a behavioural
baseline. Where MAME and the hardware notes disagree, the core follows the
notes.

Every block was checked in simulation against MAME before it went into the
core: single-instruction CPU tests, whole-machine runs compared with MAME
instruction by instruction, the sound chips' register writes compared with
MAME's, and video frames compared pixel by pixel.

Things you may notice, or may want to know:

- **Stage-2 cave torches (Golden Axe).** The torches light the cave in a
  circle that grows, shrinks and flickers. MAME 0.288 does not draw this
  effect. The core uses the model that MAME added after 0.288
  (mamedev/mame#16038), so current MAME and the core agree.
- **CPU timing.** No NEC document gives per-instruction cycle counts, so the
  V60's timing comes from its bus and prefetch logic rather than a cycle
  table. MAME charges a flat 8 clocks per instruction, so instruction timing
  can differ slightly from MAME.
- **Wait states.** The bus controller's wait-state settings are not
  documented, and the Z80's wait line is not used. Like MAME, the core adds
  no wait states on these paths.
- **Sprite drawing speed.** The real sprite chip runs at 25 MHz, but its
  exact drawing rate is not documented. The core's sprite engine runs faster
  rather than risk dropping sprites, so a scene that would run out of time on
  a real board still completes here.
- **Video sync.** Line and frame lengths come from the board; the sync pulse
  position, width and polarity have not been measured on a real board.
- **Sound output.** The core outputs the digital mix. The board's DAC and
  analog filter after it are not modelled.
- **Holosseum** is viewed through a mirror in its cabinet, so the core shows
  the lines in reverse order. Still frames are exact; a change in the middle
  of a frame tears at a different screen line than on a real cabinet.
- **Not implemented**: the 416-pixel video mode (none of the supported games
  uses it), and the parts of the V25 that Golden Axe's protection program does
  not use (it only runs at boot).

No real System 32 board was available to this project, so none of the
behaviour above has been measured against one. Measurements from real boards
are welcome.

The core was developed simulation-first, with AI assistance, under human
review and testing on real MiSTer hardware.

## Building

Open `S32.qpf` in Quartus Prime Lite 17.0.2 and compile, or run
`quartus_sh --flow compile S32`. The bitstream is `output_files/S32.rbf`.

- Add source files by editing `files.qip`, not through the Quartus GUI.
- If a compile writes the full pin list back into `S32.qsf`, restore the
  file from git.
- The design fills most of the FPGA. The tightest timing path is in the
  MiSTer framework's HDMI scaler; if a change leaves it slightly negative,
  try another `SEED` value in `S32.qsf`. Quartus reports a successful
  compile and writes an RBF even when timing is not met, so check the
  timing report after every build.

## Repository layout

```text
S32.qpf / .qsf / .sdc / .srf   Quartus project
S32.sv                         glue between the MiSTer framework and the core
files.qip                      source file list
rtl/
  v60/                         NEC V60 CPU
  sys32/                       board logic: bus, interrupts, I/O, EEPROM,
                               V25 protection, SDRAM and DDR3 memory system
  video/                       tilemaps, sprites, mixer and video timing
  sound/                       sound CPU section, PCM chip and mixing
    jt12/  tv80/               vendored YM3438 and Z80 cores
  pll.v  pll.qip  pll/         PLL megafunction
sys/                           MiSTer framework, unmodified
releases/                      dated RBF and MRA files
  _alternatives/<game>/        regional sets
```

`sys/` is an unmodified copy of
[Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) at commit
`3ea1134` (2026-08-26). Each RTL file's header says what it models and which
references it follows: the schematics, Charles MacDonald's notes (`s32tech`)
or a MAME source file (`segas32.cpp`, `segas32_v.cpp`, and so on).

## Credits

- Charles MacDonald: the System 32 hardware notes, without which this core
  could not have been built.
- The MAME team: the `segas32` driver and the V60, V25 and sound-chip cores,
  used as the behavioural baseline and as the reference for every simulation
  comparison.
- Jose Tejada (jotego): jt12, the YM3438 FM core.
- Guy Hutchison and Daniel Wallner: tv80, the Z80 core.
- Alexey Melnikov (Sorgelig) and the MiSTer-devel contributors: the MiSTer
  framework.

Core by **RetroShrimp**.

## Licence

GPL-3.0-or-later. See `LICENSE`, and `NOTICE.md` for the third-party
components and their licences. *Golden Axe*, *Holosseum* and *System 32* are
trademarks of SEGA; *Spider-Man* is a trademark of Marvel. This is an
unaffiliated hardware-preservation project. It contains no ROM data, artwork,
manuals or schematic scans. Use it only with ROMs you are legally entitled to.
