// ============================================================
//  模块名 : top_m1（集成顶层，测试件，不进交付仓库）
//  作用   : 今晚的目标 —— 把 A 的装载机和 B 的显示链接在一起，
//           上板看到"一张 800x600 的图"
// ------------------------------------------------------------
//  数据通路：
//    SD 卡 ──A 的装载机(top_a)──写口──┐
//                                     ├── sdr_arb ── 片内 SDRAM
//    B 的显示链 ──读口────────────────┘        （SDRAM 例化在 sdr_arb 里）
//    描述符：top_a ──a_desc/commit/ack── desc_rx ──> 合成器的源图参数（可选）
//
//  ★★ 今晚分两遍上板（就差一个 `define）：
//
//    第一遍：**把下面那行 `define USE_DESC 保持注释掉**
//            → 显示参数写死"大槽 0、800x600、valid=1"，变量最少。
//              出图 = 显示链 + A 的写入都对。这一步就是"看到图"。
//
//    第二遍：**把 `define USE_DESC 打开**，重新综合下载
//            → 显示参数改由 desc_rx 给（A 提交的描述符说了算）。
//              出图 = 描述符这条路也通了 = **完整版 M1**。
//
//    两遍都用同一份代码、同一个工程，只是这一行不同 —— 出问题的时候
//    一眼就知道该怀疑哪一段。
//
//  ★ 调试出口（黑屏时全靠它们）：
//      串口 115200：每 0.5 秒一行  W=xxxxxx S=xx F=xx
//        W = A 写了多少个字（**正常 800x600 应当打到 03A980 = 240000**）
//        S = 状态字节（见 dbg_report.v 文件头）
//        F = 帧号低 8 位（一直在变 = 显示链在跑）
//      LED：led0 两个 PLL 都锁 / led1 SD 就绪 / led2 装载完成过 / led3 A 报错
//      数码管：显示 A 的 dbg_wr_cnt（和串口的 W 一样）—— M0 时数码管不亮，
//              所以**以串口为准**，数码管只当参考
// ============================================================

// ★ 打开 = 显示参数来自 A 的描述符（完整版 M1）；注释掉 = 写死大槽 0 + 下面那两个尺寸
//   ★★ 2026-10-02 改成【打开】：窗口铺满 800x600，源图尺寸必须跟着图走，
//      写死的话换成 800x600 的图行距就对不上了（花屏）。
`define USE_DESC

// ★★ 打开 = 先显示 B 自己的【自测图】（不需要 SD 卡、不需要 A）
//    上电后 B 直接往大槽 0 写一张"8 条竖色条 + 顶白条 + 左边行标记"的图，
//    屏上应当立刻出现这张图；这时【按 key1】才会让 A 去装载真图。
//    作用：把"A 的数据错"和"B 的读取错"一次分开 ——
//      自测图正常 → B 的读取链没问题，问题在 A 那边（BMP 格式/解码）
//      自测图也花 → 问题在 B 的读取链（或存储），和 A 无关
//    ★ 排完就把这行注释掉，恢复"上电自动装第一张"。
`define B_SELFTEST

`timescale 1ns / 1ps

module top_m2 #(
    // PLL 报锁定之后，还要【连续稳定】这么久才放开复位（微秒）
    //   ★ 官方例程用的是 20ms（见下面复位那一段）。仿真里可以调小，
    //     不然一次仿真只有几毫秒，等不到。
    parameter integer PLL_WAIT_US = 20000
)(
    input  wire       clk,           // 50 MHz 晶振（R7）
    input  wire       rst_n,         // 硬复位（A2，低有效）
    // ★ 板子丝印与引脚（照《HX4S20 开发板手册》）：KEY1=A2  KEY2=B2  KEY3=B1  KEY4=C1
    //   本工程里 A2 当硬复位，所以只剩三个可用：
    input  wire       key1,          // 丝印 KEY2 / B2：读地址补偿旋钮（调试用，见 0b 节）
    input  wire       key2,          // 丝印 KEY4 / C1：软复位重来
    input  wire       key3,          // 丝印 KEY3 / B1：★ 装载 / 换下一张（skip+1）

    // ---- SD 卡（SPI）----
    output wire       sd_ncs,
    output wire       sd_dclk,
    output wire       sd_mosi,
    input  wire       sd_miso,

    // ---- 调试 ----
    output wire [3:0] led,
    output wire [5:0] seg_sel,
    output wire [7:0] seg_data,
    output wire       uart_tx,

    // ---- HDMI ----
    output wire       HDMI_CLK_P,
    output wire       HDMI_D0_P,
    output wire       HDMI_D1_P,
    output wire       HDMI_D2_P,
    output wire       HDMI_DDC_SCL,
    inout  wire       HDMI_DDC_SDA
);

    // ============================================================
    //  ★ 跨小节用到的连线统一在最前面声明
    //    （Verilog 里"先用后声明"会生成隐式网线，再声明就报
    //      "already declared" —— 踩过一次，别再动顺序）
    // ============================================================
    // A 的写口
    wire        a_wr_req;
    wire [20:0] a_wr_base;
    wire [20:0] a_wr_len;
    wire [31:0] a_wr_data;
    wire        a_wr_we;
    wire        a_wr_full, a_wr_ack, a_wr_done;   // ★ 2026-09-28 原厂协议
    wire        sdr_ready;                     // SDRAM 初始化完成（A 和自测图都要用，先声明）

    // B 自测图写入器的写口
    wire        stwr_busy, stwr_done, stwr_we, stwr_wrreq;
    wire [20:0] stwr_base;
    wire [20:0] stwr_len;
    wire [31:0] stwr_data;
    reg         stwr_start;
    reg  [16:0] stwr_cnt;
    reg         stwr_fired;

    // 显示链送给 HDMI 的像素（自检模块也要用同一份）
    wire [15:0] rgb565_w;
    wire        de_w, vs_w;
    wire [11:0] dbg_x, dbg_y;

    // ============================================================
    //  ★★★ 2026-10-03 第二版（上板才知道的）★★★
    //   第一版只做了"突发期间让读等一等"，结果**上板还是花**：
    //   旧图在装载期间就出现稀疏线状花屏，而且写进去的新图也带花（越按越多）。
    //   ⇒ 坐实了 M0 那条结论：**读写只要有重叠就会互相破坏**（读会读到错的、
    //     写也会写坏）。光"错开一拍"不够，必须**在时间上彻底分开**。
    //
    //   做法：用现成的背压 `a_wr_full` 把 A 的推字**只放行到"显示刚才没在读"的窗口**：
    //        push_win = 显示连续 ≥32 拍没有读请求（显存域，同步到控制域）
    //        A 看到的 full = 真 full | ~push_win
    //   ⇒ A 在"显示正在搬行"的时候自动停手（背压是正统握手机制，一个字都不丢），
    //     于是 FIFO 只在"显示没在读"的窗口里长，**写引擎的突发也就只从那种窗口里起**；
    //     突发本身再由下面的 `mem_rd_ok` 让显示让几拍路 —— 两者在时间上分开。
    //   ★ 窗口有多宽：一行 26.4 µs 里，显示只在开头 ~6.4 µs 搬这一行，
    //     其余 ~20 µs 都是窗口 → A 最多停一行时间，**吃得下**。
    //   ★ 为什么不用"整帧消隐"（第一版）：那样子 A 一停就是 16 ms 一帧一次
    //     —— 上板实测**第一张图都装不出来（纯白底）**，A 的流式写口受不了这么长的停。
    //   ★ 会不会变慢：窗口占一行时间的 ~75%，而装着速率的瓶颈是 SD（~17,000 字/秒），
    //     FIFO 每 20 ms 才攒够一次突发 → 放行窗口足够，装载速度不变。
    //   ★ 上板判读：还是花 → 把第 2b 节那行 `define LOAD_WITH_READS 关掉
    //     （退回"整段禁读"的三步方案）。
    // ============================================================
    // ★★ 关键实验用：自测图正在写的时候，把"显示的读"关掉
    //    （M0 踩过"读写同时抢同一颗 SDRAM → 读出来的数据是错的"这个坑）
    wire        disp_rd_en_g;
    // ★★★ 2026-10-06：块级读通路的连线（见第 3b 节）
    wire        d_blk_req_raw;              // 行缓冲的块请求（未过闸门）
    wire        d_blk_req;                  // 过了"装载期间禁读"闸门的块请求
    wire [20:0] d_blk_base, d_blk_len;
    wire        d_blk_want;
    wire        blk_rd_req, blk_rd_re;
    wire [20:0] blk_rd_base, blk_rd_len;

    // ★ 显示链的读请求/读地址（disp_top 的输出）—— 提前声明：
    //   下面 0c 节"只放行到显示没在读的窗口"要用它（ModelSim 不许先用后声明）
    wire        disp_rd_en;
    wire [20:0] disp_rd_addr;
    // ★ 显示链的读请求/读地址（disp_top 的输出）—— 提前声明：
    //   第 1b 节"只放行到显示没在读的窗口"要用它（ModelSim 不许先用后声明）

    // ★ 写引擎活动状态（sdr_arb 引出来，给读口握手用；见下面第 2b 节）
    wire        wr_burst, wr_guard;
    wire        occ_hi_w;                  // ★ sdr_arb 报的'占用已满'（occ>=512）
    wire        occ_pre_w;                 // ★ sdr_arb 报的"快到突发了"（occ>=240）
    // ★ rd_mute（"万一 A 卡死"的 300 秒兜底）在下面才赋值，但第 2b 节的
    //   读口握手要用它 —— 先声明（ModelSim 不允许先用后声明）。
    wire        rd_mute;

    // ---- ★ 转场相关的跨域信号（★ 必须先声明：下面第 1a 节的同步器、
    //      以及后面描述符那一段都要用；ModelSim 对"先用后声明"会报重复定义）----
    wire        tr_req;         // 像素域：一拍请求
    wire [1:0]  tr_fx;          // 像素域：淡入用哪种特效
    wire        tr_may_load;    // 像素域：屏上全米白，A 可以去写
    wire        tr_active;      // 像素域：正在转场
    wire        tr_swap;        // 像素域：一拍，请对调前台/后台
    wire        tr_show_back;   // 像素域：现在"该显示的是后台那张"（装载/淡入）
    // ★ 2026-10-04：特效从哪一端开始 —— 装载期间整段禁读（屏上米白）时用 1，
    //   否则装载一结束旧图会被读回来，"从旧图开始划"就会先闪一下旧图。
    wire        tr_from_white;

    // ---- 行探针（8 个固定行）+ 诊断计数 ----
    wire [15:0] chk_row0, chk_row1, chk_row2, chk_row3;
    wire [15:0] chk_row4, chk_row5, chk_row6, chk_row7;
    wire [15:0] lb_drop, lb_abort;
    wire [15:0] lb_off, lb_alignbad;   // 逐字对齐校验（地址图专用）
    // ---- 读口自测（★ 2026-09-27 下午换成"官方读侧"，见 rtl\vendor_read_test.v）----
    wire        st_busy, st_done, st_rd_en;
    wire [20:0] st_rd_addr;
    wire [15:0] st_read_cnt, st_bad, st_off, st_first;
    wire [15:0] st_w0, st_w1, st_w2, st_w3;
    wire        st_rd_en_m;            // 读口二选一（下面 assign）
    wire [20:0] st_rd_addr_m;
    reg         stwr_done_lat;
    reg  [23:0] st_dly;
    reg         st_go;

    // ============================================================
    //  ★★★ 2026-10-05：音频链（A 轨 top_aud）的跨小节连线与命令
    //     —— 全部在这里声明（Verilog 不许"先用后声明"，这个工程踩过五次）
    // ============================================================
    // 音效区参数（★ 必须和 A 的 sfx_ctrl 里那两个数【完全一致】）
    localparam [20:0] SFX_BASE    = 21'd1861660;   // 音效区基址（契约里未分配的小槽区）
    localparam integer SFX_STRIDE = 72000;         // 每条 3 秒 @48kHz
    // ============================================================
    //  ★★★★ 2026-10-06【音频回退开关】AUDIO_OFF
    //    = 1：**完全不启动音频链** —— 不装音效、不播放 ⇒ 音频一个读都不发
    //         ⇒ 显示回到"只有转场（10-04 那版）"的干净行为：图正常、**没有白条**。
    //         上板证据：22:06 那版（音频被饿到几乎没声）用户反馈"白条纹不在了"，
    //         而两次把显示弄坏（白屏/白条）的改动都在**读口**上 ——
    //         合起来说明 **干扰显示的是"音频那边的读"**，不是显示自己读得快。
    //    = 0：恢复音频（音乐 + 已知的沙沙声）。
    //    ★ 修音频时把它改回 0 即可，装音效/播放的逻辑一行都没删。
    // ============================================================
    // ★★★★ 2026-10-06 晚【音频改走块级读口】—— 开关打回 0
    //   上一档（=1）是过渡档："先把显示的块级读通路单独验干净，音频一条读都不发"。
    //   现在显示那条路已经在仿真里逐像素验过（tb_m2_blk_chain 19200/19200 全对），
    //   音频也换成【同一个仲裁器的音频口】（a_image\aud_blk_rd.v），
    //   所以打回 0：自动装音效 + 每次换图自动播一次。
    //   ★ 音频饿不死显示：块口是**显示优先**，而且两头都有看门狗兜底
    //     （blk_rd_arb 的 SERV_MAX + aud_blk_rd 的 SERV_MAX）。
    localparam AUDIO_OFF = 1'b0;

    // 读口绕道（line_buf ↔ top_aud ↔ sdr_arb）—— ★ 2026-10-06 起这几根全部作废：
    //   line_buf 走块口、音频也走块口，谁也不再用"逐拍 disp_rd_en/addr"。
    //   保留 `aud_line_req` 只是给串口的 flags 字段看着（它不再是任何读口的驱动）。
    wire        aud_line_req;

    // 音频链的其它线
    wire        clk_aud, pll_aud_locked;
    wire        aud_busy_w;           // top_aud 报"还在读/放"
    // ★ 音频域复位：等音频 PLL 也锁上（sys_rst_n 里已经含另外两个 PLL）
    //   ★★ 只能先声明、后面再 assign —— sys_rst_n 的声明在下面几百行，
    //      在这里直接写等式会造出隐式网线，ModelSim 会报"already declared"。
    wire        aud_rst_n;
    wire        hdmi_audio_valid, hdmi_acr_valid;
    wire [23:0] hdmi_audio_left, hdmi_audio_right;
    wire [19:0] hdmi_acr_cts, hdmi_acr_n;
    // 音频诊断（先接线网 / 进串口，见字段 28）
    wire [20:0] aud_dbg_base, aud_dbg_words;
    wire [31:0] aud_dbg_dout;
    wire        aud_dbg_vld, aud_dbg_play_tgl;
    wire [15:0] aud_dbg_cnt;            // ★★ 第 8 条：音频数据自检（字数）
    wire [31:0] aud_dbg_sum;            // ★★ 第 8 条：音频数据自检（32 位和）
    wire        aud_dbg_underrun;       // ★★ 2026-10-09：块级 FIFO 饿死过（sticky）
    // ---- ★★★ 2026-10-06 音频的块级读口（top_aud ↔ blk_rd_arb 的音频口）----
    wire        aud_a_req;              // top_aud → 闸门
    wire        aud_a_req_g;            // 闸门后 → blk_rd_arb.a_req
    wire [20:0] aud_a_base, aud_a_len;
    wire        aud_a_gnt, aud_a_next;
    wire [31:0] blk_a_data;
    wire        aud_blk_stall;
    // ★ 装载期间禁读闸门（先声明，赋值在下面第 8 节前）—— 显示和音频共用
    wire        disp_rd_gate;

    // 音频装载 / 播放的小状态机（C 轨还没接，这里自产命令）
    reg         aud_want;             // 1 = 这一次装载是"装音效"
    reg         aud_loaded;           // 音效已经在 SDRAM 里了
    reg         aud_fail;             // 音效装载失败过（不再重试）
    reg         aud_load_pulse;       // → A 的 start
    reg         aud_play_req;         // → sfx_ctrl 的 play_sfx（一拍）
    reg  [1:0]  aud_st;               // 0=等图 1=等 1 秒 2=装载中 3=做完
    reg  [25:0] aud_wait;

    // ============================================================
    //  ★★★ 2026-10-08【字幕：装载 + 叠加】—— 最小可用版
    // ------------------------------------------------------------
    //  两件事：
    //   ① 装载：上电后（**等音频那条自检做完**，避免两个"自产装载"撞车）
    //            自动装**卡里第 1 条 .SUB**：sd_mode=2 / skip=0 / sub_base=字幕区基址。
    //   ② 叠加：disp_top 的第 ④ 级（subtitle_ovl）把遮罩叠到画面上，
    //            **bit=1 画黑（字）、bit=0 透传**。
    //  ★ 位置先给一个暂定值（贴底居中），但**是"顶层 -> disp_top -> 模块"的端口**，
    //    不是常数 —— 以后 C 轨的窗口表（`WIN_SUB` 那一条）直接替掉这几个 wire 即可。
    //  ★ 极性/尺寸全部按契约：800×64 1bpp，SDR_SUBTITLE_BASE / _STRIDE。
    // ============================================================
    localparam [20:0] SUB_BASE   = 21'd2085760;   // 契约 SDR_SUBTITLE_BASE
    localparam [3:0]  SUB_SKIP   = 4'd0;          // 卡里第 1 个 .SUB（在自己的扩展名里数）
    // 暂定位置：800×64 的字幕条贴在屏幕底部（y = 600 - 64 - 8 = 528）、横向居中
    localparam [11:0] SUB_X0_DFLT = 12'd0;
    localparam [11:0] SUB_Y0_DFLT = 12'd528;
    localparam [11:0] SUB_W_DFLT  = 12'd800;      // 契约 ART_SUB_W
    localparam [11:0] SUB_H_DFLT  = 12'd64;       // 契约 ART_SUB_H
    localparam [15:0] SUB_INK     = 16'h0000;     // ★ bit=1 画这个颜色（黑 = 文字）
    // ★★★ 2026-10-09 一次性诊断开关：=1 ⇒ **左半屏画自产 8×8 棋盘、右半屏画真字幕**。
    //   左半屏整齐 ⇒ 显示这一级没问题（问题在卡上的素材）；左半屏也歪 ⇒ 显示这一级的问题。
    //   ★ 诊断完改回 0 重新出比特流即可（纯显示级开关，不影响别的）。
   localparam SUB_TPAT = 1'b0;   // ★ 2026-10-09 晚：诊断结束（左半屏棋盘已确认显示级是对的），
                                 //   关掉它 ⇒ 整条 800×64 全画真字幕；数据指纹走字段 19/20。

    wire        a_sub_done;           // ← top_a：这一条字幕写进 SDRAM 了（单拍）
    reg         sub_load_pulse;       // → A 的 start（单拍；sd_mode 也由它选）
    reg         sub_loaded;           // 字幕已经在 SDRAM 里了（= 叠加的 on）
    reg         sub_fail;             // 装载失败过（就当没有字幕，不再重试）
    reg  [1:0]  sub_st;
    reg  [25:0] sub_wait;
    // ---- ★★ 2026-10-09【字幕探针】上板看不到字，就靠这几个数定位 ----
    reg         sub_pulse_lat;        // sticky：字幕装载脉冲发出去过
    reg         sub_done_lat;         // sticky：a_sub_done 回来过
    wire        a_dbg_sub_overrun;    // ← top_a/sub2sdram：丢字
    wire        a_dbg_sub_short;      // ← top_a/sub2sdram：字数对不上
    wire [31:0] a_dbg_sub_wr_cnt;     // ← top_a/sub2sdram：写了多少字（期望 1600）
    // ★ sub_loaded 是 50 MHz 域的电平，要送进像素域用 ⇒ 两位同步器（和预装那条一个做法）
    reg         sub_on_s1, sub_on_s2;

    // ---- ★ 三选一：谁在发脉冲，sd_mode/skip/基址 就是谁的 ----
    //   ★★ 用【脉冲】而不是"电平"来选：top_a 本来就是在 `start` 那一拍锁存 sd_mode 的，
    //      而电平一旦因为失败没清干净，就会把后面的"装图"也带偏（装载中易主）。
    //      （原来音频用 aud_want 电平选，这版一起改成脉冲 —— 行为等价，但更不容易错。）
    wire [1:0]  a_sd_mode  = sub_load_pulse ? 2'd2 : (aud_load_pulse ? 2'd1 : 2'd0);
    wire [20:0] a_sub_base = sub_load_pulse ? SUB_BASE : 21'd0;
    wire [3:0]  a_sd_skip  = sub_load_pulse ? SUB_SKIP : 4'd0;

    // 行缓冲探针（第一次填充的请求地址/字数 + 收到的头两个字）
    wire [20:0] lb_wbase0;
    wire [11:0] lb_words0;
    wire [31:0] lb_rd0, lb_rd1;

    // ============================================================
    //  0. 两个 PLL
    // ============================================================
    wire clk_pix, clk_par, clk_ser, pll0_locked;
    PLL_0 u_pll0 (
        .refclk  (clk),
        .reset   (~rst_n),
        .extlock (pll0_locked),
        .clk0_out(clk_pix),        // 40 MHz  像素
        .clk1_out(clk_par),        // 100 MHz @90 并行（串化）
        .clk2_out(clk_ser)         // 200 MHz 串化
    );

    wire clk_sdr, clk_sdr180, pll_sdr_locked, clk_sdr_unused;
    PLL_SDR u_pll_sdr (
        .refclk  (clk),
        .reset   (~rst_n),
        .extlock (pll_sdr_locked),
        .clk0_out(clk_sdr_unused), // 100 MHz（用不到）
        .clk1_out(clk_sdr),        // 125 MHz          → SDRAM Clk
        .clk2_out(clk_sdr180)      // 125 MHz @180°    → SDRAM Clk_sft
    );

    // ============================================================
    //  0a-2. ★★ 2026-10-05：音频 PLL（A 轨的音频链要 12.288 MHz）
    //    用原厂例程里现成的 `PLL_HDMI_AUDIO`：C0=75M / C1=375M / C2=12.295082M。
    //    · C2 比 12.288 高 +576 ppm —— 音调高 0.058%，人耳听不出来；
    //    · C0/C1 我们用不到，不接（TD 会把没用的时钟输出摘掉）；
    //    · ★ 这颗片子有 4 个 PLL，现在用到第 3 个（离线综合能过，见资源报告）。
    // ============================================================
    PLL_HDMI_AUDIO u_pll_aud (
        .refclk  (clk),
        .reset   (~rst_n),
        .extlock (pll_aud_locked),
        .clk0_out (),
        .clk1_out (),
        .clk2_out (clk_aud)        // ★ 12.295 MHz 音频域
    );

    // ============================================================
    //  0c. ★★★ 2026-10-03：A 的推字只放行到"显示刚才没在读"的窗口
    //     （为什么这么做 / 上板踩过什么，见第 1b 节那段长注释；
    //       放这里是因为要用上面 PLL 出来的 clk_sdr）
    // ============================================================
