// ============================================================
//  模块名 : zoom_sel
//  作用   : 【档位 -> 缩放参数】—— 给 scaler_addr 提供 step（1/Z）和居中偏移
//  时钟域 : 像素域 40 MHz
//  依据   : 规划\B轨缩放器设计说明.md §4
// ------------------------------------------------------------
//  档位（按键循环）：
//    0 = 适配：整张图等比缩进窗口、居中（Z_fit = min(win_w/src_w, win_h/src_h)）
//    1 = 1.0x    2 = 1.5x    3 = 2.0x    4 = 3.0x    5 = 4.0x
//
//  三个输出：
//    step_q16   —— 每个屏幕像素走多少个源像素（Q16.16），给 scaler_addr
//    off_u/off_v—— 窗口左上角对应的源坐标（Q16.16），用来把图摆正、居中
//    bilin_en   —— 1 = 放大/1:1，用双线性；0 = 缩小，用最近邻抽点
//
//  ★ 居中偏移的公式（不需要除法）：
//      显示出来的宽度 = src_w·Z = src_w/step（step 是"每屏幕像素走多少源像素"）
//      屏幕上的左边距 m = (win_w − src_w/step)/2
//      图左边缘(u=0)要落在 x'=m 处：off_u + m·step = 0
//        ⇒ off_u = −m·step = (src_w·65536 − win_w·step) / 2
//    垂直同理。★ 符号要认准：图比窗口小（缩小）时 off 是【负】的
//    （窗口左边缘已经在源图左边外面，u<0 → 显示底色）；
//    图比窗口大（放大）时 off 是【正】的（窗口看到的是源图中间一块）。
//
//  ★ 唯一需要除法的只有"适配"档：Z_fit = min(两个比值)，
//    用交叉相乘比大小（不用除法），只有最后那一次真值用 udiv_q16_up
//    （★ 向上取整 —— 保证整张图一定放得下，见那个模块的文件头）。
//    触发点 = 档位/源尺寸/窗口尺寸变化（换图或换档），不是每帧。
// ============================================================
`timescale 1ns / 1ps

module zoom_sel (
    input  wire        clk_pix,
    input  wire        rst_pix_n,

    input  wire [2:0]  level,       // 0=适配 1=1x 2=1.5x 3=2x 4=3x 5=4x
    input  wire [11:0] src_w,
    input  wire [11:0] src_h,
    input  wire [11:0] win_w,
    input  wire [11:0] win_h,

    output wire [31:0]        step_q16,
    output wire signed [31:0] off_u_q16,
    output wire signed [31:0] off_v_q16,
    output wire               bilin_en,

    // ---- 诊断 ----
    output wire [31:0] step_fit_q16,   // 适配档算出来的 step（串口/调试看）
    output wire        fit_busy        // 除法器在跑
);

    // ============================================================
    //  档位表（由 工程代码\tools\zoom_levels.py 生成，别手改）
    //    step_q16 = round(65536 / Z)
    // ============================================================
    reg [31:0] step_tbl;
    always @(*) begin
        case (level)
            3'd1:    step_tbl = 32'h00010000;   // 1.0x
            3'd2:    step_tbl = 32'h0000AAAB;   // 1.5x
            3'd3:    step_tbl = 32'h00008000;   // 2.0x
            3'd4:    step_tbl = 32'h00005555;   // 3.0x
            3'd5:    step_tbl = 32'h00004000;   // 4.0x
            default: step_tbl = 32'h00010000;   // 适配档由 step_fit 覆盖
        endcase
    end

    // ============================================================
    //  "适配"档：先决定哪一边是限制轴（交叉相乘，不做除法）
    //    win_w/src_w < win_h/src_h  <=>  win_w*src_h < win_h*src_w
    // ============================================================
    //   ★ 交叉相乘的两边别写反：
    //       宽是限制轴 <=> win_w/src_w < win_h/src_h <=> win_w*src_h < win_h*src_w
    wire [23:0] cmp_w   = win_w * src_h;
    wire [23:0] cmp_h   = win_h * src_w;
    wire        width_lim = (cmp_w < cmp_h);      // 宽是限制轴
    wire [15:0] fit_num = width_lim ? {4'd0, src_w} : {4'd0, src_h};
    wire [15:0] fit_den = width_lim ? {4'd0, win_w} : {4'd0, win_h};
    wire        dims_ok = (src_w != 12'd0) && (src_h != 12'd0) &&
                          (win_w != 12'd0) && (win_h != 12'd0);

    // ---- 除法器：只算 (fit_num<<16)/fit_den ----
    reg         div_start;
    wire [31:0] div_q;
    wire        div_done, div_busy;
    reg  [31:0] step_fit;

    assign step_fit_q16 = step_fit;
    assign fit_busy     = div_busy;

    udiv_q16_up u_div (
        .clk(clk_pix), .rst_n(rst_pix_n),
        .start(div_start), .a(fit_num), .b(fit_den),
        .q(div_q), .done(div_done), .busy(div_busy)
    );

    // ---- 输入变化检测：变了就重算一次适配值 ----
    reg  [2:0]  lv_d;
    reg  [11:0] sw_d, sh_d, ww_d, wh_d;
    reg         need_fit;

    wire changed = (level !== lv_d) || (src_w !== sw_d) || (src_h !== sh_d) ||
                   (win_w !== ww_d) || (win_h !== wh_d);

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            div_start <= 1'b0;
            need_fit  <= 1'b0;
            step_fit  <= 32'd65536;      // 除法完成前先按 Z=1
            lv_d <= 3'd7;
            sw_d <= 12'd0; sh_d <= 12'd0; ww_d <= 12'd0; wh_d <= 12'd0;
        end
        else begin
            div_start <= 1'b0;

            if (changed) begin
                lv_d <= level;
                sw_d <= src_w; sh_d <= src_h; ww_d <= win_w; wh_d <= win_h;
                // 源尺寸/窗口一变就先算好，用户切到"适配"档时不用等
                if (dims_ok) need_fit <= 1'b1;
            end

            if (need_fit && !div_busy) begin
                div_start <= 1'b1;
                need_fit  <= 1'b0;
            end

            if (div_done) step_fit <= div_q;
        end
    end

    // ============================================================
    //  输出：step + 居中偏移
    // ============================================================
    wire [31:0] step_calc = (level == 3'd0) ? step_fit : step_tbl;
    assign step_q16 = step_calc;

    // ★★★ 2026-10-03 乘法器瘦身（和 scaler_addr 同一套，为四窗口腾 DSP）：
    //   ★ `src_w * 65536` 是【常数乘】→ 写成左移 16 位，0 个 DSP。
    //   ★ win_w/win_h 收成 10 位（≤800），step 换成【Q4.12 窄定点】（同 scaler_addr，
    //     理由见那边：TD 的成本由 32 位那个操作数撑着，只有把 step 压到 16 位，
    //     一次乘法才落进 1 个 DSP；Q4.12 的范围/精度都是够的）。
    wire [15:0] zs12 = (step_calc[31:20] != 0) ? 16'hFFFF : step_calc[19:4];
    wire [25:0] wu26 = win_w[9:0] * zs12;    // ≤ 799×65535 < 2^26（Q4.12）
    wire [25:0] wv26 = win_h[9:0] * zs12;

    wire signed [31:0] wu = {2'd0, wu26, 4'b0000};   // Q4.12 → Q16.16
    wire signed [31:0] wv = {2'd0, wv26, 4'b0000};
    wire signed [31:0] hu = $signed({20'd0, src_w}) <<< 16;   // = src_w * 65536
    wire signed [31:0] hv = $signed({20'd0, src_h}) <<< 16;

    assign off_u_q16 = (hu - wu) >>> 1;      // (src_w*65536 - win_w*step)/2
    assign off_v_q16 = (hv - wv) >>> 1;      // 算术右移：负数也对

    // Z >= 1（放大或 1:1）用双线性；Z < 1（缩小）用最近邻
    assign bilin_en = (step_calc <= 32'd65536);

endmodule
