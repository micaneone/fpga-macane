// ============================================================
//  模块名 : menu_ovl_cn —— 【参数菜单面板 + 汉字标签】（像素流水第 ④' 级）
//  层次   : `subtitle_ovl` 之后、RGB565→RGB888 之前（disp_top 里压在最上面那一层）
//  时钟域 : 单域 —— clk_pix（40 MHz），和 subtitle_ovl 的像素侧同一个域
// ------------------------------------------------------------
//  ★ 和 menu_ovl 的关系（2026-10-21 起）
//      menu_ovl.v   = 5×7 点阵 + TXT_SCALE 放大 + `>` 光标（ZOOM/AUDIO/... 英文）
//      menu_ovl_cn.v= 24×24 点阵、标签改用**汉字**（尺寸/音轨/音量/亮度），
//                     选中行改用**整行方框**（不再有 `>` 光标 —— 24 px 的字旁边放
//                     `>` 反而更乱）。
//      两个模块**端口逐个相同**（除 menu_ovl 的 `viz_on` 已在 D1 删除），
//      `disp_top.v` 里只换例化的模块名 + 文件表；menu_ovl.v 留着做回退。
//
//  ★ 为什么汉字要自己带字模（三次踩坑的总结）
//      ① `$readmemh` 给 BRAM 的初值不一定进比特流 ⇒ 2026-10-21 实测屏上字全空；
//      ② 用户给的 font.mem 只有 亮度/对比/尺寸/图 这 4 个词（音/轨/量 没有）；
//      ③ 16×16 从轮廓字体栅格化，缩/量/轨 笔画粘连（预览已废）。
//      ⇒ 定案：**纯组合 case 的 24×24 点阵**（`b_display/font_cn.v`，408 个 24 位字，
//        综合成 ~600 个 LUT4），字形由 `.tmp_py\gen_font_cn.py` 从 simsun 24px 生成。
//
//  ★ 硬约束（和 menu_ovl 同一条）：**面板外一个像素都不许改**
//      `menu_on=0` ⇒ 所有 draw_* 为 0 ⇒ `px_out == px_in`（逐位）。
//
//  ★ 层级（高者覆盖低者，同一像素只命中一层）
//        ① 文字（CLR_INK）      ← 只在字形点灯处覆盖
//        ② 行分隔线（CLR_SEP）
//        ③ 外框（CLR_FRAME）
//        ④ 选中行方框/高亮（CLR_SEL）
//        ⑤ 面板底（CLR_PANEL）  ← 不透明铺满，挡住照片
//
//  ★ 版面（全部是文件头常量，改位置只动这几个数）
//      面板 320×200 居中（240,200），4 行 × 行高 50
//      一行内容： [汉字][汉字]  空隙 12px  [数字][数字]
//                字形 24×24，行内垂直居中 ⇒ TOP_OFF = (50-24)/2 = 13
//      字符列 X0 = 346（= 面板左 240 + 左缩进 106），四个字格在 346/370/394/418
// ============================================================
`timescale 1ns / 1ps

module menu_ovl_cn #(
    parameter integer SCR_W  = 800,
    parameter integer SCR_H  = 600,
    parameter integer PANEL_W = 320,
    parameter integer PANEL_H = 200,
    parameter integer ROW_N   = 4,      // ★ 必须和 top_m2 的 MENU_N 一致
    parameter integer FRAME_T = 2,      // 外框粗细
    // ---- 颜色（RGB565）----
    parameter [15:0] CLR_PANEL = 16'h4104,   // 面板底 深灰
    parameter [15:0] CLR_FRAME = 16'hFFFF,   // 外框 近白
    parameter [15:0] CLR_SEP   = 16'h8410,   // 分隔线 中灰
    parameter [15:0] CLR_SEL   = 16'h20FF,   // 选中行 亮蓝
    parameter [15:0] CLR_INK   = 16'hFFC2,   // 文字 亮黄白
    // ---- 字形 ----
    parameter integer CELL    = 24,     // 字形边长（= font_cn 的口径）
    parameter integer TXT_X0  = 346,    // 第一个字格左边（屏幕坐标）
    parameter integer TOP_OFF = 13      // 行内垂直居中：(ROW_H - CELL)/2
)(
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire [11:0] x_in,
    input  wire [11:0] y_in,
    input  wire [15:0] px_in,
    output reg  [15:0] px_out,
    output reg         de_out,
    output reg         vs_out,

    // ---------------- 菜单状态（慢变电平，顶层已同步到 clk_pix）----------------
    input  wire        menu_on,
    input  wire [2:0]  menu_sel,      // 选中行 0..3
    // ---------------- 要显示的"活值"（只读，绝不写回）----------------
    input  wire [2:0]  zoom_lv,       // 0..5
    input  wire [1:0]  sel_aud,       // 0..3 ⇒ 显示 sel_aud+1 = 1..4
    input  wire [3:0]  vol_lv,        // 0..15
    input  wire [3:0]  bri_lv         // 0..15
);

    // ============================================================
    //  0. 版面常量
    // ============================================================
    localparam integer PANEL_X0 = (SCR_W - PANEL_W) / 2;   // 240
    localparam integer PANEL_Y0 = (SCR_H - PANEL_H) / 2;   // 200
    localparam integer PANEL_X1 = PANEL_X0 + PANEL_W;      // 560（右开）
    localparam integer PANEL_Y1 = PANEL_Y0 + PANEL_H;      // 400（右开）
    localparam integer ROW_H    = PANEL_H / ROW_N;         // 50

    localparam integer TXT_Y0   = PANEL_Y0 + TOP_OFF;      // 213：第 0 行字格顶

    localparam integer HIL_H    = CELL + 8;                // 32
    localparam integer HIL_TOP  = (ROW_H - HIL_H) / 2;     // 9
    localparam integer HIL_BOT  = HIL_TOP + HIL_H;         // 41

    // 字格序号 0..3 的左边（相对 TXT_X0）
    localparam integer G1 = CELL;        // 24
    localparam integer G2 = CELL * 2;    // 48
    localparam integer G3 = CELL * 3;    // 72
    localparam integer G4 = CELL * 4;    // 96
    localparam integer G5 = CELL * 5;    // 120
    localparam integer G6 = CELL * 6;    // 144
    localparam integer GW = CELL * 7;    // 168（七个字格：标签 2 + 空 1 + 数值最多 4）

    // 汉字序号（和 font_cn.v 的字形表一致）
    localparam [4:0] CH_BLANK = 5'd31;   // 字形表里没有 ⇒ 全 0 ⇒ 空
    localparam [4:0] CH_0     = 5'd0;
    localparam [4:0] CH_PCT   = 5'd17;   // '%'（2026-10-21：音量/亮度按百分比显示）

    // ============================================================
    //  1. 打一拍：坐标跟着数据一起走
    // ============================================================
    reg        de_p, vs_p;
    reg [11:0] x_p, y_p;
    reg [15:0] px_p;

    always @(posedge clk_pix) begin
        de_p <= de_in;
        vs_p <= vs_in;
        x_p  <= x_in;
        y_p  <= y_in;
        px_p <= px_in;
    end

    // ============================================================
    //  2. 几何：行号 / 行顶 / 行内坐标
    // ============================================================
    wire [11:0] yl = y_p - PANEL_Y0[11:0];

    wire [2:0] row_now = (yl >= ROW_H * 3) ? 3'd3 :
                         (yl >= ROW_H * 2) ? 3'd2 :
                         (yl >= ROW_H * 1) ? 3'd1 : 3'd0;

    wire [11:0] row_top = PANEL_Y0[11:0] + ROW_H * row_now;

    wire in_panel = (x_p >= PANEL_X0) && (x_p < PANEL_X1) &&
                    (y_p >= PANEL_Y0) && (y_p < PANEL_Y1);

    wire on_edge  = (x_p <  (PANEL_X0 + FRAME_T)) || (x_p >= (PANEL_X1 - FRAME_T)) ||
                    (y_p <  (PANEL_Y0 + FRAME_T)) || (y_p >= (PANEL_Y1 - FRAME_T));

    wire in_sep   = (y_p == (PANEL_Y0 + ROW_H * 1 - 1)) ||
                    (y_p == (PANEL_Y0 + ROW_H * 2 - 1)) ||
                    (y_p == (PANEL_Y0 + ROW_H * 3 - 1));

    wire [11:0] hy = y_p - row_top;
    wire in_hilite = (row_now == menu_sel) && (hy >= HIL_TOP) && (hy < HIL_BOT);

    // ---- 文字格：横向 [TXT_X0, TXT_X0+96)，纵向 [row_top+TOP_OFF, +24) ----
    wire [11:0] rx = x_p - TXT_X0[11:0];
    wire [11:0] ry = y_p - (row_top + TOP_OFF);

    wire in_gly_x = in_panel && (x_p >= TXT_X0) && (rx < GW);
    wire in_gly_y = (ry < CELL);
    wire in_gly   = in_gly_x && in_gly_y;

    wire [2:0] gx = (rx >= G6) ? 3'd6 :
                    (rx >= G5) ? 3'd5 :
                    (rx >= G4) ? 3'd4 :
                    (rx >= G3) ? 3'd3 :
                    (rx >= G2) ? 3'd2 :
                    (rx >= G1) ? 3'd1 : 3'd0;

    wire [4:0] lx = (gx == 3'd0) ? rx[4:0] :
                    (gx == 3'd1) ? (rx - G1) :
                    (gx == 3'd2) ? (rx - G2) :
                    (gx == 3'd3) ? (rx - G3) :
                    (gx == 3'd4) ? (rx - G4) :
                    (gx == 3'd5) ? (rx - G5) :
                                   (rx - G6);

    // 字形 ROM 行序是"自下而上"（row=0 在屏幕最下面）
    wire [4:0] gy = 5'd23 - ry[4:0];

    // ============================================================
    //  3. 内容表：字格 0/1 = 标签（汉字），字格 2/3 = 数值（十进制两位）
    // ============================================================
    reg [4:0] lab0, lab1;
    always @(*) begin
        case (row_now)
            3'd0: begin lab0 = 5'd10; lab1 = 5'd11; end   // 缩 放
            3'd1: begin lab0 = 5'd12; lab1 = 5'd13; end   // 音 轨
            3'd2: begin lab0 = 5'd12; lab1 = 5'd14; end   // 音 量
            default: begin lab0 = 5'd15; lab1 = 5'd16; end// 亮 度
        endcase
    end

    // 数值：缩放/音轨 = 一位数字；音量/亮度 = 百分比（0% / 50% / 100%）
    //   ★ 2026-10-21：音量、亮度改成 0..10 档、每档 10%，显示成 "50%"
    //   字格 0/1 = 标签，2 = 固定空白（分隔），3..6 = 数值右对齐（最右 6 格放 '%'）
    //   ⇒ "0%" 占 5/6、"50%" 占 4/5/6、"100%" 占 3/4/5/6，不用除法（档位就是十位数）
    reg [4:0] v_c3, v_c4, v_c5, v_c6;
    reg [4:0] lv10;
    always @(*) begin
        v_c3 = CH_BLANK; v_c4 = CH_BLANK; v_c5 = CH_BLANK; v_c6 = CH_BLANK;
        case (row_now)
            3'd0: v_c6 = CH_0 + {2'b00, zoom_lv};              // 0..5 适配/1x/1.5x/2x/3x/4x
            3'd1: v_c6 = CH_0 + ({2'b00, sel_aud} + 5'd1);     // 1..4 第几条音轨
            default: begin
                lv10 = (row_now == 3'd2) ? {1'b0, vol_lv} : {1'b0, bri_lv};   // 0..10
                v_c6 = CH_PCT;
                v_c5 = CH_0;                                   // 个位恒 0（10% 一档）
                if (lv10 == 5'd10) begin                       // 100%
                    v_c3 = CH_0 + 5'd1;
                    v_c4 = CH_0;
                end
                else if (lv10 != 5'd0) begin                   // 10%..90%
                    v_c4 = CH_0 + lv10;
                end
            end
        endcase
    end

    wire [4:0] g_ch = (gx == 3'd0) ? lab0 :
                      (gx == 3'd1) ? lab1 :
                      (gx == 3'd2) ? CH_BLANK :
                      (gx == 3'd3) ? v_c3 :
                      (gx == 3'd4) ? v_c4 :
                      (gx == 3'd5) ? v_c5 : v_c6;

    // ============================================================
    //  4. 字形 ROM
    // ============================================================
    wire font_px;
    font_cn u_font (
        .ch  (g_ch),
        .row (gy),
        .col (lx),
        .px  (font_px)
    );

    // ============================================================
    //  5. 合成（优先级见文件头）
    // ============================================================
    wire draw_text  = menu_on && in_gly && font_px;
    wire draw_sep   = menu_on && in_panel && !on_edge && in_sep;
    wire draw_frame = menu_on && in_panel && on_edge;
    wire draw_sel   = menu_on && in_panel && !on_edge && !in_sep && in_hilite;
    wire draw_base  = menu_on && in_panel && !on_edge && !in_sep && !in_hilite;

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            px_out <= 16'h0000;
            de_out <= 1'b0;
            vs_out <= 1'b0;
        end else begin
            de_out <= de_p;
            vs_out <= vs_p;
            if (draw_text)       px_out <= CLR_INK;
            else if (draw_sep)   px_out <= CLR_SEP;
            else if (draw_frame) px_out <= CLR_FRAME;
            else if (draw_sel)   px_out <= CLR_SEL;
            else if (draw_base)  px_out <= CLR_PANEL;
            else                 px_out <= px_p;
        end
    end

endmodule
