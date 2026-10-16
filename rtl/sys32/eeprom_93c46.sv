// eeprom_93c46.sv — serial EEPROM, 93C46 in 16-bit organization (64 x 16).
//
// System 32 wires it to 315-5296 port D outputs (bit7 = DI, bit6 = SCLK,
// bit5 = CS) with DO read back on port F bit 7 (MAME segas32.cpp hookup;
// schematic sheet 6: BR93C45AP at IC76).
//
// Protocol (93C46 datasheet, 16-bit mode):
//   CS high, then on SCLK rising edges: start bit (DI=1), 2-bit opcode,
//   6-bit address, MSB first.
//     READ  (10): DO outputs a dummy 0, then 16 data bits MSB-first;
//                 continued clocking streams subsequent words.
//     WRITE (01): 16 data bits follow.
//     EWEN  (00, addr[5:4]=11) / EWDS (00, addr[5:4]=00): immediate.
//     ERASE (11): word -> FFFF.
//     ERAL  (00, addr[5:4]=10): whole array -> FFFF.
//     WRAL  (00, addr[5:4]=01): 16 data bits follow; whole array <- data.
//   WRITE/ERASE/ERAL/WRAL are LATCHED when their bits complete and the
//   self-timed programming cycle starts at the CS FALLING edge
//   (datasheet tCSL); while it runs (~2 ms here: 2^17 clk at 64.43 MHz,
//   datasheet tPR typ 2 ms) a re-raised CS reads DO=0 (busy), then
//   DO=1 (ready). Start bits are ignored while busy or while an op
//   is latched awaiting its CS frame — one op per CS frame.
//   Program ops are accepted only under EWEN (ew_en), gated at latch.
//
// Contents load via init_wen / init_addr / init_data (the NVRAM restore
// in S32.sv) — works under reset
// and during busy; the registered dump port serves the NVRAM save path.

