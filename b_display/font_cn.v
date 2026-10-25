// ============================================================
//  模块名 : font_cn —— 【24×24 汉字点阵（BRAM ROM） + 7 段数字】
//  生成   : .tmp_py\gen_font_cn3.py（Windows simsun 24px 二值化）
//
//  ★ 2026-10-25【汉字点阵搬进 BRAM】：原来是 288 条 24 bit 的组合 case，
//    综合出来 ~600 LUT。现在改成一块 TD 原语 EG_PHY_BRAM32K（16 位宽 ×
//    1024 深，DP16K 模式）：
//        word 地址 a = 2*wi + {0 => 低16位, 1 => 高 8 位}
//        wi = (ch-10)*24 + gy       （ch = 10..21，gy = 0 是字形最上面一行）
//    两个读口同拍读 wi*2 / wi*2+1，拼成 24 bit 行点阵 ⇒ 每个字形行 1 拍出。
//    初值走官方 INIT_FILE 参数（文件 prj/font_cn.dat，2048 行 × 16 bit 二进制，
//    由 .tmp_py\gen_font_dat.py 从本文件旧表生成，TD 的 ROM IP 用的就是这条路）。
//
//  ★ 为什么 0..9 仍用 7 段：点阵数字 0..9 要 160 个非零行 ×24bit，7 段只是
//    7 个区间比较、约 60 LUT，读数更像仪表。
//
//  字形表（BRAM 里只有 10..21）：
//          10 缩 11 放 12 音 13 轨 14 量 15 亮 16 度 17 %
//          18 可 19 视 20 开 21 关   （2026-10-24：菜单行 1 改「可视」开关）
//
//  打包口径（和 subtitle 位图一致）：1bpp，1 = 墨；bit23 = 最左像素；
//    行序自下而上：row=0 是屏幕最下面那行 ⇒ 屏幕行 gy 对应 wi 的 gy=23-row。
//
//  时序：**1 拍**（BRAM 同步读）。menu_ovl_cn 里把"未打拍"的 g_ch/gy/lx 直接
//    送进来（组合换算地址），同一时钟沿 BRAM 采地址，下一拍 doa/dob 有效，
//    正好和 menu 里第①级寄存器的 q_* 对齐 ⇒ 菜单总延迟仍是 2 拍，下游不动。
// ============================================================
`timescale 1ns / 1ps

module font_cn (
    input  wire        clk,    // 像素时钟（BRAM 同步读）
    input  wire [4:0]  ch,     // 字形序号 0..21
    input  wire [4:0]  row,    // 行号 0..23（自下而上）
    input  wire [4:0]  col,    // 列号 0..23（0 = 最左）
    output wire        px      // 1 = 墨（相对输入晚 1 拍）
);

    // ---------------- BRAM ROM：汉字 / % 点阵 ----------------
    // 地址由"未打拍"的 ch/row 组合算出；ch<10（数字/空格）读 0 号字无所谓
    wire [4:0]  wi_ch = (ch >= 5'd10) ? (ch - 5'd10) : 5'd0;
    wire [9:0]  wi    = {5'd0, wi_ch} * 10'd24 + {5'd0, (5'd23 - row)};
    wire [10:0] addra = {wi, 1'b0};          // 低 16 位 = wi*2
    wire [10:0] addrb = addra + 11'd1;       // 高 8 位（只用 dob[7:0]）

    wire [15:0] doa, dob;

    EG_PHY_BRAM32K #(
        .MODE          ("DP16K"),
        .DATA_WIDTH_A  ("16"),
        .DATA_WIDTH_B  ("16"),
        .REGMODE_A     ("NOREG"),
        .REGMODE_B     ("NOREG"),
        .INIT_FILE     ("font_cn.dat")
    ) u_rom (
        .doa    (doa),
        .dia    (16'd0),
        .addra  (addra),
        .bytea  (1'b0),
        .bytewea(1'b0),
        .csa    (1'b1),
        .wea    (1'b0),
        .clka   (clk),
        .rsta   (1'b0),
        .ocea   (1'b1),
        .dob    (dob),
        .dib    (16'd0),
        .addrb  (addrb),
        .byteb  (1'b0),
        .byteweb(1'b0),
        .csb    (1'b1),
        .web    (1'b0),
        .clkb   (clk),
        .rstb   (1'b0),
        .oceb   (1'b1)
    );

    // ---- 字符/列号打一拍，和 BRAM 数据同拍 ----
    reg [4:0] ch_q, row_q, col_q;
    always @(posedge clk) begin
        ch_q  <= ch;
        row_q <= row;
        col_q <= col;
    end

    wire [23:0] line = {dob[7:0], doa};      // bit23 = 最左
    wire        is_digit = (ch_q <= 5'd9);

    // ---------------- 0..9 七段 ----------------
    // 24×24 格内：字高 20（gy 2..21）、字宽 16（col 4..19）、笔宽 3
    wire [4:0] gy = 5'd23 - row_q;
    reg  [6:0] sgm;                          // {a,b,c,d,e,f,g}

    always @(*) begin
        case (ch_q)
            5'd0: sgm = 7'b1111110;
            5'd1: sgm = 7'b0110000;
            5'd2: sgm = 7'b1101101;
            5'd3: sgm = 7'b1111001;
            5'd4: sgm = 7'b0110011;
            5'd5: sgm = 7'b1011011;
            5'd6: sgm = 7'b1011111;
            5'd7: sgm = 7'b1110000;
            5'd8: sgm = 7'b1111111;
            5'd9: sgm = 7'b1111011;
            default: sgm = 7'b0000000;
        endcase
    end

    wire seg_a = sgm[6] & (gy >= 5'd2)  & (gy <= 5'd4)  & (col_q >= 5'd5)  & (col_q <= 5'd18);
    wire seg_g = sgm[0] & (gy >= 5'd12) & (gy <= 5'd14) & (col_q >= 5'd5)  & (col_q <= 5'd18);
    wire seg_d = sgm[3] & (gy >= 5'd19) & (gy <= 5'd21) & (col_q >= 5'd5)  & (col_q <= 5'd18);
    wire seg_f = sgm[1] & (col_q >= 5'd4)  & (col_q <= 5'd6)  & (gy >= 5'd5)  & (gy <= 5'd12);
    wire seg_b = sgm[5] & (col_q >= 5'd17) & (col_q <= 5'd19) & (gy >= 5'd5)  & (gy <= 5'd12);
    wire seg_e = sgm[2] & (col_q >= 5'd4)  & (col_q <= 5'd6)  & (gy >= 5'd14) & (gy <= 5'd21);
    wire seg_c = sgm[4] & (col_q >= 5'd17) & (col_q <= 5'd19) & (gy >= 5'd14) & (gy <= 5'd21);

    // bit23 = 最左 ⇒ col=0 取 bit23
    assign px = is_digit ? (seg_a | seg_b | seg_c | seg_d | seg_e | seg_f | seg_g)
                         : line[5'd23 - col_q];

endmodule
