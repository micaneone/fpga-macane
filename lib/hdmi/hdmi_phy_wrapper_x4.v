// ============================================================
//  hdmi_phy_wrapper_x4 —— HDMI 物理层（用硬 4:1 串化器的版本）
//
//  和官方 hdmi_phy_warpper.v 的关系：
//    · 上半段（4 路"位序翻转"）和官方一模一样，原样保留 ✓
//    · 下半段把 4 个 lane_lvds_10_1（fabric 串化）换成 lane_lvds_10_4
//      （硬 4:1 串化），并多接一路 I_pclk
//
//  【为什么需要 I_pclk】
//    ODDRx2 一拍吃 4 位、用 sclk 双边沿发出去，所以：
//        数据率 = 4 × I_pclk = 2 × I_sclk
//    对 1024x768@70：I_pclk = 187.5MHz、I_sclk = 375MHz
//    → fabric 只跑 187.5MHz（老方案要跑 375MHz，实测花屏）
//
//  【为什么还要"位序翻转"这一段】
//    HDMI 核输出的 10 位 TMDS 字里，**bit0 是先发的那一位**。
//    而这条串化链是【bit9 先发】（lane_lvds_10_4 先送最高的 4 位，
//    而 ODDRx2 先送 d0 → 我们内部又做了一次位序映射）。
//    所以中间要翻一次，把"先发的 bit0"搬到 bit9 上去。
//    ★ 这一段别删、别"优化"，它是接口约定，不是冗余代码。
//
//  ★ 时钟相位（最容易踩的一个）：
//    I_pclk 的边沿必须落在 I_sclk 两个上升沿【中间】（相位差 90°）。
//    如果两个时钟边沿对齐，ODDRx2 内部的 q20/q31 会在输出选择那一刻翻转，
//    产生竞争 → 输出乱、屏幕花。这一条靠 PLL 的 phase_shift 参数实现：
//        C0 = 75MHz      (0°)
//        C1 = 187.5MHz   (★90°)   ← 并行时钟
//        C2 = 375MHz     (0°)     ← 串化时钟
// ============================================================
module hdmi_phy_wrapper_x4 #(
    parameter DEVICE = "EG"                  // 器件系列，我们填 "EG"
)(
    input  wire       I_pixel_clk,           // 像素时钟 75MHz
    input  wire       I_pclk,                // 并行时钟 187.5MHz（★要比 sclk 相位差 90°）
    input  wire       I_sclk,                // 串化时钟 375MHz
    input  wire       I_rst,                 // 复位，★高有效

    // 4 路 10bit TMDS 字，来自 HDMI 核
    input  wire [9:0] I_tmds_channel_0,      // 蓝 + HSYNC + VSYNC
    input  wire [9:0] I_tmds_channel_1,      // 绿
    input  wire [9:0] I_tmds_channel_2,      // 红
    input  wire [9:0] I_tmds_channel_clk,    // 时钟通道（固定图案）

    // 4 根差分输出（只出 _P，负端由工具自动配对）
    output wire       O_tmds_ch0_p,          // → HDMI_D0_P
    output wire       O_tmds_ch1_p,          // → HDMI_D1_P
    output wire       O_tmds_ch2_p,          // → HDMI_D2_P
    output wire       O_tmds_clk_p           // → HDMI_CLK_P
);

    // ------------------------------------------------------------
    //  位序翻转：把每个 10 位字整个倒过来
    //    {in[0],in[1],...,in[9]} → bit0 跑到最高位、bit9 跑到最低位
    //    这样"输入里最先要发的 bit0"就落到了 bit9（串化链先发 bit9）
    //  （4 路做的是同一件事，只是通道不同）
    // ------------------------------------------------------------
    wire [9:0] S_tmds_data_ch0;
    wire [9:0] S_tmds_data_ch1;
    wire [9:0] S_tmds_data_ch2;
    wire [9:0] S_tmds_data_clk;

    assign S_tmds_data_ch0 = {I_tmds_channel_0[0], I_tmds_channel_0[1],
                              I_tmds_channel_0[2], I_tmds_channel_0[3],
                              I_tmds_channel_0[4], I_tmds_channel_0[5],
                              I_tmds_channel_0[6], I_tmds_channel_0[7],
                              I_tmds_channel_0[8], I_tmds_channel_0[9]};

    assign S_tmds_data_ch1 = {I_tmds_channel_1[0], I_tmds_channel_1[1],
                              I_tmds_channel_1[2], I_tmds_channel_1[3],
                              I_tmds_channel_1[4], I_tmds_channel_1[5],
                              I_tmds_channel_1[6], I_tmds_channel_1[7],
                              I_tmds_channel_1[8], I_tmds_channel_1[9]};

    assign S_tmds_data_ch2 = {I_tmds_channel_2[0], I_tmds_channel_2[1],
                              I_tmds_channel_2[2], I_tmds_channel_2[3],
                              I_tmds_channel_2[4], I_tmds_channel_2[5],
                              I_tmds_channel_2[6], I_tmds_channel_2[7],
                              I_tmds_channel_2[8], I_tmds_channel_2[9]};

    assign S_tmds_data_clk = {I_tmds_channel_clk[0], I_tmds_channel_clk[1],
                              I_tmds_channel_clk[2], I_tmds_channel_clk[3],
                              I_tmds_channel_clk[4], I_tmds_channel_clk[5],
                              I_tmds_channel_clk[6], I_tmds_channel_clk[7],
                              I_tmds_channel_clk[8], I_tmds_channel_clk[9]};

    // ------------------------------------------------------------
    //  4 个硬 4:1 串化器（4 个实例完全一样，只是数据/输出不同）
    // ------------------------------------------------------------
    lane_lvds_10_4 u0_lane (
        .I_pixel_clk  (I_pixel_clk),
        .I_pclk       (I_pclk),
        .I_sclk       (I_sclk),
        .I_rst        (I_rst),
        .I_data_in    (S_tmds_data_ch0),
        .O_serial_out (O_tmds_ch0_p)
    );

    lane_lvds_10_4 u1_lane (
        .I_pixel_clk  (I_pixel_clk),
        .I_pclk       (I_pclk),
        .I_sclk       (I_sclk),
        .I_rst        (I_rst),
        .I_data_in    (S_tmds_data_ch1),
        .O_serial_out (O_tmds_ch1_p)
    );

    lane_lvds_10_4 u2_lane (
        .I_pixel_clk  (I_pixel_clk),
        .I_pclk       (I_pclk),
        .I_sclk       (I_sclk),
        .I_rst        (I_rst),
        .I_data_in    (S_tmds_data_ch2),
        .O_serial_out (O_tmds_ch2_p)
    );

    lane_lvds_10_4 u3_lane (
        .I_pixel_clk  (I_pixel_clk),
        .I_pclk       (I_pclk),
        .I_sclk       (I_sclk),
        .I_rst        (I_rst),
        .I_data_in    (S_tmds_data_clk),
        .O_serial_out (O_tmds_clk_p)
    );

endmodule
