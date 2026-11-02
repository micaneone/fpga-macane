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
//  ★ 2026-10-25【P0-1c 时序：几何/查表两级流水，总延迟仍是 2 拍】
//      上一版结构是"输入打一拍（x_p/y_p）→ 一坨组合算完 → 输出打一拍"，
//      中间那一坨（y 比较→行号→标签/数值查表→字形列选择）全压在一个 40 MHz 周期里，
//      在 P0-1/P0-1b 之后它成了像素域新的最差路径（25.211 ns / 20 级，超 0.491 ns）。
//      ⇒ 现在把这一坨**整体提前到输入侧**：直接吃 x_in/y_in 算完立刻打拍（第①级），
//        第②级只剩"字模查表 + 调色输出"。总延迟**仍是 2 拍**，和上一版逐像素对齐，
//        所以 `sim/tb_menu_cn.v` 的判据/坐标窗口不用改。
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
//        ② 选中格描边（CLR_SEL 亮蓝 3px；★ 2026-10-24：KEY2 确认进入调节态后变亮红 CLR_RED，便于识别）
//        ③ 未选中格描边（CLR_FRAME，1px）
//        ④ 半透明底：格内把画面压到 50% 亮度（RGB565 没有 alpha，
//           `(px>>1)&0x7BEF` ≈ 和黑色 50% 混合，字能看清又不会完全挡住画面）
//        ⑤ 小格之外直通（逐像素不变）
// ============================================================
`timescale 1ns / 1ps

module menu_ovl_cn #(
    parameter integer SCR_W   = 1024,
    parameter integer SCR_H   = 768,
    parameter integer ROW_N   = 6,      // ★ 必须和 top_m2 的 MENU_N 一致（2026-10-25 加第 6 行「字幕」）
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
    parameter [15:0] CLR_RED   = 16'hF800,   // ★ 2026-10-24【确认后变红】KEY2 确认（进调节态）⇒ 选中格描边变亮红
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
    input  wire        menu_edit,     // ★ 2026-10-24：KEY2 确认（调节态）=1 ⇒ 选中格描边变红
    input  wire        menu_res_1024, // ★ 2026-10-25：本镜像分辨率 1=1024x768 / 0=800x600（行 4 显示用）
    input  wire        menu_sub_on,   // ★ 2026-10-25：字幕总开关（行 5 显示用；1=显示 / 0=关）
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
    // ★ 2026-10-25【菜单第 5 行：清晰（分辨率）】：字形表里新加的两个汉字
    localparam [4:0] CH_QING  = 5'd22;   // '清'
    localparam [4:0] CH_XI    = 5'd23;   // '晰'
    // ★ 2026-10-25【菜单第 6 行：字幕开关】：字形表里新加的两个汉字
    localparam [4:0] CH_ZI    = 5'd24;   // '字'
    localparam [4:0] CH_MU    = 5'd25;   // '幕'

    // ============================================================
    //  1. 第①级：几何 / 选格 / 字符表，全部在输入侧算完并打拍
    // ============================================================
    //  （直接吃 x_in / y_in，不先打 x_p/y_p —— 这样中间那一大坨组合有整整一拍可用，
    //    第②级只剩字模查表和调色。总延迟 = 2 拍，和改版之前一致。）
    wire [11:0] yl = y_in - CELL_Y0[11:0];            // 相对第一格顶部
    wire in_x = (x_in >= CELL_X0) && (x_in < CELL_X1);
    wire in_y = (yl < TOTAL_H);                       // y_in < CELL_Y0 时 yl 回绕成大数 ⇒ 自动排除

    wire [2:0] row_now = (yl >= PITCH * 5) ? 3'd5 :
                         (yl >= PITCH * 4) ? 3'd4 :
                         (yl >= PITCH * 3) ? 3'd3 :
                         (yl >= PITCH * 2) ? 3'd2 :
                         (yl >= PITCH * 1) ? 3'd1 : 3'd0;

    reg [11:0] row_top;
    always @(*) begin
        case (row_now)
            3'd1:    row_top = CELL_Y0[11:0] + PITCH;
            3'd2:    row_top = CELL_Y0[11:0] + PITCH * 2;
            3'd3:    row_top = CELL_Y0[11:0] + PITCH * 3;
            3'd4:    row_top = CELL_Y0[11:0] + PITCH * 4;
            3'd5:    row_top = CELL_Y0[11:0] + PITCH * 5;
            default: row_top = CELL_Y0[11:0];
        endcase
    end

    wire [11:0] yy      = y_in - row_top;             // 格内纵向坐标（0..CELL_H-1）
    wire        in_row  = (yy < CELL_H);
    wire        in_cell = in_x && in_y && in_row;

    // ---- 描边：选中格 3px 亮蓝；未选中格 1px 中灰（没有底色，格内一律直通）----
    wire b_sel  = (x_in < (CELL_X0 + SEL_T)) || (x_in >= (CELL_X1 - SEL_T)) ||
                  (yy  <  SEL_T[11:0])       || (yy  >= (CELL_H - SEL_T));
    wire b_norm = (x_in < (CELL_X0 + FRAME_T)) || (x_in >= (CELL_X1 - FRAME_T)) ||
                  (yy  <  FRAME_T[11:0])     || (yy  >= (CELL_H - FRAME_T));

    wire is_sel = (row_now == menu_sel);

    // ---- 文字格：横向 [TXT_X0, TXT_X0+168)，纵向 [row_top+TOP_OFF, +24) ----
    wire [11:0] rx = x_in - TXT_X0[11:0];
    wire [11:0] ry = yy   - TOP_OFF[11:0];

    wire in_gly_x = in_cell && (x_in >= TXT_X0) && (rx < GW);
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

    // ---- 内容表：列 0/1 = 标签（汉字），列 2 = 空白，列 3..6 = 数值（右对齐）----
    reg [4:0] lab0, lab1;
    always @(*) begin
        case (row_now)
            3'd0: begin lab0 = 5'd10; lab1 = 5'd11; end   // 缩 放
            3'd1: begin lab0 = CH_K;  lab1 = CH_S;  end   // 可 视
            3'd2: begin lab0 = 5'd12; lab1 = 5'd14; end   // 音 量
            3'd3: begin lab0 = 5'd15; lab1 = 5'd16; end   // 亮 度
            3'd4: begin lab0 = CH_QING; lab1 = CH_XI; end // 清 晰（分辨率）
            3'd5: begin lab0 = CH_ZI;   lab1 = CH_MU; end // 字 幕（开关）
            default: begin lab0 = CH_BLANK; lab1 = CH_BLANK; end
        endcase
    end

    // 数值：缩放 = 数字（0..5）；可视 = 开 / 关；音量/亮度 = 百分比（0% / 50% / 100%）；
    //       清晰 = 当前镜像分辨率 800 / 1024（右对齐，最多 4 个字形）
    reg [4:0] v_c3, v_c4, v_c5, v_c6;
    reg [4:0] lv10;
    always @(*) begin
        v_c3 = CH_BLANK; v_c4 = CH_BLANK; v_c5 = CH_BLANK; v_c6 = CH_BLANK;
        lv10 = 5'd0;                                   // 行 0/1/4 不用；给默认值免推 latch
        case (row_now)
            3'd0: v_c6 = CH_0 + {2'b00, zoom_lv};              // 0..5 适配/1x/1.5x/2x/3x/4x
            3'd1: v_c6 = viz_on ? CH_ON : CH_OFF;              // 开 / 关
            3'd5: v_c6 = menu_sub_on ? CH_ON : CH_OFF;         // 开 / 关（字幕）
            3'd4: begin                                        // 清晰：800 / 1024
                if (menu_res_1024) begin
                    v_c3 = CH_0 + 5'd1;                        // "1024"
                    v_c4 = CH_0;
                    v_c5 = CH_0 + 5'd2;
                    v_c6 = CH_0 + 5'd4;
                end else begin
                    v_c4 = CH_0 + 5'd8;                        // "800"
                    v_c5 = CH_0;
                    v_c6 = CH_0;
                end
            end
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

    // ---- 半透明底：格内画面压到 50% 亮度（≈ 和黑色 50% 混合，RGB565 无 alpha 的近似做法）----
    wire [15:0] px_dim = (px_in >> 1) & 16'h7BEF;

    // ---- 第①级打拍：几何/选中/字符 全部进寄存器 ----
    reg        q_de, q_vs, q_fill, q_sel, q_frm, q_gly;
    reg [15:0] q_px, q_dim;

    always @(posedge clk_pix) begin
        q_de   <= de_in;
        q_vs   <= vs_in;
        q_fill <= menu_on && in_cell;
        q_sel  <= menu_on && in_cell &&  is_sel && b_sel;
        q_frm  <= menu_on && in_cell && !is_sel && b_norm;
        q_gly  <= menu_on && in_gly;
        q_px   <= px_in;
        q_dim  <= px_dim;
    end

    // ============================================================
    //  2. 第②级：字模查表（BRAM ROM，1 拍）+ 调色输出
    //  ★ 2026-10-25：字模从组合 case 搬进一块 EG_PHY_BRAM32K（INIT_FILE=
    //    font_cn.dat），省 ~600 LUT。BRAM 地址必须用"未打拍"的 g_ch/gy/lx
    //    （组合量）——同一时钟沿 BRAM 采地址，下一拍 doa/dob 才有效，
    //    而那个"下一拍"正好是 q_ch/q_lx 所在的这一拍 ⇒ 第②级不用加流水，
    //    菜单总延迟仍 2 拍（下游 disp_top 不动）。数字仍是 7 段组合。
    // ============================================================
    // 2026-10-31 timing: register the font-RAM address (was the 65 MHz worst path,
    // -2.973ns / 13 logic levels) and push the whole overlay one stage deeper.
    reg [4:0] g_ch_r, gy_r, lx_r;
    always @(posedge clk_pix) begin
        g_ch_r <= g_ch;
        gy_r   <= gy;
        lx_r   <= lx;
    end

    wire font_px;
    font_cn u_font (
        .clk (clk_pix),
        .ch  (g_ch_r),
        .row (gy_r),
        .col (lx_r),
        .px  (font_px)
    );

    reg        q2_de, q2_vs, q2_fill, q2_sel, q2_frm, q2_gly;
    reg [15:0] q2_px, q2_dim;
    always @(posedge clk_pix) begin
        q2_de   <= q_de;
        q2_vs   <= q_vs;
        q2_fill <= q_fill;
        q2_sel  <= q_sel;
        q2_frm  <= q_frm;
        q2_gly  <= q_gly;
        q2_px   <= q_px;
        q2_dim  <= q_dim;
    end

    wire draw_text = q2_gly && font_px;

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            px_out <= 16'h0000;
            de_out <= 1'b0;
            vs_out <= 1'b0;
        end else begin
            de_out <= q2_de;
            vs_out <= q2_vs;
            if (draw_text)      px_out <= CLR_INK;
            else if (q2_sel)    px_out <= menu_edit ? CLR_RED : CLR_SEL;   // 确认后（调节态）外框变红
            else if (q2_frm)    px_out <= CLR_FRAME;
            else if (q2_fill)   px_out <= q2_dim;     // 半透明底（画面压暗 50%）
            else                px_out <= q2_px;
        end
    end

endmodule
