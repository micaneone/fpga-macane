// ============================================================
//  frame_fifo_read.v —— 帧缓冲的【读】半边（全部在 mem_clk 域）
//
//  它负责：收到 read_req 后，按 read_addr_N + read_len，
//  用【突发】的方式一包一包从 SDRAM 读出来，塞进异步 FIFO。
//
//  为什么要"突发"：一次读一大段（BURST_SIZE），比一个地址一个地址地读
//  效率高得多（SDRAM 每次换行都要重新激活）。这里的思路是：
//  先看 FIFO 有没有足够空间 → 有就发一次突发 → 读满一帧就结束。
//
//  几个关键握手：
//    read_req      上层"我要一帧数据"，一直举着
//    read_req_ack  本模块收下了
//    read_finish   这一帧读完了
//    App_rd_en/App_rd_addr  发给 SDRAM（要一个地址）
//    Sdr_rd_en     SDRAM 回"这一拍的数据有效"（读延迟由硬件定）
//  ★ Sdr_busy（SDRAM 正在刷新）时不能发请求，要等它
//
//  ★ 文件里那些 `//rd_burst_xxx <= ...` 的行是原厂【注释掉的旧 burst 接口代码】
//    （本设计不用它，走的是 App_rd_en/App_rd_addr 那一套）。保持原样别删 ——
//    以后想换别的存储器控制器时可以参考。
// ============================================================
`timescale 1ns/1ps
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128
)               
(
	input                            rst,                  
	input                            mem_clk,                    // 存储控制器（SDRAM）域时钟
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
    input							 Sdr_rd_en,
	input							 App_wr_busy,
    output							 O_rd_busy,
	/*
    output reg                       rd_burst_req,               // 发给存储器：发起一次突发读  
	output reg[BURST_BITS - 1:0]     rd_burst_len,               // 发给存储器：这次突发读的长度（单位是字，不是字节） 
	output reg[ADDR_BITS - 1:0]      rd_burst_addr,              // 发给存储器：这次突发读的基地址
	input                            rd_burst_data_valid,        // 来自存储器：读回的数据 valid    
	input                            rd_burst_finish,            // 来自存储器：这次突发读结束
	*/
	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,
	
	input                            read_req,                   // 读侧请求：一直举着，直到 read_req_ack 拉高
	output reg                       read_req_ack,               // 读侧请求被受理
	output                           read_finish,                // 读侧一帧读完了
	input[ADDR_BITS - 1:0]           read_addr_0,                // 读侧缓冲基地址 0（read_addr_index=0 时用它）
	input[ADDR_BITS - 1:0]           read_addr_1,                // 读侧缓冲基地址 1（read_addr_index=1 时用它）
	input[ADDR_BITS - 1:0]           read_addr_2,                // 读侧缓冲基地址 2（原厂注释抄错了，写的也是 1）
	input[ADDR_BITS - 1:0]           read_addr_3,                // 读侧缓冲基地址 3（原厂注释抄错了）
	input[1:0]                       read_addr_index,            // 4 选 1：挑一个缓冲当基地址
	input[ADDR_BITS - 1:0]           read_len,                   // 读侧：这一帧要读多少个字
	output reg                       fifo_aclr,                  // 给 FIFO 的异步清零
	input[9:0]                      wrusedw                     // 来自 FIFO：已写入多少字

);
localparam ONE                       = 256'd1;                   // 256 位的全 1（可以用 ONE[n-1:0] 只取 n 位）
localparam ZERO                      = 256'd0;                   // 256 位的全 0
// 读状态机
localparam S_IDLE                    = 0;                        // 空闲：等读请求
localparam S_ACK                     = 1;                        // 受理读请求
localparam S_CHECK_FIFO              = 2;                        // 查 FIFO 状态：空间够才发突发读
localparam S_READ_BURST              = 3;                        // 开始一次突发读
localparam S_READ_BURST_END          = 4;                        // 一次突发读结束
localparam S_END                     = 5;                        // 一帧读完了

reg                                  read_req_d0;                // 异步的 read_req 同步到 mem_clk 域：第一拍
reg                                  read_req_d1;                // 第二拍
reg                                  read_req_d2;                // 第三拍（为什么要 3 拍？这是设计习惯：多打一拍留余量）
reg[ADDR_BITS - 1:0]                 read_len_d0;                // 异步的 read_len 同步到 mem_clk 域：第一拍
reg[ADDR_BITS - 1:0]                 read_len_d1;                // 第二拍
reg[ADDR_BITS - 1:0]                 read_len_latch;             // 锁存这次要读的长度
reg[ADDR_BITS - 1:0]                 read_cnt;                   // 已经读了多少字
reg[3:0]                             state;                      // 状态机
reg[1:0]                             read_addr_index_d0;         // 同步到 mem_clk 域：第一拍
reg[1:0]                             read_addr_index_d1;         // 同步到 mem_clk 域：第二拍
reg [ADDR_BITS - 1:0]	 App_rd_addr_r;

reg [BURST_BITS - 1:0]				burst_cnt;
wire								rd_burst_finish;
reg App_rd_en_r;
reg App_rd_en_d0;


wire rd_vld;
reg [3:0] rd_delay;

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};
assign rd_vld = (state == S_READ_BURST && burst_cnt >= BURST_SIZE);

assign O_rd_busy = (state == S_READ_BURST);//读指令期间
//burst_cnt代表发送的读指令
//但rd_burst_finish需要在发送完十个时钟后拉高，此时数据全部读出
assign rd_burst_finish = (rd_vld && rd_delay == 4'd10);
assign read_finish = (state == S_END) ? 1'b1 : 1'b0;             // 到 S_END 状态 = 读完了
assign App_rd_en = App_rd_en_d0;
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		read_req_d0    <=  1'b0;
		read_req_d1    <=  1'b0;
		read_req_d2    <=  1'b0;
		read_len_d0    <=  ZERO[ADDR_BITS - 1:0];               // 等价于 read_len_d0 <= 0;
		read_len_d1    <=  ZERO[ADDR_BITS - 1:0];               // 等价于 read_len_d1 <= 0;
		read_addr_index_d0 <= 2'b00;
		read_addr_index_d1 <= 2'b00;
	end
	else
	begin
		read_req_d0    <=  read_req;
		read_req_d1    <=  read_req_d0;
		read_req_d2    <=  read_req_d1;     
		read_len_d0    <=  read_len;
		read_len_d1    <=  read_len_d0; 
		read_addr_index_d0 <= read_addr_index;
		read_addr_index_d1 <= read_addr_index_d0;
		
	end 
end

always @(posedge mem_clk or posedge rst)
begin
	if(rst || App_rd_en)begin
        rd_delay <= 4'd0;
    end
    else if(rd_delay < 4'd10)begin
    	rd_delay <= rd_delay + 1'b1;
    end
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_rd_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_d0 <= 1'b0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_rd_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				if(read_addr_index_d1 == 2'd0)
					App_rd_addr_r <= read_addr_0;
				else if(read_addr_index_d1 == 2'd1)
					App_rd_addr_r <= read_addr_1;
				else if(read_addr_index_d1 == 2'd2)
					App_rd_addr_r <= read_addr_2;
				else if(read_addr_index_d1 == 2'd3)
					App_rd_addr_r <= read_addr_3;
			end
		else if(App_rd_en)
			App_rd_addr_r <= App_rd_addr_r + 1'b1;
		else
			App_rd_addr_r <= App_rd_addr_r;
		//
		if(App_rd_en_r && burst_cnt + App_rd_en < BURST_SIZE)
			App_rd_en_d0 <= 1'b1;
		else
			App_rd_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		read_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//rd_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//rd_burst_req <= 1'b0;
		App_rd_en_r <= 1'b0;
		
		read_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		//rd_burst_len <= ZERO[BURST_BITS - 1:0];
		read_req_ack <= 1'b0;
	end
	else
		case(state)
			// 空闲：read_req_d2 拉高就去 S_ACK
			S_IDLE:
			begin
				if(read_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				read_req_ack <= 1'b0;
			end
			// S_ACK：受理请求 + 清 FIFO + 锁存基地址和长度
			S_ACK:
			begin
				if(read_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					read_req_ack <= 1'b0;
				end
				else
				begin
					// 受理读请求
					read_req_ack <= 1'b1;
					// 清 FIFO
					fifo_aclr <= 1'b1;
					// 4 选 1：挑一个缓冲当基地址
					/*
					if(read_addr_index_d1 == 2'd0)
						App_rd_addr <= read_addr_0;
					else if(read_addr_index_d1 == 2'd1)
						App_rd_addr <= read_addr_1;
					else if(read_addr_index_d1 == 2'd2)
						App_rd_addr <= read_addr_2;
					else if(read_addr_index_d1 == 2'd3)
						App_rd_addr <= read_addr_3;
					*/
					// 锁存长度
					read_len_latch <= read_len_d1;
				end
				// 读计数器清零
				read_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				// 这时如果又来了请求，就回 S_ACK
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				// 确认过 FIFO 空间够，就发一次突发读
				else if(wrusedw < (FIFO_DEPTH - BURST_SIZE) && ~App_wr_busy)
				begin
					state <= S_READ_BURST;
					//rd_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//rd_burst_req <= 1'b1;
					App_rd_en_r <= 1'b1;
				end
			end
			
			S_READ_BURST:
			begin
				// 一次突发结束  
				if(rd_burst_finish == 1'b1)
				begin
					App_rd_en_r <= 1'b0;
					state <= S_READ_BURST_END;
					// 读计数器 += 突发长度
					read_cnt <= read_cnt + BURST_SIZE[ADDR_BITS - 1:0];
					// 算出下一段的起始地址
					//rd_burst_addr <= rd_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_READ_BURST_END:
			begin
				// 这时如果又来了请求，就回 S_ACK
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				// 还没读满一帧就继续，
				// 否则这一帧读完了
				else if(read_cnt < read_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule
