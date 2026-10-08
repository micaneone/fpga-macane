  module sd_top(
      input         sys_clk,
      // ★★ 2026-10-08【集成临时改动 · 提速到 25 MHz】读移位器用这根时钟
      //   （顶层给 100 MHz ⇒ SCLK = 25 MHz；给 sys_clk 就是原来的 12.5 MHz）
      input         clk_spi,
      input         sys_rst_n,
      input         spi_miso,
      output        spi_mosi,
      output        spi_clk,
      output        spi_cs,
      input  [31:0] read_addr,
      input         read_req,
      output [7:0]  data_out,
      output        read_busy,
      output        read_ok,
      output        read_done,
      output        read_err,
      output reg    led1,
      output reg    bus_owner
  );
      wire init_done;
      wire i_clk, i_cs, i_mosi;
      wire r_clk, r_cs, r_mosi;
      wire init_phase = ~bus_owner;
      assign spi_clk  = init_phase ? i_clk  : r_clk;
      assign spi_cs   = init_phase ? i_cs   : r_cs;
      assign spi_mosi = init_phase ? i_mosi : r_mosi;
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              bus_owner <= 1'b0;
          else if (init_done && i_cs)
              bus_owner <= 1'b1;
      end
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n)
              led1 <= 1'b0;
          else if (init_done)
              led1 <= 1'b1;
      end
      sd_init u_sd_init (
          .sys_clk   (sys_clk),
          .sys_rst_n (sys_rst_n),
          .init_done (init_done),
          .spi_mosi  (i_mosi),
          .spi_miso  (spi_miso),
          .spi_clk   (i_clk),
          .spi_cs    (i_cs)
      );
      // ★★ 2026-10-08【集成临时改动 · SD 读提速到 25 MHz】（见 规划\A轨待改清单.md 第十一条）
      //  这里原来是 `sd_read`（接 50 MHz ⇒ SCLK = 12.5 MHz）。
      //  现在外面套一层 `sd_read_cdc`：**真 sd_read 一个字没改**，只是被搬到
      //  `clk_spi`（= 100 MHz）上跑 ⇒ SCLK = 100/4 = **25 MHz**；
      //  对外端口与 sd_read 逐位相同（read_req/read_addr/read_busy/read_ok/
      //  read_done/read_err/data_out/spi_*），所以上层（find_bmp）一个字不用改。
      //  ★ 为什么不是"只把 my_spi 搬快"：见 sd_read_cdc.v 头部 —— 25 MHz 下一个字节
      //    只有 40 ns 就要换下一个，跨域往返 80 ns 来不及（仿真 tb_spi_cdc_bridge 抓到）。
      sd_read_cdc u_sd_read (
          .sys_clk   (sys_clk),
          .sys_rst_n (sys_rst_n),
          .clk_fast  (clk_spi),          // ★ 100 MHz ⇒ SCLK = 25 MHz
          .init_done (bus_owner),
          .read_req  (read_req),
          .read_addr (read_addr),
          .read_busy (read_busy),
          .read_ok   (read_ok),
          .read_done (read_done),
          .read_err  (read_err),
          .data_out  (data_out),
          .spi_mosi  (r_mosi),
          .spi_miso  (spi_miso),
          .spi_clk   (r_clk),
          .spi_cs    (r_cs)
      );

  endmodule
