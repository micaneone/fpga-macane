// ============================================================
//  frame_fifo_write.v —— 帧缓冲的【写】半边（全部在 mem_clk 域）
//
//  它负责：把异步 FIFO 里的像素，用【突发】的方式一包一包写进 SDRAM。
//
//  ★ 这里藏着一段"看起来很奇怪但必要"的逻辑：垂直翻转（WRITE_V_FLIP）。
//    BMP 图像的像素是【从下往上】存的（最后一行在最前面），
//    而 SDRAM 里我们想按显示顺序存。两种办法：
//      · 显示时倒着读（要改读地址，麻烦）
//      · 写入时就把行序翻过来（这里选的）
//    翻转的地址映射用三个常数：
//      VFLIP_FIRST_ADDR_OFFSET = (FRAME_HEIGHT-1) * FRAME_WIDTH
//      VFLIP_LINE_JUMP         = (FRAME_WIDTH * 2) - 1
//      VFLIP_LINE_LAST_X       = FRAME_WIDTH - 1
//    ★ 三个都是按 FRAME_WIDTH/HEIGHT 推出来的，换分辨率不用改代码 ——
//      但换完要实测（翻转是最容易出"上下颠倒"或"斜纹"的地方）
//
//  握手：write_req 一直举着直到 write_req_ack；写满一帧给 write_finish
//
//  ★ 文件里那些 `//wr_burst_xxx <= ...` 的行是原厂【注释掉的旧 burst 接口代码】
//    （本设计不用它，走的是 App_wr_en/App_wr_addr 那一套）。保持原样别删。
// ============================================================
`timescale 1ns/1ps
module frame_fifo_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 128,
	parameter WRITE_V_FLIP           = 1,      // 1 = 把图像行序倒过来写，抵消 BMP 的从下往上存储
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
)               
(
	input                            rst,                  
	input                            mem_clk,                    // 存储控制器（SDRAM）域时钟
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	input							 App_rd_busy,
    output							 O_wr_busy,
	
	output 							 App_wr_en,
	output  [ADDR_BITS - 1:0]	 	App_wr_addr,
	/*
    output reg                       wr_burst_req,               // 发给存储器：发起一次突发写  
	output reg[BURST_BITS - 1:0]     wr_burst_len,               // 发给存储器：这次突发写的长度（单位是字） 
	output reg[ADDR_BITS - 1:0]      wr_burst_addr,              // 发给存储器：这次突发写的基地址 
	input                            wr_burst_data_req,          // 来自存储器：要写数据了（比数据早一拍） 
	input                            wr_burst_finish,            // 来自存储器：这次突发写结束
	*/
	input                            write_req,                  // 写侧请求：一直举着，直到 write_req_ack 拉高（原厂这里笔误写成 read_req_ack）
	output reg                       write_req_ack,              // 写侧请求被受理
	output                           write_finish,               // 写侧一帧写完了
	input[ADDR_BITS - 1:0]           write_addr_0,               // 写侧缓冲基地址 0（write_addr_index=0 时用它）
	input[ADDR_BITS - 1:0]           write_addr_1,               // 写侧缓冲基地址 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // 写侧缓冲基地址 2（原厂注释抄错了）
	input[ADDR_BITS - 1:0]           write_addr_3,               // 写侧缓冲基地址 3（原厂注释抄错了）
	input[1:0]                       write_addr_index,           // 4 选 1：挑一个缓冲当基地址
	input[ADDR_BITS - 1:0]           write_len,                  // 写侧：这一帧要写多少个字
	output reg                       fifo_aclr,                  // 给 FIFO 的异步清零
	input[9:0]                      rdusedw                     // 来自 FIFO：还能读多少字
);
localparam ONE                       = 256'd1;                   // 256 位的全 1（可以用 ONE[n-1:0] 只取 n 位）
localparam ZERO                      = 256'd0;                   // 256 位的全 0

// 垂直翻转的地址映射（原厂注释写死 640x480，其实是按 FRAME_WIDTH/HEIGHT 参数化的）
// 输入数据的顺序不变，只把写进 SDRAM 的地址重映射：
// 输入第 0 行 → 存到第 FRAME_HEIGHT-1 行，第 1 行 → FRAME_HEIGHT-2 行 ……（正好抵消 BMP 从下往上的存法）
localparam [ADDR_BITS - 1:0] VFLIP_FIRST_ADDR_OFFSET = (FRAME_HEIGHT - 1) * FRAME_WIDTH;
localparam [ADDR_BITS - 1:0] VFLIP_LINE_JUMP         = (FRAME_WIDTH * 2) - 1;
localparam [15:0]            VFLIP_LINE_LAST_X       = FRAME_WIDTH - 1;

// 写状态机
localparam S_IDLE                    = 0;                        // 空闲：等写请求
localparam S_ACK                     = 1;                        // 受理写请求
localparam S_CHECK_FIFO              = 2;                        // 查 FIFO 状态：有足够数据才发突发写
localparam S_WRITE_BURST             = 3;                        // 开始一次突发写
localparam S_WRITE_BURST_END         = 4;                        // 一次突发写结束
localparam S_END                     = 5;                        // 一帧写完了


reg                                 write_req_d0;                // 异步的 write_req 同步到 mem_clk 域：第一拍
reg                                 write_req_d1;                // 第二拍
reg                                 write_req_d2;                // 第三拍（为什么要 3 拍？这是设计习惯：多打一拍留余量）
reg[ADDR_BITS - 1:0]                write_len_d0;                // 异步的 write_len 同步到 mem_clk 域：第一拍
reg[ADDR_BITS - 1:0]                write_len_d1;                // 第二拍
reg[ADDR_BITS - 1:0]                write_len_latch;             // 锁存这次要写的长度
reg[ADDR_BITS - 1:0]                write_cnt;                   // 已经写了多少字
reg[1:0]                            write_addr_index_d0;
reg[1:0]                            write_addr_index_d1;
reg[3:0]                            state;                       // 状态机
reg [ADDR_BITS - 1:0]	 App_wr_addr_r;
reg [15:0]                            wr_x;                       // 当前是输入这一行里的第几个像素

reg [BURST_BITS - 1:0]				burst_cnt;
wire								wr_burst_finish;

reg App_wr_en_r;
reg App_wr_en_d0;

wire into_burst;
assign into_burst = (((write_len_latch <= (rdusedw + write_cnt))||rdusedw > BURST_SIZE) && ~App_rd_busy);//当rd在突发时不会进入burst

assign App_wr_addr = {App_wr_addr_r[ADDR_BITS - 1:0]};
// （原厂注释掉的旧写法，保留作参考）assign O_wr_busy = ...
assign O_wr_busy = (state == S_WRITE_BURST || (state == S_CHECK_FIFO && into_burst));//在突发，或者将要突发，则显示busy
// ★★ 2026-10-02 集成修正（B 轨，见 规划\B轨待改清单.md）：
//   原判据只认"凑满一整串（BURST_SIZE = 256 字）"，可是这一帧的字数如果不是
//   BURST_SIZE 的整数倍，最后一串会被上面第 188 行的
//   `burst_cnt + write_cnt + App_wr_en < write_len_latch` 提前掐掉 ——
//   burst_cnt 从此停在尾巴长度上，永远到不了 BURST_SIZE，
//   于是 wr_burst_finish 永远不为真 → 状态机卡在 S_WRITE_BURST 出不来
//   → write_finish 不来 → A 一直等 a_wr_done，"忙"永远不落（连描述符都提交不了）。
//   实测：640x480 = 153,600 字 = 正好 600 串，每次都是整串，所以一直没暴露；
//         800x600 = 240,000 字 = 937.5 串（尾巴只剩 128 字）→ 当场卡死。
//   修法：写到"这一帧的最后一个字"也算这一串结束。
//   （整串的情况判据不变，所以对 640x480 这一类是零影响。）
assign wr_burst_finish = (burst_cnt >= BURST_SIZE) ||
                         ((write_cnt + burst_cnt) >= write_len_latch);
assign write_finish = (state == S_END) ? 1'b1 : 1'b0;            // 到 S_END 状态 = 写完了
assign App_wr_en = App_wr_en_d0;


always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		write_req_d0    <=  1'b0;
		write_req_d1    <=  1'b0;
		write_req_d2    <=  1'b0;
		write_len_d0    <=  ZERO[ADDR_BITS - 1:0];              // 等价于 write_len_d0 <= 0;
		write_len_d1    <=  ZERO[ADDR_BITS - 1:0];              // 等价于 write_len_d1 <= 0;
		write_addr_index_d0    <=  2'b00;
		write_addr_index_d1    <=  2'b00;
	end
	else
	begin
		write_req_d0    <=  write_req;
		write_req_d1    <=  write_req_d0;
		write_req_d2    <=  write_req_d1;
		write_len_d0    <=  write_len;
		write_len_d1    <=  write_len_d0;
		write_addr_index_d0 <= write_addr_index;
		write_addr_index_d1 <= write_addr_index_d0;
	end 
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_wr_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_wr_en_d0 <= 1'b0;
		wr_x <= 16'd0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_wr_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				wr_x <= 16'd0;
				if(write_addr_index_d1 == 2'd0)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_0 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_0;
				else if(write_addr_index_d1 == 2'd1)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_1 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_1;
				else if(write_addr_index_d1 == 2'd2)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_2 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_2;
				else if(write_addr_index_d1 == 2'd3)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_3 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_3;
			end
		else if(App_wr_en)
			begin
				if(WRITE_V_FLIP)
				begin
					if(wr_x == VFLIP_LINE_LAST_X)
					begin
						wr_x <= 16'd0;
						App_wr_addr_r <= App_wr_addr_r - VFLIP_LINE_JUMP;
					end
					else
					begin
						wr_x <= wr_x + 1'b1;
						App_wr_addr_r <= App_wr_addr_r + 1'b1;
					end
				end
				else
					App_wr_addr_r <= App_wr_addr_r + 1'b1;
			end
		else
			App_wr_addr_r <= App_wr_addr_r;
		//
		if(App_wr_en_r && burst_cnt + App_wr_en < BURST_SIZE && (burst_cnt + write_cnt + App_wr_en < write_len_latch))begin
            App_wr_en_d0 <= 1'b1;
        end
		else
			App_wr_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		write_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//wr_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//wr_burst_req <= 1'b0;
		App_wr_en_r <= 1'b0;
		
		write_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		write_req_ack <= 1'b0;
		//wr_burst_len <= ZERO[BURST_BITS - 1:0];
		
		
	end
	else 
		case(state)
			// 空闲：write_req_d2 拉高就去 S_ACK
			S_IDLE:
			begin
				if(write_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				write_req_ack <= 1'b0;
			end
			// S_ACK：受理请求 + 清 FIFO + 锁存基地址和长度
			S_ACK:
			begin
				// 请求撤销后去 S_CHECK_FIFO，同时把 write_req_ack 拉低
				if(write_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					write_req_ack <= 1'b0;
				end
				else
				begin
					// 受理写请求
					write_req_ack <= 1'b1;
					// 清 FIFO
					fifo_aclr <= 1'b1;
					// 4 选 1：挑一个缓冲当基地址
					/*
					if(write_addr_index_d1 == 2'd0)
						wr_burst_addr <= write_addr_0;
					else if(write_addr_index_d1 == 2'd1)
						wr_burst_addr <= write_addr_1;
					else if(write_addr_index_d1 == 2'd2)
						wr_burst_addr <= write_addr_2;
					else if(write_addr_index_d1 == 2'd3)
						wr_burst_addr <= write_addr_3;
					*/
					// 锁存长度
					write_len_latch <= write_len_d1;                    
				end
				// 写计数器清零
				write_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				// 这时如果又来了请求，就回 S_ACK
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				// 确认 FIFO 里数据够，就发一次突发写
				else if(into_burst)
				begin
					state <= S_WRITE_BURST;
					//wr_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//wr_burst_req <= 1'b1;
					App_wr_en_r <= 1'b1;
				end
			end 
			
			S_WRITE_BURST:
			begin
				// 一次突发结束
				if(wr_burst_finish == 1'b1)
				begin
					App_wr_en_r <= 1'b0;
					state <= S_WRITE_BURST_END;
					// 写计数器 += 突发长度
					write_cnt <= write_cnt + BURST_SIZE[ADDR_BITS - 1:0];
					// 算出下一段的起始地址
					//wr_burst_addr <= wr_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_WRITE_BURST_END:
			begin
				// 这时如果又来了请求，就回 S_ACK
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				// 还没写满一帧就继续，
				// 否则这一帧写完了
				else if(write_cnt < write_len_latch)
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
