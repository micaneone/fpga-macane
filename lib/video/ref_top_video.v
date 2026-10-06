// ============================================================
//  模块名 : top
//  作用   : 显示链顶层 —— 例化 PLL / 时序 / 内容源 / 输出级，把它们连起来
//  层次   : 顶层
//  原理   : 见 ../原理-显示链.md 第 1 节（全景图）和第 7 节（上板排错顺序）
// ------------------------------------------------------------
//  顶层要做的事（按顺序想清楚再写）
//    1. 例化 video_pll（TD 的 IP，自己生成的），拿到 pixel_clk 和 locked
//    2. 用 reset 和 locked 合成一个"干净"的复位给后面所有逻辑用
//       ★ locked 之前 pixel_clk 不稳定，不能放后面逻辑跑
//    3. 例化 video_timing，拿 hs / vs / de / x / y
//    4. 例化内容源（先 color_bar，后 pic_bram），拿到 rgb
//    5. 例化 my_hdmitop，把 rgb + vs + de 送进 HDMI（内部自己转 TMDS）
//    6. 留几个 LED 做心跳：比如 led[0] = 复位释放、led[1] = locked、
//       led[2] = 像素时钟域的分频闪烁（证明时钟真的在跑）
//
//  建议的顶层端口
//    input         clk        50MHz，引脚 R7
//    input         rst_n      引脚 A2，低有效
//    output [3:0]  led        A4 A3 C10 B12，高电平点亮
//    output        HDMI_CLK_P / HDMI_D0_P / HDMI_D1_P / HDMI_D2_P
//    output        HDMI_DDC_SCL     inout  HDMI_DDC_SDA
//
//  引脚约束别手写，照 ../原理-显示链.md 第 5 节的表抄进 src/pin.adc
//  顶层端口只要有漏约束的，TD 会报 BIT-8123 并且不生成 .bit
// ------------------------------------------------------------
//  下面由你自己写。本文件故意是空的（只有注释），没有骨架。
// ============================================================
module top (
    input         clk,
    input         rst_n,
    output [3:0]  led,

    // HDMI TMDS
    output HDMI_CLK_P,
    output HDMI_D0_P,
    output HDMI_D1_P,
    output HDMI_D2_P,
    // HDMI DDC
    output HDMI_DDC_SCL,
    inout  HDMI_DDC_SDA
);

/* 锁相环模块（PLL_0，三路输出）
//		Clock name	| Frequency 	| Phase shift
//		C0        	| 40.000000 MHZ	| 0.0000  DEG    像素时钟
//		C1        	| 100.000000MHZ	| 90.0000 DEG    并行时钟（ODDRx2 用）
//		C2        	| 200.000000MHZ	| 0.0000  DEG    串化时钟
module PLL_0 (
  refclk,
  reset,
  extlock,
  clk0_out,
  clk1_out,
  clk2_out
);
*/
wire locked;
// ============================================================
//  三路时钟（800x600@60）
//    clk_pixel =  40.000 MHz  像素时钟：时序、内容源、HDMI 核
//    clk_par   = 100.000 MHz  并行时钟：给硬 4:1 串化器（ODDRx2）
//                             ★ 这一路在 IP 生成器里 phase_shift 要填 90°
//                               （它的边沿必须落在 clk_ser 两个上升沿中间，
//                                 对齐了串化器内部会竞争，屏幕会花）
//    clk_ser   = 200.000 MHz  串化时钟 = 5 × 像素时钟
//  ★ PLL 要在 IP 生成器里重新生成成三路输出（VCO = 400MHz，÷10 / ÷4 / ÷2）
//    IP 生成器的算法（三个参考数据点反推出来的，见 src/video.sdc 第 2 节）：
//        C0  = 输入频率 × 乘系数 / 除系数      -> 40 = 50 × 4 / 5
//        VCO = C0 × C0 的分频系数              -> 400 = 40 × 10
//        Cn  = VCO / Cn 的分频系数             -> 100 = 400 / 4，200 = 400 / 2
// ============================================================
wire clk_pixel;
wire clk_par;
wire clk_ser;
PLL_0 pll (
    .refclk(clk),
    .reset(~rst_n),
    .extlock(locked),
    .clk0_out(clk_pixel),      // C0 =  40.000 MHz
    .clk1_out(clk_par),        // C1 = 100.000 MHz, 相位 90°
    .clk2_out(clk_ser)         // C2 = 200.000 MHz
);
wire sys_rst_n = rst_n & locked;

wire hs;
wire vs;
wire de;
wire [11:0] x;
wire [11:0] y;
video_timing #(
    .pic_wide(800),
    .pic_high(600)
)timing(
    .clk(clk_pixel),
    .rst_n(sys_rst_n),
    .hs(hs),
    .vs(vs),
    .de(de),
    .x(x),
    .y(y)
);


wire [23:0] rgb;
pic_bram pic (
    .clk(clk_pixel),
    .rst_n(sys_rst_n),
    .de(de),
    .x(x),
    .y(y),
    .rgb(rgb),
    .wr_en(1'b0),
    .wr_addr(14'b000000000000),
    .wr_data(24'b0)
);

my_hdmitop #(
    .DEVICE("EG"),
    .pic_wide(800),
    .pic_high(600)
) my_hdmitop (
    .I_pixel_clk(clk_pixel),
    .I_pclk(clk_par),            // ★ 并行时钟：硬 4:1 串化器要用
    .I_serial_clk(clk_ser),
    .I_rst(~sys_rst_n),          // ★ my_hdmitop 的 I_rst 是【高有效】，sys_rst_n 是低有效
    .I_vs(vs),
    .I_de(de),
    .I_rgb(rgb),
    .O_tmds_clk_p(HDMI_CLK_P),
    .O_tmds_d0_p(HDMI_D0_P),
    .O_tmds_d1_p(HDMI_D1_P),
    .O_tmds_d2_p(HDMI_D2_P),
    .O_ddc_scl(HDMI_DDC_SCL),
    .IO_ddc_sda(HDMI_DDC_SDA),
    .O_video_locked(led[3]),
    .O_edid_read_valid(),
    .O_edid_read_data()
);


// ============================================================
//  4 个 LED（上板调试用；高电平点亮）
//    led[0] : 复位中（放行后灭）
//    led[1] : PLL locked
//    led[2] : 像素时钟域心跳
//    led[3] : 上面已经接了 my_hdmitop 的 O_video_locked
// ============================================================
reg [24:0] cnt;                          // 像素时钟域分频计数器
always @(posedge clk_pixel) begin
    if (~sys_rst_n) cnt <= 25'd0;
    else            cnt <= cnt + 1'b1;
end

assign led[0] = ~sys_rst_n;              // 亮 = 正在复位
assign led[1] = locked;                  // 亮 = PLL 锁上了
assign led[2] = cnt[24];                 // 像素时钟/2^24，肉眼能看清

endmodule
