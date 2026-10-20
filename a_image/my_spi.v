module my_spi #(
    parameter data_width = 8,
    parameter sck_div=35
)(
    input                       sys_clk,
    input                       sys_rst_n,
    input                       spi_start,
    input                       spi_init_start,     
    input                       spi_end,      
    input  [data_width-1:0]     data_in,       
    output reg                  send_done,     
    output reg                  receive_done,  
    output reg [data_width-1:0] data_out,     
    input                       spi_miso,
    output reg                  spi_clk,
    output reg                  spi_cs,
    output reg                  spi_mosi,
    // ★★★ 2026-10-17【CMD18 多块读用】：0 = **冻结 SCLK**（CS 还举着，但不再给卡发时钟）。
    //   为什么需要：多块连续读时，两块之间要把时钟停住等调用方来要下一块 ——
    //   SD 卡在 SPI 模式下"没时钟就不动"，所以停时钟既不会丢数据、也不会让卡超时。
    //   ★ 置 0 时同时冻结 `div_cnt`/`cnt`（相位于是不漂），`spi_clk` 保持低电平。
    input                       spi_clk_en
);
reg  [15:0] div_cnt;
// ★ 2026-10-17：把"时钟使能"并进 cnt_inc —— 冻结时 div_cnt 停在原地、cnt 也不走，
//   于是 SCLK 相位不漂、恢复时从同一相位继续（`spi_clk_en` 默认 1，sd_init 那条不受影响）。
wire        ce      = spi_clk_en || spi_init_start;
wire        cnt_inc = (div_cnt == sck_div) && ce;
reg [$clog2(data_width):0] bit_cnt_send;
reg [1:0] cnt;
reg spi_end_require;
reg [$clog2(data_width):0] bit_cnt_receive;
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        div_cnt <= 16'd0;
    else if (!spi_cs||spi_init_start) begin
        // ★★★ 2026-10-17【时钟冻结时必须清零这个计数器】
        //   漏掉 `!ce` 这一支的后果（仿真抓到，实测 1.31 ms 的停顿就是它）：
        //   冻结期间 `cnt_inc` 恒 0 ⇒ 走 else 把 `div_cnt` 一路加下去；
        //   恢复时它得从当前值**绕满 16 位**（65536 拍 = 1.31 ms @50 MHz）才能再等于
        //   `sck_div`(0) ⇒ 每次从流式等待恢复都要白等 1.3 ms，比省下的 120 µs 还贵。
        if (cnt_inc || !ce)
            div_cnt <= 16'd0;
        else
            div_cnt <= div_cnt + 1'b1;
    end
    else
        div_cnt <= 16'd0;
end
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        cnt <= 2'd0;
    else if ((!spi_cs||spi_init_start)&& cnt_inc)
        cnt <= cnt + 1'b1;
    else if (spi_cs&&!spi_init_start)
        cnt <= 2'd0;
end
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        spi_cs <= 1'b1;
    else if (spi_start)
        spi_cs <= 1'b0;
    else if (spi_end_require && (cnt == 2'd1 && bit_cnt_receive == 'b0))
        spi_cs <= 1'b1;
end
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        spi_end_require <= 1'b0;
    else if (spi_cs)
        spi_end_require <= 1'b0;
    else if (spi_end)
        spi_end_require <= 1'b1;
end
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        spi_mosi      <= 1'b1;
        bit_cnt_send  <= 'b0;
    end
    else if (!spi_cs && cnt == 2'd0 && cnt_inc) begin
        spi_mosi <= data_in[data_width-1-bit_cnt_send];
        if (bit_cnt_send == data_width - 1'b1)
            bit_cnt_send <= 'b0;
        else
            bit_cnt_send <= bit_cnt_send + 1'b1;
    end
    else if (spi_cs) begin
        spi_mosi      <= 1'b1;     
        bit_cnt_send  <= 'b0;
    end
    else begin
        spi_mosi      <= spi_mosi;
        bit_cnt_send  <= bit_cnt_send;
    end
end
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        send_done <= 1'b0;
    else if (cnt == 2'd0 && bit_cnt_send == data_width - 1'b1 && cnt_inc)
        send_done <= 1'b1;
    else
        send_done <= 1'b0;
end
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        data_out         <= 'b0;
        bit_cnt_receive  <= 'b0;
    end
    else if (!spi_cs && cnt == 2'd2 && cnt_inc) begin
        data_out[data_width-1-bit_cnt_receive] <= spi_miso;
        if (bit_cnt_receive == data_width - 1'b1)
            bit_cnt_receive <= 'b0;
        else
            bit_cnt_receive <= bit_cnt_receive + 1'b1;
    end
    else if (spi_cs)
        bit_cnt_receive <= 'b0;
    else begin
        bit_cnt_receive <= bit_cnt_receive;
        data_out        <= data_out;
    end
end
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        receive_done <= 1'b0;
    else if (bit_cnt_receive == data_width - 1'b1 && cnt == 2'd2 && cnt_inc)
        receive_done <= 1'b1;
    else
        receive_done <= 1'b0;
end
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        spi_clk <= 1'b0;
    // ★ 2026-10-17：只在"CS 低且允许走时钟"时才输出时钟（冻结时保持低电平）。
    else if ((!spi_cs && spi_clk_en) || spi_init_start)
        spi_clk <= cnt[1];    
    else
        spi_clk <= 1'b0;
end
endmodule
