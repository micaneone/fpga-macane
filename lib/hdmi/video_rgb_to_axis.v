
// ============================================================
//  video_rgb_to_axis —— 把"逐拍扫描信号"翻译成"axis 流"
//
//  为什么需要它：
//    我们手上的是一路逐拍扫描信号：de + rgb（还有 vs 表示帧边界）。
//    HDMI 核要的却是一条"像素流"，而且要知道三个位置：
//        user  = 这一帧的第一个像素（SOF）
//        last  = 这一行的最后一个像素（EOL）
//        valid = 这一拍的数据有效
//    这个模块就是做这个翻译。
//
//  数据是"打一拍"出去的：valid / data / user / last 都比输入晚一拍，
//  所以它们之间是对齐的（这一点很重要，别单独改其中一个）。
//
//  ★ 改自官方 video_rgb_to_axis_640x480.v：
//      · 模块改名（去掉 640x480）
//      · 639 改成参数 pic_wide-1（可以换分辨率了）
//      · 增删见下面带 ★ 的注释
// ============================================================

module video_rgb_to_axis#(
    parameter  [10:0]pic_wide=640,   // 每行可见像素数 = 屏宽（要跟 video_timing 一致）
    parameter  [9:0]pic_high=480     // 每帧可见行数 = 屏高
                                     // ★ 目前本模块【没用到】它（帧边界靠 user 标），
                                     //   留着是为了和 video_timing 的参数对齐、以后要用
)
(
    input  wire        I_clk,        // 像素时钟
    input  wire        I_rst,        // 复位，★高有效，异步
    input  wire        I_vs,         // 场同步（只用它的"跳变"来标帧首）
    input  wire        I_de,         // 数据有效（可见区）
    input  wire [23:0] I_rgb,        // 24 位像素 {R,G,B}

    output reg         O_video_user, // 帧首标志，脉冲一拍
    output reg         O_video_valid,// = de 打一拍
    output reg         O_video_last, // 行尾标志，脉冲一拍
    output reg  [23:0] O_video_data  // = rgb 打一拍
);

reg        S_vs_1d;      // vs 打一拍，用来找跳变
reg        S_de_1d;      // de 打一拍，用来找"行首"（de 上升沿）
reg        S_frame_arm;  // 1 = 还没标过帧首；标过一次就清 0
reg [10:0] S_x_cnt;      // 行内像素计数（比"当前输入像素的列号"慢一拍，见下面 ★）

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_vs_1d       <= 1'b0;
        S_de_1d       <= 1'b0;
        S_frame_arm   <= 1'b1;
        S_x_cnt       <= 11'd0;
        O_video_user  <= 1'b0;
        O_video_valid <= 1'b0;
        O_video_last  <= 1'b0;
        O_video_data  <= 24'd0;
    end
    else begin
        S_vs_1d <= I_vs;                 // 打一拍，给下面找跳变用
        S_de_1d <= I_de;

        O_video_user  <= 1'b0;           // 默认拉低 -> 天然只出一拍
        O_video_valid <= I_de;           // valid 跟 de 打一拍
        O_video_last  <= 1'b0;           // 默认拉低
        O_video_data  <= I_rgb;          // data 跟 rgb 打一拍

        // 任意一次 VS 跳变后，把“下一次 active video 的首像素”当成 SOF
        if (S_vs_1d != I_vs)             // vs 上升或下降都算（不管极性）
            S_frame_arm <= 1'b1;

        if (I_de) begin
            if (!S_de_1d) begin          // de 上升沿 = 一行的第一个像素
                // 一行首像素
                S_x_cnt <= 11'd0;
                if (S_frame_arm) begin
                    O_video_user <= 1'b1;  // ← 帧首就是这里（下一拍和第一个像素的 data 同时有效）
                    S_frame_arm  <= 1'b0;
                end
            end
            else begin
                S_x_cnt <= S_x_cnt + 11'd1;
            end

            // ============================================================
            //  ★★ 这里有个"差一拍"的坑（官方原版也有） — 实测确认过的
            //
            //   S_x_cnt 在"行首那一拍"只是被清 0（没有跟着数），所以它看到的
            //   值永远比"当前输入像素的列号"小 1：
            //        第 0 个像素那拍 : S_x_cnt = 0
            //        第 1 个像素那拍 : S_x_cnt = 0   ← 慢了一拍
            //        第 n 个像素那拍 : S_x_cnt = n-1
            //   于是拿它跟 pic_wide-1(639) 比，永远等到"de 已经拉低之后"才相等，
            //   而那段代码在 if(I_de) 里面 —— 结果 last 【一次都不会拉高】。
            //
            //   实测（ModelSim，640x480，跑两行）：
            //      写 pic_wide-1 : last 出现 0 次      ← 错误（官方原版 11'd639 也一样）
            //      写 pic_wide-2 : last 出现 2 次，且 data = 639（正好是每行最后一个像素）✓
            //
            //   ⚠️ 为什么可能"看着也能出图"：HDMI 核自己有 HACTIVE 参数，
            //      可以自己数像素；所以 last 丢了不一定出事。
            //      但把它修对没有任何坏处（核若不用它，多一个正确的 EOL 也没影响）。
            //
            //  【改动记录 09-21】这一行原来是 pic_wide-1，已改成 pic_wide-2 并实测通过。
            //   如果你想自己复现/对比，把 -2 改回 -1 再跑一遍就能看到 last 变成 0 次。
            // ============================================================
            if (S_x_cnt == pic_wide - 2)      // ← 09-21 由 pic_wide-1 改成 -2（修正 last 永不拉高）
                O_video_last <= 1'b1;
        end
        else begin
            S_x_cnt <= 11'd0;
        end
    end
end

endmodule
