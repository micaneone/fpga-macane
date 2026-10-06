


// ============================================================
//  lane_lvds_10_1 —— 10:1 串化器（一条 HDMI 数据通道）
//
//  干什么：把一个像素时钟周期里的 10 位 TMDS 字，用 5 倍的时钟
//          （双边沿，每拍出 2 位）串行地推出去。
//              5 拍 × 2 位 = 10 位 ✓
//
//  ★ 它是【用普通逻辑搭的】串化器（移位寄存器 + ODDR），
//    所以 FPGA 的 fabric 本身要跑在 I_serial_clk 上 ——
//    这就是"分辨率越高越难做"的根源（见 原理-HDMI.md §8.4）：
//      640x480  → 125MHz  稳
//      1024x768 → 325MHz  很紧，要实测
//
//  最值得看的一处：它怎么把"边界在哪"从像素时钟域搬到串化时钟域
//  （odd_even 打两拍 + 两次采样异或找边沿）。
// ============================================================
module lane_lvds_10_1 #(
    parameter DEVICE = "EG"              // 器件系列，决定用哪个 ODDR 原语
    )(
    input wire      I_pixel_clk,         // 像素时钟 25MHz
    input wire      I_serial_clk,        // 串化时钟 125MHz（= 5 × 像素时钟）
    input wire      I_rst,               // 复位，★高有效

    input wire[9:0] I_data_in,           // 一个像素要发的 10 位（位序已由 wrapper 翻好）
//
    output wire     O_serial_out          //串行位流（接差分输出的 _P）
);

    reg      S_odd_even;      // 像素时钟域：每隔一个像素周期翻转一次，用来标"边界"
    reg      S_odd_even_1d;   // 搬到串化时钟域的第一级
    reg      S_odd_even_2d;   // 第二级
    reg      S_load_en;       // 两级采样不一致 = 采样到了 odd_even 的跳变 = 该装载新数据了
    reg      S_load_en_1d;    // load_en 再打两拍，和移位寄存器的时序对齐
    reg      S_load_en_2d;
    reg[9:0] S_shift_data;    // 移位寄存器：每拍左移 2 位
    reg[1:0] S_oddr_data;     // 送给 ODDR 的这 2 位（d1 先出、d0 后出）


    // 1) 像素时钟域：每来一个像素周期翻转一次
    always @(posedge I_pixel_clk or posedge I_rst) begin
        if(I_rst)
            S_odd_even <= 1'b0;
        else
            S_odd_even <= ~S_odd_even;
    end

    // 2) 把 odd_even 搬进串化时钟域（打两拍）
    always @(posedge I_serial_clk) begin
        S_odd_even_1d <= S_odd_even;
        S_odd_even_2d <= S_odd_even_1d;
    end

    // 3) 两级采样不一致 -> 说明刚跨过边界 -> 出一拍 load_en
    always @(posedge I_serial_clk) begin
        S_load_en    <= S_odd_even_1d ^ S_odd_even_2d;
        S_load_en_1d <= S_load_en;
        S_load_en_2d <= S_load_en_1d;
    end

    // 4) 移位寄存器：该装载时装入 10 位，平时每拍左移 2 位
    always @(posedge I_serial_clk or posedge I_rst) begin
        if(I_rst)
            S_shift_data <= 'd0;
        else
            if(S_load_en_2d)
                S_shift_data <= I_data_in;
            else 
                S_shift_data <= S_shift_data << 2;
    end

    // 5) 每次取最高的 2 位给 ODDR（双边沿 -> 一拍出 2 位）
    always @(posedge I_serial_clk) begin
        S_oddr_data <= S_shift_data[9:8];
    end

    // 6) ODDR 原语：d1 在下降沿出、d0 在上升沿出，合起来正好 2 位
    //    下面一长串是【8 个器件型号的分支】，只有 "EG"（我们的 EG4S20）那一段有用，
    //    其余 7 段是别的芯片的 ODDR，原样保留不用管。
    generate
        if(DEVICE == "EF2")
            begin
                EF2_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF3")
            begin
                EF3_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF4")
            begin
                EF4_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "SF1")
            begin
                SF1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EG")
            begin
                EG_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1A")
            begin
                PH1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1P")
            begin
                PH1P_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "DR1")
            begin
                DR1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
    endgenerate
    
endmodule