`ifdef LOAD_WITH_READS
    // ★★ 2026-10-03 第四版（上板看到"旧图花 + 新图花、越切越多"之后加的）：
    //    第三版只保证"推字发生在显示没在读的窗口里"，**没保证写突发在窗口内跑完** ——
    //    A 可能在窗口的最后一刻推字，引擎的突发（几百字 ≈ 4 µs）就跨进显示
    //    下一次搬行的时刻 → 读写还是重叠 → 旧图（读侧）和新图（写侧）一起花。
    //
    //    修法：**只在窗口的"前段"放行推字**，把窗口的后段留给引擎把突发跑完：
    //       窗口 ≈ 20 µs（一行 26.4 µs 里显示只搬 ~6.4 µs）
    //       前段 ≈ 5 µs 放行（600 拍 @125MHz）→ 后段 ≈ 15 µs 足够跑完 4 µs 的突发
    //   ★ 吞吐不受影响：SD 约 380k 字/秒 → 一行只送来 ~10 个字，
    //     而前段允许 600 个字/行，富余得离谱。
    reg  [11:0] rd_idle_cnt;                     // 显存域：连续多少拍没有读请求
    always @(posedge clk_sdr or negedge rst_n) begin
        if (!rst_n)                       rd_idle_cnt <= 12'd0;
        else if (disp_rd_en)              rd_idle_cnt <= 12'd0;
        else if (rd_idle_cnt != 12'hFFF)  rd_idle_cnt <= rd_idle_cnt + 12'd1;
    end
    // ★★ 2026-10-04 第五版：**推字门控整个去掉**。
    //    第四版把推字限制在窗口前段，结果上板"毫无变化"—— 而串口里
    //    字段 0/1（引擎实写字数 W）和字段 11（A 自己推的字数）对不上账
    //    （低 16 位差约 10,240 个字）⇒ **引擎少写/写错了字**，
    //    正是《B轨待改清单》§一 记过的那一族：**引擎的突发/收尾记账依赖
    //    A 的推字节奏**，人工把推字切成一顿一顿，它的账就错。
    //    ⇒ 结论：**A 的推字一个字都不能门控**（它必须保持原来的连续节奏）。
    //      于是这一档只剩"读口在写突发期间让路"（第一版那套握手）。
    //    判据（每次都能从串口直接看）：字段 0/1 的低 16 位 必须等于 字段 11。
    // ★★★ v7 第一步（2026-10-04，用户方案）：**A 的推字只放行到行场消隐期**。
    //   为什么这条能行而前面 5 版都不行：消隐期显示**根本不读** SDRAM
    //   （没有行请求）⇒ 读写天然分开，既不撞、也不饿显示。
    //   ★ 代价：A 的写口一帧要停 ~16 ms（消隐只占 0.74 ms）⇒ 装载变慢
    //     （1152x864 那张约 14 s）。所以下一步必须做**预取**：
    //     空闲时就把下一张装进后台槽，那 14 s 花在"你正在看图"的时候。
    //   ★ 另一个前提：A 的 sd_read.TIME_OUT 原来只有 2 ms，会把这种长停当超时
    //     （v2 白屏的老根）—— 已同时放大到 40 ms。
    reg pw1, pw2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pw1 <= 1'b0; pw2 <= 1'b0; end
        else        begin pw1 <= vs_w;  pw2 <= pw1; end   // vs 高 = 消隐
    end
    wire push_ok_m   = pw2;                       // 1 = 消隐期，允许 A 推字
    // ★★★ v7 第三步（2026-10-05，用户提醒"读写都要凑 4 的倍数"）：
    //   上板：白线没了 ✓ 但出现**条状花屏且越切越多** ✗。
    //   根因：这颗核"4 字一包"，**每一串突发的起始绝对地址必须是 4 的倍数**。
    //   我上一版把推字按帧切断 ⇒ 引擎的串在中途"断粮" ⇒ 下一串从一个**不是 4
    //   倍数**的地址开始 ⇒ 每 4 个字转一位 ⇒ 条状；断一次多一层 ⇒ 越切越多；
    //   大图断得最多 ⇒ 它下面那段常驻条状。
    //   修法：**每个消隐窗口一次放行整数个 4 字**（这里 512 = 2 个整串），
    //   窗口内放完就关闸、等下一个消隐窗口，**中途绝不切** ⇒ 断粮点永远是 4 的倍数。
    //   ★ 代价：一帧最多 512 字 ⇒ 约 30.7k 字/秒（240k 字约 8 s、497.6k 字约 16 s）。
    //     用户明确说"速度不重要，不花屏优先"，所以就这样；慢的部分交给预取去藏。
    localparam integer PUSH_CHUNK = 512;          // 每个消隐窗口最多放行多少个字（4 的倍数！）
    reg  [9:0] push_cnt_w;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  push_cnt_w <= 10'd0;
        else if (!push_ok_m)         push_cnt_w <= 10'd0;          // 关闸就清零
        else if (a_wr_we && !a_wr_full) push_cnt_w <= push_cnt_w + 10'd1;  // 真放行一个字才 +1
    end
    wire push_allow  = push_ok_m && (push_cnt_w < PUSH_CHUNK[9:0]);

    wire a_wr_full_g = a_wr_full | ~push_allow;  // ★ A 看到的"满"（窗口外/放满 512 字都报满）
`else
    // ★ 实验关掉时：**完全不动 A 的推字**（回到这次实验之前的行为）
    wire a_wr_full_g = a_wr_full;
`endif

    // ============================================================
    //  0b. 按键旋钮（2026-09-27，测试用）
    //      key1：每按一次"取数组内相位" +1（0→1→2→3→0），默认 3
    //           ★ 实测：这颗核每 4 拍才更新一次读数据（前 3 拍重复旧值），
    //             而"数据有效"脉冲每拍都发。所以这边把地址每 4 拍才推进 1 个字，
    //             并且每 4 个有效脉冲只取 1 个 —— 取哪一拍由这个相位决定，
    //             现场试到"逐字校验 = 0"为止。
    //      ★ 自测图模式下 key1 原本是"让 A 去装真图"，但这一版要一边看图、
    //        一边现场调补偿，所以把 key1 从控制桩那里摘开（桩拿到常 1 = 空闲），
    //        免得按一下就悄悄把自测地址图覆盖掉。
    //      key2 仍然照旧（控制桩里的软复位）。
    // ============================================================
    wire key1_press;
    key_press_debounce #(.CLK_FREQ_HZ(50_000_000), .DEBOUNCE_MS(20)) u_k1 (
        .clk(clk), .rst(~rst_n), .button_in(key1), .press_pulse(key1_press)
    );

    reg [2:0] zoom_lv;      // ★ M2：KEY1 循环的缩放档（0=适配 1=1x 2=1.5x 3=2x 4=3x 5=4x）
    reg [3:0] key_cnt;
    // ★ 这个旋钮用【引脚复位】而不是 sys_rst_n：这样 key2 软复位重来之后，
    //   调好的补偿值还留着，不用重新按。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ★★★ 2026-09-28 第五轮【本质变了】：读口那两条脾气
            //   （起点必须 4 字对齐 / 每趟第 1 个字会丢）现在由
            //   `b_display\line_buf.v` 统一抵消（请求提前 4 个字 + 丢掉第 1 个
            //   收到的字），所以【这个旋钮必须回到 0】——它现在只是一把
            //   "故意把起点挪歪"的实验工具：
            //     0 = 正常（默认，行首原样送，靠 line_buf 抵消）
            //     1..7 = 手动把行首再往前挪几个字；只要不是 4 的整数倍，
            //            核的 4 字分组就会错开 → 屏上立刻出现"等距小条"。
            //   也就是说：以后看到那种条纹，先看这个数是不是 0。
            //   （旋钮：按 key1 循环 0→1→…→7）
            zoom_lv <= 3'd0;
            key_cnt <= 4'd0;
        end
        else if (key1_press) begin
            // ★ M2：KEY1 = 【循环缩放档】0=适配 1=1x 2=1.5x 3=2x 4=3x 5=4x → 回 0
            if (zoom_lv == 3'd5) zoom_lv <= 3'd0;
            else                 zoom_lv <= zoom_lv + 3'd1;
            key_cnt <= key_cnt + 4'd1;
        end
    end

    // 档位同步到像素域（只按 KEY1 时才变，慢变；两位同步器够用，
    // 跨域瞬间最多错一帧，肉眼看不出来）
    reg [2:0] zoom_p1, zoom_p2;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin zoom_p1 <= 3'd0; zoom_p2 <= 3'd0; end
        else        begin zoom_p1 <= zoom_lv; zoom_p2 <= zoom_p1; end
    end

    // ============================================================
    //  1. 控制（桩：假装是 C）
    //     ★ 它只吃【引脚复位】—— 因为软复位是它自己产生的
    //       （它内部再自己门控出 ctl_rst_n，见 stub_ctrl.v 文件头）
    // ============================================================
    wire        a_start, soft_rst;
    wire [3:0]  a_skip;
    wire [2:0]  a_use_slot;
    wire [20:0] a_slot_base;
    wire [7:0]  a_img_no;
    wire        a_busy, a_load_done, a_desc_done, a_fail, a_sd_ready;
    wire [7:0]  a_ready_n;

    // ============================================================
    //  全设计的复位 —— ★★ 2026-09-27 按官方例程的做法改（关键修复）
    //
    //  官方 top_tf_hdmi_audio.v 里的写法（原文注释）：
    //      "end else if (sys_pll_lock && video_pll_lock) begin
    //          // 等待 PLL 连续稳定 20ms @ 50MHz
    //          if (rst_cnt < 20'd1_000_000) ... rst_all_reg <= 1'b1;"
    //      "// 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位"
    //
    //  我们原来是 `rst_n & pll0_locked & pll_sdr_locked & ~soft_rst`：
    //    ① PLL 一报锁定就立刻放行 —— 而锁定信号常常比输出时钟真正稳定早
    //       → SDRAM 的初始化（预充电/刷新/写模式寄存器）可能在时钟还在抖的时候跑
    //       → 模式寄存器没写对，SDRAM 就长期停在错误模式
    //    ② 锁定状态没有锁存 —— PLL 后面轻微抖动会让整块设计中途复位，
    //       SDRAM 跟着重新初始化，而这时显示还在读它（厂商文档明写：
    //       "Sdr_init_done 拉高之前绝对不能读写"）
    //  这两条都会让 SDRAM 停在一个"看起来能用、其实节奏不对"的状态 ——
    //  正好对应我们测到的"每 4 拍才更新一次读数据"。
    // ============================================================
    localparam [25:0] PLL_WAIT_TICKS = PLL_WAIT_US * 50;   // 50MHz
    reg        pll_ok_reg;      // PLL 稳定确认过（之后不再理会抖动）
    reg [25:0] pll_wait;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pll_ok_reg <= 1'b0;
            pll_wait   <= 26'd0;
        end
        else if (!pll_ok_reg) begin
            if (pll0_locked && pll_sdr_locked) begin
                // 连续稳定 20 ms @50MHz = 1,000,000 拍；中间抖一下就重新计时
                if (pll_wait >= PLL_WAIT_TICKS) pll_ok_reg <= 1'b1;
                else                            pll_wait <= pll_wait + 26'd1;
            end
            else pll_wait <= 26'd0;
        end
    end

    // 全设计的复位：引脚复位 + PLL 稳定确认（已锁存）+ 软复位
    wire sys_rst_n = rst_n & pll_ok_reg & ~soft_rst;

    // ★★ 2026-10-05：音频域的复位（音频 PLL 也锁上才放开）—— 到这里 sys_rst_n 已经声明过了
    assign aud_rst_n = sys_rst_n & pll_aud_locked;

    // ★★ 2026-09-28：写和读绝不能同时进行，但"只禁读"会把行缓冲饿死
    //    （上板实测：禁读一段时间后 disp_rd_en 永远是 0、行缓冲再也发不出请求，
    //      屏上只剩底色）→ 改成**写的时候把显示整块复位**，写完再从干净状态开始；
    //    这时图已经在 DRAM 里，一次就读对。
    //    ★ 开机那次（自测图）用"保持复位直到第一次写完"；
    //      A 每次装图期间也复位（装完自动恢复，屏上是新图）。
    reg disp_rst_hold;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n)      disp_rst_hold <= 1'b1;
        else if (!stwr_busy) disp_rst_hold <= 1'b0;
    end
    wire disp_rst_n = sys_rst_n & ~disp_rst_hold;   // ★ 别用 a_busy 复位整块显示：A 忙标志万一落不下来，屏上就永远无信号（读写互斥靠下面的 disp_rd_en_g 禁读就够了）

    // ★★ 2026-10-02：把"A 的启动"整件事交回 stub_ctrl，只留它一路。
    //    为什么删掉原来那路"保险启动"（a_start_force）：它和 stub_ctrl 各发一次，
    //    ① 上电会重复装两遍第 1 张；② stub_ctrl 内部的"第几张"计数器会因此和
    //    实际装的张数错位 —— 那样按 key3 换图会先重装一遍当前这张，看着像"没反应"。
    //    现在 stub_ctrl 负责"上电自动装第 1 张 + 每按一次 key3 装下一张"，计数自然同步。
    wire a_start_use = a_start;                          // 送给 A 的启动脉冲

    // ★ 上电自动装第一张（100 ms 后）。stub_ctrl 靠这个把 next_no 推到 1，
    //   这样第一次按 key3 就是"第 2 张"。
    localparam integer CTL_AUTO_START = 1;

    // ============================================================
    //  1a. ★★ 转场 ↔ 控制桩 之间的三处跨域（2026-10-03，转场 ④）
    // ------------------------------------------------------------
    //   ① 像素域 → 控制域：front_sel（前台是谁）→ A 写【另一个】槽
    //   ② 像素域 → 控制域：may_load / active（都是长时间稳定的电平）
    //   ③ 控制域 → 像素域：req_tgl（翻一下 = 请求换下一张）/ fx_sel
    //   ★ 全部是慢变电平或"翻转一次"的握手，两位同步器就够；
    //     ★ 千万别把【单拍脉冲】直接跨域 —— 40MHz 和 50MHz 互采一定会漏。
    // ============================================================
    // 前台是谁：转场走完 transition_ctrl 给一拍 swap，就把它对调。
    //   ★ 放在这里（而不是描述符那一段）是因为下面的同步器要用它，
    //     而 Verilog 的声明必须先于使用。
`ifdef USE_DESC
    reg front_sel;
    always @(posedge clk_pix or negedge disp_rst_n) begin
        if (!disp_rst_n)  front_sel <= 1'b0;
        else if (tr_swap) front_sel <= ~front_sel;
    end