module eeprom_93c46 (
    input  logic        clk,        // system clock (oversamples SCLK)
    input  logic        rst,
    input  logic        cs,
    input  logic        sclk,
    input  logic        di,
    output logic        do_out,

    input  logic        init_wen,   // preload port
    input  logic [5:0]  init_addr,
    input  logic [15:0] init_data,

    // registered readback (NVRAM save path; 1-cycle)
    input  logic [5:0]  dump_addr,
    output logic [15:0] dump_data
);

    // Storage. Written through exactly ONE port so it infers as a RAM block.
    // ERAL/WRAL must not write all 64 words in a single cycle: no RAM
    // primitive can, and Quartus would then build the array from 1,024
    // discrete flops plus the decode/mux around them (~1,500 ALMs for 1 Kbit
    // of storage). Every committed op is a SWEEP of 1..64 words, one word per
    // clock, inside the self-timed busy window — see the sw_* engine below.
    // That is also the more faithful model: a real 93C46's erase-all is an
    // internal self-timed cycle, not an instantaneous bulk write.
    //
    // Three properties Golden Axe's boot depends on:
    //   1. power-up content is 0x0000 (an inferred RAM powers up to 0).
    //      Powering up to FF instead does not help the game boot.
    //   2. the array SURVIVES rst — an OSD reset must not wipe it, or boot #2
    //      stops finding valid magic and the game hangs at boot. RAM has no
    //      reset, so this is now structural rather than incidental.
    //   3. init_wen keeps priority and works under reset and during busy (the
    //      NVRAM restore runs while reset is held).
    logic [15:0] mem [0:63];

    // ---- single write port: NVRAM preload, else the program sweep ----------
    logic        sw_run  = 1'b0;   // sweep active
    logic [5:0]  sw_addr, sw_last;
    logic [15:0] sw_data;

    wire         mem_we = init_wen | sw_run;
    wire [5:0]   mem_wa = init_wen ? init_addr : sw_addr;
    wire [15:0]  mem_wd = init_wen ? init_data : sw_data;

    always_ff @(posedge clk)
        if (mem_we) mem[mem_wa] <= mem_wd;

    always_ff @(posedge clk)
        dump_data <= mem[dump_addr];

    typedef enum logic [2:0] {
        E_IDLE, E_CMD, E_READ, E_WRITE, E_WRALD
    } est_e;
    est_e est;

    // program op latched at bit completion, executed at CS drop
    typedef enum logic [2:0] {
        OP_NONE, OP_WRITE, OP_ERASE, OP_ERAL, OP_WRAL
    } op_e;
    op_e op_pend;

    // self-timed programming cycle: 2^17 clk at 64.43 MHz ~= 2.03 ms
    // (BR93C46 tPR typ 2 ms, max 10; the game only polls DO for ready)
    localparam int BUSY_CYCLES = 1 << 17;
    logic [17:0] busy_cnt;
    wire         busy = (busy_cnt != 18'd0);
    logic        stat_frame;     // this CS frame is a READY/BUSY status poll
    logic        busy_q;            // for the ready edge at the end of the block

    logic        sclk_q, cs_q;
    logic [8:0]  cmd;               // start + 2 op + 6 addr as shifted
    logic [3:0]  cmd_cnt;
    logic [5:0]  addr, op_addr;
    logic [15:0] shreg, op_data;
    logic [4:0]  bit_cnt;
    logic        ew_en;

    wire sclk_rise = sclk && !sclk_q;

    // ONE read address for the serial engine, so the array presents a single
    // read port to inference (the dump port is the second). E_READ streams the
    // next word; every other state starts a READ at the just-clocked address.
    wire [5:0] rd_a = (est == E_READ) ? (addr + 6'd1) : {cmd[4:0], di};

    always_ff @(posedge clk) begin
        sclk_q <= sclk;
        cs_q   <= cs;

        // the program sweep runs regardless of CS/reset state: it is the
        // internal self-timed cycle, and 64 of the 131,072 busy clocks are
        // unobservable (DO stays low, commands are ignored while busy)
        if (sw_run) begin
            if (sw_addr == sw_last) sw_run <= 1'b0;
            sw_addr <= sw_addr + 6'd1;
        end

        if (busy) begin
            busy_cnt <= busy_cnt - 18'd1;
            if (cs && !cs_q)
                do_out <= 1'b0;         // busy status on the CS rise itself
            if (busy_cnt == 18'd1 && cs)
                do_out <= 1'b1;         // ready flag once polled
        end
        // A CS rise while a programming cycle is running opens a STATUS frame.
        // A real BR93C46 stays in READY/BUSY status until CS goes low; it does
        // NOT accept a command in that frame.
        if (cs && !cs_q && busy) stat_frame <= 1'b1;

        if (rst) begin
            est <= E_IDLE;
            do_out <= 1'b1;
            ew_en <= 1'b0;
            op_pend <= OP_NONE;
            busy_cnt <= 18'd0;
            stat_frame <= 1'b0;
            // abort an in-flight sweep with the cycle it belongs to: this
            // branch already clears busy_cnt, so leaving sw_run set would
            // write the array while the device reports NOT busy. It also
            // removes any chance of a sweep racing the NVRAM restore, which
            // runs under held reset and shares the write port.
            sw_run <= 1'b0;
        end else if (!cs) begin
            est <= E_IDLE;
            do_out <= 1'b1;
            cmd_cnt <= 4'd0;
            stat_frame <= 1'b0;     // CS low ends the status frame
            // CS falling edge starts the latched self-timed cycle
            if (op_pend != OP_NONE && !busy) begin
                // every op is a sweep: single-word ops sweep one address,
                // ERAL/WRAL sweep the whole array
                unique case (op_pend)
                    OP_WRITE: begin sw_run <= 1'b1; sw_addr <= op_addr;
                                    sw_last <= op_addr;  sw_data <= op_data;  end
                    OP_ERASE: begin sw_run <= 1'b1; sw_addr <= op_addr;
                                    sw_last <= op_addr;  sw_data <= 16'hFFFF; end
                    OP_ERAL:  begin sw_run <= 1'b1; sw_addr <= 6'd0;
                                    sw_last <= 6'd63;    sw_data <= 16'hFFFF; end
                    OP_WRAL:  begin sw_run <= 1'b1; sw_addr <= 6'd0;
                                    sw_last <= 6'd63;    sw_data <= op_data;  end
                    default: ;
                endcase
                op_pend  <= OP_NONE;
                busy_cnt <= 18'(BUSY_CYCLES);
            end
        end else if (sclk_rise) begin
            if (busy) begin
                do_out <= 1'b0;         // busy poll: DO low until ready
            end else if (!stat_frame) begin
                unique case (est)
                    E_IDLE: begin
                        // one op per CS frame: ignore start bits while
                        // an op is latched awaiting its commit frame
                        if (di && op_pend == OP_NONE) begin
                            est <= E_CMD;
                            cmd_cnt <= 4'd0;
                            cmd <= 9'd0;
                        end
                    end
                    E_CMD: begin
                        cmd <= {cmd[7:0], di};
                        cmd_cnt <= cmd_cnt + 4'd1;
                        if (cmd_cnt == 4'd7) begin  // 2 op + 6 addr collected
                            addr <= {cmd[4:0], di};
                            unique case (cmd[6:5])
                                2'b10: begin        // READ
                                    // dummy 0 appears as the address
                                    // completes; data bits then drive DO
                                    // MSB-first on subsequent rising edges
                                    est <= E_READ;
                                    do_out <= 1'b0;
                                    shreg <= mem[rd_a];
                                    bit_cnt <= 5'd0;
                                end
                                2'b01: begin        // WRITE
                                    est <= E_WRITE;
                                    shreg <= 16'd0;
                                    bit_cnt <= 5'd0;
                                end
                                2'b11: begin        // ERASE
                                    if (ew_en) begin
                                        op_pend <= OP_ERASE;
                                        op_addr <= {cmd[4:0], di};
                                    end
                                    est <= E_IDLE;
                                    do_out <= 1'b1;
                                end
                                default:            // 00 family
                                    unique case (cmd[4:3])  // addr[5:4]
                                        2'b11: begin        // EWEN
                                            ew_en <= 1'b1;
                                            est <= E_IDLE;
                                            do_out <= 1'b1;
                                        end
                                        2'b00: begin        // EWDS
                                            ew_en <= 1'b0;
                                            est <= E_IDLE;
                                            do_out <= 1'b1;
                                        end
                                        2'b10: begin        // ERAL
                                            if (ew_en)
                                                op_pend <= OP_ERAL;
                                            est <= E_IDLE;
                                            do_out <= 1'b1;
                                        end
                                        default: begin      // WRAL: data follows
                                            est <= E_WRALD;
                                            shreg <= 16'd0;
                                            bit_cnt <= 5'd0;
                                        end
                                    endcase
                            endcase
                        end
                    end
                    E_READ: begin
                        do_out <= shreg[15];
                        shreg <= {shreg[14:0], 1'b0};
                        bit_cnt <= bit_cnt + 5'd1;
                        if (bit_cnt == 5'd15) begin // word done: stream next
                            addr <= addr + 6'd1;
                            shreg <= mem[rd_a];
                            bit_cnt <= 5'd0;
                        end
                    end
                    E_WRITE, E_WRALD: begin
                        shreg <= {shreg[14:0], di};
                        bit_cnt <= bit_cnt + 5'd1;
                        if (bit_cnt == 5'd15) begin
                            // latch only; the cycle starts at CS drop
                            if (ew_en) begin
                                op_pend <= (est == E_WRITE) ? OP_WRITE
                                                            : OP_WRAL;
                                op_addr <= addr;
                                op_data <= {shreg[14:0], di};
                            end
                            est <= E_IDLE;
                            do_out <= 1'b1;
                        end
                    end
                    default: est <= E_IDLE;
                endcase
            end
        end

        // ---- READY on the end of the self-timed programming cycle.
        //
        // A real BR93C46 drives DO high when the programming cycle ends and
        // keeps it high while selected; Golden Axe polls DO with CS held
        // high. The one-cycle `busy_cnt == 1 && cs` pulse above is not
        // enough on its own: a poll on that same cycle overrides it, and
        // nothing restores it afterwards, so the game would hang at boot.
        // Setting DO on the falling edge of busy needs no CS or SCLK
        // alignment, and it comes last so nothing overrides it. It cannot
        // disturb a read: no command can be issued while busy.
        busy_q <= busy;
        if (busy_q && !busy)
            do_out <= 1'b1;
    end

endmodule
