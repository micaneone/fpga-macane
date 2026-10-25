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
//  ★★★ 2026-10-25【时序 · 三级流水】(P0-1 的续)
//    P0-1 把 scaler 行地址流水化以后，像素域剩下的唯一真违例是**本模块的算术链**：
//      u_scaler/b_u_first_w[10] → … → u_zoom/b_off_v[18]
//      Data 26.178 ns / 预算 25 ns / 11 级（3×MULT18 + 多个 ADDER + LUT）
//    根因：整条链（win_w×src_h、win_h×src_w → 比较 → ×K → 取 step
//      → win_w×step、win_h×step → 减/移 → off）挤在一个 40 MHz 周期里。
//    改法：切成 3 级流水，每级至多一条乘法链：
//      ① 级：两个交叉乘积 win_w*src_h / win_h*src_w（并行）+ 输入打拍；
//      ② 级：比较取限制轴 → ×K(≈2^24/win) → step_fit/step_calc 打拍；
//      ③ 级：step→Q4.12 → 两个"窗口×step"乘法（并行）→ off_u/off_v，输出打拍。
//    latency = 3 clk_pix。输入只在"换图 / 换档 / 相位切换"时变（zoom_dual 每
//    256 拍才锁存一次输出），3 拍延迟肉眼不可见；功能等价由
//    sim/tb_zoom_pipe.v 与旧实现（zoom_sel_ref）逐拍对拍验证。
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

    output reg  [31:0]        step_q16,
    output reg  signed [31:0] off_u_q16,
    output reg  signed [31:0] off_v_q16,
    output reg                bilin_en,

    // ---- 诊断 ----
    output reg  [31:0] step_fit_q16,   // 适配档算出来的 step（串口/调试看）
    output wire        fit_busy        // 除法器已在 2026-10-17 删掉，恒 0
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
    //
    //  ★★★ 2026-10-17【去面积 · 整只删掉除法器】
    //    "适配"档要算  step = (num << 16) / den ，
    //    而 `win_w/win_h` 在本工程里是**常数**（顶层窗口表 `WIN_W(800)/WIN_H(600)`
    //    ⇒ stub_win_table 把它们直连成常数口）⇒ 这是**除以常数**，不需要除法器：
    //        q = (num << 16) / den ≈ (num * K) >> 8 ，  K = round(2^24 / den)
    //          den = 800 ⇒ K = 20972   （2^24/800  = 20971.52）
    //          den = 600 ⇒ K = 27962   （2^24/600  = 27962.03）
    //    误差 ≤ num × (0.5/2^24) ≈ 1e-4 LSB（Q16.16 的 1 LSB = 1/65536 像素）⇒ 不可见。
    //    代价：12×15 的常数乘（落 1 个 DSP / 几个移位加法）；
    //    收益：`udiv_q16_up`（176 LE）连同 div_start/need_fit/changed 那一整套
    //          握手与变化检测一起删掉（实测 u_zoom 471 → 约 300 LE）。
    //    ★ 语义变化：原来是"除法器算完再锁存（fit_busy 期间 zoom_dual 不锁存）"，
    //      现在纯组合、随时有效 ⇒ `fit_busy` 恒 0，zoom_dual 的 `!z_busy` 恒真。
    //    ★ 源尺寸非法（0）时仍退回 Z=1 的安全值，和原来 `step_fit` 复位值同口径。
    // ============================================================
    localparam [14:0] K_DEN800 = 15'd20972;
    localparam [14:0] K_DEN600 = 15'd27962;

    // ============================================================
    //  第 1 级流水：输入打拍 + 两个交叉乘积（并行）
    // ============================================================
    reg [2:0]  r1_level;
    reg [11:0] r1_src_w, r1_src_h, r1_win_w, r1_win_h;
    reg [23:0] r1_cmp_w, r1_cmp_h;      // win_w*src_h / win_h*src_w
    reg        r1_dims_ok;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            r1_level   <= 3'd0;
            r1_src_w   <= 12'd0;
            r1_src_h   <= 12'd0;
            r1_win_w   <= 12'd0;
            r1_win_h   <= 12'd0;
            r1_cmp_w   <= 24'd0;
            r1_cmp_h   <= 24'd0;
            r1_dims_ok <= 1'b0;
        end
        else begin
            r1_level   <= level;
            r1_src_w   <= src_w;
            r1_src_h   <= src_h;
            r1_win_w   <= win_w;
            r1_win_h   <= win_h;
            r1_cmp_w   <= win_w * src_h;
            r1_cmp_h   <= win_h * src_w;
            r1_dims_ok <= (src_w != 12'd0) && (src_h != 12'd0) &&
                          (win_w != 12'd0) && (win_h != 12'd0);
        end
    end

    // ============================================================
    //  第 2 级流水：限制轴比较 → ×K → step_fit / step_calc
    // ============================================================
    wire        width_lim1 = (r1_cmp_w < r1_cmp_h);      // 宽是限制轴
    wire [11:0] fit_num1   = width_lim1 ? r1_src_w : r1_src_h;
    wire [14:0] fit_k1     = width_lim1 ? K_DEN800 : K_DEN600;
    wire [26:0] fit_prd1   = fit_num1 * fit_k1;          // 12×15 ⇒ 27 位
    wire [31:0] step_fit1  = r1_dims_ok ? ({5'd0, fit_prd1} >> 8) : 32'd65536;

    reg [31:0] step_tbl1;
    always @(*) begin
        case (r1_level)
            3'd1:    step_tbl1 = 32'h00010000;   // 1.0x
            3'd2:    step_tbl1 = 32'h0000AAAB;   // 1.5x
            3'd3:    step_tbl1 = 32'h00008000;   // 2.0x
            3'd4:    step_tbl1 = 32'h00005555;   // 3.0x
            3'd5:    step_tbl1 = 32'h00004000;   // 4.0x
            default: step_tbl1 = 32'h00010000;   // 适配档由 step_fit 覆盖
        endcase
    end

    wire [31:0] step_calc1 = (r1_level == 3'd0) ? step_fit1 : step_tbl1;

    reg [31:0] r2_step, r2_step_fit;
    reg [11:0] r2_src_w, r2_src_h, r2_win_w, r2_win_h;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            r2_step     <= 32'd65536;
            r2_step_fit <= 32'd65536;
            r2_src_w    <= 12'd0;
            r2_src_h    <= 12'd0;
            r2_win_w    <= 12'd0;
            r2_win_h    <= 12'd0;
        end
        else begin
            r2_step     <= step_calc1;
            r2_step_fit <= step_fit1;
            r2_src_w    <= r1_src_w;
            r2_src_h    <= r1_src_h;
            r2_win_w    <= r1_win_w;
            r2_win_h    <= r1_win_h;
        end
    end

    // ============================================================
    //  第 3 级流水：step + 居中偏移（两个乘法并行）
    // ============================================================
    // ★★★ 2026-10-03 乘法器瘦身（和 scaler_addr 同一套，为四窗口腾 DSP）：
    //   ★ `src_w * 65536` 是【常数乘】→ 写成左移 16 位，0 个 DSP。
    //   ★ win_w/win_h 收成 10 位（≤800），step 换成【Q4.12 窄定点】（同 scaler_addr，
    //     理由见那边：TD 的成本由 32 位那个操作数撑着，只有把 step 压到 16 位，
    //     一次乘法才落进 1 个 DSP；Q4.12 的范围/精度都是够的）。
    wire [15:0] zs12 = (r2_step[31:20] != 0) ? 16'hFFFF : r2_step[19:4];
    wire [25:0] wu26 = r2_win_w[9:0] * zs12;    // ≤ 799×65535 < 2^26（Q4.12）
    wire [25:0] wv26 = r2_win_h[9:0] * zs12;

    wire signed [31:0] wu = {2'd0, wu26, 4'b0000};   // Q4.12 → Q16.16
    wire signed [31:0] wv = {2'd0, wv26, 4'b0000};
    wire signed [31:0] hu = $signed({20'd0, r2_src_w}) <<< 16;   // = src_w * 65536
    wire signed [31:0] hv = $signed({20'd0, r2_src_h}) <<< 16;

    wire signed [31:0] off_u_c = (hu - wu) >>> 1;      // (src_w*65536 - win_w*step)/2
    wire signed [31:0] off_v_c = (hv - wv) >>> 1;      // 算术右移：负数也对

    // Z >= 1（放大或 1:1）用双线性；Z < 1（缩小）用最近邻
    wire bilin_c = (r2_step <= 32'd65536);

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            step_q16     <= 32'd65536;
            off_u_q16    <= 32'sd0;
            off_v_q16    <= 32'sd0;
            bilin_en     <= 1'b1;
            step_fit_q16 <= 32'd65536;
        end
        else begin
            step_q16     <= r2_step;
            off_u_q16    <= off_u_c;
            off_v_q16    <= off_v_c;
            bilin_en     <= bilin_c;
            step_fit_q16 <= r2_step_fit;
        end
    end

    // 除法器已删（2026-10-17），恒不忙
    assign fit_busy = 1'b0;

endmodule
