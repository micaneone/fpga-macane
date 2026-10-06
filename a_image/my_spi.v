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
    output reg                  spi_mosi
);
reg  [15:0] div_cnt;
wire        cnt_inc = (div_cnt == sck_div);
reg [$clog2(data_width):0] bit_cnt_send;
reg [1:0] cnt;
reg spi_end_require;
reg [$clog2(data_width):0] bit_cnt_receive;
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        div_cnt <= 16'd0;
    else if (!spi_cs||spi_init_start) begin
        if (cnt_inc)
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
    else if (!spi_cs || spi_init_start)
        spi_clk <= cnt[1];    
    else
        spi_clk <= 1'b0;
end
endmodule
