
// ============================================================
//  startup_pulse —— 上电后"打一拍"的脉冲发生器
//  作用：复位释放以后，等 CNT_MAX 个时钟，然后给出【一个时钟宽】的脉冲，
//        之后再也不发（S_done 锁住）。
//  例程用它触发一次 EDID 读取（I_edid_read_trig）。
//  ★ 注意：I_rst 是【高有效】，而且这里用的是异步复位
//     （always 里写了 or posedge I_rst）
// ============================================================
module startup_pulse #(
    parameter [19:0] CNT_MAX = 20'd100000 // 等多少个时钟再打脉冲
                                          // 100000 @ 25MHz = 4ms
)(
    input  wire I_clk,                    // 时钟（接像素时钟即可）
    input  wire I_rst,                    // 复位，★高有效
    output reg  O_pulse                   // 输出：一个时钟宽的脉冲
);

reg [19:0] S_cnt;                         // 计数器
reg        S_done;                        // 已经打过了 -> 锁住，不再重复

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_cnt   <= 20'd0;
        S_done  <= 1'b0;
        O_pulse <= 1'b0;
    end
    else begin
        O_pulse <= 1'b0;                  // 默认拉低 -> 天然只出一拍

        if (!S_done) begin                // 还没打过脉冲
            if (S_cnt == CNT_MAX - 1'b1) begin   // 数满了
                S_cnt   <= S_cnt;         // 停住（反正也不再用它）
                S_done  <= 1'b1;
                O_pulse <= 1'b1;          // ← 就是这一拍
            end
            else begin
                S_cnt <= S_cnt + 1'b1;
            end
        end
    end
end

endmodule
