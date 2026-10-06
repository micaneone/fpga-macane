


// ============================================================
//  global_def.v —— SDRAM 那套代码共用的"位宽 + 时序"定义
//
//  被 sdr_as_ram / sdr_init_ref / SD/sdram.v 用 `include 引进来，
//  是它们之间的【共同语言】：位宽对不上就全错，而且不一定报错。
//
//  ★ 换 SDRAM 时钟频率时改这里的 SDR_CLK_PERIOD（刷新间隔由它算出来）
//  ★ 注意 sdr_wrrd.enc.v 里【自己又 define 了一遍】DATA_WIDTH/ADDR_WIDTH/
//    DM_WIDTH/ROW_WIDTH/BA_WIDTH —— 两份定义必须一致，编译顺序也要注意
// ============================================================

// ---- 数据通路位宽 ----
`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4
//   ★ DATA_WIDTH=32：SDRAM 每个地址放【一个像素】的 32 位（低 8 位是 alpha/填充，
//     只有高 24 位送给 HDMI —— 例程 video_delay.v 里就是取 read_data[31:8]）
//   ★ ADDR_WIDTH=21：2^21 = 2M 个地址 → 2M × 32bit = 64Mbit = 8MB

// ---- SDRAM 芯片内部结构（Row/Bank 位宽，由芯片规格决定）----
`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// ---- 时钟与刷新 ----
//   SDR_CLK_PERIOD：SDRAM 时钟周期（ns）。125MHz → 8ns
`define	  SDR_CLK_PERIOD				1000000000/125000000
//   SELF_REFRESH_INTERVAL：两次刷新的间隔拍数。
//   SDRAM 靠电容存数据，必须周期性刷新；标准要求 64ms 内把所有行刷一遍，
//   所以 间隔 = 64ms ÷ 周期 ÷ 行数。★ 这一项算错了数据会慢慢丢
`define   SELF_REFRESH_INTERVAL			64000000/`SDR_CLK_PERIOD/2**(`ROW_WIDTH)

