// s32_mixer.sv — 315-5388 mixer: layer priority, palette lookup, colour
// offsets, blending and shadow.
//
// References: s32tech (315-5388 registers) and MAME segas32_v.cpp
// mix_all_layers.
//
// Interface: a register write port ($610000-$61007F word offsets), then a
// pixel stream: s32_video presents every layer's pixel for one screen
// position at once, with px_valid; four cen ticks later the pipeline
// answers with rgb_valid and 15-bit RGB (5 bits per channel; the DAC
// output is v << 3).
//
// Per pixel: layers are scanned in effective-priority order
// (effpri = {priority[3:0], 3'(6 - laynum)}, priority 0 = excluded) for
// the first and second non-transparent candidates; palette lookups run
// on two external read ports (palette RAM lives outside — BRAM at the
// top level); color offsets (sets A/B, sext-6) are added, the blend
// (7-f)/(f+1) applies when the top layer's blendmask selects the
// second's laynum, channels clamp to 0..31.
//
// The background (line color) layer is synthesized internally from
// $31FF5E (input r5e): line mode (bit 15) pix = (r5e & 0x1E00) +
// ((r5e + line) & 0x1FF), else (r5e & 0x1E00); always opaque, lowest
// real priority (effpri 8). `line` is the backdrop line index: the caller
// passes 223 - line under the global flip (MAME update_background).

