// ============================================================
//  模块名 : zoom_dual
//  作用   : 【两套缩放几何】—— 前台一张、后台一张，给 scaler_addr 的两路用
//  时钟域 : 像素域 40 MHz
//  依据   : 规划\B轨待改清单.md §十六（"不经过米白"的转场）
// ------------------------------------------------------------
//  ★ 为什么要两套：直接划像 / 叠化时**两张图同时在屏上**，而它们的适配缩放
//    不一样（640×480 → step 0.8；800×600 → step 1.0）。共用一套的话，
//    进来的那张会被拿出去的 step/off 取样 → 只露左上角、收尾才闪回正位
//    （就是上板抓到的那个 bug，见台账 §十五）。
//
//  ★ 为什么不干脆例化两个 zoom_sel：DSP 只剩 3 个，而一个 zoom_sel 要 4 个
//    （两处"窗口宽 × step"的乘法）。所以这里**只留一套算术**：
//      · 除法器（适配档那个）和两处乘法都只有一份；
//      · 输入按相位轮流喂 A 槽 / B 槽的源尺寸；
//      · 输出分两个寄存器组锁住 —— 锁定以后，两路的几何**各自稳定**，
//        和算术单元在忙什么完全无关。
//    几何只在"换图 / 换档 / 换窗口"时变，而且是慢变信号，锁存晚几百拍
//    肉眼完全看不出来（一次刷新 ≈ 512 拍 = 12.8 µs）。
//
//  ★ 相位：一个自由计数器的最高位。
//       phase=0 → 喂 A 槽尺寸； 相位结束时（且除法器不忙）锁进 A 组
//       phase=1 → 喂 B 槽尺寸； 相位结束时锁进 B 组
//    ★ 锁存前判 `!fit_busy`：万一除法还没走完就跳过这一轮，
//      下一轮（256 拍后）再锁 —— 只会晚一点，不会锁进半个结果。
// ============================================================
`timescale 1ns / 1ps

module zoom_dual #(
    // 相位长度（拍）。256 拍 @40MHz = 6.4 µs，刷新一轮 512 拍 ≈ 12.8 µs
    parameter integer PHASE_LEN = 256
)(
    input  wire        clk_pix,
    input  wire        rst_pix_n,

    input  wire [2:0]  level,       // 0=适配 1=1x 2=1.5x 3=2x 4=3x 5=4x
    // 两个槽的源尺寸
    input  wire [11:0] a_w, a_h,
    input  wire [11:0] b_w, b_h,
    input  wire [11:0] win_w,
    input  wire [11:0] win_h,

    // ---- 前台那套 ----
    output wire [31:0]        a_step, a_off_u, a_off_v,
    // ---- 后台那套 ----
    output wire [31:0]        b_step, b_off_u, b_off_v,
    // ---- 诊断 ----
    output wire               busy
);

    // ============================================================
    //  相位计数器
    // ============================================================
    reg  [16:0] ph_cnt;
    reg         ph;                          // 0 = 喂 A 槽，1 = 喂 B 槽
    wire        ph_end = (ph_cnt >= PHASE_LEN-1);

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            ph_cnt <= 17'd0;
            ph     <= 1'b0;
        end
        else if (ph_end) begin
            ph_cnt <= 17'd0;
            ph     <= ~ph;
        end
        else ph_cnt <= ph_cnt + 17'd1;
    end

    // ============================================================
    //  唯一那套算术：输入按相位切
    // ============================================================
    wire [11:0] z_src_w = ph ? b_w : a_w;
    wire [11:0] z_src_h = ph ? b_h : a_h;

    wire [31:0]        z_step;
    wire signed [31:0] z_off_u, z_off_v;
    wire               z_bilin, z_busy;

    zoom_sel u_zoom (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .level(level),
        .src_w(z_src_w), .src_h(z_src_h),
        .win_w(win_w), .win_h(win_h),
        .step_q16(z_step), .off_u_q16(z_off_u), .off_v_q16(z_off_v),
        .bilin_en(z_bilin),
        .step_fit_q16(), .fit_busy(z_busy)
    );

    assign busy = z_busy;

    // ============================================================
    //  两个寄存器组：相位结束那一拍（且算术已经算完）才锁
    // ============================================================
    reg [31:0] a_step_r32, a_offu_r32, a_offv_r32;
    reg [31:0] b_step_r32, b_offu_r32, b_offv_r32;

    wire latch = ph_end && !z_busy;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            // 上电先给一个"1:1、不偏移"的安全值，别让两路看到 step=0
            a_step_r32 <= 32'd65536; a_offu_r32 <= 32'sd0; a_offv_r32 <= 32'sd0;
            b_step_r32 <= 32'd65536; b_offu_r32 <= 32'sd0; b_offv_r32 <= 32'sd0;
        end
        else if (latch) begin
            if (ph) begin                        // 这一相位喂的是 B 槽
                b_step_r32 <= z_step;
                b_offu_r32 <= z_off_u;
                b_offv_r32 <= z_off_v;
            end
            else begin
                a_step_r32 <= z_step;
                a_offu_r32 <= z_off_u;
                a_offv_r32 <= z_off_v;
            end
        end
    end

    assign a_step  = a_step_r32;
    assign a_off_u = a_offu_r32;
    assign a_off_v = a_offv_r32;
    assign b_step  = b_step_r32;
    assign b_off_u = b_offu_r32;
    assign b_off_v = b_offv_r32;

endmodule
