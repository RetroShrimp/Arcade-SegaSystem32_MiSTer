// s32_pcm.sv — RF5C68/RF5C105 PCM (8 channels, 64KB wave RAM).
//
// References: MAME rf5c68.cpp (register map, sample loop). The board
// carries an RF5C105, modelled as an RF5C68 (no differences are
// documented).
//
// CPU window (Z80 C000-DFFF via s32_sound's pcm port, 13-bit offset):
//   A12 = 0: registers (write-only; reads return FF)
//     0 env, 1 pan (L lo / R hi), 2/3 FD lo/hi (address step, added to
//     the 27-bit channel address whose sample index is addr >> 11),
//     4/5 LS lo/hi (loop start sample address), 6 ST (start page:
//     addr = ST << 19), 7 control (bit7 = master enable; bit6 = 1 ->
//     channel bank = data & 7, else wave bank = (data & 0xF) << 12),
//     8 channel on/off (inverted; disabling reloads addr from start)
//   A12 = 1: 4KB wave-RAM page at the wave bank
//
// Samples are sign-magnitude bytes (bit 7 = positive); 0xFF is the
// loop marker (jump to loopst << 11; a second 0xFF kills the channel
// for the batch). Per tick each channel adds (sample * pan_nibble *
// env) >> 5 into a signed accumulator; RF5C68 output is 10 bits
// (low 6 bits masked) with +/-32768 clamp.
//
// Sample tick = clock / 384 (12.5 MHz -> ~32.55 kHz), generated here
// from cen_pcm (12.5 MHz enable). The 8 channels are processed
// sequentially after each tick (wave reads are 1-cycle synchronous).