module s32_mixer (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,          // render-time enable (freeze on 0)

    // mixer register file write port (word offset within $610000-$7F)
    input  logic        reg_we,
    input  logic [5:0]  reg_addr,
    input  logic [15:0] reg_wdata,
    input  logic [1:0]  reg_bsel,    // byte strobes: a byte write only
                                     // changes its own byte (these
                                     // registers read back $FFFF, so a
                                     // read-merge-write cannot be used)

    // tilemap-side inputs
    input  logic [15:0] r5e,          // $31FF5E backdrop control
    input  logic [5:0]  lay_en,       // {bitmap,nbg3..nbg0,text} enables

    // pixel stream (all layer pixels pre-masked to 13 bits — MAME masks
    // every non-sprite layer with &0x1fff before the palette lookup)
    input  logic        px_valid,
    input  logic [7:0]  line,
    // Force the 315-5242 shade on this pixel, as a sprite shadow would.
    // s32_video ties it 0. Kept because the 315-5242 has a real /SHADE pin
    // (schematic) whose driver is not known.
    input  logic        shade_win,
    input  logic [12:0] pix_text,
    input  logic [12:0] pix_nbg0,
    input  logic [12:0] pix_nbg1,
    input  logic [12:0] pix_nbg2,
    input  logic [12:0] pix_nbg3,
    input  logic [12:0] pix_bitmap,
    // sprite framebuffer word for this pixel (raw; 0x7FFF pattern =
    // transparent, erase fill 0xFFFF; feed 16'hFFFF when absent)
    input  logic [15:0] pix_sprite,

    // palette read ports (1-cycle latency, xBGR555 words)
    output logic        pal_re_a,
    output logic [13:0] pal_addr_a,
    input  logic [15:0] pal_rdata_a,
    output logic        pal_re_b,
    output logic [13:0] pal_addr_b,
    input  logic [15:0] pal_rdata_b,

    // output stream (2 cycles behind px_valid)
    output logic        rgb_valid,
    output logic [14:0] rgb           // {b[4:0], g[4:0], r[4:0]}
);

    // ------------------------------------------------------ register file
    // power-up state: zero, as in MAME (the games write every register
    // during boot; the real chip's power-up state is not known)
    logic [15:0] mreg [0:63] = '{64{16'h0000}};
    always_ff @(posedge clk)
        if (reg_we) begin
            if (reg_bsel[0]) mreg[reg_addr][7:0]  <= reg_wdata[7:0];
            if (reg_bsel[1]) mreg[reg_addr][15:8] <= reg_wdata[15:8];
        end

    // NOTE: indices are word offsets (byte offset / 2). A sized literal
    // such as 6'h4E is truncated to 6 bits before any shift, so write the
    // word offset directly.
    logic [15:0] r3e, r4e;
    assign r3e = mreg[6'h1F];         // $3E
    assign r4e = mreg[6'h27];         // $4E

    logic       blendenable;
    logic [2:0] blendfactor;
    assign blendenable = r4e[11];
    assign blendfactor = r4e[10:8];

    // color offset sets A/B (sext-6 each), set 2 = zero (grayscale stub)
    logic signed [5:0] roffs [0:2][0:2];
    always_comb begin
        roffs[0][0] = mreg[6'h20][5:0];   // $40
        roffs[0][1] = mreg[6'h21][5:0];   // $42
        roffs[0][2] = mreg[6'h22][5:0];   // $44
        roffs[1][0] = mreg[6'h23][5:0];   // $46
        roffs[1][1] = mreg[6'h24][5:0];   // $48
        roffs[1][2] = mreg[6'h25][5:0];   // $4A
        roffs[2][0] = 6'd0; roffs[2][1] = 6'd0; roffs[2][2] = 6'd0;
    end

    // -------------------------------------------- per-layer static config
    // laynum: 0 text, 1-4 NBG0-3, 7 background
    function automatic logic [1:0] coloroffs (input logic [3:0] laybit,
                                              input logic layerflag);
        logic [1:0] mode;
        mode = {r3e[15], laybit[0]};   // laybit[0] = $3E per-layer bit
        unique case (mode)
            2'd0, 2'd3: coloroffs = layerflag ? 2'd0 : 2'd1;
            2'd1:       coloroffs = 2'd2;
            default:    coloroffs = layerflag ? 2'd0 : 2'd2;
        endcase
    endfunction

    typedef struct packed {
        logic        active;
        logic [6:0]  effpri;
        logic [13:0] palbase;
        logic [1:0]  mixshift;
        logic [7:0]  blendmask;
        logic [15:0] sprblend;   // per-sprite-group blend gate
        logic [1:0]  coffs;
        logic [2:0]  lay;
    } layctl_t;

    // MAME segas32_v.cpp compute_sprite_blend (0.288): the $30-family
    // bits 5:0 encode WHICH sprite groups a layer blends with —
    // {mode[1:0], value[3:0]}: 0 = only group `value`, 1 = groups
    // 0..value, 2 = groups value..15, 3 = all. s32tech is silent, so this
    // follows MAME.
    function automatic logic [15:0] sprite_blend_mask
        (input logic [5:0] enc);
        logic [15:0] onehot, low;
        onehot = 16'd1 << enc[3:0];
        low    = onehot - 16'd1;
        unique case (enc[5:4])
            2'd0: sprite_blend_mask = onehot;
            2'd1: sprite_blend_mask = onehot | low;
            2'd2: sprite_blend_mask = ~low;
            default: sprite_blend_mask = 16'hFFFF;
        endcase
    endfunction

    layctl_t cfg [0:6];               // text, NBG0-3, bitmap, background
    always_comb begin
        for (int l = 0; l < 6; l++) begin
            logic [15:0] ctl, bctl;
            ctl  = mreg[(6'h20 >> 1) + 6'(l)];    // $20..$2A
            bctl = mreg[(6'h30 >> 1) + 6'(l)];    // $30..$3A
            cfg[l].lay      = 3'(l);
            cfg[l].active   = (ctl[3:0] != 4'd0) && lay_en[l];
            cfg[l].effpri   = {ctl[3:0], 3'(3'd6 - 3'(l))};
            cfg[l].palbase  = {ctl[7:4], 10'd0};
            cfg[l].mixshift = ctl[9:8];
            cfg[l].blendmask = blendenable ? bctl[13:6] : 8'd0;
            cfg[l].sprblend  = sprite_blend_mask(bctl[5:0]);
            cfg[l].coffs    = coloroffs({3'd0, r3e[l]}, bctl[14]);
        end
        // background from $2C; always active, effpri = 8
        cfg[6].lay      = 3'd7;
        cfg[6].active   = 1'b1;
        cfg[6].effpri   = 7'd8;
        cfg[6].palbase  = {mreg[6'h2C >> 1][7:4], 10'd0};
        cfg[6].mixshift = mreg[6'h2C >> 1][9:8];
        cfg[6].blendmask = 8'd0;
        cfg[6].sprblend  = 16'd0;
        cfg[6].coffs    = coloroffs({3'd0, r3e[8]}, r3e[14]);
    end

    // sorted order: 7 entries, bubble-sort network (combinational;
    // config changes only between frames in practice)
    // the bubble network output is REGISTERED (free-running): 42
    // serial compare-swaps are ~40 ns of comb, but the inputs are
    // pure mixer-register config (quasi-static — stable for frames),
    // so sorted gets its own relaxed SDC multicycle and the
    // per-pixel path starts from registers.
    layctl_t sorted_c [0:6];
    layctl_t sorted [0:6];
    always_ff @(posedge clk)
        for (int i = 0; i < 7; i++) sorted[i] <= sorted_c[i];
    always_comb begin
        layctl_t tmp [0:6];
        layctl_t t;
        t = cfg[0];                    // swap temporary: defined on every path
        for (int i = 0; i < 7; i++) tmp[i] = cfg[i];
        // descending by {active, effpri}: active layers first, higher
        // effective priority first, inactive entries sink to the end
        for (int i = 0; i < 7; i++)
            for (int j = 0; j < 6; j++)
                if ({tmp[j].active, tmp[j].effpri}
                    < {tmp[j+1].active, tmp[j+1].effpri}) begin
                    t = tmp[j]; tmp[j] = tmp[j+1]; tmp[j+1] = t;
                end
        sorted_c = tmp;
    end

    // ------------------------------------------------- sprite grouping
    // $4C[3:0] selects the group field position (MAME table); per-group
    // control regs $00-$1E give priority/palbase/mixshift. Sprite
    // effpri = {prio, 3'd7} — sprites win every tiebreak; a priority-0
    // group lands below the background (effpri 7 < 8) = invisible.
    logic [15:0] r4c;
    assign r4c = mreg[6'h26];         // $4C
    logic [3:0] sgshift_m4;           // shift - 10 (10..14 -> 0..4)
    logic [3:0] sgmask, sgor;
    always_comb begin
        unique case (r4c[3:0])
            4'h0: begin sgshift_m4 = 4'd4; sgmask = 4'h0; sgor = 4'h1; end
            4'h1: begin sgshift_m4 = 4'd4; sgmask = 4'h1; sgor = 4'h2; end
            4'h2: begin sgshift_m4 = 4'd3; sgmask = 4'h3; sgor = 4'h4; end
            4'h3: begin sgshift_m4 = 4'd2; sgmask = 4'h7; sgor = 4'h8; end
            4'h4: begin sgshift_m4 = 4'd4; sgmask = 4'h1; sgor = 4'h0; end
            4'h5: begin sgshift_m4 = 4'd3; sgmask = 4'h3; sgor = 4'h0; end
            4'h6: begin sgshift_m4 = 4'd2; sgmask = 4'h7; sgor = 4'h0; end
            4'h7: begin sgshift_m4 = 4'd1; sgmask = 4'hF; sgor = 4'h0; end
            4'h8: begin sgshift_m4 = 4'd4; sgmask = 4'h1; sgor = 4'h0; end
            4'h9: begin sgshift_m4 = 4'd3; sgmask = 4'h3; sgor = 4'h0; end
            4'hA: begin sgshift_m4 = 4'd2; sgmask = 4'h7; sgor = 4'h0; end
            4'hB: begin sgshift_m4 = 4'd1; sgmask = 4'hF; sgor = 4'h0; end
            4'hC: begin sgshift_m4 = 4'd3; sgmask = 4'h1; sgor = 4'h0; end
            4'hD: begin sgshift_m4 = 4'd2; sgmask = 4'h3; sgor = 4'h0; end
            4'hE: begin sgshift_m4 = 4'd1; sgmask = 4'h7; sgor = 4'h0; end
            default: begin sgshift_m4 = 4'd0; sgmask = 4'hF; sgor = 4'h0; end
        endcase
    end
    logic [4:0]  sgshift;
    assign sgshift = 5'd10 + {1'b0, sgshift_m4};
    logic [15:0] sprshadowmask;
    assign sprshadowmask = r4c[2] ? 16'h8000 : 16'h0000;
    logic [13:0] sprpixmask;
    assign sprpixmask = 14'(((16'd1 << sgshift) - 16'd1) & 16'h3FFF);
    logic [13:0] sprshadow;
    assign sprshadow = 14'h3FFE & sprpixmask;

    // per-pixel sprite candidate
    logic [3:0]  sgrp, seffgrp;
    assign sgrp = 4'(pix_sprite >> sgshift) & sgmask;
    assign seffgrp = sgor | sgrp;
    logic [15:0] sgctl;
    assign sgctl = mreg[{2'd0, seffgrp}];         // $00 + 2*effgroup
    layctl_t sprent;
    always_comb begin
        sprent.lay      = 3'd6;
        sprent.active   = 1'b1;
        sprent.effpri   = {sgctl[3:0], 3'd7};
        sprent.palbase  = (r4c[1:0] == 2'd3) ? {r4c[7:4], 10'd0}
                                             : {sgctl[7:4], 10'd0};
        sprent.mixshift = sgctl[9:8];
        sprent.blendmask = 8'd0;      // sprites never blend as FIRST
        sprent.sprblend  = 16'd0;
        sprent.coffs    = coloroffs({3'd0, r3e[6]}, r4c[15]);
    end

    logic        spr_trans, spr_shadowpat, spr_opaque, spr_bit15sh;
    logic [13:0] spr_masked;
    assign spr_trans = (pix_sprite & 16'h7FFF) == 16'h7FFF;
    assign spr_masked = 14'(pix_sprite) & sprpixmask;
    assign spr_shadowpat = !spr_trans &&
                           ((spr_masked & 14'h3FFE) == sprshadow);
    assign spr_opaque = !spr_trans && !spr_shadowpat;
    assign spr_bit15sh = (~pix_sprite & sprshadowmask) != 16'h0;

    // ------------------------------------------------------- pixel stage 0
    // candidate pixels per laynum
    logic [12:0] bgpix;
    assign bgpix = r5e[15]
        ? {r5e[12:9], 9'((r5e[8:0] + {1'b0, line}))}
        : {r5e[12:9], 9'd0};

    function automatic logic [12:0] laypix (input logic [2:0] lay);
        unique case (lay)
            3'd0: laypix = pix_text;
            3'd1: laypix = pix_nbg0;
            3'd2: laypix = pix_nbg1;
            3'd3: laypix = pix_nbg2;
            3'd4: laypix = pix_nbg3;
            3'd5: laypix = pix_bitmap;
            default: laypix = bgpix;   // background (always opaque)
        endcase
    endfunction

    // first/second non-transparent scan in sorted order
    logic        hit_v [0:6];
    always_comb begin
        for (int i = 0; i < 7; i++) begin
            logic [12:0] p;
            p = laypix(sorted[i].lay);
            hit_v[i] = sorted[i].active &&
                       (sorted[i].lay == 3'd7 || p != 13'd0);
        end
    end

    // virtual 8-slot scan: the sprite entry inserts before the first
    // sorted slot it outranks (slot k); shadow pixels pass through and
    // darken whatever wins below (MAME mix loop semantics)
    logic [2:0] spr_k;
    always_comb begin
        spr_k = 3'd7;
        for (int i = 6; i >= 0; i--)
            if (sprent.effpri > sorted[i].effpri) spr_k = 3'(i);
    end

    // virtual slot v: entry = sprite when v == spr_k, else sorted
    // index (v < spr_k ? v : v - 1)
    logic       vhit [0:7];
    always_comb begin
        int si;
        si = 0;
        for (int v = 0; v < 8; v++) begin
            if (3'(v) == spr_k)
                vhit[v] = spr_opaque;
            else begin
                si = (3'(v) < spr_k) ? v : v - 1;
                vhit[v] = (si <= 6) ? hit_v[si] : 1'b0;
            end
        end
    end

    logic [3:0] firstv, secondv;
    always_comb begin
        firstv = 4'd8; secondv = 4'd8;
        for (int v = 7; v >= 0; v--)
            if (vhit[v]) begin
                secondv = firstv;
                firstv = 4'(v);
            end
    end

    function automatic layctl_t vent (input logic [3:0] v);
        logic [2:0] si;
        si = (3'(v) < spr_k) ? v[2:0] : v[2:0] - 3'd1;
        if (v[2:0] == spr_k && v < 4'd8)
            vent = sprent;
        else if (v < 4'd8 && si <= 3'd6)
            vent = sorted[si];
        else
            // v == 8 ("none"): a zeroed entry, as MAME's mix loop
            // treats an absent layer (a real slot here would add a
            // phantom blend term)
            vent = '0;
    endfunction

    logic first_f, second_f;
    assign first_f  = firstv < 4'd8;
    assign second_f = secondv < 4'd8;

    // palette index per candidate
    function automatic logic [13:0] palidx (input layctl_t e,
                                            input logic [13:0] p);
        logic [15:0] shifted;
        shifted = {2'd0, p} >> e.mixshift;
        palidx = (e.palbase + {shifted[13:4], 4'd0} + {10'd0, p[3:0]})
                 & 14'h3FFF;
    endfunction

    // pixel value for a virtual slot (sprite uses the masked FB word)
    function automatic logic [13:0] vpix (input logic [3:0] v);
        if (v[2:0] == spr_k && v < 4'd8)
            vpix = spr_masked;
        else
            vpix = {1'b0,
                    laypix(sorted[(3'(v) < spr_k) ? v[2:0]
                                                  : v[2:0] - 3'd1].lay)};
    endfunction

    // stage 0 -> stage 1 registers. Quartus 17.0 cannot member-select a
    // function result (vent(x).field) — go through struct temporaries.
    layctl_t f_ent, s_ent;
    always_comb begin
        f_ent = vent(firstv);
        s_ent = vent(secondv);
    end

    // blend gate (MAME mix loop): the first layer's blendmask must select
    // the second's laynum and, when the second is the sprite layer, the
    // pixel's sprite group must be in the first layer's group mask
    // (compute_sprite_blend). Golden Axe never enables blending.
    logic blend_gate;
    assign blend_gate = second_f
        && ((f_ent.blendmask >> s_ent.lay) & 8'd1) != 8'd0
        && (s_ent.lay != 3'd6 || f_ent.sprblend[seffgrp]);

    // shadow applies when the scan reaches the sprite slot before the
    // winner, and also when the blend scan passes the sprite slot on its
    // way to the second layer (MAME checks the sprite case on the second
    // scan too; not confirmed on hardware). MAME runs that second scan
    // whenever the first layer has ANY blendmask bit set, whether or not
    // the second layer it finds is one the first blends with, so the
    // shadow does not wait for blend_gate: SegaSonic's cobblestone
    // foreground has blend bits, sits above the sprite group, and the
    // character shadows under it are halved in MAME (docs/sonic-bringup.md
    // §6, sonicp attract f750/f900). The bit-15 rule holds for a
    // TRANSPARENT sprite pixel as well: MAME's mix loop sets
    // `shadow = ~sprpix & sprshadowmask` when the scan reaches the sprite
    // slot, before its transparency test (segas32_v.cpp mix_all_layers,
    // 0.288 and master alike). That is how a shadow sprite works: it only
    // clears bit 15 of the frame-buffer word (`dest &= 0x7fff`), leaving
    // 0x7FFF over empty frame buffer, and the layers under it come out
    // halved. Burning Rival's fighters' floor shadows are drawn this way
    // ($4C = FF45). A 2026-07-16 change had excluded transparent pixels to
    // satisfy s32_mixer_blend case F, whose "no shadow" reference used
    // 0x7FFF under a $4C with bit 2 set; that reference is now 0xFFFF.
    logic spr_shadow_px;
    assign spr_shadow_px = spr_shadowpat || spr_bit15sh;
    logic shadow0;
    assign shadow0 = (({1'b0, spr_k} <= firstv)
                      // (secondv = 8, no second layer: MAME's scan
                      // still passes the sprite slot to the background)
                      || (f_ent.blendmask != 8'd0
                          && {1'b0, spr_k} <= secondv))
                     && spr_shadow_px;

    // stage 0: register the palette addresses. The priority sort and
    // palidx/vpix are ~38 ns of logic, too long to feed the palette RAM's
    // address register directly.
    layctl_t     s0_first, s0_second;
    logic        s0_v, s0_vb, s0_blend, s0_shadow;
    logic [13:0] s0_addr_a, s0_addr_b;
    always_ff @(posedge clk) begin
        if (rst) begin
            s0_v  <= 1'b0;
            s0_vb <= 1'b0;
        end else if (cen) begin
            s0_v  <= px_valid && first_f;
            s0_vb <= px_valid && second_f;
            s0_addr_a <= palidx(f_ent, vpix(firstv));
            s0_addr_b <= palidx(s_ent, vpix(secondv));
            s0_first  <= f_ent;
            s0_second <= s_ent;
            // shade_win joins the sprite shadow here and follows the same
            // s0 -> s0r -> s1 path to the halving after the clamp
            s0_shadow <= shadow0 || shade_win;
            s0_blend  <= blend_gate;
        end
    end

    assign pal_re_a   = s0_v;
    assign pal_addr_a = s0_addr_a;
    assign pal_re_b   = s0_vb;
    assign pal_addr_b = s0_addr_b;

    // stage 0r: one more stage of context, so the pixel's context meets
    // its palette data at s1. The palette reads use the M10K output
    // register (s32_tdp OREGB=1 in s32_video) and the result is captured
    // on cen_mix, two cen ticks after the address goes out.
    layctl_t     s0r_first, s0r_second;
    logic        s0r_v, s0r_blend, s0r_shadow;
    always_ff @(posedge clk) begin
        if (rst) begin
            s0r_v <= 1'b0;
        end else if (cen) begin
            s0r_v <= s0_v;
            s0r_first  <= s0_first;
            s0r_second <= s0_second;
            s0r_shadow <= s0_shadow;
            s0r_blend  <= s0_blend;
        end
    end

    // stage 1 context: aligned with the palette RAM's registered read
    layctl_t     s1_first, s1_second;
    logic        s1_v, s1_blend, s1_shadow;
    always_ff @(posedge clk) begin
        if (rst) begin
            s1_v <= 1'b0;
        end else if (cen) begin
            s1_v <= s0r_v;
            s1_first  <= s0r_first;
            s1_second <= s0r_second;
            s1_shadow <= s0r_shadow;
            s1_blend  <= s0r_blend;
        end
    end

    // ------------------------------------------------------- pixel stage 1
    // palette data + offsets + blend + clamp
    function automatic logic signed [7:0] offs_chan
        (input logic [4:0] v, input logic [1:0] set, input int c);
        offs_chan = $signed({3'd0, v}) + $signed(roffs[set][c]);
    endfunction

    logic signed [7:0] fr, fg, fb, sr, sg, sb;
    logic signed [11:0] br, bg_, bb;
    logic [4:0] outr, outg, outb;
    always_comb begin
        fr = offs_chan(pal_rdata_a[4:0],   s1_first.coffs, 0);
        fg = offs_chan(pal_rdata_a[9:5],   s1_first.coffs, 1);
        fb = offs_chan(pal_rdata_a[14:10], s1_first.coffs, 2);
        sr = offs_chan(pal_rdata_b[4:0],   s1_second.coffs, 0);
        sg = offs_chan(pal_rdata_b[9:5],   s1_second.coffs, 1);
        sb = offs_chan(pal_rdata_b[14:10], s1_second.coffs, 2);
        if (s1_blend) begin
            br  = (fr * $signed({5'd0, 4'd7 - {1'b0, blendfactor}})
                 + sr * $signed({5'd0, {1'b0, blendfactor} + 4'd1})) >>> 3;
            bg_ = (fg * $signed({5'd0, 4'd7 - {1'b0, blendfactor}})
                 + sg * $signed({5'd0, {1'b0, blendfactor} + 4'd1})) >>> 3;
            bb  = (fb * $signed({5'd0, 4'd7 - {1'b0, blendfactor}})
                 + sb * $signed({5'd0, {1'b0, blendfactor} + 4'd1})) >>> 3;
        end else begin
            br  = 12'(fr);
            bg_ = 12'(fg);
            bb  = 12'(fb);
        end
        // The 315-5242 shadow halves each channel after the DAC: the DAC
        // gets the clamped 5-bit value and the shade control then pulls each
        // channel's analog level down. So clamp first, then halve (a zero
        // channel stays zero). MAME halves before clamping (segas32_v.cpp
        // mix_all_layers); the two differ only on a shadowed channel that a
        // colour offset pushed outside 0..31. The exact analog ratio is not
        // measured.
        outr = br  < 0 ? 5'd0 : (br  > 31 ? 5'd31 : br[4:0]);
        outg = bg_ < 0 ? 5'd0 : (bg_ > 31 ? 5'd31 : bg_[4:0]);
        outb = bb  < 0 ? 5'd0 : (bb  > 31 ? 5'd31 : bb[4:0]);
        if (s1_shadow) begin
            outr = outr >> 1;
            outg = outg >> 1;
            outb = outb >> 1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) rgb_valid <= 1'b0;
        else if (cen) begin
            rgb_valid <= s1_v;
            rgb <= {outb, outg, outr};
        end
    end

endmodule
