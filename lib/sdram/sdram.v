// ============================================================
//  sdram.v —— SDRAM 的【包装层】（可读源码，不是加密的）
//
//  它干三件事：
//    ① 把加密的 sdr_as_ram 包成一个模块
//    ② 对外只暴露"平地址 + 32 位字"的 RAM 接口（App_wr_* / App_rd_*）
//       —— bank/row/col 那一套被加密层吃掉了，我们只管给一个地址
//    ③ 综合时把 SDRAM 的物理引脚（SDR_*）藏成【内部 wire】而不是端口
//       ★ 因为这颗 SDRAM 在【芯片封装内部】(SIP)，不是板上芯片 ——
//         所以它不需要引脚约束，也没有板级走线问题
//
//  时钟：Clk = 125MHz、Clk_sft = 125MHz 但相位差 180°
//        这一对是 SDRAM 的采样相位关系，缺一不可
//        （例程用 sys_pll 的 C1/C2 给；我们另外生成一个 PLL）
//
//  握手：写 —— App_wr_en 一拍给一个地址（要配合 App_wr_dm 决定写哪几个字节）
//        读 —— App_rd_en 进去，若干拍后 Sdr_rd_en 表示"这一拍 Sdr_rd_dout 有效"
//        Sdr_init_done 拉高之前【绝对不能】开始读写（要先等初始化）
// ============================================================
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 公司：安路（原厂把 anlogic 拼成了 anlgoic）
// 作者： 	xg 
// 描述：顶层（把 SDRAM 包成一块 RAM 用）
//////////////////////////////////////////////////////////////////////////////////

`define DEBUG

`include "global_def.v"

module sdram(
    `ifdef SIMULATION
	output					SDRAM_CLK,
	output					SDR_CKE,
	output					SDR_RAS,
	output					SDR_CAS,
	output					SDR_WE,
	output	[`BA_WIDTH-1:0]	SDR_BA,
	output	[`ROW_WIDTH-1:0]SDR_ADDR,
	output	[`DM_WIDTH-1:0]	SDR_DM,
	inout	[`DATA_WIDTH-1:0]	SDR_DQ,	
	`endif
    input   					Clk,
    input						Clk_sft,
    input						Rst,
    
    output 						Sdr_init_done,
    output						Sdr_init_ref_vld,
    output						Sdr_busy,
    
    input						App_wr_en,
	input [`ADDR_WIDTH-1:0]		App_wr_addr,  	
	input [`DM_WIDTH-1:0]		App_wr_dm,
	input [`DATA_WIDTH-1:0]		App_wr_din,	// synthesis keep：综合指令，别把这个信号优化掉
    
    input 						App_rd_en,
	input [`ADDR_WIDTH-1:0]		App_rd_addr,
	output 						Sdr_rd_en,
	output [`DATA_WIDTH-1:0]	Sdr_rd_dout	// synthesis keep：综合指令，别把这个信号优化掉
    
    
    
);
`ifndef SIMULATION
wire  			SDRAM_CLK;
wire 			SDR_RAS;
wire  			SDR_CAS;
wire  			SDR_WE;
wire  [`BA_WIDTH-1:0]	SDR_BA; 
wire  [`ROW_WIDTH-1:0]	SDR_ADDR;
wire  [`DATA_WIDTH-1:0]	SDR_DQ ;
wire  [`DM_WIDTH-1:0]	SDR_DM; 
`endif

sdr_as_ram  #( .self_refresh_open(1'b1))
	u2_ram( 
		.Sdr_clk(Clk),
		.Sdr_clk_sft(Clk_sft),
		.Rst(Rst),
			  			  
		.Sdr_init_done(Sdr_init_done),
		.Sdr_init_ref_vld(Sdr_init_ref_vld),
		.Sdr_busy(Sdr_busy),
		
		.App_ref_req(1'b0),
		
        .App_wr_en(App_wr_en), 
        .App_wr_addr(App_wr_addr),  	
		.App_wr_dm(App_wr_dm),
		.App_wr_din(App_wr_din),

		.App_rd_en(App_rd_en),
		.App_rd_addr(App_rd_addr),
		.Sdr_rd_en	(Sdr_rd_en),
		.Sdr_rd_dout(Sdr_rd_dout),
	
		.SDRAM_CLK(SDRAM_CLK),
		.SDR_RAS(SDR_RAS),
		.SDR_CAS(SDR_CAS),
		.SDR_WE(SDR_WE),
		.SDR_BA(SDR_BA),
		.SDR_ADDR(SDR_ADDR),
		.SDR_DM(SDR_DM),
		.SDR_DQ(SDR_DQ)	
	);


assign SDR_CKE=1'b1;

//`ifndef SIMULATION ← 原厂把它注释掉了：让下面那个 SDRAM 硬宏在综合和仿真里都例化
	EG_PHY_SDRAM_2M_32 sdram(
		.clk(SDRAM_CLK),
		.ras_n(SDR_RAS),
		.cas_n(SDR_CAS),
		.we_n(SDR_WE),
		.addr(SDR_ADDR[10:0]),
		.ba(SDR_BA),
		.dq(SDR_DQ),
		.cs_n(1'b0),
		.dm0(SDR_DM[0]),
		.dm1(SDR_DM[1]),
		.dm2(SDR_DM[2]),
		.dm3(SDR_DM[3]),
		.cke(1'b1)
		);
//`endif ← 同上，配合上面那行

endmodule 
