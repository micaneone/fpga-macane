  module bmp_analyze(
      input         sys_clk,
      input         sys_rst_n,

      // ---- SD 卡引脚（透传给内部 find_bmp）----
      input         spi_miso,
      output        spi_mosi,
      output        spi_clk,
      output        spi_cs,

      // ---- 命令 ----
      input         start,          // 拉高一拍开始
      input  [3:0]  skip,           // 第几张 BMP

      // ---- 状态 ----
      output reg    busy,
      output reg    done,           // 单拍：全部像素输出完毕
      output reg    fail,           // 单拍：失败

      // ---- 图像信息 ----
      output reg [15:0] img_width,
      output reg [15:0] img_height,
      output reg        img_valid,  // 1 = 宽高有效

      // ---- 像素输出 ----
      output reg [15:0] px_data,    // RGB565 = {R[7:3], G[7:2], B[7:3]}
      output reg        px_we,      // 单拍写使能
      output     [31:0] px_addr,    // 像素序号 = y*W + x

      // ---- 调试 ----
      output            led_init,
      output            sd_ready,
      output     [31:0] dbg_px_cnt,      // 已输出像素数，正常 == W*H
      output     [31:0] dbg_data_off,    // 从文件头读出的数据起点
      output     [15:0] dbg_first_px,    // 第一个像素的【完整 RGB888】（调试用）
      output     [31:0] dbg_first_addr   // 第一个像素的地址（期望 (H-1)*W）
  );

      //======================================================================
      //  和 find_bmp 的连线
      //======================================================================
      reg         f_start;                          // → find_bmp.start
      wire        f_done, f_fail;
      wire [31:0] f_sector, f_size, f_cluster;

      reg  [31:0] rd_lba;                           // → find_bmp.rd_lba
      reg         rd_req;                           // → find_bmp.rd_req
      wire [7:0]  rd_data;                          // ← find_bmp.rd_data
      wire        rd_ok, rd_done, rd_busy, rd_err;  // ←

      //======================================================================
      //  状态机
      //======================================================================
      localparam B_IDLE = 4'd0,
                 B_FIND = 4'd1,
                 B_WAIT = 4'd2,
                 B_REQ  = 4'd3,
                 B_RECV = 4'd4,
                 B_NEXT = 4'd5,
                 B_DONE = 4'd6,
                 B_FAIL = 4'd7;

      reg [3:0]  state;

      // ---- 从 find_bmp 拿到 ----
      reg [31:0] bmp_sector;      // 文件起始扇区
      reg [31:0] cur_lba;         // 当前要读的扇区
      reg [31:0] max_sec;         // 文件总共占几个扇区

      // ---- 从 BMP 头解出来的 ----
      reg [31:0] bmp_data_off;    // 像素数据起点（第 10~13 字节）
      reg [31:0] bmp_width;       // 宽（第 18~21 字节）
      reg [31:0] bmp_height;      // 高（第 22~25 字节）
      reg [15:0] bmp_bpp;         // 位深（第 28~29 字节）
      reg        bm_ok;           // 开头是不是 "BM"
      reg        hdr_ready;       // 头解完了
      reg        hdr_bad;         // 头里有问题

      reg [31:0] row_bytes;       // 每行占几个字节 = ((W*3+3)/4)*4
      reg [31:0] total_px;        // 总像素数 = W*H

      // ---- 收字节 ----
      reg [31:0] g_cnt;           // 全局字节计数（从文件第 0 字节算起）
      reg [31:0] byte_in_row;     // 当前行已收字节数
      reg [31:0] sec_cnt;         // 已读扇区数（防死循环）

      // ---- 像素转换 ----
      reg [1:0]  sub_cnt;         // 像素内第几字节 0=蓝 1=绿 2=红
      reg [7:0]  b_byte, g_byte;  // 暂存蓝、绿（完整 8 位，供调试用）
      reg [15:0] col;             // 当前列 0..W-1
      reg [31:0] row_base;        // 当前显示行在帧缓冲里的起始地址
      reg [31:0] px_cnt;          // 已输出像素数
      reg [31:0] px_addr_r;       // ★ 像素序号（寄存，和 px_we 同拍更新）
      reg [15:0] first_px_r;      // 第一个像素的完整 RGB888（调试用）
      reg [31:0] first_addr_r;    // 第一个像素的地址（调试用）

      // ★ px_addr 改成寄存输出，保证和 px_we / px_data 严格对齐
      assign px_addr = px_addr_r;

      // "BM" 两个字节都对
      wire bm_all_ok = bm_ok;

      // 尺寸上限（col 只有 16 位，超过 65535 的宽度算不了）
      wire size_ok = (bmp_width  >= 32'd1) && (bmp_width  <= 32'd4096) &&
                     (bmp_height >= 32'd1) && (bmp_height <= 32'd4096);

      // ★ 像素处理的总条件：头部就绪 + 过了头部 + 像素还没收够
      wire pix_phase = hdr_ready && (g_cnt >= bmp_data_off) && (px_cnt < total_px);

      assign dbg_px_cnt     = px_cnt;
      assign dbg_data_off   = bmp_data_off;
      assign dbg_first_px   = first_px_r;
      assign dbg_first_addr = first_addr_r;
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n) begin
              state        <= B_IDLE;
              f_start      <= 1'b0;
              rd_lba       <= 32'd0;
              rd_req       <= 1'b0;
              cur_lba      <= 32'd0;
              max_sec      <= 32'd0;
              bmp_sector   <= 32'd0;
              bmp_data_off <= 32'd0;
              bmp_width    <= 32'd0;
              bmp_height   <= 32'd0;
              bmp_bpp      <= 16'd0;
              bm_ok        <= 1'b0;
              hdr_ready    <= 1'b0;
              hdr_bad      <= 1'b0;
              row_bytes    <= 32'd0;
              total_px     <= 32'd0;
              g_cnt        <= 32'd0;
              byte_in_row  <= 32'd0;
              sec_cnt      <= 32'd0;
              sub_cnt      <= 2'd0;
              b_byte       <= 8'd0;
              g_byte       <= 8'd0;
              col          <= 16'd0;
              row_base     <= 32'd0;
              px_cnt       <= 32'd0;
              px_addr_r    <= 32'd0;
              first_px_r   <= 'd0;
              first_addr_r <= 32'd0;
              busy         <= 1'b0;
              done         <= 1'b0;
              fail         <= 1'b0;
              img_width    <= 16'd0;
              img_height   <= 16'd0;
              img_valid    <= 1'b0;
              px_data      <= 16'd0;        // ★ 16 位
              px_we        <= 1'b0;
          end
          else begin
              done  <= 1'b0;
              fail  <= 1'b0;
              px_we <= 1'b0;        // 单拍脉冲，默认清零

              case (state)
              //--------------------------------------------------------------
              B_IDLE: begin
                  busy <= 1'b0;
                  if (start && sd_ready) begin
                      f_start     <= 1'b1;      // 一拍
                      hdr_ready   <= 1'b0;
                      hdr_bad     <= 1'b0;
                      bm_ok       <= 1'b0;
                      img_valid   <= 1'b0;
                      g_cnt       <= 32'd0;
                      byte_in_row <= 32'd0;
                      sec_cnt     <= 32'd0;
                      sub_cnt     <= 2'd0;
                      col         <= 16'd0;
                      px_cnt      <= 32'd0;
                      px_addr_r   <= 32'd0;     // 顺手清掉，方便调试
                      first_px_r  <= 16'd0;
                      first_addr_r<= 32'd0;
                      busy        <= 1'b1;
                      state       <= B_FIND;
                  end
              end
              //--------------------------------------------------------------
              B_FIND: begin
                  f_start <= 1'b0;
                  if (f_done) begin
                      bmp_sector <= f_sector;
                      cur_lba    <= f_sector;
                      // 文件占几个扇区，向上取整
                      max_sec    <= (f_size + 32'd511) >> 9;
                      sec_cnt    <= 32'd0;
                      state      <= B_WAIT;
                  end
                  else if (f_fail)
                      state <= B_FAIL;
              end
              //--------------------------------------------------------------
              // 等上一笔事务彻底结束
              B_WAIT: begin
                  if (!rd_busy) begin
                      rd_lba <= cur_lba;
                      rd_req <= 1'b1;
                      state  <= B_REQ;
                  end
              end
              //--------------------------------------------------------------
              // 请求举着，等被受理
              B_REQ: begin
                  if (rd_busy) begin
                      rd_req <= 1'b0;
                      state  <= B_RECV;
                  end
              end
              //--------------------------------------------------------------
              B_RECV: begin
                  if (rd_ok) begin
                      //==========================================================
                      //  1. BMP 头字段（只在前 30 个字节）
                      //==========================================================
                      if (g_cnt == 32'd0) bm_ok <= (rd_data == 8'h42);          // 'B'
                      if (g_cnt == 32'd1) bm_ok <= bm_ok && (rd_data == 8'h4D); // 'M'

                      // 第 10~13 字节：像素数据起点（小端）
                      if (g_cnt == 32'd10) bmp_data_off[7:0]   <= rd_data;
                      if (g_cnt == 32'd11) bmp_data_off[15:8]  <= rd_data;
                      if (g_cnt == 32'd12) bmp_data_off[23:16] <= rd_data;
                      if (g_cnt == 32'd13) bmp_data_off[31:24] <= rd_data;

                      // 第 18~21 字节：宽
                      if (g_cnt == 32'd18) bmp_width[7:0]   <= rd_data;
                      if (g_cnt == 32'd19) bmp_width[15:8]  <= rd_data;
                      if (g_cnt == 32'd20) bmp_width[23:16] <= rd_data;
                      if (g_cnt == 32'd21) bmp_width[31:24] <= rd_data;

                      // 第 22~25 字节：高
                      if (g_cnt == 32'd22) bmp_height[7:0]   <= rd_data;
                      if (g_cnt == 32'd23) bmp_height[15:8]  <= rd_data;
                      if (g_cnt == 32'd24) bmp_height[23:16] <= rd_data;
                      if (g_cnt == 32'd25) bmp_height[31:24] <= rd_data;

                      // 第 28~29 字节：位深
                      if (g_cnt == 32'd28) bmp_bpp[7:0]  <= rd_data;
                      if (g_cnt == 32'd29) bmp_bpp[15:8] <= rd_data;

                      //----------------------------------------------------------
                      // 第 30 个字节：所有头字段都齐了，做校验 + 算派生量
                      //----------------------------------------------------------
                      if (g_cnt == 32'd30) begin
                          if (!bm_all_ok || (bmp_bpp != 16'd24) || !size_ok) begin
                              hdr_bad <= 1'b1;      // 不是 24 位 BMP / 宽高异常
                          end
                          else begin
                              hdr_ready <= 1'b1;
                              // 每行字节数 = ((W*3 + 3) / 4) * 4
                              row_bytes <= ((bmp_width * 32'd3 + 32'd3) >> 2) << 2;
                              total_px  <= bmp_width * bmp_height;
                              // bottom-up：文件第 0 行写到帧缓冲最后一行
                              row_base  <= (bmp_height - 32'd1) * bmp_width;
                              img_width  <= bmp_width[15:0];
                              img_height <= bmp_height[15:0];
                              img_valid  <= 1'b1;
                          end
                      end

                      //==========================================================
                      //  2. 像素数据
                      //==========================================================
                      if (pix_phase) begin

                          // ---- 2a. BGR → RGB565（跳过行尾 padding）----
                          if ({16'd0, col} < bmp_width[15:0]) begin
                              case (sub_cnt)
                                  2'd0: begin                      // 蓝
                                      b_byte  <= rd_data;
                                      sub_cnt <= 2'd1;
                                  end
                                  2'd1: begin                      // 绿
                                      g_byte  <= rd_data;
                                      sub_cnt <= 2'd2;
                                  end
                                  default: begin                   // 红，出一个像素
                                      // ★ RGB565 = {R[7:3], G[7:2], B[7:3]}
                                      //   丢掉 R 低 3 位、G 低 2 位、B 低 3 位
                                      px_data <= {rd_data[7:3],    // R[7:3] 5 位
                                                  g_byte[7:2],     // G[7:2] 6 位
                                                  b_byte[7:3]};    // B[7:3] 5 位

                                      // ★ px_addr_r 必须在这里、用【自增前】的
                                      //   row_base / col 算出来。
                                      //   如果写成组合逻辑 assign px_addr =
                                      //   row_base + col，等 px_we 拉高时 col
                                      //   已经自增过了，地址会多 1。
                                      //   行尾更糟：row_base 也变了，会错一整行。
                                      px_addr_r <= row_base + {16'd0, col};

                                      // 调试：锁存第一个像素的【完整 24 位】
                                      if (px_cnt == 32'd0) begin
                                          first_px_r   <= {rd_data[7:3], g_byte[7:2], b_byte[7:3]};
                                          first_addr_r <= row_base + {16'd0, col};
                                      end

                                      px_we   <= 1'b1;
                                      sub_cnt <= 2'd0;
                                      col     <= col + 1'b1;
                                      px_cnt  <= px_cnt + 1'b1;
                                  end
                              endcase
                          end

                          // ---- 2b. 行内计数 / 翻行 ----
                          // ★ 必须放在 2a 后面：行尾那一拍 col 要清零，
                          //   不能被 2a 的 col+1 覆盖掉
                          //
                          // ★★ 集成临时改动（见 规划\A轨待改清单.md 第 5 条）
                          //   原来这里用【外部字节计数器 byte_in_row】判行尾：
                          //       if (byte_in_row == row_bytes - 1) ...
                          //   问题：640x480 24 位每行 1920 字节 = 3.75 个 512 字节扇区，
                          //   行首每 4 行才落在扇区边界上；只要字节流在扇区切换处
                          //   多算/漏算一个字节，行边界就会错 → 每 4 行错一次
                          //   → 屏上正是"一条一条、每 4 行跳一次的错位横带"。
                          //   现在改成用【本行已吐出的像素数】判行尾，和字节流完全解耦：
                          //   吐满 bmp_width 个像素（且正好在第 3 个字节=红）就是这一行结束。
                          //   byte_in_row 降级成纯参考量，不再参与行边界判断。
                          if ((col == bmp_width[15:0] - 16'd1) && (sub_cnt == 2'd2)) begin
                              row_base    <= row_base - bmp_width;  // 显示行往上走
                              col         <= 16'd0;
                              byte_in_row <= 32'd0;
                          end
                          else begin
                              byte_in_row <= byte_in_row + 32'd1;
                          end
                      end

                      g_cnt <= g_cnt + 32'd1;
                  end

                  if (rd_done) state <= hdr_bad ? B_FAIL : B_NEXT;
                  if (rd_err)  state <= B_FAIL;
              end
              //--------------------------------------------------------------
              B_NEXT: begin
                  if (px_cnt >= total_px)
                      state <= B_DONE;          // 所有像素都吐完了
                  else if (sec_cnt >= max_sec)
                      state <= B_FAIL;          // 文件读完了但像素没凑齐
                  else begin
                      cur_lba <= cur_lba + 32'd1;
                      sec_cnt <= sec_cnt + 32'd1;
                      state   <= B_WAIT;
                  end
              end
              //--------------------------------------------------------------
              B_DONE: begin
                  done  <= 1'b1;
                  busy  <= 1'b0;
                  state <= B_IDLE;
              end
              B_FAIL: begin
                  fail  <= 1'b1;
                  busy  <= 1'b0;
                  state <= B_IDLE;
              end
              default: state <= B_IDLE;
              endcase
          end
      end

      find_bmp u_find_bmp (
          .sys_clk    (sys_clk),
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
