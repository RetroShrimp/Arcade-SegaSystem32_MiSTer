// s32_dspbd.sv — Air Rescue's 837-8341 DSP board as the V60 sees it at
// $A00000-$A00007: a uPD77P25 (s32_dsp7725) running its dumped program
// (d7725.01), with four 16-bit latches between it and the V60.
//
// References:
//   MAME latest master a40c1f06196: segas32.cpp segas32_upd7725_state (the
//     uPD7725 at 16 MHz / 2 "on the 837-8341 daughterboard which plugs into
//     the socket on the main pcb's ROM board where an fd1149 could go", left
//     disabled: "TODO: figure out how the p0 and p1 lines from the upd7725
//     affect the mainboard ... TODO: trace out the 837-8341 pcb");
//     segas32_m.cpp arescue_dsp_r/_w, MAME's stand-in for the board, and its
//     comment: "a00000 - a00002 dsp i/o, a00004 - dsp int/ack; dsp uses its
//     p0/p1 for address select: sr = ???0 read a00000 into dsp.a, ???1 read
//     a00002 into dsp.b, ???2 write dsp.b in a00000, ???3 write dsp.a in
//     a00002".
//   d7725.01 (tools/upd7725_model.py; docs/arescue-bringup.md §3): 188
//     instruction words. At reset it posts $0000 then $1234 with P1P0 = 3
//     and enables interrupts. Its interrupt handler ($100) fetches the
//     parameter (P1P0 = 1, into B) and the command (P1P0 = 0, into A) with
//     DMA requests, runs one of seven commands, and returns two words with
//     P1P0 = 2 (B) and then 3 (A).
//   Air Rescue V60 program (epr-14542/14541): every exchange writes $A00002
//     (parameter) BEFORE $A00000 (command), and then polls $A00004 bit 0
//     until it reads 0 (060A6C-060B44, 060321-060739).
//
// The board logic below is this project's reading of those two programs; the
// board itself is untraced (Q64):
//   - a V60 write to $A00000 latches the command, raises the DSP's INT for
//     one DSP clock and sets BUSY; $A00002 latches the parameter
//   - reads: $A00000 / $A00002 return the DSP's two output latches,
//     $A00004 / $A00006 return BUSY in bit 0 and 0 above it
//   - the DSP's DMA request moves one DR byte per transfer, low byte first
//     (DRC = 0: 16-bit DR), BYTE_CLKS DSP clocks after it is first seen; P1
//     picks the direction (0: latch P0 -> DR, 1: DR -> output latch P0) and
//     P0 the latch
//   - BUSY clears when a P1P0 = 3 transfer completes, the last thing every
//     command and the reset path do; it is set at reset. The reset path
//     posts twice ($0000, then $1234 after ~750 DSP clocks of RAM clear
//     with interrupts off), so a command written between the two is
//     dropped: the boot's command 1 after its command 0, whose effect
//     (DP = 0) the reset already leaves (Q64)
// With this logic the dumped program returns 4 x the parameter for command 6,
// which is MAME's stand-in result and what the V60 needs: it indexes its state
// jump table with the answer (060B3D, 06026E). Command 3's answer differs from
// MAME's guessed $8000/$0001; the V60 reads it at boot and never uses it.
//
// The DSP clock is 16 MHz / 2 (MAME), from clk by a fractional accumulator:
// 80000 / 644318 = 8.000 MHz / 64.4318 MHz.
//
// Bench: sim/s32_dsp7725 (this board and the core, against
// tools/upd7725_model.py).

