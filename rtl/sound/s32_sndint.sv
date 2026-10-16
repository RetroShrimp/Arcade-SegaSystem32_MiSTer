// s32_sndint.sv — sound-side interrupt controller (Z80 companion of the
// 315-5385, three vectors).
//
// References: MAME segas32.cpp :924-1010 (update_sound_irq_state,
// signal/clear_sound_irq, int control lo/hi).
// Source codes: 0 = YM3438 #1 IRQ (level), 1 = V60 command (latched
// pulse; the main CPU touched $D0000C-F). Control registers (Z80 OUT
// 0xD0-0xD3, mirrored to 0xDF): [0..2] = source select per vector,
// [3] = mask (1 disables). OUT 0xC0-0xCF: odd offsets ACK
// (irq_input &= data), offsets with bit 2 set pulse the V60 interrupt
// (the 315-5385's Z80-comm source). Z80 interrupt vector byte = 2 * n
// for the lowest pending unmasked vector n.

module s32_sndint (
    input  logic       clk,
    input  logic       rst,

    // Z80 I/O write strobes (decoded by the sound top)
    input  logic       lo_we,         // 0xC0-0xCF
    input  logic [3:0] lo_off,
    input  logic [7:0] lo_data,
    input  logic       hi_we,         // 0xD0-0xDF (mirrored regs 0-3)
    input  logic [1:0] hi_off,
    input  logic [7:0] hi_data,

    // interrupt sources
    input  logic       ym_irq,        // level (source code 0)
    input  logic       v60_cmd,       // single-cycle pulse (source 1)

    // Z80 side
    output logic       int_n,
    output logic [7:0] int_vector,    // byte driven during intack

    // V60 side (315-5385 Z80-comm event)
    output logic       v60_irq_pulse
);

    logic [7:0] ctl [0:3];
    logic [2:0] pend;
    logic       ym_q;

    // vectors whose source register selects a given code
    function automatic logic [2:0] hits (input logic [7:0] code);
        hits = {ctl[2] == code, ctl[1] == code, ctl[0] == code};
    endfunction

    logic [2:0] effirq;
    assign effirq = pend & ~ctl[3][2:0];

    always_comb begin
        int_n = !(|effirq);
        int_vector = 8'd0;
        if      (effirq[0]) int_vector = 8'd0;
        else if (effirq[1]) int_vector = 8'd2;
        else if (effirq[2]) int_vector = 8'd4;
    end

    always_ff @(posedge clk) begin
        v60_irq_pulse <= 1'b0;
        if (rst) begin
            ctl[0] <= 8'd0; ctl[1] <= 8'd0;
            ctl[2] <= 8'd0; ctl[3] <= 8'd0;
            pend <= 3'd0;
            ym_q <= 1'b0;
        end else begin
            // YM level source: set on rise, clear on fall (MAME
            // signal/clear pair from the ym3438 irq handler)
            ym_q <= ym_irq;
            if (ym_irq && !ym_q)  pend <= pend | hits(8'd0);
            if (!ym_irq && ym_q)  pend <= pend & ~hits(8'd0);

            // V60 command: latched until acked
            if (v60_cmd) pend <= pend | hits(8'd1);

            if (lo_we) begin
                if (lo_off[0])
                    pend <= pend & lo_data[2:0];       // ack
                if (lo_off[2])
                    v60_irq_pulse <= 1'b1;             // signal the V60
            end
            if (hi_we)
                ctl[hi_off] <= hi_data;
        end
    end

endmodule
