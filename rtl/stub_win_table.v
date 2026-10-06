// ============================================================
//  模块名 : stub_win_table（测试件，不进交付仓库）
//  作用   : 假装是 C 的【窗口表】—— 给合成器一个写死的窗口矩形
// ------------------------------------------------------------
//  为什么现在是"写死"的：
//    C 的窗口表（ERAM 双缓冲 + 帧边界切换）是 M2 才接的。
//    M1 只需要一个窗口，所以先用常量顶着 —— 但**接口保持和真表一样**，
//    将来换成 C 的表时，改的只是"这些常量从哪来"，合成器一行都不用动。
//
//  ★ 窗口四个数直接给（不是"内缩多少"）：
//      铺满全屏         : WIN_X0=0   WIN_Y0=0   WIN_W=800 WIN_H=600
//      640x480 居中     : WIN_X0=80  WIN_Y0=60  WIN_W=640 WIN_H=480   ← 今晚用这个
//    居中摆一圈底色有两个好处：
//      ① 一眼能看出"窗口逻辑在工作"（不是整屏就是图）
//      ② 图和窗口一样大，不会踩到"图比窗口小"那种边角情况
// ============================================================
`timescale 1ns / 1ps

module stub_win_table #(
    parameter integer WIN_X0 = 0,
    parameter integer WIN_Y0 = 0,
    parameter integer WIN_W  = 800,
    parameter integer WIN_H  = 600
)(
    output wire [11:0] win_x0,
    output wire [11:0] win_y0,
    output wire [11:0] win_w,
    output wire [11:0] win_h,
    output wire        win_on
);

    assign win_x0 = WIN_X0[11:0];
    assign win_y0 = WIN_Y0[11:0];
    assign win_w  = WIN_W[11:0];
    assign win_h  = WIN_H[11:0];
    assign win_on = 1'b1;

endmodule