module s32_dspbd #(
    parameter int BYTE_CLKS = 2,
    // DSP clock = clk x CEN_INC / CEN_MOD (8.000 MHz from 64.4318 MHz; the
    // bench slows it to leave room for its V60 writes between DSP clocks)
    parameter int CEN_INC = 80000,
    parameter int CEN_MOD = 644318
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        ld_we,
    input  logic [13:0] ld_addr,
    input  logic [7:0]  ld_data,

    // V60 side: one word port, a[2:1] = woff, byte lanes for a byte write
    input  logic        sel,
    input  logic        we,
    input  logic [1:0]  woff,
    input  logic [1:0]  bsel,
    input  logic [15:0] wdata,
    output logic [15:0] rdata
);

    // ------------------------------------------------------- DSP clock
    logic [19:0] acc;
    logic        cen;
    always_ff @(posedge clk) begin
        if (rst) begin
            acc <= '0;
            cen <= 1'b0;
        end else if (acc + 20'(CEN_INC) >= 20'(CEN_MOD)) begin
            acc <= acc + 20'(CEN_INC) - 20'(CEN_MOD);
            cen <= 1'b1;
        end else begin
            acc <= acc + 20'(CEN_INC);
            cen <= 1'b0;
        end
    end

    // ------------------------------------------------------- latches
    logic [15:0] lat [0:3];               // 0/1 V60 -> DSP, 2/3 DSP -> V60
    logic        busy;
    logic        int_req;
    logic [2:0]  xfer;
    logic        dsp_p0, dsp_p1, dsp_drq;
    logic        host_rd, host_wr;
    logic [7:0]  host_wdata, host_rdata;
    logic        dsp_drs;                 // SR.DRS: the next byte is the high one

    initial for (int i = 0; i < 4; i++) lat[i] = 16'h0000;

    assign rdata = (woff == 2'd0) ? lat[2]
                 : (woff == 2'd1) ? lat[3] : {15'd0, busy};

    // the transfer this DSP clock: the counter reaches 0 with DRQ still up
    wire xfer_now = cen && dsp_drq && xfer == 3'd1;
    assign host_wr = xfer_now && !dsp_p1;
    assign host_rd = xfer_now &&  dsp_p1;
    wire [15:0] src_w = lat[{1'b0, dsp_p0}];
    assign host_wdata = dsp_drs ? src_w[15:8] : src_w[7:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            busy    <= 1'b1;
            int_req <= 1'b0;
            xfer    <= 3'd0;
        end else begin
            // DSP side, one DSP clock at a time
            if (cen) begin
                int_req <= 1'b0;
                if (dsp_drq) begin
                    if (xfer == 3'd0)
                        xfer <= 3'(BYTE_CLKS);
                    else if (xfer == 3'd1) begin
                        // this edge's transfer; RQM stays up after a low byte
                        xfer <= dsp_drs ? 3'd0 : 3'(BYTE_CLKS);
                        if (dsp_p1) begin
                            if (!dsp_drs)
                                lat[{1'b1, dsp_p0}][7:0]  <= host_rdata;
                            else begin
                                lat[{1'b1, dsp_p0}][15:8] <= host_rdata;
                                if (dsp_p0) busy <= 1'b0;
                            end
                        end
                    end else
                        xfer <= xfer - 3'd1;
                end else
                    xfer <= 3'd0;
            end
            // V60 side, last: a command written on the edge of the last
            // transfer still sets BUSY and raises INT
            if (sel && we) begin
                if (woff == 2'd0 || woff == 2'd1) begin
                    if (bsel[0]) lat[woff][7:0]  <= wdata[7:0];
                    if (bsel[1]) lat[woff][15:8] <= wdata[15:8];
                end
                if (woff == 2'd0) begin
                    busy    <= 1'b1;
                    int_req <= 1'b1;
                end
            end
        end
    end

    s32_dsp7725 u_dsp (
        .clk(clk), .rst(rst), .cen(cen),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data),
        .int_in(int_req), .p0(dsp_p0), .p1(dsp_p1), .drq(dsp_drq),
        .drs(dsp_drs),
        .host_rd(host_rd), .host_wr(host_wr),
        .host_wdata(host_wdata), .host_rdata(host_rdata)
    );

endmodule
