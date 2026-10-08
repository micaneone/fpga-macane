  //==========================================================================
    //  top_a —— A 轨集成模块（交付给集成顶层用）
    //==========================================================================
    //
    //  层次：
    //      top_a
    //        ├─ 图像链：bmp_analyze → bmp_scale → bmp2sdram → 写口
    //        ├─ 音频链：wav_analyze ─────────────→ wav2sdram  → 写口
    //        └─ desc_tx   组装描述符 → 描述符口（只有图像用）
    //
    //  ★ 本模块【不含 sdr_arb】—— 全项目只能例化一次 SDRAM，
    //    它归集成顶层，由顶层把写口接进来
    //
    //  ★★★ 两条链有两处竞争，都用同一个 sd_to_wav 解决：
    //
    //      ① SD 卡引脚：两个模块各自带一套 find_bmp→sd_top→my_spi ✗
    //         所以 spi_clk / spi_mosi / spi_cs 必须【二选一】
    //         （spi_miso 是输入，广播给两个，不冲突）
    //
    //      ② SDRAM 写口：bmp2sdram 和 wav2sdram 都在驱动 ✗
    //         所以 a_wr_req/base/len/data/we 必须【二选一】
    //         （a_wr_ack / a_wr_full / a_wr_done 广播给两个，没启动那个在 IDLE 不动它）
    //
    //      ★★ sd_to_wav 在 start 那一刻【锁存】，整次传输期间不变 ——
    //         中途换 = 引脚和写口同时易主，两条链都会读到垃圾，而且都不报错 ✗
    //
    //  ★★★ 一个切换信号管两条链的启动：
    //         sd_to_wav = 0 → 只有 bmp_start 有脉冲，引脚和写口都给图像
    //         sd_to_wav = 1 → 只有 wav_start 有脉冲，引脚和写口都给音频
    //
    //  ★ 两个尺寸别搞混（接了 bmp_scale 之后最容易踩）：
    //      img_width/img_height = 【源图】尺寸（bmp_analyze 给）
    //      st_w/st_h            = 【存进 SDRAM 的】尺寸（bmp_scale 给）
    //    · frame_words 必须用 st_w*st_h  · desc_tx 也必须用 st_w/st_h
    //
    //  ★ 写口协议（原厂 frame_fifo_write 那套）：
    //      举 base + len + req  →  等 ack  →  推字（满了看 a_wr_full）→  等 done
    //
    //  使用流程：
    //   1) 等 sd_ready 变 1
    //   2) 摆好 sd_to_wav，以及对应那一边的命令：
    //        装图：skip / use_slot / slot_base / img_no
    //        装音频：skip / sfx_base
    //   3) 给 start 一个单拍脉冲
    //   4) 装图 → 等 load_done，再等 desc_done
    //      装音频 → 等 wav_done
    //   5) 中途 fail 亮了说明出错
    //==========================================================================
    module top_a #(
        parameter integer SLOT_NUM = 2         // ★ 2 个槽（必须和 desc_rx 一致）
    )(
        // ---------------- 时钟复位 ----------------
        input         sys_clk,          // 50 MHz
        // ★★ 2026-10-08【集成临时改动 · 提速到 25 MHz】：SD 读移位器用的时钟。
        //   顶层给 PLL_0 的 clk_par = 100 MHz ⇒ SCLK = 100/4 = 25 MHz（原来 12.5 MHz）。
        //   ★ 只给【图像链】用；音频链仍接 sys_clk（行为不变）。
        input         clk_spi,          // 100 MHz
        input         sys_rst_n,

        // ---------------- SD 卡引脚（内部二选一后接出去）----------------
        input         spi_miso,
        output        spi_mosi,
        output        spi_clk,
        output        spi_cs,

        // ---------------- 命令 ----------------
        input         start,            // 单拍：开始装一张图 / 一条音频
        input         sd_to_wav,        // ★ 0 = 这次装图，1 = 这次装音频
        input  [3:0]  skip,             // 第几个（图/音频共用，看 sd_to_wav）

        // ---- 图像专用 ----
        input  [2:0]  use_slot,         // ★ 3 位：装到第几个槽（0 ~ SLOT_NUM-1）
        input  [20:0] slot_base,        // ★ 这个槽的帧缓冲基址（字地址）
        input  [7:0]  img_no,           // 图片序号

        // ---- 音频专用 ----
        input  [20:0] sfx_base,         // ★ 这一条音效写到哪（音效区基址 + 条号×stride）

        // ---------------- 状态回报 ----------------
        output        busy,             // 1 = SD 卡正忙（图或音频）
        output        load_done,        // 单拍：整帧图写进 SDRAM
        output        desc_done,        // 单拍：描述符生效（= ready_n）
        output [7:0]  ready_n,          // 和 desc_done 同拍：第几张就绪
        output        wav_done,         // ★ 单拍：这一条音频写进 SDRAM
        output        fail,             // 出错（找不到 / 格式不对 / 丢数据）
        output        sd_ready,         // 电平：SD 卡初始化完成
        output        led_init,         // 电平：引脚已交接（调试用）

        // ---------------- SDRAM 写口 → 接 sdr_arb ----------------
        output        a_wr_req,         // 写请求：举着，直到 a_wr_ack
        output [20:0] a_wr_base,        // 这一段从哪个字地址开始
        output [20:0] a_wr_len,         // 这一段多少个字
        input         a_wr_ack,         // 一拍：受理了
        output [31:0] a_wr_data,
        output        a_wr_we,
        input         a_wr_full,
        input         a_wr_done,        // 一拍：这一段写进 SDRAM 了
        input         sdr_ready,        // SDRAM 初始化完成（sdr_arb 给的）

        // ---------------- 描述符口 → 接 desc_rx ----------------
        output [SLOT_NUM*64-1:0] a_desc,
        output        a_commit_tgl,
        input         a_ack_tgl,

        // ---------------- 诊断 ----------------
        output [31:0] dbg_px_cnt,       // 已输出像素数（源图的），正常 == W*H
        output [15:0] dbg_first_px,     // 第一个像素的 RGB565
        output [31:0] dbg_wr_cnt,       // 图写了多少字，正常 == st_w*st_h/2
        output [31:0] dbg_first_addr,   // 第一个像素的地址（源图的），期望 (H-1)*W
        output [31:0] dbg_wav_cnt,      // ★ 音频写了多少字
        output        dbg_overrun,      // 不能亮
        output        dbg_warn_odd,     // 不能亮
        output        dbg_scaled,       // 1 = 这一帧缩过
        output        dbg_wav_odd       // ★ 音频采样数为奇数（最后一个采样落单）
    );

        //======================================================================
        //  图像链的连线
        //======================================================================
        wire        px_we;
        wire [31:0] px_addr;
        wire [15:0] px_data;
        wire        bmp_done, bmp_fail, bmp_busy;
        wire [15:0] img_width, img_height;
        wire        img_valid;

        wire        sc_we, sc_done;
        wire [31:0] sc_addr;
        wire [15:0] sc_px;
        wire [15:0] st_w, st_h;
        wire        sc_busy, sc_err;

        //======================================================================
        //  音频链的连线
        //======================================================================
        wire        wav_busy, wav_an_done, wav_an_fail;
        wire [15:0] smp_data;
        wire        smp_we;
        wire [31:0] smp_idx, smp_cnt;
        wire        wav_wr_busy, wav_wr_done_p;

        //======================================================================
        //  ★★★ SD 卡引脚 / 写口 的二选一（sd_to_wav_r）
        //  在 start 那一刻锁存；busy 期间锁死不采 ——
        //  一次读卡几百万拍，中途换引脚 = 两条链都读到垃圾，且都不报错 ✗
        //======================================================================
        wire sd_busy = bmp_busy | wav_busy;

        reg  sd_to_wav_r;
        always @(posedge sys_clk or negedge sys_rst_n) begin
            if (!sys_rst_n)             sd_to_wav_r <= 1'b0;
            else if (start && !sd_busy) sd_to_wav_r <= sd_to_wav;   // ★ 忙时不采
        end

        // ---- ① SPI 三根输出：二选一 ----
        wire bmp_mosi, bmp_clk, bmp_cs;
        wire wav_mosi, wav_clk, wav_cs;
            // ---- 图像写口（先用内部信号，最后二选一接到引脚上）----
        wire        bm_req, bm_we;
        wire [20:0] bm_base, bm_len;
        wire [31:0] bm_data;

        // ---- 音频写口 ----
        wire        wv_req, wv_we;
        wire [20:0] wv_base, wv_len;
        wire [31:0] wv_data;
        
        
        //======================================================================
        //  ★★★ ② SDRAM 写口：二选一
        //  ★ addr/data/we/req 跟着 sd_to_wav_r 走；
        //    ack/full/done 广播（没启动那个在 IDLE，不会误动作）
        //======================================================================
        assign a_wr_req  = sd_to_wav_r ? wv_req  : bm_req;
        assign a_wr_base = sd_to_wav_r ? wv_base : bm_base;
        assign a_wr_len  = sd_to_wav_r ? wv_len  : bm_len;
        assign a_wr_data = sd_to_wav_r ? wv_data : bm_data;
        assign a_wr_we   = sd_to_wav_r ? wv_we   : bm_we;


        assign spi_mosi = sd_to_wav_r ? wav_mosi : bmp_mosi;
        assign spi_clk  = sd_to_wav_r ? wav_clk  : bmp_clk;
        assign spi_cs   = sd_to_wav_r ? wav_cs   : bmp_cs;
        // ★ spi_miso 是【输入】，不用 mux —— 广播给两个

        // ---- start 分发给谁 ----
      wire bmp_start = start & ~sd_to_wav;   // ★ 用组合的 sd_to_wav，不是寄存过的
      wire wav_start = start &  sd_to_wav;

        //======================================================================
        //  ★★★ 尺寸 / 长度
        //======================================================================
        // 这一帧一共多少个字（图像）：必须用【缩放后】的尺寸
        wire [31:0] frame_px    = st_w * st_h;
        wire [20:0] frame_words = frame_px >> 1;

        // 这一条多少个字（音频）：★ 向下取整 ——
        //  用 (smp_cnt+1)>>1 会让奇数采样时多算 1，推不够 → 卡死 ✗
        wire [20:0] sfx_words = smp_cnt[20:1];

        //======================================================================
        //  状态汇总
        //======================================================================
        wire        frame_done;
        wire        bmp2sdram_busy;
        wire        desc_busy;
        wire        wav2sdram_busy;

        assign busy      = bmp_busy | sc_busy | bmp2sdram_busy | desc_busy
                         | wav_busy | wav2sdram_busy;
        assign load_done = frame_done;
        assign wav_done  = wav_wr_done_p;
        assign fail      = bmp_fail | dbg_overrun | sc_err | wav_an_fail;
        assign dbg_scaled= (st_w != img_width) | (st_h != img_height);

        //======================================================================
        //  ★★★ 槽基址锁存（图像）
        //======================================================================
        reg [20:0] base_r;

        always @(posedge sys_clk or negedge sys_rst_n) begin
            if (!sys_rst_n) base_r <= 21'd0;
            else if (bmp_start) base_r <= slot_base;
        end

        //======================================================================
        //  图像链
        //======================================================================
        bmp_analyze u_bmp_analyze (
            .sys_clk    (sys_clk),
            .clk_spi    (clk_spi),           // ★ 集成临时改动：图像链 SD 读到 25 MHz
            .sys_rst_n  (sys_rst_n),
            .spi_miso   (spi_miso),          // ★ 广播（输入）
            .spi_mosi   (bmp_mosi),          // ★ 不直接接引脚
            .spi_clk    (bmp_clk),
            .spi_cs     (bmp_cs),
            .start      (bmp_start),         // ★ 只在装图那一拍给
            .skip       (skip),
            .busy       (bmp_busy),
            .done       (bmp_done),
            .fail       (bmp_fail),
            .img_width  (img_width),
            .img_height (img_height),
            .img_valid  (img_valid),
            .px_data    (px_data),
            .px_we      (px_we),
            .px_addr    (px_addr),
            .led_init   (led_init),
            .sd_ready   (sd_ready),
            .dbg_px_cnt     (dbg_px_cnt),
            .dbg_data_off   (),
            .dbg_first_px   (dbg_first_px),
            .dbg_first_addr (dbg_first_addr)
        );

        bmp_scale u_bmp_scale (
            .clk        (sys_clk),
            .rst_n      (sys_rst_n),
            .start      (bmp_start),
            .src_w      (img_width),
            .src_h      (img_height),
            .src_we     (px_we),
            .src_addr   (px_addr),
            .src_px     (px_data),
            .src_done   (bmp_done),
            .out_we     (sc_we),
            .out_addr   (sc_addr),
            .out_px     (sc_px),
            .out_done   (sc_done),
            .out_w      (st_w),
            .out_h      (st_h),
            .scaled     (),
            .err_overrun(sc_err),
            .busy       (sc_busy)
        );


        bmp2sdram u_bmp2sdram (
            .sys_clk      (sys_clk),
            .sys_rst_n    (sys_rst_n),
            .frame_base   (base_r),
            .frame_words  (frame_words),
            .px_we        (sc_we),
            .px_addr      (sc_addr),
            .px_data      (sc_px),
            .img_done     (sc_done),
            .sdr_req      (bm_req),
            .sdr_base     (bm_base),
            .sdr_len      (bm_len),
            .sdr_ack      (a_wr_ack),        // ★ 广播
            .sdr_data     (bm_data),
            .sdr_we       (bm_we),
            .a_wr_full    (a_wr_full),       // ★ 广播
            .sdr_done     (a_wr_done),       // ★ 广播
            .sdr_ready    (sdr_ready),
            .frame_done   (frame_done),
            .busy         (bmp2sdram_busy),
            .wr_cnt       (dbg_wr_cnt),
            .warn_overrun (dbg_overrun),
            .warn_odd     (dbg_warn_odd)
        );

        desc_tx #(
            .SLOT_NUM (SLOT_NUM)
        ) u_desc_tx (
            .clk_ctl      (sys_clk),
            .rst_ctl_n    (sys_rst_n),
            .frame_done   (frame_done),
            .img_width    (st_w),            // ★ 存储尺寸
            .img_height   (st_h),            // ★
            .img_no       (img_no),
            .use_slot     (use_slot),
            .slot_base    (base_r),
            .a_desc       (a_desc),
            .a_commit_tgl (a_commit_tgl),
            .a_ack_tgl    (a_ack_tgl),
            .busy         (desc_busy),
            .ready_pulse  (desc_done),
            .ready_n      (ready_n)
        );

        //======================================================================
        //  音频链
        //======================================================================
        wav_analyze #(
            .TARGET_EXT ({"W","A","V"})
        ) u_wav_analyze (
            .sys_clk      (sys_clk),
            .clk_spi      (sys_clk),         // ★ 音频链暂不提速（= 原来的行为）
            .sys_rst_n    (sys_rst_n),

            .spi_miso     (spi_miso),        // ★ 广播（输入）
            .spi_mosi     (wav_mosi),        // ★ 不直接接引脚
            .spi_clk      (wav_clk),
            .spi_cs       (wav_cs),

            .start        (wav_start),       // ★ 只在装音频那一拍给
            .skip         (skip),

            .busy         (wav_busy),
            .done         (wav_an_done),
            .fail         (wav_an_fail),

            .smp_rate     (),
            .smp_ch       (),
            .smp_bits     (),
            .smp_cnt      (smp_cnt),
            .info_valid   (),

            .smp_data     (smp_data),
            .smp_we       (smp_we),
            .smp_idx      (smp_idx),

            .led_init     (),               // 引脚交接由 bmp_analyze 报
            .sd_ready     (),

            .dbg_data_off (),
            .dbg_data_len (),
            .dbg_first_smp(),
            .dbg_rd_sec   ()
        );


        wav2sdram u_wav2sdram (
            .sys_clk      (sys_clk),
            .sys_rst_n    (sys_rst_n),

            .sfx_base     (sfx_base),
            .sfx_words    (sfx_words),       // ★ 向下取整

            .smp_we       (smp_we),
            .smp_idx      (smp_idx),
            .smp_data     (smp_data),
            .smp_done     (wav_an_done),

            .sdr_req      (wv_req),
            .sdr_base     (wv_base),
            .sdr_len      (wv_len),
            .sdr_ack      (a_wr_ack),        // ★ 广播
            .sdr_data     (wv_data),
            .sdr_we       (wv_we),
            .a_wr_full    (a_wr_full),       // ★ 广播
            .sdr_done     (a_wr_done),       // ★ 广播
            .sdr_ready    (sdr_ready),

            .wav_wr_done  (wav_wr_done_p),
            .busy         (wav2sdram_busy),

            .wr_cnt       (dbg_wav_cnt),
            .warn_overrun (),
            .warn_odd     (dbg_wav_odd)
        );



    endmodule
