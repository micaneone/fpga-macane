// ============================================================
//  模块名 : udiv_q16_up
//  作用   : 顺序除法器 —— 算 ceil((a << 16) / b)，即 Q16.16 的 a/b、**向上取整**
//  时钟域 : 调用方给（本设计里是像素域 40 MHz，只在换档/换图时跑一次）
//  依据   : 规划\B轨缩放器设计说明.md §4（"适配"档的那一次除法）
// ------------------------------------------------------------
//  为什么要它：窗口要"等比适配"时 step = max(src_w/win_w, src_h/win_h)，
//  免不了除一次。32 位组合除法器又大又慢，而这里**换一次档才跑一次**
//  （32 拍 ≈ 0.8us @40MHz，一帧 16.6ms），所以用顺序移位相减最省资源。
//
//  ★★ 为什么是【向上取整】（这一条是 tb 抓出来的）：
//      step 是"每屏幕像素走多少源像素"，图在屏上的宽度 = src·65536/step。
//      若向下取整，宽度会**略大于**窗口（例：640 宽适配 800，step=52428 时
//      宽度 = 800.0012 像素）—— 严格说右边缘会掉一丁点。
//      向上取整则保证 src·65536 ≤ win·step，即**整张图一定放得下**
//      （代价只是可能留不到 1 个源像素的余量，肉眼看不见）。
//
//  ★ 实现：ceil(p/q) = floor((p + q - 1)/q)，在装被除数时把 (b-1) 加进去就行。
//  ★ 使用：start 给一拍 -> busy 拉高 32 拍 -> done 给一拍脉冲，此时 q 有效。
//  ★ b = 0 时不要 start（调用方保证）；否则结果是 0。
// ============================================================
`timescale 1ns / 1ps

module udiv_q16_up (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,      // 一拍脉冲：开始算
    input  wire [15:0] a,          // 被除数（整数）
    input  wire [15:0] b,          // 除数（整数，不能为 0）
    output reg  [31:0] q,          // ceil((a<<16)/b)
    output reg         done,       // 一拍脉冲：q 有效
    output wire        busy
);

    reg [31:0] dd;      // 被除数（a<<16 + b-1），每拍左移一位
    reg [31:0] quo;     // 商（逐位凑）
    reg [32:0] rem;     // 余数（33 位，够放下移位后的值）
    reg [5:0]  cnt;     // 还剩多少拍
    reg        run;

    assign busy = run;

    // 这一拍要试的余数 = rem 左移一位、再补进被除数的最高位
    wire [32:0] rem_sh = {rem[31:0], dd[31]};
    wire        ge     = (rem_sh >= {17'd0, b});
    wire [32:0] rem_n  = ge ? (rem_sh - {17'd0, b}) : rem_sh;
    wire [31:0] quo_n  = {quo[30:0], ge};   // 够减 -> 商这一位是 1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run  <= 1'b0;
            done <= 1'b0;
            q    <= 32'd0;
            dd   <= 32'd0;
            quo  <= 32'd0;
            rem  <= 33'd0;
            cnt  <= 6'd0;
        end
        else begin
            done <= 1'b0;                       // 默认不给脉冲

            if (start && !run) begin
                dd  <= {a, 16'd0} + {16'd0, b} - 32'd1;   // ★ + (b-1) = 向上取整
                quo <= 32'd0;
                rem <= 33'd0;
                cnt <= 6'd32;
                run <= 1'b1;
            end
            else if (run) begin
                rem <= rem_n;
                dd  <= {dd[30:0], 1'b0};
                quo <= quo_n;
                cnt <= cnt - 6'd1;
                if (cnt == 6'd1) begin          // 最后一拍
                    run  <= 1'b0;
                    done <= 1'b1;
                    q    <= quo_n;
                end
            end
        end
    end

endmodule
