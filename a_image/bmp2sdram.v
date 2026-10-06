// ============================================================
//  bmp2sdram（A 轨的装载机第二级）—— 两两打包 + 写进 SDRAM
//
//  ★ 2026-09-28 集成临时改动（见 规划\A轨待改清单.md 第 0 条）：
//    写口换成原厂 `frame_fifo_write` 的协议（B 侧 sdr_arb 用的就是它）：
//      1) 请求：摆好 sdr_base（这一段从哪写）和 sdr_len（这一段多少个字），
//               把 sdr_req 举着，直到看见 sdr_ack
//      2) 推数据：sdr_data + sdr_we 一个字一个字推（满了看 a_wr_full）
//      3) 收尾：等 sdr_done 一拍脉冲 = 这段真的写进 SDRAM 了
//    ★ 新增输入 frame_words：这一帧一共多少个字（= (W*H+1)/2），上层给。
//      原厂引擎必须先知道长度才开工。
//  ★ 删掉的东西：sdr_dm（半字写）、sdr_addr（地址由 B 自己数）、req/ack 四相握手。
// ============================================================
module bmp2sdram (
      input             sys_clk,
      input             sys_rst_n,

      // ★ 帧缓冲基址（字地址）—— 由上层在 start 那一刻锁存后传进来
      input      [20:0] frame_base,
      // ★ 这一帧一共多少个字（= (宽*高+1)/2）—— 原厂引擎要先知道长度
      input      [20:0] frame_words,

      // ---- 从 bmp_analyze 来 ----
      input             px_we,
      input      [31:0] px_addr,
      input      [15:0] px_data,
      input             img_done,

      // ---- 去 sdr_arb 的写口（原厂协议）----
      output reg        sdr_req,        // 举着，直到 sdr_ack
      output reg [20:0] sdr_base,
      output reg [20:0] sdr_len,
      input             sdr_ack,
      output reg [31:0] sdr_data,
      output reg        sdr_we,
      input             a_wr_full,
      input             sdr_done,       // 引擎写完这一段
      input             sdr_ready,

      // ---- 状态回报 ----
      output reg        frame_done,
      output reg        busy,

      // ---- 诊断 ----
      output reg [31:0] wr_cnt,
      output reg        warn_overrun,
      output reg        warn_odd
  );

      localparam [1:0] S_IDLE = 2'd0, S_REQ = 2'd1, S_PUSH = 2'd2, S_WAIT = 2'd3;

      reg  [1:0]  st;
      reg  [15:0] px_lo;
      reg         pair2_ready;    // ★ 集成临时改动：第二级暂存（见 A轨待改清单 第 8 条）
      reg  [31:0] sdr_data2;
      reg         pair_ready;      // 攒着一对像素，等推
      reg         last_px_even;

      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n) begin
              st           <= S_IDLE;
              sdr_req      <= 1'b0;
              sdr_base     <= 21'd0;
              sdr_len      <= 21'd0;
              sdr_data     <= 32'd0;
              sdr_we       <= 1'b0;
              px_lo        <= 16'd0;
              pair_ready   <= 1'b0;
              pair2_ready  <= 1'b0;
              last_px_even <= 1'b0;
              frame_done   <= 1'b0;
              busy         <= 1'b0;
              wr_cnt       <= 32'd0;
              warn_overrun <= 1'b0;
              warn_odd     <= 1'b0;
          end
          else begin
              frame_done <= 1'b0;
              sdr_we     <= 1'b0;              // 默认不给脉冲

              busy <= (st != S_IDLE) | pair_ready;

              if (px_we && px_addr[0]) last_px_even <= 1'b0;
              if (px_we) begin
                  if (px_addr[0] == 1'b0) px_lo <= px_data;   // 偶数序号：暂存
              end
              // 图完了、最后一个像素没配对（奇数个像素）→ 报一声
              if (img_done && (px_addr[0] == 1'b0)) warn_odd <= 1'b1;

              case (st)
              // ---------- 空闲：等第一对像素，然后发请求 ----------
              S_IDLE: begin
                  sdr_req <= 1'b0;
                  if (px_we && (px_addr[0] == 1'b1) && sdr_ready) begin
                      // ★★ 2026-09-28 修：这里只要【槽基址】！
                      //   原来写成 frame_base + px_addr[20:1] —— 那是"第 1 个像素的绝对
                      //   字地址"。A 输出的第 1 个像素是显示方向的左上角，它的像素序号是
                      //   (H-1)*W = 479*640 = 306560、字地址 153280，于是整段图从 153280
                      //   开始写，基址 0 一直空着（留着开机自测图的残余 → 屏上永远是格子图）。
                      //   段内偏移由 sdr_arb 自己数（base + k），这里给槽基址就行。
                      sdr_base   <= frame_base;
                      sdr_len    <= frame_words;
                      sdr_req    <= 1'b1;
                      sdr_data   <= {px_lo, px_data};   // [31:16] 是靠前那个
                      pair_ready <= 1'b1;
                      wr_cnt     <= 32'd0;
                      st         <= S_REQ;
                  end
              end

              // ---------- 等引擎受理（受理时会清 FIFO，所以这时别推）----------
              S_REQ: begin
                  if (sdr_ack) begin
                      sdr_req <= 1'b0;
                      st      <= S_PUSH;
                  end
              end

              // ---------- 推数据：一对像素一个字 ----------
              S_PUSH: begin
                  // ★★ 集成临时改动（见 规划\A轨待改清单.md 第 8 条）：
                  //   原来的写法是"上一个字还没推出去时，新来的一对像素【直接丢掉】"
                  //   （只置 warn_overrun）。上板实测这就是"每 1024 字有一个地址
                  //   从没被写过、留下一版旧图内容"的根因。
                  //   改成【两级暂存】：FIFO 偶尔满一下就多存一个字，不再丢数据；
                  //   只有两级都满（真顶不住）才报 warn_overrun。
                  if (px_we && (px_addr[0] == 1'b1)) begin
                      if (!pair_ready) begin
                          sdr_data    <= {px_lo, px_data};
                          pair_ready  <= 1'b1;
                      end
                      else if (!pair2_ready) begin
                          sdr_data2   <= {px_lo, px_data};
                          pair2_ready <= 1'b1;
                      end
                      else warn_overrun <= 1'b1;   // 两级都满（FIFO 长时间满）
                  end

                  // 有存货、FIFO 不满 → 推一个字；推完把二级挪进一级
                  if (pair_ready && !a_wr_full) begin
                      sdr_we     <= 1'b1;
                      wr_cnt     <= wr_cnt + 32'd1;
                      if (pair2_ready) begin
                          sdr_data    <= sdr_data2;
                          pair2_ready <= 1'b0;
                      end
                      else pair_ready <= 1'b0;
                  end

                  // 推满了这一帧的字数 → 等引擎写完
                  // 推够了就收尾；万一引擎已经报了 finish（也可能比我们推得快），
                  // 也直接算完成，免得卡在"FIFO 满"上
                  if ((wr_cnt >= {10'd0, frame_words}) || sdr_done) begin
                      st <= S_WAIT;
                  end
              end

              // ---------- 等引擎给出 write_finish ----------
              S_WAIT: begin
                  if (sdr_done) begin
                      frame_done   <= 1'b1;
                      st           <= S_IDLE;
                  end
              end
              endcase
          end
      end

  endmodule

