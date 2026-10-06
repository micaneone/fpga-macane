// ============================================================
//  我的 hdmi 顶层模块
//  把「HDMI 核 + 视频转axis + 物理层串化」全部包在这里，
//  上层只需要给：像素时钟 / 并行时钟 / 串化时钟 / 复位 / vs / de / rgb
//
//  【当前分辨率】800x600@60
//      I_pixel_clk =  40.000 MHz  像素时钟
//      I_pclk      = 100.000 MHz  并行时钟（ODDRx2 用，★相位要比 I_serial_clk 差 90°）
//      I_serial_clk= 200.000 MHz  串化时钟（= 5 × 像素时钟）
//
//  【为什么需要 I_pclk】见 hdmi_phy_wrapper_x4.v 里的说明：
//      硬 4:1 串化器一拍吃 4 位，数据率 = 4 × I_pclk = 2 × I_serial_clk，
//      这样 fabric 只需要跑 100MHz（老方案要跑 200MHz，1024x768 时要跑 375MHz，实测花屏）
// ============================================================
module my_hdmitop #(
    parameter DEVICE = "EG",
    parameter pic_wide = 640,
    parameter pic_high = 480
) (
    // ---- 时钟与复位 ----
    input  wire        I_pixel_clk,     // 像素时钟（800x600@60 → 40MHz）
    input  wire        I_pclk,          // ★并行时钟（100MHz，边沿要在 sclk 两上升沿中间）
    input  wire        I_serial_clk,    // ★串化时钟（200MHz = 5 × 像素时钟）
    input  wire        I_rst,           // ★高有效（核和 phy 都要高有效）

    // ---- 视频输入（只要这三样）----
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,

    // ---- TMDS 输出：4 根 ----
    output wire        O_tmds_clk_p,    // → HDMI_CLK_P
    output wire        O_tmds_d0_p,     // → HDMI_D0_P
    output wire        O_tmds_d1_p,     // → HDMI_D1_P
    output wire        O_tmds_d2_p,     // → HDMI_D2_P

    // ---- DDC（和显示器之间的 I2C）----
    output wire        O_ddc_scl,       // → HDMI_DDC_SCL（引脚 P2）
    inout  wire        IO_ddc_sda,      // → HDMI_DDC_SDA（引脚 R2，要上拉）

    // ---- 状态（建议露出来，接个 LED）----
    output wire        O_video_locked,

    // ---- EDID 读取暴露给上层 ---
    output wire        O_edid_read_valid,
    output wire [7:0]  O_edid_read_data, //核一次给一个字节（8 位）

    // ---- ★★ 2026-10-05 音频（来自 top_aud，全部在【像素域】）----
    //   A 轨的音频链给的就是这 6 根（并行采样 + ACR），不是 I2S ——
    //   HDMI 核本来就在同一颗芯片里，不需要先串出去再解回来。
    //   ★ 不接就是原来的行为（核吃到常数 0 = 没有音频）。
    input  wire        I_audio_valid,    // 单拍：这一拍有一个采样
    input  wire [23:0] I_audio_left,     // 左声道（16 位采样左对齐到 24 位）
    input  wire [23:0] I_audio_right,    // 右声道（单声道 → 和左一样）
    input  wire        I_acr_valid,      // ACR（音频时钟重建）
    input  wire [19:0] I_acr_cts,
    input  wire [19:0] I_acr_n
);

// VIC 编号（写进 AVI infoframe 告诉显示器"这是什么格式"）
//   640x480@60 在 CEA 表里有编号（1）
//   800x600 / 1024x768 不属于 CEA 格式 → 填 0（= "没有标准编号"）
localparam VIDEO_VIC = (pic_wide == 640) ? 1 : 0;

// DDC(=I2C) 的 SCL 分频：核按【像素时钟】计数，值 = f_pixel / 100kHz
//   25MHz → 250（官方例程就是这个数）   40MHz → 400   75MHz → 750
//   ★ 这个数不能照抄：像素时钟换了它不换，SCL 就会超过 DDC 规范的 100kHz 上限
localparam IIC_SCL_DIV = (pic_wide == 800)  ? 400 :
                         (pic_wide == 1024) ? 750 : 250;

// ============================================================
//  时序参数（★ 必须和 video_timing.v 里那一档【完全一致】）
//    640x480  配 25.000MHz 像素时钟（@60，总长  800x525）
//    800x600  配 40.000MHz 像素时钟（@60，总长 1056x628）← 现在用这一档
//    1024x768 配 75.000MHz 像素时钟（@70，总长 1328x806）
//  核要这几个数的原因是：它自己按 HTOTAL/VTOTAL 生成 TMDS 里的行场时序，
//  我们的 de / vs 只告诉它"哪里是可见像素、哪里是帧首"。
// ============================================================
localparam RES_640x480  = 0;
localparam RES_800x600  = 1;
localparam RES_1024x768 = 2;
localparam RES_ID = (pic_wide == 800)  ? RES_800x600  :
                    (pic_wide == 1024) ? RES_1024x768 : RES_640x480;

// ---------------------- 行时序参数 ----------------------
localparam HPORCH  = (RES_ID == RES_1024x768) ? 12'd24  :
                     (RES_ID == RES_800x600 ) ? 12'd40  : 12'd16;   // 行前肩
localparam HSYNC_W = (RES_ID == RES_1024x768) ? 12'd136 :
                     (RES_ID == RES_800x600 ) ? 12'd128 : 12'd96;   // 行同步宽度
localparam BPORCH  = (RES_ID == RES_1024x768) ? 12'd144 :
                     (RES_ID == RES_800x600 ) ? 12'd88  : 12'd48;   // 行后肩
