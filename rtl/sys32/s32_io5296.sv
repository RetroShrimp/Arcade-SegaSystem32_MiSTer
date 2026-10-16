// s32_io5296.sv — Sega 315-5296 I/O chip (System 32 single: mapped at
// V60 C00000-C0001F, byte lanes on even addresses; register offset =
// (A >> 1) & 0x3F).
//
// Behaviour per MAME 315_5296.cpp (the game's I/O self-check toggles
// output ports and verifies the latch readback):
//   0-7  ports A-H: dir bit set -> read back the output latch,
//        else the input port
//   8-B  'S','E','G','A' protection bytes
//   C/E  CNT register — exposed raw on the cnt output. On System 32
//        single MAME wires out_cnt1 (bit 1) to display_enable_w: the
//        game clears it across scene transitions and the screen blanks
//        (s32_sys routes cnt[1] to s32_video's display-enable blank).
//        cnt[2] = SRES, the sound-section reset (wired in s32_sys).
//        cnt[0] = CNT0, the port C buffer direction (s32tech REG2 D0):
//        only its readback quirk (below) is modelled, not the buffer
//   D/F  direction register
//
// On System 32 single: port D latch drives the EEPROM (bit7 DI,
// bit6 SCLK, bit5 CS), port G = SW2 outputs, port H = tilebank;
// port F input carries SW1 DIPs (low nibble), service/test switches
// and the EEPROM DO on bit7 (pulled high when the EEPROM CS is low).

module s32_io5296 (
    input  logic        clk,
    input  logic        rst,

    input  logic        sel,
    input  logic        we,
    input  logic [5:0]  offset,       // (A >> 1) & 0x3F
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,

    input  logic [63:0] in_ports,        // {H,...,A} inputs, 8x8
    output logic [63:0] out_latches,     // {H,...,A} output latches
    output logic [7:0]  dir,
    output logic [7:0]  cnt
);

    // unpacked views (packed ports for Quartus 17 compatibility)
    logic [7:0] in_port [0:7];
    logic [7:0] out_latch [0:7];
    genvar gp;
    generate
        for (gp = 0; gp < 8; gp = gp + 1) begin : g_ports
            assign in_port[gp] = in_ports[8*gp +: 8];
            assign out_latches[8*gp +: 8] = out_latch[gp];
        end
    endgenerate

    always_comb begin
        unique case (offset)
            6'h00, 6'h01, 6'h02, 6'h03,
            6'h04, 6'h05, 6'h06, 6'h07: begin
                rdata = dir[offset[2:0]] ? out_latch[offset[2:0]]
                                         : in_port[offset[2:0]];
                // s32tech, 315-5296 "Unusual behavior": read as INPUT,
                // port D bits 5:4
                // return the CNT0 level and port G returns all 0
                if (!dir[3] && offset[2:0] == 3'd3)
                    rdata[5:4] = {2{cnt[0]}};
                if (!dir[6] && offset[2:0] == 3'd6)
                    rdata = 8'h00;
            end
            6'h08: rdata = "S";
            6'h09: rdata = "E";
            6'h0A: rdata = "G";
            6'h0B: rdata = "A";
            6'h0C, 6'h0E: rdata = cnt;
            6'h0D, 6'h0F: rdata = dir;
            default: rdata = 8'hFF;
        endcase
    end

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1) out_latch[i] <= 8'h00;
            dir <= 8'h00;
            cnt <= 8'h00;
        end else if (sel && we) begin
            unique case (offset)
                6'h00, 6'h01, 6'h02, 6'h03,
                6'h04, 6'h05, 6'h06, 6'h07:
                    out_latch[offset[2:0]] <= wdata;
                6'h0E: cnt <= wdata;
                6'h0F: dir <= wdata;
                default: ;
            endcase
        end
    end

endmodule
