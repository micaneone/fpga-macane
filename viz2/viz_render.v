//==========================================================================
  //  viz_render —— 通用【柱状图渲染器】（时域 / 频域共用）
  //==========================================================================
  //  ① 存 N 根柱子的高度（reg 阵列，组合读 → 分布式 RAM）
  //  ② 维护：缓降 + 峰值（比柱子慢 PEAK_SLOW 倍回落）
  //  ③ 渲染：按像素坐标出 mask / in_band / color
  //
  //  ★★★ 输出【不碰 rgb】—— 只出 mask + color：
  //        assign rgb_out = mask ? color : (in_band ? 压暗 : rgb_in);
  //
  //  ★ 颜色按【高度】渐变：绿 → 黄 → 红（专业电平表的做法）
  //  ★ 零乘法、零除法 —— 全靠移位和减法
  //
  //  ★★★ 时钟域（★ 这是本模块唯一需要想清楚的地方）
  //    · 【写 + 维护】用 clk_aud —— wr_* 是音频域产生的，同域省掉跨域握手
  //    · 【渲染】是纯组合 —— x/y/mask/color 都是组合逻辑，不涉及时钟
  //    ⇒ 代价：bar[]/peak[] 是"音频域写、像素域组合读"，理论上可能撕裂，
  //       但每 122µs 才写一次、只有 6 位 ⇒ 后果是某一根柱子瞬时差 1 像素，
  //       人眼完全看不出。**要更严格**就改成双口 BRAM + 独立读写口。
  //
  //  ── 参数 ───────────────────────────────────────────────────
  //    N          柱子数（≤32）
  //    CELL_SHIFT 柱宽 = 2^CELL_SHIFT 像素 ★ 必须 2 的幂（算列号靠移位）
  //    VIS_X/Y    显示区左上角（★ 位置由调用者定）
  //    BAR_H      显示区高度（像素）★ 必须 ≥ 63（柱高是 6 位 = 0..63）
  //    DECAY_DIV  缓降：每多少拍降 1（★ 按 clk_aud=12.288MHz 算）
  //               想让满格(63) 6 秒掉光：12.288e6×6/(N×63) ≈ 36571
  //    PEAK_SLOW  峰值回落比柱子慢几倍
  //    GAP        柱间空隙（像素）
  //
  //  ★★★ 声明全部前置
  //==========================================================================
  module viz_render #(
      parameter integer N          = 32,
      parameter integer CELL_SHIFT = 3,            // 柱宽 = 8 px
      parameter [9:0]   VIS_X      = 10'd16,
      parameter [9:0]   VIS_Y      = 10'd440,
      parameter [9:0]   BAR_H      = 10'd64,       // ★改1：原来是 parameter integer，
                                                   //   下面要对它做位选，严格 Verilog-2001
                                                   //   不允许对 integer 位选，改成 10 位向量
      parameter integer DECAY_DIV  = 36571,        // ★ 按 clk_aud 算的
      parameter [3:0]   PEAK_SLOW  = 4'd4,
      // ★★★ 2026-10-18【浮标（峰值点）想落得更快】：PEAK_FAST > 0 时**不再**用
      //   `DECAY_DIV×PEAK_SLOW`，而是 `DECAY_DIV >> PEAK_FAST`（比柱子还快）。
      //   0 = 保持老行为（浮标比柱子慢 PEAK_SLOW 倍），对 viz_top.v 完全向后兼容。
      //   1 ⇒ 浮标降落速度 = 柱子的 2 倍；2 ⇒ 4 倍。
      //   ★ 用参数做 `localparam` ⇒ 综合时是常数，**不产生任何额外逻辑**。
      parameter [3:0]   PEAK_FAST  = 4'd0,
      // ★★★ 2026-10-19【浮标速度改成"直接给秒数"】：`PEAK_DIV` > 0 时**直接指定**
      //   浮标回落周期（单位：clk_aud 拍），把上面两个参数整个覆盖掉。
      //   原因：柱子 2 s、浮标 1 s"太快"、4 s"太慢"，而 `×PEAK_SLOW` / `>>PEAK_FAST`
      //   只能给出 1×/2×/4× 这几档 ⇒ 加一个绝对量参数，想要几秒就给几秒：
      //       满格落地秒数 ≈ 63 × N × PEAK_DIV / 12.288e6
      //       （N=32 ⇒ PEAK_DIV ≈ 6095×秒；N=24 ⇒ 8127×秒）
      //   0 = 不用它（沿用 PEAK_SLOW / PEAK_FAST 的老口径），对 viz_top.v 向后兼容。
      parameter integer PEAK_DIV   = 0,
      parameter integer GAP        = 1,
      // ★★★ 2026-10-20【柱高缩放】：`h_draw = (h_bar >> H_SHIFT) | 1`。
      //   用途：`BAR_H` 里 `dy >= BAR_H - h_draw` 是 6 位比较，BAR_H 小于 64 会下溢，
      //   所以"音谱占屏高"只能靠缩波形，不能靠把 BAR_H 改小。
      //   H_SHIFT=0 = 原样；1 = 满格 31 px；2 = 15 px。纯移位，**零逻辑**。
      parameter integer H_SHIFT    = 0,
      parameter [7:0]   COL_B      = 8'd24
  )(
      // ---- ★ 写/维护在音频域 ----
      input  wire        clk_aud,
      input  wire        rst_aud_n,

      input  wire        wr_en,
      input  wire [4:0]  wr_addr,
      input  wire [5:0]  wr_val,

      // ---- 渲染在像素域（纯组合，不涉及时钟）----
      input  wire        de,
      input  wire [9:0]  x,
      input  wire [9:0]  y,

      output reg         mask,
      output reg         in_band,
      output reg  [23:0] color
  );

      //======================================================================
      //  ★ 常量
      //======================================================================
      localparam integer CELL   = (1 << CELL_SHIFT);
      localparam [9:0]   BAND_W = N * CELL;        // ★改2：原来是 localparam integer
                                                   //   同样是为了后面不做位选
      localparam [4:0]   N_M1   = N - 1;
      localparam [9:0]   X_END  = VIS_X + BAND_W;  // ★改2：去掉 BAND_W[9:0]
      localparam [9:0]   Y_END  = VIS_Y + BAR_H;   // ★改1：去掉 BAR_H[9:0]

      localparam [31:0]  DECAY_DIV32 = DECAY_DIV;              // ★ 不截断
      // ★ 峰值回落周期：优先用绝对量 `PEAK_DIV`（>0）；
      //   否则 PEAK_FAST=0 沿用"比柱子慢 PEAK_SLOW 倍"，PEAK_FAST>0 取 `DECAY_DIV >> PEAK_FAST`
      localparam [31:0]  PEAK_DIV32  = (PEAK_DIV != 0)
                                     ? PEAK_DIV
                                     : ((PEAK_FAST == 4'd0)
                                        ? (DECAY_DIV * PEAK_SLOW)
                                        : (DECAY_DIV >> PEAK_FAST));

      //======================================================================
      //  ★ 数据存储
      //======================================================================
      reg [5:0] bar  [0:N-1];
      reg [5:0] peak [0:N-1];

      reg [31:0] dec_cnt;
      reg [4:0]  dec_ptr;
      reg [31:0] pk_cnt;
      reg [4:0]  pk_ptr;

      //======================================================================
      //  ★ 渲染用的组合量（全部前置）
      //======================================================================
      reg  [9:0]  dx, dy;
      reg         in_rect;
      reg  [4:0]  ci;
      reg  [5:0]  h_bar, h_peak, h_draw, h_pk_s;
      reg         gap_hit;
      reg         is_bar, is_peak;
      reg  [5:0]  c_lvl;
      reg  [23:0] c_out;

      //======================================================================
      //  维护（★ 缓降在前、写入在后 → 冲突时新值赢）
      //======================================================================
      integer i;
      always @(posedge clk_aud or negedge rst_aud_n) begin
          if (!rst_aud_n) begin
              for (i = 0; i < N; i = i + 1) begin
                  bar[i]  <= 6'd0;
                  peak[i] <= 6'd0;
              end
              dec_cnt <= 32'd0;  dec_ptr <= 5'd0;
              pk_cnt  <= 32'd0;  pk_ptr  <= 5'd0;
          end
          else begin
              // ① 缓降：每 DECAY_DIV 拍降 dec_ptr 那根 1
              if (dec_cnt >= DECAY_DIV32) begin
                  dec_cnt <= 32'd0;
                  if (bar[dec_ptr] != 6'd0)
                      bar[dec_ptr] <= bar[dec_ptr] - 6'd1;
                  dec_ptr <= (dec_ptr >= N_M1) ? 5'd0 : dec_ptr + 5'd1;
              end
              else dec_cnt <= dec_cnt + 32'd1;

              // ② 峰值回落：每 DECAY_DIV×PEAK_SLOW 拍降一根
              if (pk_cnt >= PEAK_DIV32) begin
                  pk_cnt <= 32'd0;
                  if (peak[pk_ptr] != 6'd0)
                      peak[pk_ptr] <= peak[pk_ptr] - 6'd1;
                  pk_ptr <= (pk_ptr >= N_M1) ? 5'd0 : pk_ptr + 5'd1;
              end
              else pk_cnt <= pk_cnt + 32'd1;

              // ③ 写入（放最后 → 新值赢）
              if (wr_en) begin
                  if (wr_val > bar[wr_addr])  bar[wr_addr]  <= wr_val;
                  if (wr_val > peak[wr_addr]) peak[wr_addr] <= wr_val;
              end
          end
      end

      //======================================================================
      //  渲染（纯组合）
      //======================================================================
      always @(*) begin
          in_rect = de &&
                    (x >= VIS_X) && (x < X_END) &&
                    (y >= VIS_Y) && (y < Y_END);

          dx = x - VIS_X;
          dy = y - VIS_Y;

          ci      = dx >> CELL_SHIFT;
          gap_hit = (dx[CELL_SHIFT-1:0] >= (CELL - GAP)) ? 1'b1 : 1'b0;

          h_bar  = bar [ci];
          h_peak = peak[ci];

          h_draw = (h_bar == 6'd0) ? 6'd1 : ((h_bar >> H_SHIFT) | 6'd1);   // ★ 地平线 + 柱高缩放
          h_pk_s = (h_peak == 6'd0) ? 6'd0 : ((h_peak >> H_SHIFT) | 6'd1); // ★ 浮标同比例

          // ★ 2026-10-20【带高可以小于 64 了】：`dy >= BAR_H - h_draw` 是 10 位减法，
          //   h_draw > BAR_H 会下溢成一个大数（柱子直接铺满整带，看着像"卡满"）。
          //   这里把 h_draw 钳到 BAR_H-1，满格就正好顶到带顶，不再靠下溢兜。
          if (h_draw > (BAR_H[5:0] - 6'd1)) h_draw = BAR_H[5:0] - 6'd1;
          if (h_pk_s > (BAR_H[5:0] - 6'd1)) h_pk_s = BAR_H[5:0] - 6'd1;

          is_bar = in_rect && !gap_hit &&
                   (dy >= (BAR_H - {4'd0, h_draw}));    // ★改1：BAR_H 直接是 10 位

          is_peak = in_rect && !gap_hit && (h_pk_s != 6'd0) &&
                    (dy == (BAR_H - {4'd0, h_pk_s} - 10'd1));   // ★改1

          c_lvl = is_bar ? h_bar : 6'd0;
          c_out = { c_lvl[5] ? 8'hFF : {c_lvl[4:0], 3'b000},
                    c_lvl[5] ? {~c_lvl[4:0], 3'b000} : 8'hFF,
                    COL_B };

          in_band = in_rect;
          mask    = is_bar || is_peak;
          color   = is_peak ? 24'hFFFFC0 : c_out;
      end

  endmodule