localparam H_TOTAL = HPORCH + HSYNC_W + pic_wide + BPORCH;   // 640:800 / 800x600:1056 / 1024@70:1328

// ---------------------- 场时序参数 ----------------------
localparam VPORCH  = (RES_ID == RES_1024x768) ? 12'd3   :
                     (RES_ID == RES_800x600 ) ? 12'd1   : 12'd10;   // 场前肩
localparam VSYNC_W = (RES_ID == RES_1024x768) ? 12'd6   :
                     (RES_ID == RES_800x600 ) ? 12'd4   : 12'd2;    // 场同步宽度
localparam VBPORCH = (RES_ID == RES_1024x768) ? 12'd29  :
                     (RES_ID == RES_800x600 ) ? 12'd23  : 12'd33;   // 场后肩
localparam V_TOTAL = VPORCH + VSYNC_W + pic_high + VBPORCH; // 640:525 / 800x600:628 / 1024@70:806




wire video_user, video_valid, video_last;    //内部接线
wire [23:0]video_data;
video_rgb_to_axis #(
    .pic_wide(pic_wide),                //每行可见像素数 = 屏宽（要跟 video_timing 一致）
    .pic_high(pic_high))                //每帧可见行数 = 屏高
rgb2axis (
    .I_clk(I_pixel_clk),                //像素时钟 
    .I_rst(I_rst),                      //复位，★高有效，异步
    .I_vs(I_vs),                        //场同步（只用它的"跳变"来标帧首）
    .I_de(I_de),                        //数据有效（可见区）
    .I_rgb(I_rgb),                      //24位像素 {R,G,B}
    .O_video_user(video_user),          //帧首标志，脉冲一拍
    .O_video_valid(video_valid),        //= de 打一拍
    .O_video_last(video_last),          //行尾标志，脉冲一拍
    .O_video_data(video_data)           //= rgb 打一拍
);

wire edid_read_trig;
wire[9:0]ch0_tmds_data;
wire[9:0]ch1_tmds_data;
wire[9:0]ch2_tmds_data;
wire[9:0]clk_tmds_data;
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE(DEVICE),
    // ---------------------- 行时序参数  ----------
    .HTOTAL(H_TOTAL),
    .HSA(HSYNC_W),
    .HFP(HPORCH),
    .HBP(BPORCH),
    .HACTIVE(pic_wide),

   // ---------- 场时序参数  ----------
    .VTOTAL(V_TOTAL),
    .VSA(VSYNC_W),
    .VFP(VPORCH),
    .VBP(VBPORCH),
    .VACTIVE(pic_high),

    .VIDEO_TPG("Disable"),
    .VIDEO_FORMAT("RGB"),
    .VIDEO_VIC(VIDEO_VIC),
    .AUDIO_SAMPLE_RATE("48K"),
    .IIC_SCL_DIV(IIC_SCL_DIV)           //按上面的 localparam 自动跟着分辨率走
) hdmi_core (
    .I_pixel_clk(I_pixel_clk),
    .I_rst(I_rst),

    .I_edid_read_trig(edid_read_trig),
    .O_edid_read_valid(O_edid_read_valid),
    .O_edid_read_data(O_edid_read_data),

    .I_axis_s_user(video_user),
    .I_axis_s_valid(video_valid),
    .I_axis_s_last(video_last),
    .I_axis_s_data(video_data),
    .O_axis_s_ready(),

    .I_audio_valid(I_audio_valid),
    .I_audio_left_data(I_audio_left),
    .I_audio_right_data(I_audio_right),

    .I_acr_valid(I_acr_valid),
    .I_acr_cts(I_acr_cts),
    .I_acr_n(I_acr_n),

    .O_video_locked(O_video_locked),

    .O_ddc_scl(O_ddc_scl),
    .IO_ddc_sda(IO_ddc_sda),

    .O_ch0_tmds_data(ch0_tmds_data),
    .O_ch1_tmds_data(ch1_tmds_data),
    .O_ch2_tmds_data(ch2_tmds_data),
    .O_clk_tmds_data(clk_tmds_data)
);

// ------------------------------------------------------------
//  物理层：4 路"位序翻转" + 4 个硬 4:1 串化器（EG_LOGIC_ODDRx2）
//
//  ★ 想换回老方案（fabric 串化，只能跑到 125MHz）：
//      把 hdmi_phy_wrapper_x4 改成 hdmi_phy_wrapper，
//      去掉 .I_pclk(...)，并把 I_pixel_clk/I_serial_clk 换成 25MHz/125MHz。
//    老的 hdmi_phy_warpper.v + lane_lvds_10_1.v 都还在工程里，随时能切回去。
// ------------------------------------------------------------
hdmi_phy_wrapper_x4 #(
    .DEVICE(DEVICE)
) hdmi_phy (
    .I_pixel_clk(I_pixel_clk),
    .I_pclk(I_pclk),
    .I_sclk(I_serial_clk),
    .I_rst(I_rst),

    .I_tmds_channel_0(ch0_tmds_data),
    .I_tmds_channel_1(ch1_tmds_data),
    .I_tmds_channel_2(ch2_tmds_data),
    .I_tmds_channel_clk(clk_tmds_data),

    .O_tmds_ch0_p(O_tmds_d0_p),
    .O_tmds_ch1_p(O_tmds_d1_p),
    .O_tmds_ch2_p(O_tmds_d2_p),
    .O_tmds_clk_p(O_tmds_clk_p)
);

startup_pulse #(
    .CNT_MAX(20'd100000) // 等多少个时钟再打脉冲
                                          // 100000 @ 40MHz = 2.5ms
) startup_pulse (
    .I_clk(I_pixel_clk),
    .I_rst(I_rst),
    .O_pulse(edid_read_trig)
);




endmodule
