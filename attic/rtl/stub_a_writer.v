// ============================================================
//  模块名 : stub_a_writer（测试件，不进交付仓库）
//  作用   : 假装是 A 的装载机 —— 产生一张测试图，按 A 的【写口时序】写进 SDRAM
//
//  ★ 2026-09-28 第四版：写口协议照原厂（和 A 的 bmp_sdram.v 一样）：
//      请求（base/len，举 req）→ 等 ack → 推 len 个字 → 等 done
//
//  测试图（PAT_MODE）：
//    0 = {u[7:0], v[7:0]} 渐变（仿真逐像素比对用）
//    1 = 板上自测图（8 条竖色条 + 顶白条 + 左边行标记）
//    2 = ★ 数据自己带地址：字地址 a 的字 = {a[15:0], a[15:0]}
//    3 = ★★ 数据自己带【像素】地址：像素(u,v) 的值 = (v*PAGE_W + u) 的低 16 位
//        —— 每个像素的值就是"第几行第几列"，横移/错位一看数就知道
// ============================================================
`timescale 1ns / 1ps

module stub_a_writer #(
    parameter integer PAGE_W = 160,      // 源图宽（像素，必须偶数）
    parameter integer PAGE_H = 120,      // 源图高（像素）
    parameter integer BASE   = 0,        // 写到大槽的哪个基址
    parameter integer PAT_MODE = 0
)(
    input  wire        clk_ctl,
    input  wire        rst_ctl_n,
    input  wire        start,            // 一拍脉冲：开始写一张
    input  wire        pack_swap,        // 1 = 模仿 A 老代码的像素顺序（反的）
    input  wire        sdr_ready,        // SDRAM 初始化完成

    output reg         done,             // 一拍脉冲：整张写完（已落进 SDRAM）
    output reg         busy,

    // 写口（原厂协议）
    output reg         a_wr_req,         // 举着，直到 a_wr_ack
    output reg  [20:0] a_wr_base,
    output reg  [20:0] a_wr_len,
    input  wire        a_wr_ack,
    output reg  [31:0] a_wr_data,
    output reg         a_wr_we,
    input  wire        a_wr_full,
    input  wire        a_wr_done
);

    localparam integer WPL = PAGE_W / 2;         // 每行字数
    localparam integer NW  = WPL * PAGE_H;       // 一整张多少个字

    localparam [2:0] ST_IDLE = 3'd0,
                     ST_REQ  = 3'd1,
                     ST_PUSH = 3'd2,
                     ST_WAIT = 3'd3,
                     ST_DONE = 3'd4;

    reg [2:0]  st;
    integer    v, w;
    integer    u0_, u1_;
    reg [15:0] pe, po;
    reg [20:0] pushed;                           // 已经推了多少个字
    reg        start_lat;                        // ★ 收到 start 先记住，等 sdr_ready 再发请求
    reg [24:0] wdt_cnt;                          // ★ 看门狗：busy 太久就强行收尾（别让显示/A 干等）
    localparam [24:0] WDT_MAX = 25'd10_000_000;  // 200ms @50MHz

    function [15:0] pat_pix;
        input [11:0] u, vv;
        reg [31:0] a32;
        begin
            if (PAT_MODE == 3) begin
                // 像素地址：低 16 位 = v*640 + u（列号直接读得出来）
                a32 = vv * PAGE_W + u;
                pat_pix = a32[15:0];
            end
            else if (PAT_MODE == 2) begin
                a32 = vv * WPL + (u >> 1);
                pat_pix = a32[15:0];
            end
            else if (PAT_MODE == 1) begin
                if (vv < 32)         pat_pix = 16'hFFFF;
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
            else pat_pix = {u[7:0], vv[7:0]};
        end
    endfunction

    always @(posedge clk_ctl or negedge rst_ctl_n) begin
        if (!rst_ctl_n) begin
            st        <= ST_IDLE;
            v         <= 0;
            w         <= 0;
            pushed    <= 21'd0;
            start_lat <= 1'b0;
            wdt_cnt   <= 25'd0;
            a_wr_req  <= 1'b0;
            a_wr_base <= 21'd0;
            a_wr_len  <= 21'd0;
            a_wr_data <= 32'd0;
            a_wr_we   <= 1'b0;
            done      <= 1'b0;
            busy      <= 1'b0;
            pe        <= 16'd0;
            po        <= 16'd0;
        end
        else begin
            done    <= 1'b0;
            a_wr_we <= 1'b0;                       // 默认不给脉冲

            // ★ 看门狗：只要还在忙，就数拍；数到 200ms 还没收尾就强行结束。
            //   （写引擎/握手上真卡住时，别让 stwr_busy 把显示读和 A 的启动一直挡着）
            if (st == ST_IDLE) wdt_cnt <= 25'd0;
            else if (wdt_cnt < WDT_MAX) wdt_cnt <= wdt_cnt + 25'd1;

            case (st)
            ST_IDLE: begin
                busy <= 1'b0;
                wdt_cnt <= 25'd0;
                a_wr_req <= 1'b0;
                // ★ start 是一拍脉冲、sdr_ready 可能还没上来（SDRAM 初始化没完），
                //   所以先把 start 记住，等 ready 了再发请求 —— 否则这一拍就丢了。
                if (start) start_lat <= 1'b1;
                if (start_lat && sdr_ready) begin
                    v         <= 0;
                    w         <= 0;
                    pushed    <= 21'd0;
                    busy      <= 1'b1;
                    start_lat <= 1'b0;
                    a_wr_base <= BASE[20:0];
                    a_wr_len  <= NW[20:0];
                    a_wr_req  <= 1'b1;             // 举着请求
                    st        <= ST_REQ;
                end
            end

            // 等引擎受理（受理时会清 FIFO，所以这时别推数据）
            ST_REQ: if (a_wr_ack) begin
                        a_wr_req <= 1'b0;
                        st       <= ST_PUSH;
                    end

            // 推数据
            ST_PUSH: begin
                u0_ = 2*w;
                u1_ = 2*w + 1;
                pe  = pat_pix(u0_[11:0], v[11:0]);
                po  = pat_pix(u1_[11:0], v[11:0]);

                // ★ 推够了就收尾；万一引擎已经报了 finish（它在 FIFO 里的最后一段
                //   可能比我们推得快），也直接算完成 —— 免得卡在"FIFO 满"上
                if ((pushed >= NW[20:0]) || a_wr_done) begin
                    st <= ST_WAIT;
                end
                else if (!a_wr_full) begin
                    a_wr_data <= pack_swap ? {po, pe} : {pe, po};
                    a_wr_we   <= 1'b1;
                    pushed    <= pushed + 21'd1;
                    if (w == WPL-1) begin
                        w <= 0;
                        v <= v + 1;
                    end
                    else w <= w + 1;
                end
            end

            // 等引擎写完
            ST_WAIT: if (a_wr_done) st <= ST_DONE;

            ST_DONE: begin
                done <= 1'b1;
                busy <= 1'b0;
                st   <= ST_IDLE;
            end
            endcase

            // 看门狗到点：不管在哪一步，直接收尾
            if ((st != ST_IDLE) && (wdt_cnt >= WDT_MAX)) begin
                a_wr_req <= 1'b0;
                a_wr_we  <= 1'b0;
                done     <= 1'b1;
                busy     <= 1'b0;
                st       <= ST_IDLE;
            end
        end
    end

endmodule
