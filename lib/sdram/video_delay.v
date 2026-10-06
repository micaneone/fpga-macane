// ============================================================
//  video_delay.v —— 把【像素数据】和【行场时序】对齐
//
//  为什么需要它：数据从 SDRAM / 异步 FIFO 出来，比 de 晚若干拍；
//  直接输出的话整幅图会整体偏移几列。这里用一条 21 位延迟链，
//  把 hs / vs / de 一起延迟【同样的拍数】，让它们和 read_data 同拍。
//
//  三条延迟链的抽头是 18 / 19 / 20：
//    de_d[18]  → 当 read_en 用（提前两拍去要数据）
//    de_d[19]  → 决定"这一拍要不要把 read_data 锁进来"
//    de_d[20] / hs_d[20] / vs_d[20] → 输出的 de_r / hs_r / vs_r
//  ★ 这几个数字对应 SDRAM 读通路的固定延迟，和分辨率无关 ——
//    换分辨率不用改这里；但如果换了存储器或改了突发长度，要重新对。
// ============================================================
module video_delay
#(
	parameter DATA_WIDTH = 24                       // 一个时钟周期传输的像素位宽
)
(
	input                       video_clk,          // 像素时钟
	input                       rst,
	output                      read_en,            // 读使能（提前两拍去要数据）
	input[DATA_WIDTH - 1:0]     read_data,          // 读回来的数据
	input                      hs,                 // 行同步
	input                      vs,                 // 场同步
	input                      de,                 // 像素有效（可见区）

	output                      hs_r,                 // 行同步
	output                      vs_r,                 // 场同步
	output                      de_r,                 // 像素有效（可见区）
	output[DATA_WIDTH - 1:0]    vout_data           // 像素数据

);
reg [20:0] hs_d;
reg [20:0] vs_d;
reg [20:0] de_d;
reg[DATA_WIDTH - 1:0]  vout_data_r;

assign read_en = de_d[18];
assign hs_r = hs_d[20];
assign vs_r = vs_d[20];
assign de_r = de_d[20];
assign vout_data = vout_data_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(de_d[19])
		vout_data_r <= read_data;
	else
		vout_data_r <= {DATA_WIDTH{1'b0}};
end
always @(posedge video_clk or posedge rst)begin
	if(rst)begin
    	hs_d <= 20'b0;
        vs_d <= 20'b0;
        de_d <= 20'b0;
    end
	else begin
    	
    	hs_d <= {hs_d[19:0],hs};
        vs_d <= {vs_d[19:0],vs};
        de_d <= {de_d[19:0],de};
    end
end
endmodule
