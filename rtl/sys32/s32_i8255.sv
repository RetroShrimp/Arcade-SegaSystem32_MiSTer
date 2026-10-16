// s32_i8255.sv — i8255A PPI, mode-0 subset (System 32 4-player PCB:
// V60 C00060-C00067, byte lanes on even addresses; offset = A[2:1]).
// The 4-player I/O board: ports A/B/C = EXTRA1-3 player inputs; the
// game's self-check sets part of port C as outputs and verifies the latch
// readback.
//
// Reset control word = 0x9B (all ports input, mode 0). Modes 1 and 2
// (strobed, bidirectional) are not modelled: System 32 only uses mode 0
// (MAME segas32), and a mode 1/2 control word behaves as mode 0 here.
// Mode-set writes clear the output latches (8255 datasheet). BSR writes to
// the control offset set or reset single port-C bits.

module s32_i8255 (
    input  logic       clk,
    input  logic       rst,

    input  logic       sel,
    input  logic       we,
    input  logic [1:0] offset,        // 0=A 1=B 2=C 3=control
    input  logic [7:0] wdata,
    output logic [7:0] rdata,

    input  logic [7:0] in_a,
    input  logic [7:0] in_b,
    input  logic [7:0] in_c,
    output logic [7:0] out_a,
    output logic [7:0] out_b,
    output logic [7:0] out_c,
    output logic [7:0] ctrl
);

    always_comb begin
        unique case (offset)
            2'd0: rdata = ctrl[4] ? in_a : out_a;
            2'd1: rdata = ctrl[1] ? in_b : out_b;
            2'd2: rdata = {ctrl[3] ? in_c[7:4] : out_c[7:4],
                           ctrl[0] ? in_c[3:0] : out_c[3:0]};
            2'd3: rdata = ctrl;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl  <= 8'h9B;           // all ports input
            out_a <= 8'h00;
            out_b <= 8'h00;
            out_c <= 8'h00;
        end else if (sel && we) begin
            unique case (offset)
                2'd0: out_a <= wdata;
                2'd1: out_b <= wdata;
                2'd2: out_c <= wdata;
                2'd3: begin
                    if (wdata[7]) begin       // mode set
                        ctrl  <= wdata;
                        out_a <= 8'h00;
                        out_b <= 8'h00;
                        out_c <= 8'h00;
                    end else                  // port C bit set/reset
                        out_c[wdata[3:1]] <= wdata[0];
                end
            endcase
        end
    end

endmodule
