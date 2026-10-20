module sd_init(
    input sys_clk,
    input sys_rst_n,
    output reg init_done,
    output spi_mosi,
    input spi_miso,
    output spi_clk,
    output spi_cs
  
);
parameter sck_div=35;
parameter DATA_WIDTH = 8;
reg [7:0]init_tx_data;
wire [7:0]init_rx_data;
wire send_done;
wire receive_done;
reg spi_start;
reg spi_init_start;
reg spi_end;
reg [3:0]flag;
reg [19:0]delay_cnt;
reg delay_done;
reg [6:0] send_cnt;
reg [6:0]time_out;
reg [3:0] flag_d;
always @(posedge sys_clk or negedge sys_rst_n)begin
      if(!sys_rst_n)
          flag_d<=4'd0;
      else
          flag_d<=flag;
  end
always @(posedge sys_clk or negedge sys_rst_n)begin
    if(!sys_rst_n)
    send_cnt<=7'd0;
    else if(send_done)
    send_cnt<=send_cnt+1'b1;
    else if(flag!=flag_d)         
    send_cnt<=7'd0;
    else if(time_out==7'd99)
    send_cnt<=7'd0;
    else if(delay_done)
    send_cnt<=7'd0;

end
always @(posedge sys_clk or negedge sys_rst_n)begin
     if(!sys_rst_n)begin
        delay_cnt<=20'd0;
        delay_done<=1'b0;
     end
     else if(delay_cnt<20'd50000&&flag==4'd1)
     delay_cnt<=delay_cnt+1'b1;
     else if(delay_cnt==20'd50000&&flag==4'd1)
     delay_done<=1'b1;
     else if(flag!=4'd1)
     delay_done<=1'b0;
end
always @(posedge sys_clk or negedge sys_rst_n)begin
    if(!sys_rst_n)begin
    flag<=4'd0;
    spi_start<=1'b0;
    spi_init_start<=1'b0;
    time_out<=6'd0;
    init_tx_data<=8'hFF;
    spi_end<=1'b0;
    init_done<=1'b0;
    end
    else if(flag==4'd0)
    flag<=4'd1;
    else if(flag==4'd1)begin
        spi_init_start<=1'b1;
         if(delay_done)begin
            flag<=4'd2;
            spi_init_start<=1'b0;
        end
    end
    else if(flag==4'd2)begin
        spi_start<=1'b1;
        if(send_cnt==7'd0)
        init_tx_data<=8'h40;
        else if(send_cnt==7'd1)
        init_tx_data<=8'h00;
        else if(send_cnt==7'd2)
        init_tx_data<=8'h00;
        else if(send_cnt==7'd3)
        init_tx_data<=8'h00;
         else if(send_cnt==7'd4)
        init_tx_data<=8'h00;
        else if(send_cnt==7'd5)
        init_tx_data<=8'h95;
        else if(send_cnt>=7'd6)begin
            init_tx_data<=8'hFF;
            if(receive_done)begin
            if(init_rx_data==8'h01)begin
            flag<=4'd3;
            // spi_end<=1'b1;
            // spi_start<=1'b0;
            time_out<=7'd0;
            end
            else if(init_rx_data!=8'h01&&time_out<7'd100)
            time_out<=time_out+1'b1;
            else begin
            time_out<=7'd0;
            end
            end
        end
    end
    else if(flag==4'd3)begin
        spi_start<=1'b1;
        if(send_cnt==7'd0)      init_tx_data<=8'h48;
        else if(send_cnt==7'd1) init_tx_data<=8'h00;
        else if(send_cnt==7'd2) init_tx_data<=8'h00;
        else if(send_cnt==7'd3) init_tx_data<=8'h01;
        else if(send_cnt==7'd4) init_tx_data<=8'hAA;
        else if(send_cnt==7'd5) init_tx_data<=8'h87;
        else begin
        init_tx_data<=8'hFF;
        if(receive_done)begin
        if(init_rx_data==8'h01)begin    
            time_out<=7'd0;              
            flag<=4'd4;
        end
        else if(time_out<7'd100)
        time_out<=time_out+7'd1;
        else                    
            time_out<=7'd0;
            end    
        end
    end
     else if(flag==4'd4)begin
         spi_start<=1'b1;
        init_tx_data<=8'hFF;
        if(receive_done)begin
        if(time_out==7'd5)begin
        time_out<=7'd0;
        // spi_start<=1'b0;
        // spi_end<=1'b1;
        flag<=4'd5;                      // → ACMD41
         end
        else
        time_out<=time_out+7'd1;
        end
    end
      else if(flag==4'd5)begin
      spi_start<=1'b1;
      if(send_cnt==7'd0)      init_tx_data<=8'h77;
      else if(send_cnt==7'd1) init_tx_data<=8'h00;
      else if(send_cnt==7'd2) init_tx_data<=8'h00;
      else if(send_cnt==7'd3) init_tx_data<=8'h00;
      else if(send_cnt==7'd4) init_tx_data<=8'h00;
      else if(send_cnt==7'd5) init_tx_data<=8'h01;
      else begin
          init_tx_data<=8'hFF;
          if(receive_done)begin
              if(init_rx_data==8'h01)begin        
                  time_out<=7'd0;
                  flag<=4'd6;                    
              end
              else if(time_out<7'd100)
                  time_out<=time_out+7'd1;
              else begin                           
                  time_out<=7'd0;
              end
          end
      end
  end
  else if(flag==4'd6)begin
    spi_start<=1'b1;
      if(send_cnt==7'd0)      init_tx_data<=8'h69;
      else if(send_cnt==7'd1) init_tx_data<=8'h40;   
      else if(send_cnt==7'd2) init_tx_data<=8'h00;
      else if(send_cnt==7'd3) init_tx_data<=8'h00;
      else if(send_cnt==7'd4) init_tx_data<=8'h00;
      else if(send_cnt==7'd5) init_tx_data<=8'h01;
      else begin
          init_tx_data<=8'hFF;
          if(receive_done)begin
              if(init_rx_data==8'h00)begin      // 初始化完成
                  time_out<=7'd0;
                //   spi_start<=1'b0;
                //   spi_end<=1'b1;
                  flag<=4'd7;                 
              end
              else if(init_rx_data==8'h01)begin 
                  time_out<=7'd0;
                  flag<=4'd5;                  
              end
              else if(time_out<7'd100)
                  time_out<=time_out+7'd1;
              else begin                       
                  time_out<=7'd0;
                  flag<=4'd5;
              end
          end
      end
  end
  else if(flag==4'd7)begin
    init_done<=1'b1;
     spi_start<=1'b0;
    spi_end<=1'b1;
  end
end

my_spi #(
    .data_width(DATA_WIDTH),
    .sck_div(sck_div)
)u_my_spi(
    .sys_clk(sys_clk),
    .sys_rst_n(sys_rst_n),
    .spi_start(spi_start),       // 由初始化逻辑控制触发
    .spi_end(spi_end),           // 由接收完成信号同步
    .data_in(init_tx_data),      // 待发送的初始化数据
    .spi_init_start(spi_init_start),           // 时钟分频值
    .send_done(send_done),       // 发送完成标志
    .receive_done(receive_done), // 接收完成标志
    .data_out(init_rx_data),     // 接收数据
    .spi_miso(spi_miso),
    .spi_clk(spi_clk),
    .spi_cs(spi_cs),
    .spi_mosi(spi_mosi),
    // ★★★ 2026-10-17：`my_spi` 新增了 SCLK 使能（给 CMD18 多块读"两块之间停时钟"用）。
    //   初始化这条**必须恒 1**（漏接会悬空成 z ⇒ 初始化时钟不走 ⇒ 卡永远 init 不完）。
    .spi_clk_en(1'b1)
);
endmodule