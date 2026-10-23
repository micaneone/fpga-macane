    //==========================================================================
      //  sub_analyze —— 字幕 BMP → 1bpp 遮罩字
      //==========================================================================
      //
      //  干的活：
      //    SD 卡里的 .SUB 文件（内容其实是标准 24 位 BMP）
      //      → 逐像素判"是不是黑" → 1 bit
      //      → 每 32 个像素拼成 1 个 32 位字
      //      → 吐给 sub2sdram 写进 SDRAM 字幕区
      //
      //  ★★★ 和图片链 / 音频链【不冲突】的三道保险
      //
      //    ① 【独立扩展名】TARGET_EXT = "SUB"
      //       图片链找 "BMP"、音频链找 "WAV"、本模块找 "SUB" ——
      //       三套索引【完全独立】。find_bmp 的 skip 是在"匹配到的文件"里
      //       数第几个，所以：
      //         · 加一条字幕【不会】让任何一张图的 skip 变号
      //         · 图最多 16 张、字幕最多 16 条，各算各的（4 位不共享）
      //         · 就算 skip 写错，BMP 也【永远】不会被字幕链捞到（硬过滤）
      //       ★ 文件内容仍是标准 24 位 BMP，只是改名成 .SUB。
      //         解析器只看文件头，不看文件名。
      //
      //    ② 【SD 前端共享】★ 2026-10-15【第②步·减重】已改：本模块不再自己带
      //       sd_top/sd_init（三条链原来三份逐字相同）。sd_top 现在在 top_a 里
      //       【全局只有一份】，本模块只保留自己的 find_bmp（FAT/目录/簇链状态机）
      //       并通过 fe_* 端口共享那份前端；`fe_owner` 保证只有 sd_mode_r 选中的
      //       那一条链的话算数（另两条连"前端忙"都看不见）。
      //
      //    ③ 【不碰 SDRAM 写口】本模块只吐 mask_we/mask_data/mask_idx，
      //       写 SDRAM 是 sub2sdram 的事，写口仲裁在 top_a，和这里无关。
      //
      //  ★★★ 契约（artwork_def.v）
      //      800 x 64 / 24 位 / 无压缩 / 白底黑字
      //      800 = 32 x 25 → 每行正好 25 个字，【没有一个像素跨字边界】
      //      64 行 x 25 = 1600 个字
      //
      //  ★ 遮罩极性：mask = (R < 128)
      //      黑字 = 1 = 画；白底 = 0 = 透过去
      //      写反了的后果：屏幕底部出现一块白方块，字的地方透出底图（反白）
      //
      //  ★ 位序：bit31 = 这 32 个像素里【最左边】那个
      //      （和全工程一致：高位 = 早出现的元素）
      //
      //  ★ 行序：BMP 存的是【自下而上】，本模块【原样】吐出去
      //      所以 SDRAM 里字 0..24 = 屏幕最下面那行
      //      叠加时用 63-(y-SUB_Y) 反一下就行（装载这边零成本）
      //
      //  ★ 尺寸：必须正好 800x64，否则 hdr_bad（宁可报错，不要花屏）
      //      高度必须为正（负数 = 自顶向下 BMP，行序会反，直接拒）
      //
      //  ★★★ 两个【必须记住】的坑（都是上板踩出来的）
      //
      //      ① 文件签名【逐字节比】，别用 {"B","M"}！
      //         Verilog 里 {a,b} 是 a 在高位 → {"B","M"} = 0x424D；
      //         而从文件按字节拼出来是 [7:0]='B' → 0x4D42，两者【永远不等】。
      //         用了就会 hdr_bad 每次都误报 → S_FAIL → 一个 mask_we 都不出。
      //         （bmp_analyze.v:218 用的是 8'h42 / 8'h4D，照抄它最稳）
      //
      //      ② 数据区要两个门：
      //         hdr_rdy  —— 头 34 字节读完之前【不能】认数据，
      //                     否则 hdr_off 还是复位值 0，文件头会被当成像素，
      //                     整个像素流错位（1700 个字全对不上）
      //         pix_cnt < 51200 —— 51200 个像素收够就【立刻】停，
      //                     否则文件尾那点垃圾字节会多吐 3 个字
      //                     （mask_we 会数到 1603 而不是 1600）
      //
      //  ★ 数据起点【必须读字节 10~13】，绝不能写死 54
      //      卡里的图都是 124 字节 V5 头 → data_off = 138
      //
      //  ★★★ 声明全部前置（这个工程踩过五次"先用后声明"）
      //==========================================================================
      `timescale 1ns / 1ps

      module sub_analyze #(
          // ★★★ 独立扩展名 —— 这是和图片链不冲突的关键
          parameter [23:0] TARGET_EXT = {"S","U","B"},

          // 契约尺寸（artwork_def.v 的 ART_SUB_W / ART_SUB_H）
          //  ★ REQ_W 必须是 32 的整数倍（800 = 32 x 25）
          parameter integer REQ_W = 800,
          parameter integer REQ_H = 64
      )(
          input         sys_clk,
          input         sys_rst_n,

          // ---- ★★★ 第②步：共享 SD 前端（sd_top 在 top_a，三条链共用那一份）----
          input         fe_init_done,   // ← 原来 find_bmp 的 bus_owner（sd_ready）
          input         fe_led,         // ← 原来 find_bmp 的 led1（led_init）
          input         fe_owner,       // ★ 1 = 现在是"装字幕"这一条当家
          output [31:0] fe_lba,         // → 共享前端 read_addr
          output        fe_req,         // → 共享前端 read_req
          input  [7:0]  fe_data,        // ← 读回的数据（每字节单拍 fe_ok）
          input         fe_ok,
          input         fe_done,
          input         fe_busy,
          input         fe_err,

          // ---- ★★★ 2026-10-16【切法C·find_bmp 合流】：查文件请求/结果口 ----
          //   本链不再自带 FAT/目录状态机，这 8 根原样引到 top_a，
          //   由 top_a 接到【全局唯一一份】`find_bmp_eng`（u_find_eng）上。
          output [23:0] eng_ext,        // → 引擎：本链扩展名（= TARGET_EXT "SUB"）
          output [3:0]  eng_skip,       // → 引擎：本链 skip（引擎在 start 那拍锁存）
          output        eng_start,      // → 引擎：本链要查文件
          output        eng_owner,      // → 引擎：1 = 装字幕这条当家 → 接 u_find_eng.owner
          input  [31:0] eng_lba_i,      // ← 引擎：引擎自己算的扇区地址
          input         eng_req_i,      // ← 引擎：引擎自己的读请求
          input         eng_busy,       // ← 引擎：引擎自己的 busy
          input         eng_done,       // ← 引擎：查到了
          input         eng_fail,       // ← 引擎：查不到 / 卡 / 坏卡
          input  [31:0] eng_sector,     // ← 引擎：file_sector（已打拍）
          input  [31:0] eng_size,       // ← 引擎：file_size  （已打拍）
          input  [31:0] eng_cluster,    // ← 引擎：file_cluster（已打拍）

          // ---- 命令 ----
          input         start,          // 拉高一拍开始
          input  [3:0]  skip,           // ★ 第几个 .SUB（和 .BMP / .WAV 各算各的）

          // ---- 状态 ----
          output reg    busy,
          output reg    done,           // 单拍：1600 个字全吐完
          output reg    fail,           // 单拍：失败

          // ---- 尺寸信息 ----
          output reg [15:0] sub_width,
          output reg [15:0] sub_height,
          output reg        info_valid,

          // ---- ★ 遮罩字输出（直接喂 sub2sdram）----
          output reg [31:0] mask_data,  // 32 个像素 = 1 个字，bit31 = 最左边的像素
          output reg        mask_we,    // 单拍写使能
          output     [31:0] mask_idx,   // 第几个字，0 .. 1599

          // ---- 调试 ----
          output            led_init,
          output            sd_ready,
          output     [31:0] dbg_data_off,    // 从文件头读出的数据起点（应为 138）
          output     [31:0] dbg_first_word,  // 第一个遮罩字（应为 32'h0000_0000）
          output     [31:0] dbg_rd_sec,
          output     [31:0] dbg_word_cnt,    // 应为 1600
          output     [31:0] dbg_px_cnt,      // 应为 51200
output     [7:0]  dbg_hdr_cause,   // 2026-10-23：S_FAIL 时锁存的失因位
output     [15:0] dbg_hdr_bytes    // 头两个原始字节 {byte0, byte1}
      );

          //======================================================================
          //  ★ 常量（全部前置）
          //======================================================================
          localparam integer ROW_BYTES = REQ_W * 3;                   // 800*3 = 2400
          localparam integer STRIDE    = ((ROW_BYTES + 3) / 4) * 4;   // 2400
          localparam integer TOT_WORDS = (REQ_W / 32) * REQ_H;        // 25 * 64 = 1600
          localparam integer TOT_PIXS  = REQ_W * REQ_H;               // 800 * 64 = 51200

          localparam [15:0] REQ_W16 = REQ_W[15:0];
          localparam [15:0] REQ_H16 = REQ_H[15:0];
          localparam [31:0] ROW_B32 = ROW_BYTES[31:0];
          localparam [31:0] ROW_LAST= STRIDE[31:0] - 32'd1;
          localparam [31:0] TOT_W32 = TOT_WORDS[31:0];
          localparam [31:0] TOT_P32 = TOT_PIXS[31:0];

          localparam [15:0] BPP_REQ  = 16'd24;
          localparam [31:0] COMP_REQ = 32'd0;
          localparam [7:0]  DARK_TH  = 8'd128;

          //======================================================================
          //  ★ 和 find_bmp 的连线（和 bmp_analyze / wav_analyze 一模一样）
          //======================================================================
          reg         f_start;
          wire        f_done, f_fail;
          wire [31:0] f_sector, f_size, f_cluster;

          reg  [31:0] rd_lba;
          reg         rd_req;
          wire [7:0]  rd_data;
          wire        rd_ok, rd_done, rd_busy, rd_err;

          //======================================================================
          //  ★ 文件级状态机（和 bmp_analyze / wav_analyze 同一套）
          //======================================================================
          localparam S_IDLE = 4'd0,
                     S_FIND = 4'd1,
                     S_WAIT = 4'd2,
                     S_REQ  = 4'd3,
                     S_RECV = 4'd4,
                     S_NEXT = 4'd5,
                     S_DONE = 4'd6,
                     S_FAIL = 4'd7,
                     S_PAD  = 4'd8;      // 数据不够：用零字补齐（不再整条判失败）

          reg [3:0]  state;

          reg [31:0] sub_sector;
          reg [31:0] cur_lba;
          reg [31:0] max_sec;
          reg [31:0] sec_cnt;

          //======================================================================
          //  ★ 文件头
          //  ★★★ 别用 {"B","M"}！Verilog 里 {a,b} 是【a 在高位】，
          //      所以 {"B","M"} = 0x424D；
          //      而下面按字节拼出来是 [7:0]=第一个字节='B' → 0x4D42，两者【永远不等】！
          //      后果：hdr_bad 每次都误报 → 直接 S_FAIL → 一个 mask_we 都不出。
          //      ⇒ 逐字节比（照抄 bmp_analyze.v:218 的写法）
          //======================================================================
          reg        bm_b;              // 第 0 字节是 'B'
          reg        bm_m;              // 第 1 字节是 'M'
          reg [31:0] hdr_off;           // ★ 从字节 10~13 读出（应为 138）
          reg [15:0] h_w;
          reg [15:0] h_h;
          reg [15:0] h_bpp;
          reg [31:0] h_comp;
          reg        hdr_bad;           // 1 = 格式不对
reg [7:0]  hdr_cause;         // 失因位：b0/1=BM，b2=bpp，b3=comp，b4=w，b5=h，b6=rd_err
reg [15:0] hdr_bytes;         // {byte0, byte1} 原始前两字节
reg [7:0]  b0_r;              // 第 0 字节原值
          reg        hdr_rdy;           // ★ 头 34 字节读完了

          localparam [7:0] CH_B = 8'h42;    // 'B'
          localparam [7:0] CH_M = 8'h4D;    // 'M'

          //======================================================================
          //  ★ 行 / 像素 / 打包
          //======================================================================
          reg [31:0] g_cnt;        // 全局字节计数（从文件第 0 字节算起）
          reg [31:0] row_byte;     // 行内字节位置 0 .. STRIDE-1
          reg [1:0]  bcnt;         // 像素内第几字节 0=蓝 1=绿 2=红

          reg [31:0] acc;          // 遮罩移位寄存器
          reg [5:0]  bit_cnt;      // 已经攒了几个 bit（0..31）
          reg [31:0] word_idx;     // 下一个要吐的字号
          reg [31:0] mask_idx_r;
          reg [31:0] pix_cnt;
          reg [31:0] first_word_r;

          // ★ 自增前的字号（和 bmp_analyze 的 px_addr_r、wav_analyze 的
          //   smp_idx_r 是同一个坑：不能用自增后的值）
          assign mask_idx = mask_idx_r;

          // ---- ★★ 三个条件一个都不能少 ----
          //   hdr_rdy         —— 头 34 字节读够没      → 防止把文件头当像素
          //   !hdr_bad        —— 格式对不对            → 不对就一个字节都不吐
          //   g_cnt>=hdr_off  —— 进数据区了没
          //   pix_cnt<TOT_P32 —— 51200 个像素还没收够  → 防止文件尾垃圾多吐字
          wire in_data  = hdr_rdy && !hdr_bad && (g_cnt >= hdr_off) && (pix_cnt < TOT_P32);
          wire in_pixel = in_data && (row_byte < ROW_B32);
          wire is_R     = in_pixel && (bcnt == 2'd2);
          wire bit_v    = (rd_data < DARK_TH);                       // ★ 黑 = 1
          wire [31:0] word_now = {acc[30:0], bit_v};

          //======================================================================
          //  调试输出
          //======================================================================
          assign dbg_data_off   = hdr_off;
          assign dbg_hdr_cause = hdr_cause;
          assign dbg_hdr_bytes = hdr_bytes;
          assign dbg_first_word = first_word_r;
          assign dbg_rd_sec     = sec_cnt;
          assign dbg_word_cnt   = word_idx;
          assign dbg_px_cnt     = pix_cnt;

          //======================================================================
          //  主状态机
          //======================================================================
          always @(posedge sys_clk or negedge sys_rst_n) begin
              if (!sys_rst_n) begin
                  state       <= S_IDLE;
                  f_start     <= 1'b0;
                  rd_lba      <= 32'd0;
                  rd_req      <= 1'b0;
                  cur_lba     <= 32'd0;
                  max_sec     <= 32'd0;
                  sub_sector  <= 32'd0;
                  sec_cnt     <= 32'd0;

                  bm_b        <= 1'b0;
                  bm_m        <= 1'b0;
                  hdr_cause   <= 8'd0;
                  hdr_bytes   <= 16'd0;
                  b0_r        <= 8'd0;
                  hdr_off     <= 32'd0;
                  h_w         <= 16'd0;
                  h_h         <= 16'd0;
                  h_bpp       <= 16'd0;
                  h_comp      <= 32'd0;
                  hdr_bad     <= 1'b0;
                  hdr_rdy     <= 1'b0;

                  g_cnt       <= 32'd0;
                  row_byte    <= 32'd0;
                  bcnt        <= 2'd0;
                  acc         <= 32'd0;
                  bit_cnt     <= 6'd0;
                  word_idx    <= 32'd0;
                  mask_idx_r  <= 32'd0;
                  pix_cnt     <= 32'd0;
                  first_word_r<= 32'd0;

                  busy        <= 1'b0;
                  done        <= 1'b0;
                  fail        <= 1'b0;
                  sub_width   <= 16'd0;
                  sub_height  <= 16'd0;
                  info_valid  <= 1'b0;
                  mask_data   <= 32'd0;
                  mask_we     <= 1'b0;
              end
              else begin
                  done    <= 1'b0;
                  fail    <= 1'b0;
                  mask_we <= 1'b0;         // 单拍脉冲，默认清零

                  case (state)
                  //----------------------------------------------------------
                  S_IDLE: begin
                      busy <= 1'b0;
                      if (start && sd_ready) begin
                          f_start     <= 1'b1;
                          bm_b        <= 1'b0;
                          bm_m        <= 1'b0;
                          hdr_cause   <= 8'd0;
                          hdr_bytes   <= 16'd0;
                          hdr_off     <= 32'd0;
                          h_w         <= 16'd0;
                          h_h         <= 16'd0;
                          h_bpp       <= 16'd0;
                          h_comp      <= 32'd0;
                          hdr_bad     <= 1'b0;
                          hdr_rdy     <= 1'b0;
                          g_cnt       <= 32'd0;
                          row_byte    <= 32'd0;
                          bcnt        <= 2'd0;
                          acc         <= 32'd0;
                          bit_cnt     <= 6'd0;
                          word_idx    <= 32'd0;
                          mask_idx_r  <= 32'd0;
                          pix_cnt     <= 32'd0;
                          first_word_r<= 32'd0;
                          sec_cnt     <= 32'd0;
                          info_valid  <= 1'b0;
                          busy        <= 1'b1;
                          state       <= S_FIND;
                      end
                  end
                  //----------------------------------------------------------
                  S_FIND: begin
                      f_start <= 1'b0;
                      if (f_done) begin
                          sub_sector <= f_sector;
                          cur_lba    <= f_sector;
                          // ★ 用文件总大小算要读几个扇区 —— 简单且一定够
                          max_sec    <= (f_size + 32'd511) >> 9;
                          sec_cnt    <= 32'd0;
                          state      <= S_WAIT;
                      end
                      else if (f_fail)
                          state <= S_FAIL;
                  end
                  //----------------------------------------------------------
                  S_WAIT: begin
                      if (!rd_busy) begin
                          rd_lba <= cur_lba;
                          rd_req <= 1'b1;
                          state  <= S_REQ;
                      end
                  end
                  //----------------------------------------------------------
                  S_REQ: begin
                      if (rd_busy) begin
                          rd_req <= 1'b0;
                          state  <= S_RECV;
                      end
                  end
                  //----------------------------------------------------------
                  S_RECV: begin
                      if (rd_ok) begin
                          //==================================================
                          //  ① 文件头（★ 签名逐字节比，见文件头的警告）
                          //==================================================
                          if (g_cnt == 32'd0)  begin
                              b0_r      <= rd_data;
                              hdr_bytes <= {rd_data, hdr_bytes[7:0]};
                              bm_b      <= (rd_data == CH_B);
                          end
                          if (g_cnt == 32'd1)  begin
                              hdr_bytes <= {hdr_bytes[15:8], rd_data};
                              bm_m      <= (rd_data == CH_M);
                          end

                          // ★★★ 数据起点必须【读出来】，不能写死 54 或 138
                          if (g_cnt == 32'd10) hdr_off[7:0]   <= rd_data;
                          if (g_cnt == 32'd11) hdr_off[15:8]  <= rd_data;
                          if (g_cnt == 32'd12) hdr_off[23:16] <= rd_data;
                          if (g_cnt == 32'd13) hdr_off[31:24] <= rd_data;

                          if (g_cnt == 32'd18) h_w[7:0]   <= rd_data;
                          if (g_cnt == 32'd19) h_w[15:8]  <= rd_data;

                          if (g_cnt == 32'd22) h_h[7:0]   <= rd_data;
                          if (g_cnt == 32'd23) h_h[15:8]  <= rd_data;

                          if (g_cnt == 32'd28) h_bpp[7:0]  <= rd_data;
                          if (g_cnt == 32'd29) h_bpp[15:8] <= rd_data;

                          if (g_cnt == 32'd30) h_comp[7:0]   <= rd_data;
                          if (g_cnt == 32'd31) h_comp[15:8]  <= rd_data;
                          if (g_cnt == 32'd32) h_comp[23:16] <= rd_data;

                          // ---- 第 33 个字节到 → 头部收完，一次性判定 ----
                          if (g_cnt == 32'd33) begin
                              h_comp[31:24] <= rd_data;
                              hdr_rdy       <= 1'b1;      // ★ 从现在起才认数据
                              sub_width     <= h_w;
                              sub_height    <= h_h;
                              info_valid    <= 1'b1;

                              // ★ 严格校验：宁可在仿真里报错，也不要在屏上花屏
                              //   · 前两字节必须是 "BM"
                              //   · 位深必须 24、无压缩
                              //   · 尺寸必须正好 800x64
                              //   · 高度必须为正（负数 = 自顶向下，行序会反）
                              if ((!bm_b)  || (!bm_m)         ||
                                  (h_bpp         != BPP_REQ)  ||
                                  (h_comp        != COMP_REQ) ||
                                  (h_w[15]       == 1'b1)     ||
                                  (h_h[15]       == 1'b1)     ||
                                  (h_w           != REQ_W16)  ||
                                  (h_h           != REQ_H16))
                                  hdr_bad <= 1'b1;
                          end

                          //==================================================
                          //  ② 数据区：3 字节一个像素，第 3 个字节是 R
                          //==================================================
                          if (in_data) begin
                              // ---- 打包（只在 is_R 那一拍）----
                              if (is_R) begin
                                  if (bit_cnt == 6'd31) begin
                                      // 收满 32 个 → 吐一个字
                                      mask_data   <= word_now;
                                      mask_we     <= 1'b1;
                                      mask_idx_r  <= word_idx;     // ★ 自增前的号
                                      if (word_idx == 32'd0)
                                          first_word_r <= word_now;
                                      word_idx    <= word_idx + 32'd1;
                                      acc         <= 32'd0;
                                      bit_cnt     <= 6'd0;
                                  end
                                  else begin
                                      acc     <= word_now;
                                      bit_cnt <= bit_cnt + 6'd1;
                                  end
                                  pix_cnt <= pix_cnt + 32'd1;   // ★ 到 51200 就停
                              end

                              // ---- 行内位置推进（含行末补齐字节）----
                              if (row_byte == ROW_LAST) begin
                                  row_byte <= 32'd0;
                                  bcnt     <= 2'd0;            // ★ 行首重新开始
                              end
                              else begin
                                  row_byte <= row_byte + 32'd1;
                                  if (in_pixel)
                                      bcnt <= (bcnt == 2'd2) ? 2'd0 : (bcnt + 2'd1);
                              end
                          end

                          g_cnt <= g_cnt + 32'd1;
                      end

                      //------------------------------------------------------
                      //  一个扇区读完
                      //------------------------------------------------------
                      if (rd_done)
                          state <= hdr_bad ? S_FAIL : S_NEXT;

                      if (rd_err)
                          state <= S_FAIL;
                  end
                  //----------------------------------------------------------
                  S_NEXT: begin
                      if (word_idx >= TOT_W32)
                          state <= S_DONE;       // ★ 1600 个字都吐完了
                      else if (sec_cnt >= max_sec)
                          state <= S_PAD;        // 文件读完了但字没凑齐 → 补零，别判死
                      else begin
                          cur_lba <= cur_lba + 32'd1;
                          sec_cnt <= sec_cnt + 32'd1;
                          state   <= S_WAIT;
                      end
                  end
                  //----------------------------------------------------------
                  S_DONE: begin
                      done  <= 1'b1;
                      busy  <= 1'b0;
                      state <= S_IDLE;
                  end
                  S_PAD: begin
                      if (word_idx >= TOT_W32)
                          state <= S_DONE;
                      else begin
                          mask_data  <= 32'd0;   // 补零字，写满整个槽（避免残留旧字幕）
                          mask_we    <= 1'b1;
                          mask_idx_r <= word_idx;
                          word_idx   <= word_idx + 32'd1;
                      end
                  end
                  S_FAIL: begin
                      fail  <= 1'b1;
                      hdr_cause <= {1'b0, rd_err, (h_h != REQ_H16), (h_w != REQ_W16),
                                    (h_comp != COMP_REQ), (h_bpp != BPP_REQ), (!bm_m), (!bm_b)};
                      busy  <= 1'b0;
                      state <= S_IDLE;
                  end
                  default: state <= S_IDLE;
                  endcase
              end
          end

          //======================================================================
          //  find_bmp：★ 只有扩展名和另两条链不一样，其余全部原样复用
          //  （FAT32 扫描 / 目录项匹配 / 簇链 / 扇区直通读 —— 一行没改）
          //======================================================================
          find_bmp #(
              .TARGET_EXT (TARGET_EXT),         // ★ {"S","U","B"}
              .NAME_EN    (1'b0)                // ★ 2026-10-20：字幕链只比后缀
          ) u_find_bmp (
              .sys_clk    (sys_clk),
              .sys_rst_n  (sys_rst_n),

              // ---- ★★★ 第②步：共享 SD 前端（真正的 sd_top 在 top_a，全局一份）----
              .fe_init_done (fe_init_done),
              .fe_led       (fe_led),
              .fe_owner     (fe_owner),
              .fe_lba       (fe_lba),
              .fe_req       (fe_req),
              .fe_data      (fe_data),
              .fe_ok        (fe_ok),
              .fe_done      (fe_done),
              .fe_busy      (fe_busy),
              .fe_err       (fe_err),

              .start      (f_start),
              .cmd        (1'b0),               // 0 = 找文件
              .skip       (skip),
              .name_sel   (1'b0),
        .name_inv   (1'b0),           // ★ 2026-10-21：过滤器在 top_a 的共享引擎里               // ★ 2026-10-20：本链不比名字，固定 0
              .in_cluster (32'd0),              // cmd=0 用不到

              .busy       (),                   // 不用
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
              .bus_owner (sd_ready),

              // ---- ★★★ 2026-10-16【切法C·find_bmp 合流】----
              .eng_ext     (eng_ext),
              .eng_skip    (eng_skip),
              .eng_start   (eng_start),
              .eng_owner   (eng_owner),
              .eng_lba_i   (eng_lba_i),
              .eng_req_i   (eng_req_i),
              .eng_busy    (eng_busy),
              .eng_done    (eng_done),
              .eng_fail    (eng_fail),
              .eng_sector  (eng_sector),
              .eng_size    (eng_size),
              .eng_cluster (eng_cluster)
          );

      endmodule
