// s32_ddrload.sv — fast ROM loading through DDR3.
//
// The .mra carries address="0x30000000" on the rom element, so the MiSTer
// firmware copies the assembled 27.3 MB image into DDR3 itself and sends an
// empty index-0 download (start, a seek to the image length, end; no data).
// S32.sv detects that and starts this module, which reads the image over
// the DDRAM port in 128 x 64-bit bursts (1 KB pages) into a staging RAM and
// feeds the bytes into the normal loader path (S32.sv's skid buffer). That
// costs ~3 clk per byte, about 1.4 s for the whole image instead of 7-15 s
// over the byte-by-byte download, and keeps a single path into the loader.
// A download that carries data still uses the byte-by-byte path.
//
// DDRAM port protocol (MiSTer framework):
//   - DDRAM_ADDR addresses 64-bit words; byte 0x30000000 = 0x06000000.
//   - assert RD with BURSTCNT n while !BUSY; n DOUT beats arrive with
//     DOUT_READY strobes (BUSY may stall the REQUEST, not the beats).
//   - one request in flight here: issue, collect exactly n beats,
//     then drain before the next page (the staging BRAM absorbs the
//     SDRAM-side line-flush stalls without stalling a DDR burst).
//
// The output is {offset, byte} like hps_io's download stream, with a dv
// strobe that honours the skid buffer's stall input.

module s32_ddrload #(
    // byte 0x30000000 as a 64-bit-word address
    parameter logic [28:0] DDR_BASE = 29'h06000000
) (
    input  logic        clk,
    input  logic        rst,          // rst_ctrl class (PLL/RESET only)

    // trigger: pulse with the image length in bytes (from the empty
    // download's final ioctl_addr)
    input  logic        start,
    input  logic [26:0] length,
    output logic        busy,
    output logic        done,         // 1-cycle pulse: image drained

    // byte stream into the shell's skid (ioctl-shaped)
    output logic        dv,           // one byte offered this cycle
    output logic [26:0] doffs,        // stream offset (ld_map input)
    output logic [7:0]  dbyte,
    input  logic        stall,        // skid busy / board not ready

    // MiSTer DDRAM port (64-bit)
    input  logic        ddr_busy,
    output logic [7:0]  ddr_burstcnt,
    output logic [28:0] ddr_addr,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready,
    output logic        ddr_rd
);

    // 1 KB page = 128 x 64-bit beats
    logic [63:0] page [0:127];
    logic [6:0]  beat;                // beats received this burst
    logic [26:0] pgbase;              // stream offset of page[0] byte 0
    logic [10:0] drain;               // byte index into the page (0-1023)
    logic [26:0] remain;              // bytes left including this page

    typedef enum logic [1:0] { D_IDLE, D_REQ, D_BEATS, D_DRAIN } dst_e;
    dst_e dst;

    // bytes are little-endian within each 64-bit beat (beat k carries
    // bytes 8k..8k+7)
    wire [63:0] cur_beat = page[drain[9:3]];
    assign dbyte = cur_beat[8 * drain[2:0] +: 8];
    assign doffs = pgbase + {16'd0, drain};
    assign busy  = (dst != D_IDLE);

    // this page's byte count (last page may be short)
    wire [10:0] page_bytes = (remain >= 27'd1024) ? 11'd1024
                                                  : remain[10:0];

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            dst    <= D_IDLE;
            ddr_rd <= 1'b0;
            dv     <= 1'b0;
        end else begin
            unique case (dst)
                D_IDLE: begin
                    dv <= 1'b0;
                    if (start && length != 27'd0) begin
                        pgbase <= 27'd0;
                        remain <= length;
                        dst    <= D_REQ;
                    end
                end

                D_REQ:
                    if (!ddr_busy) begin
                        // whole-page burst even for a short last page;
                        // the extra beats are simply not drained
                        ddr_addr     <= DDR_BASE + {5'd0, pgbase[26:3]};
                        ddr_burstcnt <= 8'd128;
                        ddr_rd       <= 1'b1;
                        beat         <= 7'd0;
                        dst          <= D_BEATS;
                    end

                D_BEATS: begin
                    // hold RD until a not-busy cycle takes it (BUSY is
                    // sampled in the same cycle as RD, so a one-cycle
                    // pulse could land on a busy cycle and be lost)
                    if (!ddr_busy) ddr_rd <= 1'b0;
                    if (ddr_dout_ready) begin
                        page[beat] <= ddr_dout;
                        beat <= beat + 7'd1;
                        if (beat == 7'd127) begin
                            drain <= 11'd0;
                            dst   <= D_DRAIN;
                        end
                    end
                end

                D_DRAIN: begin
                    // offer one byte per cycle; hold while stalled.
                    // dv stays up until the cycle AFTER the skid took
                    // the byte (shell captures on dv && !stall).
                    if (!dv) begin
                        dv <= 1'b1;
                    end else if (!stall) begin
                        if (drain + 11'd1 == page_bytes) begin
                            dv <= 1'b0;
                            if (remain <= 27'd1024) begin
                                done <= 1'b1;
                                dst  <= D_IDLE;
                            end else begin
                                remain <= remain - 27'd1024;
                                pgbase <= pgbase + 27'd1024;
                                dst    <= D_REQ;
                            end
                        end else
                            drain <= drain + 11'd1;
                    end
                end

                default: dst <= D_IDLE;
            endcase
        end
    end

endmodule
