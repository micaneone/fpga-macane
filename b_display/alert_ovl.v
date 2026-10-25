// ============================================================================
//  alert_ovl.v —— D5 · S1 插播态视觉层（纯净组合 + 一个帧计数器）
// ----------------------------------------------------------------------------
//  作用：报警期间在"画面 + 字幕 + 亮度"之上叠一层东西：
//    ① 8 px 纯红警示边框，1 Hz 闪（0.5 s 亮 / 0.5 s 透明）
//    ② 画面本身**永不变色**：报警时图像照常显示，只靠边框闪 + 蜂鸣器提醒
//
//  ★ 2026-10-25 改（现场反馈"紧急情况下画面不要一直闪，旁边的框闪就行，
//    要让图能看清"）：原实现是 1 Hz **全屏红罩**（0.5 s 整屏压红 / 0.5 s 只留
//    边框），画面被红罩盖住一半时间、看不清内容；现改为红罩只落在边框区域，
//    黑相时边框直接透传像素 ⇒ 屏幕上只有一圈红框在闪，中间图像始终原样。
//
//  ★ 为什么这么做而不是切一张"应急图"：
//    切图要占一个 SDRAM 槽 + 一次装载（0.8 s 起），而叠层是**组合逻辑**，
//    拨下开关当帧就红 ⇒ 这是"响应 ≤1 帧"这条硬指标唯一便宜的做法。
//
//  ★ 红框不用乘法：直接写 RGB565 纯红常量，0 个 DSP、0 个 BRAM。
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

    // ---- 边框几何（1024×768，8 px）----
    localparam [11:0] BORDER = 12'd8;
    localparam [11:0] X_END  = 12'd1016;  // 1024 - 8
    localparam [11:0] Y_END  = 12'd760;   // 768 - 8

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

    always @(*) begin
        if (!de_in || !alert_on)
            px_out = px_in;                 // 不报警 / 消隐期：逐位透传
        else if (border && flash)
            px_out = 16'hF800;              // 亮相：只有边框纯红
        else
            px_out = px_in;                 // 暗相：边框透明 ⇒ 整幅图原样可见
    end

endmodule
