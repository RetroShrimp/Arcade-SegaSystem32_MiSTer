// s32_msm6253.sv — OKI MSM6253 8-bit 4-channel A/D converter, as used on
// Rad Mobile's 837-7536 A/D board (MAME sega_system32_analog: one chip at
// $C00050-$C00057, even bytes, repeating every $80 through $CFFFFF).
//
// References:
//   MAME latest master src/devices/machine/msm6253.cpp (address_w, d7_r,
//     shift_out) and src/mame/sega/segas32.cpp system32_analog_map /
//     INPUT_PORTS_START(radm) (ch0 wheel, ch1 accelerator, ch2 brake).
//   MAME segas32.cpp ROM_START(radm) comment: "A/D BD NO. 837-7536".
//   docs/radm-bringup.md §3; docs/OPEN-QUESTIONS.md Q51.
//
// Bus view (MAME):
//   write, any data, to word offset n  -> the shift register loads channel
//                                         n & 3's conversion result
//   read, any of the four words        -> D7 = the shift register's MSB,
//                                         D0-D6 open bus (1s); then the
//                                         register shifts left, 0 in
// So the program selects a channel with one write and reads the 8-bit
// result MSB first with eight reads, collecting D7.
//
// The chip converts continuously and keeps a latch per channel; MAME reads
// the input port at the write, and so does this model (ain* are the live
// values). When the real latch updates relative to the write, and whether the
// shift happens as /RD falls or rises, are Q51; the program cannot see
// either while it reads one bit per access.
//
// Timing: the fabric's strobe (sel) is one clock, and it captures rdata two
// clocks later (s32_v60bus A_SUB -> A_SUB_L), so the bit read is latched at
// the strobe, as the chip drives D7 for the whole /RD low, rather than taken
// from the register after it has shifted.
//
// Cost: an 8-bit shift register, one output flop, a 4:1 byte mux.

module s32_msm6253 (
    input  logic        clk,
    input  logic        rst,

    // conversion results, channels 0-3 (unsigned, 0x00-0xFF)
    input  logic [7:0]  ain0,
    input  logic [7:0]  ain1,
    input  logic [7:0]  ain2,
    input  logic [7:0]  ain3,

    // V60 side (8-bit device on the even byte lane)
    input  logic        sel,
    input  logic        we,
    input  logic [1:0]  offset,       // word offset within $C00050-57
    output logic [7:0]  rdata
);

    logic [7:0] sr;
    logic       d7;

    always_ff @(posedge clk) begin
        if (rst) begin
            sr <= 8'd0;
            d7 <= 1'b0;
        end else if (sel && we) begin
            unique case (offset)
                2'd0: sr <= ain0;
                2'd1: sr <= ain1;
                2'd2: sr <= ain2;
                2'd3: sr <= ain3;
            endcase
        end else if (sel) begin
            d7 <= sr[7];
            sr <= {sr[6:0], 1'b0};
        end
    end

    assign rdata = {d7, 7'h7F};

endmodule
