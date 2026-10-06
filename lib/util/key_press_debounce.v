// ============================================================
//  key_press_debounce —— 按键消抖（按下给一个单拍脉冲）
//
//  ★ 这份不是我们写的，是从官方竞赛例程里【原样抠出来】的：
//      来源：7_lab_ex_2026_nosoft\lab_ex4_tf\src\user_source\hdl_source\SD\sd_card_bmp.v
//            （模块定义在该文件末尾，第 388 行起）
//      同一份也在 模块库\10_官方例程_可复用\lab_ex4_tf\sd_card_bmp.v 里
//    为什么抠出来单独放一个文件：它原本埋在那个 51 KB 的读图顶层里，
//    我们只需要消抖这一小块，不能把整棵读图依赖树搬进来。
//    模块体一个字符没动，只在上面加了这段说明。
//
//  ★ 为什么用它，而不是模块库里另外两套：
//      模块库\README.md §0 的速查表把「按键消抖」指向
//      key_remove_shakes.v / ax_debounce.v，但那两套分别是
//      "固定 100000 拍、不可参数化" 和 "计时器 + 双边沿输出"。
//      官方例程实际用的是这一套 key_press_debounce ——
//      它就是拿板上这两个键（key_next / key_auto）跑的，
//      参数化、语义简单（松开=1 按下=0，按一下出一个脉冲），
//      所以我们也用它。另外两套留着当备选，别重复造第四套。
//
//  接口与用法：
//      .CLK_FREQ_HZ (50_000_000)   ★ 必须填对！默认是 100 MHz，
//      .DEBOUNCE_MS (20)             填错了消抖时间就跟着错一倍
//      .rst         (~rst_n)       ★ 高有效
//      .button_in   (key1)         板上按键低有效 + 上拉，不按=1
//      .press_pulse (key1_press)   按一下出一个单拍脉冲
// ============================================================
`timescale 1ns / 1ps

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
