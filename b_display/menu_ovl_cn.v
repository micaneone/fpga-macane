// ============================================================
//  模块名 : menu_ovl_cn —— 【参数菜单：左上角 4 个独立小格 + 汉字标签】（像素流水第 ④' 级）
//  层次   : `subtitle_ovl` 之后、RGB565→RGB888 之前（disp_top 里压在最上面那一层）
//  时钟域 : 单域 —— clk_pix（40 MHz），和 subtitle_ovl 的像素侧同一个域
// ------------------------------------------------------------
//  ★ 2026-10-24【版式改版：中心大面板 → 左上角 4 个独立小格】
//      用户要求："把菜单的每一格都拆分，在屏幕左上角显示"；样式取"纯描边、不要大底色"
//      ⇒ 不再有 320x200 的大面板/不透明底；4 行各成一个独立小格（描边框 + 汉字标签 + 数值），
//        竖排在屏幕左上角；选中行用亮蓝色更粗的描边（3px），未选中行 1px 暗灰描边。
//      面板外一个像素都不许改（`menu_on=0` ⇒ 所有 draw_* 为 0 ⇒ `px_out == px_in`）。
//
//  版面（全部是文件头常量，改位置只动这几个数）
//      小格 184x40，左上角起点 (12,12)，格间隙 6 ⇒ 行距 PITCH = 46
//      4 格纵向：y = 12 / 58 / 104 / 150（右下角 196,190）
//      一行内容： [汉字][汉字]  空隙 24px  [数值右对齐，最多 4 个字形]
//                字形 24x24，格内垂直居中 ⇒ TOP_OFF = (40-24)/2 = 8
//      字格 X0 = 12+8 = 20，7 个字形列（2 标签 + 1 空隙 + 4 数值）= 168 px
//
//  ★ 字符内容
//      行 0 尺寸：缩放 -> 0..5；行 1 可视：开 / 关；行 2 音量 / 行 3 亮度 -> 百分比 0%..100%
//      字形表见 b_display/font_cn.v（0..9 是七段数字，10..17 是 缩放/音轨/量/亮/度/%，18..21 是 可视开关）。
//
//  ★ 层级（高者覆盖低者，同一像素只命中一层）
//        ① 文字（CLR_INK）  ← 只在字形点灯处覆盖
//        ② 选中格描边（CLR_SEL，3px）
//        ③ 未选中格描边（CLR_FRAME，1px）
//        ④ 其余像素直通（无底色！）
// ============================================================
`timescale 1ns / 1ps

module menu_ovl_cn #(
    parameter integer SCR_W   = 800,
    parameter integer SCR_H   = 600,
    parameter integer ROW_N   = 4,      // ★ 必须和 top_m2 的 MENU_N 一致
    parameter integer CELL_X0 = 12,     // 第一个小格左上角（屏幕坐标）
    parameter integer CELL_Y0 = 12,
    parameter integer CELL_W  = 184,    // 小格宽（7 个字形列 + 左右各 8 px 内边距）
    parameter integer CELL_H  = 40,     // 小格高
    parameter integer GAP     = 6,      // 小格之间的垂直间隙
    parameter integer FRAME_T = 1,      // 未选中格：描边粗细
    parameter integer SEL_T   = 3,      // 选中格：描边粗细（更粗 ⇒ 一眼看出选中）
    // ---- 颜色（RGB565）----
    parameter [15:0] CLR_FRAME = 16'h8410,   // 未选中描边 中灰（和旧分隔线同一个灰）
    parameter [15:0] CLR_SEL   = 16'h20FF,   // 选中描边 亮蓝（和旧选中行同一个蓝）
    parameter [15:0] CLR_INK   = 16'hFFC2,   // 文字 亮黄白
    // ---- 字形 ----
    parameter integer CELL    = 24,     // 字形边长（= font_cn 的口径）
    parameter integer TXT_PAD = 8       // 小格左内边距 ⇒ 字格 X0 = CELL_X0 + TXT_PAD
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
    input  wire [1:0]  sel_aud,       // （2026-10-24 起不再显示：行 1 换成可视化开关；端口保留，disp_top 铺线不动）
    input  wire        viz_on,        // 行 1 = 音频可视化总开关（1 = 显示 / 0 = 关闭）
    input  wire [3:0]  vol_lv,        // 0..10
    input  wire [3:0]  bri_lv         // 0..10
);

    // ============================================================
    //  0. 版面常量
    // ============================================================
    localparam integer PITCH   = CELL_H + GAP;        // 46
    localparam integer TOTAL_H = ROW_N * PITCH - GAP; // 178（4 格整体高度）
    localparam integer CELL_X1 = CELL_X0 + CELL_W;    // 196（右开）
    localparam integer CELL_Y1 = CELL_Y0 + TOTAL_H;   // 190（右开）

    localparam integer TOP_OFF = (CELL_H - CELL) / 2; // 8：格内垂直居中
    localparam integer TXT_X0  = CELL_X0 + TXT_PAD;   // 20：第一个字形列左边

    // 字形列序号 0..6 的左边（相对 TXT_X0）
    localparam integer G1 = CELL;        // 24
    localparam integer G2 = CELL * 2;    // 48
    localparam integer G3 = CELL * 3;    // 72
    localparam integer G4 = CELL * 4;    // 96
    localparam integer G5 = CELL * 5;    // 120
    localparam integer G6 = CELL * 6;    // 144
    localparam integer GW = CELL * 7;    // 168（七个字格：标签 2 + 空隙 1 + 数值最多 4）

    // 汉字序号（和 font_cn.v 的字形表一致）
    localparam [4:0] CH_BLANK = 5'd31;   // 字形表里没有 ⇒ 全 0 ⇒ 空
    localparam [4:0] CH_0     = 5'd0;
    localparam [4:0] CH_PCT   = 5'd17;   // '%'
    localparam [4:0] CH_K     = 5'd18;   // '可'
    localparam [4:0] CH_S     = 5'd19;   // '视'
    localparam [4:0] CH_ON    = 5'd20;   // '开'
    localparam [4:0] CH_OFF   = 5'd21;   // '关'

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
    //  2. 几何：落在第几格 / 格内坐标
    // ============================================================
    wire [11:0] yl = y_p - CELL_Y0[11:0];             // 相对第一格顶部

    wire in_x = (x_p >= CELL_X0) && (x_p < CELL_X1);
    wire in_y = (yl < TOTAL_H);                        // y_p < CELL_Y0 时 yl 回绕成大数 ⇒ 自动排除

    wire [2:0] row_now = (yl >= PITCH * 3) ? 3'd3 :
                         (yl >= PITCH * 2) ? 3'd2 :
                         (yl >= PITCH * 1) ? 3'd1 : 3'd0;

    reg [11:0] row_top;
    always @(*) begin
        case (row_now)
            3'd1:    row_top = CELL_Y0[11:0] + PITCH;
            3'd2:    row_top = CELL_Y0[11:0] + PITCH * 2;
            3'd3:    row_top = CELL_Y0[11:0] + PITCH * 3;
            default: row_top = CELL_Y0[11:0];
        endcase
    end

    wire [11:0] yy      = y_p - row_top;               // 格内纵向坐标（0..CELL_H-1）
    wire        in_row  = (yy < CELL_H);
    wire        in_cell = in_x && in_y && in_row;

    // ---- 描边：选中格 3px 亮蓝；未选中格 1px 中灰（没有底色，格内一律直通）----
    wire b_sel  = (x_p <  (CELL_X0 + SEL_T)) || (x_p >= (CELL_X1 - SEL_T)) ||
                  (yy  <  SEL_T[11:0])       || (yy  >= (CELL_H - SEL_T));
    wire b_norm = (x_p <  (CELL_X0 + FRAME_T)) || (x_p >= (CELL_X1 - FRAME_T)) ||
                  (yy  <  FRAME_T[11:0])       || (yy  >= (CELL_H - FRAME_T));

    wire is_sel   = (row_now == menu_sel);
    wire draw_sel = menu_on && in_cell &&  is_sel && b_sel;
    wire draw_frm = menu_on && in_cell && !is_sel && b_norm;

    // ---- 文字格：横向 [TXT_X0, TXT_X0+168)，纵向 [row_top+TOP_OFF, +24) ----
    wire [11:0] rx = x_p - TXT_X0[11:0];
    wire [11:0] ry = yy  - TOP_OFF[11:0];

    wire in_gly_x = in_cell && (x_p >= TXT_X0) && (rx < GW);
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
    //  3. 内容表：列 0/1 = 标签（汉字），列 2 = 空白，列 3..6 = 数值（右对齐）
    // ============================================================
    reg [4:0] lab0, lab1;
    always @(*) begin
        case (row_now)
            3'd0: begin lab0 = 5'd10; lab1 = 5'd11; end   // 缩 放
            3'd1: begin lab0 = CH_K;  lab1 = CH_S;  end   // 可 视
            3'd2: begin lab0 = 5'd12; lab1 = 5'd14; end   // 音 量
            default: begin lab0 = 5'd15; lab1 = 5'd16; end// 亮 度
        endcase
    end

    // 数值：缩放 = 数字（0..5）；可视 = 开 / 关；音量/亮度 = 百分比（0% / 50% / 100%）
    reg [4:0] v_c3, v_c4, v_c5, v_c6;
    reg [4:0] lv10;
    always @(*) begin
        v_c3 = CH_BLANK; v_c4 = CH_BLANK; v_c5 = CH_BLANK; v_c6 = CH_BLANK;
        case (row_now)
            3'd0: v_c6 = CH_0 + {2'b00, zoom_lv};              // 0..5 适配/1x/1.5x/2x/3x/4x
            3'd1: v_c6 = viz_on ? CH_ON : CH_OFF;              // 开 / 关
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
    //  5. 合成（优先级见文件头；无底色，其余像素直通）
    // ============================================================
    wire draw_text = menu_on && in_gly && font_px;

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            px_out <= 16'h0000;
            de_out <= 1'b0;
            vs_out <= 1'b0;
        end else begin
            de_out <= de_p;
            vs_out <= vs_p;
            if (draw_text)     px_out <= CLR_INK;
            else if (draw_sel) px_out <= CLR_SEL;
            else if (draw_frm) px_out <= CLR_FRAME;
            else               px_out <= px_p;
        end
    end

endmodule
