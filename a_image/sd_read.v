    module sd_read(
      input           sys_clk,
      input           sys_rst_n,
      input           init_done,
      input           read_req,        
      input  [31:0]   read_addr,      
      output reg      read_busy,        
      output reg      read_ok,          
      output reg      read_done,       
      output reg      read_err,        
      output reg [7:0]data_out,
      output          spi_mosi,
      input           spi_miso,
      output          spi_clk,
      output          spi_cs,
      // ★★★ 2026-10-17【CMD18 多块连续读】1 = 这次事务允许"连续读多块"：
      //   · 命令由 CMD17 换成 **CMD18**（READ_MULTIPLE_BLOCK）；
      //   · 读完一块（512 B + 2 B CRC）**不撤 CS、也不再发命令**，而是
      //     ① 冻结 SCLK（CS 保持低）② `read_busy` 放低让调用方来要下一块；
      //   · 调用方要的下一块正好是"上一块 + 1" ⇒ 直接等它的数据 token 继续收
      //     （= 省掉每块一次的卡访问延迟，实测约 120 µs/块）；
      //   · 调用方跳到别的扇区、或者等太久没人来 ⇒ 打几个空字节把在途数据放掉、撤 CS。
      //   ★ 外部协议（read_req/read_busy/read_ok/read_done）**一个字没变**，
      //     所以调用方（bmp_analyze 等）一行都不用改。
      //   ★ `stream_en = 0` 时行为与原版**逐位相同**（这就是回退开关）。
      // ★★★★ 2026-10-17【警告 · 别打开】上板实测：`stream_en = 1` 时**整条 SD 读会死**
      //   仿真里是对的（sim\tb_sd_stream.v，1.32x、逐字节一致、发了 CMD12），
      //   但上板表现是"图装进去了、之后音频/字幕全读不到"（卡停在多块模式里不认新命令）。
      //   ⇒ `top_a.v` 里 `stream_en` 现在**恒接 1'b0**，这条路是死代码。
      //   要重新试：① 先确认卡支持 CMD18；② 补上"CMD12 之后等 busy 释放"的判据；
      //   ③ 一次只改这一个开关，别再同时动 SCLK 频率。
      input           stream_en
  );
      parameter sck_div = 0;
      // ★★ 2026-10-04（B 改）：2 ms → 40 ms。
      //   为什么：v7 让 A 的推字**只发生在行场消隐期**，于是一帧里有 ~16 ms
      //   写口是"满"的（A 必须停着等）。原来 100000 拍 @50MHz = 2 ms 的超时
      //   会把这种"长停"当故障中止读 —— 这正是 v2"第一张图都出不来"的老根。
      //   20 位装不下 40 ms（20 位最大 1,048,575 ≈ 21 ms），所以加宽到 22 位。
      parameter [21:0] TIME_OUT = 22'd2_000_000;   // 40 ms @50MHz
      parameter [15:0] IDLE_MAX = 16'd255;     
      localparam CMD17 = 8'h51;
      localparam CMD18 = 8'h52;        // ★ 2026-10-17：READ_MULTIPLE_BLOCK（0x40|18）
      localparam CMD12 = 8'h4C;        // ★ 2026-10-17：STOP_TRANSMISSION（0x40|12，收流必须发）
      localparam S_IDLE  = 4'd0;
      localparam S_CMD   = 4'd1;
      localparam S_RESP  = 4'd2;
      localparam S_TOKEN = 4'd3;
      localparam S_DATA  = 4'd4;
      localparam S_CRC   = 4'd5;   
      localparam S_STOP  = 4'd6;
      localparam S_STRM  = 4'd7;       // ★ 流式：一块读完了，CS 举着 + SCLK 停住，等下一块请求
      localparam S_STRME = 4'd8;       // ★ 流式收尾：打几个空字节放掉在途数据，再撤 CS
      //  流式等待上界：调用方回访一般在 1 µs 内；读到文件末尾没人再要了就等这么久收流。
      //  ★ 100 MHz 下 2000 拍 = 20 µs（`sd_read_cdc` 就是把本模块搬到快速域跑的）。
      localparam [15:0] STRM_TO = 16'd2000;
      localparam [2:0]  STRME_N = 3'd4;   // 收尾打几个空字节

      reg         spi_start;
      reg         spi_end;
      reg  [3:0]  flag_r;
      reg  [7:0]  read_tx_data;
      wire [7:0]  read_rx_data;
      wire        send_done;
      wire        receive_done;

      reg  [3:0]  send_cnt;
      reg  [2:0]  cmd_cnt;
      reg  [8:0]  data_cnt;
      reg  [1:0]  crc_cnt;
      reg  [21:0] time_out;                 // ★ 加宽到 22 位（TIME_OUT 已放到 40ms）
      reg  [15:0] idle_cnt;
      reg  [31:0] addr_r;
      // ---- ★ 2026-10-17 流式（CMD18 多块读）用 ----
      reg         strm_r;                   // ★ 本**次事务**是否走流式（在 start_read 锁存）
      reg  [15:0] strm_to;                  // 等"下一块请求"的计时
      reg  [2:0]  strme_cnt;                // 收尾阶段的字节计数
      reg  [3:0]  c12_rcv;                  // CMD12 阶段已收发几个字节
      // 流式等待中冻结 SCLK（CS 仍举着）；其余状态一律放行
      wire        spi_clk_en = (flag_r != S_STRM);

      wire start_read = (flag_r == S_IDLE) && read_req && init_done
                      && (idle_cnt == IDLE_MAX);
      // ★ 2026-10-17：流式开关**每笔事务锁存一次**。
      //   为什么必须锁：调用方的电平会在"读到第一个数据扇区"时中途变高，
      //   若直接用实时电平，一笔**已经用 CMD17 发出**的事务会在块尾误进 S_STRM
      //   （卡那边其实只发一块就停了）⇒ 等 token 超时 ⇒ 报错、丢一块。
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              strm_r <= 1'b0;
          else if (start_read)
              strm_r <= stream_en;
      end
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              addr_r <= 32'd0;
          else if (start_read)
              addr_r <= read_addr;     
          // ★ 2026-10-17【流式】：接着读下一块时也要把 `addr_r` 推上去（`+1` 判据要用它）。
          //   ★ 必须写在**这个块**里 —— 不能放主状态机那个 always，
          //     否则 `addr_r` 会被两个 always 同时驱动：ModelSim 只报竞争，
          //     **TD 直接报 HDL-8007 net 'addr_r[31]' is constantly driven from multiple places**。
          else if ((flag_r == S_STRM) && read_req && (read_addr == (addr_r + 32'd1)))
              addr_r <= read_addr;
      end
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              read_tx_data <= 8'hFF;
          else if (start_read)
              read_tx_data <= stream_en ? CMD18 : CMD17;  // 命令按"这一笔事务"的流式开关选
          else if (flag_r == S_CMD && send_done) begin
              if (send_cnt == 4'd0)       read_tx_data <= addr_r[31:24];
              else if (send_cnt == 4'd1)  read_tx_data <= addr_r[23:16];
              else if (send_cnt == 4'd2)  read_tx_data <= addr_r[15:8];
              else if (send_cnt == 4'd3)  read_tx_data <= addr_r[7:0];
              else                        read_tx_data <= 8'hFF;
          end
          // ★★★ 2026-10-17【收流必须发 CMD12】：CMD12 = 0x4C + 4 字节 0 + 0xFF
          //   上板教训：只"撤 CS"结束多块读，真卡不会干净退出 —— 图像那一趟能读完，
          //   但随后的音频/字幕装载全部失败（fail=1）。⇒ 收流时按规范补 CMD12。
          else if (flag_r == S_STRME && c12_rcv == 4'd0 && !send_done)
              read_tx_data <= CMD12;                 // 第一个字节 = 命令码
          else if (flag_r == S_STRME && send_done) begin
              if (send_cnt == 4'd0)       read_tx_data <= 8'h00;
              else if (send_cnt == 4'd1)  read_tx_data <= 8'h00;
              else if (send_cnt == 4'd2)  read_tx_data <= 8'h00;
              else if (send_cnt == 4'd3)  read_tx_data <= 8'h00;
              else                        read_tx_data <= 8'hFF;
          end
      end
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              send_cnt <= 4'd0;
          else if (start_read)
              send_cnt <= 4'd0;
          // ★ 2026-10-17【收流 CMD12】进入 S_STRME 前把发送字节序号清零（CMD12 也要 6 个字节）
          else if (flag_r == S_STRM)
              send_cnt <= 4'd0;
          else if ((flag_r == S_CMD || flag_r == S_STRME) && send_done)
              send_cnt <= send_cnt + 1'b1;
      end
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n) begin
              flag_r    <= S_IDLE;
              spi_start <= 1'b0;
              spi_end   <= 1'b0;
              cmd_cnt   <= 3'd0;
              data_cnt  <= 9'd0;
              crc_cnt   <= 2'd0;
              time_out  <= 22'd0;
              idle_cnt  <= 16'd0;
              read_err  <= 1'b0;
              // ★ 2026-10-17 流式状态也要复位（否则流水号未定义）
              strm_to   <= 16'd0;
              strme_cnt <= 3'd0;
          end
          else if (flag_r == S_IDLE) begin
              if (start_read) begin
                  spi_start <= 1'b1;
                  flag_r    <= S_CMD;
                  idle_cnt  <= 16'd0;
                  cmd_cnt   <= 3'd0;
                  data_cnt  <= 9'd0;
                  crc_cnt   <= 2'd0;
                  time_out  <= 22'd0;
                  read_err  <= 1'b0;           
              end
              else begin
                  spi_start <= 1'b0;
                  if (idle_cnt != IDLE_MAX)     
                      idle_cnt <= idle_cnt + 1'b1;
              end
          end
          else if (flag_r == S_CMD) begin
              spi_start <= 1'b0;
              if (receive_done) begin
                  if (cmd_cnt == 3'd5) begin
                      flag_r   <= S_RESP;
                      time_out <= 22'd0;
                  end
                  else
                      cmd_cnt <= cmd_cnt + 1'b1;
              end
          end
          else if (flag_r == S_RESP) begin
              if (receive_done) begin
                  if (read_rx_data[7] == 1'b0) begin     
                      if (read_rx_data == 8'h00) begin    
                          flag_r   <= S_TOKEN;
                          time_out <= 22'd0;
                      end
                      else begin                          
                          read_err <= 1'b1;
                          flag_r   <= S_STOP;
                      end
                  end
                  else if (time_out >= TIME_OUT) begin   
                      read_err <= 1'b1;
                      flag_r   <= S_STOP;
                  end
                  else
                      time_out <= time_out + 1'b1;
              end
          end
          else if (flag_r == S_TOKEN) begin
              if (receive_done) begin
                  if (read_rx_data == 8'hFE) begin
                      flag_r   <= S_DATA;
                      data_cnt <= 9'd0;
                      // ★ 2026-10-17：`crc_cnt` 原来只在 `start_read` 清一次；
                      //   流式下一拍事务里有多块 ⇒ 必须**每块开头清**，否则第一块之后
                      //   S_CRC 会立刻以为"2 字节 CRC 收完了"。
                      crc_cnt  <= 2'd0;
                  end
                  else if (read_rx_data != 8'hFF) begin   
                      read_err <= 1'b1;
                      flag_r   <= S_STOP;
                  end
                  else if (time_out >= TIME_OUT) begin
                      read_err <= 1'b1;
                      flag_r   <= S_STOP;
                  end
                  else
                      time_out <= time_out + 1'b1;
              end
          end
          else if (flag_r == S_DATA) begin
              if (receive_done) begin
                  if (data_cnt == 9'd511)
                      flag_r <= S_CRC;
                  else
                      data_cnt <= data_cnt + 1'b1;
              end
          end
          else if (flag_r == S_CRC) begin
              if (receive_done) begin
                  if (strm_r) begin
                      // ★ 流式：**只吃 2 个 CRC 字节**就停（非流式那边吃 3 个是历史写法，
                      //   多吃的第 3 个字节在 CMD18 下可能正好是**下一块的数据 token**
                      //   ⇒ 那样会漏掉一整块）。吃完 ⇒ 进 S_STRM（CS 举着、时钟停住）。
                      if (crc_cnt == 2'd1) begin
                          strm_to <= 16'd0;
                          flag_r  <= S_STRM;
                      end
                      else
                          crc_cnt <= crc_cnt + 1'b1;
                  end
                  else if (crc_cnt == 2'd2)
                      flag_r <= S_STOP;
                  else
                      crc_cnt <= crc_cnt + 1'b1;
              end
          end
          else if (flag_r == S_STRM) begin
              // ============================================================
              //  ★ 2026-10-17【流式等待】：一块已经交付完，CS 还举着、SCLK 已停住。
              //    调用方要"下一块"（地址正好 +1）⇒ 不发任何命令，直接等它的数据 token；
              //    ★ 省掉的就是这一段：原来每块都要"撤 CS → CMD17 → 卡访问延迟(~120 µs) → token"。
              // ============================================================
              spi_start <= 1'b0;
              spi_end   <= 1'b0;                       // ★ CS 绝不能撤
              if (read_req && (read_addr == (addr_r + 32'd1))) begin
                  // ★ `addr_r` 的推进不在这里做（见上面那个 addr_r 的 always，单一驱动）
                  time_out <= 22'd0;
                  strm_to  <= 16'd0;
                  flag_r   <= S_TOKEN;
              end
              else if (read_req || (strm_to >= STRM_TO)) begin
                  // 跳到别的扇区（调用方不连续了）/ 等太久没人要 ⇒ 收流（发 CMD12）
                  strme_cnt <= 3'd0;
                  c12_rcv   <= 4'd0;
                  strm_to   <= 16'd0;
                  flag_r    <= S_STRME;
              end
              else
                  strm_to <= strm_to + 16'd1;
          end
          else if (flag_r == S_STRME) begin
              // ============================================================
              //  ★ 2026-10-17【收流 = 发 CMD12 再撤 CS】
              //    上板教训：只把在途字节吃掉就撤 CS，真卡不会退出多块读 ——
              //    图像那一趟能读完（因为跑到底了），但**随后的音频/字幕装载全失败**
              //    （遥测：图写了 153600 字、`fail=1`、px 被清 0）。
              //    SPI 规范：多块读要用 CMD12(STOP_TRANSMISSION) 收尾。
              //    序列：发 6 字节命令 → 收 2 字节（stuff + R1，值不管）→ 撤 CS。
              // ============================================================
              spi_start <= 1'b0;
              if (c12_rcv < 4'd6) begin
                  if (receive_done) c12_rcv <= c12_rcv + 4'd1;
              end
              else if (c12_rcv < 4'd8) begin
                  if (receive_done) c12_rcv <= c12_rcv + 4'd1;
              end
              else begin
                  spi_end <= 1'b1;
                  flag_r  <= S_STOP;
              end
          end
          else begin
              if (spi_cs) begin
                  spi_end <= 1'b0;
                  flag_r  <= S_IDLE;
              end
              else
                  spi_end <= 1'b1;
          end
      end
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n) begin
              data_out  <= 8'd0;
              read_ok   <= 1'b0;
              read_done <= 1'b0;
          end
          else begin
              read_ok   <= 1'b0;
              read_done <= 1'b0;
              if (flag_r == S_DATA && receive_done) begin
                  data_out <= read_rx_data;
                  read_ok  <= 1'b1;
                  if (data_cnt == 9'd511)     
                      read_done <= 1'b1;
              end
          end
      end
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              read_busy <= 1'b0;
          else if (start_read)
              read_busy <= 1'b1;
          // ★ 2026-10-17【流式】：等待态先放低（让调用方的"看 !busy 再发请求"能通过），
          //   一旦看到"下一块"的请求就拉高（调用方那边靠 busy 上升完成握手）。
          else if (flag_r == S_STRM)
              read_busy <= (read_req && (read_addr == (addr_r + 32'd1)));
          else if (flag_r == S_STOP && spi_cs)
              read_busy <= 1'b0;
      end
       my_spi #(
          .data_width (8),
          .sck_div    (sck_div)
      ) u_my_spi (
          .sys_clk        (sys_clk),
          .sys_rst_n      (sys_rst_n),
          .spi_start      (spi_start),
          .spi_init_start (1'b0),
          .spi_end        (spi_end),
          .data_in        (read_tx_data),
          .send_done      (send_done),
          .receive_done   (receive_done),
          .data_out       (read_rx_data),
          .spi_miso       (spi_miso),
          .spi_clk        (spi_clk),
          .spi_cs         (spi_cs),
          .spi_mosi       (spi_mosi),
          .spi_clk_en     (spi_clk_en)      // ★ 流式等待时冻结 SCLK
      );
      endmodule

