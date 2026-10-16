// s32_sdp.sv — simple dual-port RAM (write port A, read port B) as an
// explicit altsyncram, companion to s32_tdp.sv.
//
// For RAMs where inference slices the M10K blocks badly or fails: the
// Z80 sound ROM cache's fixed region (2560 x 128) infers as 64 blocks, but
// maximum_depth=256 packs it into 40. Registered 1-cycle read; a read of
// the address being written in the same cycle is undefined (no user does
// that).

module s32_sdp #(
    parameter AW = 12,                  // address bits
    parameter NW = 2560,                // actual word count
    parameter DW = 128,                 // data bits
    parameter MAXDEPTH = 256            // M10K slice depth
) (
    input  logic          clk,

    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] d,

    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] q
);

    altsyncram #(
        .operation_mode("DUAL_PORT"),
        .width_a(DW), .widthad_a(AW), .numwords_a(NW),
        .width_b(DW), .widthad_b(AW), .numwords_b(NW),
        .outdata_reg_b("UNREGISTERED"),
        .address_reg_b("CLOCK0"),
        .read_during_write_mode_mixed_ports("DONT_CARE"),
        .maximum_depth(MAXDEPTH),
        .width_byteena_a(1),
        .lpm_type("altsyncram")
    ) u_ram (
        .clock0(clk), .clock1(1'b1),
        .wren_a(we), .address_a(waddr), .data_a(d),
        .address_b(raddr), .q_b(q),
        .aclr0(1'b0), .aclr1(1'b0),
        .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1),
        .data_b({DW{1'b0}}), .wren_b(1'b0),
        .rden_a(1'b1), .rden_b(1'b1),
        .q_a(), .eccstatus()
    );

endmodule
