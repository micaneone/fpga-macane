// ============================================================
//  模块名 : frame_gen
//  作用   : 从行场时序里产生两个【全项目都要用】的帧信号：
//             frame_start —— 每帧一个脉冲（帧首，VSYNC 的上升沿）
//             frame_id    —— 16 位自由运行的帧号
//  层次   : 显示链的"计时基准"（像素域 40 MHz），比合成器还靠下
//  依据   : 契约第七节（FRM_ID_W / FRM_START_W）、B轨说明书 §4.5
// ------------------------------------------------------------
//  为什么这两个信号这么重要（它们不是"顺便产生"的）：
//    所有"到某个时刻才生效"的机制都挂在这两个信号上：
//      · 描述符表整份切换（desc_rx）：B 在 frame_start 那一拍才采新表
//      · 窗口表 / 布局切换（C 提交，M2）：同一个道理
//      · 转场进度：C 用 frame_id 算 progress = (frame_id - t0) * 255 / duration
//        —— 两屏各自算、天然同步，不用传进度
//      · 双机同帧判定（M4）：比 frame_id 就知道两边差了几帧
//    所以它是"同一帧号生效"这个机制的物理载体（B轨说明书 §4.5）。
//
//  ★ 帧首取的是 VSYNC 的【上升沿】：此时整屏正在消隐，改什么都不可能被看见，
//    所以是"整份切换"最安全的时刻。
//  ★ frame_id 在 frame_start 那一拍就已经是【新帧】的号了
//    （同一拍里 +1），用的时候注意这一点。
//  ★ 复位后 frame_id = 0；第一个 frame_start 之后变成 1。
//    想算转场进度就记 t0，用 (frame_id - t0) 就对了。
//
//  ★ 这一级【只加两个寄存器】，组合逻辑几乎为零 —— 放在像素域最前面，
//    时序上完全不用担心。M4 从机模式要"用主机的 VSYNC 复位本机行计数"，
//    到时候在这一级加一个同步输入即可（不是现在的事）。
// ============================================================
`timescale 1ns / 1ps

module frame_gen (
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        vs,             // 正极性：VSYNC 期间为 1（video_timing 的输出）

    output reg         frame_start,    // 每帧一拍的高脉冲
    output reg  [15:0] frame_id        // 16 位帧号，自由运行
);

    reg vs_d;
    wire vs_rise = vs & ~vs_d;         // VSYNC 上升沿 = 帧首

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            vs_d        <= 1'b0;
            frame_start <= 1'b0;
            frame_id    <= 16'd0;
        end
        else begin
            vs_d        <= vs;
            frame_start <= vs_rise;
            if (vs_rise) frame_id <= frame_id + 16'd1;
        end
    end

endmodule
