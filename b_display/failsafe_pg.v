// ============================================================
//  模块名 : failsafe_pg —— 【D2 · B1】兜底页 / 上电自检页
//  层次   : `disp_top` 里，插在**合成器之后、可视化/字幕之前**（最底层背景）
//  依据   : 2026-10-19 评审结论 + `评审文档_20261019\03_本周改动计划` D2-B1
// ------------------------------------------------------------
//  ★ 它解决什么问题（一句话）：
//      "没卡 / 坏图 / 正在装载"这三种情况下，屏上原来是**米白空屏**
//      （`disp_top.BG_COLOR`），现场看着像"设备坏了"。现在换成一张
//      深底 + 三行 ASCII 说明的**自检页**：一眼能看出是"没插卡"还是"在装载"。
//
//  ★ 三个状态（`fs_state`，由顶层给）：
//      0 = OK       —— 正常出图 ⇒ 本模块被 `fs_on=0` 整个门掉，一个像素都不改
//      1 = LOADING  —— 插了卡、正在认 FAT/读 BMP ⇒ 屏上 "LOADING"
//      2 = BAD_IMG  —— 卡在、但一张也没读成（坏图/格式不对）⇒ "BAD IMAGE"
//      3 = NO_CARD  —— SD 初始化就没过（没插卡/接触不良）⇒ "NO SD CARD"
//    ★ 优先级由**顶层**决定（NO_CARD > BAD_IMAGE > LOADING > OK），本模块只负责画。
//
//  ★ 坐标与延迟（和 `menu_ovl` / `subtitle_ovl` 同一口径，必须对齐）：
//      · 本模块是**纯组合**：`x/y` 进来、`px_out` 同一拍出去，**不打拍**；
//      · 顶层喂进来的 `x/y` 必须是**和 `px_in` 同一像素**的那一对
//        （`disp_top` 里用 `o_dbg_x/o_dbg_y`，它和 `px_mix` 同拍 —— 见那里注释）；
//      · ⇒ 千万不要在这里为省事加寄存器，否则整页会偏几个像素。
//
//  ★ 字号：`SCALE=2` ⇒ 一个字符格 16×16 像素，字形本体 10×14（5×7 点阵放大两倍）。
//      字符格宽取 **16（2 的幂）** 是故意的：取字符下标只要 `dx[11:4]`，
//      不需要除以 12 那种除法器（省 DSP / 省 LUT）。
//
//  ★ 字模：复用 `b_display/font_rom.v`（5×7、纯组合 case、不落 BRAM）。
//      `font_rom.ch` 吃的是 **ASCII - 0x20** 的 6 位码，所以本模块里
//      所有字符串常量都要先减 0x20 再送进去（见下面 `ch_*` 的写法）。
//
//  ★ 面积：字符串是**常数**，综合器会把整条查表折叠成小 mux 树；
//      实测见 D2 交付记录（预算 +110 slices / 约 +150 LUT）。
// ============================================================
`timescale 1ns / 1ps

module failsafe_pg #(
    // 屏上放大倍数：2 ⇒ 字符格 16×16、字形 10×14
    parameter integer SCALE   = 2,
    // 底色（RGB565）：RGB888 (16,20,28) 的深板岩色，和"米白"完全区分开
    parameter [15:0]  BG      = 16'h1082,
    // 正文墨色
    parameter [15:0]  INK     = 16'hFFFF,
    // 四条状态线各自的颜色（OK 绿 / LOADING 青 / BAD 琥珀 / NO_CARD 红）
    parameter [15:0]  INK_OK  = 16'h07E0,
    parameter [15:0]  INK_LD  = 16'h07FF,
    parameter [15:0]  INK_BAD = 16'hFD20,
    parameter [15:0]  INK_ERR = 16'hF800
)(
    input  wire        clk_pix,
    input  wire        rst_pix_n,

    // ---------------- 画面坐标（与 px_in 同拍）----------------
    input  wire        de_in,          // 行有效（0 时不画，逐位透传）
    input  wire [11:0] x_in,           // 本像素的 x（0..799）
    input  wire [11:0] y_in,           // 本像素的 y（0..599）

    // ---------------- 状态（来自顶层，像素域同步副本）----------------
    input  wire        fs_on,          // 1 = 出兜底页；0 = 逐位透传（正常出图）
    input  wire [1:0]  fs_state,       // 0=OK 1=LOADING 2=BAD_IMG 3=NO_CARD

    // ---------------- 像素 ----------------
    input  wire [15:0] px_in,
    output wire [15:0] px_out
);

    // ------------------------------------------------------------
    //  一、几何常量
    // ------------------------------------------------------------
    // 字符格：16×16（SCALE=2 时 5×7 字形占 10×14，四周各留 1~3 px 空隙）
    localparam integer CELL = 16;

    // 三行文字的左上角。x 都按"屏宽 800 居中"算好写成常量（省掉乘法/除法）：
    //   行0 "HX4S20C"            7 字符 ⇒ 7*16=112 ⇒ x0 = 400-56 = 344
    //   行2 "FW 3.0  2026-10-20" 17 字符 ⇒ 17*16=272 ⇒ x0 = 400-136 = 264
    //   行1 是状态词（4..10 字符，长度随状态变）⇒ x0 用 st_len 现算（×8 即 ×16/2）
    localparam [11:0] X0_0 = 12'd344;
    localparam [11:0] X0_2 = 12'd264;

    localparam [11:0] Y0_0 = 12'd212;   // 行0 顶边
    localparam [11:0] Y0_1 = 12'd244;   // 行1 顶边（状态行，最醒目）
    localparam [11:0] Y0_2 = 12'd276;   // 行2 顶边
    localparam [11:0] Y_BAR = 12'd240;  // 行0 与行1 之间的 3 px 分隔条
    localparam [11:0] Y_BAR_E = 12'd243;

    // 状态词长度：
    //   0 "READY"=5   1 "LOADING"=7   2 "BAD IMAGE"=9   3 "NO SD CARD"=10
    reg [3:0] st_len;
    always @(*) begin
        case (fs_state)
            2'd0:    st_len = 4'd5;
            2'd1:    st_len = 4'd7;
            2'd2:    st_len = 4'd9;
            default: st_len = 4'd10;
        endcase
    end

    // 行1 的居中：x0 = 400 - len*8（len*16/2）
    wire [11:0] X0_1 = 12'd400 - {6'd0, st_len, 3'd0};
    // 行1 的右边界（含）：x0 + len*16
    wire [11:0] X1_E = X0_1 + {2'd0, st_len, 4'd0};

    // ------------------------------------------------------------
    //  二、像素落在哪一行
    // ------------------------------------------------------------
    wire row0_hit = (y_in >= Y0_0) && (y_in <  Y0_0 + CELL) &&
                    (x_in >= X0_0) && (x_in <  X0_0 + 12'd112);   // 7*16
    wire row1_hit = (y_in >= Y0_1) && (y_in <  Y0_1 + CELL) &&
                    (x_in >= X0_1) && (x_in <  X1_E);
    wire row2_hit = (y_in >= Y0_2) && (y_in <  Y0_2 + CELL) &&
                    (x_in >= X0_2) && (x_in <  X0_2 + 12'd272);   // 17*16

    wire bar_hit  = (y_in >= Y_BAR) && (y_in < Y_BAR_E) &&
                    (x_in >= X0_0) && (x_in <  X0_0 + 12'd112);

    // ------------------------------------------------------------
    //  三、字符下标 / 字形坐标
    //   ★ CELL=16 是 2 的幂 ⇒ 下标 = dx>>4，列 = dx[3:1]（÷2），行 = dy[3:1]
    // ------------------------------------------------------------
    wire [11:0] dx0 = x_in - X0_0;
    wire [11:0] dy0 = y_in - Y0_0;
    wire [11:0] dx1 = x_in - X0_1;
    wire [11:0] dy1 = y_in - Y0_1;
    wire [11:0] dx2 = x_in - X0_2;
    wire [11:0] dy2 = y_in - Y0_2;

    wire [2:0] ci0 = dx0[6:4];          // 行0 字符号 0..6
    wire [2:0] ci1 = dx1[6:4];          // 行1 字符号 0..7（st_len≤10 ⇒ 用到 ci 的 0..9）
    wire [3:0] ci1x = dx1[7:4];
    wire [3:0] ci2 = dx2[7:4];          // 行2 字符号 0..16

    wire [2:0] col0 = dx0[3:1];
    wire [2:0] col1 = dx1[3:1];
    wire [2:0] col2 = dx2[3:1];
    wire [2:0] row0 = dy0[3:1];
    wire [2:0] row1 = dy1[3:1];
    wire [2:0] row2 = dy2[3:1];

    // ------------------------------------------------------------
    //  四、取字符码（ASCII - 0x20 的 6 位码）
    //   ★ 三行共用一个 mux：先按"命中哪一行"选行号，再按字符下标查串
    // ------------------------------------------------------------
    reg [7:0] ch_a;        // 该字符的 ASCII
    reg [1:0] which;       // 0/1/2 = 行号（组合，只用于下面的 mux）
    always @(*) begin
        if (row0_hit)      which = 2'd0;
        else if (row1_hit) which = 2'd1;
        else               which = 2'd2;
    end

    always @(*) begin
        case (which)
            // ---- 行0：品牌 "HX4S20C"（7 字符，常数）----
            2'd0: begin
                case (ci0)
                    3'd0: ch_a = "H";
                    3'd1: ch_a = "X";
                    3'd2: ch_a = "4";
                    3'd3: ch_a = "S";
                    3'd4: ch_a = "2";
                    3'd5: ch_a = "0";
                    default: ch_a = "C";
                endcase
            end
            // ---- 行1：状态词（4 选 1，最长 10 字符）----
            2'd1: begin
                case (fs_state)
                    2'd0: begin                     // "READY"
                        case (ci1x)
                            4'd0: ch_a = "R";
                            4'd1: ch_a = "E";
                            4'd2: ch_a = "A";
                            4'd3: ch_a = "D";
                            default: ch_a = "Y";
                        endcase
                    end
                    2'd1: begin                     // "LOADING"
                        case (ci1x)
                            4'd0: ch_a = "L";
                            4'd1: ch_a = "O";
                            4'd2: ch_a = "A";
                            4'd3: ch_a = "D";
                            4'd4: ch_a = "I";
                            4'd5: ch_a = "N";
                            default: ch_a = "G";
                        endcase
                    end
                    2'd2: begin                     // "BAD IMAGE"
                        case (ci1x)
                            4'd0: ch_a = "B";
                            4'd1: ch_a = "A";
                            4'd2: ch_a = "D";
                            4'd3: ch_a = " ";
                            4'd4: ch_a = "I";
                            4'd5: ch_a = "M";
                            4'd6: ch_a = "A";
                            4'd7: ch_a = "G";
                            default: ch_a = "E";
                        endcase
                    end
                    default: begin                  // "NO SD CARD"
                        case (ci1x)
                            4'd0:  ch_a = "N";
                            4'd1:  ch_a = "O";
                            4'd2:  ch_a = " ";
                            4'd3:  ch_a = "S";
                            4'd4:  ch_a = "D";
                            4'd5:  ch_a = " ";
                            4'd6:  ch_a = "C";
                            4'd7:  ch_a = "A";
                            4'd8:  ch_a = "R";
                            default: ch_a = "D";
                        endcase
                    end
                endcase
            end
            // ---- 行2：固件/日期 "FW 3.0  2026-10-20"（17 字符，常数）----
            default: begin
                case (ci2)
                    4'd0:  ch_a = "F";
                    4'd1:  ch_a = "W";
                    4'd2:  ch_a = " ";
                    4'd3:  ch_a = "3";
                    4'd4:  ch_a = ".";
                    4'd5:  ch_a = "0";
                    4'd6:  ch_a = " ";
                    4'd7:  ch_a = " ";
                    4'd8:  ch_a = "2";
                    4'd9:  ch_a = "0";
                    4'd10: ch_a = "2";
                    4'd11: ch_a = "6";
                    4'd12: ch_a = "-";
                    4'd13: ch_a = "1";
                    4'd14: ch_a = "0";
                    4'd15: ch_a = "-";
                    default: ch_a = "2";
                endcase
            end
        endcase
    end

    wire [5:0] ch6 = ch_a[5:0] - 6'h20;     // font_rom 的码 = ASCII 低 6 位 - 0x20

    // 字形坐标：行1/行2 与行0 用同一套（都是 dx[3:1]/dy[3:1]）
    wire [2:0] col = row0_hit ? col0 : (row1_hit ? col1 : col2);
    wire [2:0] row = row0_hit ? row0 : (row1_hit ? row1 : row2);

    // ------------------------------------------------------------
    //  五、查字模（5×7，纯组合）
    // ------------------------------------------------------------
    wire glyph;
    font_rom u_font (
        .ch  (ch6),
        .row (row),
        .col (col),
        .px  (glyph)
    );

    // ------------------------------------------------------------
    //  六、出像素
    // ------------------------------------------------------------
    // 状态行用各自颜色，品牌行/固件行用白
    reg [15:0] ink_sel;
    always @(*) begin
        case (fs_state)
            2'd0:    ink_sel = INK_OK;
            2'd1:    ink_sel = INK_LD;
            2'd2:    ink_sel = INK_BAD;
            default: ink_sel = INK_ERR;
        endcase
    end

    reg [15:0] px_draw;
    always @(*) begin
        px_draw = BG;                                   // 默认深底
        if (row0_hit || row2_hit) begin
            if (col < 3'd5 && row < 3'd7 && glyph) px_draw = INK;
        end
        else if (row1_hit) begin
            if (col < 3'd5 && row < 3'd7 && glyph) px_draw = ink_sel;
        end
        if (bar_hit) px_draw = ink_sel;                  // 分隔条
    end

    // 关掉时逐位透传（`fs_on=0` ⇒ 综合里这条链被常数传播消掉大部分）
    assign px_out = (de_in && fs_on) ? px_draw : px_in;

endmodule