`else
    wire front_sel = 1'b0;              // 写死单路时：前台永远是槽 0
`endif

    reg fs1, fs2;                       // front_sel → 控制域
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fs1 <= 1'b0; fs2 <= 1'b0; end
        else        begin fs1 <= front_sel; fs2 <= fs1; end
    end
    // A 写【非前台】那个槽：前台=0 就写槽 1，前台=1 就写槽 0
`ifdef USE_DESC
    wire [2:0] a_slot_use = fs2 ? 3'd0 : 3'd1;
`else
    wire [2:0] a_slot_use = 3'd0;       // 写死单路时：就写槽 0
`endif

    reg ml1, ml2, ac1, ac2;             // may_load / active → 控制域
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ml1 <= 1'b0; ml2 <= 1'b0;
            ac1 <= 1'b0; ac2 <= 1'b0;
        end
        else begin
            ml1 <= tr_may_load; ml2 <= ml1;
            ac1 <= tr_active;   ac2 <= ac1;
        end
    end

    wire        req_tgl;                // 控制桩翻一次 = 请求换下一张
    wire [1:0]  fx_sel_ctl;             // 控制桩选的淡入特效
    wire        k1_press_w;             // ★ 探针：消抖后的 KEY3 脉冲
    wire        req_pend_w;             // ★ 探针：转场请求挂起中

    // 控制域 → 像素域：req_tgl 取边沿 = 一拍请求脉冲
    reg rt1, rt2, rt3;
    always @(posedge clk_pix or negedge disp_rst_n) begin
        if (!disp_rst_n) begin rt1 <= 1'b0; rt2 <= 1'b0; rt3 <= 1'b0; end
        else             begin rt1 <= req_tgl; rt2 <= rt1; rt3 <= rt2; end
    end
    assign tr_req = rt2 ^ rt3;

    // 控制域 → 像素域：fx_sel（只变不抖，两位同步器）
    reg [1:0] fx1, fx2;
    always @(posedge clk_pix or negedge disp_rst_n) begin
        if (!disp_rst_n) begin fx1 <= 2'd0; fx2 <= 2'd0; end
        else             begin fx1 <= fx_sel_ctl; fx2 <= fx1; end
    end
    assign tr_fx = fx2;

    // ============================================================
    //  ★★★ 2026-10-08【预装 prefetch】控制桩 ↔ 转场 的两根新线
    // ------------------------------------------------------------
    //   pf_ready_w   : 控制域。后台槽里已经装好"下一张"（长时间稳定的电平）
    //   req_accept_w : 控制域。本次换图请求被受理（★ 单拍）—— 音效挂它
    //   ★ 需求：按键时**转场立刻开始**（屏上不再有"按下去 0.3~1.8 秒没反应"）。
    //     顶层在 IDLE 期间就指挥 A 把下一张装进后台槽（见 stub_ctrl 头注释）。
    //   ★ 三处连线，全在这一段里做完（声明必须先于使用 —— 下面 569 行就例化它）：
    //     ① pf_go：允许预装的门。★ 竞态①（撞上音效自检）：顶层
    //        `.start(a_start_use | aud_load_pulse)` + `.skip(aud_want ? 0 : a_skip)`
    //        ⇒ 预装的 a_start 若和 aud_load_pulse 同拍，会被当成"装音效"，
    //        图的脉冲丢了 ⇒ stub_ctrl 等的 a_load_done 永远不来 ⇒ 卡死。
    //        所以音频自检没做完（也没失败）之前，一个预装都不许发。
    //     ② pf_ready → 像素域：慢变电平，两位同步器就够（★ 单拍脉冲绝不能这么跨）。
    //        这就是给 transition_ctrl 的 `back_ready`。
    //     ③ 例化里带上的 .a_load_done / .pf_ready_o / .req_accept_o。
    // ============================================================
    localparam AUD_PF_GO = AUDIO_OFF;             // 音频整个关掉时直接允许预装
    wire       pf_go_w   = AUD_PF_GO | aud_loaded | aud_fail;
    wire       pf_ready_w;
    wire       req_accept_w;

    reg pfr1, pfr2;                               // pf_ready → 像素域（两位同步器）
    always @(posedge clk_pix or negedge disp_rst_n) begin
        if (!disp_rst_n) begin pfr1 <= 1'b0; pfr2 <= 1'b0; end
        else             begin pfr1 <= pf_ready_w; pfr2 <= pfr1; end
    end
    wire tr_back_ready = pfr2;                    // → disp_top → transition_ctrl

    // ★★ 2026-10-09：字幕的"要不要显示"也是 50 MHz 域的电平 → 像素域，同样两位同步器
    always @(posedge clk_pix or negedge disp_rst_n) begin
        if (!disp_rst_n) begin sub_on_s1 <= 1'b0; sub_on_s2 <= 1'b0; end
        else             begin sub_on_s1 <= sub_loaded; sub_on_s2 <= sub_on_s1; end
    end

    stub_ctrl #(
        .CLK_HZ(50_000_000), .AUTO_DELAY_MS(100), .RST_HOLD_MS(5),
        .SLOT_BASE(0), .AUTO_START(CTL_AUTO_START)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .key1(key3), .key2(key2),     // ★ key3（B1）= 装载 / 换下一张；key1（B2）留给偏移补偿旋钮
        .sd_ready(a_sd_ready), .a_busy(a_busy), .hold(stwr_busy),
        // ★ 转场握手：屏上全米白了才真的去装；转场期间不受理新请求
        .may_load(ml2), .tr_active(ac2),
        .slot_in(a_slot_use),
        .a_start(a_start), .a_skip(a_skip),
        .a_use_slot(a_use_slot), .a_slot_base(a_slot_base),
        .a_img_no(a_img_no), .soft_rst(soft_rst),
        .req_tgl(req_tgl), .fx_sel(fx_sel_ctl),
        .k1_press_o(k1_press_w), .req_pend_o(req_pend_w),
        // ★★★ 2026-10-08【预装】四根新线
        .pf_go(pf_go_w), .a_load_done(a_load_done),
        .pf_ready_o(pf_ready_w), .req_accept_o(req_accept_w)
    );

    // ============================================================
    //  1b. B 自己的自测图写入器（只在 B_SELFTEST 打开时用）
    //      复位后约 1ms 发一次 start，把"竖色条"图写进大槽 0
    // ============================================================
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            stwr_cnt   <= 17'd0;
            stwr_start <= 1'b0;
        // ★★ 2026-09-28 第三轮（测量版）：**重新打开开机自测图**，
        //    而且图案换成 PAT_MODE=2（一个字的两个像素都 = 这个字的字地址）。
        //    屏上会是一张"自描述"的图：串口探针读到的每个数，
        //    低 16 位直接就是"哪个字"，错位/重复/串行一眼可判；
        //    而且行缓冲的"本趟几个字对不上"（badwords）这时候才有意义：
        //    它 = 0 就说明这一趟 320 个字全部落对位置。
            // ★★ 2026-09-28 第五轮（量完之后）：**关掉开机自测图**，
            //    让 A 把卡里那张真图装进来 —— 这一版是要"看真图"。
            //    （要回去做地址图测量：把这行改回 1'b0，并把下面 astart_fired
            //      改回 1'b1，同时把 stub_a_writer 的 PAT_MODE 保持 2。）
            stwr_fired <= 1'b1;
        end
        else begin
            stwr_start <= 1'b0;
            if (!stwr_fired) begin
                if (stwr_cnt >= 17'd50000) begin      // 约 1ms @50MHz
                    stwr_start <= 1'b1;
                    stwr_fired <= 1'b1;
                end
                else stwr_cnt <= stwr_cnt + 17'd1;
            end
        end
    end

    stub_a_writer #(
        // ★★ 2026-09-28：只写【显示要用的那 480 行】= 640x480。
        //   原来写整槽(2909 行)要 26ms，那段时间显示必须让位，屏幕会长时间空着；
        //   现在只写 76,800 字（板子上约 2ms、仿真里 1.6ms），够显示用，
        //   而且和"卡里那张 640x480 真图"占的区域完全一样。
        .PAGE_W(640), .PAGE_H(480), .BASE(0), .PAT_MODE(2)
    ) u_self (
        .clk_ctl(clk), .rst_ctl_n(sys_rst_n),
        .start(stwr_start), .pack_swap(1'b0),
        .sdr_ready(sdr_ready),
        .done(stwr_done), .busy(stwr_busy),
        .a_wr_req(stwr_wrreq), .a_wr_base(stwr_base), .a_wr_len(stwr_len),
        .a_wr_ack(a_wr_ack), .a_wr_data(stwr_data), .a_wr_we(stwr_we),
        .a_wr_full(a_wr_full), .a_wr_done(a_wr_done)
    );

    // ============================================================
    //  2. A 的装载机（SD → BMP → 565 → SDRAM 写口 + 描述符）
    // ============================================================
    wire [2*64-1:0] a_desc;
    wire        a_commit_tgl, a_ack_tgl;
    wire [31:0] a_dbg_px_cnt, a_dbg_wr_cnt;
    wire [15:0] a_dbg_first_px;
    wire        a_dbg_overrun, a_dbg_warn_odd;
    wire [31:0] a_dbg_first_addr;   // A 报的第一个像素的地址（期望 (H-1)*W = 479*640）

    // ★★ 2026-10-02 接上 A 的新接口（A 轨 368cbfd「音频+缩放」）：
    //    A 的 top_a 从这一版起同时管"装图"和"装音频"，start 那一拍由 sd_to_wav 决定装哪个。
    //    · 本版（M1_super 第一遍）只装一张 BMP → sd_to_wav 恒 0、sfx_base 恒 0；
    //    · 音频的三个诊断口先接到线网上备用（以后接串口探针看 wav_cnt / wav_odd）。
    //    ★ 注意：这四路是【新增】的，漏接不会报错 —— sd_to_wav 悬空成 Z 时，
    //      top_a 内部 bmp_start / wav_start 会同时变成不定态，两条链都不启动。
    wire        a_wav_done;
    wire [31:0] a_dbg_wav_cnt;
    wire        a_dbg_scaled, a_dbg_wav_odd;

    top_a #(.SLOT_NUM(2)) u_a (
        .sys_clk(clk), .sys_rst_n(sys_rst_n),
        // ★★ 2026-10-08【集成临时改动 · SD 提速到 25 MHz】：SD 读移位器用 100 MHz。
        //   原来是接在 50 MHz 晶振上（4 相拍 ⇒ SCLK = 12.5 MHz），
        //   换成 PLL_0 的 clk_par（100 MHz）后 SCLK = 100/4 = **25 MHz**（规格内上限）。
        //   ★ 只有"图像链"的读走这根；音频链仍用 50 MHz（见 top_a 里的注释）。
        //   ★ 要回退：把这一行改成 `.clk_spi(clk)` 即可（行为与改动前逐位相同）。
        .clk_spi(clk_par),
        .spi_miso(sd_miso), .spi_mosi(sd_mosi),
        .spi_clk(sd_dclk), .spi_cs(sd_ncs),
        // ★★★ 2026-10-08：A 的 top_a 改成**三选一**（`sd_to_wav` 一位 → `sd_mode` 两位）——
        //   0 = 装图（控制桩那套，和以前一模一样）
        //   1 = 装音频（自产的音效自检）
        //   2 = 装字幕（自产的字幕自检；卡里第 1 个 .SUB）
        //   ★ sd_mode / skip / 基址 全部由【发脉冲的那一个】决定，而且 top_a 本来
        //     就在 `start` 那一拍锁存 ⇒ 三条链绝不会中途易主。
        //   ★ 三个脉冲由各自的 FSM 产生，且字幕那条**等音频做完**才动 ⇒ 不会撞。
        .start(a_start_use | aud_load_pulse | sub_load_pulse),
        .sd_mode(a_sd_mode),
        .skip(a_sd_mode == 2'd2 ? SUB_SKIP : (a_sd_mode == 2'd1 ? 4'd0 : a_skip)),
        .use_slot(a_use_slot),
        .slot_base(a_slot_base), .img_no(a_img_no),
        .sfx_base(a_sd_mode == 2'd1 ? SFX_BASE : 21'd0),
        .sub_base(a_sub_base),
        .busy(a_busy), .load_done(a_load_done), .desc_done(a_desc_done),
        .ready_n(a_ready_n), .fail(a_fail), .sd_ready(a_sd_ready), .led_init(),
        .sub_done(a_sub_done),
        .a_wr_req(a_wr_req), .a_wr_base(a_wr_base), .a_wr_len(a_wr_len),
        .a_wr_ack(a_wr_ack),
        .a_wr_data(a_wr_data), .a_wr_we(a_wr_we),
        // ★ 只给 A 看到"消隐期之外就算满" —— 它的推字就只发生在消隐期
        .a_wr_full(a_wr_full_g), .a_wr_done(a_wr_done), .sdr_ready(sdr_ready),
        .a_desc(a_desc), .a_commit_tgl(a_commit_tgl), .a_ack_tgl(a_ack_tgl),
        .dbg_px_cnt(a_dbg_px_cnt), .dbg_first_px(a_dbg_first_px),
        .dbg_wr_cnt(a_dbg_wr_cnt),
        .dbg_overrun(a_dbg_overrun), .dbg_warn_odd(a_dbg_warn_odd),
        .dbg_first_addr(a_dbg_first_addr),
        .wav_done(a_wav_done), .dbg_wav_cnt(a_dbg_wav_cnt),
        .dbg_scaled(a_dbg_scaled), .dbg_wav_odd(a_dbg_wav_odd),
        // ★★ 2026-10-09 字幕链的诊断（上板看不到字，靠这三个数定位）
        .dbg_sub_wr_cnt(a_dbg_sub_wr_cnt),
        .dbg_sub_overrun(a_dbg_sub_overrun),
        .dbg_sub_short(a_dbg_sub_short)
    );


    // ============================================================
    //  3. 存储封装（SDRAM 例化在它里面）
    // ============================================================
    wire        sdr_init_done, sdr_busy, sdr_init_ref_vld;
    wire [23:0] sdr_wr_cnt;
    wire        rd_vld;
    wire [31:0] rd_data;

    // ★★ 2026-09-28：读口【完全交给显示】。
    //    上板实测：读口自测（`vendor_read_test`，按官方读引擎写的那套）会一直占着
    //    读口不放（串口里 disp_rd_en=0、行缓冲全是被掐断），显示一条数据都读不到，
    //    屏上只剩合成器底色（纯蓝）。自测实例留着（它只是数收到的数据，无害），
    //    但读口不再做"二选一"。
    // 读口【永远】归显示
    // ★★★ 2026-10-05：读口现在**绕经 top_aud**（A 的音频链要借读口取音效 PCM）。
    //   绕道方式（A 的说明书 §3.2，line_buf.v / sdr_arb.v 一行都不改）：
    //      disp_top.mem_rd_en/addr  → top_aud.line_rd_req/addr
    //      top_aud.line_rd_data/vld → disp_top.mem_rd_data/vld
    //      top_aud.sdr_rd_en/addr   → sdr_arb.disp_rd_en/addr   （= 下面这两根）
    //      sdram.Sdr_rd_dout/Sdr_rd_en → top_aud.mem_rd_dout/vld
    //   ★ 仲裁是"显示优先、音频只捡显示不用的拍"，**绝不压 disp_rd_en**
    //     （line_buf 的 fsent 是自己数的，压一拍就少收一个字 → 那行错位）。
    //   ⇒ 原来那两根直连线由 top_aud 驱动。
    // ★★★ 2026-10-06：音频和显示都改成块级之后，**没有任何东西再用逐拍读口**了，
    //   所以这两根打桩成 0（sdr_arb 内部的读侧本来就已经断开、App_rd_* 也没接）。
    assign st_rd_addr_m = 21'd0;
    assign st_rd_en_m   = 1'b0;

    // ============================================================
    //  ★★★ 2026-10-03（转场"不经过米白"）★★★  读口：整段禁读 → 只在写突发时等一等
    // ------------------------------------------------------------
    //  旧做法（`define 关掉时）：`a_busy` 期间把显示读**整段掐掉** →
    //     装载那几秒屏上是米白（这就是"三步方案"里那一步的来历）。
    //     ★ 但掐读是**有损**的：行缓冲按"发出去多少就收多少"记账，
    //       这一行只能等看门狗放弃（屏上那行变底色）。
    //  新做法（默认打开）：请求**原样**送下去，只在写引擎**突发**的那几拍
    //     让行缓冲**等一等**（`mem_rd_ok=0`，见 line_buf 的 rd_ok 那一段）。
    //     → 装载期间**旧图继续显示**，屏上不再有米白那一段。
    //  ★ 为什么代价极小：SD 慢，写突发是 512 字 / 约 20 ms 一次、每次约 4 µs
    //     （0.02% 的时间）；显示一行有 26 µs 余量，最多被推迟几 µs。
    //  ★★ 上板判读：万一看到花屏/错误像素，把下面这行注释掉就回到旧行为。
    // ============================================================
