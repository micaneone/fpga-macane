// ============================================================
//  frame_read_write.v —— 帧缓冲（双缓冲/乒乓），三个时钟域的枢纽
//
//  它内部例化两个【异步 FIFO】，把三个时钟域连起来：
//
//    write_clk(SD 卡域) ──wfifo──► mem_clk(SDRAM 域) ──写进 SDRAM
//    mem_clk ──从 SDRAM 读──► rfifo ──► read_clk(像素域) ──送显示
//
//  ★ 两个 FIFO 不是外部的，就在这个文件里例化，模块名是
//    wfifo_32_32_512 / rfifo_32_32_512，定义在同目录的
//    afifo_16_32_256.v / afifo_32_16_256.v 里（厂商 IP 生成的纯 Verilog）
//
//  为什么必须用【异步】FIFO：三个域的时钟频率和相位都无关，
//  跨域传数据只能用异步 FIFO（用同步 FIFO 会偶发丢数据，而且仿真看不出来）
//
//  read_addr_0..3 + read_addr_index：可以放最多 4 个缓冲，
//  例程用 2 个做乒乓：BUF0 = 0、BUF1 = 一帧的像素数
//  （800×600 时就是 BUF1 = 480000）
//
//  读侧握手：read_req 一直举着，直到 read_req_ack 拉高（视频模块的约定）
// ============================================================
`timescale 1ns/1ps
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,//
	parameter BURST_SIZE             = 256,
	parameter WRITE_V_FLIP           = 1,      // 1 = 写进 SDRAM 时把行序上下翻转（抵消 BMP 从下往上存）
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
) 
(
	input                            rst,                  
	input                            mem_clk,                    // 存储控制器（SDRAM）域时钟
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    /*
    output                           rd_burst_req,               // 发给存储器：发起一次突发读
	output[BURST_BITS - 1:0]         rd_burst_len,               // 发给存储器：这次突发读的长度（单位是字，不是字节）
	output[ADDR_BITS - 1:0]          rd_burst_addr,              // 发给存储器：这次突发读的基地址 
	input                            rd_burst_data_valid,        // 来自存储器：读数据有效 
	input[MEM_DATA_BITS - 1:0]       rd_burst_data,              // 来自存储器：读回的数据
	input                            rd_burst_finish,            // 来自存储器：这次突发读结束
	*/
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 // 来自存储器：读数据有效
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
	input                            read_clk,                   // 读侧（像素域）时钟
	input                            read_req,                   // 读侧请求：一直举着，直到 read_req_ack 拉高
	output                           read_req_ack,               // 读侧请求被受理
	output                           read_finish,                // 读侧一帧读完了
	input[ADDR_BITS - 1:0]           read_addr_0,                // 读侧缓冲基地址 0（read_addr_index=0 时用它）
	input[ADDR_BITS - 1:0]           read_addr_1,                // 读侧缓冲基地址 1（read_addr_index=1 时用它）
	input[ADDR_BITS - 1:0]           read_addr_2,                // 读侧缓冲基地址 2（原厂注释抄错了，写的也是 1）
	input[ADDR_BITS - 1:0]           read_addr_3,                // 读侧缓冲基地址 3（原厂注释抄错了）
	input[1:0]                       read_addr_index,            // 4 选 1：挑一个缓冲当基地址
	input[ADDR_BITS - 1:0]           read_len,                   // 读侧：这一帧要读多少个字
	input                            read_en,                    // 读侧：要一个数据，下一拍 read_data 有效
	output[READ_DATA_BITS  - 1:0]    read_data,                  // 读出的数据
	/*
	output                           wr_burst_req,               // 发给存储器：发起一次突发写
	output[BURST_BITS - 1:0]         wr_burst_len,               // 发给存储器：这次突发写的长度（单位是字）
	output[ADDR_BITS - 1:0]          wr_burst_addr,              // 发给存储器：这次突发写的基地址 
	input                            wr_burst_data_req,          // 来自存储器：要写数据了（比数据早一拍）
	output[MEM_DATA_BITS - 1:0]      wr_burst_data,              // 发给存储器：要写的数据
	input                            wr_burst_finish,            // 来自存储器：这次突发写结束
	*/
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	//
	input                            write_clk,                  // 写侧（SD 卡域）时钟
	input                            write_req,                  // 写侧请求：一直举着，直到 write_req_ack 拉高（原厂这里笔误写成 read_req_ack）
	output                           write_req_ack,              // 写侧请求被受理
	output                           write_finish,               // 写侧一帧写完了
	input[ADDR_BITS - 1:0]           write_addr_0,               // 写侧缓冲基地址 0（write_addr_index=0 时用它）
	input[ADDR_BITS - 1:0]           write_addr_1,               // 写侧缓冲基地址 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // 写侧缓冲基地址 2（原厂注释抄错了）
	input[ADDR_BITS - 1:0]           write_addr_3,               // 写侧缓冲基地址 3（原厂注释抄错了）
	input[1:0]                       write_addr_index,           // 4 选 1：挑一个缓冲当基地址
	input[ADDR_BITS - 1:0]           write_len,                  // 写侧：这一帧要写多少个字
	input                            write_en,                   // 写侧：要一个数据（一个时钟写一个字）
	input[WRITE_DATA_BITS - 1:0]     write_data                 // 要写进去的数据

);
// ★★ 2026-09-27 修（只影响仿真，不影响综合）：
//    FIFO 输出的计数器是 9 位，而 frame_fifo_read / frame_fifo_write 的端口是 [9:0]（10 位）。
//      · 综合（TD）：未连接的最高位按 0 处理 → 比较正常
//      · 仿真（ModelSim）：最高位是 Z → 比较变未知 → 读状态机永远卡在 S_CHECK_FIFO
//    所以这里用 9 位接收、显式补一个 0 再送出去（硬件行为不变）。
wire[BURST_BITS - 1:0]                           wrusedw_f;                  // FIFO 输出的 9 位
wire[BURST_BITS - 1:0]                           rdusedw_f;
wire[9:0]                                        wrusedw = {1'b0, wrusedw_f}; // 补 0 → 10 位
wire[9:0]                                        rdusedw = {1'b0, rdusedw_f};

wire 								 App_rd_busy;
wire								 App_wr_busy;

wire                                 read_fifo_aclr;             // FIFO 异步清零
wire                                 write_fifo_aclr;            // FIFO 异步清零

wire O_wr_busy;
wire O_rd_busy;

assign App_wr_busy = O_wr_busy;//下个时钟写指令拉高
assign App_rd_busy = O_rd_busy;//读指令还没有过去十个时钟;因为写指令优先，不需要在意下个时钟是否是读指令
assign App_wr_dm = 4'b0000;

// 例化异步 FIFO（跨时钟域的关键） 
wfifo_32_32_512 write_buf
	(
	.clkr                      	(mem_clk                  ),          // 读侧时钟
	.clkw                      	(write_clk                ),          // 写侧时钟
	.rst                       	(write_fifo_aclr          ),          // 异步清零
	.we                      	(write_en                 ),          // 写请求
	.re                      	(App_wr_en        		  ),          // 读请求
	.di                       	(write_data               ),          // 输入数据
	.empty_flag                 (                         ),          // 读侧空标志
	.full_flag                  (                         ),          // 写侧满标志
	.wrusedw                	(              	  		  ),          // 读侧已用字数
	.rdusedw                	(rdusedw_f                ),          // 写侧已用字数
	.dout                       (App_wr_din		          )
);

frame_fifo_write
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.WRITE_V_FLIP               (WRITE_V_FLIP             ),
	.FRAME_WIDTH                (FRAME_WIDTH              ),
	.FRAME_HEIGHT               (FRAME_HEIGHT             )
) 
frame_fifo_write_m0              
(  
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
	.App_rd_busy				(App_rd_busy),
    .O_wr_busy					(O_wr_busy),
	
	.App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
	.write_req                  (write_req                ),
	.write_req_ack              (write_req_ack            ),
	.write_finish               (write_finish             ),
	.write_addr_0               (write_addr_0             ),
	.write_addr_1               (write_addr_1             ),
	.write_addr_2               (write_addr_2             ),
	.write_addr_3               (write_addr_3             ),
	.write_addr_index           (write_addr_index         ),    
	.write_len                  (write_len                ),
	.fifo_aclr                  (write_fifo_aclr          ),
	.rdusedw                 	(rdusedw                  )
);

// 例化异步 FIFO（跨时钟域的关键） 
rfifo_32_32_512 read_buf
	(
	.clkr                     	(read_clk                   ),          // 读侧时钟
	.clkw                     	(mem_clk                    ),          // 写侧时钟
	.rst                      	(read_fifo_aclr             ),          // 异步清零
	.we                     	(Sdr_rd_en       			),          // 写请求
	.re                     	(read_en                    ),          // 读请求
	.di                      	(Sdr_rd_dout                ),          // 输入数据
	.empty_flag					(                           ),          // 读侧空标志
	.full_flag					(                           ),          // 写侧满标志
	.wrusedw                	(wrusedw_f       	  	  		 ),          // 读侧已用字数
	.rdusedw                	(                  			 ),          // 写侧已用字数
	.dout						(read_data                  )
);

frame_fifo_read
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               )
)
frame_fifo_read_m0
(
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(Sdr_rd_en),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy),
	
    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
	.read_req                   (read_req                 ),
	.read_req_ack               (read_req_ack             ),
	.read_finish                (read_finish              ),
	.read_addr_0                (read_addr_0              ),
	.read_addr_1                (read_addr_1              ),
	.read_addr_2                (read_addr_2              ),
	.read_addr_3                (read_addr_3              ),
	.read_addr_index            (read_addr_index          ),    
	.read_len                   (read_len                 ),
	.fifo_aclr                  (read_fifo_aclr           ),
	.wrusedw                	(wrusedw                  )
);

endmodule
