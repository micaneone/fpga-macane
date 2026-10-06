// ============================================================
//  模块名 : video_timing
//  作用   : 产生行场时序 —— hs / vs / de，以及可见区坐标 x / y
//  层次   : 显示链 第 2 层      时钟 → 【时序】 → 内容 → 输出
//  时钟域 : pixel_clk（由 PLL 给出：800x600@60 → 40MHz）
//  原理   : 见 ../原理-显示链.md 第 3 节（计时参数、计数器原理、极性的来历）
// ------------------------------------------------------------
//  建议的接口契约（叫什么名字、带不带复位都由你定，但建议动手前先定死）
//    input         clk      像素时钟（40MHz for 800x600@60）
//    input         rst_n    复位，低有效（外面用 rst_n & locked 合成后再进来）
//    output        hs       行同步（极性随分辨率：800x600 是正极性，见 HS_POL）
//    output        vs       场同步（极性随分辨率：800x600 是正极性，见 VS_POL）
//    output        de       像素有效，可见区为 1
//    output [11:0] x        可见区内横坐标 0..pic_wide-1（de 为 1 时才有意义）
//    output [11:0] y        可见区内纵坐标 0..pic_high-1（de 为 1 时才有意义）
//
//  验收标准（先把 testbench 写好，再写模块）
//    · 一帧总拍数 = 800 x 525
//    · 每行里 de 连续 640 拍，其余 160 拍按 前肩16 / 同步96 / 后肩48 分
//    · hs 每 800 拍来一次、宽 96 拍；vs 每 525 行来一次、宽 2 行
//    · de 有效时 x 从 0 数到 639，y 从 0 数到 479
//    · 行频 = 25MHz / 800 = 31.25kHz，场频 = 31.25kHz / 525 = 59.5Hz
// ------------------------------------------------------------
//  下面由你自己写。本文件故意是空的（只有注释），没有骨架。
// ============================================================
module video_timing #(
    parameter  [10:0]pic_wide=640,
    parameter  [9:0]pic_high=480
) (
    input clk,
    input rst_n,
    output hs,
    output vs,
    output de,
    output [11:0] x,
    output [11:0] y
);

// ============================================================
//  分辨率参数（按 pic_wide 自动选一档）
//    640x480  配 25.000MHz 像素时钟（@60，总长  800x525，负/负极性）
//    800x600  配 40.000MHz 像素时钟（@60，总长 1056x628，正/正极性）← 现在用这一档
//    1024x768 配 75.000MHz 像素时钟（@70，总长 1328x806，正/正极性）
//              ★ 这些数字只能整组换，不能只换一半：
//                 像素时钟换了、后肩不跟着换，刷新率就不标准，显示器可能不认
//                 800x600   : 40 + 128 + 800 + 88  = 1056，40MHz/1056/628 = 60.3Hz
//                 1024x768@60/70 的后肩分别是 160 / 144，也不是同一个数
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

// ---------------------- 同步极性 ----------------------
//  0 = 负极性（同步期间输出 0）   1 = 正极性（同步期间输出 1）
//    640x480@60  → 负/负
//    800x600@60  → 正/正     ← VESA DMT（这一档是正的，别照抄 640 的写法）
//    1024x768@70 → 负/负
//  ★ HDMI 这一路其实用不到这两个极性：核自己按 HTOTAL/HSA/HFP/HBP 生成
//    TMDS 里的同步控制字符，我们只把 vs 当作"帧首"标记（只看跳变，不看极性）。
//    把极性写正确是为了 VGA 那条备用通路（vga_out.v）。
//    证据：640x480@60 和 1024x768@70 用负极性都在同一块屏上出图了，说明
//    HDMI 这一路对极性不敏感；极性只在走 VGA 时才真的影响几何位置。
localparam HS_POL = (RES_ID == RES_800x600) ? 1'b1 : 1'b0;
localparam VS_POL = (RES_ID == RES_800x600) ? 1'b1 : 1'b0;


// ---------------------- 时序控制 ----------
reg [11:0] h_cnt;  // 行计数器
reg [11:0] v_cnt;  // 场计数器

// "处在同步段里"的中间信号，最后再按 HS_POL / VS_POL 决定是取反还是原样
wire hs_sync = (h_cnt>=HPORCH+pic_wide && h_cnt<HPORCH+pic_wide+HSYNC_W);
wire vs_sync = (v_cnt>=VPORCH+pic_high && v_cnt<VPORCH+pic_high+VSYNC_W);

assign hs = HS_POL ? hs_sync : ~hs_sync;
assign vs = VS_POL ? vs_sync : ~vs_sync;
assign de = (h_cnt<pic_wide && v_cnt<pic_high);
assign x  = de ? h_cnt : 12'd0;
assign y  = de ? v_cnt : 12'd0;

    always @(posedge clk ) begin
        if(rst_n==1'b0) begin
            h_cnt<=12'b0;
            v_cnt<=12'b0;
    end
    else begin
        if(h_cnt==H_TOTAL-1) begin
            h_cnt<=12'b0;
            if(v_cnt==V_TOTAL-1) begin
                v_cnt<=12'b0;
            end
            else v_cnt<=v_cnt+1;
        end
        else begin
            h_cnt<=h_cnt+1;
        end
    end
    end
endmodule
