 //==========================================================================
  //  viz_time —— 时域：从音频采样流算【音量历史】
  //==========================================================================
  //
  //  接在 aud_blk_rd 的输出上（音频域 12.288 MHz）：
  //      aud_dout[31:0] = {前一个采样[31:16], 后一个采样[15:0]}
  //
  //  ── ★★★ 握手（2026-10-16 修正：原来那句"aud_vld 是单拍"是错的）──
  //      aud_vld   是【电平】—— 手里有字就一直是 1，**不是单拍脉冲**
  //      aud_next  是【单拍】—— 消费端取走那一拍
  //                （12.288 MHz ÷ 512 = 24 kHz 字率 = 48 kHz 采样率 ÷ 2）
  //  ⇒ 真正"来了一个新字"的事件 = aud_vld & aud_next
  //     ✗ 拿 aud_vld 当脉冲用 → 窗口快 512 倍（62.5ms 变 122µs）→ 柱子乱跳
  //
  //  ★★★ 三个信号全部【只读】，绝不置 aud_next！
  //      驱动 aud_next = 重复消费 ⇒ 音频直接断掉 ✗
  //
  //  ── 参数 ───────────────────────────────────────────────────
  //    N        柱子数（必须和 viz_render 的 N 一致）
  //    SMP_WIN  每根柱子统计多少个"字"
  //             ★ 一个"字" = (aud_vld & aud_next) 那一拍 = 2 个采样
  //             ⇒ 一屏时长 = N × SMP_WIN × 2 / 48000 秒
  //                默认 N=32, SMP_WIN=1500 → 32×1500×2/48000 = 2.0 秒
  //                想要 1.0 秒就把 SMP_WIN 改成 750
  //    GAIN     线性映射的增益（音乐太矮就调大）
  //
  //  ★★★ 声明全部前置
  //==========================================================================
  module viz_time #(
      parameter integer N       = 32,
      parameter integer SMP_WIN = 1500,
      parameter [5:0]   GAIN    = 6'd16
  )(
      input  wire        clk_aud,
      input  wire        rst_aud_n,

      // ---- 音频采样流（从 aud_blk_rd 来，★ 只读）----
      input  wire        aud_vld,       // ★ 电平：手里有字就一直是 1
      input  wire [31:0] aud_dout,
      input  wire        aud_next,      // ★ 单拍：消费端取走那一拍

      // ---- 输出给 viz_render 的 wr_* ----
      output reg         wr_en,
      output reg  [4:0]  wr_addr,
      output reg  [5:0]  wr_val,

      // ---- 诊断 ----
      output wire [4:0]  dbg_addr,
      output wire [5:0]  dbg_peak,
      output wire [15:0] dbg_cnt
  );

      localparam [4:0]  N_M1   = N - 1;
      localparam [15:0] WIN_M1 = SMP_WIN - 1;
      localparam [5:0]  V_MAX  = 6'd63;

      reg  [15:0] win_cnt;
      reg  [4:0]  cur_addr;
      reg  [5:0]  win_peak;

      reg  [15:0] smp_a, smp_b;
      reg  [15:0] mag_a, mag_b;
      reg  [15:0] mag;

      // ★★★ BUG 修复：原来只有 6 位的 mag6 直接装 7 位+6 位的和，
      //     Verilog 会先把和截到 6 位再比较 ⇒ 饱和那句永远不成立。
      //     满量程时 64+16=80，截成 6 位 = 16 ⇒ 音量一大柱子反而塌回去！
      //     现在先算到 8 位（够放 64+63=127），再饱和。
      reg  [7:0]  mag8;
      reg  [5:0]  mag6;

      // ★★★ 真正"来了一个新字"的事件。aud_vld 是【电平】不能当脉冲用！
      wire wr_stb = aud_vld & aud_next;

      assign dbg_addr = cur_addr;
      assign dbg_peak = win_peak;
      assign dbg_cnt  = win_cnt;

      // 绝对值（补码取负；-32768 → 32768 用 16 位无符号正好表示）
      // 高度 = |采样| 的高 7 位 + GAIN，饱和到 63
      always @(*) begin
          smp_a = aud_dout[31:16];
          smp_b = aud_dout[15:0];
          mag_a = smp_a[15] ? (~smp_a + 16'd1) : smp_a;
          mag_b = smp_b[15] ? (~smp_b + 16'd1) : smp_b;
          mag   = (mag_a > mag_b) ? mag_a : mag_b;

          mag8 = {2'b00, mag[15:9]} + GAIN;              // ★ 9 位域算，不会截断
          mag6 = (mag8 > 8'd63) ? 6'd63 : mag8[5:0];     // ★ 先比较，后饱和
      end

      always @(posedge clk_aud or negedge rst_aud_n) begin
          if (!rst_aud_n) begin
              win_cnt  <= 16'd0;
              cur_addr <= 5'd0;
              win_peak <= 6'd0;
              wr_en    <= 1'b0;
              wr_addr  <= 5'd0;
              wr_val   <= 6'd0;
          end
          else begin
              wr_en <= 1'b0;                                 // 单拍脉冲

              if (wr_stb) begin
                  if (mag6 > win_peak) win_peak <= mag6;

                  if (win_cnt >= WIN_M1) begin
                      win_cnt  <= 16'd0;
                      wr_en    <= 1'b1;
                      wr_addr  <= cur_addr;
                      wr_val   <= (mag6 > win_peak) ? mag6 : win_peak;  // 含本拍
                      win_peak <= 6'd0;
                      cur_addr <= (cur_addr >= N_M1) ? 5'd0 : cur_addr + 5'd1;
                  end
                  else
                      win_cnt <= win_cnt + 16'd1;
              end
          end
      end

  endmodule