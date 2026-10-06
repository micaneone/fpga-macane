// ============================================================
//  模块名 : UART_sendchar
//  功能   : UART 发送一个字节（8N1，LSB first）
// ------------------------------------------------------------
//  参数
//    baud    : 波特率，默认 115200
//    sys_clk : 时钟频率，默认 50 MHz
//  端口
//    clk       时钟
//    rst_n     复位，低电平有效，异步
//    str       要发送的字节
//    en        发送触发  ★ 必须是一拍脉冲
//    UART_out  串行输出（空闲为高）
//    busy      正在发送中；为高时不要重复触发
// ------------------------------------------------------------
//  ★ 时序约定
//    · en 拉高一拍、且 busy==0 → 下一拍开始发送，busy 拉高
//    · 一帧约 10 个位周期，发完 busy 自动落低
//    · en 一直保持高也不会连发两个（内部判 busy），但推荐只给一拍
// ------------------------------------------------------------
//  内部实现
//    发送缓存 send_buffer = {停止位1, 数据8位, 起始位0}，
//    每 divide+1 个时钟（divide = sys_clk/baud - 1）移出一位。
// ------------------------------------------------------------
//  ★ 已知细节（以后改动时注意）
//    移出条件是 addr < 9，也就是只明确输出"起始位 + 8 位数据"共 9 位；
//    停止位是靠"下一帧要等一个位周期才发起始位"那段空闲补上的。
//    功能上没问题（每字节仍然占满 10 个位周期），但它耦合了调用方的时序：
//    如果以后改了"等待一个位周期"的逻辑，停止位就不完整了。
//    想更稳妥可以改回 addr < 10，让停止位在模块内部明确发完。
// ============================================================
module UART_sendchar
#(
    parameter  baud=115200,sys_clk=50_000_000
)
(
    input [7:0]str,
    input en,clk,rst_n,
    output reg UART_out,
    output reg busy
);
localparam divide = sys_clk/baud-1;
reg [9:0]send_buffer;
reg [4:0]addr;
reg [15:0]tim;
always @(posedge clk,negedge rst_n) begin
    if(!rst_n) begin
        addr<=5'd0;
        UART_out<=1'b1;
        busy<=1'b0;
        tim<=16'd0;
    end
    else begin
        if(en==1'b1&&busy==1'b0) begin
            busy<=1'b1;
            send_buffer<={1'b1,str[7:0],1'b0}; //bit9停止位,bit8~1数据,bit0起始位
            addr<=5'd0;
            tim<=16'd0;
        end
        else begin
            if(busy==1'b1) begin
                if(tim==divide)begin
                    addr<=addr+1'b1;
                    if(addr < 5'd9) begin //0~9，addr=9是停止位
                        UART_out<=send_buffer[addr];
                    end
                    else begin
                        addr<=5'd0;
                        UART_out<=1'b1;
                        busy<=1'b0;
                    end
                    tim<=16'd0;
                end
                else tim<=tim+1'b1;
            end
        end
    end
end
endmodule
