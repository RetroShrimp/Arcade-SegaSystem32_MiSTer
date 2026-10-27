// s32_upd4701.sv — NEC uPD4701A two-axis incremental encoder counter, as
// used on SegaSonic's 837-8685 trackball I/O board (three of them, at
// $C00040 / $C00048 / $C00050).
//
// References:
//   MAME latest master src/devices/machine/upd4701.cpp (read_xy, d_r,
//     reset_xy_w, cs_w) and src/mame/sega/segas32.cpp
//     system32_trackball_map / INPUT_PORTS_START(sonic).
//   NEC uPD4701A pinout (MAME upd4701.h): 12-bit up/down counters per axis,
//     /CS, X/Y and U/L select the byte on D0-D7, RESET X / RESET Y pins,
//     /LEFT /RIGHT /MIDDLE switch inputs reported in D4-D7 of the upper byte.
//   docs/sonic-bringup.md §3; docs/OPEN-QUESTIONS.md Q50.
//
// Bus view (MAME read_xy): offset[1] = X/Y, offset[0] = upper/lower byte.
//   lower byte = count[7:0]
//   upper byte = {any-switch, left, right, middle, count[11:8]}
// SegaSonic's buttons are on the 315-5296, not on these switch inputs, so the
// switch bits read 0 (inputs inactive). The game reads only the lower bytes.
// Any write resets both axes (MAME reset_xy_w; how the board decodes its
// reset is Q50).
//
// The chip latches the counts when /CS falls. One V60 access is one /CS
// assertion and the fabric samples rdata during it, so returning the live
// count at the access is the same value. Counting is continuous: a step
// that lands between the game's read and its reset is lost, as on a real
// board. MAME counts once a frame instead (upd4701_device::update).
//
// Cost: two 12-bit counters, a byte mux.

module s32_upd4701 (
    input  logic        clk,
    input  logic        rst,

    // count input: add the signed (mod 4096) steps when cnt_stb is high
    input  logic        cnt_stb,
    input  logic [11:0] dx,
    input  logic [11:0] dy,

    // V60 side (8-bit device on the even byte lane)
    input  logic        sel,
    input  logic        we,
    input  logic [1:0]  offset,       // {X/Y, U/L}
    output logic [7:0]  rdata
);

    logic [11:0] cx, cy;

    always_ff @(posedge clk) begin
        if (rst) begin
            cx <= 12'd0; cy <= 12'd0;
        end else if (sel && we) begin
            cx <= 12'd0; cy <= 12'd0;     // RESET X + RESET Y
        end else if (cnt_stb) begin
            cx <= cx + dx; cy <= cy + dy;
        end
    end

    always_comb begin
        unique case (offset)
            2'd0: rdata = cx[7:0];
            2'd1: rdata = {4'd0, cx[11:8]};
            2'd2: rdata = cy[7:0];
            default: rdata = {4'd0, cy[11:8]};
        endcase
    end

endmodule
