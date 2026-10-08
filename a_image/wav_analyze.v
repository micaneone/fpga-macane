//==========================================================================
  //  wav_analyze —— SD 卡 → FAT32 → WAV → 16bit PCM 采样流
  //
  //  和 bmp_analyze 是【同一个套路】：
  //     bmp_analyze:  find_bmp 找文件 → 解 BMP 头 → 流像素
  //     wav_analyze:  find_bmp 找文件 → 解 RIFF 头 → 流采样
  //
  //  ★★ 和 BMP 最大的区别：WAV 头【不是固定偏移】，必须遍历 chunk
  //
  //     BMP：数据起点永远在第 10~13 字节 —— bmp_analyze 直接写 g_cnt==10 就行
  //     WAV：RIFF 是 chunk 链：
  //
  //         "RIFF" + 文件长度 + "WAVE"
  //            ├─ "fmt " + 长度 + 格式/声道/采样率/位深…   ← 长度可能是 16 / 18 / 40
  //            ├─ "LIST" / "fact" / "bext" …              ← 位置和个数都不固定
  //            └─ "data" + 长度 + PCM 数据                ← 起点在这里，不是固定偏移
  //
  //     所以本模块是【按 g_cnt 逐字节走 + 一个 chunk 子状态机 cst】：
  //         读 4 字节 chunk ID → 读 4 字节长度 → 是 fmt 就读、是 data 就收工、
  //         都不是就【跳过】那么多字节（★ 奇数长度要补 1 字节对齐）
  //
  //  ★ 只认一种格式（和契约统一），不满足直接 fail：
  //         48 kHz / 单声道 / 16 bit / PCM（audioFormat = 1）
  //
  //  使用流程（和 bmp_analyze 一样）：
  //   1) 等 sd_ready 变 1
  //   2) 摆好 skip（第几个 WAV，0 = 第一个）
  //   3) 给 start 一个单拍脉冲
  //   4) 找到 data chunk 那一拍 → info_valid 拉高，
  //      smp_rate / smp_ch / smp_bits / smp_cnt 有效
  //   5) 采样一个接一个出来（smp_we 单拍 + smp_data + smp_idx）
  //   6) done（全部出完）/ fail（找不到 / 格式不对 / 字节不够）
  //
  //  ★ 只解析一次：头解完就是裸 PCM 流了，下游（wav2sdram）只管搬字节，
  //    再也不碰 RIFF。这跟"BMP 只在装的时候是 BMP"是一模一样的思路。
  //==========================================================================
  module wav_analyze #(
      // ★ 找什么扩展名 —— 直接透传给 find_bmp（它本来就是参数化的）
      parameter [23:0] TARGET_EXT = {"W","A","V"},

      // ★ 只认这一种格式
      parameter integer RATE_REQ = 48000,
      parameter integer CH_REQ   = 1,
      parameter integer BITS_REQ = 16
  )(
      input         sys_clk,
      // ★★ 2026-10-08【集成临时改动 · 提速到 25 MHz】：读移位器时钟（透传给 find_bmp）。
      //   ★ 音频这条链暂时【仍给 sys_clk】⇒ 行为与改动前逐位相同（只有 288 KB、0.19 s，
      //     不值得为它多担一次风险）。要一起提速，只要在 top_a 把这里改成 clk_spi 即可。
      input         clk_spi,
      input         sys_rst_n,

      // ---- SD 卡引脚（透传给内部 find_bmp）----
      input         spi_miso,
      output        spi_mosi,
      output        spi_clk,
      output        spi_cs,

      // ---- 命令 ----
      input         start,          // 拉高一拍开始
      input  [3:0]  skip,           // 第几个 WAV

      // ---- 状态 ----
      output reg    busy,
      output reg    done,           // 单拍：全部采样输出完毕
      output reg    fail,           // 单拍：失败

      // ---- 音频信息 ----
      output reg [31:0] smp_rate,   // 采样率（Hz）
      output reg [15:0] smp_ch,     // 声道数
      output reg [15:0] smp_bits,   // 位深
      output reg [31:0] smp_cnt,    // 采样总数
      output reg        info_valid, // 1 = 上面四项有效

      // ---- 采样输出 ----
      output reg [15:0] smp_data,   // 16bit PCM（有符号，小端已还原）
      output reg        smp_we,     // 单拍写使能
      output     [31:0] smp_idx,    // 采样序号 0,1,2,…

      // ---- 调试 ----
      output            led_init,
      output            sd_ready,
      output     [31:0] dbg_data_off,   // data chunk 载荷的绝对字节偏移
      output     [31:0] dbg_data_len,   // data chunk 长度（字节）
      output     [15:0] dbg_first_smp,  // 第一个采样
      output     [31:0] dbg_rd_sec      // 读了多少个扇区
  );

      //======================================================================
      //  和 find_bmp 的连线（和 bmp_analyze 一模一样）
      //======================================================================
      reg         f_start;
      wire        f_done, f_fail;
      wire [31:0] f_sector, f_size, f_cluster;

      reg  [31:0] rd_lba;
      reg         rd_req;
      wire [7:0]  rd_data;
      wire        rd_ok, rd_done, rd_busy, rd_err;

      //======================================================================
      //  文件级状态机（和 bmp_analyze 同一套）
      //======================================================================
      localparam S_IDLE = 4'd0,
                 S_FIND = 4'd1,
                 S_WAIT = 4'd2,
                 S_REQ  = 4'd3,
                 S_RECV = 4'd4,
                 S_NEXT = 4'd5,
                 S_DONE = 4'd6,
                 S_FAIL = 4'd7;

      reg [3:0]  state;

      reg [31:0] wav_sector;
      reg [31:0] cur_lba;
      reg [31:0] max_sec;
      reg [31:0] sec_cnt;

      //======================================================================
      //  chunk 子状态机（★ BMP 那边没有的部分）
      //======================================================================
      localparam C_RIFF = 3'd0,   // 等 "RIFF" … "WAVE"
                 C_HDR  = 3'd1,   // 读 8 字节 chunk 头
                 C_FMT  = 3'd2,   // 读 fmt 载荷
                 C_SKIP = 3'd3,   // 跳过不关心的 chunk 载荷
                 C_SAMP = 3'd4;   // 已经在吐采样

      reg [2:0]  cst;

      reg [31:0] g_cnt;        // 全局字节计数（从文件第 0 字节算起）
      reg [31:0] id_sr;        // 最近几个字节（认 "RIFF"/"WAVE"/chunk ID 用）
      reg [31:0] cur_sz;       // 当前 chunk 长度（小端已还原）
      reg [31:0] hdr_off;      // 当前 chunk 头的绝对偏移
      reg [31:0] skip_end;     // 跳到哪个绝对偏移（已含奇数补齐）

      // ---- fmt 里解出来的 ----
      reg [15:0] a_fmt;        // audioFormat（必须 1 = PCM）
      reg [15:0] n_ch;
      reg [31:0] rate;
      reg [15:0] blkalign;
      reg [15:0] bits;

      reg        riff_ok, wave_ok, fmt_seen, info_bad, data_seen;

      // ---- data chunk ----
      reg [31:0] data_off;
      reg [31:0] data_len;

      // ---- 采样组装 ----
      reg [31:0] s_idx;
      reg [31:0] s_total;
      reg        s_lo_vld;
      reg [7:0]  s_lo;
      reg [15:0] first_smp_r;

      // ★ 采样序号必须【寄存输出自增前的值】——
      //   和 bmp_analyze 里 px_addr_r 是同一个坑：
      //   如果直接 assign smp_idx = s_idx，那 s_idx 是在 smp_we 打出来的
      //   同一拍自增的，下游看到 smp_we=1 时 smp_idx 已经是下一个了。
      reg [31:0] smp_idx_r;
      assign smp_idx = smp_idx_r;

      // chunk 内偏移（0 = chunk 头的第一个字节）
      wire [31:0] c_off = g_cnt - hdr_off;
      // ★ 载荷内偏移：chunk 头占 8 字节，所以载荷第一个字节的 c_off 是 8 不是 0
      wire [31:0] f_off = c_off - 32'd8;

      localparam [31:0] ID_FMT  = {"f","m","t"," "};
      localparam [31:0] ID_DATA = {"d","a","t","a"};

      // 本拍要用的 chunk ID / 长度
      //  ★ ID：id_sr 只在 c_off 0~3 移位，所以到 c_off==7 时它【已经就是完整的 4 字节 ID】
      //    —— 不能再拼 rd_data，那会把 ID 掐掉一个字节
      //  ★ 长度：cur_sz 的 4 个字节在 c_off 4~7 陆续进来，第 4 个正是本拍，
      //    寄存器里还是旧值，所以这里要"现拼"
      wire [31:0] cid_now = id_sr;
      //  ★ 拼接方向：第 4 个长度字节是【最高字节】。
      //    小端 08 00 00 00 的值是 8，不是 2048 —— 写反了会跳到老远去
      wire [31:0] csz_now = {rd_data, cur_sz[23:0]};

      assign dbg_data_off  = data_off;
      assign dbg_data_len  = data_len;
      assign dbg_first_smp = first_smp_r;
      assign dbg_rd_sec    = sec_cnt;

      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n) begin
              state       <= S_IDLE;
              f_start     <= 1'b0;
              rd_lba      <= 32'd0;
              rd_req      <= 1'b0;
              cur_lba     <= 32'd0;
              max_sec     <= 32'd0;
              wav_sector  <= 32'd0;
              sec_cnt     <= 32'd0;

              cst         <= C_RIFF;
              g_cnt       <= 32'd0;
              id_sr       <= 32'd0;
              cur_sz      <= 32'd0;
              hdr_off     <= 32'd0;
              skip_end    <= 32'd0;

              a_fmt       <= 16'd0;
              n_ch        <= 16'd0;
              rate        <= 32'd0;
              blkalign    <= 16'd0;
              bits        <= 16'd0;

              riff_ok     <= 1'b0;
              wave_ok     <= 1'b0;
              fmt_seen    <= 1'b0;
              info_bad    <= 1'b0;
              data_seen   <= 1'b0;

              data_off    <= 32'd0;
              data_len    <= 32'd0;

              s_idx       <= 32'd0;
              s_total     <= 32'd0;
              s_lo_vld    <= 1'b0;
              s_lo        <= 8'd0;
              first_smp_r <= 16'd0;

              busy        <= 1'b0;
              done        <= 1'b0;
              fail        <= 1'b0;
              smp_rate    <= 32'd0;
              smp_ch      <= 16'd0;
              smp_bits    <= 16'd0;
              smp_cnt     <= 32'd0;
              info_valid  <= 1'b0;
              smp_data    <= 16'd0;
              smp_we      <= 1'b0;
              smp_idx_r   <= 32'd0;
          end
          else begin
              done   <= 1'b0;
              fail   <= 1'b0;
              smp_we <= 1'b0;          // 单拍脉冲，默认清零

              case (state)
              //--------------------------------------------------------------
              S_IDLE: begin
                  busy    <= 1'b0;
                  cst     <= C_RIFF;
                  hdr_off <= 32'd0;
                  if (start && sd_ready) begin
                      f_start     <= 1'b1;      // 一拍
                      g_cnt       <= 32'd0;
                      id_sr       <= 32'd0;
                      cur_sz      <= 32'd0;
                      skip_end    <= 32'd0;
                      riff_ok     <= 1'b0;
                      wave_ok     <= 1'b0;
                      fmt_seen    <= 1'b0;
                      info_bad    <= 1'b0;
                      data_seen   <= 1'b0;
                      sec_cnt     <= 32'd0;
                      s_idx       <= 32'd0;
                      s_total     <= 32'd0;
                      s_lo_vld    <= 1'b0;
                      first_smp_r <= 16'd0;
                      info_valid  <= 1'b0;
                      busy        <= 1'b1;
                      state       <= S_FIND;
                  end
              end
              //--------------------------------------------------------------
              S_FIND: begin
                  f_start <= 1'b0;
                  if (f_done) begin
                      wav_sector <= f_sector;
                      cur_lba    <= f_sector;
                      max_sec    <= (f_size + 32'd511) >> 9;   // 占几个扇区，向上取整
                      sec_cnt    <= 32'd0;
                      state      <= S_WAIT;
                  end
                  else if (f_fail)
                      state <= S_FAIL;
              end
              //--------------------------------------------------------------
              S_WAIT: begin
                  if (!rd_busy) begin
                      rd_lba <= cur_lba;
                      rd_req <= 1'b1;
                      state  <= S_REQ;
                  end
              end
              //--------------------------------------------------------------
              S_REQ: begin
                  if (rd_busy) begin
                      rd_req <= 1'b0;
                      state  <= S_RECV;
                  end
              end
              //--------------------------------------------------------------
              S_RECV: begin
                  if (rd_ok) begin

                      case (cst)
                      //======================================================
                      //  ① "RIFF" … "WAVE"（前 12 字节）
                      //======================================================
                      C_RIFF: begin
                          id_sr <= {id_sr[23:0], rd_data};
                          if (g_cnt == 32'd3)
                              riff_ok <= ({id_sr[23:0], rd_data} == {"R","I","F","F"});
                          if (g_cnt == 32'd11) begin
                              wave_ok <= ({id_sr[23:0], rd_data} == {"W","A","V","E"});
                              cst     <= C_HDR;
                              hdr_off <= 32'd12;      // 首个 chunk 头在这儿
                              // ★ 清零：不然 id_sr 里还留着 "WAVE"，
                              //   进 C_HDR 后移位 4 次只凑得出 3 个 ID 字节
                              id_sr   <= 32'd0;
                          end
                      end

                      //======================================================
                      //  ② chunk 头：ID(4) + 长度(4，小端)
                      //======================================================
                      C_HDR: begin
                          if (c_off <= 32'd3)
                              id_sr <= {id_sr[23:0], rd_data};

                          if (c_off == 32'd4) cur_sz[7:0]   <= rd_data;
                          if (c_off == 32'd5) cur_sz[15:8]  <= rd_data;
                          if (c_off == 32'd6) cur_sz[23:16] <= rd_data;

                          if (c_off == 32'd7) begin
                              cur_sz[31:24] <= rd_data;

                              if (cid_now == ID_FMT) begin
                                  cst      <= C_FMT;
                                  fmt_seen <= 1'b1;
                              end
                              else if (cid_now == ID_DATA) begin
                                  // 极少数 WAV 把 data 放在 fmt 前面 —— 不放行
                                  if (!fmt_seen) info_bad <= 1'b1;
                                  cst       <= C_SAMP;
                                  data_seen <= 1'b1;
                                  data_off  <= hdr_off + 32'd8;
                                  data_len  <= csz_now;
                                  // ★ 到这一拍 fmt 的字段全都锁好了（fmt 一定在前面），
                                  //   所以派生量和校验就在这儿做，不用等整个扇区读完
                                  smp_rate   <= rate;
                                  smp_ch     <= n_ch;
                                  smp_bits   <= bits;
                                  smp_cnt    <= csz_now >> 1;      // 16bit 单声道 → 2 字节一个采样
                                  s_total    <= csz_now >> 1;
                                  info_valid <= 1'b1;
                                  if (!riff_ok || !wave_ok || !fmt_seen ||
                                      (a_fmt != 16'd1)   ||
                                      (n_ch  != CH_REQ[15:0])   ||
                                      (rate  != RATE_REQ[31:0]) ||
                                      (bits  != BITS_REQ[15:0]))
                                      info_bad <= 1'b1;
                              end
                              else begin
                                  cst      <= C_SKIP;
                                  // ★ 奇数长度要补 1 字节对齐（RIFF 规范）
                                  skip_end <= hdr_off + 32'd8 + csz_now + {31'd0, csz_now[0]};
                              end
                          end
                      end

                      //======================================================
                      //  ③ fmt 载荷（16 字节起步，可能 18 / 40）
                      //======================================================
                      C_FMT: begin
                          // ★ 用 f_off（载荷内偏移），不是 c_off
                          if (f_off == 32'd0)  a_fmt[7:0]     <= rd_data;
                          if (f_off == 32'd1)  a_fmt[15:8]    <= rd_data;
                          if (f_off == 32'd2)  n_ch[7:0]      <= rd_data;
                          if (f_off == 32'd3)  n_ch[15:8]     <= rd_data;
                          if (f_off == 32'd4)  rate[7:0]      <= rd_data;
                          if (f_off == 32'd5)  rate[15:8]     <= rd_data;
                          if (f_off == 32'd6)  rate[23:16]    <= rd_data;
                          if (f_off == 32'd7)  rate[31:24]    <= rd_data;
                          if (f_off == 32'd12) blkalign[7:0]  <= rd_data;
                          if (f_off == 32'd13) blkalign[15:8] <= rd_data;
                          if (f_off == 32'd14) bits[7:0]      <= rd_data;
                          if (f_off == 32'd15) bits[15:8]     <= rd_data;

                          // 前 16 字节读够了：
                          //   fmt 长度正好 16 → 没有尾巴，【直接去下一个 chunk 头】
                          //   fmt 更长(18/40) → 进跳过态把尾巴跳掉
                          // ★ 不能一律进跳过态：此时 g_cnt 已经追平 skip_end，
                          //   "g_cnt == skip_end-1" 永远不成立，会卡死在 C_SKIP
                          if (f_off == 32'd15) begin
                              if (cur_sz <= 32'd16) begin
                                  cst     <= C_HDR;
                                  hdr_off <= hdr_off + 32'd8 + cur_sz + {31'd0, cur_sz[0]};
                                  id_sr   <= 32'd0;
                              end
                              else begin
                                  cst      <= C_SKIP;
                                  skip_end <= hdr_off + 32'd8 + cur_sz + {31'd0, cur_sz[0]};
                              end
                          end
                      end

                      //======================================================
                      //  ④ 跳过不关心的 chunk 载荷
                      //======================================================
                      C_SKIP: begin
                          if (g_cnt == skip_end - 32'd1) begin
                              cst     <= C_HDR;
                              hdr_off <= skip_end;
                              id_sr   <= 32'd0;       // ★ 同上：读下一个 chunk 头前清零
                          end
                      end

                      //======================================================
                      //  ⑤ 采样区：每两个字节拼一个 16bit 采样（小端）
                      //======================================================
                      C_SAMP: begin
                          if (s_idx < s_total) begin
                              if (!s_lo_vld) begin
                                  s_lo     <= rd_data;         // 低字节
                                  s_lo_vld <= 1'b1;
                              end
                              else begin
                                  smp_data   <= {rd_data, s_lo}; // 高字节在后 = 小端还原
                                  smp_we     <= 1'b1;
                                  smp_idx_r  <= s_idx;           // ★ 自增【前】的序号
                                  if (s_idx == 32'd0) first_smp_r <= {rd_data, s_lo};
                                  s_idx      <= s_idx + 32'd1;
                                  s_lo_vld   <= 1'b0;
                              end
                          end
                      end

                      default: cst <= C_RIFF;
                      endcase

                      g_cnt <= g_cnt + 32'd1;
                  end

                  //----------------------------------------------------------
                  //  一个扇区读完
                  //----------------------------------------------------------
                  if (rd_done)
                      state <= info_bad ? S_FAIL : S_NEXT;

                  if (rd_err)
                      state <= S_FAIL;
              end
              //--------------------------------------------------------------
              S_NEXT: begin
                  if (data_seen && (s_idx >= s_total))
                      state <= S_DONE;         // 采样都吐完了
                  else if (sec_cnt >= max_sec)
                      state <= S_FAIL;         // 文件读完了但采样没凑齐
                  else begin
                      cur_lba <= cur_lba + 32'd1;
                      sec_cnt <= sec_cnt + 32'd1;
                      state   <= S_WAIT;
                  end
              end
              //--------------------------------------------------------------
              S_DONE: begin
                  done  <= 1'b1;
                  busy  <= 1'b0;
                  state <= S_IDLE;
              end
              S_FAIL: begin
                  fail  <= 1'b1;
                  busy  <= 1'b0;
                  state <= S_IDLE;
              end
              default: state <= S_IDLE;
              endcase
          end
      end

      //======================================================================
      //  find_bmp：★ 扩展名是它的参数，找 WAV 只要传一个参数
      //  （FAT32 扫描 / 目录项匹配 / 簇链 / 扇区直通读 —— 全部原样复用）
      //======================================================================
      find_bmp #(
          .TARGET_EXT (TARGET_EXT)
      ) u_find_bmp (
          .sys_clk    (sys_clk),
          .clk_spi    (clk_spi),        // ★ 集成临时改动：音频链暂仍接 sys_clk（见端口注释）
          .sys_rst_n  (sys_rst_n),

          .spi_miso   (spi_miso),
          .spi_mosi   (spi_mosi),
          .spi_clk    (spi_clk),
          .spi_cs     (spi_cs),

          .start      (f_start),
          .cmd        (1'b0),           // 0 = 找文件
          .skip       (skip),
          .in_cluster (32'd0),          // cmd=0 用不到

          .busy       (),               // 不用
          .done       (f_done),
          .fail       (f_fail),

          .file_sector (f_sector),
          .file_size   (f_size),
          .file_cluster(f_cluster),

          .next_cluster(), .next_sector(), .chain_end(),

          .rd_lba  (rd_lba),
          .rd_req  (rd_req),
          .rd_data (rd_data),
          .rd_ok   (rd_ok),
          .rd_done (rd_done),
          .rd_busy (rd_busy),
          .rd_err  (rd_err),

          .led1      (led_init),
          .bus_owner (sd_ready)
      );

  endmodule
