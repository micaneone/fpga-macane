// ============================================================
//  sfx_ctrl —— 音效播放控制（A 轨）
//
//  把 C 轨发来的【第几条】翻译成 sdr_rd_arb 要的【基址 + 字数】。
//
//  ★ 接口（和 A轨说明书 §3.4 说死的）
//      C → 本模块：play_sfx[3:0]（单拍脉冲）+ volume[7:0]
//      本模块 → sdr_rd_arb：play_tgl / sfx_base / sfx_words
//                ★ play 用【toggle】不是单拍脉冲 —— 它要跨到 125MHz 显存域，
//                  单拍脉冲用两级同步会漏 ✗
//                ★ 不用给 sfx_player 发 play：它的淡入淡出是自动跟随数据的
//
//  ★ 音效区布局（★ 参数，改这里就行）
//      基址   SFX_BASE   = 1,861,660（契约里【未分配】的小槽区，180,000 字）
//      每条   SFX_STRIDE = 72,000 字 = 144,000 采样 = 3 秒 @48kHz
//      条数   SFX_NUM    = 2（180,000 ÷ 72,000 = 2.5）
//
//    ★ 为什么用这块地方：契约里明确写着"整块预留、还没切"，
//      用它当音效区【完全不用动两个大槽】—— 也就不会踩
//      "改了 SLOT0_WORDS 就得同步改 bmp_scale 的 SLOT_WORDS"那个坑。
//
//  ★ 播放中忽略新命令（`busy` 期间不接），避免播到一半被换掉。
// ============================================================
`timescale 1ns / 1ps

module sfx_ctrl #(
    parameter integer SFX_NUM    = 2,               // 音效条数
    parameter integer SFX_STRIDE = 72000,           // 每条占多少字
    parameter [20:0]  SFX_BASE   = 21'd1861660      // 音效区基址（小槽区）
)(
    input  wire        clk_ctl,
    input  wire        rst_ctl_n,

    // ---- 从 C 轨来 ----
    input  wire        play_sfx,        // 单拍脉冲：开始播
    // ★★★ 2026-10-17【修 · 换音频失真】`stop_sfx` = 单拍脉冲：立刻停止播放。
    //   为什么必须有它：下面那句判据是 `!busy` 才收命令（"播放中忽略新命令"），
    //   而 `busy`（= sdr_rd_arb 的 `a_run`）要等**整首词全部发完**才落，
    //   且装载期间音频读被 `disp_rd_gate` 掐断 ⇒ `busy` 在装载后还要挂很久。
    //   ⇒ 换歌时"先装新数据、再发 play"的话，play 会被这里丢掉：
    //     旧播放指针（旧 base/旧字数）继续去读**已经被覆写**的那片区域
    //     ⇒ 用户听到的"失真/串味"。停一下就没这个竞态了：
    //     停止 ⇒ busy 落 ⇒ 装载（本次装载期间区域无读，也干净）⇒ play 必被接收。
    input  wire        stop_sfx,        // ★ 单拍脉冲：立刻停（字数清 0 + 翻 toggle）
    input  wire  [3:0] sfx_id,          // 第几条（0 ~ SFX_NUM-1）
    input  wire  [7:0] volume,          // 音量
    input  wire  [20:0] words_act,    // ★★★ 本次装入音效的【实际字数】（0 = 未知，退回 SFX_STRIDE）

    // ---- 去 sdr_rd_arb ----
    output reg         play_tgl,        // ★ toggle（跨到显存域用）
    output reg  [20:0] sfx_base,
    output reg  [20:0] sfx_words,
    output wire  [7:0] vol_out,         // 音量直通（给 sfx_player）

    // ---- 状态 ----
    input  wire        busy             // 来自 sdr_rd_arb（还在读/放）
);

    wire id_ok = (sfx_id < SFX_NUM);       // 序号越界就不理（★ 2026-10-25：不能写 SFX_NUM[3:0]——SFX_NUM=16 时 [3:0]=0，id_ok 恒 0 ⇒ 播放命令全被丢，整机没音乐）

    assign vol_out = volume;

    always @(posedge clk_ctl or negedge rst_ctl_n) begin
        if (!rst_ctl_n) begin
            play_tgl  <= 1'b0;
            sfx_base  <= 21'd0;
            sfx_words <= 21'd0;
        end
        else begin
            if (stop_sfx) begin
                //  ★ 停止 = "新命令 + 0 字"：sdr_rd_arb 收到后 a_iss >= a_words_r 立即成立
                //    ⇒ 下一拍 a_run 就落 ⇒ 不再发读；FIFO 里剩下的旧采样自己淡出。
                //  ★ 不受 `!busy` 限制 —— 它本来就是用来打断正在播的那一首的。
                sfx_words <= 21'd0;
                play_tgl  <= ~play_tgl;
            end
            else if (play_sfx && id_ok && !busy) begin
                //  ★ 基址 = 音效区基址 + 条号 × 每条长度
                sfx_base  <= SFX_BASE + sfx_id * SFX_STRIDE[20:0];
                sfx_words <= (words_act != 21'd0) ? words_act : SFX_STRIDE[20:0];   // ★ 播放长度 = 实际字数（治「太短」+「放完后的杂音」）
                play_tgl  <= ~play_tgl;         // ★ 翻 toggle = 一条新命令
            end
        end
    end

endmodule