// `define LOAD_WITH_READS
//   ★★★ 2026-10-05【v7 收手】—— 用户在 v7 第三次迭代（4 字分块）上板后反馈
//     "和上一次没有什么差别"：条状花屏依旧、且越切越多。
//     三次迭代都没能消掉花屏 ⇒ 按用户定的优先级（**不花屏优先、速度不重要**），
//     回到确认干净的档：**装载期间整段禁读**（屏上是桌面米白）。
//   ★ "缩短米白"改走另一条**不碰这颗核**的路：
//     PC 端把演示素材先缩到 ~1152×864（写 497,664 字而不是 884,736 字，少 1.78 倍，
//     而且 BMP 文件更小、SD 读得也更快）。A 的 bmp_scale 那条路不要碰（上板证明会白屏）。
//   ★★★ 2026-10-05【v7 要打开它】：注意！下面 v7 的"推字只放行到消隐期"
//     （push_ok_m = vs / a_wr_full_g）是写在 **这个 ifdef 里面**的 ——
//     开关关着的时候那一支根本不编译，v7 就等于没改（上板看到的就是原来的
//     "米白 + 装载很快"）。所以 v7 必须：**开关打开** + 推字窗口 = 消隐期。
//     打开后的行为：读口不再整段禁读（旧图一直在）+
//                   写突发只在消隐期（那段时间显示不读）⇒ 既不撞也不饿。
//   ★★ 2026-10-04【又收回一次】：v6（提前 8 个字让路）上板仍然是
//      "白线扫屏 + 旧图花条纹"（写侧已经干净了：新图是好的），说明
//      **只要装载期间显示还在读，就一定会饿到显示** —— 这条路走不通。
//      ⇒ 默认回到"整段禁读"（屏上米白、图像干净）。
//      ⇒ "既要没米白、又要不花"只剩一条路：**把写限制在消隐期**（显示那段时间
//        根本不读），代价是 A 的写口一帧要停 ~16 ms —— 而 A 的 sd_read 里
//        TIME_OUT = 2 ms，所以必须先把它放大，这是 v2 白屏的老根，也是 v7 的前提。
//   ★★ 2026-10-04 【结论：默认关掉】——目标是"装载过程中不花屏"，而这一档做不到：
//      ① 突发期间让读等一等 → 上板：稀疏花屏（且花屏跟着缩放放大 ⇒ 坏的是写进 SDRAM 的图）
//      ② 整帧消隐才推字       → 上板：第一张图都出不来（A 的流式写口停 16ms 就死）
//      ③ 显示空闲窗口推字     → 上板：按 KEY3 没反应 + 花
//      ④ 只放行窗口前段       → 上板：毫无变化、依旧花
//      ⑤ 串口对账：引擎实写字数 vs A 自己推的字数 差 ~10,240 字
//      ⇒ 结论：**这颗 SDRAM 核 + 这颗原厂写引擎，容忍不了"边读边写"**。
//        只要装载期间显示还在读，写进去的图就有坏点（越切越多）。
//      ⇒ 要"不花屏"，只能：**装载期间整段禁读**（屏上是桌面米白），
//        这正好也是之前你确认能用的那档。
//      ⇒ 真想再试：取消这里注释（同时 0c 节的推字窗口也会一起生效）。
//   ★★ 2026-10-03：**默认关掉**。这一档（"装载期间继续读，只让写突发躲开显示"）
//      连着两版上板都没过：
//        v2（推字窗口=整帧消隐）→ A 写口一次停 16 ms，**第一张图都出不来**；
//        v3（推字窗口=显示没在读）→ **按 KEY3 没反应**（还没定性：可能是
//             中断在"装载没等到描述符"那一步，也可能是读写交织在别的环节上出事）。
//      ⇒ 先回到这次实验之前的、**确认能工作的**状态：
//        装载期间整段禁读（屏上米白）+ 两步直接转场（白 → 划像/淡化 → 新图）。
//      ⇒ 想再试就把这一行的注释去掉（同时第 1b/0c 节的推字窗口也会一起生效）。

`ifdef LOAD_WITH_READS
    assign aud_line_req = disp_rd_en;                   // 不再整段掐
    // ★★ v6（2026-10-04）：让路条件里加 `occ_pre`（占用快到 256 就先让）——
    //    请求是寄存的，"等突发开始再让"已经晚几拍，那几拍正是坏数据的来源。
    //    代价：每 ~330 µs 让 ~20 µs（SD 25MHz 下 16 个字），比一行 26.4 µs 还小。
    // ★★★ 2026-10-05【v7 关键修正】：这一档**不再让路**。
    //   用户上板：旧图在 ✓（读口没被整段禁读）但**白线还在扫** ✗
    //   ⇒ 那是"让路"造成的饿显示：`wr_burst|wr_guard|occ_pre` 会在装载期间
    //     反复把读口掐掉，几次连在一起就够让一行的取数跨过行尾 → 露一行底色
    //     （= 往上扫的白条）。
    //   ★ 而在 v7 里让路**本来就是多余的**：写突发已经被 `push_ok_m = vs`
    //     限制在**行场消隐期**，那段时间显示**根本不发读请求**（没有行首脉冲）
    //     ⇒ 读写天然分开，不需要再让谁让路。
    //   ⇒ 所以这里直接放行：`mem_rd_ok = 1'b1`。
    wire   mem_rd_ok  = 1'b1;                           // v7：不让路（写只在消隐期）
    wire   rd_allowed = 1'b1;                           // 给串口 flags 看
    // 这一档装载期间屏上一直是旧图 → 特效**从旧图那一端**开始划
    assign tr_from_white = 1'b0;