module s32_pcm (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_pcm,      // 12.5 MHz enable

    // CPU window
    input  logic        sel,
    input  logic        we,
    input  logic [12:0] addr,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,

    // audio out (signed, updated once per sample tick)
    output logic signed [15:0] out_l,
    output logic signed [15:0] out_r
);

    // ------------------------------------------------------- registers
    logic        enable;
    logic [2:0]  cbank;
    logic [15:0] wbank;               // wave window base (A12 pages)
    logic [7:0]  ch_env  [0:7];
    logic [7:0]  ch_pan  [0:7];
    logic [15:0] ch_fd   [0:7];
    logic [15:0] ch_ls   [0:7];
    logic [7:0]  ch_st   [0:7];
    logic        ch_en   [0:7];
    logic [26:0] ch_addr [0:7];

    // -------------------------------------------------------- wave RAM
    // s32_tdp: port A = CPU read/write, port B = channel engine read (the
    // `wbank | {...}` address expression stops Quartus 17 inferring it)
    logic [7:0]  wave_q_cpu, wave_q_ch;
    logic [15:0] wave_raddr_ch;

    // OREGB=1 registers port B's q in the M10K's own output register. This
    // is the deepest s32_tdp in the design (AW=16, 64K, 4x the palette), and
    // port B's address jumps far on every channel step (P_LOOPS reloads
    // mix_addr from ch_addr[mix_ch+1]), so an unregistered read through the
    // multi-block output mux is a core-clock critical path; registering it
    // takes the ~5.6 ns RAM side off that path. Cost: read latency 1 -> 2
    // clk, absorbed by wq_wait in the FSM. The tick budget is ~1979 clk for
    // 8 channels at ~4 clk each.
    localparam int WAVE_RDW_OLD_P = 0;
    wire [7:0] wave_q_cpu_s, wave_q_ch_s;
    wire [7:0] wave_din = wdata;
    assign wave_q_cpu = wave_q_cpu_s;
    assign wave_q_ch  = wave_q_ch_s;
    s32_tdp #(.AW(16), .DW(8), .OREGB(1), .RDW_FWD(1),
              .RDW_OLD(WAVE_RDW_OLD_P)) u_wave (
        .clk(clk),
        .we_a(sel && we && addr[12]),
        .addr_a(wbank | {4'd0, addr[11:0]}),
        .d_a(wave_din), .q_a(wave_q_cpu_s),
        .we_b(1'b0), .addr_b(wave_raddr_ch),
        .d_b(8'd0), .q_b(wave_q_ch_s)
    );

    assign rdata = addr[12] ? wave_q_cpu : 8'hFF;

    // sample-engine state (declared before the CPU-writes block that
    // handles the mix_wb channel-address writeback — iverilog requires
    // declaration before use)
    typedef enum logic [2:0] {
        P_IDLE, P_FETCH, P_SAMPLE, P_LOOPRD, P_LOOPS, P_DONE
    } pstate_e;
    pstate_e pst;

    logic [2:0]  mix_ch;
    logic        mix_wb;
    // wave read settle window: set whenever mix_addr moves to a new fetch
    // address and cleared one clk later, so the engine uses wave_q_ch from
    // the registered (2-clk) read. A CPU wave write inside the window
    // re-arms it (see the collision guard below).
    logic        wq_wait;
    logic [26:0] mix_addr, mix_addr_next;
    logic signed [21:0] acc_l, acc_r;

    // ------------------------------------------------------ CPU writes
    always_ff @(posedge clk) begin
        if (rst) begin
            enable <= 1'b0;
            cbank <= 3'd0;
            wbank <= 16'd0;
            for (int i = 0; i < 8; i++) begin
                ch_en[i] <= 1'b0;
                ch_env[i] <= 8'd0;
                ch_pan[i] <= 8'd0;
                ch_fd[i] <= 16'd0;
                ch_ls[i] <= 16'd0;
                ch_st[i] <= 8'd0;
                ch_addr[i] <= 27'd0;
            end
        end else begin
        if (sel && we && !addr[12]) begin
            unique case (addr[3:0])
                4'h0: ch_env[cbank] <= wdata;
                4'h1: ch_pan[cbank] <= wdata;
                4'h2: ch_fd[cbank][7:0] <= wdata;
                4'h3: ch_fd[cbank][15:8] <= wdata;
                4'h4: ch_ls[cbank][7:0] <= wdata;
                4'h5: ch_ls[cbank][15:8] <= wdata;
                4'h6: begin
                    ch_st[cbank] <= wdata;
                    if (!ch_en[cbank])
                        ch_addr[cbank] <= {wdata, 19'd0};
                end
                4'h7: begin
                    enable <= wdata[7];
                    if (wdata[6])
                        cbank <= wdata[2:0];
                    else
                        wbank <= {wdata[3:0], 12'd0};
                end
                4'h8: begin
                    for (int i = 0; i < 8; i++) begin
                        ch_en[i] <= ~wdata[i];
                        if (wdata[i])
                            ch_addr[i] <= {ch_st[i], 19'd0};
                    end
                end
                default: ;
            endcase
        end
        // sample engine address writeback: never dropped for an
        // unrelated CPU register write (that would repeat a sample).
        // Defers only on a true same-channel
        // conflict: the CPU setting this channel's start address
        // (reg 6 while disabled) or restarting it via key-on (reg 8
        // with this channel's bit) — there the CPU wins, matching the
        // real part's restart semantics.
        if (mix_wb && !(sel && we && !addr[12] &&
                ((addr[3:0] == 4'h6 && cbank == mix_ch
                  && !ch_en[cbank]) ||
                 (addr[3:0] == 4'h8 && wdata[mix_ch]))))
            ch_addr[mix_ch] <= mix_addr_next;
        end
    end

    // ---------------------------------------------------- sample engine
    // tick divider: cen_pcm / 384
    logic [8:0] divq;
    logic       tick;
    always_ff @(posedge clk) begin
        tick <= 1'b0;
        if (rst)
            divq <= 9'd0;
        else if (cen_pcm) begin
            if (divq == 9'd383) begin
                divq <= 9'd0;
                tick <= 1'b1;
            end else
                divq <= divq + 9'd1;
        end
    end

    always_comb wave_raddr_ch = mix_addr[26:11];

    // Wave RAM collision guard: the CPU writes sample bytes into the RAM
    // the engine reads from (a sound effect loading during play), and a
    // read of the address being written in the same cycle returns
    // undefined data on the FPGA (simulation returns the old data). Any
    // CPU wave write holds the engine's read one cycle, so the read is
    // repeated after the write (the new byte is used at once, as in MAME).
    // Z80 writes never come on consecutive clks, and a tick (384 cen_pcm)
    // is far longer than the hold.
    logic wave_cpu_wr;
    assign wave_cpu_wr = sel && we && addr[12];

    // registered, to keep mix_ch -> pan/env muxes -> multiply ->
    // accumulate off the critical path. The FSM sets
    // mix_ch at least two edges before P_SAMPLE consumes lv/rv, so a
    // free-running register stage is settled by consumption.
    logic [11:0] lv, rv;
    always_ff @(posedge clk) begin
        lv <= {4'd0, ch_pan[mix_ch][3:0]} * {4'd0, ch_env[mix_ch]};
        rv <= {4'd0, ch_pan[mix_ch][7:4]} * {4'd0, ch_env[mix_ch]};
    end

    // (sample * v) >> 5, sign-magnitude sample (bit 7 set = positive)
    function automatic logic signed [21:0] contrib
        (input logic [7:0] s, input logic [11:0] v);
        logic [18:0] mag;
        mag = ({12'd0, s[6:0]} * {7'd0, v}) >> 5;
        contrib = s[7] ? {3'd0, mag} : -{3'd0, mag};
    endfunction

    always_ff @(posedge clk) begin
        mix_wb <= 1'b0;
        if (rst) begin
            pst <= P_IDLE;
            smp_cur_l <= 16'd0;  smp_cur_r <= 16'd0;
            wq_wait <= 1'b0;
        end else begin
            unique case (pst)
                P_IDLE: if (tick) begin
                    if (enable) begin
                        mix_ch <= 3'd0;
                        acc_l <= 22'd0;
                        acc_r <= 22'd0;
                        mix_addr <= ch_addr[0];
                        wq_wait <= 1'b1;
                        pst <= P_FETCH;
                    end else begin
                        // MAME: disabled chip streams silence
                        smp_cur_l <= 16'd0;  smp_cur_r <= 16'd0;
                    end
                end

                P_FETCH: begin              // wave read in flight
                    // Only the first window cycle feeds the byte used here
                    // (q_b latches that read two edges later), so a CPU
                    // write matters only now: stay in the window on a
                    // collision, otherwise advance. A wider guard would let
                    // extra writes shift the engine's timing.
                    if (wq_wait)
                        wq_wait <= wave_cpu_wr;
                    else if (ch_en[mix_ch])
                        pst <= P_SAMPLE;
                    else begin
                        // skip disabled channel
                        if (mix_ch == 3'd7) pst <= P_DONE;
                        else begin
                            mix_ch <= mix_ch + 3'd1;
                            mix_addr <= ch_addr[mix_ch + 3'd1];
                            wq_wait <= 1'b1;
                        end
                    end
                end

                P_SAMPLE: begin
                    if (wave_q_ch == 8'hFF) begin
                        // loop marker: jump and refetch
                        mix_addr <= {ch_ls[mix_ch], 11'd0};
                        wq_wait <= 1'b1;
                        pst <= P_LOOPRD;
                    end else begin
                        acc_l <= acc_l + contrib(wave_q_ch, lv);
                        acc_r <= acc_r + contrib(wave_q_ch, rv);
                        mix_addr_next <= mix_addr + {11'd0, ch_fd[mix_ch]};
                        mix_wb <= 1'b1;
                        pst <= P_LOOPS;     // reuse as channel-advance
                    end
                end

                P_LOOPRD: begin             // looped read in flight
                    if (wq_wait)            // same narrow guard as P_FETCH
                        wq_wait <= wave_cpu_wr;
                    else
                        pst <= P_LOOPS;
                end
                P_LOOPS: begin
                    if (mix_wb) begin
                        // normal advance path: next channel
                        if (mix_ch == 3'd7) pst <= P_DONE;
                        else begin
                            mix_ch <= mix_ch + 3'd1;
                            mix_addr <= ch_addr[mix_ch + 3'd1];
                            wq_wait <= 1'b1;
                            pst <= P_FETCH;
                        end
                    end else begin
                        // post-loop sample arrived
                        if (wave_q_ch == 8'hFF) begin
                            // loop-to-loop: channel dead this tick
                            mix_wb <= 1'b1;
                            mix_addr_next <= mix_addr;
                        end else begin
                            acc_l <= acc_l + contrib(wave_q_ch, lv);
                            acc_r <= acc_r + contrib(wave_q_ch, rv);
                            mix_addr_next <= mix_addr
                                           + {11'd0, ch_fd[mix_ch]};
                            mix_wb <= 1'b1;
                        end
                    end
                end

                P_DONE: begin
                    // RF5C68: 10-bit output (mask low 6 bits), clamp
                    smp_cur_l <= clamp10(acc_l);
                    smp_cur_r <= clamp10(acc_r);
                    pst <= P_IDLE;
                end

                default: pst <= P_IDLE;
            endcase
        end
    end

    // ======================================================== output
    // The engine produces one sample per tick (32.552 kHz) and holds it
    // until the next tick, as the RF5C68 presents it. The board's LC7881 DAC
    // and op-amp filter (schematic sheets 8 and 9) are not modelled.
    logic signed [15:0] smp_cur_l, smp_cur_r;
    always_comb begin
        out_l = smp_cur_l;
        out_r = smp_cur_r;
    end

    // MAME order: mask low 6 bits of the full-precision mix FIRST,
    // then clamp (an over-range mix therefore lands on 32767, not on
    // a 64-aligned value)
    function automatic logic signed [15:0] clamp10
        (input logic signed [21:0] v);
        logic signed [21:0] m;
        m = v & ~22'sd63;
        if (m > 22'sd32767)       clamp10 = 16'sd32767;
        else if (m < -22'sd32768) clamp10 = 16'sh8000;   // -32768
        else                      clamp10 = m[15:0];
    endfunction

endmodule
