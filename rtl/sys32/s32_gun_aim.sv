// s32_gun_aim.sv — the aim of Alien3's two positional guns, as the four
// MSM6253 channels of the 837-7536 A/D board read it.
//
// References:
//   MAME latest master src/mame/sega/segas32.cpp INPUT_PORTS_START(alien3):
//     ANALOG1/ANALOG2 P1 gun X/Y, ANALOG3/ANALOG4 P2 gun X/Y
//     (IPT_AD_STICK_X/Y, centre $80; Y PORT_MINMAX(0x01, 0xff));
//     sega_system32_analog: adc.set_input_tag<0..3>("ANALOG1".."ANALOG4").
//   ROM_START(alien3) comment: "A/D BD NO. 837-7536" (Rad Mobile's board).
//   docs/alien3-bringup.md §3. Bench: sim/s32_gun_aim.
//
// Each gun turns two potentiometers, so the converter reads its position:
// X left $00 .. right $FF, Y top .. bottom, never $00 in Y. A mounted gun
// stays where it is pointed, so each gun has ONE aim, and whichever control
// moved last sets it:
//   - the player's left analog stick, or a lightgun reporting its aim as
//     that stick, is an absolute pointer: $80 + its value. While it has the
//     aim, the aim is its value exactly, every count, with no dead zone (a
//     lightgun has to track through the middle of the screen too).
//   - the d-pad moves the aim 3 counts per `tick` (S32.sv's adc_tick,
//     ~250 Hz: ~0.34 s across the range), and for P1 the mouse moves it one
//     count per mouse count. Either takes the aim from the stick, and it
//     stays where it is left.
//   - the stick takes the aim back once it moves more than STICK_GRAB counts
//     on either axis from where it stood when it lost it, so a thumbstick
//     resting slightly off centre does not drag a d-pad aim back.
// Reset centres the aim and gives it to the stick. The game maps the range
// to the screen with its own GUN ADJUSTMENT (service mode; the factory
// EEPROM carries a calibration), which also calibrates a lightgun. The rates,
// the grab threshold and the mouse scale are usability settings, not
// hardware.
//
// Cost: per gun an 8-bit X/Y aim, the stick's reference X/Y and an owner
// bit; their step/clamp adders and compares.

module s32_gun_aim #(
    parameter logic [7:0] STICK_GRAB = 8'd4
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,          // d-pad step strobe
    input  logic [3:0]  dpad1,         // MiSTer order: [0]R [1]L [2]D [3]U
    input  logic [3:0]  dpad2,
    input  logic [15:0] stick1,        // left stick: [7:0] X, [15:8] Y,
    input  logic [15:0] stick2,        //   signed, positive right / down
    input  logic        mouse_ev,      // one PS/2 packet (P1 only)
    input  logic [8:0]  mouse_dx,      // signed, positive right
    input  logic [8:0]  mouse_dy,      // signed, positive UP
    output logic [31:0] ain            // {P2 Y, P2 X, P1 Y, P1 X}
);

    function automatic [7:0] aim_step (input [7:0] v, input up, input dn,
                                       input [7:0] lo);
        aim_step = (up & ~dn) ? ((v > 8'hFC) ? 8'hFF : v + 8'd3)
                 : (dn & ~up) ? ((v < lo + 8'd3) ? lo : v - 8'd3) : v;
    endfunction
    function automatic [7:0] aim_add (input [7:0] v, input [9:0] d,
                                      input [7:0] lo);
        logic signed [10:0] s;
        s = $signed({3'b000, v}) + $signed({d[9], d});
        aim_add = (s > 11'sd255) ? 8'hFF
                : (s < $signed({3'b000, lo})) ? lo : s[7:0];
    endfunction
    // the stick as a pointer: {Y, X}, Y kept off $00 as MAME's port is
    function automatic [15:0] point (input [15:0] stick);
        logic [7:0] y;
        y = stick[15:8] ^ 8'h80;
        point = {(y == 8'h00) ? 8'h01 : y, stick[7:0] ^ 8'h80};
    endfunction
    function automatic logic far (input [7:0] a, input [7:0] b);
        far = ((a > b) ? a - b : b - a) > STICK_GRAB;
    endfunction

    logic [15:0] aim [0:1];                  // {Y, X}
    logic [15:0] ref_q [0:1];                // the stick when it lost the aim
    logic        own [0:1];                  // 1 = the stick has the aim
    initial for (int n = 0; n < 2; n++) begin
        aim[n] = 16'h8080; ref_q[n] = 16'h8080; own[n] = 1'b1;
    end

    always_ff @(posedge clk) begin
        for (int n = 0; n < 2; n++) begin
            logic [15:0] p, a;
            logic [3:0]  dp;
            logic        dmove, mmove;
            p  = point(n == 0 ? stick1 : stick2);
            dp = (n == 0) ? dpad1 : dpad2;
            dmove = tick & |dp;
            mmove = (n == 0) & mouse_ev & (|mouse_dx | |mouse_dy);
            a = aim[n];
            if (dmove | mmove) begin
                if (own[n]) a = p;           // carry on from the stick's aim
                if (dmove) begin
                    a[7:0]  = aim_step(a[7:0],  dp[0], dp[1], 8'h00);  // R / L
                    a[15:8] = aim_step(a[15:8], dp[2], dp[3], 8'h01);  // D / U
                end
                if (mmove) begin             // screen Y runs down
                    a[7:0]  = aim_add(a[7:0],  {mouse_dx[8], mouse_dx}, 8'h00);
                    a[15:8] = aim_add(a[15:8], -{mouse_dy[8], mouse_dy}, 8'h01);
                end
                aim[n] <= a;
                own[n] <= 1'b0;
                ref_q[n] <= p;
            end else if (own[n]) begin
                aim[n] <= p;
            end else if (far(p[7:0], ref_q[n][7:0]) || far(p[15:8], ref_q[n][15:8])) begin
                aim[n] <= p;
                own[n] <= 1'b1;
            end
        end
        if (rst) for (int n = 0; n < 2; n++) begin
            aim[n] <= 16'h8080; ref_q[n] <= 16'h8080; own[n] <= 1'b1;
        end
    end

    // the stick's aim shows the clock it moves; a held aim from its register
    assign ain = {own[1] ? point(stick2) : aim[1],
                  own[0] ? point(stick1) : aim[0]};

endmodule
