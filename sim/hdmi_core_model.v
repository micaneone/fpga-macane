// ============================================================
//  hdmi_core_model.v -- compile/elaborate stand-in for the encrypted
//  hdmi_1_4b_transmitter_core_wrapper (same module name + ports).
//
//  WHY: the real wrapper is an encrypted .enc.v that ModelSim cannot read,
//  so check_compile.ps1 must substitute a module with the identical interface.
//  This is SIM/COMPILE ONLY -- never add it to a TD project.
//
//  Behaviour: outputs tied to safe constants; it does NOT drive TMDS.
//  Ports/widths copied from lib\hdmi\my_hdmitop.v (2026-10-20).
// ============================================================
`timescale 1ns / 1ps

module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE            = "EG",
    parameter HTOTAL            = 1056,
    parameter HSA               = 128,
    parameter HFP               = 40,
    parameter HBP               = 88,
    parameter HACTIVE           = 800,
    parameter VTOTAL            = 628,
    parameter VSA               = 4,
    parameter VFP               = 1,
    parameter VBP               = 23,
    parameter VACTIVE           = 600,
    parameter VIDEO_TPG         = "Disable",
    parameter VIDEO_FORMAT      = "RGB",
    parameter VIDEO_VIC         = 8'h00,
    parameter AUDIO_SAMPLE_RATE = "48K",
    parameter IIC_SCL_DIV       = 8'd40
) (
    input  wire        I_pixel_clk,
    input  wire        I_rst,

    input  wire        I_edid_read_trig,
    output wire        O_edid_read_valid,
    output wire [7:0]  O_edid_read_data,

    input  wire        I_axis_s_user,
    input  wire        I_axis_s_valid,
    input  wire        I_axis_s_last,
    input  wire [23:0] I_axis_s_data,
    output wire        O_axis_s_ready,

    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_left_data,
    input  wire [23:0] I_audio_right_data,

    input  wire        I_acr_valid,
    input  wire [19:0] I_acr_cts,
    input  wire [19:0] I_acr_n,

    output wire        O_video_locked,

    output wire        O_ddc_scl,
    inout  wire        IO_ddc_sda,

    output wire [9:0]  O_ch0_tmds_data,
    output wire [9:0]  O_ch1_tmds_data,
    output wire [9:0]  O_ch2_tmds_data,
    output wire [9:0]  O_clk_tmds_data
);

    assign O_edid_read_valid = 1'b0;
    assign O_edid_read_data  = 8'h00;
    assign O_axis_s_ready    = 1'b1;
    assign O_video_locked    = 1'b0;
    assign O_ddc_scl         = 1'b1;
    assign IO_ddc_sda        = 1'bz;
    assign O_ch0_tmds_data   = 10'h000;
    assign O_ch1_tmds_data   = 10'h000;
    assign O_ch2_tmds_data   = 10'h000;
    assign O_clk_tmds_data   = 10'h000;

endmodule