`else
    assign aud_line_req = disp_rd_en_g;                 // 旧行为：整段禁读（默认档）
    // ★★★★ 2026-10-06【试过并否掉 · 第二例】：曾把这里接成"每 2 拍放行 1 拍"的节流
    //   （想在"每拍一个读"上少发一半）。**上板结果：只有白屏 + 沙沙声** ——
    //   和把 `~sdr_busy` 接进来那次的症状一样。⇒ **结论：`line_buf` 的 `rd_ok` 这个口
    //   在当前的取数逻辑里【不能拿来当节流旋钮】**（一旦不是恒 1，整行就取不完）。
    //   ⇒ 已回退成恒放行。要做节流只能在【上层按块调度】做，不能在逐拍请求上做。
    wire   mem_rd_ok  = 1'b1;                           // 握手恒放行
    wire   rd_allowed = disp_rd_en_g;
    // ★★ 老档：装载期间屏上是米白（读被整段掐掉）→ 特效必须**从米白那一端**开始划。
    // ★★★ 2026-10-08【最小实验】装载期间**不再禁读**（上一条已经改掉），屏上一直是**旧图**
    //   ⇒ 特效必须**从旧图那一端**开始划（= 0），否则会先闪一下米白。
    assign tr_from_white = 1'b0;
`endif


    // ★ 写口仲裁：B 自测图正在写的时候，写口归它；其它时候归 A
    //   （两者不会同时写：自测图写完才允许 key1 触发 A 装载，
    //     见 stub_ctrl 的 hold 输入）
    wire        wr_req_m  = stwr_busy ? stwr_wrreq : a_wr_req;
    wire [20:0] wr_base_m = stwr_busy ? stwr_base  : a_wr_base;
    wire [20:0] wr_len_m  = stwr_busy ? stwr_len   : a_wr_len;
    wire [31:0] wr_data_m = stwr_busy ? stwr_data  : a_wr_data;
    wire        wr_we_m   = stwr_busy ? stwr_we    : a_wr_we;

    // ★ 存储本体的 App 接口（顶层例化 sdram，sdr_arb 只把信号引出来）
    wire        sdr_wr_en;
    wire [20:0] sdr_wr_addr;
    wire [3:0]  sdr_wr_dm;
    wire [31:0] sdr_wr_din;
    wire        sdr_rd_en;
    wire [20:0] sdr_rd_addr;

    // ★★★ 2026-10-04：**读写同拍**的"红线指示灯"（sticky）
    //   这颗 SDRAM 核只要在同一拍既收到读请求又收到写请求，就会坏数据。
    //   这里在显存域盯着 `App_rd_en & App_wr_en`：**一旦撞上就永久置 1**
    //   （软复位/重新下载才清），再同步到控制域放进串口 `flags` 的 bit14。
    //   ⇒ 判据：只要 flags bit14 = 1，就一定能解释"写进去的数据坏"；
    //     而 bit14 一直 0，坏数据就别赖读写了，得去查引擎/A 侧。
    // ★★ 2026-10-04：这三个都做成【寄存器】—— TD 的调试插入只保证寄存器能被抓
    //    （组合线网经常被优化掉，用户实测"列表里只有 clash_lat、没有 clash_now"）。
    //    app_rd_en_q / app_wr_en_q 是"核实际看到的读写请求"打一拍（两者同拍）
    //    ⇒ 触发用 app_wr_en_q（一定会停）就能顺便看 app_rd_en_q 有没有同时为 1。
    //    clash_q 就是"同拍撞上"的直接标志，clash_lat 是它的 sticky 版。
    reg app_rd_en_q, app_wr_en_q, clash_q, clash_lat;
    // ---- ★★ 写侧镜像（2026-10-04）：厂商模块（frame_fifo_write）内部的 reg
    //     在综合时会被重编码/改名，ChipWatcher 抓不到（用户实测 u_arb/u_wr/state
    //     找不到）。所以**不要在别人的模块里抓**，改成在顶层用我自己的寄存器
    //     把要看的量镜像出来 —— 而且全部喂进串口字段 25..28，
    //     有真实负载 ⇒ 一定不会被优化掉。
    //   ★★ 位宽**刚好用满**：TD 只保留"被用到的位"，位宽留大了会被剪掉高位、
    //      甚至改名 → watcher 列表里就找不到那个名字（用户踩过两次）。
    reg        app_wr_en_qq;                 // 上一拍（做上升沿用）
    reg [15:0] wr_beats;                     // 引擎"写字"的拍数低 16 位 = 写进 SDRAM 的字数
    reg [15:0] wr_bursts;                    // 引擎开过多少次突发
    reg [15:0] clash_cyc;                    // 读写同拍的拍数（累计）
    always @(posedge clk_sdr or negedge rst_n) begin
        if (!rst_n) begin
            app_rd_en_q <= 1'b0; app_wr_en_q <= 1'b0;
            clash_q <= 1'b0;     clash_lat   <= 1'b0;
            app_wr_en_qq <= 1'b0; wr_beats <= 16'd0;
            wr_bursts <= 16'd0;   clash_cyc <= 16'd0;
        end
        else begin
            app_rd_en_q <= sdr_rd_en;
            app_wr_en_q <= sdr_wr_en;
            clash_q     <= sdr_rd_en & sdr_wr_en;   // ← 读写同拍（寄存一拍）
            // ★★ 2026-10-04：`clash_lat` 里**同时**或上 app_rd_en_q & app_wr_en_q ——
            //   语义完全一样（同拍撞上，或它晚一拍的版本），但这样一来
            //   `app_rd_en_q` / `app_wr_en_q` 就有了**真实的负载**，
            //   TD 不会再把它们当成"没人用的寄存器"剪掉
            //   （用户实测 `clash_lat` 在、`app_wr_en_q` 不在，就是被剪了）。
            //   ★ 以后凡是要给 ChipWatcher 抓的寄存器，都必须挂一个真实负载。
            clash_lat   <= clash_lat | clash_q | (app_rd_en_q & app_wr_en_q);
            // 写侧镜像
            app_wr_en_qq <= app_wr_en_q;
            if (app_wr_en_q)              wr_beats  <= wr_beats + 16'd1;
            if (app_wr_en_q & ~app_wr_en_qq) wr_bursts <= wr_bursts + 16'd1;
            if (clash_q)                  clash_cyc <= clash_cyc + 16'd1;
        end
    end
    reg cl1, cl2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cl1 <= 1'b0; cl2 <= 1'b0; end
        else        begin cl1 <= clash_lat; cl2 <= cl1; end
    end

    // ★★ 2026-10-04：**occ 高位指示**（1 位，串口 flags bit14）
    //   `u_arb/occ` 是我们自己估的 FIFO 占用，写引擎的开工条件
    //   `into_burst = (rdusedw > BURST_SIZE=256)` 就看它。
    //   多位总线在 ChipWatcher 的 CSV 里导不准（实测 wr_beats 这种只加不减的计数器
    //   都在乱跳），所以这里压成 **1 位**：occ ≥ 512 就是"引擎认为满"。
    //   ★ 判据：**空闲时如果这一位一直是 1 ⇒ 引擎会永远突发、永远和显示抢读**。
    reg occ_hi_m;                                  // 显存域采样
    always @(posedge clk_sdr or negedge rst_n) begin
        if (!rst_n) occ_hi_m <= 1'b0;
        else        occ_hi_m <= occ_hi_w;
    end
    reg oh1, oh2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin oh1 <= 1'b0; oh2 <= 1'b0; end
        else        begin oh1 <= occ_hi_m; oh2 <= oh1; end
    end

    // ★★★ 2026-10-08【最小实验】读写两边的忙标志（互相接起来 = 恢复原厂仲裁）
    //   ★ 声明必须放在下面两个例化之前（这个工程踩过五次"先用后声明"）
    wire        rd_busy_w;                 // 读通路：读突发进行中（vendor_rd_path.o_rd_busy）
    wire        wr_busy_w;                 // 写引擎：突发中/马上突发（sdr_arb.o_wr_busy）

    sdr_arb u_arb (
        .clk_ctl(clk), .rst_ctl_n(sys_rst_n),
        .a_wr_req(wr_req_m), .a_wr_base(wr_base_m), .a_wr_len(wr_len_m),
        .a_wr_ack(a_wr_ack),
        .a_wr_data(wr_data_m), .a_wr_we(wr_we_m),
        .a_wr_full(a_wr_full), .a_wr_done(a_wr_done), .sdr_ready(sdr_ready),
        .clk_mem(clk_sdr), .clk_mem_180(clk_sdr180), .rst_mem_n(sys_rst_n),
        .disp_rd_en(st_rd_en_m), .disp_rd_addr(st_rd_addr_m),
        .o_wr_burst(wr_burst), .o_wr_guard(wr_guard),
        .o_occ_hi(occ_hi_w), .o_occ_pre(occ_pre_w),
        .o_wr_cnt(sdr_wr_cnt),
        // ★★★ 2026-10-08 最小实验：把原厂的读写仲裁接上（见《B轨待改清单》§22）
        .rd_busy(rd_busy_w),            // ← 读通路：读突发进行中
        .o_wr_busy(wr_busy_w),          // → 读通路：写侧忙（突发中/马上突发）
        // ★ 存储本体挪到顶层了：App 接口引出去，顶层接 sdram
        .App_wr_en(sdr_wr_en), .App_wr_addr(sdr_wr_addr),
        .App_wr_dm(sdr_wr_dm), .App_wr_din(sdr_wr_din),
        // ★★★ 2026-10-06：**读口不再由 sdr_arb 驱动**（交给下面的 vendor_rd_path）
        .App_rd_en(), .App_rd_addr(),
        .Sdr_init_done(sdr_init_done), .Sdr_init_ref_vld(sdr_init_ref_vld),
        .Sdr_busy(sdr_busy)
    );

    // ============================================================
    //  3b. ★★★ 2026-10-06：**官方读通路**（块级）—— 显示的行取数走这里
    //      · vendor_rd_path = frame_fifo_read + 读 FIFO（把 wrusedw 引出来）
    //      · blk_rd_arb     = 块级仲裁（显示优先；音频口留着，现在音频关着）
    //      · 读口 sdr_rd_en/sdr_rd_addr 由 vendor_rd_path 驱动（sdram 那两行不用改）
    //      · 读写互斥仍靠 disp_rd_gate（装载期间不许发块请求）
    // ============================================================
    wire        vrd_ack, vrd_fin, vrd_used_nz, vrd_busy;
    wire [31:0] vrd_dout;
    wire [9:0]  vrd_used;                  // ★ 探针：FIFO 现在几个字
    wire [15:0] vrd_rd_en_cnt;             // ★ 探针①：官方控制器发过多少次 App_rd_en
    wire        vrd_fifo_seen;             // ★ 探针②：FIFO 曾经非空过吗
    wire [15:0] blk_fin_cnt;               // ★ 探针③：仲裁器服务完几个块
    wire [15:0] blk_aud_cnt;               // ★ 探针：其中几块是音频
    wire        blk_timeout;               // ★ 探针：仲裁器看门狗掐断过（sticky）
    wire        blk_d_gnt;
    wire        dbg_want_seen, dbg_lock_seen;   // ★ 探针 bit6/bit7（o_want 到过 / 锁拿到过）
    // ★ 2026-10-08：o_dv 由 2 位扩到 3 位 —— bit0 = 显示 / bit1 = 音频 / bit2 = 字幕
    wire [2:0]  o_blk_dv;
    // ---- ★★★ 2026-10-08 字幕的块级读口（top ↔ blk_rd_arb 的第三个客户）----
    //   ★ 这一组**不过**"装载期间禁读"闸门：字幕只在图装完之后才去读，
    //     那时闸门早就是 1 了；而过了闸门反而会在闸门为 0 时把 req 掩掉、
    //     让 subtitle_ovl 的取数 FSM 卡在"等授权"上（得不偿失）。
    wire        sub_blk_req;
    wire [20:0] sub_blk_base, sub_blk_len;
    wire        sub_blk_gnt, sub_blk_next, sub_blk_fin;
    wire [31:0] sub_blk_data;
    wire [15:0] sub_row_cnt;
    wire        sub_hit;
    wire [15:0] sub_sum16;           // ★ 指纹：片上字幕 RAM 求和低 16
    wire [10:0] sub_nz;              // ★ 指纹：第一个非零字下标
    wire        sub_nz_v;
    wire [31:0] blk_d_data;

    vendor_rd_path u_vrd (
        .clk_mem          (clk_sdr),
        .rst_mem_n        (sys_rst_n),
        .sdr_init_done    (sdr_init_done),
        .sdr_init_ref_vld (sdr_init_ref_vld),
        .sdr_busy         (sdr_busy),
        .wr_busy          (wr_busy_w),      // ★ 原厂互锁：写侧忙 ⇒ 读不发突发
        // 读口（独占 SDRAM）
        .App_rd_en        (sdr_rd_en),
        .App_rd_addr      (sdr_rd_addr),
        .Sdr_rd_en        (rd_vld),
        .Sdr_rd_dout      (rd_data),
        // 块请求
        .rd_req           (blk_rd_req),
        .rd_ack           (vrd_ack),
        .rd_fin           (vrd_fin),
        .rd_base          (blk_rd_base),
        .rd_len           (blk_rd_len),
        // 取数
        .rd_re            (blk_rd_re),
        .rd_dout          (vrd_dout),
        .rd_valid         (),
        .rd_used          (vrd_used),
        .rd_used_nz       (vrd_used_nz),
        .o_rd_busy        (vrd_busy),
        .o_rd_en_cnt      (vrd_rd_en_cnt),
        .o_fifo_seen      (vrd_fifo_seen)
    );
    assign rd_busy_w = vrd_busy;            // 给写引擎看（同一根线上游）

    blk_rd_arb u_blk (
        .clk_mem        (clk_sdr), .rst_mem_n(sys_rst_n),
        // 官方读侧
        .rd_req         (blk_rd_req), .rd_ack(vrd_ack), .rd_fin(vrd_fin),
        .rd_base        (blk_rd_base), .rd_len(blk_rd_len),
        .rd_en          (blk_rd_re), .rd_data(vrd_dout),
        .rd_used_nz     (vrd_used_nz),
        // ★★ 2026-10-09：短块收尾要用"官方还忙不忙"来判（漏掉一拍宽的 read_finish 时
        //   不再死等到看门狗 —— 那一下会把显示/音频的读口卡 65 µs）
        .rd_busy        (rd_busy_w),
        // 显示口（接到 disp_top 的 blk_*）
        .d_req          (d_blk_req), .d_base(d_blk_base), .d_len(d_blk_len),
        .d_gnt          (blk_d_gnt), .d_next(d_blk_want),
        .d_data         (blk_d_data), .o_dv(o_blk_dv), .d_done(),
        // 音频口：★ 2026-10-06 起接到 top_aud 的块级音频读客户端
        .a_req          (aud_a_req_g), .a_base(aud_a_base), .a_len(aud_a_len),
        .a_gnt          (aud_a_gnt), .a_next(aud_a_next), .a_data(blk_a_data), .a_done(),
        // ★ 字幕口（2026-10-08）：一次一行的 25 字短块，优先级排在最后
        .s_req          (sub_blk_req), .s_base(sub_blk_base), .s_len(sub_blk_len),
        .s_gnt          (sub_blk_gnt), .s_next(sub_blk_next),
        .s_data         (sub_blk_data), .s_done(sub_blk_fin),
        .o_blk_cnt      (blk_fin_cnt), .o_aud_blk_cnt(blk_aud_cnt),
        .o_sub_blk_cnt  (),
        .o_timeout      (blk_timeout)
    );

    // ============================================================
    //  ★★★ 2026-10-06 诊断：读通路【整条链】的 sticky 位图（串口字段 30）
    //   上一版探针已证明"官方控制器一次 App_rd_en 都没发"。那到底卡在链的哪一环？
    //   这一位图一次就能看出来（每一位一旦置起就保持，直到复位）：
    //     bit0 = 行缓冲的原始块请求 blk_req 出现过
    //     bit1 = 过了"装载期间禁读"闸门、仲裁器看到的 d_req 出现过
    //     bit2 = blk_rd_arb 受理并授权过（read_req_ack 回来过）
    //     bit3 = blk_rd_arb 把请求转发给官方控制器（rd_req）过
    //     bit4 = 官方控制器受理（read_req_ack）过
    //     bit5 = 官方控制器真的发过 App_rd_en（= 驱动 SDRAM 的读使能，就是 sdr_rd_en）
    //   ★ 判读：从 bit0 往上看，**第一个还是 0 的那一位就是断点**。
    //  ★★★ 2026-10-08【最小实验】再加两位，专看"原厂读写仲裁到底有没有生效"：
    //     bit8 = 读忙(O_rd_busy) 和 写忙(O_wr_busy) **同拍都高**过（sticky）
    //            两者本来就该互斥，同拍高说明互锁没拦住 ⇒ 会看到读写命令撞车
    //     bit9 = 显示读请求**被推迟超过 200 拍**过（sticky；200 拍 ≈ 1.6 µs）
    //            有它 = 写突发确实把显示挡住过（配合字段 29 看挡得最久多少拍）
    // ============================================================
    // ★ 显示读请求被推迟的拍数（字段 29 报最大值）——★ 声明必须在下面两个 always 之前
    reg [15:0] rd_defer_cnt, rd_defer_max;
    reg [15:0] dbg_chain;
    always @(posedge clk_sdr or negedge rst_n) begin
        if (!rst_n) dbg_chain <= 16'd0;
        else begin
            if (d_blk_req_raw) dbg_chain[0] <= 1'b1;
            if (d_blk_req)     dbg_chain[1] <= 1'b1;
            if (blk_d_gnt)     dbg_chain[2] <= 1'b1;
            if (blk_rd_req)    dbg_chain[3] <= 1'b1;
            if (vrd_ack)       dbg_chain[4] <= 1'b1;
            if (sdr_rd_en)     dbg_chain[5] <= 1'b1;
            if (dbg_want_seen) dbg_chain[6] <= 1'b1;
            if (dbg_lock_seen) dbg_chain[7] <= 1'b1;
            if (rd_busy_w & wr_busy_w)          dbg_chain[8] <= 1'b1;
            if (rd_defer_cnt > 16'd200)         dbg_chain[9] <= 1'b1;
            // ★★ 2026-10-09：bit10 = 音频块读 FIFO 被饿穿过（sticky）
            //   它是"沙沙声到底是数据错、还是读没跟上"的分水岭。
            if (aud_dbg_underrun)               dbg_chain[10] <= 1'b1;
        end
    end

    // ★★★ 2026-10-08【最小实验】探针（串口字段 29）：**显示读请求被推迟的最大拍数**
    //   `d_blk_req` 一直举着（拿到第一个字才撤），`blk_d_gnt` 是仲裁器授权 ——
    //   两者之间"举着但没授权"的最长连续拍数，就是"写突发把显示挡了多久"。
    //   ★ 基线（没有写突发时）大约 5~10 拍（等官方控制器的 ack 握手）。
    //   ★ 判读：一次 256 字写突发 ≈ 250 拍以上；只要它 < 一行的时间（3300 拍）
    //     且图不花，就说明"块级交替"是能用的。
    always @(posedge clk_sdr or negedge rst_n) begin
        if (!rst_n) begin
            rd_defer_cnt <= 16'd0;
            rd_defer_max <= 16'd0;
        end
        else if (d_blk_req && ~blk_d_gnt) begin
            if (rd_defer_cnt != 16'hFFFF) rd_defer_cnt <= rd_defer_cnt + 16'd1;
            if (rd_defer_cnt > rd_defer_max) rd_defer_max <= rd_defer_cnt;
        end
        else rd_defer_cnt <= 16'd0;
    end

    // ============================================================
    //  3a. 存储本体：★ 例化在【顶层】（和官方例程 / M0 一样）
    //      原来它套在 sdr_arb 里面（u_arb/u_sdram/sdram），现在挪出来。
    // ============================================================
`ifdef SIM_SDRAM
    fake_sdram u_sdram (
`else
    sdram u_sdram (
`endif
        .Clk              (clk_sdr),
        .Clk_sft          (clk_sdr180),      // ★ 必须接 180° 那一相
        .Rst              (~sys_rst_n),
        .Sdr_init_done    (sdr_init_done),
        .Sdr_init_ref_vld (sdr_init_ref_vld),
        .Sdr_busy         (sdr_busy),
        .App_wr_en        (sdr_wr_en),
        .App_wr_addr      (sdr_wr_addr),
        .App_wr_dm        (sdr_wr_dm),
        .App_wr_din       (sdr_wr_din),
        .App_rd_en        (sdr_rd_en),
        .App_rd_addr      (sdr_rd_addr),
        .Sdr_rd_en        (rd_vld),
        .Sdr_rd_dout      (rd_data)
    );

    // ============================================================
    //  ★★ 2026-09-28：抓【SDRAM 写口上前 4 个字】= 图像左上角前 4 个像素。
    //     和电脑上那张原图的同位置逐点对比：
    //       一致  → 卡/存储都对，问题在显示侧
    //       不一致→ A 的取数/打包错了（能看出是偏移、上下翻、还是每两个像素互换）
    //     ★ 覆盖写：留下的就是【最后一次】写进去的值（= A 的真图，
    //       而不是开机那张自测图）。
    // ============================================================
    // ★★ 2026-09-28 改法（上一版"当地址=0 时抓"在加补偿后永远不触发，读到一堆 0）：
    //   改成抓【最后 4 笔写的地址】+ 最新那一笔的数据 ——
    //   这样能直接看出 A 的那一串写到哪个地址区间去了（落在哪、结束在哪）。
    // ★★ 2026-09-28 第二轮：写口落点已经查清（举多少落多少），这 8 个字段
    //    改抓【第 200 行、x = 0/2/4/.../14 这 8 个“屏上真实像素”】——
    //    用来定位"每隔几列有一小条右移"的横向问题。
    // ★★ 2026-09-28 第三轮：原来采的是【屏幕第 200 行、窗口列 0..14】，
    //    但那一行在原图里正好是一大片纯色（窗口列 0..14 全一样），
    //    有错位也看不出来。改成采原图【第 241 行】（它对 2 像素的横移
    //    8 个采样点全都会变），并且分两处采：
    //      左端：窗口列 0/2/4/6     （屏幕 x = 80/82/84/86）
    //      中段：窗口列 300/302/304/306（屏幕 x = 380/382/384/386）
    //    行映射：屏幕第 y 行 = 原图第 (y-60) 行（窗口左上角在 80,60）
    //            → 采原图第 241 行就是采【屏幕第 301 行】。
    //    原图第 241 行的标准答案（从卡里那张 BMP 用脚本算出来的）：
    //      左端 0/2/4/6     = 29D1 21D1 21F1 2211
    //      中段 300/302/304/306 = 2127 2969 20E7 18C6
    //    右移 2 像素会变成 21D1 21F1 2211 2231 / 2969 20E7 18C6 5AAD，
    //    所以只要错位，这 8 个数立刻就对不上。
    // ★★ 2026-09-28 第四轮（★ 整行扫描探针）：把"固定 8 个点"升级成
    //    "每帧换一组、40 帧把一整行 320 个字全读回来"。
    //    为什么：固定 8 个点只能看到 8 个字，错位的【形态】（从第几个字开始歪、
    //    是重复、跳字还是整段平移）看不全 —— 这次要一次量到底。
    //
    //    原理：窗口是 x = 80..719（640 宽），屏幕列 80+2k 对应行内第 k 个字。
    //          第 i 帧取 k = 8i .. 8i+7（屏幕列 80+16i .. 80+16i+14），
    //          i 从 0 走到 39 就把 k = 0..319 全部覆盖一遍。
    //          探针是在【屏幕第 301 行】取的（= 窗口第 241 行 = 源图第 241 行），
    //          和串口里 lb_* 那组数采的是同一行的搬运结果。
    //    判读：自测图 PAT_MODE=2 里"字的值 = 它的字地址"，所以第 k 个字正确的
    //          时候，读回来的低 16 位应当 = 0x2980 + k（本行行首 = 238*320）。
    //    ★ 组号用 vs 的上升沿推进（frame_start_w 在本文件里声明得比较晚，
    //      这里用不了；vs_w 是提前声明过的）。
    //    ★ 每 4 帧才换一组：串口一条帧 200ms ≈ 12 帧，若每帧都换，组号
    //      每次刚好跳 12（mod 40），永远只能看到 1/4 的组；改成 4 帧换一组
    //      后每次跳 3（3 与 40 互质）→ 40 条帧就能把整行 320 个字走一遍。
    // ★★★ 2026-09-28 第六轮（★ 边缘巡检）：上面那版只抽【偶数像素】（字的"高半字"），
    //     奇数像素从来没看过，上/下边缘那两行也没抽 —— 而用户看到的问题正好是
    //     "四条边缘各差 1 个像素"。这一版一次下载把这几处全覆盖：
    //       每一趟(pass)固定"看窗口哪一行 + 取偶数还是奇数像素"，在这一行上扫 40 组。
    //         pass 0: 窗口第   0 行（图的【上边缘】）  偶数列
    //         pass 1: 窗口第   0 行                    奇数列
    //         pass 2: 窗口第   1 行                    偶数列
    //         pass 3: 窗口第 479 行（图的【下边缘】）  偶数列
    //         pass 4: 窗口第 479 行                    奇数列
    //         pass 5: 窗口第 241 行（已用偶数验过的那行）奇数列 ← 补上盲区
    //       每组 8 个采样点 = 16 个像素（间隔 2）：屏幕列 80+16i+2j+half。
    //     ★ 组号每 4 帧走一格（40 格 ≈ 8 秒走完一趟），走完一趟换 pass（共 6 趟 ≈ 48 秒）。
    //    ★ 第七轮改成【列巡边】：每一趟查"左边缘 16 列"或"右边缘 16 列"的
    //      偶数/奇数像素，组号 g 决定查哪一行（第 0 行 + 每 12 行一行，共 40 行）：
    //         pass 0: 窗口列 0..15 的偶数像素    pass 1: 同左，奇数像素
    //         pass 2: 窗口列 624..639 的偶数像素 pass 3: 同右，奇数像素
    //      （每组的 8 个采样点 = 该行端点上的 8 个像素，间隔 2。）
    //    ★ 第十轮【只盯最左一列、逐行铺开】：pass 只区分"取偶数像素(列0)/奇数像素(列1)"，
    //      组号 g 决定从第 8g 行开始，连续看 8 行 → 40 组铺满第 0..319 行。
    //      这样一次抓取就能看出"每 3 行一个字错"这条周期（上一版一次只抽到 12 处）。
    reg [2:0]  pass_i;                        // 0..1
    reg [5:0]  dump_i;                        // 0..39：这一趟里的第几组
    reg        vs_d;
    reg [1:0]  dump_div;
    wire       scan_half  = pass_i[0];                     // 0=偶数像素 1=奇数像素
    wire [11:0] scan_y_scn = 12'd60 + ({6'd0, dump_i} * 12'd8);   // 这一组的头一行（屏幕行）
    wire [11:0] scan_x_scn = 12'd80 + {11'd0, scan_half};         // 最左一列（列 0 或 1）
    always @(posedge clk_pix or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            pass_i <= 3'd0;
            dump_i <= 6'd0;
            vs_d   <= 1'b0;
            dump_div <= 2'd0;
        end
        else begin
            vs_d <= vs_w;
            if (vs_w & ~vs_d) begin                 // 场同步上升沿 = 新的一帧
                if (dump_div == 2'd3) begin
                    dump_div <= 2'd0;
                    if (dump_i >= 6'd39) begin
                        dump_i <= 6'd0;
                        pass_i <= (pass_i >= 3'd1) ? 3'd0 : pass_i + 3'd1;
                    end
                    else dump_i <= dump_i + 6'd1;
                end
                else dump_div <= dump_div + 2'd1;
            end
        end
    end

    reg [15:0] px0, px1, px2, px3, px4, px5, px6, px7;
    reg [5:0]  px_grp;              // ★ 和这 8 个字【同一拍】锁存的组号
                                    //   （串口那边冻结的就是这一对，不会半新半旧）
    always @(posedge clk_pix or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            px0 <= 16'd0; px1 <= 16'd0; px2 <= 16'd0; px3 <= 16'd0;
            px4 <= 16'd0; px5 <= 16'd0; px6 <= 16'd0; px7 <= 16'd0;
            px_grp <= 6'd0;
        end
        else if (de_w && (dbg_x == scan_x_scn)) begin
            if (dbg_y == scan_y_scn + 12'd0) begin px0 <= rgb565_w; px_grp <= dump_i; end
            if (dbg_y == scan_y_scn + 12'd1) px1 <= rgb565_w;
            if (dbg_y == scan_y_scn + 12'd2) px2 <= rgb565_w;
            if (dbg_y == scan_y_scn + 12'd3) px3 <= rgb565_w;
            if (dbg_y == scan_y_scn + 12'd4) px4 <= rgb565_w;
            if (dbg_y == scan_y_scn + 12'd5) px5 <= rgb565_w;
            if (dbg_y == scan_y_scn + 12'd6) px6 <= rgb565_w;
            if (dbg_y == scan_y_scn + 12'd7) px7 <= rgb565_w;
        end
    end

    // ============================================================
    //  3b. 读口自测（M0 读法的移植）—— 开机自测图写完 + 50ms 之后跑一次
    //      ★ 它跑的时候占着读口（显示那边那几十微秒的行会黑一下，随后自愈）
    // ============================================================
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            stwr_done_lat <= 1'b0;
            st_dly        <= 24'd0;
            st_go         <= 1'b0;
        end
        else begin
            if (stwr_done) stwr_done_lat <= 1'b1;
            if (stwr_done_lat && !st_go) begin
                if (st_dly >= 24'd2_500_000) st_go <= 1'b1;   // ≈50ms @50MHz
                else                         st_dly <= st_dly + 24'd1;
            end
        end
    end

    // ======================================================================
    //  ★★★ 2026-10-09【集成临时改动 · 省面积】**删掉读口自检 u_selftest**
    //    （`vendor_read_test` + 它内部的 `frame_read_write` 两颗 FIFO，共 ~285 LUT）
    //  · 它从 **2026-09-28** 起就**没有任何作用**了：读口当时已经"完全交给显示"，
    //    顶层把它的输出打桩成 0（`st_rd_en_m/st_rd_addr_m` = 0，见上面那一行），
    //    `st_go` 拉高也读不到任何东西 —— 属于纯挂着的死逻辑。
    //  · 它的 8 个输出里，只有 `st_bad` 还进串口（另外几格早被写侧镜像/转场探针占掉了）。
    //    ⇒ 这里把 `st_bad` 直接接 0（`st_bad`/`st_first` 那两格在转场探针模式下本来就不看）。
    //  ★ 要恢复：把这段例化放回来、并把下面那行 assign 删掉。
    //    例化原文在 git 历史里（`git show 651aa6a:rtl/top_m2.v`，搜 vendor_read_test）。
    // ======================================================================
    assign st_bad  = 16'd0;
    assign st_busy = 1'b0;      // 串口 flags 的 bit12 用它（自检都没了，恒 0）

    // ============================================================
    //  4. 描述符接收侧（A 写 → B 每帧读）
    //     ★ 第一遍上板它只是"接上、正常工作"，但显示参数不从它取
    // ============================================================
    wire [2-1:0] desc_valid;
    wire [2*21-1:0] desc_base;
    wire [2*12-1:0] desc_src_w, desc_src_h;
    wire [2*2-1:0]  desc_format;
    wire [2-1:0]    desc_transposed;
    wire [2*8-1:0]  desc_img_no;
    wire [15:0]     desc_version;
    wire            desc_pending;

    wire            frame_start_w;
    wire [15:0]     frame_id_w;

    desc_rx #(.SLOT_NUM(2)) u_desc (
        .clk_ctl(clk), .rst_ctl_n(sys_rst_n),
        .a_desc(a_desc), .a_commit_tgl(a_commit_tgl), .a_ack_tgl(a_ack_tgl),
        .clk_pix(clk_pix), .rst_pix_n(disp_rst_n), .frame_start(frame_start_w),
        .o_valid(desc_valid), .o_base(desc_base),
        .o_src_w(desc_src_w), .o_src_h(desc_src_h),
        .o_format(desc_format), .o_transposed(desc_transposed),
        .o_img_no(desc_img_no),
        .o_version(desc_version), .o_pending(desc_pending)
    );

    // ============================================================
    //  5. 显示链
    // ============================================================
    wire        win_on;
    wire [11:0] win_x0, win_y0, win_w, win_h;

    // ★★ 2026-10-02：窗口改成【铺满全屏 800x600】，用来显示 800x600 的图。
    //   配套把上面的 `define USE_DESC 打开 —— 源图尺寸从 A 的描述符里读，
    //   这样 800x600 铺满整屏、640x480 就摆在左上角（右边/下边留底色），
    //   换图不用改代码。（B 的 win_sample 自带"窗口比源图宽/高"两个兜底）
    stub_win_table #(
        .WIN_X0(0), .WIN_Y0(0), .WIN_W(800), .WIN_H(600)
    ) u_win (
        .win_x0(win_x0), .win_y0(win_y0),
        .win_w(win_w), .win_h(win_h), .win_on(win_on)
    );

`ifdef USE_DESC
    // ---- 显示参数来自 A 的描述符 ----
    // ★★★ 2026-10-03（转场）：从"挑最新的那一张"改成【前台 / 后台两路一起给】。
    //   · front_sel = 0 → 槽 0 当前台（合成器的 A 路）、槽 1 当后台（B 路）；
    //                  = 1 → 反过来。
    //   · 转场走完 transition_ctrl 会给一拍 swap，这里就把前台/后台对调。
    //     ★ 对调那一拍屏上正好"精确等于新图"，所以一点跳变都看不见。
    //   · A 往【非前台】那个槽写（见下面 a_slot_use）—— 于是"前台正在显示的那份"
    //     永远不会被覆盖；这就是原来 ⑤ 想用 slot_free 保证的事，结构上就成立了。
    wire        src_valid = desc_valid[front_sel];
    wire [20:0] src_base  = front_sel ? desc_base[41:21]  : desc_base[20:0];
    wire [11:0] src_w     = front_sel ? desc_src_w[23:12] : desc_src_w[11:0];
    wire [11:0] src_h     = front_sel ? desc_src_h[23:12] : desc_src_h[11:0];

    // 后台那一路（同一个槽，只是取反）
    wire        src_b_valid = desc_valid[~front_sel];
    wire [20:0] src_b_base  = front_sel ? desc_base[20:0]  : desc_base[41:21];
    wire [11:0] src_b_w     = front_sel ? desc_src_w[11:0] : desc_src_w[23:12];
    wire [11:0] src_b_h     = front_sel ? desc_src_h[11:0] : desc_src_h[23:12];
`else
    // ---- 先写死：大槽 0、640x480（第一遍上板，变量最少）----
    //   ★★ 这两个数【必须和卡里那张图的实际尺寸一致】★
    //      卡里是 640x480 的图 → 就写 640 / 480。
    //      写错的话行距（每行多少个字）就和 A 写进去的对不上，屏上是花屏。
    //      （打开 USE_DESC 之后就不用管了：尺寸从描述符里读，见上面那段）
    wire        src_valid = 1'b1;
    wire [20:0] src_base  = 21'd0;
    wire [11:0] src_w     = 12'd640;
    wire [11:0] src_h     = 12'd480;
    // 第二路：关掉（常数传播，整块逻辑不综合）
    wire        src_b_valid = 1'b0;
    wire [20:0] src_b_base  = 21'd0;
    wire [11:0] src_b_w     = 12'd640;
    wire [11:0] src_b_h     = 12'd480;
`endif

    // ============================================================
    //  5b. 缩放档位 → step + 居中偏移（★ M2 新增）
    //     level 0 = 适配（整张图缩进窗口、居中）；1..5 = 1x/1.5x/2x/3x/4x
    //     "适配"那一次除法在这里算（udiv_q16_up，换档/换图才跑一次）
    // ============================================================
    // ★★★ 2026-10-03 ★ 缩放几何：前台/后台**各一套** ★（见台账 §十五 / §十六）
    //   为什么要两套：直接划像/叠化时**两张图同时在屏上**，而它们的适配缩放
    //   不一样。共用一套的话，进来的那张会被拿出去的 step/off 取样 ——
    //   就是上板抓到的"只露左上角、收尾才闪回正位"（§十五）。
    //   ★ 资源：zoom_dual 里只留**一套**算术（除法 + 两处乘法），
    //     输入按相位轮流喂两个槽的尺寸、输出分两个寄存器组锁住 ——
    //     比"例化两个 zoom_sel"省 4 个 DSP（预算只剩 3 个）。
    wire [31:0] z_a_step, z_a_offu, z_a_offv;
    wire [31:0] z_b_step, z_b_offu, z_b_offv;

    zoom_dual u_zoom (
        .clk_pix(clk_pix), .rst_pix_n(disp_rst_n),
        .level(zoom_p2),
        .a_w(src_w),   .a_h(src_h),
        .b_w(src_b_w), .b_h(src_b_h),
        .win_w(win_w), .win_h(win_h),
        .a_step(z_a_step), .a_off_u(z_a_offu), .a_off_v(z_a_offv),
        .b_step(z_b_step), .b_off_u(z_b_offu), .b_off_v(z_b_offv),
        .busy()
    );

    wire        hdmi_locked;

    // ============================================================
    //  ★★★ 2026-10-03 转场探针（"装载期间继续读"那一档卡住时用来定位）
    //  一条链是：KEY3 → 请求 → A 起装 → 描述符生效 → 转场 → 对调前台。
    //  这四组数（塞进串口字段 6/7/8/9）能一眼看出断在哪一节：
    //     6 = {KEY3 次数, 请求次数}      键有没有被看到 / 请求有没有发出去
    //     7 = {a_start 次数, a_wr_ack 次数}   A 有没有被放行去写
    //     8 = {描述符版本变化次数, a_wr_done 次数}  装载有没有真的完成
    //     9 = {swap 次数, 状态位}         转场有没有走完
    //  ★ 计数在一个域里做、用"翻一次"的位过域（脉冲直接跨域会漏）。
    // ============================================================
    // ① 像素域：把两个"事件"变成翻转位（翻一次永远不会漏）
    reg        ver_tgl, ver_d;
    reg        swap_tgl;
    always @(posedge clk_pix or negedge disp_rst_n) begin
        if (!disp_rst_n) begin
            ver_tgl <= 1'b0; ver_d <= 16'd0; swap_tgl <= 1'b0;
        end
        else begin
            ver_d <= desc_version;
            if (desc_version != ver_d) ver_tgl  <= ~ver_tgl;   // 描述符生效一次
            if (tr_swap)               swap_tgl <= ~swap_tgl;  // 转场走完一次
        end
    end
    // ② 控制域：把翻转位同步过来 + 取边沿 → 计数
    reg vt1, vt2, vt3, st1, st2, st3, rt1b, rt2b, rt3b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vt1<=1'b0; vt2<=1'b0; vt3<=1'b0;
            st1<=1'b0; st2<=1'b0; st3<=1'b0;
            rt1b<=1'b0; rt2b<=1'b0; rt3b<=1'b0;
        end
        else begin
            vt1<=ver_tgl;   vt2<=vt1;   vt3<=vt2;
            st1<=swap_tgl;  st2<=st1;   st3<=st2;
            rt1b<=req_tgl;  rt2b<=rt1b; rt3b<=rt2b;
        end
    end
    reg [7:0] p_k1, p_req, p_start, p_ack, p_ver, p_swap, p_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_k1<=8'd0; p_req<=8'd0; p_start<=8'd0; p_ack<=8'd0;
            p_ver<=8'd0; p_swap<=8'd0; p_done<=8'd0;
        end
        else begin
            if (k1_press_w)         p_k1    <= p_k1    + 8'd1;
            if (rt2b ^ rt3b)        p_req   <= p_req   + 8'd1;   // 请求（翻转一次）
            if (a_start)            p_start <= p_start + 8'd1;
            if (a_wr_ack)           p_ack   <= p_ack   + 8'd1;
            if (vt2 ^ vt3)          p_ver   <= p_ver   + 8'd1;   // 描述符生效
            if (st2 ^ st3)          p_swap  <= p_swap  + 8'd1;   // 转场走完
            if (a_wr_done)          p_done  <= p_done  + 8'd1;
        end
    end
    // ③ 四组探针（接串口字段 6/7/8/9）
    wire [15:0] tr_p0 = {p_k1,    p_req};
    wire [15:0] tr_p1 = {p_start, p_ack};
    wire [15:0] tr_p2 = {p_ver,   p_done};
    wire [15:0] tr_p3 = {p_swap, 2'b00, ml2, ac2, fs2, fx2, req_pend_w};

    // ★★ 2026-09-28：写和读绝不能同时进行，但"只禁读"会把行缓冲饿死
    //    （实测：禁读一段时间后 disp_rd_en 永远是 0、行缓冲再也发不出请求，
    //      屏上只剩底色）。所以改成：**只要有写在跑，就把显示整块复位**，
    //    写完再从干净状态开始 —— 这时图已经在 DRAM 里，一次就读对。
    disp_top u_disp (
        .clk_pix(clk_pix), .clk_par(clk_par), .clk_ser(clk_ser),
        .rst_pix_n(disp_rst_n),
        .src_valid(src_valid), .src_base(src_base),
        .src_w(src_w), .src_h(src_h),
        // ★★ 2026-10-03（转场）：第二路 = 后台那个槽 + 转场三级
        .src_b_valid(src_b_valid), .src_b_base(src_b_base),
        .src_b_w(src_b_w), .src_b_h(src_b_h),
        // ★ 后台那一路自己的缩放几何（前台的在下面 step_q16/off_*）
        .step_b_q16(z_b_step), .off_ub_q16(z_b_offu), .off_vb_q16(z_b_offv),
        .tr_req(tr_req), .tr_fx(tr_fx), .tr_ver(desc_version),
        .tr_from_white(tr_from_white),
        // ★★★ 2026-10-08【预装】：后台槽已就绪 ⇒ 按键时转场走快速路（跳过 LOAD）
        .tr_back_ready(tr_back_ready),
        .tr_may_load(tr_may_load), .tr_active(tr_active), .tr_swap(tr_swap),
        .tr_show_back(tr_show_back),
        // ★★★ 2026-10-08【字幕叠加】：先给暂定位置；以后换成 C 的 WIN_SUB 那一行
        .sub_on(sub_on_s2),          // ★ 50 MHz 域 → 像素域，过了两位同步器
        .sub_x0(SUB_X0_DFLT), .sub_y0(SUB_Y0_DFLT),
        .sub_w(SUB_W_DFLT), .sub_h(SUB_H_DFLT),
        .sub_base(SUB_BASE), .sub_ink(SUB_INK),
        .sub_tpat(SUB_TPAT),
        .s_blk_req(sub_blk_req), .s_blk_base(sub_blk_base), .s_blk_len(sub_blk_len),
        .s_blk_gnt(sub_blk_gnt), .s_blk_next(sub_blk_next),
        .s_blk_dv(o_blk_dv[2]), .s_blk_data(sub_blk_data), .s_blk_fin(sub_blk_fin),
        .o_sub_row_cnt(sub_row_cnt), .o_sub_hit(sub_hit),
        .o_sub_sum16(sub_sum16), .o_sub_nz(sub_nz), .o_sub_nz_v(sub_nz_v),
        .win_on(win_on),
        .win_x0(win_x0), .win_y0(win_y0), .win_w(win_w), .win_h(win_h),
        .step_q16(z_a_step), .off_u_q16(z_a_offu), .off_v_q16(z_a_offv),
        .clk_mem(clk_sdr), .rst_mem_n(disp_rst_n),
        // ★★★ 2026-10-06：块级读通路（原来这里是 mem_rd_en/addr）
        .blk_req(d_blk_req_raw), .blk_base(d_blk_base), .blk_len(d_blk_len),
        // ★★★ 2026-10-05：读数据不再直连 SDRAM 控制器，而是**经 top_aud 分流**
        //   （top_aud 只把"显示要的那份"给回来，音频的数据它自己收进 FIFO）
        .blk_gnt(blk_d_gnt), .blk_want(d_blk_want), .blk_dv(o_blk_dv[0]), .blk_data(blk_d_data),
        .o_dbg_want_seen(dbg_want_seen), .o_dbg_lock_seen(dbg_lock_seen),
        // ★★ 音频 6 根 → my_hdmitop（同一个像素域）
        .I_audio_valid(hdmi_audio_valid),
        .I_audio_left (hdmi_audio_left),
        .I_audio_right(hdmi_audio_right),
        .I_acr_valid  (hdmi_acr_valid),
        .I_acr_cts    (hdmi_acr_cts),
        .I_acr_n      (hdmi_acr_n),
        .HDMI_CLK_P(HDMI_CLK_P),
        .HDMI_D0_P(HDMI_D0_P), .HDMI_D1_P(HDMI_D1_P), .HDMI_D2_P(HDMI_D2_P),
        .HDMI_DDC_SCL(HDMI_DDC_SCL), .HDMI_DDC_SDA(HDMI_DDC_SDA),
        .o_video_locked(hdmi_locked),
        .o_frame_start(frame_start_w), .o_frame_id(frame_id_w),
        .o_de(de_w), .o_vs(vs_w),
        .o_dbg_x(dbg_x), .o_dbg_y(dbg_y),
        .o_rgb565(rgb565_w),
        .dbg_wbase(lb_wbase0), .dbg_fwords(lb_words0),
        .dbg_rd0(lb_rd0), .dbg_rd1(lb_rd1),
        .o_drop_cnt(lb_drop), .o_abort_cnt(lb_abort)
        ,.o_off_first(lb_off), .o_align_bad(lb_alignbad)
    );

    // ============================================================
    //  5a-2. ★★★ 2026-10-05：A 轨音频链（top_aud）
    //    它内部收了 4 个模块：sfx_ctrl / sdr_rd_arb / sfx_player / audio_arc_calculate。
    //    在这里只做三件事：① 时钟复位；② 读口绕道（见上面第 2b 节那几行）；
    //                      ③ 音频 6 根接进 disp_top → my_hdmitop。
    //    ★ 复位：mem/pix 域都用 sys_rst_n（**不要**用 disp_rst_n ——
    //      display 在装载期间会被整段复位，那会把"静音兜底"的音频流也一起掐断）。
    // ============================================================
    top_aud #(
        .SFX_NUM    (2),
        .SFX_STRIDE (SFX_STRIDE),
        .SFX_BASE   (SFX_BASE),
        .ACR_N      (6144)
    ) u_aud (
        .clk_ctl(clk),          .rst_ctl_n(sys_rst_n),
        .clk_mem(clk_sdr),      .rst_mem_n(sys_rst_n),
        .clk_aud(clk_aud),      .rst_aud_n(aud_rst_n),
        .clk_pix(clk_pix),      .rst_pix_n(sys_rst_n),

        // ---- C 轨命令（现在由顶层那个小状态机自产）----
        .play_sfx(aud_play_req), .sfx_id(4'd0), .volume(8'hFF), .busy(aud_busy_w),

        // ---- ★★★ 2026-10-06 块级音频读口（接 blk_rd_arb 的音频口）----
        //   a_req 过和显示同一道"装载期间禁读"闸门（§6.3-1 红线）。
        .a_req     (aud_a_req),
        .a_base    (aud_a_base),
        .a_len     (aud_a_len),
        .a_gnt     (aud_a_gnt),
        .a_next    (aud_a_next),
        .a_data    (blk_a_data),
        .a_dv      (o_blk_dv[1]),
        .rd_ok     (disp_rd_gate),

        // ---- 音频 6 根 ----
        .o_audio_valid(hdmi_audio_valid),
        .o_audio_left (hdmi_audio_left),
        .o_audio_right(hdmi_audio_right),
        .o_acr_valid  (hdmi_acr_valid),
        .o_acr_cts    (hdmi_acr_cts),
        .o_acr_n      (hdmi_acr_n),

        // ---- 诊断（进串口字段 28）----
        .dbg_sfx_base (aud_dbg_base),
        .dbg_sfx_words(aud_dbg_words),
        .dbg_play_tgl (aud_dbg_play_tgl),
        .dbg_aud_dout (aud_dbg_dout),
        .dbg_aud_vld  (aud_dbg_vld),
        .dbg_blk_stall(aud_blk_stall),
        .dbg_aud_cnt  (aud_dbg_cnt),
        .dbg_aud_sum  (aud_dbg_sum),
        .dbg_aud_underrun(aud_dbg_underrun)   // ★★ 2026-10-09 饿死探针
    );

    // ============================================================
    //  5b. 【送到 HDMI 的像素】逐像素自检
    //      和自测图（stub_a_writer PAT_MODE=1）比对：
    //        R=000000 → 显示链吐出来的就是那张自测图
    //        R 很大   → 读出来/搬过来的东西是错的，看 G/E
    // ============================================================
    wire [23:0] chk_cmp, chk_bad;
    wire [15:0] chk_got, chk_exp;
    wire [9:0]  chk_u;
    wire [8:0]  chk_v;

    pix_check #(
        .WIN_X0(80), .WIN_Y0(60), .WIN_W(640), .WIN_H(480),
        .PAT_MODE(2)
    ) u_chk (
        .clk_pix(clk_pix), .rst_pix_n(sys_rst_n),
        .de(de_w), .x(dbg_x), .y(dbg_y), .rgb565(rgb565_w),
        .o_cmp(chk_cmp), .o_bad(chk_bad), .o_got(chk_got), .o_exp(chk_exp),
        .o_u(chk_u), .o_v(chk_v),
        .o_row0(chk_row0), .o_row1(chk_row1), .o_row2(chk_row2), .o_row3(chk_row3),
        .o_row4(chk_row4), .o_row5(chk_row5), .o_row6(chk_row6), .o_row7(chk_row7)
    );

    // ============================================================
    //  6. LED：一眼看出卡在哪一步
    // ============================================================
    reg load_done_latch;
    reg fail_latch;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            load_done_latch <= 1'b0;
            fail_latch      <= 1'b0;
        end
        else begin
            // ★ 这两个都是【单拍脉冲】，必须锁存 ——
            //   串口每 0.5 秒才看一次，不锁存就会漏掉（这会直接骗人）
            if (a_load_done) load_done_latch <= 1'b1;
            if (a_fail)      fail_latch      <= 1'b1;
        end
    end

    // ============================================================
    //  ★★★ 2026-10-05：音频上板首试 —— 自产的"装音效 + 播放"命令
    // ------------------------------------------------------------
    //  为什么要有它：C 轨还没接，`play_sfx / sfx_id / volume` 没有来源。
    //  这一版让顶层自己发一遍，把整条链（SD → SDRAM → top_aud → HDMI）走通。
    //
    //  ★ 顺序（全自动，不用按键）：
    //     上电 → 装第一张图（原有流程一个字没改）→ 图显示出来
    //          → 等 1 秒 → **屏上米白 ≈ 音效时长**（装音效；装载期间显示整段禁读
    //            是当前唯一确认不花屏的那一档）
    //          → 图自己回来 + **自动播一次**
    //     之后每按 KEY3 换一张图，新图出来时会再播一次
    //     （换图带音效，正好是演示想要的效果；sfx_ctrl 正在播时会自动忽略新命令）
    //
    //  ★ 判据（串口字段 28 的高 8 位）：
    //     bit15 aud_fail / bit14 aud_loaded / bit13 音频PLL锁 / bit12 aud_busy
    //     bit11 有音频数据流 / bit10 play_tgl 在翻 / bit9:8 状态机
    // ============================================================
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            aud_want       <= 1'b0;
            aud_loaded     <= 1'b0;
            aud_fail       <= 1'b0;
            aud_load_pulse <= 1'b0;
            aud_play_req   <= 1'b0;
            aud_st         <= 2'd0;
            aud_wait       <= 26'd0;
        end
        else begin
            aud_load_pulse <= 1'b0;
            // ---- 每次【受理换图请求】→ 请播一次（音效没装进来时就别播了，免得放垃圾）----
            // ★★★ 2026-10-08【预装】：原来是挂 `a_load_done`（= 图装完那一刻响）。
            //   预装之后 a_load_done 会在【IDLE 期间偷偷预装】时就来一次 ⇒ 若还挂它，
            //   音效会在"没人按键"的时候自己响。改成挂 `req_accept_w`
            //   （控制桩受理请求那一拍）⇒ **还是按键那一下响**，而且比原来早
            //   0.3~1.8 秒（原来的响点被 LOAD 那段等到了图装完之后）。
            //   上电那一次：req_accept 早于 aud_loaded ⇒ 不响；音效自己装完后
            //   （下面 aud_st==2）照旧播一次 —— 和原来一样。
            if (req_accept_w && aud_loaded) aud_play_req <= 1'b1;
            else                            aud_play_req <= 1'b0;

            case (aud_st)
            // ---- 0：等第一张图真的出来 ----
            2'd0: begin
                // ★★ 2026-10-06：AUDIO_OFF=1 时在这里就停住 —— 不进 1，也就
                //    不会装音效、不会播放 ⇒ 音频一个读都不发（见上面那个开关的说明）。
                if (AUDIO_OFF) begin
                    aud_st <= 2'd0;
                end
                else if (load_done_latch && !aud_loaded && !aud_fail) begin
                    aud_wait <= 26'd0;
                    aud_st   <= 2'd1;
                end
            end
            // ---- 1：先等 1 秒（让用户看到图），再挑一个"没在换图"的时刻开装 ----
            2'd1: begin
                if (!load_done_latch) begin
                    aud_st <= 2'd0;
                end
                else if (!tr_active && !a_busy && !req_pend_w) begin
                    if (aud_wait >= 26'd50_000_000) begin      // 1 s @50MHz
                        aud_want       <= 1'b1;
                        aud_load_pulse <= 1'b1;
                        aud_st         <= 2'd2;
                    end
                    else aud_wait <= aud_wait + 26'd1;
                end
                // 忙（正在换图 / A 在装 / 有挂起的转场请求）就停着等，计时不推进
            end
            // ---- 2：等音效装完 ----
            2'd2: begin
                if (a_wav_done) begin
                    aud_loaded   <= 1'b1;
                    aud_want     <= 1'b0;
                    aud_play_req <= 1'b1;
                    aud_st       <= 2'd3;
                end
                else if (a_fail) begin
                    aud_fail <= 1'b1;
                    aud_want <= 1'b0;
                    aud_st   <= 2'd3;
                end
            end
            // ---- 3：做完，不再动 ----
            default: ;
            endcase
        end
    end

    // ============================================================
    //  ★★★ 2026-10-08【字幕自检装载】：等音频那条做完 → 等 0.5 秒 → 装一条 .SUB
    //    ★ 顺序是刻意的：A 只有一个"start"口，两个自产装载必须串起来。
    //      这里用"等 aud_loaded / aud_fail（或 AUDIO_OFF）+ 图已经出来"当闸门。
    // ============================================================
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sub_st         <= 2'd0;
            sub_load_pulse <= 1'b0;
            sub_loaded     <= 1'b0;
            sub_fail       <= 1'b0;
            sub_wait       <= 26'd0;
            sub_pulse_lat  <= 1'b0;
            sub_done_lat   <= 1'b0;
        end
        else begin
            sub_load_pulse <= 1'b0;
            case (sub_st)
            // ---- 0：等"音频那条自检"收工（或音频关掉），并且图已经出来过 ----
            2'd0: begin
                if ((AUDIO_OFF || aud_loaded || aud_fail) && load_done_latch) begin
                    sub_wait <= 26'd0;
                    sub_st   <= 2'd1;
                end
            end
            // ---- 1：挑一个"没在换图 / 没在装别的"的时刻，等 0.5 秒再发 ----
            2'd1: begin
                if (!tr_active && !a_busy && !req_pend_w && !aud_load_pulse) begin
                    if (sub_wait >= 26'd25_000_000) begin      // 0.5 s @50MHz
                        sub_load_pulse <= 1'b1;
                        sub_pulse_lat  <= 1'b1;                // ★ 探针：脉冲发出去过
                        sub_wait       <= 26'd0;
                        sub_st         <= 2'd2;
                    end
                    else sub_wait <= sub_wait + 26'd1;
                end
            end
            // ---- 2：等这一条字幕写进 SDRAM；失败就当没有字幕（不再重试）----
            2'd2: begin
                if (a_sub_done) begin
                    sub_loaded <= 1'b1;
                    sub_done_lat <= 1'b1;                      // ★ 探针：A 报"装完了"
                    sub_st     <= 2'd3;
                end
                // ★ 等 40 ms 之后再信 a_fail：`a_fail` 是三条链**合并**的出错口，
                //   之前的装载（比如卡里没 WAV）可能已经把它拉高过，不能立刻判死。
                else if (sub_wait < 26'd2_000_000) begin
                    sub_wait <= sub_wait + 26'd1;
                end
                else if (a_fail) begin
                    sub_fail <= 1'b1;
                    sub_st   <= 2'd3;
                end
                // ★ 另一个兜底：A 已经闲下来了却迟迟没有 sub_done ⇒ 那条链没跑起来
                else if (!a_busy) begin
                    sub_wait <= sub_wait + 26'd1;
                    if (sub_wait >= 26'd50_000_000) begin      // 1 s
                        sub_fail <= 1'b1;
                        sub_st   <= 2'd3;
                    end
                end
            end
            // ---- 3：做完，不再动 ----
            default: ;
            endcase
        end
    end

    assign led[0] = pll0_locked & pll_sdr_locked;   // 两个 PLL 都锁了
    assign led[1] = a_sd_ready;                     // SD 卡初始化完成
    assign led[2] = load_done_latch;                // 至少装完过一张
    assign led[3] = fail_latch;                     // A 报错过（亮就是出问题，一直亮）

    // ============================================================
    //  ★ 2026-09-28 诊断位图：塞进串口的 drop_cnt 字段（read_report.ps1 会翻译）
    //    目的是把"蓝屏"这件事一次看清：到底谁把显示的读挡住了。
    // ============================================================
    reg a_started_lat;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) a_started_lat <= 1'b0;
        else if (a_start_use) a_started_lat <= 1'b1;
    end
    wire [15:0] dbg_flags = {
        cl2,                // bit15 ★★ 2026-10-04：读写同拍过吗（clash_lat 的同步副本）
        oh2,                // bit14 ★ 占用已满（occ>=512，见上面 occ_hi_m 那段）
        a_started_lat,      // bit13 ★ A 收到过启动脉冲吗
        st_busy,            // bit12 ★ 读口自测还占着读口吗
        ac2,                // bit11 ★ 2026-10-03 转场：正在转场中（transition_ctrl.active）
        ml2,                // bit10 ★ 转场说"屏上全米白，可以去写 SDRAM"（may_load）
        fs2,                // bit9  ★ 前台上的是哪个槽（0=槽0 1=槽1）
        a_load_done,        // bit8  ★ A 装完过一张吗（电平）
        hdmi_locked,        // bit7
        desc_valid[0],      // bit6  ★ A 的描述符有效吗
        rd_allowed,         // bit5  ★ 这一拍存储**愿意收**读请求吗
                            //   （LOAD_WITH_READS 打开时 = mem_rd_ok，
                            //    关掉时 = disp_rd_en_g，两种口径都是"能不能读"）
        disp_rd_en,         // bit4  ★ 显示想不想读
        stwr_busy,          // bit3  ★ 自测图写入器还在忙吗
        a_busy,             // bit2
        sdr_ready,          // bit1
        a_sd_ready          // bit0
    };

    // ============================================================
    //  ★★ 2026-10-01 实验一：Sdr_busy / Sdr_init_ref_vld 到底动不动？
    // ------------------------------------------------------------
    //  要回答的问题（"每 1024 字漏写一个地址"那个已知瑕疵）：
    //    "写使能有效的时候，SDRAM 的忙/刷新标志是不是也高着？"
    //    如果从来没同时高过 → "没管 busy 所以丢字"这条猜测当场否掉。
    //
    //  为什么必须实测：APUG011 手册的表 3-1 把 `Sdr_busy` 标成"暂不使用"，
    //    原厂参考设计的 top 里它甚至是个没声明的隐式 wire（综合器报警告），
    //    原厂测试发生器 app_wrrd 的端口上根本没有这个信号；可手册 2.3 节
    //    和移植注意第 3 条又让你"读写前判断忙不忙"。到底该门控哪一个，
    //    文档自己说不清，只能上板量。
    //
    //  ★ 全部在 clk（50MHz）域数：先把三根线各同步两拍再数。
    //    采样分辨率 20ns，而这三根线的电平都远长于 20ns（刷新要几十拍），够用。
    //    ⇒ 报告里的"拍数"单位是 50MHz 拍，不是 125MHz 拍（差 2.5 倍），
    //      只影响绝对值，不影响"0 / 非 0"和数量级。
    //  ★ 计数器只增不减、饱和在 0xFFFF；串口一条帧 200ms，
    //    要看"速率"就在两次读数之间做差（_check_busy.py 会打印时间戳）。
    // ============================================================
    reg sb1, sb2, rv1, rv2, we1, we2;
    reg sb_d, rv_d;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sb1 <= 1'b0; sb2 <= 1'b0; rv1 <= 1'b0; rv2 <= 1'b0;
            we1 <= 1'b0; we2 <= 1'b0; sb_d <= 1'b0; rv_d <= 1'b0;
        end
        else begin
            sb1 <= sdr_busy;          sb2 <= sb1;
            rv1 <= sdr_init_ref_vld;  rv2 <= rv1;
            we1 <= sdr_wr_en;         we2 <= we1;
            sb_d <= sb2;              rv_d <= rv2;
        end
    end
    wire sb_hi   = sb2;                 // Sdr_busy         （同步后）
    wire rv_hi   = rv2;                 // Sdr_init_ref_vld （同步后）
    wire we_hi   = we2;                 // 写使能（= App_wr_en）
    wire sb_rise = sb_hi & ~sb_d;       // Sdr_busy 的上升沿

    reg        we_ever, sb_ever, rv_ever, sb_col_ever, rv_col_ever;
    reg [15:0] sb_rise_cnt, sb_col_cnt, rv_col_cnt;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            we_ever <= 1'b0; sb_ever <= 1'b0; rv_ever <= 1'b0;
            sb_col_ever <= 1'b0; rv_col_ever <= 1'b0;
            sb_rise_cnt <= 16'd0; sb_col_cnt <= 16'd0; rv_col_cnt <= 16'd0;
        end
        else begin
            if (we_hi)          we_ever     <= 1'b1;   // 量的是不是东西，自检
            if (sb_hi)          sb_ever     <= 1'b1;
            if (rv_hi)          rv_ever     <= 1'b1;
            if (we_hi && sb_hi) sb_col_ever <= 1'b1;   // ★ 撞车
            if (we_hi && rv_hi) rv_col_ever <= 1'b1;   // ★ 撞车

            if (sb_rise && sb_rise_cnt != 16'hFFFF)
                sb_rise_cnt <= sb_rise_cnt + 16'd1;
            if (we_hi && sb_hi && sb_col_cnt != 16'hFFFF)
                sb_col_cnt <= sb_col_cnt + 16'd1;
            if (we_hi && rv_hi && rv_col_cnt != 16'hFFFF)
                rv_col_cnt <= rv_col_cnt + 16'd1;
        end
    end

    // 位图：bit4 写使能曾有效 / bit3 busy 撞车 / bit2 刷新撞车
    //       / bit1 busy 曾高 / bit0 刷新标志曾高
    wire [15:0] dbg_busy_flags = {
        11'd0, we_ever, sb_col_ever, rv_col_ever, sb_ever, rv_ever
    };

    // ============================================================
    //  7. 串口状态输出（黑屏时的"眼睛"，以它为准）
    // ============================================================
    wire [7:0] dbg_status = {
        hdmi_locked,        // bit7
        a_dbg_warn_odd,     // bit6
        a_dbg_overrun,      // bit5
        fail_latch,         // bit4 ★ 锁存过的，不是单拍脉冲
        load_done_latch,    // bit3
        a_busy,             // bit2
        a_sd_ready,         // bit1
        (pll0_locked & pll_sdr_locked)  // bit0
    };

    dbg_report #(
        .CLK_HZ(50_000_000), .PERIOD_MS(200)      // ★ 测量版：快一点（200ms 一帧）
    ) u_dbg (
        .clk(clk), .rst_n(sys_rst_n),
        .val(sdr_wr_cnt),               // ★ W 改成"存储封装一共交接了多少字"
        .status(dbg_status),
        .frm(frame_id_w[7:0]),
        // ★ 第六轮：chk_bad 在真图模式下没有参考价值（它按地址图的期望值比），
        //   这两个字段改接【A 输出过多少个像素】（正常 307200 = 0x0004B000）
        .bad(a_dbg_px_cnt[23:0]),
        // ★★★ 2026-10-03：字段 6..9 改成【转场探针】（见上面那段）——
        //   M1 时代那组"整行扫描"已经不用了，字段 25..28 仍留着旧的那 4 个字。
        .row0(tr_p0), .row1(tr_p1), .row2(tr_p2), .row3(tr_p3),
        .row4(px0), .row5(px1), .row6(px2), .row7(px3),
        // ★ 诊断位图（见上面 dbg_flags）+ 行缓冲被掐断次数
        // ★ 第六轮：字段11 改接【A 自己报的推字个数】低 16 位（正常 153600 → 0x5800）
        .drop_cnt(dbg_flags), .abort_cnt(a_dbg_wr_cnt[15:0]),
        // ★ 行缓冲探针：请求的行首地址 + 实际收到的头两个字
        .lb_wbase(lb_wbase0[15:0]), .lb_rd0(lb_rd0[15:0]),
        .lb_rd1(lb_rd1[15:0]),      .lb_words({4'd0, lb_words0}),
        // ★ 逐字对齐校验：第 1 个字偏几个 / 本趟几个字不对（0 = 逐字全对）
        //   ★★★ 2026-10-09【临时占用 · 查字幕指纹】：这两个口只在"地址图"模式下有意义
        //      （现在屏上是真照片 ⇒ 它们的读数本来就没意义），借来报字幕指纹：
        //        字段 19 = **片上字幕 RAM 1600 字求和**的低 16 位（对位序/极性敏感）
        //        字段 20 = {bit15 有效, bit10:0 **第一个非零字的下标**}（对行序/内容敏感）
        //      电脑上按同一套规则算 SUB1.SUB 的期望值，一比就知道"片上数据对不对"。
        //      查完字幕再换回 lb_off / lb_alignbad。
        .lb_off(sub_sum16), .lb_alignbad({4'd0, sub_nz_v, sub_nz}),
        // ★ 测试旋钮：当前在途上限档位 / key1 按了多少次
        // ★ M2：字段 29（原 cmp_sel）现在报【当前缩放档 0..5】；字段 30 是 KEY1 按了几次
        .cmp_sel({13'd0, zoom_lv}), .key_cnt({12'd0, key_cnt}),
        // ★★ 2026-09-28 第四轮：这四个字段改接"整行扫描组号 + 第一个错像素的位置/值"
        //    （A 那几个诊断数在自测图模式下本来就没有意义，出图版要的话改回来即可）
        // ★ 第六轮：边缘巡检 —— 字段 21..24 = 组号 / 趟号 / 奇偶 / 看的窗口行
        .st_read_cnt({10'd0, px_grp}),           // 字段21：这一趟里的第几组（0..39）
        .st_bad({13'd0, pass_i}),                // 字段22：第几趟（0..5，见上面注释表）
        // ★ 第六轮：字段 23/24 改接【A 请求的长度 a_wr_len】—— "一帧最后 256 个字
        //   没写进 SDRAM"到底是 A 请求短了、还是引擎少写了一段，看
        //   字段 0/1（引擎实写字数）+ 字段 11（A 自己推的字数）+ 这两个数就能定死。
        .st_off(a_wr_len[15:0]),                 // 字段23：A 请求的长度低 16 位
        .st_first({11'd0, a_wr_len[20:16]}),     // 字段24：A 请求的长度高位
        .st_w0(wr_beats), .st_w1(wr_bursts), .st_w2(clash_cyc),
        // ★★ 2026-10-05：字段 28 从"固定 0"改成【音频链状态位图】
        //   高 8 位：bit7=fail bit6=loaded bit5=音频PLL锁 bit4=busy
        //            bit3=有音频数据流 bit2=play_tgl 在翻 bit1:0=状态机(0等图/1等待/2装载/3做完)
        .st_w3({aud_fail, aud_loaded, pll_aud_locked, aud_busy_w,
                aud_dbg_vld, aud_dbg_play_tgl, aud_st,
                // ★★★ 2026-10-09【字段 28 的低 8 位改成字幕状态】（高 8 位音频一字未动）
                //   bit7 sub_loaded(装好了) bit6 sub_fail(失败) bit5 脉冲发过
                //   bit4 a_sub_done 回来过 bit3 sub_overrun bit2 sub_short bit1:0 sub_st
                sub_loaded, sub_fail, sub_pulse_lat, sub_done_lat,
                a_dbg_sub_overrun, a_dbg_sub_short, sub_st}),
        // ★★ 2026-10-04：字段 25..28 从 M1 时代的扫描字 px4..px7 改成【写侧镜像】：
        //    25 = 引擎写字拍数(低16) / 26 = 突发次数 / 27 = 读写同拍拍数 / 28 = A 的段长度(低5)
        // ★★ 2026-10-01 实验一：SDRAM 忙 / 刷新 与写使能
        // ★★★ 2026-10-08【最小实验】：字段 29 从"10-01 那次 SDRAM 忙/刷新实验位图"
        //   改成 **显示读请求被推迟的最大拍数**（`rd_defer_max`）——
        //   那次实验的结论早就有了（那两根线的问题被否掉），现在这一格更有用。
        //   判读：0~10 拍 = 一切正常；几百拍 = 被写突发挡过（配合字段 30 的 bit9）。
        .sb_flags(rd_defer_max),
        // ★★ 2026-10-06：字段 12 的 bit1 从"tag 队列脱钩过"改成
        //   **音频块级读被看门狗掐断过**（tag 机制整条删掉了，这一位留给音频自检）。
        .tag_bad(aud_blk_stall),
        // ★★★ 2026-10-05（第 8 条）：字段 30/31/32 从"10-01 那次 SDRAM 忙/刷新实验"
        //     改成【音频数据自检】——那次实验的结论早就有了（那两根线的问题被否掉），
        //     现在这三格更有用：
        //       30 = 本次播放已从 SDRAM 收了多少个音频字
        //       31 = 这些字的 32 位累加和【低 16】
        //       32 = 这些字的 32 位累加和【高 16】
        //     ★ 拿它和电脑上按 WAV 算出的期望值比：对上了 = 读回来的音频数据逐字正确。
        // ★★★ 2026-10-06 诊断临时占用（音频现在 AUDIO_OFF=1，它的自检本来就闲着）：
        //   字段 30 = 官方控制器发过多少次 App_rd_en（0 ⇒ 一次读都没发）
        //   字段 31 = 仲裁器服务完几个块（read_fin 次数）
        //   字段 32 = 读 FIFO 的当前占用 + bit15 = "FIFO 曾经非空过"
        // ★★★ 2026-10-06【一个下载要能同时验两件事】：
        //   30 = 读通路整条链的 sticky 位图（显示用）—— 全 1 才算过
        //   31 = 本次播放音频从 SDRAM 收了多少个字（低 16 位；满 3 秒 = 0x1940）
        //   32 = 这些字的 32 位和的【低 16 位】（期望 0x4411，和 = 0xB7464411，
        //        见 sd_card_sfx\sfx_checksum.py 复算）
        //   ⇒ 这一版既有显示、又有音频，一次烧录就能同时判这两条。
        .sb_rise (dbg_chain),
        .sb_col  (aud_dbg_cnt[15:0]),
        .rv_col  (aud_dbg_sum[15:0]),
        .uart_tx(uart_tx)
    );

    // 自测图写的时候不读：写完再让显示读
    // ★★ 2026-09-26 晚：把读和写【串行化】—— 这正是 M0 那份上板验过的写路径的做法：
    //    bw_measure 是"先猛写一串 → 显式歇一会儿等写缓冲排空 → 再读"，
    //    它**从来没有让读和写同时进行**。
    //    而我们这版是"显示的读一直不停 + 写穿插在里面"，实测后果是
    //    **写入握手全走完、数据却没真正落进 DRAM**（串口 A=000000/N=140 全对，
    //    但 D0/D1 读回来是未初始化的原始内容）。
    //   所以：B 自测图正在写的那段时间，把显示的读关掉；写完再恢复。
    //   ★ 被掐断的那一次搬运会由 line_buf 的看门狗放弃（65us），不会永久卡死。
    // ★★ 2026-09-27 补：SDRAM 初始化完成之前【绝对不能读写】（厂商文档原话）。
    //    原来只挡了"自测图正在写"那一段，没有挡"初始化还没完"那一段 ——
    //    初始化期间（预充电/刷新/写模式寄存器）被读请求打扰，SDRAM 可能就停在
    //    一个错误模式里，而且会一直错下去。所以这里把 sdr_ready 也加进来。
    // ★★ 2026-09-28：写和读【绝对不能同时进行】—— 原厂的 frame_read_write 就是
    //    用 App_rd_busy / O_wr_busy 把两边串起来的，它从来没有让读写在时间上重叠。
    //    我们这版以前只挡住"自测图在写"的那一段，A 从 SD 卡装载期间显示的读还在跑，
    //    后果就是"写入握手全走完、数据却没落进 DRAM"（2026-09-26 就记过一次）。
    //    现在：自测图在写、A 在装图、SDRAM 还没好 —— 三种情况都把显示的读关掉。
    //    （被掐断的搬运由 line_buf 的看门狗放弃，不会永久卡死；期间屏上是旧内容/杂点，
    //      装完之后自然恢复。）
    // ============================================================
    //  ★★★ 2026-10-03 第二版【读禁用】—— 回到 a_busy 门控，兜底放到 300 秒
    //
    //  历史教训（全是上板换来的）：
    //    · 2026-09-26：读写在时间上重叠 → 握手走完、数据没落进 DRAM
    //    · 2026-10-02：rd_mute 只管到"第一次装完"，从第二张起没禁读 →"越切越花"
    //    · 2026-10-03：兜底时间写错（28 位装不下 5 亿 → 实际只有 4.63 秒）。
    //      这张 1920x1200 的图装载要约 70 秒 → 65 秒里读写在打架，
    //      屏上是"一大片上一张图的残余"；把兜底改到 60 秒后重叠只剩 10 秒，
    //      残余退化成"稀疏花点" —— 坐实了病根是读写重叠。
    //      但 60 秒仍然不够（装载 70 秒），所以这里放到 **300 秒**：
    //      任何真实装载都顶不到，兜底只当"万一 A 卡死"的安全网。
    //
    //  ★ 为什么不用 a_wr_done 门控（试过，不可行）：
    //    按 sdr_arb 的注释，它应该是"引擎报 finish 置 1、下一笔 ack 清 0"的锁存电平，
    //    理论上 ~a_wr_done 是最干净的门控。**实测上板直接白屏**（闸门一直关着、
    //    屏上只剩桌面底色）→ 说明它在这套设计里并不按注释描述工作。
    //    所以回到 a_busy：它覆盖 A 的全部阶段（含 bmp2sdram 等 sdr_done 的 S_WAIT），
    //    是这条链上真正"从头到尾"的信号。
    //
    //  ★ 闸门关着不是黑屏：disp_rd_en_g=0 只是【不读 SDRAM】，合成器照常输出
    //    桌面底色（米白），HDMI 信号不断。装图期间看到底色、装完出图。
    // ============================================================
    reg        rd_load_seen;
    reg [33:0] rd_mute_cnt;      // 34 位：300 秒 @50MHz = 1.5e10 < 2^34
    assign     rd_mute = ~rd_load_seen && (rd_mute_cnt < 34'd15_000_000_000);
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rd_load_seen <= 1'b0;
            rd_mute_cnt  <= 34'd0;
        end
        else begin
            if (a_load_done) rd_load_seen <= 1'b1;
            if (!rd_load_seen && (rd_mute_cnt < 34'd15_000_000_000))
                rd_mute_cnt <= rd_mute_cnt + 34'd1;
        end
    end

    reg [33:0] abusy_cnt;
    wire       abusy_block = a_busy && (abusy_cnt < 34'd15_000_000_000);
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n)                          abusy_cnt <= 34'd0;
        else if (!a_busy)                        abusy_cnt <= 34'd0;
        else if (abusy_cnt < 34'd15_000_000_000) abusy_cnt <= abusy_cnt + 34'd1;
    end

    // ★★★ 2026-10-08【最小实验】把 `abusy_block` 从这道闸门里去掉：
    //   以前"装载期间整段禁读"（屏上米白）。现在改成**不整段禁读**，
    //   由原厂的读写仲裁（App_rd_busy/App_wr_busy 互相接）去保证"块级交替、不重叠"。
    //   ★ 这条老闸门留在注释里：**回退就是把它加回来**。
    //   ★ stwr_busy（B 自测图写入）仍保留：那条路只在 bring-up 时用，别动它。
    assign disp_rd_en_g = (stwr_busy | ~sdr_ready | rd_mute) ? 1'b0 : disp_rd_en;

    // ============================================================
    //  ★★★ 2026-10-06：块级读通路的收尾（放在这里，所有声明都已就位）
    //    · 旧的"逐拍读请求" `disp_rd_en/disp_rd_addr` 已经没有驱动源了
    //      （line_buf 改成块级）⇒ 打桩成 0，免得 `aud_line_req`、串口 flags、
    //      `rd_idle_cnt` 那些老引用悬空。音频现在 AUDIO_OFF=1，本来也不需要它。
    //    · 块请求走同一个"装载期间禁读"闸门（§6.3-1 红线，条件与上一行完全一致）。
    // ============================================================
    assign disp_rd_en   = 1'b0;
    assign disp_rd_addr = 21'd0;
    // ★★★ 2026-10-08【最小实验】块请求的闸门也不再看 `abusy_block`（装载期间不再禁读）。
    //   ⇒ 装载时显示照常读**旧图**，读写由原厂仲裁做"块级交替"。
    //   回退：把 `| abusy_block` 加回来即可（= 老的"整段禁读"档）。
    assign disp_rd_gate = ~(stwr_busy | ~sdr_ready | rd_mute);
    assign d_blk_req    = d_blk_req_raw & disp_rd_gate;
    // ★ 音频的块请求走【同一道闸门】（装载期间一个读都不发，§6.3-1 红线）。
    assign aud_a_req_g  = aud_a_req & disp_rd_gate;

    // ============================================================
    //  8. 数码管：显示 dbg_wr_cnt（正常 03A980）—— 以串口为准，这是参考
    // ============================================================
    wire [6:0] s5, s4, s3, s2, s1, s0;
    seg_decoder u_d5 (.bin_data(a_dbg_wr_cnt[23:20]), .seg_data(s5));
    seg_decoder u_d4 (.bin_data(a_dbg_wr_cnt[19:16]), .seg_data(s4));
    seg_decoder u_d3 (.bin_data(a_dbg_wr_cnt[15:12]), .seg_data(s3));
    seg_decoder u_d2 (.bin_data(a_dbg_wr_cnt[11:8]),  .seg_data(s2));
    seg_decoder u_d1 (.bin_data(a_dbg_wr_cnt[7:4]),   .seg_data(s1));
    seg_decoder u_d0 (.bin_data(a_dbg_wr_cnt[3:0]),   .seg_data(s0));

    seg_scan #(.SCAN_FREQ(200), .CLK_FREQ(50_000_000)) u_seg (
        .clk(clk), .rst_n(sys_rst_n),
        .seg_sel(seg_sel), .seg_data(seg_data),
        .seg_data_0({1'b1, s0}),       // 最高位是小数点，1 = 灭
        .seg_data_1({1'b1, s1}),
        .seg_data_2({1'b1, s2}),
        .seg_data_3({1'b1, s3}),
        .seg_data_4({1'b1, s4}),
        .seg_data_5({1'b1, s5})
    );

endmodule











