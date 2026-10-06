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
    //  三、★ 接 line_buf（显示的读口）
    //      原来是：line_buf.mem_rd_en/addr ──直连──► sdr_arb.disp_rd_en/addr
    //              Sdr_rd_dout/Sdr_rd_en   ──直连──► line_buf.mem_rd_data/vld
    //      现在把两端都接到这里来（line_buf.v 和 sdr_arb.v 一行不用改）
    // ==================================================================
    input  wire        line_rd_req,     // ← line_buf.mem_rd_en
    input  wire [20:0] line_rd_addr,    // ← line_buf.mem_rd_addr
    output wire [31:0] line_rd_data,    // → line_buf.mem_rd_data
    output wire        line_rd_vld,     // → line_buf.mem_rd_vld

    // ==================================================================
    //  四、★ 接 sdr_arb 的读口（原来 line_buf 直连的那两根）
    // ==================================================================
    output wire        sdr_rd_en,       // → sdr_arb.disp_rd_en
    output wire [20:0] sdr_rd_addr,     // → sdr_arb.disp_rd_addr

    // ==================================================================
    //  五、★ 接 SDRAM 控制器（读数据回来）
    // ==================================================================
    input  wire [31:0] mem_rd_dout,     // ← sdram.Sdr_rd_dout
    input  wire        mem_rd_vld,      // ← sdram.Sdr_rd_en
    // ★★ 集成临时改动（见 规划\A轨待改清单.md 2026-10-05 第 6 条）：
    //    SDRAM 核的忙 / 刷新标志，直接透传给 sdr_rd_arb（只用来推迟音频的读）
    input  wire        sdr_busy,        // ← sdram.Sdr_busy
    input  wire        sdr_init_ref_vld,// ← sdram.Sdr_init_ref_vld

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
    output wire        dbg_tag_bad,     // ★ 集成临时改动：tag 队列脱钩过（sticky）
    output wire [15:0] dbg_aud_cnt,     // ★★ 第 8 条：音频数据自检（本次播放收了多少字）
    output wire [31:0] dbg_aud_sum      // ★★ 第 8 条：音频数据自检（这些字的 32 位和）
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
        .sfx_id     (sfx_id),
        .volume     (volume),
        .play_tgl   (play_tgl),
        .sfx_base   (sfx_base),
        .sfx_words  (sfx_words),
        .vol_out    (vol_out),
        .busy       (aud_busy)
    );

    // ============================================================
    //  ② sdr_rd_arb —— SDRAM 读口仲裁 + 读音频数据
    //     时钟域：显存域 125 MHz（仲裁）+ 音频域（数据 FIFO）
    //     ★ 显示的读口就是在这儿"绕道"的
    // ============================================================
    sdr_rd_arb u_sdr_rd_arb (
        .clk_mem       (clk_mem),
        .rst_mem_n     (rst_mem_n),

        // ---- 显示申请人（接 line_buf）----
        .disp_rd_en    (line_rd_req),
        .disp_rd_addr  (line_rd_addr),
        .disp_rd_data  (line_rd_data),
        .disp_rd_vld   (line_rd_vld),

        // ---- 去 sdr_arb 的读口 ----
        .rd_en         (sdr_rd_en),
        .rd_addr       (sdr_rd_addr),

        // ---- SDRAM 控制器回来的 ----
        .sdr_rd_dout   (mem_rd_dout),
        .sdr_rd_en     (mem_rd_vld),
        // ★★ 集成临时改动（见 规划\A轨待改清单.md 2026-10-05 第 6 条）：
        //    忙/刷新标志透传（只用来推迟音频的读，绝不挡显示）
        .sdr_busy         (sdr_busy),
        .sdr_init_ref_vld (sdr_init_ref_vld),

        // ---- 播放命令（从 sfx_ctrl 来）----
        .aud_play_tgl  (play_tgl),
        .aud_base      (sfx_base),
        .aud_words     (sfx_words),

        // ---- 音频域：把数据交给 sfx_player ----
        .clk_aud       (clk_aud),
        .rst_aud_n     (rst_aud_n),
        .aud_dout      (aud_dout),
        .aud_vld       (aud_vld),
        .aud_next      (aud_next),
        .aud_busy      (aud_busy),
        .o_tag_bad     (dbg_tag_bad),
        .aud_dbg_cnt   (dbg_aud_cnt),
        .aud_dbg_sum   (dbg_aud_sum)
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
