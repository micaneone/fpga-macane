//==========================================================================
//  viz_top —— 音频可视化顶层（时域历史 + 频域频谱）
//==========================================================================
//
//  ── ★★★ 分界就在这两组线上 ──
//
//    【A 轨（音频域）】接这 4 根：
//        clk_aud / rst_aud_n / aud_vld / aud_dout
//      ★ 这 4 根在 top_aud.v 里现成就有：
//        aud_vld / aud_dout 就是 aud_blk_rd → sfx_player 之间那对线，
//        而且已经引出成 dbg_aud_vld / dbg_aud_dout 两个端口了
//
//    【B 轨（像素域）】接这 9 根：
//        de / x / y   +   两组 mask / band / color
//
//  ── 位置由参数定（摆在哪儿由 B 拍板）──
//      HIST_X/Y、FREQ_X/Y 是两块显示区的左上角
//      HIST_H、FREQ_H 是矩形高度（★ 必须 ≥ 63，柱高是 6 位）
//      宽度自动 = N × 2^CELL_SHIFT
//
//  ── 叠图规则（B 那边照着抄就行）──
//      wire        m   = hist_mask | freq_mask;
//      wire [23:0] c   = hist_mask ? hist_color : freq_color;
//      wire        dim = (hist_band | freq_band) & ~m;
//
//      rgb_out = m   ? c
//              : dim ? {1'b0, rgb_in[23:1]}     // 矩形内没被柱子盖住 → 压暗一半
//              :       rgb_in;
//
//  ★ viz_time / viz_freq 都是【只旁听】aud_dout，绝不会去碰 aud_next，
//    和 sfx_player 共用同一路音频流没有任何冲突
//  ★★★ 声明全部前置
//==========================================================================
module viz_top #(
    // ---------------- 时域历史（音量柱）----------------
    parameter integer HIST_N     = 32,
    parameter [9:0]   HIST_X     = 10'd16,
    parameter [9:0]   HIST_Y     = 10'd392,
    parameter [9:0]   HIST_H     = 10'd64,
    parameter integer HIST_WIN   = 1500,      // 每根柱子统计多少次 aud_vld
    parameter [5:0]   HIST_GAIN  = 6'd16,     // ★ 实测：61% 的帧会顶到 63，
                                              //   想留余量就改 10（中位数 39/最高 53）
    parameter integer HIST_DECAY = 36571,     // 满格 6 秒掉光 @12.288MHz

    // ---------------- 频域频谱 ----------------
    parameter integer FREQ_N     = 24,
    parameter [9:0]   FREQ_X     = 10'd16,
    parameter [9:0]   FREQ_Y     = 10'd312,
    parameter [9:0]   FREQ_H     = 10'd64,
    parameter integer FREQ_WIN   = 2048,      // 2048/48000 = 42.7ms ≈ 23fps
    parameter integer FREQ_BIAS  = 16,        // ★ 实测：谱峰落在 42 级，+16 → 58
    parameter integer FREQ_DECAY = 48761,

    // ---------------- 共用外观 ----------------
    parameter integer CELL_SHIFT = 3,         // 柱宽 8px
    parameter integer GAP        = 1,         // 柱间空隙 1px
    parameter [3:0]   PEAK_SLOW  = 4'd4,      // 峰值回落比柱子慢 4 倍
    parameter [7:0]   COL_B      = 8'd24      // 柱子的蓝色分量（24 偏冷黑）
)(
    // ---------------- A 轨接这边（音频域）----------------
    input  wire        clk_aud,
    input  wire        rst_aud_n,
    input  wire        aud_vld,       // ★ 电平：手里有字就一直是 1
    input  wire [31:0] aud_dout,
    input  wire        aud_next,      // ★ 单拍：消费端取走那一拍（只读，不驱动）

    // ---------------- B 轨接这边（像素域）----------------
    input  wire        de,
    input  wire [9:0]  x,
    input  wire [9:0]  y,

    output wire        hist_mask,
    output wire        hist_band,
    output wire [23:0] hist_color,

    output wire        freq_mask,
    output wire        freq_band,
    output wire [23:0] freq_color,

    // ---------------- 诊断（可不接）----------------
    output wire [15:0] dbg_freq_win,
    output wire        dbg_freq_dump
);

    //======================================================================
    //  ① 时域：音量历史
    //======================================================================
    wire        h_wr_en;
    wire [4:0]  h_wr_addr;
    wire [5:0]  h_wr_val;

    viz_time #(
        .N       (HIST_N),
        .SMP_WIN (HIST_WIN),
        .GAIN    (HIST_GAIN)
    ) u_hist (
        .clk_aud   (clk_aud),
        .rst_aud_n (rst_aud_n),
        .aud_vld   (aud_vld),
        .aud_dout  (aud_dout),
        .aud_next  (aud_next),      // ★
        .wr_en     (h_wr_en),
        .wr_addr   (h_wr_addr),
        .wr_val    (h_wr_val),
        .dbg_addr  (),
        .dbg_peak  (),
        .dbg_cnt   ()
    );

    viz_render #(
        .N          (HIST_N),
        .CELL_SHIFT (CELL_SHIFT),
        .VIS_X      (HIST_X),
        .VIS_Y      (HIST_Y),
        .BAR_H      (HIST_H),
        .DECAY_DIV  (HIST_DECAY),
        .PEAK_SLOW  (PEAK_SLOW),
        .GAP        (GAP),
        .COL_B      (COL_B)
    ) u_hist_draw (
        .clk_aud   (clk_aud),
        .rst_aud_n (rst_aud_n),
        .wr_en     (h_wr_en),
        .wr_addr   (h_wr_addr),
        .wr_val    (h_wr_val),
        .de        (de),
        .x         (x),
        .y         (y),
        .mask      (hist_mask),
        .in_band   (hist_band),
        .color     (hist_color)
    );

    //======================================================================
    //  ② 频域：24 段频谱（对数刻度）
    //======================================================================
    wire        f_wr_en;
    wire [4:0]  f_wr_addr;
    wire [5:0]  f_wr_val;

    viz_freq #(
        .N        (FREQ_N),
        .SMP_WIN  (FREQ_WIN),
        .LOG_BIAS (FREQ_BIAS)
    ) u_freq (
        .clk_aud   (clk_aud),
        .rst_aud_n (rst_aud_n),
        .aud_vld   (aud_vld),
        .aud_dout  (aud_dout),
        .aud_next  (aud_next),      // ★
        .wr_en     (f_wr_en),
        .wr_addr   (f_wr_addr),
        .wr_val    (f_wr_val),
        .dbg_win   (dbg_freq_win),
        .dbg_dump  (dbg_freq_dump),
        .dbg_hi    ()
    );

    viz_render #(
        .N          (FREQ_N),
        .CELL_SHIFT (CELL_SHIFT),
        .VIS_X      (FREQ_X),
        .VIS_Y      (FREQ_Y),
        .BAR_H      (FREQ_H),
        .DECAY_DIV  (FREQ_DECAY),
        .PEAK_SLOW  (PEAK_SLOW),
        .GAP        (GAP),
        .COL_B      (COL_B)
    ) u_freq_draw (
        .clk_aud   (clk_aud),
        .rst_aud_n (rst_aud_n),
        .wr_en     (f_wr_en),
        .wr_addr   (f_wr_addr),
        .wr_val    (f_wr_val),
        .de        (de),
        .x         (x),
        .y         (y),
        .mask      (freq_mask),
        .in_band   (freq_band),
        .color     (freq_color)
    );

endmodule
