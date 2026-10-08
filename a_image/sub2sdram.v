    // ============================================================
      //  sub2sdram（A 轨字幕装载第三级）—— 遮罩字写进 SDRAM 字幕区
      //
      //  和 wav2sdram 是【同一个套路】，区别只有两处：
      //    1) 输入换成 sub_analyze 的遮罩字流（mask_we / mask_data）
      //    2) ★★ 不用配对！sub_analyze 吐出来的【已经是完整的 32 位字】，
      //       不像 wav 那样要两两拼（没有奇偶、没有落单采样）
      //
      //  写口协议和 bmp2sdram / wav2sdram 完全一样（原厂 frame_fifo_write 那套）：
      //    举 sdr_base + sdr_len + sdr_req  →  等 sdr_ack
      //      →  用 sdr_we + sdr_data 推字（满了看 a_wr_full）
      //      →  等 sdr_done
      //
      //  ★ 地址：字幕区里【顺序】放，第 N 个字就写 sub_base + N
      //     （不像图像那样要按行序映射 —— 遮罩的存储顺序天生就是
      //       "BMP 自下而上"，叠加时用 63-y 反一下即可）
      //
      //  ★ 两级暂存（pair_ready / pair2_ready）和 wav2sdram 一模一样，
      //    用来兜住两个窗口：
      //      ① 第一个字在【等 ack】期间到达
      //      ② FIFO 偶尔满一下
      //    实际上 mask_we 每 ~3000 拍才来一个，远慢于写口（1 字/拍），
      //    所以 warn_overrun 正常【永远不该亮】
      //
      //  ★★★ 引擎已经报过 finish 时【就地完成】，不能进 S_WAIT ——
      //       sdr_done 是单拍脉冲，进 S_WAIT 就再也等不到了
      //
      //  ★★★ 声明全部前置（这个工程踩过五次"先用后声明"）
      // ============================================================
      module sub2sdram (
          input             sys_clk,
          input             sys_rst_n,

          // ★ 这一条字幕写到哪
          input      [20:0] sub_base,       // 字幕区基址 + 条号×STRIDE（字地址）
          // ★ 这一条多少个字（契约里 = 1600）—— 引擎要先知道长度
          input      [20:0] sub_words,

          // ---- 从 sub_analyze 来 ----
          input             mask_we,        // 单拍：一个完整的 32 位遮罩字
          input      [31:0] mask_data,
          input      [31:0] mask_idx,       // 第几个字（诊断用，正常 0..1599）
          input             mask_done,      // 1600 个字吐完了

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
          output reg        sub_wr_done,    // 单拍：这一条写进 SDRAM 了
          output reg        busy,

          // ---- 诊断 ----
          output reg [31:0] wr_cnt,
          output reg        warn_overrun,   // 两级暂存都满了（正常不亮）
          output reg        warn_short      // 分析侧提前收工 / 字数对不上（正常不亮）
      );

          localparam [1:0] S_IDLE = 2'd0, S_REQ = 2'd1, S_PUSH = 2'd2, S_WAIT = 2'd3;

          // ★ 声明全部前置
          reg  [1:0]  st;
          reg  [31:0] sdr_data2;      // 二级暂存（名字和 wav2sdram 保持一致）
          reg         pair2_ready;
          reg         pair_ready;

          always @(posedge sys_clk or negedge sys_rst_n) begin
              if (!sys_rst_n) begin
                  st            <= S_IDLE;
                  sdr_req       <= 1'b0;
                  sdr_base      <= 21'd0;
                  sdr_len       <= 21'd0;
                  sdr_data      <= 32'd0;
                  sdr_we        <= 1'b0;
                  sdr_data2     <= 32'd0;
                  pair_ready    <= 1'b0;
                  pair2_ready   <= 1'b0;
                  sub_wr_done   <= 1'b0;
                  busy          <= 1'b0;
                  wr_cnt        <= 32'd0;
                  warn_overrun  <= 1'b0;
                  warn_short    <= 1'b0;
              end
              else begin
                  sub_wr_done <= 1'b0;
                  sdr_we      <= 1'b0;              // 默认不给脉冲

                  busy <= (st != S_IDLE) | pair_ready | pair2_ready;

                  // 分析侧提前收工 → 字数对不上，报一声（正常不亮）
                  if (mask_done && (mask_idx != (sub_words - 21'd1)))
                      warn_short <= 1'b1;

                  case (st)
                  // ---------- 空闲：等第一个字，然后发请求 ----------
                  S_IDLE: begin
                      sdr_req <= 1'b0;
                      if (mask_we && sdr_ready) begin
                          sdr_base    <= sub_base;          // ★ 段内偏移由引擎自己数
                          sdr_len     <= sub_words;
                          sdr_req     <= 1'b1;
                          sdr_data    <= mask_data;         // ★ 已经是完整的字，不用拼
                          pair_ready  <= 1'b1;
                          wr_cnt      <= 32'd0;
                          st          <= S_REQ;
                      end
                  end

                  // ---------- 等引擎受理（受理时会清 FIFO，这时别推）----------
                  S_REQ: begin
                      if (sdr_ack) begin
                          sdr_req <= 1'b0;
                          st      <= S_PUSH;
                      end
                  end

                  // ---------- 推数据：一个 mask_we 就是一个字 ----------
                  S_PUSH: begin
                      // 两级暂存：FIFO 偶尔满一下就多存一个字，不丢数据
                      if (mask_we) begin
                          if (!pair_ready) begin
                              sdr_data    <= mask_data;
                              pair_ready  <= 1'b1;
                          end
                          else if (!pair2_ready) begin
                              sdr_data2   <= mask_data;
                              pair2_ready <= 1'b1;
                          end
                          else warn_overrun <= 1'b1;    // 两级都满（正常不会）
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

                      // 推够了这一条的字数 → 等引擎收尾
                      // ★ 引擎已经报过 finish 时【就地完成】，不能进 S_WAIT
                      //   （sdr_done 是单拍脉冲，进 S_WAIT 就再也等不到了）
                      if (sdr_done) begin
                          sub_wr_done <= 1'b1;
                          st          <= S_IDLE;
                      end
                      else if (wr_cnt >= {11'd0, sub_words}) begin
                          st <= S_WAIT;
                      end
                  end

                  // ---------- 等引擎给出 write_finish ----------
                  S_WAIT: begin
                      if (sdr_done) begin
                          sub_wr_done <= 1'b1;
                          st          <= S_IDLE;
                      end
                  end
                  endcase
              end
          end

      endmodule