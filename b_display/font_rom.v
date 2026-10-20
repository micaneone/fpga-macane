// ============================================================
//  模块名 : font_rom —— 【参数菜单·第2步】**紧凑 ASCII 子集字模**（只读、组合输出）
//  层次   : `menu_ovl` 内部例化（像素域 clk_pix 流水里，纯组合查表，不打拍）
//  依据   : 用户 2026-10-15 定稿的「参数菜单·第 2 步」规格
// ------------------------------------------------------------
//  ★★★ 2026-10-15【参数菜单·第2步】本模块干什么（一句话）：
//      给一组**子集 ASCII 码**（数字 0-9、大写 A-Z、空格 ':' '-' '>'），
//      按"第几行(0..6) + 第几列(0..4)"查出这一位**该不该点灯**（1 = 前景）。
//
//  ★★★ 2026-10-17【菜单字模·修正与放大】**怎么"换字模"（只改本文件，别的文件一行都不用碰）**：
//      ① 换字形：只改下面 `case (ch)` 里那个字符的 7 条 `5'b….` 行常量
//         （每条右边都画了 █ 点阵图，照着图改，不用猜 bit 位）。
//      ② 换字号：改本模块参数 `FONT_W` / `FONT_H`（默认 5×7）；
//         **屏上放大倍数不在这里**，在 `menu_ovl.v` 的 `TXT_SCALE`（默认 2 ⇒ 10×14）。
//      ③ 换字符集：把 `case` 里没列出的码删掉即可 —— 查不到就是全 0（空白），不会画乱码。
//      ⇒ 接口永远不变："字符码 + 行 + 列 → 这一位亮不亮"，换 ROM 不用动 menu_ovl 的接线。
//
//  ★ 点阵规格：**5 列 × 7 行**（经典 5×7 点阵字体），
//      · 一个字形 = 7 个"行向量"，每行只占**低 5 位**（bit[4]=最左列，bit[0]=最右列）；
//      · 字模里 bit = 1 表示【前景】（MENU_INK 那个亮色），0 = 透出底色；
//        ⇒ **不要取反**！菜单面板底是深灰、字是亮色，取反就成了"亮底黑字"、
//          在深灰面板上几乎看不见 —— 这是本步最容易踩的坑（见交付"风险"）。
//      · 一个字符格在屏上占 TXT_W=5 / TXT_H=7 个像素；间距由 menu_ovl 的
//        TXT_SP 常量控（本模块只管字形本体，**不含间距**）。
//
//  ★★★ 2026-10-16【菜单字模·修正】与 `menu_ovl.v` 的**极性契约**（写在这里，防再犯）：
//      ┌────────────────────────────────────────────────────────────────────┐
//      │  本模块 `px`        │  menu_ovl.v 的处置          │  屏上结果        │
//      ├─────────────────────┼─────────────────────────────┼──────────────────┤
//      │  1 = 点灯（前景）   │  px_out <= CLR_INK（亮）    │  一个**墨色**点   │
//      │  0 = 不点灯         │  **什么都不做**             │  保留已铺好的底色  │
//      │                     │  （面板底 / 高亮条）        │  ★ **绝不透出照片**│
//      └─────────────────────┴─────────────────────────────┴──────────────────┘
//      · ⇒ **两边约定完全一致：1 = 墨、0 = 保留底色。任何一边都不要取反。**
//      · ★★★ 2026-10-17【菜单字模·修正与放大】**本约定不变、再确认一次**：
//        `px = 1` 就是"画一颗墨色点"，`px = 0` 就是"这颗点什么都不做"。
//        ⇒ 本模块**永远不输出"透明/背景色"**；也**绝不允许**输出 1 的像素落在
//          字形（col ≥ FONT_W）或字高（row ≥ FONT_H）之外 —— 见文件末尾的越界保护。
//      · ⇒ menu_ovl 必须**先铺不透明面板底**，再（只在高亮条上）画高亮条，
//        最后才"只在 px=1 的像素上"改颜色 —— 三者顺序错了就会出现
//        "字形缝隙里能看到照片"（2026-10-16 上板反馈，已修）。
//      · 本模块的输出**永远不含"透明"这个语义**：它只说"这一位是不是墨"，
//        "不点灯时该是什么颜色"由 menu_ovl 的底色层决定。
//
//  ★ 为什么**一定不会落 BRAM**（这颗 EG4S20 的 BRAM **不能上电初始化**）：
//      · 本模块**没有任何数组/寄存器**：没有 `reg [6:0] mem [0:63]` 那种被综合器
//        认成"块 RAM"的写法，只有一条**纯组合 `case` 常量赋值**；
//      · 综合器对这种"常数 case"只会落 **LUT（LUTRAM 也行）**，综合不出 BRAM 原语；
//        ⇒ 上电即有值、不需要配置、不需要初值，字模**绝不会是空白**。
//      · 面积：约 56 个码 × 7 行 ⇒ 一张 7 位输出的小查找表，几十个 LUT 而已
//        （实测见交付报告，远小于 +400 LUT 的预算）。
//
//  ★ 码表（**码值是 ASCII**，一眼能对上；没列出的码查出来是"全 0"= 空白）：
//      6'd0    = 空格 ' '（也当"没有这个字符"的兜底）
//      6'd13   = '-'  6'd26 = ':'  6'd29 = '>'   ← 菜单要的三个符号
//      6'd16..6'd25 = '0'..'9'
//      6'd33..6'd58 = 'A'..'Z'
//    注：Verilog 的 `case` 按**位**比较，ASCII '0'(8'h30) 与 6'h10 的低 6 位相同 ⇒
//        menu_ovl 那边直接把 6 位字符码送进来即可（它自己就是按 ASCII 低 6 位编的）。
//
//  ★ 每个字形的点阵都画在下面 case 每一条的注释里（█ = 点灯）——以后要改字形，
//    照着那份"图"改 7 个 5 位常量就行，不用再去猜哪个 bit 是哪个像素。
// ============================================================
`timescale 1ns / 1ps

module font_rom #(
    // ---- ★★★ 2026-10-17【菜单字模·修正与放大】字形几何（**换字模只改这两个默认值**）----
    //   与 `menu_ovl.v` 的 TXT_W / TXT_H 对应，两边必须一致（menu_ovl 那边管"屏上多大"）。
    parameter integer FONT_W = 5,   // 字形宽 = 列数（每行的低 FONT_W 位）
    parameter integer FONT_H = 7    // 字形高 = 行数（case 里的条目数）
)(
    input  wire [5:0] ch,        // 字符码（ASCII 低 6 位；见上面码表）
    input  wire [2:0] row,       // 字形内行号 0..(FONT_H-1)（0 = 最上面那一行）
                                 //   ★ 3 位 ⇒ 最多 8 行；FONT_H > 8 时这个端口要加宽
    input  wire [2:0] col,       // 字形内列号 0..(FONT_W-1)（0 = 最左边那一列）
                                 //   ★ 3 位 ⇒ 最多 8 列；FONT_W > 8 时这个端口要加宽
    output wire       px         // ★ 1 = 这一位点灯（前景/墨色）；0 = 该位保持底色，
                                 //   由 menu_ovl 的底色层决定 ⇒ **本模块不含透明语义**
);

    // 查表：这一行（row）的 FONT_W 位行向量
    reg [FONT_W-1:0] rowbits;

    always @(*) begin
        case (ch)
            // ---------------- 空格 ----------------
            6'd0 : case (row)
                3'd0: rowbits = 5'b00000;    //  .....
                3'd1: rowbits = 5'b00000;    //  .....
                3'd2: rowbits = 5'b00000;    //  .....
                3'd3: rowbits = 5'b00000;    //  .....
                3'd4: rowbits = 5'b00000;    //  .....
                3'd5: rowbits = 5'b00000;    //  .....
                default: rowbits = 5'b00000;//  .....
            endcase

            // ---------------- '-' = 6'd13 横线（第 3 行，5 个点）----------------
            6'd13: case (row)
                3'd0: rowbits = 5'b00000;    //  .....
                3'd1: rowbits = 5'b00000;    //  .....
                3'd2: rowbits = 5'b00000;    //  .....
                3'd3: rowbits = 5'b11111;    //  █████
                3'd4: rowbits = 5'b00000;    //  .....
                3'd5: rowbits = 5'b00000;    //  .....
                default: rowbits = 5'b00000;//  .....
            endcase

            // ---------------- '.' = 6'd14 小数点（第 6 行一个点）----------------
            //   ★ 2026-10-21【D2 兜底页】新增：兜底页要写 "FW 3.0" 的小数点。
            //     菜单不用这个码，加了不影响既有 8 组黄金对照（它们不查 '.'）。
            6'd14: case (row)
                3'd0: rowbits = 5'b00000;    //  .....
                3'd1: rowbits = 5'b00000;    //  .....
                3'd2: rowbits = 5'b00000;    //  .....
                3'd3: rowbits = 5'b00000;    //  .....
                3'd4: rowbits = 5'b00000;    //  .....
                3'd5: rowbits = 5'b00100;    //  ..█..
                default: rowbits = 5'b00100;//  ..█..
            endcase

            // ---------------- ':' = 6'd26 冒号（第 2/4 行两个点）----------------
            6'd26: case (row)
                3'd0: rowbits = 5'b00000;    //  .....
                3'd1: rowbits = 5'b00100;    //  ..█..
                3'd2: rowbits = 5'b00000;    //  .....
                3'd3: rowbits = 5'b00100;    //  ..█..
                3'd4: rowbits = 5'b00000;    //  .....
                3'd5: rowbits = 5'b00000;    //  .....
                default: rowbits = 5'b00000;//  .....
            endcase

            // ---------------- '>' = 6'd29 光标箭头（右尖）----------------
            6'd29: case (row)
                3'd0: rowbits = 5'b10000;    //  █....
                3'd1: rowbits = 5'b01000;    //  .█...
                3'd2: rowbits = 5'b00100;    //  ..█..
                3'd3: rowbits = 5'b00010;    //  ...█.
                3'd4: rowbits = 5'b00100;    //  ..█..
                3'd5: rowbits = 5'b01000;    //  .█...
                default: rowbits = 5'b10000;//  █....
            endcase

            // ================= 数字 '0'..'9'（6'd16..6'd25）================
            // '0' = 6'd16
            6'd16: case (row)
                3'd0: rowbits = 5'b01110;    //  .███.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10011;    //  █..██
                3'd3: rowbits = 5'b10101;    //  █.█.█
                3'd4: rowbits = 5'b11001;    //  ██..█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b01110;//  .███.
            endcase
            // '1' = 6'd17
            6'd17: case (row)
                3'd0: rowbits = 5'b00100;    //  ..█..
                3'd1: rowbits = 5'b01100;    //  .██..
                3'd2: rowbits = 5'b00100;    //  ..█..
                3'd3: rowbits = 5'b00100;    //  ..█..
                3'd4: rowbits = 5'b00100;    //  ..█..
                3'd5: rowbits = 5'b00100;    //  ..█..
                default: rowbits = 5'b01110;//  .███.
            endcase
            // '2' = 6'd18
            6'd18: case (row)
                3'd0: rowbits = 5'b01110;    //  .███.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b00001;    //  ....█
                3'd3: rowbits = 5'b00110;    //  ..██.
                3'd4: rowbits = 5'b01000;    //  .█...
                3'd5: rowbits = 5'b10000;    //  █....
                default: rowbits = 5'b11111;//  █████
            endcase
            // '3' = 6'd19
            6'd19: case (row)
                3'd0: rowbits = 5'b11111;    //  █████
                3'd1: rowbits = 5'b00010;    //  ...█.
                3'd2: rowbits = 5'b00100;    //  ..█..
                3'd3: rowbits = 5'b00010;    //  ...█.
                3'd4: rowbits = 5'b00001;    //  ....█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b01110;//  .███.
            endcase
            // '4' = 6'd20
            6'd20: case (row)
                3'd0: rowbits = 5'b00010;    //  ...█.
                3'd1: rowbits = 5'b00110;    //  ..██.
                3'd2: rowbits = 5'b01010;    //  .█.█.
                3'd3: rowbits = 5'b10010;    //  █..█.
                3'd4: rowbits = 5'b11111;    //  █████
                3'd5: rowbits = 5'b00010;    //  ...█.
                default: rowbits = 5'b00010;//  ...█.
            endcase
            // '5' = 6'd21
            6'd21: case (row)
                3'd0: rowbits = 5'b11111;    //  █████
                3'd1: rowbits = 5'b10000;    //  █....
                3'd2: rowbits = 5'b11110;    //  ████.
                3'd3: rowbits = 5'b00001;    //  ....█
                3'd4: rowbits = 5'b00001;    //  ....█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b01110;//  .███.
            endcase
            // '6' = 6'd22
            6'd22: case (row)
                3'd0: rowbits = 5'b00110;    //  ..██.
                3'd1: rowbits = 5'b01000;    //  .█...
                3'd2: rowbits = 5'b10000;    //  █....
                3'd3: rowbits = 5'b11110;    //  ████.
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b01110;//  .███.
            endcase
            // '7' = 6'd23
            6'd23: case (row)
                3'd0: rowbits = 5'b11111;    //  █████
                3'd1: rowbits = 5'b00001;    //  ....█
                3'd2: rowbits = 5'b00010;    //  ...█.
                3'd3: rowbits = 5'b00100;    //  ..█..
                3'd4: rowbits = 5'b01000;    //  .█...
                3'd5: rowbits = 5'b01000;    //  .█...
                default: rowbits = 5'b01000;//  .█...
            endcase
            // '8' = 6'd24
            6'd24: case (row)
                3'd0: rowbits = 5'b01110;    //  .███.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b01110;    //  .███.
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b01110;//  .███.
            endcase
            // '9' = 6'd25
            6'd25: case (row)
                3'd0: rowbits = 5'b01110;    //  .███.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b01111;    //  .████
                3'd4: rowbits = 5'b00001;    //  ....█
                3'd5: rowbits = 5'b00010;    //  ...█.
                default: rowbits = 5'b01100;//  ..██.
            endcase

            // ================= 大写 'A'..'Z'（6'd33..6'd58）================
            // 'A' = 6'd33
            6'd33: case (row)
                3'd0: rowbits = 5'b00100;    //  ..█..
                3'd1: rowbits = 5'b01010;    //  .█.█.
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b10001;    //  █...█
                3'd4: rowbits = 5'b11111;    //  █████
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b10001;//  █...█
            endcase
            // 'B' = 6'd34
            6'd34: case (row)
                3'd0: rowbits = 5'b11110;    //  ████.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b11110;    //  ████.
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b11110;//  ████.
            endcase
            // 'C' = 6'd35
            6'd35: case (row)
                3'd0: rowbits = 5'b01110;    //  .███.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10000;    //  █....
                3'd3: rowbits = 5'b10000;    //  █....
                3'd4: rowbits = 5'b10000;    //  █....
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b01110;//  .███.
            endcase
            // 'D' = 6'd36
            6'd36: case (row)
                3'd0: rowbits = 5'b11100;    //  ███..
                3'd1: rowbits = 5'b10010;    //  █..█.
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b10001;    //  █...█
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10010;    //  █..█.
                default: rowbits = 5'b11100;//  ███..
            endcase
            // 'E' = 6'd37
            6'd37: case (row)
                3'd0: rowbits = 5'b11111;    //  █████
                3'd1: rowbits = 5'b10000;    //  █....
                3'd2: rowbits = 5'b10000;    //  █....
                3'd3: rowbits = 5'b11110;    //  ████.
                3'd4: rowbits = 5'b10000;    //  █....
                3'd5: rowbits = 5'b10000;    //  █....
                default: rowbits = 5'b11111;//  █████
            endcase
            // 'F' = 6'd38
            6'd38: case (row)
                3'd0: rowbits = 5'b11111;    //  █████
                3'd1: rowbits = 5'b10000;    //  █....
                3'd2: rowbits = 5'b10000;    //  █....
                3'd3: rowbits = 5'b11110;    //  ████.
                3'd4: rowbits = 5'b10000;    //  █....
                3'd5: rowbits = 5'b10000;    //  █....
                default: rowbits = 5'b10000;//  █....
            endcase
            // 'G' = 6'd39
            6'd39: case (row)
                3'd0: rowbits = 5'b01110;    //  .███.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10000;    //  █....
                3'd3: rowbits = 5'b10111;    //  █.███
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b01110;//  .███.
            endcase
            // 'H' = 6'd40
            6'd40: case (row)
                3'd0: rowbits = 5'b10001;    //  █...█
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b11111;    //  █████
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b10001;//  █...█
            endcase
            // 'I' = 6'd41
            6'd41: case (row)
                3'd0: rowbits = 5'b01110;    //  .███.
                3'd1: rowbits = 5'b00100;    //  ..█..
                3'd2: rowbits = 5'b00100;    //  ..█..
                3'd3: rowbits = 5'b00100;    //  ..█..
                3'd4: rowbits = 5'b00100;    //  ..█..
                3'd5: rowbits = 5'b00100;    //  ..█..
                default: rowbits = 5'b01110;//  .███.
            endcase
            // 'J' = 6'd42
            6'd42: case (row)
                3'd0: rowbits = 5'b00111;    //  ..███
                3'd1: rowbits = 5'b00010;    //  ...█.
                3'd2: rowbits = 5'b00010;    //  ...█.
                3'd3: rowbits = 5'b00010;    //  ...█.
                3'd4: rowbits = 5'b10010;    //  █..█.
                3'd5: rowbits = 5'b10010;    //  █..█.
                default: rowbits = 5'b01100;//  .██..
            endcase
            // 'K' = 6'd43
            6'd43: case (row)
                3'd0: rowbits = 5'b10001;    //  █...█
                3'd1: rowbits = 5'b10010;    //  █..█.
                3'd2: rowbits = 5'b10100;    //  █.█..
                3'd3: rowbits = 5'b11000;    //  ██...
                3'd4: rowbits = 5'b10100;    //  █.█..
                3'd5: rowbits = 5'b10010;    //  █..█.
                default: rowbits = 5'b10001;//  █...█
            endcase
            // 'L' = 6'd44
            6'd44: case (row)
                3'd0: rowbits = 5'b10000;    //  █....
                3'd1: rowbits = 5'b10000;    //  █....
                3'd2: rowbits = 5'b10000;    //  █....
                3'd3: rowbits = 5'b10000;    //  █....
                3'd4: rowbits = 5'b10000;    //  █....
                3'd5: rowbits = 5'b10000;    //  █....
                default: rowbits = 5'b11111;//  █████
            endcase
            // 'M' = 6'd45
            6'd45: case (row)
                3'd0: rowbits = 5'b10001;    //  █...█
                3'd1: rowbits = 5'b11011;    //  ██.██
                3'd2: rowbits = 5'b10101;    //  █.█.█
                3'd3: rowbits = 5'b10101;    //  █.█.█
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b10001;//  █...█
            endcase
            // 'N' = 6'd46
            6'd46: case (row)
                3'd0: rowbits = 5'b10001;    //  █...█
                3'd1: rowbits = 5'b11001;    //  ██..█
                3'd2: rowbits = 5'b10101;    //  █.█.█
                3'd3: rowbits = 5'b10011;    //  █..██
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b10001;//  █...█
            endcase
            // 'O' = 6'd47
            6'd47: case (row)
                3'd0: rowbits = 5'b01110;    //  .███.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b10001;    //  █...█
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b01110;//  .███.
            endcase
            // 'P' = 6'd48
            6'd48: case (row)
                3'd0: rowbits = 5'b11110;    //  ████.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b11110;    //  ████.
                3'd4: rowbits = 5'b10000;    //  █....
                3'd5: rowbits = 5'b10000;    //  █....
                default: rowbits = 5'b10000;//  █....
            endcase
            // 'Q' = 6'd49
            6'd49: case (row)
                3'd0: rowbits = 5'b01110;    //  .███.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b10001;    //  █...█
                3'd4: rowbits = 5'b10101;    //  █.█.█
                3'd5: rowbits = 5'b10010;    //  █..█.
                default: rowbits = 5'b01101;//  .██.█
            endcase
            // 'R' = 6'd50
            6'd50: case (row)
                3'd0: rowbits = 5'b11110;    //  ████.
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b11110;    //  ████.
                3'd4: rowbits = 5'b10100;    //  █.█..
                3'd5: rowbits = 5'b10010;    //  █..█.
                default: rowbits = 5'b10001;//  █...█
            endcase
            // 'S' = 6'd51
            6'd51: case (row)
                3'd0: rowbits = 5'b01111;    //  .████
                3'd1: rowbits = 5'b10000;    //  █....
                3'd2: rowbits = 5'b10000;    //  █....
                3'd3: rowbits = 5'b01110;    //  .███.
                3'd4: rowbits = 5'b00001;    //  ....█
                3'd5: rowbits = 5'b00001;    //  ....█
                default: rowbits = 5'b11110;//  ████.
            endcase
            // 'T' = 6'd52
            6'd52: case (row)
                3'd0: rowbits = 5'b11111;    //  █████
                3'd1: rowbits = 5'b00100;    //  ..█..
                3'd2: rowbits = 5'b00100;    //  ..█..
                3'd3: rowbits = 5'b00100;    //  ..█..
                3'd4: rowbits = 5'b00100;    //  ..█..
                3'd5: rowbits = 5'b00100;    //  ..█..
                default: rowbits = 5'b00100;//  ..█..
            endcase
            // 'U' = 6'd53
            6'd53: case (row)
                3'd0: rowbits = 5'b10001;    //  █...█
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b10001;    //  █...█
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b01110;//  .███.
            endcase
            // 'V' = 6'd54
            6'd54: case (row)
                3'd0: rowbits = 5'b10001;    //  █...█
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b10001;    //  █...█
                3'd4: rowbits = 5'b10001;    //  █...█
                3'd5: rowbits = 5'b01010;    //  .█.█.
                default: rowbits = 5'b00100;//  ..█..
            endcase
            // 'W' = 6'd55
            6'd55: case (row)
                3'd0: rowbits = 5'b10001;    //  █...█
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b10001;    //  █...█
                3'd3: rowbits = 5'b10101;    //  █.█.█
                3'd4: rowbits = 5'b10101;    //  █.█.█
                3'd5: rowbits = 5'b11011;    //  ██.██
                default: rowbits = 5'b10001;//  █...█
            endcase
            // 'X' = 6'd56
            6'd56: case (row)
                3'd0: rowbits = 5'b10001;    //  █...█
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b01010;    //  .█.█.
                3'd3: rowbits = 5'b00100;    //  ..█..
                3'd4: rowbits = 5'b01010;    //  .█.█.
                3'd5: rowbits = 5'b10001;    //  █...█
                default: rowbits = 5'b10001;//  █...█
            endcase
            // 'Y' = 6'd57
            6'd57: case (row)
                3'd0: rowbits = 5'b10001;    //  █...█
                3'd1: rowbits = 5'b10001;    //  █...█
                3'd2: rowbits = 5'b01010;    //  .█.█.
                3'd3: rowbits = 5'b00100;    //  ..█..
                3'd4: rowbits = 5'b00100;    //  ..█..
                3'd5: rowbits = 5'b00100;    //  ..█..
                default: rowbits = 5'b00100;//  ..█..
            endcase
            // 'Z' = 6'd58
            6'd58: case (row)
                3'd0: rowbits = 5'b11111;    //  █████
                3'd1: rowbits = 5'b00001;    //  ....█
                3'd2: rowbits = 5'b00010;    //  ...█.
                3'd3: rowbits = 5'b00100;    //  ..█..
                3'd4: rowbits = 5'b01000;    //  .█...
                3'd5: rowbits = 5'b10000;    //  █....
                default: rowbits = 5'b11111;//  █████
            endcase

            // ---------------- 其它码：全 0 = 空白（不会画任何东西）----------------
            default: rowbits = 5'b00000;
        endcase
    end

    // ============================================================
    //  ★★★ 2026-10-17【菜单字模·修正与放大】**列/行的越界保护**（本次上板"字模没做好"的正主之一）
    // ------------------------------------------------------------
    //  上一版最后一行是：`assign px = rowbits[3'd4 - col];`
    //    · `col` 是 3 位，调用方只要送来 5/6/7（字间距那几列，或任何漂到字形外的列），
    //      `4-col` 就会算成 7/6/5 —— 这是**超出 5 位向量下标范围的位选**：
    //      仿真给 `x`（字缝里不画，看着还行），**综合结果未定义**（TD 一声不吭，
    //      不报 HDL 错），硅上就可能把字缝点亮、把字糊成一块 —— 上板现象与仿真不一致。
    //    · 同时还把"列号"当成了"绝对列"用（见 menu_ovl.v 里那段修正说明）。
    //  ⇒ 现在：**先把列号夹到合法范围、再查表**：
    //      `ci` 恒在 0..FONT_W-1（所以 `rowbits[ci]` 永远是合法位选，不留未定义项），
    //      `px` 再与 (col<FONT_W && row<FONT_H) 相与 ⇒ 字形外**恒 0**（绝不点灯）。
    // ============================================================
    localparam integer FONT_WM1 = FONT_W - 1;              // 最右列的 bit 号（5 列 ⇒ 4）
    wire [2:0] ci = (col < FONT_W) ? (FONT_WM1 - col) : 3'd0;   // ★ 恒合法：0..FONT_W-1

    // 从这一行里挑出 col 那一列：col = 0 ⇒ 最左（bit FONT_W-1）… col = FONT_W-1 ⇒ 最右（bit0）
    assign px = ((col < FONT_W) && (row < FONT_H)) ? rowbits[ci] : 1'b0;

endmodule
