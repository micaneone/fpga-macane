  module sd_top(
      input         sys_clk,
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
      sd_read u_sd_read (
          .sys_clk   (sys_clk),
          .sys_rst_n (sys_rst_n),
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