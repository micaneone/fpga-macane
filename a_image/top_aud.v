// ==========================================================================
//  top_aud —— 音频链【次顶层】（和图像链的 top_a 并列）
// ==========================================================================
//
//  ★★★ 集成顶层怎么用（就两步）
//
//      ① 例化 top_a     —— 图像链，接口是【写口 + SD 引脚 + 描述符】
//      ② 例化 top_aud   —— 音频链，接口是【读口 + HDMI 音频 6 根线 + C 轨命令】
//
//      然后：
//        · top_aud 的 HDMI 6 根线  → 接进 HDMI 核
//        · top_aud 的 line_rd_*    → 接 line_buf 的读口
//        · top_aud 的 sdr_rd_*     → 接 sdr_arb 的 disp_rd_en/addr
//        · top_aud 的 mem_rd_*     → 接 SDRAM 控制器的 Sdr_rd_dout/Sdr_rd_en
//
//  ★★ 它内部收了 4 个模块
//
//      top_aud
//        ├─ sfx_ctrl              第几条 → 基址/字数        （控制域 50 MHz）
//        ├─ sdr_rd_arb            SDRAM 读口仲裁 + 读数据    （显存域 + 音频域）
//        ├─ sfx_player            数据流 → 并行采样          （音频域 → 像素域）
//        └─ audio_arc_calculate   ACR                        （像素域）
//
//  ★★ 本模块【不含 SDRAM 本体、也不含 sdr_arb】
//      全项目只能例化一次 SDRAM，它归集成顶层。
//      这里是"借道"：把显示的读口绕一下，音频插个空档。
//
//  ★★★ 三个绝不能搞错的地方
//
//      ① 【绝不压 line_rd_req】
//         line_buf 的 fsent 是它自己数的。你把它某一拍压掉，
//         它就少收一个字 → 那一行显示错位 ✗
//         ⇒ 音频只在【line_rd_req 为 0】的那一拍才用读口。
//           本模块内部已经保证，你只要【原样透传】就行，别在中间加逻辑。
//
//      ② 【ACR 的时钟】audio_arc_calculate 用 clk_pix
//         它靠"数像素时钟"算 CTS。接成别的时钟 → 声音变调/断续，
//         而且【不报错】，只能靠耳朵听出来 ✗
//         本模块内部已经接好 clk_pix，你只要给对 clk_pix 就行。
//
//      ③ 【音频 PLL】clk_aud 必须自己建（12.288 MHz）
//         50 MHz 精确做不出 12.288，但 ±600ppm 以内人耳完全无感。
//
//  ★ 使用流程（C 轨）
//      1) 先让 top_a 把音效 WAV 装进 SDRAM 音效区（sd_to_wav=1）
//      2) C 轨发 play_sfx（单拍）+ sfx_id + volume
//      3) 自动：读 SDRAM → FIFO → 音量/淡入淡出 → 采样 → HDMI
//         放完自动淡出，然后一直推 0 采样（静音兜底，HDMI 不断流）
//         ★ 不需要"停止"命令
//
//  ★★★ 声明全部前置（这个工程踩过五次"先用后声明"）
// ==========================================================================
`timescale 1ns / 1ps

module top_aud #(
    // ---- 音效区布局 ----
    parameter integer SFX_NUM    = 2,               // 音效条数
    parameter integer SFX_STRIDE = 72000,           // 每条占多少字（72000 = 3 秒 @48kHz）
    parameter [20:0]  SFX_BASE   = 21'd1861660,     // 音效区基址（契约里未分配的小槽区）
    // ---- HDMI ACR ----
    parameter integer ACR_N      = 6144             // 48 kHz 用 6144，别改
)(
    // ==================================================================
    //  一、时钟 / 复位（4 个域，一个都少不了）
    // ==================================================================
    input  wire        clk_ctl,         //  50     MHz  控制域（C 轨命令、volume）
    input  wire        rst_ctl_n,       //               低有效
    input  wire        clk_mem,         // 125     MHz  显存域（★ 显示读口在这）
    input  wire        rst_mem_n,       //               低有效
    input  wire        clk_aud,         //  12.288  MHz  音频域（★ 音频 PLL 给）
    input  wire        rst_aud_n,       //               低有效
    input  wire        clk_pix,         //  像素时钟      （★ 和 HDMI 核同一个）
    input  wire        rst_pix_n,       //               低有效

    // ==================================================================
    //  二、命令（给 C 轨）
    // ==================================================================
    input  wire        play_sfx,        // 单拍脉冲：开始播
    input  wire  [3:0] sfx_id,          // 第几条（0 ~ SFX_NUM-1，越界忽略）
    input  wire  [7:0] volume,          // 音量（用高 4 位当 0..15 档）
    output wire        busy,            // 1 = 还在读/放

    // ==================================================================
    //  三、★★★ 2026-10-06【集成侧重做】音频不再"逐拍抢读口"
    //
    //  原来是：line_buf ──逐字──► sdr_rd_arb ──逐字──► sdr_arb 的读口，
    //          音频趁"显示没发读的那一拍"插一个地址进去，回来靠 tag 队列分流。
    //          ★ 上板结论：这颗核受不了两个地址流被逐拍交织 —— 音频听到
    //            "沙沙声"、而且**跟着显示的读流量变大**（1536 宽的图最响）。
    //
    //  现在：显示走【块级】读通路（rtl\blk_rd_arb.v + rtl\vendor_rd_path.v），
    //        音频也走同一个仲裁器的**音频口**（a_* 这一组）——
    //        **谁拿到读口谁整块读完，块与块之间不交叠** ⇒ 不需要 tag 队列，
    //        也不会交织。显示永远优先（仲裁器只在显示没有块请求时才接音频）。
    //
    //  ★ 与 A 的接口：sfx_ctrl / sfx_player / audio_arc_calculate 一个字没改，
    //    只把中间那层换成 a_image\aud_blk_rd.v（B 新写的块级客户端）。
    //    ⇒ 转给 A 的条目见 规划\A轨待改清单.md。
    // ==================================================================
    output wire        a_req,           // → blk_rd_arb.a_req
    output wire [20:0] a_base,          // → blk_rd_arb.a_base
    output wire [20:0] a_len,           // → blk_rd_arb.a_len
    input  wire        a_gnt,           // ← blk_rd_arb.a_gnt
    output wire        a_next,          // → blk_rd_arb.a_next（收集期间恒 1）
    input  wire [31:0] a_data,          // ← blk_rd_arb.a_data
    input  wire        a_dv,            // ← blk_rd_arb.o_dv[1]
    input  wire        rd_ok,           // 1 = 现在允许读（装载期间顶层压 0）
    input  wire [20:0] aud_words_act,   // ★★★ 本次装入音效的【实际字数】（顶层 latch 后送来；0 = 未知）

    // ==================================================================
    //  六、★ 接 HDMI（6 根，接进 HDMI 核 / my_hdmitop）
    // ==================================================================
    output wire        o_audio_valid,   // → HDMI 核 I_audio_valid
    output wire [23:0] o_audio_left,    // →              I_audio_left_data
    output wire [23:0] o_audio_right,   // →              I_audio_right_data
    output wire        o_acr_valid,     // →              I_acr_valid
    output wire [19:0] o_acr_cts,       // →              I_acr_cts
    output wire [19:0] o_acr_n,         // →              I_acr_n

    // ==================================================================
    //  七、诊断（接 ILA，不用就悬空）
    // ==================================================================
    output wire [20:0] dbg_sfx_base,    // 这一次播哪一条（它的基址）
    output wire [20:0] dbg_sfx_words,   // 这一条多少个字
    output wire        dbg_play_tgl,    // 播放命令的 toggle（ILA 上看翻转）
    output wire [31:0] dbg_aud_dout,    // 音频数据流（音频域）
    output wire        dbg_aud_vld,
    output wire        dbg_blk_stall,   // ★ 块级读看门狗掐断过（sticky）
    output wire [15:0] dbg_aud_cnt,     // ★★ 第 8 条：音频数据自检（本次播放收了多少字）
    output wire [31:0] dbg_aud_sum,     // ★★ 第 8 条：音频数据自检（这些字的 32 位和）
    // ★★★ 2026-10-09：块级 FIFO 被饿穿过（sticky）—— 判"沙沙声是不是读没跟上"
    output wire        dbg_aud_underrun
);

    // ============================================================
    //  ★ 声明全部前置
    // ============================================================
    // ---- sfx_ctrl → sdr_rd_arb ----
    wire        play_tgl;               // ★ toggle（跨到显存域用）
    wire [20:0] sfx_base;
    wire [20:0] sfx_words;
    wire  [7:0] vol_out;

    // ---- sdr_rd_arb → sfx_player ----
    wire [31:0] aud_dout;
    wire        aud_vld;
    wire        aud_next;
    wire        aud_underrun_w;      // ★★ 2026-10-09：块级 FIFO 饿死探针（sticky）

    // ---- 内部 ----
    wire        aud_busy;
    wire        audio_valid;
       assign busy          = aud_busy;

    assign dbg_sfx_base  = sfx_base;
    assign dbg_sfx_words = sfx_words;
    assign dbg_play_tgl  = play_tgl;
    assign dbg_aud_dout  = aud_dout;
      assign o_audio_valid = audio_valid;
    assign dbg_aud_vld   = aud_vld;
    assign dbg_aud_underrun = aud_underrun_w;

    // ============================================================
    //  ① sfx_ctrl —— 第几条 → 基址 / 字数
    //     时钟域：控制域 50 MHz
    // ============================================================
    sfx_ctrl #(
        .SFX_NUM    (SFX_NUM),
        .SFX_STRIDE (SFX_STRIDE),
        .SFX_BASE   (SFX_BASE)
    ) u_sfx_ctrl (
        .clk_ctl    (clk_ctl),
        .rst_ctl_n  (rst_ctl_n),
        .play_sfx   (play_sfx),
        .words_act  (aud_words_act),   // ★ 实际字数（0 时 sfx_ctrl 退回 SFX_STRIDE）
        .sfx_id     (sfx_id),
        .volume     (volume),
        .play_tgl   (play_tgl),
        .sfx_base   (sfx_base),
        .sfx_words  (sfx_words),
        .vol_out    (vol_out),
        .busy       (aud_busy)
    );

    // ============================================================
    //  ② aud_blk_rd —— 音频的【块级】读客户端（替换原来的 sdr_rd_arb）
    //     时钟域：显存域 125 MHz（排块 + FIFO 写）+ 音频域（FIFO 读）
    //     ★ 它对外只有一组块口（a_*），接到顶层 blk_rd_arb 的音频口；
    //       读口怎么和显示分，全部归那个仲裁器管。
    // ============================================================
    aud_blk_rd #(
        // ★★★ 2026-10-14【§30.20 判定：块边界接缝】
        //   假设"每 64 字一条接缝 ⇒ 听感失真"，把块加大到 512（接缝数少 8 倍）
        //   ⇒ 若失真明显变轻/消失 ⇒ 坐实接缝在块边界；也顺带是个可用的缓解。
        //   （512 也正好是官方读 FIFO 的深度；`wrusedw` 那套"有字就取"的协议支持整块。）
        // ★★★ 2026-10-14 晚【治"偶发一声爆破音"】：512 → **256**
        //   病根：BLK_WORDS(512) == AFIFO 深度(512) ⇒ ROOM_LIMIT = 0
        //   ⇒ **只有把 FIFO 抽干到 0 才去申请下一块**，块边界上余量恰好为零。
        //   能不能接上全看读口仲裁延迟（显示链占读口约 86%，音频块要跨好几个
        //   行消隐间隙才取得完）。平常几十 µs，消费端 buf0/buf1 顶得住；
        //   偶尔更长就把一个字（2 采样）替换成 0 = **一声爆**，然后立刻恢复。
        //   256 字 ⇒ 余量 256 字 ≈ 10.7 ms，比任何读口阻塞都大两个数量级。
        //   （64 字那版是另一种病：每 64 字一条接缝 → 持续失真，别退回去。）
        //
        // ★★★ 2026-10-14 深夜【上板 A/B 结论：上面这个改法撤回】
        //   上板对照（同一个 KEY3 动作）：
        //     BLK_WORDS=256 → 稳态那声爆确实没了（第一遍全干净），**但按 KEY3 重装重播后
        //                     出现一层持续"嗤嗤"声，要 KEY4/断电才清**；
        //     BLK_WORDS=512 → 按 KEY3 **不嗤嗤**（只有那个偶发爆）。
        //   ⇒ 撤回。病根不在"余量大小"，而在"**有重叠**"这件事本身：
        //     ROOM_LIMIT = 深度 − 块长 > 0 ⇒ FIFO 一边被写一边被读，写指针和读指针
        //     会走到**同一地址附近**（手写格雷码 FIFO 的读写同址隐患），读到被写一半的字
        //     ⇒ 每圈都错几个字 ⇒ 持续高频"嗤嗤"，而且指针相位一旦偏了就不会自己回来
        //     （所以只有复位能清）。512 时 ROOM_LIMIT = 0 ⇒ **永不重叠** ⇒ 干净。
        //   ★ 注意：加深度（AFIFO_AW 9→10）同样会产生重叠，别再走这条路。
        //   ⇒ 那声爆改在**消费端**治（`sfx_player`：没数据时保持上一个采样而不是灌 0），
        //     见 a_image\sfx_player.v 里那段说明。
        // ★★★ 2026-10-14 深夜【减重·FIFO 与块长同时减半】：
        //   设计贴着器件上限（实测 mslice 4949 > 4900），而 512x32 的手写 FIFO 被综合成
        //   LUTRAM（1952 LUT ≈ 250 MSlice）。这里把**深度和块长同时**减半到 256：
        //     ROOM_LIMIT = 256 - 256 = 0  ⇒ **保持"永不读写重叠"**（这是被上板验证过的关键
        //     性质：一旦余量>0，FIFO 边写边读，会带出一层持续"嗤嗤"声）。
        //   ⇒ LUTRAM 直接少一半（约 -120 MSlice），足够把字幕那条修复装进去。
        //   ★ 曾试过"把 FIFO 搬进 BRAM（寄存读 + show-ahead 输出寄存器）"：面积确实降到
        //     66% LUT、也推断出 2 个 BRAM，但**上板没声音**（读出协议对不齐）⇒ 放弃。
        .BLK_WORDS (256),
        // ★★★ 2026-10-09 晚【A/B 实验】：缩小的 7 先退回 **9**（512 字）。
        //   上午缩到 128 字省了 ~1,200 LUT，可上板音频只剩沙沙声；
        //   现在 LUT 只 68%（字幕 RAM 进 BRAM，面积反而降了），所以恢复 512 做对照。
        .AFIFO_AW  (8)          // FIFO 256 字（与块长 256 配套 ⇒ ROOM_LIMIT = 0）          // FIFO 512 字 ≈ 21 ms
    ) u_aud_blk_rd (
        .clk_mem       (clk_mem),
        .rst_mem_n     (rst_mem_n),
        .rd_ok         (rd_ok),

        // ---- 播放命令（从 sfx_ctrl 来）----
        .aud_play_tgl  (play_tgl),
        .aud_base      (sfx_base),
        .aud_words     (sfx_words),

        // ---- 块口（顶层接 blk_rd_arb 的音频口）----
        .a_req         (a_req),
        .a_base        (a_base),
        .a_len         (a_len),
        .a_gnt         (a_gnt),
        .a_next        (a_next),
        .a_data        (a_data),
        .a_dv          (a_dv),

        // ---- 音频域：把数据交给 sfx_player ----
        .clk_aud       (clk_aud),
        .rst_aud_n     (rst_aud_n),
        .aud_dout      (aud_dout),
        .aud_vld       (aud_vld),
        .aud_next      (aud_next),
        .aud_busy      (aud_busy),

        .dbg_cnt       (dbg_aud_cnt),
        .dbg_sum       (dbg_aud_sum),
        .dbg_blk_cnt   (),
        .o_stall       (dbg_blk_stall),
        .o_underrun    (aud_underrun_w)      // ★★ 饿死探针
    );

    // ============================================================
    //  ③ sfx_player —— 数据流 → 并行采样（含音量 / 淡入淡出 / 静音兜底）
    //     时钟域：音频域产生、像素域输出
    // ============================================================
    sfx_player u_sfx_player (
        .clk_aud       (clk_aud),
        .rst_aud_n     (rst_aud_n),

        // ---- ★ 输出在【像素域】，直接接 HDMI 核 ----
        .clk_pix       (clk_pix),
        .rst_pix_n     (rst_pix_n),
        .o_audio_valid (audio_valid),
        .o_audio_left  (o_audio_left),
        .o_audio_right (o_audio_right),

        // ---- 控制域（只同步 volume）----
        .clk_ctl       (clk_ctl),
        .rst_ctl_n     (rst_ctl_n),
        .volume        (vol_out),

        // ---- 数据流（从 sdr_rd_arb 的 FIFO 来）----
        .aud_dout      (aud_dout),
        .aud_vld       (aud_vld),
        .aud_next      (aud_next),

        .busy          ()
    );

  

    // ============================================================
    //  ④ audio_arc_calculate —— HDMI 的 ACR（音频时钟重建）
    //     时钟域：★ 必须是【像素时钟】
    //              （它靠"数像素时钟"算 CTS；接错会变调/断续而且不报错）
    //     ★ I_rst 是【高有效】，和本模块的 rst_pix_n 反着
    // ============================================================
    audio_arc_calculate #(
        .ACR_N (ACR_N)
    ) u_arc (
        .I_clk        (clk_pix),
        .I_rst        (~rst_pix_n),         // ★ 高有效
        .I_audio_valid(audio_valid),        // ★ 和 HDMI 核吃同一个信号
        .O_acr_valid  (o_acr_valid),
        .O_acr_cts    (o_acr_cts),
        .O_acr_n      (o_acr_n)
    );


endmodule
