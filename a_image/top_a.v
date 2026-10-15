         //==========================================================================
        //  top_a —— A 轨集成模块（交付给集成顶层用）
        //==========================================================================
        //
        //  层次：
        //      top_a
        //        ├─ 图像链：bmp_analyze ─────────────────→ bmp2sdram → 写口
        //        ├─ 音频链：wav_analyze ─────────────→ wav2sdram  → 写口
        //        ├─ 字幕链：sub_analyze ── mask 字流 ─→ sub2sdram  → 写口
        //        └─ desc_tx   组装描述符 → 描述符口（只有图像用）
        //
        //  ★★ 2026-10-11：去掉了 bmp_scale —— 图像【不缩放】，源图直接进槽
        //      好处：省字空间 / 装图更快 / 显示 1:1 更清晰 /
        //            彻底避开"放大填不满"那个坑
        //      代价：图必须 ≤ 大槽容量（930,830 字 = 1,861,660 像素）
        //            超了会 fail 且【不写】（有 size_bad 保护，不会写坏隔壁）
        //
        //  ★ 本模块【不含 sdr_arb】—— 写口是 9/28 第四版定稿那套（一段式）：
        //      举 a_wr_base + a_wr_len + a_wr_req → 等 a_wr_ack（一拍）
        //        → 推 a_wr_data + a_wr_we（满了看 a_wr_full）→ 等 a_wr_done（一拍）
        //    sdr_arb 和 SDRAM 本体都归集成顶层。
        //
        //  ★★★ 三条链的【三处竞争】，全部用同一个 sd_mode[1:0] 解决
        //
        //      sd_mode = 0 → 装图     1 → 装音频     2 → 装字幕
        //
        //    ┌── ① SD 卡引脚 ───────────────────────────────────────────┐
        //    │ ★★★ 2026-10-15【第②步·减重】已改：sd_top 全局【只有一份】│
        //    │   原来三条链各带一套 find_bmp→sd_top→my_spi，靠三行 mux   │
        //    │   抢引脚（≈2.9k LUT 就这么来的）。现在：                 │
        //    │     · 引脚直连那唯一一份 sd_top，不用 mux；              │
        //    │     · 请求按 sd_mode_r 三选一进前端；                     │
        //    │     · 应答广播，但 find_bmp 里用 fe_owner 屏蔽 ——        │
        //    │       非主链连"前端忙"都看不见。                         │
        //    └──────────────────────────────────────────────────────────┘
        //
        //    ┌── ② SDRAM 写口 ──────────────────────────────────────────┐
        //    │ bmp2sdram / wav2sdram / sub2sdram 都在驱动 ✗            │
        //    │ ⇒ a_wr_req/base/len/data/we 【三选一】                   │
        //    │   a_wr_ack / a_wr_full / a_wr_done 广播                  │
        //    │   （没启动那两个在 IDLE，不会误动作）                     │
        //    └──────────────────────────────────────────────────────────┘
        //
        //    ┌── ③ 三条链的【文件索引】── 靠扩展名天然隔离 ─────────────┐
        //    │ 图像链找 "BMP" / 音频链找 "WAV" / 字幕链找 "SUB"          │
        //    │ find_bmp 的 skip 是在【自己匹配到的文件】里数第几个，所以：│
        //    │   · 加一条字幕【不会】让任何一张图的 skip 变号             │
        //    │   · 图 16 张、音频 16 条、字幕 16 条，各算各的             │
        //    │     （4 位 skip 的限制【不共享】）                        │
        //    │   · 就算 skip 写错，BMP 也永远不会被字幕链捞到（硬过滤）   │
        //    └──────────────────────────────────────────────────────────┘
        //
        //      ★★ sd_mode 在 start 那一刻【锁存】，整次传输期间不变 ——
        //         中途换 = 引脚和写口同时易主，几条链都会读到垃圾，而且都不报错 ✗
        //
        //  ★★ 现在只有一套尺寸（没有缩放）：
        //      img_width / img_height  =  源图尺寸 = 存进 SDRAM 的尺寸
        //    · frame_words 用 img_width*img_height/2
        //    · desc_tx 也用 img_width / img_height
        //
        //  ★★ 越界保护（size_bad）：
        //      大槽只有 SLOT_WORDS(930830) 个字。图太大 → frame_words=0（不写）
        //      并让 fail 亮。用 img_valid 门控 —— 上电时 img_valid=0，
        //      size_bad 也是 0，fail 不会误亮。
        //
        //  使用流程：
        //   1) 等 sd_ready 变 1
        //   2) 摆好 sd_mode，以及对应那一边的命令：
        //        装图  ：skip / use_slot / slot_base / img_no
        //        装音频：skip / sfx_base
        //        装字幕：skip / sub_base
        //   3) 给 start 一个单拍脉冲
        //   4) 装图   → 等 load_done，再等 desc_done
        //      装音频 → 等 wav_done
        //      装字幕 → 等 sub_done
        //   5) 中途 fail 亮了说明出错
        //==========================================================================
        module top_a #(
            parameter integer SLOT_NUM = 2,        // ★ 2 个槽（必须和 desc_rx 一致）
            // ★★★ 2026-10-15【音频溢出保护】音效区容量（字）= 契约 v9 的 120000 字（5.0 s @48 kHz，单声道 16bit）。
            //   ★ 由 top_m2 例化时用 SFX_STRIDE 传进来 ⇒ 契约常量仍然【只在顶层一处定义】。
            //   ★ 默认值只是"没人传参时也不会越界"，正式值以顶层传入的为准。
            parameter integer AUDIO_MAX_WORDS = 120000
        )(
            // ---------------- 时钟复位 ----------------
            input         sys_clk,          // 50 MHz
            input         sys_rst_n,

            // ---------------- SD 卡引脚（内部三选一后接出去）----------------
            input         spi_miso,
            output        spi_mosi,
            output        spi_clk,
            output        spi_cs,

            // ---------------- 命令 ----------------
            input         start,            // 单拍：开始装一张图 / 一条音频 / 一条字幕
            input  [1:0]  sd_mode,          // ★★ 0 = 装图   1 = 装音频   2 = 装字幕
            input  [3:0]  skip,             // 第几个（三条链各在【自己的扩展名】里数）

            // ---- 图像专用 ----
            input  [2:0]  use_slot,         // ★ 3 位：装到第几个槽（0 ~ SLOT_NUM-1）
            input  [20:0] slot_base,        // ★ 这个槽的帧缓冲基址（字地址）
            input  [7:0]  img_no,           // 图片序号

            // ---- 音频专用 ----
            input  [20:0] sfx_base,         // ★ 这一条音效写到哪（音效区基址 + 条号×stride）

            // ---- 字幕专用 ----------------
            input  [20:0] sub_base,         // ★ 这一条字幕写到哪（字幕区基址 + 条号×1600）

            // ---------------- 状态回报 ----------------
            output        busy,             // 1 = SD 卡正忙（图 / 音频 / 字幕）
            output        load_done,        // 单拍：整帧图写进 SDRAM
            output        desc_done,        // 单拍：描述符生效（= ready_n）
            output [7:0]  ready_n,          // 和 desc_done 同拍：第几张就绪
            output        wav_done,         // ★ 单拍：这一条音频写进 SDRAM
            output        sub_done,         // ★ 单拍：这一条字幕写进 SDRAM
            output        fail,             // 出错（找不到 / 格式不对 / 丢数据 / 图太大）

            // ---------------- SDRAM 写口 → 接 sdr_arb（9/28 定稿那套）----------------
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

            // ---------------- 诊断：图像 / 音频 ----------------
            output        sd_ready,         // 电平：SD 卡初始化完成（bmp_analyze 报的）
            output        led_init,         // 电平：引脚已交接（调试用）
            output [31:0] dbg_px_cnt,       // 已输出像素数（源图的），正常 == W*H
            output [15:0] dbg_first_px,     // 第一个像素的 RGB565
            output [31:0] dbg_wr_cnt,       // 图写了多少字，正常 == W*H/2
            output [31:0] dbg_first_addr,   // 第一个像素的地址（源图的），期望 (H-1)*W
            output [31:0] dbg_wav_cnt,      // ★ 音频写了多少字
            output        dbg_overrun,      // 不能亮
            output        dbg_warn_odd,     // 不能亮
            output        dbg_scaled,       // ★ 已去掉缩放 → 现在恒 0
            output        dbg_wav_odd,      // ★ 音频采样数为奇数（最后一个采样落单）

            // ---------------- 诊断：字幕 ----------------
            output [31:0] dbg_sub_wr_cnt,   // 字幕写了多少字，正常 == 1600
            output        dbg_sub_overrun,  // 字幕丢字，不能亮
            output        dbg_sub_short     // 字幕字数对不上，不能亮
        );

            //======================================================================
            //  ★ 声明全部前置（这个工程踩过五次"先用后声明"）
            //======================================================================
            // ---- 常量 ----
            localparam [20:0] SUB_WORDS  = 21'd1600;      // 一条字幕 1600 字（契约）
            localparam [20:0] SLOT_WORDS = 21'd930830;    // ★ 大槽容量（越界保护用）

            // ---- 图像链 ----
            wire        px_we;
            wire [31:0] px_addr;
            wire [15:0] px_data;
            wire        bmp_done, bmp_fail, bmp_busy;
            wire [15:0] img_width, img_height;
            wire        img_valid;
            // ★ bmp_scale 已去掉 —— 源图直接进槽，不缩放

            // ---- 音频链 ----
            wire        wav_busy, wav_an_done, wav_an_fail;
            wire [15:0] smp_data;
            wire        smp_we;
            wire [31:0] smp_idx, smp_cnt;
            wire        wav_wr_busy, wav_wr_done_p;

            // ---- 字幕链 ----
            wire        sub_busy, sub_an_done, sub_an_fail;
            wire [31:0] sub_mask_data;
            wire        sub_mask_we;
            wire [31:0] sub_mask_idx;
            wire [15:0] sub_w, sub_h;
            wire        sub_info_valid;
            wire        sub2sdram_busy, sub_wr_done_p;

            // ---- ★★★ 第②步：共享 SD 前端（三条链共用本文件里唯一那份 sd_top）----
            //   每条链一组请求出口 + 一组广播回来的应答/状态
            wire [31:0] fe_lba_bmp, fe_lba_wav, fe_lba_sub;
            wire        fe_req_bmp, fe_req_wav, fe_req_sub;
            wire [31:0] fe_lba;          // 按 sd_mode_r 三选一 → sd_top.read_addr
            wire        fe_req;          // 按 sd_mode_r 三选一 → sd_top.read_req
            wire [7:0]  fe_data;         // ← sd_top.data_out（广播给三条链）
            wire        fe_ok, fe_done, fe_busy, fe_err;
            wire        fe_init_done;    // ← sd_top.bus_owner
            wire        fe_led;          // ← sd_top.led1

            // ---- 图像写口 ----
            wire        bm_req, bm_we;
            wire [20:0] bm_base, bm_len;
            wire [31:0] bm_data;

            // ---- 音频写口 ----
            wire        wv_req, wv_we;
            wire [20:0] wv_base, wv_len;
            wire [31:0] wv_data;

            // ---- 字幕写口 ----
            wire        sb_req, sb_we;
            wire [20:0] sb_base, sb_len;
            wire [31:0] sb_data;

            // ---- 状态汇总 ----
            wire        frame_done;
            wire        bmp2sdram_busy;
            wire        desc_busy;
            wire        wav2sdram_busy;

            // ---- 锁存寄存器 ----
            reg [20:0] base_r;          // 图像：槽基址
            reg [20:0] sub_base_r;      // ★ 字幕：写着走的那条字幕的基址
            reg [1:0]  sd_mode_r;       // ★ 三选一的模式

            //======================================================================
            //  ★★★ SD 卡引脚 / SDRAM 写口 的【三选一】（sd_mode_r）
            //  在 start 那一刻锁存；busy 期间锁死不采 ——
            //  一次读卡几百万拍，中途换引脚 = 几条链都读到垃圾，且都不报错 ✗
            //======================================================================
            wire sd_busy = bmp_busy | wav_busy | sub_busy;

            always @(posedge sys_clk or negedge sys_rst_n) begin
                if (!sys_rst_n)             sd_mode_r <= 2'd0;
                else if (start && !sd_busy) sd_mode_r <= sd_mode;   // ★ 忙时不采
            end

            wire mode_is_bmp = (sd_mode_r == 2'd0);
            wire mode_is_wav = (sd_mode_r == 2'd1);
            wire mode_is_sub = (sd_mode_r == 2'd2);

            // ---- ② SDRAM 写口：三选一（ack/full/done 广播给三个）----
            assign a_wr_req  = mode_is_sub ? sb_req  : (mode_is_wav ? wv_req  : bm_req);
            assign a_wr_base = mode_is_sub ? sb_base : (mode_is_wav ? wv_base : bm_base);
            assign a_wr_len  = mode_is_sub ? sb_len  : (mode_is_wav ? wv_len  : bm_len);
            assign a_wr_data = mode_is_sub ? sb_data : (mode_is_wav ? wv_data : bm_data);
            assign a_wr_we   = mode_is_sub ? sb_we   : (mode_is_wav ? wv_we   : bm_we);

            // ---- ① SD 卡引脚：★ 不再需要"三选一 mux"（前端只有一份）----
            //   ★★★ 2026-10-15【第②步 · 减重】：原来三条链各带一份
            //     find_bmp→sd_top(含 sd_init/sd_read_cdc/sd_read/my_spi)，三份逐字相同，
            //     只靠三行 mux 抢引脚 —— 那正是"三份 SD 前端 ≈2.9k LUT"的来源。
            //   现在把 sd_top 提出成【只例化一份】`u_sd_front`，三条链的 find_bmp 共享它：
            //     · 请求：按 `sd_mode_r` 三选一 ⇒ 只有当家那条链的请求能到前端；
            //     · 应答/状态：广播给三条，但 find_bmp 内部用 fe_owner 屏蔽 ——
            //       非主链连"前端忙"都看不见，绝不会把主链的字节当成自己的。
            //   ★ 为什么"不会在事务中途换主"（红线）：
            //     ① `sd_mode_r` 的锁存条件一个字没改 = `start && !sd_busy`，
            //        而 sd_busy = bmp_busy|wav_busy|sub_busy 覆盖三条链【整段】SD 活动
            //        ⇒ 换主只可能发生在"上一条链已 done/fail、三条链 busy 全 0"之后；
            //     ② 新主自己还要先在 find_bmp 的 S_WAIT 等 `!sd_busy`（= 前端电平）
            //        才敢举 fe_req ⇒ 就算前端刚巧还在收尾上一条的最后一块，也等它落下来。
            assign fe_lba = mode_is_sub ? fe_lba_sub :
                            mode_is_wav ? fe_lba_wav : fe_lba_bmp;
            assign fe_req = mode_is_sub ? fe_req_sub :
                            mode_is_wav ? fe_req_wav : fe_req_bmp;

            sd_top u_sd_front (
                .sys_clk   (sys_clk),
                .clk_spi   (sys_clk),        // ★ 与改动前逐位相同：三条链原来都接 sys_clk（SCLK 12.5 MHz）
                .sys_rst_n (sys_rst_n),

                .spi_miso  (spi_miso),
                .spi_mosi  (spi_mosi),
                .spi_clk   (spi_clk),
                .spi_cs    (spi_cs),

                .read_addr (fe_lba),
                .read_req  (fe_req),
                .data_out  (fe_data),
                .read_busy (fe_busy),
                .read_ok   (fe_ok),
                .read_done (fe_done),
                .read_err  (fe_err),

                .led1      (fe_led),
                .bus_owner (fe_init_done)
            );

            // ---- start 分发给谁（★ 用组合的 sd_mode，不是寄存过的）----
            wire bmp_start = start & (sd_mode == 2'd0);
            wire wav_start = start & (sd_mode == 2'd1);
            wire sub_start = start & (sd_mode == 2'd2);

            //======================================================================
            //  ★★★ 尺寸 / 长度
            //======================================================================
            // ★ 图不缩放了：用【源图】尺寸，字 = W*H/2（向下取整）
            //   ★ 显式扩到 32 位，不依赖"上下文位宽"规则（不同工具实现有别）
            wire [31:0] frame_w32 = ({16'd0, img_width} * {16'd0, img_height}) >> 1;

            // ★★ 越界保护：只判"图太大"，不判"还没解析"
            //    上电时 img_valid=0 → size_bad=0 → fail 不会误亮 ✓
            //    太大了就 frame_words=0（不写）并让 fail 亮，绝不写坏隔壁区域
            wire        size_bad    = img_valid && (frame_w32 > {11'd0, SLOT_WORDS});
            wire [20:0] frame_words = size_bad ? 21'd0 : frame_w32[20:0];

            // 这一条多少个字（音频）：★ 向下取整 ——
            //  用 (smp_cnt+1)>>1 会让奇数采样时多算 1，推不够 → 卡死 ✗
            // ★★★ 2026-10-15【音频溢出保护 · 装载侧】两层夹子，缺一不可：
            //   ① 长度夹到音效区容量（= AUDIO_MAX_WORDS 字）—— 这一条就是发给写引擎的 sdr_len；
            //   ② 采样流也拦：只放行【前 2×AUDIO_MAX_WORDS 个采样】（= 前 120000 个字），
            //      编号更大的采样根本不进 wav2sdram。
            //   ★ 为什么必须连采样流一起拦（只夹长度会卡死）：
            //     `wav2sdram` 是"推满 sdr_len 个字 → 等引擎收尾"的套路。只夹长度、采样还在流，
            //     它推满后会回到 S_IDLE **再开一趟**请求，而这一趟的采样已经不够
            //     ⇒ 永远等不到 sdr_done ⇒ A 链 busy 卡死（顺带把"等 A 空闲"的字幕那条也堵死）。
            //     拦掉多余采样后，超长文件在 wav2sdram 眼里**和一条正好 5.0 s 的文件逐位等价**：
            //     A 链状态机照旧走完，只是少写后面的字（`smp_done` / `done` 的时序一个字没动）。
            //   ★ ≤5 s 的文件：smp_cnt>>1 ≤ 上限、且 smp_idx < 2×上限 ⇒ 两个夹子都不生效 ⇒ 逐位不变。
            localparam [20:0] AUD_MAX_W   = AUDIO_MAX_WORDS;              // 21 位对齐（与 sfx_words 同宽）
            localparam [31:0] AUD_SMP_CAP = {11'd0, AUD_MAX_W} << 1;      // 采样数上限 = 2×字数 = 240000
            // ★ 夹取在【32 位】里比：先整体 >>1、再用 32 位和上限比，避开 `smp_cnt[20:1]` 的截断
            //   （原写法只取 20 位，几十分钟级的超长文件 smp_cnt 一溢出就"夹不上"了）。
            //   ⇒ sfx_words = min(实际字数, 上限)：＞5 s 的文件恒等于 120000。
            wire [31:0] sfx_pairs32 = smp_cnt >> 1;                       // 实际字数（32 位，先不截断）
            wire [20:0] sfx_words   = (sfx_pairs32 > {11'd0, AUD_MAX_W}) ? AUD_MAX_W : sfx_pairs32[20:0];
            // ★ 不变量：发给引擎的长度 == 真正放行的采样对数（超长时都是 120000）
            //   ⇒ wav2sdram 眼里超长文件和"正好 5.0 s 的文件"完全一样，不存在"请求了却喂不满"的卡死。
            wire        sfx_smp_we  = smp_we & (smp_idx < AUD_SMP_CAP);   // ★ 超出的采样：丢掉，不写

            //======================================================================
            //  状态汇总
            //======================================================================
            assign busy      = bmp_busy | bmp2sdram_busy | desc_busy
                             | wav_busy | wav2sdram_busy
                             | sub_busy | sub2sdram_busy;
            assign load_done = frame_done;
            assign wav_done  = wav_wr_done_p;
            assign sub_done  = sub_wr_done_p;
            assign fail      = bmp_fail | dbg_overrun | size_bad | wav_an_fail
                             | sub_an_fail | dbg_sub_overrun | dbg_sub_short;
            assign dbg_scaled= 1'b0;      // ★ 不再缩放（端口保留，队友不用改接线）

            //======================================================================
            //  ★★★ 基址锁存（都要在 start 那一刻锁，不能直接用组合值）
            //======================================================================
            always @(posedge sys_clk or negedge sys_rst_n) begin
                if (!sys_rst_n) base_r <= 21'd0;
                else if (bmp_start) base_r <= slot_base;
            end

            always @(posedge sys_clk or negedge sys_rst_n) begin
                if (!sys_rst_n)      sub_base_r <= 21'd0;
                else if (sub_start)  sub_base_r <= sub_base;
            end

            //======================================================================
            //  图像链
            //======================================================================
            bmp_analyze u_bmp_analyze (
                .sys_clk    (sys_clk),
                .sys_rst_n  (sys_rst_n),

                // ---- ★★★ 第②步：共享 SD 前端（真正的 sd_top 见上面 u_sd_front）----
                .fe_init_done (fe_init_done),
                .fe_led       (fe_led),
                .fe_owner     (mode_is_bmp),     // ★ 只有"装图"这一条当家
                .fe_lba       (fe_lba_bmp),
                .fe_req       (fe_req_bmp),
                .fe_data      (fe_data),
                .fe_ok        (fe_ok),
                .fe_done      (fe_done),
                .fe_busy      (fe_busy),
                .fe_err       (fe_err),
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

            // ★★ bmp_scale 已删除 —— bmp_analyze 的像素流【直连】bmp2sdram

            bmp2sdram u_bmp2sdram (
                .sys_clk      (sys_clk),
                .sys_rst_n    (sys_rst_n),
                .frame_base   (base_r),
                .frame_words  (frame_words),     // ★ 源图尺寸算出来的（含越界保护）
                .px_we        (px_we),           // ★ 直连 bmp_analyze
                .px_addr      (px_addr),         // ★
                .px_data      (px_data),         // ★
                .img_done     (bmp_done),        // ★
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
                .img_width    (img_width),       // ★ 源图尺寸（不再缩放）
                .img_height   (img_height),      // ★
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
                .sys_rst_n    (sys_rst_n),

                // ---- ★★★ 第②步：共享 SD 前端 ----
                .fe_init_done (fe_init_done),
                .fe_led       (fe_led),
                .fe_owner     (mode_is_wav),     // ★ 只有"装音频"这一条当家
                .fe_lba       (fe_lba_wav),
                .fe_req       (fe_req_wav),
                .fe_data      (fe_data),
                .fe_ok        (fe_ok),
                .fe_done      (fe_done),
                .fe_busy      (fe_busy),
                .fe_err       (fe_err),

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

                .smp_we       (sfx_smp_we),      // ★ 溢出保护：只放行前 120000 个字的采样
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

            //======================================================================
            //  ★★★ 字幕链
            //    sub_analyze：SD 里的 .SUB（内容其实是 24 位 BMP）
            //                 → 1bpp 遮罩字（1600 个，每个 32 像素）
            //    sub2sdram  ：1600 个字写进 SDRAM 字幕区
            //  ★ 扩展名 "SUB" 是和图片链隔离的关键（见文件头 ③）
            //======================================================================
            sub_analyze #(
                .TARGET_EXT ({"S","U","B"}),     // ★★ 独立扩展名
                .REQ_W      (800),               // 契约：必须正好 800x64
                .REQ_H      (64)
            ) u_sub_analyze (
                .sys_clk        (sys_clk),
                .sys_rst_n      (sys_rst_n),

                // ---- ★★★ 第②步：共享 SD 前端 ----
                .fe_init_done   (fe_init_done),
                .fe_led         (fe_led),
                .fe_owner       (mode_is_sub),   // ★ 只有"装字幕"这一条当家
                .fe_lba         (fe_lba_sub),
                .fe_req         (fe_req_sub),
                .fe_data        (fe_data),
                .fe_ok          (fe_ok),
                .fe_done        (fe_done),
                .fe_busy        (fe_busy),
                .fe_err         (fe_err),

                .start          (sub_start),     // ★ 只在装字幕那一拍给
                .skip           (skip),          // ★ 在 .SUB 里数第几个

                .busy           (sub_busy),
                .done           (sub_an_done),
                .fail           (sub_an_fail),

                .sub_width      (sub_w),
                .sub_height     (sub_h),
                .info_valid     (sub_info_valid),

                .mask_data      (sub_mask_data),
                .mask_we        (sub_mask_we),
                .mask_idx       (sub_mask_idx),

                .led_init       (),
                .sd_ready       (),

                .dbg_data_off   (),
                .dbg_first_word (),
                .dbg_rd_sec     (),
                .dbg_word_cnt   (),
                .dbg_px_cnt     ()
            );

            sub2sdram u_sub2sdram (
                .sys_clk      (sys_clk),
                .sys_rst_n    (sys_rst_n),

                .sub_base     (sub_base_r),      // ★ 锁存过的
                .sub_words    (SUB_WORDS),       // 1600

                .mask_we      (sub_mask_we),
                .mask_data    (sub_mask_data),
                .mask_idx     (sub_mask_idx),
                .mask_done    (sub_an_done),

                .sdr_req      (sb_req),
                .sdr_base     (sb_base),
                .sdr_len      (sb_len),
                .sdr_ack      (a_wr_ack),        // ★ 广播
                .sdr_data     (sb_data),
                .sdr_we       (sb_we),
                .a_wr_full    (a_wr_full),       // ★ 广播
                .sdr_done     (a_wr_done),       // ★ 广播
                .sdr_ready    (sdr_ready),

                .sub_wr_done  (sub_wr_done_p),
                .busy         (sub2sdram_busy),

                .wr_cnt       (dbg_sub_wr_cnt),  // 正常 == 1600
                .warn_overrun (dbg_sub_overrun), // 不能亮
                .warn_short   (dbg_sub_short)    // 不能亮
            );

        endmodule