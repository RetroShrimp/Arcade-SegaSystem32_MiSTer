// s32_v25.sv — NEC V25 subset core for Golden Axe's 315-5533-02
// protection module. Executes the original mcu.bin: the ROM address-line
// scramble is undone combinationally on the fetch address and the
// per-instruction opcode encryption through a 256-entry LUT, exactly
// as the real module does (MAME decrypt_protrom + ga2_opcode_table).
// The implemented subset is exactly the 28 opcodes the decryption table
// defines: an encrypted byte outside the table cannot be executed by this
// module at all.
//
// Bus model: one byte access per two clocks (issue/latch), no cycle
// accuracy (the program runs once at boot and halts; the V60 only
// ever sees the finished dpram). Memory decode:
//   linear 0xxxx / F0000-FFDFF  ROM (swizzled, via the rom port)
//   1xxxx                       dpram left port (offset & 0x7FF)
//   FFE00-FFFFF                 512B internal RAM (SFR writes land
//                               here; no side effects needed)

module s32_v25 (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,          // the FSM steps only on cen (10 MHz
                                      // from s32_sys, the real V25's
                                      // clock; each state is about one bus
                                      // byte, so this is an upper bound on
                                      // its speed)
    input  logic        hold,         // freeze (ROM line refill in flight)

    // original-dump ROM (64KB; combinational or 1-cycle registered)
    output logic [15:0] rom_addr,
    input  logic [7:0]  rom_data,
    output logic        rom_rd,       // current bus access targets ROM

    // dpram left port
    output logic        dp_sel,
    output logic        dp_we,
    output logic [10:0] dp_addr,
    output logic [7:0]  dp_wdata,
    input  logic [7:0]  dp_rdata
);

    // ---------------------------------------------- opcode decryption
    // ga2_opcode_table (segas32_m.cpp); FF = never appears at an
    // instruction boundary
    function automatic logic [7:0] decrypt (input logic [7:0] e);
        case (e)
            8'h02: decrypt = 8'hEA;  8'h05: decrypt = 8'h8B;
            8'h1F: decrypt = 8'hFA;  8'h2A: decrypt = 8'h3B;
            8'h2C: decrypt = 8'h49;  8'h35: decrypt = 8'hE8;
            8'h38: decrypt = 8'h75;  8'h3D: decrypt = 8'h3A;
            8'h44: decrypt = 8'h8D;  8'h4C: decrypt = 8'hBF;
            8'h4E: decrypt = 8'h88;  8'h53: decrypt = 8'h81;
            8'h70: decrypt = 8'h02;  8'h7F: decrypt = 8'hBC;
            8'h83: decrypt = 8'h8A;  8'h8A: decrypt = 8'h83;
            8'h9D: decrypt = 8'hB8;  8'h9E: decrypt = 8'h26;
            8'hAD: decrypt = 8'hB5;  8'hAF: decrypt = 8'hEB;
            8'hBB: decrypt = 8'hB2;  8'hC3: decrypt = 8'hC3;
            8'hD8: decrypt = 8'hB9;  8'hD9: decrypt = 8'hBB;
            8'hDB: decrypt = 8'h43;  8'hF2: decrypt = 8'h8E;
            8'hFB: decrypt = 8'hBE;  8'hFD: decrypt = 8'h80;
            default: decrypt = 8'hFF;
        endcase
    endfunction

    // ROM address-line descramble (MAME decrypt_protrom bitswap<16>)
    function automatic logic [15:0] swizzle (input logic [15:0] i);
        swizzle = {i[14], i[11], i[15], i[12], i[13], i[4], i[3],
                   i[7],  i[5],  i[10], i[2],  i[8],  i[9], i[6],
                   i[1],  i[0]};
    endfunction

    // ------------------------------------------------- architectural
    logic [15:0] reg16 [0:7];    // AW CW DW BW SP BP IX(SI) IY(DI)
    logic [15:0] sreg  [0:3];    // ES CS SS DS (8086 sreg encoding)
    logic [15:0] ip;
    logic        fl_z, fl_s, fl_c;

    localparam AX = 3'd0, CX = 3'd1, DX = 3'd2, BX = 3'd3,
               SP = 3'd4, BP = 3'd5, SI = 3'd6, DI = 3'd7;
    localparam SEG_ES = 2'd0, SEG_CS = 2'd1, SEG_SS = 2'd2,
               SEG_DS = 2'd3;

    logic [7:0] iram [0:511];    // internal RAM/SFR page FFE00-FFFFF

    // ------------------------------------------------------ bus mux
    // one shared byte port: issue in one state, latch the next
    logic [19:0] bus_addr;
    logic        bus_we;
    logic [7:0]  bus_wdata;
    logic [7:0]  bus_q;          // latched read data

    assign rom_addr = swizzle(bus_addr[15:0]);
    assign dp_sel   = (bus_addr[19:16] == 4'h1);
    assign dp_addr  = bus_addr[10:0];
    assign dp_wdata = bus_wdata;

    // the V25 internal RAM/SFR page overlays the top of memory for
    // DATA accesses only — instruction fetches always go external
    // (the reset vector at FFFF0 is fetched from ROM)
    logic is_fetch;
    logic in_iram, in_rom;
    assign in_iram = (bus_addr >= 20'hFFE00) && !is_fetch;
    assign in_rom  = (bus_addr[19:16] == 4'h0) ||
                     (bus_addr[19:16] == 4'hF && !in_iram);
    assign rom_rd = in_rom;

    logic [7:0] iram_q;
    logic       dp_we_r;
    assign dp_we = dp_we_r;

    // ------------------------------------------------- decode state
    logic        es_ovr;
    logic [7:0]  opc;
    logic [7:0]  mrm;
    logic [15:0] disp, imm;
    logic [15:0] ea_off;
    logic [1:0]  ea_seg;
    logic [15:0] rmval;          // memory/register operand value
    logic [15:0] wr_val;         // value being stored (memory path)
    logic [19:0] wr_lin;         // linear address for stores

    wire [1:0] mrm_mod = mrm[7:6];
    wire [2:0] mrm_reg = mrm[5:3];
    wire [2:0] mrm_rm  = mrm[2:0];

    // 8-bit register file view (8086: 0-3 = low bytes, 4-7 = high)
    function automatic logic [7:0] r8_get (input logic [2:0] n);
        r8_get = n[2] ? reg16[{1'b0, n[1:0]}][15:8]
                      : reg16[{1'b0, n[1:0]}][7:0];
    endfunction

    task automatic r8_set (input logic [2:0] n, input logic [7:0] v);
        if (n[2]) reg16[{1'b0, n[1:0]}][15:8] <= v;
        else      reg16[{1'b0, n[1:0]}][7:0]  <= v;
    endtask

    // modrm EA offset from current regs + disp
    function automatic logic [15:0] ea_base (input logic [2:0] rm);
        case (rm)
            3'd0: ea_base = reg16[BX] + reg16[SI];
            3'd1: ea_base = reg16[BX] + reg16[DI];
            3'd2: ea_base = reg16[BP] + reg16[SI];
            3'd3: ea_base = reg16[BP] + reg16[DI];
            3'd4: ea_base = reg16[SI];
            3'd5: ea_base = reg16[DI];
            3'd6: ea_base = reg16[BP];
            3'd7: ea_base = reg16[BX];
        endcase
    endfunction

    function automatic logic [1:0] ea_defseg (input logic [1:0] mod,
                                              input logic [2:0] rm);
        // BP-based forms default to SS ([disp16] mod=00 rm=6 is DS)
        if (rm == 3'd2 || rm == 3'd3 || (rm == 3'd6 && mod != 2'd0))
            ea_defseg = SEG_SS;
        else
            ea_defseg = SEG_DS;
    endfunction

    // immediate-group ALU (80/81/83 reg field, and the cmp/add ops)
    function automatic logic [17:0] grp_alu   // {c, z_ignore, res16}
        (input logic [2:0] sel, input logic [15:0] a,
         input logic [15:0] b, input logic wide);
        logic [16:0] r;
        case (sel)
            3'd0: r = {1'b0, a} + {1'b0, b};              // add
            3'd1: r = {1'b0, a | b};                       // or
            3'd2: r = {1'b0, a} + {1'b0, b} + {16'd0, fl_c}; // adc
            3'd3: r = {1'b0, a} - {1'b0, b} - {16'd0, fl_c}; // sbb
            3'd4: r = {1'b0, a & b};                       // and
            3'd5: r = {1'b0, a} - {1'b0, b};               // sub
            3'd6: r = {1'b0, a ^ b};                       // xor
            3'd7: r = {1'b0, a} - {1'b0, b};               // cmp
        endcase
        if (!wide)
            grp_alu = {r[8], 1'b0, 8'd0, r[7:0]};
        else
            grp_alu = {r[16], 1'b0, r[15:0]};
    endfunction

    task automatic set_zs (input logic [15:0] v, input logic wide);
        fl_z <= wide ? (v == 16'd0) : (v[7:0] == 8'd0);
        fl_s <= wide ? v[15] : v[7];
    endtask

    // --------------------------------------------------------- FSM
    typedef enum logic [4:0] {
        S_OP, S_OP_L, S_MOD, S_MOD_L, S_D1, S_D1_L, S_D2, S_D2_L,
        S_I1, S_I1_L, S_I2, S_I2_L, S_I3, S_I3_L, S_I4, S_I4_L,
        S_RD0, S_RD0_L, S_RD1, S_RD1_L, S_EXEC,
        S_WR0, S_WR1, S_PUSH0, S_PUSH1, S_POP0, S_POP0_L,
        S_POP1, S_POP1_L, S_HALT
    } state_e;
    state_e st;

    // instruction classification (on the DECRYPTED opcode)
    function automatic logic has_modrm (input logic [7:0] o);
        has_modrm = (o == 8'h8B) || (o == 8'h8A) || (o == 8'h88) ||
                    (o == 8'h8D) || (o == 8'h8E) || (o == 8'h3B) ||
                    (o == 8'h3A) || (o == 8'h02) || (o == 8'h80) ||
                    (o == 8'h81) || (o == 8'h83);
    endfunction

    function automatic logic op_wide (input logic [7:0] o);
        op_wide = (o == 8'h8B) || (o == 8'h8D) || (o == 8'h8E) ||
                  (o == 8'h3B) || (o == 8'h81) || (o == 8'h83);
    endfunction

    // memory operand needed (loads; 88 is a pure store, 8D pure EA)
    function automatic logic op_loads (input logic [7:0] o);
        op_loads = (o == 8'h8B) || (o == 8'h8A) || (o == 8'h8E) ||
                   (o == 8'h3B) || (o == 8'h3A) || (o == 8'h02) ||
                   (o == 8'h80) || (o == 8'h81) || (o == 8'h83);
    endfunction

    logic [15:0] nip;            // IP after current fetch byte
    logic [19:0] lin_ea;
    assign lin_ea = ({4'd0, sreg[ea_seg]} << 4) + {4'd0, ea_off};

    logic [17:0] gr;
    logic [15:0] pushv;

    // registered memories deliver data one cycle after the address:
    // every latch state waits one extra cycle before sampling
    logic waitq;
    function automatic logic is_latch (input state_e s);
        is_latch = (s == S_OP_L) || (s == S_MOD_L) || (s == S_D1_L) ||
                   (s == S_D2_L) || (s == S_I1_L) || (s == S_I2_L) ||
                   (s == S_I3_L) || (s == S_I4_L) || (s == S_RD0_L) ||
                   (s == S_RD1_L) || (s == S_POP0_L) ||
                   (s == S_POP1_L);
    endfunction

    always_ff @(posedge clk) begin
        // default bus: instruction fetch address
        bus_we   <= 1'b0;
        dp_we_r  <= 1'b0;
        iram_q   <= iram[bus_addr[8:0]];
        if (in_iram && bus_we)
            iram[bus_addr[8:0]] <= bus_wdata;

        if (rst) begin
            st <= S_OP;
            ip <= 16'hFFF0;                 // V25 reset: CS:IP = F000:FFF0
            sreg[SEG_CS] <= 16'hF000;       // reset fetch at FFFF0
            sreg[SEG_ES] <= 16'd0;
            sreg[SEG_SS] <= 16'd0;
            sreg[SEG_DS] <= 16'd0;
            es_ovr <= 1'b0;
            fl_z <= 1'b0; fl_s <= 1'b0; fl_c <= 1'b0;
            bus_addr <= 20'hFFFF0;
            is_fetch <= 1'b1;
            waitq <= 1'b0;
        end else if (hold) begin
            // ROM line refill in flight: FSM frozen (bus_addr, st,
            // waitq all keep state; the idempotent iram/dpram strobe
            // repeats above are harmless)
        end else if (!cen) begin
            // between cen ticks: frozen, as for hold. Read data is
            // stable long before the next tick, so the one-cycle
            // is_latch wait is correct at any cen rate.
        end else if (is_latch(st) && !waitq) begin
            waitq <= 1'b1;       // memory data lands this cycle
        end else begin
            waitq <= 1'b0;
            unique case (st)
                // ------------------------------------ opcode fetch
                S_OP: begin
                    bus_addr <= ({4'd0, sreg[SEG_CS]} << 4)
                              + {4'd0, ip};
                    is_fetch <= 1'b1;
                    st <= S_OP_L;
                end
                S_OP_L: begin
                    logic [7:0] o;
                    o = decrypt(in_rom ? rom_data :
                                dp_sel ? dp_rdata : iram_q);
                    ip <= ip + 16'd1;
                    if (o == 8'h26) begin
                        es_ovr <= 1'b1;
                        st <= S_OP;
                    end else if (o == 8'hFF) begin
                        st <= S_HALT;
                    end else begin
                        opc <= o;
                        disp <= 16'd0;
                        if (has_modrm(o))              st <= S_MOD;
                        else if (o[7:3] == 5'b10111)   st <= S_I1; // mov r16,imm
                        else if (o[7:3] == 5'b10110)   st <= S_I1; // mov r8,imm
                        else if (o == 8'hE8)           st <= S_I1;
                        else if (o == 8'hEB || o == 8'h75) st <= S_I1;
                        else if (o == 8'hEA)           st <= S_I1;
                        else                           st <= S_EXEC;
                    end
                end

                // ------------------------------------------ modrm
                S_MOD: begin
                    bus_addr <= ({4'd0, sreg[SEG_CS]} << 4)
                              + {4'd0, ip};
                    is_fetch <= 1'b1;
                    st <= S_MOD_L;
                end
                S_MOD_L: begin
                    logic [7:0] m;
                    m = in_rom ? rom_data : dp_sel ? dp_rdata : iram_q;
                    mrm <= m;
                    ip <= ip + 16'd1;
                    if (m[7:6] == 2'b00 && m[2:0] == 3'd6)
                        st <= S_D1;                    // disp16 direct
                    else if (m[7:6] == 2'b01)
                        st <= S_D1;                    // disp8
                    else if (m[7:6] == 2'b10)
                        st <= S_D1;                    // disp16
                    else begin
                        // no displacement
                        ea_off <= ea_base(m[2:0]);
                        ea_seg <= es_ovr ? SEG_ES
                                         : ea_defseg(m[7:6], m[2:0]);
                        st <= after_ea(m[7:6]);
                    end
                end
                S_D1: begin
                    bus_addr <= ({4'd0, sreg[SEG_CS]} << 4)
                              + {4'd0, ip};
                    is_fetch <= 1'b1;
                    st <= S_D1_L;
                end
                S_D1_L: begin
                    logic [7:0] d;
                    d = in_rom ? rom_data : dp_sel ? dp_rdata : iram_q;
                    ip <= ip + 16'd1;
                    if (mrm_mod == 2'b01) begin        // disp8 sext
                        disp <= {{8{d[7]}}, d};
                        ea_off <= ea_base(mrm_rm) + {{8{d[7]}}, d};
                        ea_seg <= es_ovr ? SEG_ES
                                         : ea_defseg(mrm_mod, mrm_rm);
                        st <= after_ea(mrm_mod);
                    end else begin                     // low of disp16
                        disp[7:0] <= d;
                        st <= S_D2;
                    end
                end
                S_D2: begin
                    bus_addr <= ({4'd0, sreg[SEG_CS]} << 4)
                              + {4'd0, ip};
                    is_fetch <= 1'b1;
                    st <= S_D2_L;
                end
                S_D2_L: begin
                    logic [15:0] d16;
                    d16 = {(in_rom ? rom_data :
                            dp_sel ? dp_rdata : iram_q), disp[7:0]};
                    disp <= d16;
                    ip <= ip + 16'd1;
                    if (mrm_mod == 2'b00)              // [disp16]
                        ea_off <= d16;
                    else                               // base+disp16
                        ea_off <= ea_base(mrm_rm) + d16;
                    ea_seg <= es_ovr ? SEG_ES
                                     : ea_defseg(mrm_mod, mrm_rm);
                    st <= after_ea(mrm_mod);
                end

                // ------------------------------------- immediates
                S_I1: begin
                    bus_addr <= ({4'd0, sreg[SEG_CS]} << 4)
                              + {4'd0, ip};
                    is_fetch <= 1'b1;
                    st <= S_I1_L;
                end
                S_I1_L: begin
                    imm[7:0] <= in_rom ? rom_data
                                       : dp_sel ? dp_rdata : iram_q;
                    ip <= ip + 16'd1;
                    if (imm_len2())
                        st <= S_I2;
                    else if ((opc == 8'h80 || opc == 8'h83) &&
                             mrm_mod != 2'b11)
                        st <= S_RD0;   // group RMW: fetch old value
                    else
                        st <= S_EXEC;
                end
                S_I2: begin
                    bus_addr <= ({4'd0, sreg[SEG_CS]} << 4)
                              + {4'd0, ip};
                    is_fetch <= 1'b1;
                    st <= S_I2_L;
                end
                S_I2_L: begin
                    imm[15:8] <= in_rom ? rom_data
                                        : dp_sel ? dp_rdata : iram_q;
                    ip <= ip + 16'd1;
                    if (opc == 8'hEA)
                        st <= S_I3;                    // segment word
                    else if (opc == 8'h81 && mrm_mod != 2'b11)
                        st <= S_RD0;   // group RMW: fetch old value
                    else
                        st <= S_EXEC;
                end
                S_I3: begin
                    bus_addr <= ({4'd0, sreg[SEG_CS]} << 4)
                              + {4'd0, ip};
                    is_fetch <= 1'b1;
                    st <= S_I3_L;
                end
                S_I3_L: begin
                    disp[7:0] <= in_rom ? rom_data
                                        : dp_sel ? dp_rdata : iram_q;
                    ip <= ip + 16'd1;
                    st <= S_I4;
                end
                S_I4: begin
                    bus_addr <= ({4'd0, sreg[SEG_CS]} << 4)
                              + {4'd0, ip};
                    is_fetch <= 1'b1;
                    st <= S_I4_L;
                end
                S_I4_L: begin
                    disp[15:8] <= in_rom ? rom_data
                                         : dp_sel ? dp_rdata : iram_q;
                    ip <= ip + 16'd1;
                    st <= S_EXEC;
                end

                // ------------------------------- memory operand read
                S_RD0: begin
                    bus_addr <= lin_ea;
                    is_fetch <= 1'b0;
                    st <= S_RD0_L;
                end
                S_RD0_L: begin
                    rmval[7:0] <= in_rom ? rom_data
                                         : dp_sel ? dp_rdata : iram_q;
                    if (op_wide(opc)) st <= S_RD1;
                    else              st <= S_EXEC;
                end
                S_RD1: begin
                    bus_addr <= lin_ea + 20'd1;
                    is_fetch <= 1'b0;
                    st <= S_RD1_L;
                end
                S_RD1_L: begin
                    rmval[15:8] <= in_rom ? rom_data
                                          : dp_sel ? dp_rdata : iram_q;
                    st <= S_EXEC;
                end

                // ------------------------------------------ execute
                S_EXEC: begin
                    st <= S_OP;                        // default next
                    es_ovr <= 1'b0;
                    if (opc[7:3] == 5'b10111)
                        reg16[opc[2:0]] <= imm;        // mov r16,imm
                    else if (opc[7:3] == 5'b10110)
                        r8_set(opc[2:0], imm[7:0]);    // mov r8,imm
                    else case (opc)
                        8'hFA: ;                       // di
                        8'h43: begin
                            reg16[BX] <= reg16[BX] + 16'd1;
                            set_zs(reg16[BX] + 16'd1, 1'b1);
                        end
                        8'h49: begin
                            reg16[CX] <= reg16[CX] - 16'd1;
                            set_zs(reg16[CX] - 16'd1, 1'b1);
                        end
                        8'hEB: ip <= ip + {{8{imm[7]}}, imm[7:0]};
                        8'h75: if (!fl_z)
                            ip <= ip + {{8{imm[7]}}, imm[7:0]};
                        8'hEA: begin
                            ip <= imm;
                            sreg[SEG_CS] <= disp;
                        end
                        8'hE8: begin
                            pushv <= ip;               // return address
                            ip <= ip + imm;
                            st <= S_PUSH0;
                        end
                        8'hC3: st <= S_POP0;
                        8'h8D: reg16[mrm_reg] <= ea_off;
                        8'h8E: sreg[mrm_reg[1:0]] <=
                                   (mrm_mod == 2'b11)
                                       ? reg16[mrm_rm] : rmval;
                        8'h8B: reg16[mrm_reg] <=
                                   (mrm_mod == 2'b11)
                                       ? reg16[mrm_rm] : rmval;
                        8'h8A: r8_set(mrm_reg,
                                   (mrm_mod == 2'b11)
                                       ? r8_get(mrm_rm) : rmval[7:0]);
                        8'h88: begin                   // mov rm8, r8
                            if (mrm_mod == 2'b11)
                                r8_set(mrm_rm, r8_get(mrm_reg));
                            else begin
                                wr_val <= {8'd0, r8_get(mrm_reg)};
                                wr_lin <= lin_ea;
                                st <= S_WR0;
                            end
                        end
                        8'h3B: begin
                            gr = grp_alu(3'd7, reg16[mrm_reg],
                                         (mrm_mod == 2'b11)
                                             ? reg16[mrm_rm] : rmval,
                                         1'b1);
                            fl_c <= gr[17]; set_zs(gr[15:0], 1'b1);
                        end
                        8'h3A: begin
                            gr = grp_alu(3'd7,
                                         {8'd0, r8_get(mrm_reg)},
                                         {8'd0, (mrm_mod == 2'b11)
                                             ? r8_get(mrm_rm)
                                             : rmval[7:0]}, 1'b0);
                            fl_c <= gr[17]; set_zs(gr[15:0], 1'b0);
                        end
                        8'h02: begin                   // add r8, rm8
                            gr = grp_alu(3'd0,
                                         {8'd0, r8_get(mrm_reg)},
                                         {8'd0, (mrm_mod == 2'b11)
                                             ? r8_get(mrm_rm)
                                             : rmval[7:0]}, 1'b0);
                            fl_c <= gr[17]; set_zs(gr[15:0], 1'b0);
                            r8_set(mrm_reg, gr[7:0]);
                        end
                        8'h80, 8'h81, 8'h83: begin
                            logic [15:0] b;
                            logic wide;
                            wide = (opc != 8'h80);
                            b = (opc == 8'h81) ? imm
                              : (opc == 8'h83) ? {{8{imm[7]}}, imm[7:0]}
                              :                  {8'd0, imm[7:0]};
                            gr = grp_alu(mrm_reg,
                                         (mrm_mod == 2'b11)
                                             ? (wide ? reg16[mrm_rm]
                                                : {8'd0, r8_get(mrm_rm)})
                                             : rmval,
                                         b, wide);
                            fl_c <= gr[17]; set_zs(gr[15:0], wide);
                            if (mrm_reg != 3'd7) begin // not cmp
                                if (mrm_mod == 2'b11) begin
                                    if (wide)
                                        reg16[mrm_rm] <= gr[15:0];
                                    else
                                        r8_set(mrm_rm, gr[7:0]);
                                end else begin
                                    wr_val <= gr[15:0];
                                    wr_lin <= lin_ea;
                                    st <= S_WR0;
                                end
                            end
                        end
                        default: begin
                            st <= S_HALT;
                        end
                    endcase
                end

                // ----------------------------------- memory writes
                S_WR0: begin
                    bus_addr <= wr_lin;
                    is_fetch <= 1'b0;
                    bus_wdata <= wr_val[7:0];
                    bus_we <= 1'b1;
                    dp_we_r <= (wr_lin[19:16] == 4'h1);
                    if (op_wide(opc)) st <= S_WR1;
                    else              st <= S_OP;
                end
                S_WR1: begin
                    bus_addr <= wr_lin + 20'd1;
                    is_fetch <= 1'b0;
                    bus_wdata <= wr_val[15:8];
                    bus_we <= 1'b1;
                    dp_we_r <= ((wr_lin + 20'd1) >> 16 == 4'h1);
                    st <= S_OP;
                end

                // ---------------------------------------- push/pop
                S_PUSH0: begin                         // high byte first
                    bus_addr <= ({4'd0, sreg[SEG_SS]} << 4)
                              + {4'd0, reg16[SP] - 16'd1};
                    is_fetch <= 1'b0;
                    bus_wdata <= pushv[15:8];
                    bus_we <= 1'b1;
                    dp_we_r <= ((({4'd0, sreg[SEG_SS]} << 4)
                               + {4'd0, reg16[SP] - 16'd1}) >> 16
                               == 4'h1);
                    st <= S_PUSH1;
                end
                S_PUSH1: begin
                    bus_addr <= ({4'd0, sreg[SEG_SS]} << 4)
                              + {4'd0, reg16[SP] - 16'd2};
                    is_fetch <= 1'b0;
                    bus_wdata <= pushv[7:0];
                    bus_we <= 1'b1;
                    dp_we_r <= ((({4'd0, sreg[SEG_SS]} << 4)
                               + {4'd0, reg16[SP] - 16'd2}) >> 16
                               == 4'h1);
                    reg16[SP] <= reg16[SP] - 16'd2;
                    st <= S_OP;
                end
                S_POP0: begin
                    bus_addr <= ({4'd0, sreg[SEG_SS]} << 4)
                              + {4'd0, reg16[SP]};
                    is_fetch <= 1'b0;
                    st <= S_POP0_L;
                end
                S_POP0_L: begin
                    ip[7:0] <= in_rom ? rom_data
                                      : dp_sel ? dp_rdata : iram_q;
                    st <= S_POP1;
                end
                S_POP1: begin
                    bus_addr <= ({4'd0, sreg[SEG_SS]} << 4)
                              + {4'd0, reg16[SP] + 16'd1};
                    is_fetch <= 1'b0;
                    st <= S_POP1_L;
                end
                S_POP1_L: begin
                    ip[15:8] <= in_rom ? rom_data
                                       : dp_sel ? dp_rdata : iram_q;
                    reg16[SP] <= reg16[SP] + 16'd2;
                    st <= S_OP;
                end

                S_HALT: ;                              // parked

                default: st <= S_HALT;
            endcase
        end
    end

    // next state after EA resolution: loads go through memory read,
    // register forms and pure stores (88) / lea go straight to EXEC;
    // 80/81/83 need their immediate first
    function automatic state_e after_ea (input logic [1:0] mod);
        if (opc == 8'h80 || opc == 8'h81 || opc == 8'h83)
            after_ea = S_I1;         // immediate; memory read follows
        else if (mod != 2'b11 && op_loads(opc))
            after_ea = S_RD0;
        else
            after_ea = S_EXEC;
    endfunction

    // immediate sizing: 16-bit for mov r16 / call / far-jmp offset /
    // 81-group; 8-bit otherwise
    function automatic logic imm_len2 ();
        imm_len2 = (opc[7:3] == 5'b10111) || (opc == 8'hE8) ||
                   (opc == 8'hEA) || (opc == 8'h81);
    endfunction

endmodule
