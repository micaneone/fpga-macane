// ============================================================
//  模块名 : pix_check（测试件，不进交付仓库）
//  作用   : 【送到 HDMI 的像素】逐像素自检 —— 看它是不是我们应该写进去的那张图
// ------------------------------------------------------------
//  为什么要它：
//    屏上不出图时，"没写进去"和"读出来是错的"长得一模一样。
//    这个模块把【真正送进 HDMI 的像素】拿过来，和本地算出来的期望值比对：
//      o_bad = 0        → 显示链吐出来的就是我们期望的图（那屏上就该是这张图）
//      o_bad 很大       → 读出来/搬过来的东西是错的
//      o_got / o_exp    → 第一个错像素的"实际值 / 应该值"，一眼看出错在哪一类
//
//  ★ 期望图案必须和 stub_a_writer 的 PAT_MODE=1 一模一样（同一张自测图）。
//  ★ 只统计窗口内的像素（窗口外是桌面底色，不算）。
// ============================================================
`timescale 1ns / 1ps

module pix_check #(
    parameter integer WIN_X0 = 80,
    parameter integer WIN_Y0 = 60,
    parameter integer WIN_W  = 640,
    parameter integer WIN_H  = 480,
    parameter integer PAT_MODE = 1      // ★ 必须和 stub_a_writer 的 PAT_MODE 一样！
                                        //   1 = 8 条竖色条；2 = "数据自己带地址"
)(
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        de,             // 和 rgb565 同拍
    input  wire [11:0] x,              // 和 rgb565 同拍
    input  wire [11:0] y,
    input  wire [15:0] rgb565,

    output reg  [23:0] o_cmp,          // 比对过多少个像素
    output reg  [23:0] o_bad,          // 其中多少个不对
    output reg  [15:0] o_got,          // 第一个错像素：实际值
    output reg  [15:0] o_exp,          // 第一个错像素：应该值
    output reg  [9:0]  o_u,            // 它的窗口内列号 u（0..639）
    output reg  [8:0]  o_v,            // 它的窗口内行号 v（0..479）
    // ★★ 行探针（2026-09-27 第三次改）：**同一行（v=208）里不同位置**的显示值。
    //    前面已经量出：8 个不同的行都是"整行偏 +3"，而且同一行里有 240/320 个字
    //    对不上（= 每 4 个里只对 1 个）。这看起来像"行内每 4 个字一组、组内被转了位"。
    //    所以要换成"看一行的内部结构"：
    //      A 组：u = 0/2/4/6   → 第 0/1/2/3 个字（四个值一模一样 = "每字重复 4 次"）
    //      B 组：u = 8/10/12/14 → 第 4/5/6/7 个字（相邻！用来确认重复是不是消失了）
    //    地址图里"字的值 = 它的地址"，所以每个位置的期望值是 (208*320 + u/2) 低 16 位。
    output reg  [15:0] o_row0,         // v=208, u=0   → 第 0 个字
    output reg  [15:0] o_row1,         // v=208, u=2   → 第 1 个字
    output reg  [15:0] o_row2,         // v=208, u=4   → 第 2 个字
    output reg  [15:0] o_row3,         // v=208, u=6   → 第 3 个字
    output reg  [15:0] o_row4,         // v=208, u=8   → 第 4 个字
    output reg  [15:0] o_row5,         // v=208, u=10  → 第 5 个字
    output reg  [15:0] o_row6,         // v=208, u=12  → 第 6 个字
    output reg  [15:0] o_row7          // v=208, u=14  → 第 7 个字
);

    // ---- 和 stub_a_writer(PAT_MODE=1) 完全一致的自测图 ----
    function [15:0] pat_pix;
        input [11:0] u, vv;
        reg [31:0] a32;
        begin
            if (PAT_MODE == 2) begin
                // ★★ 2026-09-28 修：A 现在按 BMP 的原始顺序（自下而上）往 SDRAM 里存，
                //    显示侧把行号翻过来读（见 win_sample 里的 row_read），所以
                //    窗口第 v 行真正读的是"存储里的第 (WIN_H-1-v) 行"。
                //    ★ 原来这里按 v 算 —— 全屏都会被判成"错"，chk_bad 那个数
                //      于是完全没意义（这也是之前"错像素计数"读数一直不好用的原因）。
                a32 = (WIN_H - 1 - vv) * (WIN_W/2) + (u >> 1);
                pat_pix = a32[15:0];
            end
            else if (vv < 32)    pat_pix = 16'hFFFF;
            else if (u < 32)     pat_pix = vv[2] ? 16'h0000 : 16'hFFFF;
            else if (u < 80)     pat_pix = 16'hF800;
            else if (u < 160)    pat_pix = 16'h07E0;
            else if (u < 240)    pat_pix = 16'h001F;
            else if (u < 320)    pat_pix = 16'hFFFF;
            else if (u < 400)    pat_pix = 16'h07FF;
            else if (u < 480)    pat_pix = 16'hF81F;
            else if (u < 560)    pat_pix = 16'hFFE0;
            else                 pat_pix = 16'h0000;
        end
    endfunction

    wire        in_win = de && (x >= WIN_X0) && (x < WIN_X0 + WIN_W)
                            && (y >= WIN_Y0) && (y < WIN_Y0 + WIN_H);
    wire [11:0] u = x - WIN_X0;
    wire [11:0] v = y - WIN_Y0;
    wire [15:0] e = pat_pix(u, v);

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            o_cmp <= 24'd0;
            o_bad <= 24'd0;
            o_got <= 16'd0;
            o_exp <= 16'd0;
            o_u    <= 10'd0;
            o_v    <= 9'd0;
            o_row0 <= 16'd0;
            o_row1 <= 16'd0;
            o_row2 <= 16'd0;
            o_row3 <= 16'd0;
            o_row4 <= 16'd0;
            o_row5 <= 16'd0;
            o_row6 <= 16'd0;
            o_row7 <= 16'd0;
        end
        else begin
          // ---- 行内探针：固定第 208 行，取 8 个不同位置 ----
          if (in_win && (v == 12'd208)) begin
              if (u == 12'd0)  o_row0 <= rgb565;   // 第 0 个字
              if (u == 12'd2)  o_row1 <= rgb565;   // 第 1 个字
              if (u == 12'd4)  o_row2 <= rgb565;   // 第 2 个字
              if (u == 12'd6)  o_row3 <= rgb565;   // 第 3 个字
              if (u == 12'd8)  o_row4 <= rgb565;   // 第 4 个字
              if (u == 12'd10) o_row5 <= rgb565;   // 第 5 个字
              if (u == 12'd12) o_row6 <= rgb565;   // 第 6 个字
              if (u == 12'd14) o_row7 <= rgb565;   // 第 7 个字
          end

          if (in_win) begin
            o_cmp <= o_cmp + 24'd1;
            if (rgb565 !== e) begin
                o_bad <= o_bad + 24'd1;
                if (o_bad == 24'd0) begin      // 只记【第一个】错像素
                    o_got <= rgb565;
                    o_exp <= e;
                    o_u   <= u[9:0];
                    o_v   <= v[8:0];
                end
            end
          end
        end
    end

endmodule
