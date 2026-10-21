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
            parameter integer AUDIO_MAX_WORDS = 120000,
            // ★★★ 2026-10-20【找图逻辑·开关】1 = 图像链按文件名找（AD* / MAP*），
            //   0 = 只按后缀找（= 老行为）。★ 默认 0：卡里现有素材没改名，开了就找不到图。
            //   素材统一改名成 `AD*.BMP`（广告位）/ `MAP*.BMP`（插播图）之后，把它改成 1。
            parameter integer BMP_NAME_EN = 1'b0
        )(
            // ---------------- 时钟复位 ----------------
            input         sys_clk,          // 50 MHz
            // ★★★ 2026-10-17【拿回 SD 25 MHz】SD 读的移位器（`sd_read_cdc` 的 fast 侧）用这根：
            //   顶层接 100 MHz ⇒ SCLK = 100/4 = **25 MHz**（接 sys_clk 就是 12.5 MHz）。
            //   10-15 合流时这个端口被删掉、`sd_top.clk_spi` 只好接 sys_clk ⇒ 装图时间翻倍
            //   （见 `rtl\top_m2.v` 里那段自述）。实测（12.5 MHz）：A 轨 379 kpx/s = 1.14 MB/s，
            //   1.77 Mpx 的图要 4.7 s。★ 只影响**读**：`sd_init`（400 kHz 那条）一直用 sys_clk。
            input         clk_spi,
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
            // ★★★ 2026-10-20【找图逻辑·按名字分类】：0 = 找 AD 类，1 = 找 MAP 类。
            //   ★ 必须接，不能悬空（悬空 ⇒ 名字比较出 x ⇒ 永远找不到图 ⇒ 装图一直 FAIL）。
            //   ★ 三条链的 `skip` 仍然只用一根 —— 顶层本来就按 sd_mode 先三选一，
            //     拆成三根在这里是纯冗余（交付说明里那三根是给"旧底座"写的）。
            input         bmp_name_sel,
    // ★ 2026-10-21：1 = 只认 EMG*（报警态）/ 0 = 排除 EMG*（正常态）——全局名字过滤
    input         name_emg_only,

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
            output        dbg_sub_short,    // 字幕字数对不上，不能亮

            // ---------------- ★★★ 2026-10-21【D3 · C2/C3】素材格式（给兜底页讲原因用）
            //   原来这两类失败是**静默**的：44.1 kHz 的 WAV、32 位 BMP 只会让
            //   `a_fail` 亮一下，屏上只写 "BAD IMAGE"，现场还得猜。
            //   这里把"到底哪儿不对"这三根信号引出去，兜底页据此改文案。
            output [15:0] o_img_bpp,        // 最近一次 BMP 头里的位深（0 = 还没读到）
            output [31:0] o_aud_rate,       // 最近一次 WAV fmt 里的采样率
            output [15:0] o_aud_bits,       // 位深
            output        o_aud_info_valid  // 上面两个值有效
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
            // ★★★ 2026-10-17【CMD18 多块连续读】：图像链"正在读像素数据"时允许连续读多块，
            //   省掉每块一次的卡访问延迟（实测约 120 µs/块 ⇒ 装载约快 1.3x）。
            //   ★ 只有图像链用：wav/sub 的文件只有几十个扇区，且中途还会跳扇区，不值当。
            wire        sd_stream_bmp;
            wire [7:0]  fe_data;         // ← sd_top.data_out（广播给三条链）
            wire        fe_ok, fe_done, fe_busy, fe_err;
            wire        fe_init_done;    // ← sd_top.bus_owner
            wire        fe_led;          // ← sd_top.led1

            //==================================================================
            //  ★★★ 2026-10-16【切法C·find_bmp 合流】：FAT/目录索引 FSM 三合一
            //   原来三条链各带一份逐字相同的 FAT/目录/簇链状态机
            //   （只有 TARGET_EXT 和 skip 不同），现在全工程只有一份 `u_find_eng`
            //   （= find_bmp_eng，在 a_image\find_bmp.v 里）：
            //     · 请求侧：三条链各出一个 start 脉冲（top_a 已经用**组合的** sd_mode
            //       分好了 ⇒ 同一时刻最多一条链有 start）；用 sd_mode_r 选出
            //       「谁在查」= eng_sel，并把对应扩展名/地址往上送。
            //     · 结果侧：引擎的结果由 arb_result_owner 分发给对应父模块，
            //       并且**打一拍**再连同 eng_done/eng_fail 一起发出去 ——
            //       这样父模块看到的 (f_done, f_sector, f_size) 与原版同时刻关系一致。
            //   ★ 怎么保证"同一时刻只有一条链在查"（红线）：
            //     ① 引擎的 start 是 3 个脉冲的或 —— 三条链的 start 都由组合 sd_mode
            //        门控，一次只可能有一条；
            //     ② 引擎在 start 那拍锁存 owner（= sd_mode_r 对应的那条），整次查询
            //        期间不变；非 owner 的 fe_ok/fe_done/fe_err 在引擎内部被门控成 0
            //        ⇒ 就算两条链同时误启动，非当家那条也只会走看门狗 → fail；
            //     ③ 引擎 busy 期间 top_a 只把「当家链选出来的地址」送去前端
            //        （fe_lba/fe_req 的 sd_mode_r 三选一，和 fe_data 广播那套对称）。
            //==================================================================
            // ★★★ 2026-10-16【清理冗余 viz + 修 top_a 多重驱动】
            //   ★ 删掉 `eng_lba_bmp/wav/sub`、`eng_req_bmp/wav/sub`、`eng_busy_bmp/wav/sub`
            //     这三行**悬空网线声明**：切法C 之后它们已经没有任何驱动源 ——
            //     三条 analyze 薄壳的 `eng_lba_i/eng_req_i` 都是**输入**
            //     （bmp_analyze.v:25-26 / wav_analyze.v:68-69 / sub_analyze.v:105-106），
            //     它们不再自己算扇区地址；地址的唯一来源是下面唯一引擎 u_find_eng 的
            //     `eng_lba/eng_req` 输出。留着这三行只会让 333 行那个残留 mux
            //     去读悬空网线（= 把 X 静默送去前端）。
            wire [23:0] eng_ext_bmp, eng_ext_wav, eng_ext_sub;
            wire [3:0]  eng_skip_bmp, eng_skip_wav, eng_skip_sub;
            wire        eng_start_bmp, eng_start_wav, eng_start_sub;
            wire        eng_done_bmp, eng_done_wav, eng_done_sub;
            wire        eng_fail_bmp, eng_fail_wav, eng_fail_sub;
            // 引擎结果总线（打拍后广播）
            wire [31:0] eng_res_sector, eng_res_size, eng_res_cluster;
            wire        eng_res_done, eng_res_fail;
            reg  [31:0] eng_sec_r, eng_siz_r, eng_clu_r;
            reg         eng_done_r, eng_fail_r;
            // 引擎请求侧
            wire [31:0] eng_lba_o;         // 引擎自算地址（三选一后回送给三条链）
            wire        eng_req_o;         // 引擎读请求
            wire [23:0] eng_ext_sel;
            wire [3:0]  eng_skip_sel;
            wire        eng_name_en_sel;   // ★ 2026-10-20：本笔传输要不要比文件名
            wire        eng_name_sel_sel;  // ★ 2026-10-20：0 = AD 类，1 = MAP 类
            wire        eng_name_en_bmp;   // ★ 2026-10-20：图像链恒 1
            wire        eng_name_sel_bmp;  // ★ 2026-10-20：= bmp_name_sel
            wire        eng_start;
            wire        eng_owner_sel;
            wire        eng_busy_o;        // ← 引擎自己的 busy（回送给三条链做让位仲裁）
            wire        eng_use;           // 引擎正在查文件（= 三条链 busy 的或）


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

            //==================================================================
            //  ★★★ 2026-10-16【切法C·find_bmp 合流】请求/结果仲裁 + 唯一引擎
            //==================================================================
            // ---- start 分发给谁（★ 用组合的 sd_mode，不是寄存过的）----
            //   ★ 声明前置：下面仲裁和三个父实例都要用（这个工程踩过"先用后声明"）
            wire bmp_start = start & (sd_mode == 2'd0);
            wire wav_start = start & (sd_mode == 2'd1);
            wire sub_start = start & (sd_mode == 2'd2);

            // ---- 谁在查（★ 全部用**组合的** sd_mode，和 start 的分配口径一致）----
            //   因为 start 就是组合分发的（`start & (sd_mode==N)`），同一拍必须能对上号。
            //   引擎在 start 那拍把 owner / 扩展名 / skip 一起锁存，之后整次查询不再看它们。
            //   ★ owner 的口径：`start` 只发给「组合 sd_mode 选中的那一条」⇒
            //     **发起者天然就是当家链**，owner 在 start 那拍恒为 1（三条 start 的或）。
            //   ★★ 为什么不能用 fe_owner / mode_is_* 去算：`sd_mode_r` 是在**同一拍**才锁存
            //     新模式的（`start && !sd_busy` 那一拍）⇒ start 当拍读 mode_is_* 拿到的是
            //     上一笔传输的旧模式，第一笔必然错。
            //   ★★★ 2026-10-17 修正：原写法是 `eng_start_wav | eng_start_sub`
            //     = "不是装图才算当家" ⇒ 装图（sd_mode==0）时 owner=0，
            //     引擎内部把前端 sd_ok/sd_done/sd_busy/sd_err 全门成 0
            //     ⇒ 装图必然走看门狗失败、屏上连首页都出不来。
            //     （见 a_image\README_atrack_reverted.md 的第 ② 条）
            assign eng_owner_sel = eng_start_bmp | eng_start_wav | eng_start_sub;

            // ---- 请求三选一：扩展名 / skip ----
            // ★★★ 2026-10-17【修正 · 这里必须用寄存的 mode_is_*，不能用组合 sd_mode】
            //   引擎的 start 不是顶层那个 1 拍脉冲，而是**薄壳从分析器内部 `f_start` 送出的**，
            //   比顶层 start 晚几拍；那时组合 `sd_mode` 已经回落（装图/0）⇒ 字幕链会拿
            //   "BMP" 去查、把查到的 BMP 当 1bpp 解析 ⇒ sub_fail + short。
            //   实测现象就是"图/音频都好了、只有字幕 fail"。
            //   `sd_mode_r` 在顶层 start 那拍就锁存（`start && !sd_busy`）且整次传输不变，
            //   正是引擎延后取用时需要的口径。
            assign eng_ext_sel  = mode_is_sub ? eng_ext_sub  :
                                  mode_is_wav ? eng_ext_wav  : eng_ext_bmp;
            assign eng_skip_sel = mode_is_sub ? eng_skip_sub :
                                  mode_is_wav ? eng_skip_wav : eng_skip_bmp;
            // ★★★ 2026-10-20【找图逻辑·按名字分类】：只有图像链要比文件名，
            //   所以这里按 mode 门控 —— 音频/字幕那两笔传输必须送 0，否则它们也会拿
            //   "AD" 去比名字 ⇒ 一条 WAV 都找不到。
            assign eng_name_en_sel  = (mode_is_sub || mode_is_wav) ? 1'b0 : eng_name_en_bmp;
            assign eng_name_sel_sel = (mode_is_sub || mode_is_wav) ? 1'b0 : bmp_name_sel;

            // ---- 引擎自己的地址/请求 ----
            // ★★★ 2026-10-16【清理冗余 viz + 修 top_a 多重驱动】
            //   ★★ 根因：这里原来还有两条 `assign`（照抄上面 fe_lba/fe_req 那套
            //     「三条链各算各的、top_a 三选一」模式**残留**下来的）：
            //         assign eng_lba_o = mode_is_sub ? eng_lba_sub : ...;
            //         assign eng_req_o = mode_is_sub ? eng_req_sub : ...;
            //     切法C 之后 `eng_lba_o/eng_req_o` 已经由唯一引擎 u_find_eng 的
            //     `eng_lba/eng_req` **输出端口**驱动（find_bmp.v:214-215），
            //     于是同一根 net 有了两个驱动源 ⇒ TD 报
            //         HDL-8007 net 'eng_lba_o' is constantly driven from multiple places
            //         HDL-8007 net 'eng_req_o' is constantly driven from multiple places
            //     ⇒ `top_a` 降级成黑盒 ⇒ `PRJ-8806 syn_1 exited unexpectedly`。
            //   ★ 而且那两条 assign 的右值（eng_lba_bmp/wav/sub、eng_req_bmp/wav/sub）
            //     在切法C 之后**根本没有任何驱动**，所以它不只是"多一个驱动"——
            //     就算让它当家，也是把悬空值送去前端 = 无声的错。两条都不能留。
            //   ★ 修法：**只删这两条残留 assign**（连同上面三行悬空声明），
            //     保留引擎输出作为唯一驱动源 —— 这正是切法C 的原意图：
            //       引擎算地址 → 三薄壳按 eng_owner 让位后各自 fe_lba/fe_req 出口
            //       → top_a 的 fe_lba/fe_req 三选一 → u_sd_front。
            //   ★ 本次**没有**新增/改动任何 A 轨信号，也没接常量/悬空。

            // ---- 引擎忙？（★ 电平：引擎 FSM 自己锁存的那一位）----
            assign eng_use   = eng_busy_o;
            assign eng_start = eng_start_bmp | eng_start_wav | eng_start_sub;

            // ---- 结果：引擎一路广播（同一时刻只有一个文件在查）----
            //   三条链都拿到同一份，但只有发起者那拍在听（它的 done 才刚发出来）。
            always @(posedge sys_clk or negedge sys_rst_n) begin
                if (!sys_rst_n) begin
                    eng_sec_r  <= 32'd0;
                    eng_siz_r  <= 32'd0;
                    eng_clu_r  <= 32'd0;
                    eng_done_r <= 1'b0;
                    eng_fail_r <= 1'b0;
                end
                else begin
                    eng_done_r <= 1'b0;
                    eng_fail_r <= 1'b0;
                    if (eng_res_done) begin
                        eng_sec_r  <= eng_res_sector;
                        eng_siz_r  <= eng_res_size;
                        eng_clu_r  <= eng_res_cluster;
                        eng_done_r <= 1'b1;
                    end
                    if (eng_res_fail) eng_fail_r <= 1'b1;
                end
            end

            //==================================================================
            //  ★ FAT/目录索引引擎：全工程唯一一份
            //==================================================================
            find_bmp_eng #(.NAME1(64'h454D_4700_0000_0000)) u_find_eng (   // NAME1 = 'E','M','G'
                .sys_clk         (sys_clk),
                .sys_rst_n       (sys_rst_n),

                // 共享前端应答（广播）
                .fe_init_done    (fe_init_done),
                .fe_data         (fe_data),
                .fe_ok           (fe_ok),
                .fe_done         (fe_done),
                .fe_busy         (fe_busy),
                .fe_err          (fe_err),

                // 请求（三选一；start 是三条链的或，owner 用组合 sd_mode）
                .start           (eng_start),
                .owner           (eng_owner_sel),
                .target_ext      (eng_ext_sel),
                // ★★★ 2026-10-21【全局名字过滤】三条链共用一个引擎 ⇒ 名字比较统一在这里做。
                //   name_emg_only=1（报警态）⇒ 只认 EMG*；=0（正常态）⇒ 排除 EMG*。
                //   于是"正常态永远转不到报警素材"是硬件保证，不靠软件让路。
                .name_en         (1'b1),
                .name_sel        (1'b1),               // 比 NAME1 = "EMG"
                .name_inv        (~name_emg_only),
                .cmd             (1'b0),          // ★ 三条链都只找文件
                .skip            (eng_skip_sel),
                .in_cluster      (32'd0),         // cmd=0 用不到

                // 引擎自己的读请求（→ 三选一回送给三条链，由薄壳做让位仲裁）
                .eng_lba         (eng_lba_o),
                .eng_req         (eng_req_o),
                .eng_busy        (eng_busy_o),

                // 结果
                .eng_res_sector  (eng_res_sector),
                .eng_res_size    (eng_res_size),
                .eng_res_cluster (eng_res_cluster),
                .eng_res_done    (eng_res_done),
                .eng_res_fail    (eng_res_fail)
            );

            // ★ 引擎的结果已经打过一拍；广播给三条链（只有发起者那拍在听）
            assign eng_done_bmp = eng_done_r;   assign eng_fail_bmp = eng_fail_r;
            assign eng_done_wav = eng_done_r;   assign eng_fail_wav = eng_fail_r;
            assign eng_done_sub = eng_done_r;   assign eng_fail_sub = eng_fail_r;

            sd_top u_sd_front (
                .sys_clk   (sys_clk),
                // ★★★ 2026-10-17【25 MHz 试过上板，**不可靠**，已回退到 sys_clk = 12.5 MHz】
                //   接线方式：顶层 `.clk_spi(clk_par)`（100 MHz）⇒ SCLK = 25 MHz。
                //   上板现象（COM6 遥测）：`load_done` 掉、`a_dbg_px_cnt` 以 3.9 Mpx/s "疯跑"
                //   （= 11.8 MB/s，**超过 25 MHz 的物理上限 3.1 MB/s**）⇒ 读回数据是错的、
                //   在反复重试，9 秒后才偶尔成功一次。⇒ 是**卡/走线信号完整性**扛不住，
                //   不是时序问题（时序报告里 100 MHz 域 SWNS +0.971 ns、0 违例）。
                //   ★ 想再试的话：把这一根换回 `clk_spi`、顶层接 `clk_par` 即可（两行）。
                .clk_spi   (sys_clk),        // SCLK = 50/4 = 12.5 MHz（实测 A 轨 379 kpx/s = 1.14 MB/s）
                .sys_rst_n (sys_rst_n),

                .spi_miso  (spi_miso),
                .spi_mosi  (spi_mosi),
                .spi_clk   (spi_clk),
                .spi_cs    (spi_cs),

                .read_addr (fe_lba),
                .read_req  (fe_req),                .data_out  (fe_data),
                .read_busy (fe_busy),
                .read_ok   (fe_ok),
                .read_done (fe_done),
                .read_err  (fe_err),

                .led1      (fe_led),
                .bus_owner (fe_init_done),
                // ★★★ 2026-10-17【CMD18 多块连续读：仿真过、**上板失败**，现已关闭】
                //   仿真结论（`sim\tb_sd_stream.v` + `sim\sd_card_model.v` 假卡）：
                //     每块 456 µs → **330 µs**（1.32x），8 块只发 **1 条命令**，
                //     4608 字节逐字节正确，而且"流式收尾后紧接着单块读"也对。
                //   上板结论（两次下载，含补 CMD12 那版）：
                //     图像那一趟**能装完**（遥测：写字数正好 153600 = 640×480/2），
                //     但**此后所有 SD 读全失败**（`fail=1`、px 被清 0、音频/字幕都装不上）
                //     ⇒ 这张卡在 SPI 模式下无法被干净地退出多块读（撤 CS 与 CMD12 都试过）。
                //   ⇒ 现在恒接 0：**行为与改动前逐位相同**（每块一次 CMD17）。
                //   ★ 想再试：把它改回 `.stream_en(sd_stream_bmp)` 即可（一行）。
                .stream_en (1'b0)
            );

            // ---- start 分发（★ 声明已前置到上面【切法C】那一段）----

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
            bmp_analyze #(
                .NAME_EN (BMP_NAME_EN)        // ★ 2026-10-20：0 = 只按后缀找（老行为）
            ) u_bmp_analyze (
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
                // ★★★ 2026-10-16【切法C·find_bmp 合流】：查文件走唯一引擎 u_find_eng
                .eng_ext      (eng_ext_bmp),
                .eng_skip     (eng_skip_bmp),
                .eng_name_en  (eng_name_en_bmp),   // ★ 2026-10-20：恒 1
                .eng_name_sel (eng_name_sel_bmp),  // ★ 2026-10-20：= bmp_name_sel
                .eng_start    (eng_start_bmp),
                .eng_owner    (),
                .eng_lba_i    (eng_lba_o),
                .eng_req_i    (eng_req_o),
                .eng_busy     (eng_busy_o),
                .eng_done     (eng_done_bmp),
                .eng_fail     (eng_fail_bmp),
                .eng_sector   (eng_sec_r),
                .eng_size     (eng_siz_r),
                .eng_cluster  (eng_clu_r),
                .start      (bmp_start),         // ★ 只在装图那一拍给
                .skip       (skip),
                .name_sel   (bmp_name_sel),      // ★ 2026-10-20：0 = AD 类，1 = MAP 类
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
                // ★★★ 2026-10-17【CMD18 多块连续读】"正在读像素数据"⇒ 允许连续读多块
                .seq_rd     (sd_stream_bmp),
                .dbg_px_cnt     (dbg_px_cnt),
                .dbg_data_off   (),
                .dbg_first_px   (dbg_first_px),
                .dbg_first_addr (dbg_first_addr),
                .bmp_bpp        (o_img_bpp)      // ★ D3 · C3：位深引出去给兜底页
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
                // ★★★ 2026-10-16【切法C·find_bmp 合流】：查文件走唯一引擎 u_find_eng
                .eng_ext      (eng_ext_wav),
                .eng_skip     (eng_skip_wav),
                .eng_start    (eng_start_wav),
                .eng_owner    (),
                .eng_lba_i    (eng_lba_o),
                .eng_req_i    (eng_req_o),
                .eng_busy     (eng_busy_o),
                .eng_done     (eng_done_wav),
                .eng_fail     (eng_fail_wav),
                .eng_sector   (eng_sec_r),
                .eng_size     (eng_siz_r),
                .eng_cluster  (eng_clu_r),

                .start        (wav_start),       // ★ 只在装音频那一拍给
                .skip         (skip),

                .busy         (wav_busy),
                .done         (wav_an_done),
                .fail         (wav_an_fail),

                .smp_rate     (o_aud_rate),
                .smp_ch       (),
                .smp_bits     (o_aud_bits),
                .smp_cnt      (smp_cnt),
                .info_valid   (o_aud_info_valid),

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
                // ★★★ 2026-10-16【切法C·find_bmp 合流】：查文件走唯一引擎 u_find_eng
                .eng_ext        (eng_ext_sub),
                .eng_skip       (eng_skip_sub),
                .eng_start      (eng_start_sub),
                .eng_owner      (),
                .eng_lba_i      (eng_lba_o),
                .eng_req_i      (eng_req_o),
                .eng_busy       (eng_busy_o),
                .eng_done       (eng_done_sub),
                .eng_fail       (eng_fail_sub),
                .eng_sector     (eng_sec_r),
                .eng_size       (eng_siz_r),
                .eng_cluster    (eng_clu_r),

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