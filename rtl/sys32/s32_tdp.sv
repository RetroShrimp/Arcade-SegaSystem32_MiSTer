// s32_tdp.sv — true dual-port RAM as an explicit altsyncram.
//
// Most dual-port RAMs in the core are inferred from Intel's two-always-
// block template. Quartus 17 fails to infer two shapes and builds them from
// registers instead: a port address that is an expression or a mux, and a
// genvar-indexed 2-D array. Those use this wrapper.
//
// One read/write port per side, synchronous 1-cycle reads, new data on a
// same-port write. A read on one port of the address the other port is
// writing in the same cycle is undefined on the M10K (DONT_CARE) unless
// RDW_FWD or RDW_OLD is set. A read-only side is written as we=0.

module s32_tdp #(
    parameter AW = 14,                  // address bits (depth = 2**AW)
    parameter DW = 8,                   // data bits
    // OREGA/OREGB=1 use the M10K's own output register on port A/B: read
    // latency becomes 2 clk, but the output is clean even when the address
    // jumps across the RAM's internal blocks. Without it, on a deep RAM the
    // output mux does not always settle before the next clock edge after a
    // far jump, and the FPGA reads a wrong value (simulation does not show
    // this). Used where a port's address jumps far: the palette's mixer
    // and CPU ports, and the V60 work RAM.
    parameter OREGA = 0,
    parameter OREGB = 0,
    // RDW_FWD=1: when one port reads the address the other is writing in
    // the same cycle, return the written data (delayed to match the read
    // latency) instead of the RAM's undefined output. This makes the RAM
    // behave like the RF5C68's single wave RAM, where a CPU write during a
    // channel read gives defined data. Used by s32_pcm's wave RAM.
    parameter RDW_FWD = 0,
    // RDW_OLD=1 sets the mixed-port read-during-write mode to OLD_DATA
    // instead of DONT_CARE (allowed because this RAM uses a single clock).
    // On the RF5C68 wave RAM an undefined read matters: 0xFF is the loop
    // marker, and a stray 0xFF sends the channel back to its loop start. If
    // Quartus cannot honour the mode it warns and falls back to DONT_CARE,
    // so check the build log.
    parameter RDW_OLD = 0
) (
    input  logic          clk,

    input  logic          we_a,
    input  logic [AW-1:0] addr_a,
    input  logic [DW-1:0] d_a,
    output logic [DW-1:0] q_a,

    input  logic          we_b,
    input  logic [AW-1:0] addr_b,
    input  logic [DW-1:0] d_b,
    output logic [DW-1:0] q_b
);

    // RAM outputs (the RDW_FWD bypass, if enabled, sits after these)
    logic [DW-1:0] q_a_ram, q_b_ram;

    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"),
        .width_a(DW), .widthad_a(AW), .numwords_a(2**AW),
        .width_b(DW), .widthad_b(AW), .numwords_b(2**AW),
        .outdata_reg_a(OREGA ? "CLOCK0" : "UNREGISTERED"),
        .outdata_reg_b(OREGB ? "CLOCK0" : "UNREGISTERED"),
        // single-clock TDP: port B registers default to CLOCK1 in
        // BIDIR mode — force everything onto clock0
        .address_reg_b("CLOCK0"),
        .indata_reg_b("CLOCK0"),
        .wrcontrol_wraddress_reg_b("CLOCK0"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_mixed_ports(RDW_OLD ? "OLD_DATA" : "DONT_CARE"),
        .width_byteena_a(1), .width_byteena_b(1),
        .lpm_type("altsyncram")
    ) u_ram (
        .clock0(clk), .clock1(1'b1),
        .wren_a(we_a), .address_a(addr_a), .data_a(d_a), .q_a(q_a_ram),
        .wren_b(we_b), .address_b(addr_b), .data_b(d_b), .q_b(q_b_ram),
        .aclr0(1'b0), .aclr1(1'b0),
        .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1),
        .rden_a(1'b1), .rden_b(1'b1),
        .eccstatus()
    );

    // -------------- mixed-port read-during-write forwarding (RDW_FWD) -----
    // Detect the collision when the read is issued (one port reads the
    // address the other writes, and is not writing itself), delay the write
    // data by the reading port's latency, and use it instead of the RAM
    // output.
    generate
        if (RDW_FWD) begin : g_rdwfwd
            localparam int LB = 1 + (OREGB ? 1 : 0);   // port-B read latency
            localparam int LA = 1 + (OREGA ? 1 : 0);   // port-A read latency
            logic [LB-1:0] cb;  logic [DW-1:0] fb [0:LB-1];
            logic [LA-1:0] ca;  logic [DW-1:0] fa [0:LA-1];
            integer i;
            always_ff @(posedge clk) begin
                cb[0] <= we_a && !we_b && (addr_a == addr_b);  fb[0] <= d_a;
                ca[0] <= we_b && !we_a && (addr_b == addr_a);  fa[0] <= d_b;
                for (i = 1; i < LB; i = i + 1) begin cb[i] <= cb[i-1]; fb[i] <= fb[i-1]; end
                for (i = 1; i < LA; i = i + 1) begin ca[i] <= ca[i-1]; fa[i] <= fa[i-1]; end
            end
            assign q_b = cb[LB-1] ? fb[LB-1] : q_b_ram;
            assign q_a = ca[LA-1] ? fa[LA-1] : q_a_ram;
        end else begin : g_nordwfwd
            assign q_b = q_b_ram;
            assign q_a = q_a_ram;
        end
    endgenerate

endmodule
