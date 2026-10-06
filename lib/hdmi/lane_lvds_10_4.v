// ============================================================
//  lane_lvds_10_4 —— 用芯片 IO 里的【硬 4:1 串化器】做一条 HDMI 数据通道
//
//  【为什么要写这个】
//    老的 lane_lvds_10_1 是"用普通逻辑搭"的 2:1 串化器（移位寄存器 + ODDR），
//    所以 FPGA 的 fabric 自己必须跑在串化时钟上：
//        640x480  -> 125MHz  fabric 能跑
//        1024x768 -> 375MHz  fabric 跑不动（实测花屏）
//
//    这个模块改用芯片 IO 里现成的 EG_LOGIC_ODDRx2（硬 4:1 串化器）：
//        - 它一拍吃 4 位并行数据，用 sclk 的双边沿发出去
//        - 数据率 = 4 x I_pclk = 2 x I_sclk
//        - 对 1024x768@70：I_pclk = 187.5MHz、I_sclk = 375MHz
//          -> fabric 只需要跑 187.5MHz，是原来的一半
//
//  【本模块要解决的核心难题】
//    一个像素 10 位，而 ODDRx2 一次吃 4 位 —— 10 / 4 = 2.5，不是整数，
//    所以不能像老方案那样"每 5 个串化周期装载一次"。
//    这里用【打包 + 队列】解决：
//      - 打包：4 个像素 = 40 位 = 10 个 4 位组，正好整除
//      - 队列：像素域按包写、pclk 域按包读，一共 4 个包缓冲
//
//  【数据流】
//      像素域 I_pixel_clk (75MHz)
//          I_data_in[9:0] 每个像素一个字
//             |  攒 4 个像素 -> 40 位一包（先来的像素放高位 -> 先发）
//             v
//      4 包缓冲 buf0..buf3（各 40 位）+ 写指针
//             |  写指针用【格雷码】同步到 pclk 域
//             v
//      I_pclk 域 (187.5MHz)  每拍送出 4 位 + 读指针
//             v
//      EG_LOGIC_ODDRx2  ---> O_serial_out
//
//  【位序】下面第 4 段有详细说明：ODDRx2 是 d0 先发
//
//  【时钟相位】I_pclk 的边沿必须落在 I_sclk 两个上升沿【中间】（相位差 90°），
//    否则 ODDRx2 内部的 q20/q31 正好在输出选择那一刻翻转 -> 竞争 -> 输出乱。
//    这一条靠 PLL 的 phase_shift 实现（见 hdmi_phy_wrapper_x4.v 顶部说明）。
// ============================================================
module lane_lvds_10_4 #(
    parameter PKT_PIX = 4                    // 一包几个像素（4 个 = 40 位，正好被 4 整除）
)(
    input  wire       I_pixel_clk,           // 像素时钟（1024x768@70 -> 75MHz）
    input  wire       I_pclk,                // 并行时钟 187.5MHz（= 2.5 x 像素时钟，相位 +90 度）
    input  wire       I_sclk,                // 串化时钟 375MHz（= 2 x I_pclk）
    input  wire       I_rst,                 // 复位，高有效
    input  wire [9:0] I_data_in,             // 每个像素时钟进来一个 10 位 TMDS 字
    output wire       O_serial_out           // 串行位流（接差分输出的 _P）
);

    localparam PBITS = PKT_PIX * 10;         // 一包多少位（4 x 10 = 40）
    localparam NIB   = PBITS / 4;            // 一包几个 4 位组（40 / 4 = 10）

    // ============================================================
    //  第 1 段：像素域 —— 攒包，写进 4 包队列
    //
    //    每来一个像素，把新字塞到 acc 的低位（高位是先到的像素，
    //    这样一包里第一个像素落在最高位 -> 串化时先从它发出去）。
    //    攒满 PKT_PIX 个 = 一包，写进 bufN，然后写指针 +1。
    //
    //  【写指针为什么用格雷码】
    //    跨时钟域同步一个多位二进制计数器是危险的：0->1（00->01）只变 1 位没事，
    //    但 1->2（01->10）两位同时变，pclk 域可能采到"半路"的 11。
    //    格雷码保证【每步只变 1 位】-> 同步过去顶多差一步，不会采到错误值。
    //    4 包队列的格雷序列：00 -> 01 -> 11 -> 10 -> 00
    //    递推写法：gray_next = {gray[0], ~gray[1]}   （每步只翻最高位）
    // ============================================================
    reg [PBITS-1:0] acc;                     // 攒包用的移位寄存器
    reg [1:0]       pcnt;                    // 这一包已经攒了几个像素
    reg [1:0]       wr_bin;                  // 写指针（二进制，用来选缓冲）
    reg [1:0]       wr_gray;                 // 写指针（格雷码，用来跨时钟域）
    reg [PBITS-1:0] buf0, buf1, buf2, buf3;  // 4 包缓冲（给 pclk 域留 3 包余量）

    always @(posedge I_pixel_clk or posedge I_rst) begin
        if (I_rst) begin
            acc     <= {PBITS{1'b0}};
            pcnt    <= 2'd0;
            wr_bin  <= 2'd0;
            wr_gray <= 2'd0;
            buf0    <= {PBITS{1'b0}};
            buf1    <= {PBITS{1'b0}};
            buf2    <= {PBITS{1'b0}};
            buf3    <= {PBITS{1'b0}};
        end
        else begin
            // 左移 10 位，再把新像素放到低 10 位
            //   ★ 不能写成 acc << 10 然后 acc[9:0] <= ...（同一拍两次赋值，只有最后一次有效）
            acc <= {acc[PBITS-11:0], I_data_in};

            if (pcnt == PKT_PIX-1) begin
                // 这一拍刚好攒满 -> 整包写进 wr_bin 指定的缓冲
                case (wr_bin)
                    2'd0:    buf0 <= {acc[PBITS-11:0], I_data_in};
                    2'd1:    buf1 <= {acc[PBITS-11:0], I_data_in};
                    2'd2:    buf2 <= {acc[PBITS-11:0], I_data_in};
                    default: buf3 <= {acc[PBITS-11:0], I_data_in};
                endcase
                pcnt    <= 2'd0;
                wr_bin  <= wr_bin + 2'd1;
                wr_gray <= {wr_gray[0], ~wr_gray[1]};   // 格雷码递推（每步只变 1 位）
            end
            else begin
                pcnt <= pcnt + 1'b1;
            end
        end
    end

    // ============================================================
    //  第 2 段：把写指针（格雷码）搬进 I_pclk 域
    //    两级触发器：第 1 级可能采到亚稳态，第 2 级给它一个完整周期稳定下来
    //    （格雷码保证"同时只有 1 位在变"，所以这一步是安全的）
    // ============================================================
    reg [1:0] wg1, wg2;
    always @(posedge I_pclk or posedge I_rst) begin
        if (I_rst) begin wg1 <= 2'd0; wg2 <= 2'd0; end
        else       begin wg1 <= wr_gray; wg2 <= wg1; end
    end

    // ============================================================
    //  第 3 段：I_pclk 域 —— 把一包 40 位拆成 10 个 4 位组，每拍送一组
    //    · 装载时把"最高的 4 位"直接送给 ODDRx2，同时把 sh 左移 4 位
    //      （这样下一拍 sh 的最高 4 位就是第 2 组，两者对齐）
    //
    //  ★★ 这一版最重要的改动 ★★
    //    老写法：写端翻转一个 toggle，读端用 t2^t3 检边沿得到【一拍宽的脉冲】。
    //    脉冲的毛病：**那一拍如果正好在忙（busy=1），就被漏掉了**。
    //    而读端的节奏是"10 拍读完一包、下一包正好第 10 拍到"，一点余量都没有
    //    -> 真机上时钟一抖就会漏包 -> 整段数据错位 -> 屏幕上花纹乱跳。
    //
    //    新写法是【电平比较】：have_pkt = (写指针 != 我的读指针)
    //      它是一个"电平"：只要还有没读的包就一直是 1 -> **不可能漏**。
    //      再加上 4 包缓冲，读端最多可以落后 3 包，抖动余量很足。
    // ============================================================
    reg [PBITS-1:0] sh;                      // 消费用的移位寄存器
    reg [3:0]       nib_cnt;                 // 这一包已经发了几组（0 ~ NIB-1）
    reg             busy;                    // 正在发一包
    reg [3:0]       d_out;                   // 送给 ODDRx2 的 4 位数据
    reg [1:0]       rd_bin;                  // 读指针（二进制，用来选缓冲）
    reg [1:0]       rd_gray;                 // 读指针（格雷码，用来和写指针对比）

    wire have_pkt = (wg2 != rd_gray);        // 电平判断：还有没读的包

    // 按读指针选出这一包（4 选 1）
    wire [PBITS-1:0] pkt_rd = (rd_bin == 2'd0) ? buf0 :
                              (rd_bin == 2'd1) ? buf1 :
                              (rd_bin == 2'd2) ? buf2 : buf3;

    always @(posedge I_pclk or posedge I_rst) begin
        if (I_rst) begin
            sh      <= {PBITS{1'b0}};
            nib_cnt <= 4'd0;
            busy    <= 1'b0;
            d_out   <= 4'd0;
            rd_bin  <= 2'd0;
            rd_gray <= 2'd0;
        end
        else if (!busy) begin
            // 空闲：只要还有没读的包，就立刻开始发它
            if (have_pkt) begin
                sh      <= {pkt_rd[PBITS-5:0], 4'd0};   // 左移 4 位，准备下一拍
                d_out   <= pkt_rd[PBITS-1 -: 4];        // 第 1 组：最高 4 位
                nib_cnt <= 4'd1;
                busy    <= 1'b1;
                rd_bin  <= rd_bin + 2'd1;               // 这一包收下了，读指针 +1
                rd_gray <= {rd_gray[0], ~rd_gray[1]};
            end
        end
        else begin
            // 忙：这一拍把 sh 的最高 4 位送出去，然后左移
            d_out <= sh[PBITS-1 -: 4];
            sh    <= {sh[PBITS-5:0], 4'd0};
            if (nib_cnt == NIB-1) begin
                busy    <= 1'b0;             // 这一包发完了
                nib_cnt <= 4'd0;
            end
            else begin
                nib_cnt <= nib_cnt + 4'd1;
            end
        end
    end

    // ============================================================
    //  第 4 段：硬 4:1 串化器
    //    位序（实测出来的，不是猜的）：
    //      EG_LOGIC_ODDRx2 内部是"三级 ODDR 级联"，最外面那一级是
    //          q = clk 高电平 ? true_reg : comp_reg[1]
    //      也就是 d0 先发、然后 d1、d2、d3。
    //      所以"最先要发出去的那一位"必须接 d0，不是 d3。
    //
    //      d_out 里：[3] 是这一组的第 1 位、[0] 是第 4 位
    //      -> 映射要反过来：d0<-d_out[3]、d1<-d_out[2]、d2<-d_out[1]、d3<-d_out[0]
    //
    //      （踩过的坑：一开始按"d3 先发"接，结果每一组的 4 位都被倒着发，
    //        收到的位流里 '1' 的间距变成 7/14 交替，而不是整齐的 10。）
    // ============================================================
    EG_LOGIC_ODDRx2 #(
        .ASYNCRST ("ENABLE")
    ) u_oddrx2 (
        .q    (O_serial_out),
        .pclk (I_pclk),
        .sclk (I_sclk),
        .d3   (d_out[0]),
        .d2   (d_out[1]),
        .d1   (d_out[2]),
        .d0   (d_out[3]),
        .rst  (I_rst)
    );

endmodule
