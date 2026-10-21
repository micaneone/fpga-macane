// ============================================================================
//  alert_ovl.v —— D5 · S1 插播态视觉层（纯净组合 + 一个帧计数器）
// ----------------------------------------------------------------------------
//  作用：报警期间在"画面 + 字幕 + 亮度"之上叠两层东西：
//    ① 8 px 纯红警示边框（一直亮）
//    ② 1 Hz 全屏红闪：0.5 s 红罩 / 0.5 s 只留边框
//
//  ★ 为什么这么做而不是切一张"应急图"：
//    切图要占一个 SDRAM 槽 + 一次装载（0.8 s 起），而叠层是**组合逻辑**，
//    拨下开关当帧就红 ⇒ 这是"响应 ≤1 帧"这条硬指标唯一便宜的做法。
//
//  ★ 红罩不用乘法：直接把 R 拉满、G/B 各右移一位
//    ⇒ 只有 5 个 LUT 层的移位 + 拼接，0 个 DSP、0 个 BRAM。
//
//  ★ 延迟：**0 拍**（和 bri_scale 同口径）。所以 de/x/y 用上游那一级原样，
//    不需要像 font32 那样补拍 —— 补拍会把整幅图右移一像素。
//
//  位置（disp_top.v）：`bri_scale` 之后、`menu_ovl_cn` 之前
//    ⇒ 报警红罩**压不住菜单**（现场要能一边报警一边调音量/亮度）。
// ============================================================================
`timescale 1ns / 1ps

module alert_ovl (
    input  wire        clk_pix,
    input  wire        rst_pix_n,

    input  wire        de_in,
    input  wire        vs_in,
    input  wire [11:0] x_in,
    input  wire [11:0] y_in,
    input  wire [15:0] px_in,

    input  wire        alert_on,     // 像素域电平（top_m2 里两级同步过）

    output reg  [15:0] px_out
);

    // ---- 边框几何（800×600，8 px）----
    localparam [11:0] BORDER = 12'd8;
    localparam [11:0] X_END  = 12'd792;   // 800 - 8
    localparam [11:0] Y_END  = 12'd592;   // 600 - 8

    // ---- 闪烁节拍：30 帧 = 0.5 s @60 Hz ----
    localparam [5:0] HALF_FRAMES = 6'd30;

    reg vs_d;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) vs_d <= 1'b0;
        else            vs_d <= vs_in;
    end
    wire vs_rise = vs_in & ~vs_d;

    reg [5:0] fcnt;
    reg       flash;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            fcnt  <= 6'd0;
            flash <= 1'b0;
        end
        // ★ 报警一解除立刻回"只留边框"，下次报警从亮相开始
        else if (!alert_on) begin
            fcnt  <= 6'd0;
            flash <= 1'b0;
        end
        else if (vs_rise) begin
            if (fcnt >= (HALF_FRAMES - 6'd1)) begin
                fcnt  <= 6'd0;
                flash <= ~flash;
            end
            else begin
                fcnt <= fcnt + 6'd1;
            end
        end
    end

    wire border = (x_in < BORDER) || (x_in >= X_END) ||
                  (y_in < BORDER) || (y_in >= Y_END);

    // 红罩：R 拉满（5 位全 1），G/B 各减半
    wire [15:0] wash = {5'h1F, 1'b0, px_in[10:6] >> 1, px_in[4:0] >> 1};

    always @(*) begin
        if (!de_in || !alert_on)
            px_out = px_in;
        else if (flash)
            px_out = wash;          // 红相：整屏（含边框，边框本来就是纯红）
        else if (border)
            px_out = 16'hF800;      // 黑相：只有边框
        else
            px_out = px_in;
    end

endmodule
