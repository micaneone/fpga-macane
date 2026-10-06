// ============================================================
//  hdmi_phy_wrapper —— HDMI 的"物理层"外壳（官方例程自带，可读）
//
//  它只干两件事：
//    1) 把核送来的 4 路 10bit TMDS 字【位序反过来】再往下送
//       （核是"低位先发"，串化器是"高位先发"，所以必须翻一下）
//    2) 例化 4 个 lane_lvds_10_1，把 4 路 10bit 并行字串化成 4 根差分线
//
//  这一层和分辨率【无关】：分辨率变化只影响时钟频率，不影响这里接什么。
//
//  ★ 文件名里的 "warpper" 是官方的拼写错误（应该是 wrapper），
//    文件名叫什么都行，模块名是 hdmi_phy_wrapper（正确拼写）。
// ============================================================
module hdmi_phy_wrapper#(
    parameter DEVICE = "EG"              // 器件系列，我们填 "EG"
    )(
    input wire      I_pixel_clk,         // 像素时钟 25MHz
    input wire      I_serial_clk,        // ★ 串化时钟 = 5 × 像素时钟 = 125MHz
    input wire      I_rst,               // 复位，★高有效

    // 4 路 10bit TMDS 字，来自 HDMI 核
    input wire[9:0] I_tmds_channel_0,    // 蓝 + HSYNC + VSYNC
    input wire[9:0] I_tmds_channel_1,    // 绿
    input wire[9:0] I_tmds_channel_2,    // 红
    input wire[9:0] I_tmds_channel_clk,  // 时钟通道（固定图案）

    // 4 根差分输出（只出 _P，负端由工具自动配对）
    output wire     O_tmds_ch0_p,        // → HDMI_D0_P
    output wire     O_tmds_ch1_p,        // → HDMI_D1_P
    output wire     O_tmds_ch2_p,        // → HDMI_D2_P
    output wire     O_tmds_clk_p         // → HDMI_CLK_P
);
    
    wire[9:0] S_tmds_data_ch0;           // 位序翻转之后的 4 路数据
    wire[9:0] S_tmds_data_ch1;
    wire[9:0] S_tmds_data_ch2;
    wire[9:0] S_tmds_data_clk;

    // ------------------------------------------------------------
    //  下面 4 个 assign 是【同一件事做 4 遍】：把 10 位整个倒过来。
    //  写法 {in[0],in[1],...,in[9]} 的结果就是 bit0 跑到最高位、bit9 跑到最低位。
    //  为什么必须翻：核输出的位序和串化器需要的位序相反（一个低位先发一个高位先发）。
    //  这不是写错了，是接口约定 —— 别"优化"掉。
    //  （ch0 / ch1 / ch2 / clk 四段完全一样，只是通道不同）
    // ------------------------------------------------------------
    assign S_tmds_data_ch0 = {I_tmds_channel_0[0],
                              I_tmds_channel_0[1],
                              I_tmds_channel_0[2],
                              I_tmds_channel_0[3],
                              I_tmds_channel_0[4],
                              I_tmds_channel_0[5],
                              I_tmds_channel_0[6],
                              I_tmds_channel_0[7],
                              I_tmds_channel_0[8],
                              I_tmds_channel_0[9]};

    assign S_tmds_data_ch1 = {I_tmds_channel_1[0],
                              I_tmds_channel_1[1],
                              I_tmds_channel_1[2],
                              I_tmds_channel_1[3],
                              I_tmds_channel_1[4],
                              I_tmds_channel_1[5],
                              I_tmds_channel_1[6],
                              I_tmds_channel_1[7],
                              I_tmds_channel_1[8],
                              I_tmds_channel_1[9]};

    assign S_tmds_data_ch2 = {I_tmds_channel_2[0],
                              I_tmds_channel_2[1],
                              I_tmds_channel_2[2],
                              I_tmds_channel_2[3],
                              I_tmds_channel_2[4],
                              I_tmds_channel_2[5],
                              I_tmds_channel_2[6],
                              I_tmds_channel_2[7],
                              I_tmds_channel_2[8],
                              I_tmds_channel_2[9]};

    assign S_tmds_data_clk = {I_tmds_channel_clk[0],
                              I_tmds_channel_clk[1],
                              I_tmds_channel_clk[2],
                              I_tmds_channel_clk[3],
                              I_tmds_channel_clk[4],
                              I_tmds_channel_clk[5],
                              I_tmds_channel_clk[6],
                              I_tmds_channel_clk[7],
                              I_tmds_channel_clk[8],
                              I_tmds_channel_clk[9]};


    // ---- 4 个串化器，每个负责一个通道（4 个实例完全一样）----
    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u0_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),   // 25MHz
        .I_serial_clk ( I_serial_clk    ),   // 125MHz
        .I_rst        ( I_rst           ),   // 高有效

        .I_data_in    ( S_tmds_data_ch0 ),   // 10bit，已翻转位序
        .O_serial_out ( O_tmds_ch0_p    )    // 串行位流 -> 差分输出
    );


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u1_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),
        
        .I_data_in    ( S_tmds_data_ch1 ),
        .O_serial_out ( O_tmds_ch1_p    )
    );


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u2_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),
        
        .I_data_in    ( S_tmds_data_ch2 ),
        .O_serial_out ( O_tmds_ch2_p    )
    );


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u3_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),
        
        .I_data_in    ( S_tmds_data_clk ),
        .O_serial_out ( O_tmds_clk_p    )
    );


endmodule





