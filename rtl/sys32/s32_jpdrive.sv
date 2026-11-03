// s32_jpdrive.sv — Jurassic Park's motion drive board, as the main board
// sees it on connector CNB: the reply it gives to the program's boot-time
// loopback check ("NET_WORK CHECKING NOW", MAIN BD to DRIVE BD).
//
// References:
//   s32tech.txt 315-5296 section: port C = CNB pins 19-26 through a
//     bidirectional buffer (CNT0 = direction, 0 = CNB to port C), port G =
//     CNB pins 3-17, open-collector outputs.
//   MAME latest master src/mame/sega/segas32.cpp ROM_START(jpark): region
//     cpu2 epr-13908.xx "cabinet movement" (the drive board's Z80 program,
//     not emulated); init_jpark() patches the program at $C15A8 ("Temp.
//     Patch until we emulate the 'Drive Board'") so the check never runs.
//   epr-13908 (disassembled, docs/jpark-bringup.md §4): every interrupt
//     ($0038 -> $0A35) reads the command on its port 00, complements it,
//     and accepts it once two successive reads agree ($0A51-$0A62). A
//     loopback pattern ($1F/$2F/$4F/$8F/$F1/$F2/$F4/$F8, $0A63-$0A8C)
//     selects its one-hot nibble (the low one when the high nibble is $F,
//     $0AB7-$0ACE), and the board writes that nibble, complemented, to its
//     port 3 bits 3-0, keeping bits 7-4 ($0C20-$0C2A). Nothing else writes
//     those four bits after power-on (all-ones, $0103-$010B), so the reply
//     stays latched across every other command.
//   jpark program (epr-16402a): the vblank handler latches port C bits 3-0
//     ($FF546); every other frame $C17F9 sends the next pattern of the table
//     at $C1886 on port G and compares the latched reply with that entry's
//     answer, so a reply to the previous pattern must be in by the next
//     vblank, ~224 lines (~14 ms) after the port G write. 150 consecutive
//     matches pass the check ($C184A). MAME with the patch removed and this
//     reply answered from a Lua tap passes it (151/151 compares) and boots
//     (tools/mame/jpark_probe.lua JP_RAW=1 JP_DRIVE=1).
//
// The wiring: the drive board reads the port G pins complemented (the
// open-collector outputs pull its input low for a 1), which its program
// undoes, so the command is the port G latch; and its port 3 bits 3-0 reach
// port C bits 3-0 straight, the only wiring that passes the check. When
// port G is an input the pins are released, the board reads all-ones, and
// the command is $00, which it ignores.
//
// Timing: the board samples on its interrupt, whose rate is not known
// (Q61). The model samples every 2^16 clocks (~1.02 ms at 64.43 MHz), so a
// new pattern is answered 1-2 ms after the write: well inside the ~14 ms
// the program allows. Nothing else in the program reads the reply except
// the service mode's input and drive tests, which only display it.
//
// The seat's motors and sensors are not modelled; the program sends motion
// commands ($80-$DF) during play and never reads anything back.
//
// Bench: sim/s32_jpdrive.
//
// Cost: a 16-bit tick counter, an 8-bit sample and a 4-bit reply.

module s32_jpdrive #(
    parameter int TICK_BITS = 16      // sample every 2^TICK_BITS clocks
) (
    input  logic        clk,
    input  logic        rst,

    input  logic [7:0]  cnb_g,     // port G as the board decodes it
    output logic [3:0]  reply      // to port C bits 3-0 (power-on $F)
);

    logic [TICK_BITS-1:0] tick_cnt;
    logic [7:0]  smp;

    function automatic logic loopback (input logic [7:0] c);
        loopback = (c == 8'h1F) || (c == 8'h2F) || (c == 8'h4F) ||
                   (c == 8'h8F) || (c == 8'hF1) || (c == 8'hF2) ||
                   (c == 8'hF4) || (c == 8'hF8);
    endfunction

    always_ff @(posedge clk) begin
        tick_cnt <= tick_cnt + 1'b1;
        if (&tick_cnt) begin
            smp <= cnb_g;
            if (cnb_g == smp && loopback(cnb_g))
                reply <= ~((cnb_g[7:4] == 4'hF) ? cnb_g[3:0] : cnb_g[7:4]);
        end
        if (rst) begin
            tick_cnt <= '0;
            smp      <= 8'h00;
            reply    <= 4'hF;
        end
    end

endmodule
