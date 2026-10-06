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
      output          spi_cs
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
      localparam S_IDLE  = 4'd0;
      localparam S_CMD   = 4'd1;
      localparam S_RESP  = 4'd2;
      localparam S_TOKEN = 4'd3;
      localparam S_DATA  = 4'd4;
      localparam S_CRC   = 4'd5;   
      localparam S_STOP  = 4'd6;

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

      wire start_read = (flag_r == S_IDLE) && read_req && init_done
                      && (idle_cnt == IDLE_MAX);
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              addr_r <= 32'd0;
          else if (start_read)
              addr_r <= read_addr;     
      end
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              read_tx_data <= 8'hFF;
          else if (start_read)
              read_tx_data <= CMD17;
          else if (flag_r == S_CMD && send_done) begin
              if (send_cnt == 4'd0)       read_tx_data <= addr_r[31:24];
              else if (send_cnt == 4'd1)  read_tx_data <= addr_r[23:16];
              else if (send_cnt == 4'd2)  read_tx_data <= addr_r[15:8];
              else if (send_cnt == 4'd3)  read_tx_data <= addr_r[7:0];
              else                        read_tx_data <= 8'hFF;
          end
      end
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              send_cnt <= 4'd0;
          else if (start_read)
              send_cnt <= 4'd0;
          else if (flag_r == S_CMD && send_done)
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
                  if (crc_cnt == 2'd2)
                      flag_r <= S_STOP;
                  else
                      crc_cnt <= crc_cnt + 1'b1;
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
          .spi_mosi       (spi_mosi)
      );
      endmodule

