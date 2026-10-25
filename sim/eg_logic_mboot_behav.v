// -----------------------------------------------------------------------------
//  eg_logic_mboot_behav.v  --  ModelSim behaviour stand-in for TD's
//                              EG_LOGIC_MBOOT primitive (MULTI BOOT control).
//
//  TD's sim_release model for this primitive is IEEE-1735 encrypted and is not
//  present in the eg4 sim model set at all, so check_compile.ps1 gets a plain
//  behavioural module instead (compile/sim only -- NEVER add this file to the TD
//  project; TD resolves the real primitive from arch/eagle_macro.v by itself).
//
//  Behaviour: rebootn is active-low.  In simulation we just latch a flag so a
//  testbench can observe that a reconfiguration was requested; the fabric is not
//  actually reconfigured.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module EG_LOGIC_MBOOT (
    input  wire       rebootn,
    input  wire [7:0] dynamic_addr
);

    parameter ADDR_SOURCE_SEL = "STATIC";
    parameter STATIC_ADDR     = 8'b00000000;

    // synthesis translate_off
    reg mboot_requested = 1'b0;
    always @(negedge rebootn) begin
        mboot_requested = 1'b1;
    end
    // synthesis translate_on

endmodule
