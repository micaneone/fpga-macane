// ============================================================
  //  wav2sdram（A 轨音频装载第二级）—— 两两打包 + 写进 SDRAM 音效区
  //
  //  和 bmp2sdram 是【同一个套路】，区别只有三处：
  //    1) 输入换成 wav_analyze 的采样流（smp_we / smp_idx / smp_data）
  //    2) 基址是【音效区基址 + 条号×STRIDE】，不是图像槽基址
  //    3) 长度是【采样数/2】，不是 W*H/2
  //
  //  写口协议和 bmp2sdram 完全一样（原厂 frame_fifo_write 那套）：
  //    举 sdr_base + sdr_len + sdr_req  →  等 sdr_ack
  //      →  用 sdr_we + sdr_data 推字（满了看 a_wr_full）
  //      →  等 sdr_done
  //
  //  ★ 拼字顺序：{靠前(低序号)那个, 靠后那个}
  //       [31:16] = 前一个采样   [15:0] = 后一个采样
  //     和契约"一个字装两个 16bit"一致
  //
  //  ★ 采样数是奇数时：最后一个采样落单，不会推出去，
  //    同时 warn_odd 会亮。长度按【向下取整】算（采样数>>1），
  //    这样"告诉引擎的长度"和"实际推的字数"严格相等，不会卡死。
  // ============================================================
  module wav2sdram (
        input             sys_clk,
        input             sys_rst_n,

        // ★ 这一条音效写到哪
        input      [20:0] sfx_base,       // 音效区基址 + 条号×STRIDE（字地址）
        // ★ 这一条多少个字（= 采样数>>1，向下取整）—— 引擎要先知道长度
        input      [20:0] sfx_words,

        // ---- 从 wav_analyze 来 ----
        input             smp_we,
        input      [31:0] smp_idx,        // 采样序号（只用 [0] 判奇偶）
        input      [15:0] smp_data,
        input             smp_done,       // 采样吐完了

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
        output reg        wav_wr_done,    // 单拍：这一条写进 SDRAM 了
        output reg        busy,

        // ---- 诊断 ----
        output reg [31:0] wr_cnt,
        output reg        warn_overrun,
        output reg        warn_odd
    );

        localparam [1:0] S_IDLE = 2'd0, S_REQ = 2'd1, S_PUSH = 2'd2, S_WAIT = 2'd3;

        reg  [1:0]  st;
        reg  [15:0] smp_lo;
        reg  [31:0] sdr_data2;      // ★ 二级暂存（名字和 bmp2sdram 保持一致）
        reg         pair2_ready;
        reg         pair_ready;
        reg         last_smp_even;

        always @(posedge sys_clk or negedge sys_rst_n) begin
            if (!sys_rst_n) begin
                st            <= S_IDLE;
                sdr_req       <= 1'b0;
                sdr_base      <= 21'd0;
                sdr_len       <= 21'd0;
                sdr_data      <= 32'd0;
                sdr_we        <= 1'b0;
                smp_lo        <= 16'd0;
                pair_ready    <= 1'b0;
                pair2_ready   <= 1'b0;
                last_smp_even <= 1'b0;
                wav_wr_done   <= 1'b0;
                busy          <= 1'b0;
                wr_cnt        <= 32'd0;
                warn_overrun  <= 1'b0;
                warn_odd      <= 1'b0;
            end
            else begin
                wav_wr_done <= 1'b0;
                sdr_we      <= 1'b0;              // 默认不给脉冲

                busy <= (st != S_IDLE) | pair_ready | pair2_ready;

                if (smp_we) last_smp_even <= ~smp_idx[0];

                // ---- 收采样，两两配对 ----
                if (smp_we) begin
                    if (smp_idx[0] == 1'b0) smp_lo <= smp_data;   // 偶数序号：暂存
                end

                // 采样吐完了、最后一个没配上对（采样数是奇数）→ 报一声
                if (smp_done && (smp_idx[0] == 1'b0)) warn_odd <= 1'b1;

                case (st)
                // ---------- 空闲：等第一对采样，然后发请求 ----------
                S_IDLE: begin
                    sdr_req <= 1'b0;
                    if (smp_we && (smp_idx[0] == 1'b1) && sdr_ready) begin
                        sdr_base   <= sfx_base;              // ★ 段内偏移由引擎自己数
                        sdr_len    <= sfx_words;
                        sdr_req    <= 1'b1;
                        sdr_data   <= {smp_lo, smp_data};    // [31:16] 是前一个
                        pair_ready <= 1'b1;
                        wr_cnt     <= 32'd0;
                        st         <= S_REQ;
                    end
                end

                // ---------- 等引擎受理（受理时会清 FIFO，这时别推）----------
                S_REQ: begin
                    if (sdr_ack) begin
                        sdr_req <= 1'b0;
                        st      <= S_PUSH;
                    end
                end

                // ---------- 推数据：一对采样一个字 ----------
                S_PUSH: begin
                    // 两级暂存：FIFO 偶尔满一下就多存一个字，不丢数据
                    if (smp_we && (smp_idx[0] == 1'b1)) begin
                        if (!pair_ready) begin
                            sdr_data    <= {smp_lo, smp_data};
                            pair_ready  <= 1'b1;
                        end
                        else if (!pair2_ready) begin
                            sdr_data2   <= {smp_lo, smp_data};
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

                    // 推够了这一条的字数 → 等引擎收尾
                    // ★ 引擎已经报过 finish 时【就地完成】，不能进 S_WAIT
                    //   （sdr_done 是单拍脉冲，进 S_WAIT 就再也等不到了）
                    if (sdr_done) begin
                        wav_wr_done <= 1'b1;
                        st          <= S_IDLE;
                    end
                    else if (wr_cnt >= {10'd0, sfx_words}) begin
                        st <= S_WAIT;
                    end
                end

                // ---------- 等引擎给出 write_finish ----------
                S_WAIT: begin
                    if (sdr_done) begin
                        wav_wr_done <= 1'b1;
                        st          <= S_IDLE;
                    end
                end
                endcase
            end
        end

    endmodule