// ============================================================
//  模块名 : dbg_report（测试件，不进交付仓库）
//  作用   : 每 0.5 秒往串口（115200 8N1）打【一条定长帧】
// ------------------------------------------------------------
//  ★ 2026-09-27 改成"定长紧凑帧"：
//    原来是带标签的文本（W=xxxxxx S=xx ...），字段一多就长得没法看。
//    现在一条帧 = 【21 个 16 位数，每个 4 位十六进制】，连成一串 84 个字符，
//    最后 CR/LF 结束。字段位置固定，读的人（或脚本）按位置解释。
//
//    位序（每个 4 位十六进制 = 一个 16 位数，29 个）：
//      00  : W[15:0]      —— 存储封装一共交接了多少字（低 16 位）
//      01  : W[23:16]
//      02  : 状态字节 S（bit0 PLL / bit1 SD / bit2 装载中 / bit3 装完过
//                         / bit4 A报错 / bit5 越界 / bit6 奇数 / bit7 HDMI锁）
//      03  : 帧号低 8 位 F
//      04  : 错像素计数 R[23:16]（自测地址图模式下，显示全对应当是 0）
//      05  : 错像素计数 R[15:0]
//      06  : 显示探针：行 0 / 128（每帧交替）的 u=0 那个像素的值
//      07  :            行 1 / 208
//      08  :            行 2 / 256
//      09  :            行 3 / 479
//            ★ 地址图里"值 = 字地址"，所以第 v 行的期望值是 v*320（低 16 位）：
//              行 0->0000  1->0140  2->0280  3->03C0
//              128->A000  208->0400  256->4000  479->56C0
//      10  : 搬运请求被丢的次数（那一行会显示底色）
//      11  : 看门狗掐断搬运的次数
//      12  : 0 = 上面四个是"行 0/1/2/3"，1 = "行 128/208/256/479"
//      13  : 行缓冲探针：我请求的行首地址（期望 0400）
//      14  : 行缓冲探针：实际收到的第 1 个字（期望 0400）
//      15  : 行缓冲探针：实际收到的第 2 个字（期望 0401）
//      16  : 行缓冲探针：这一趟要读多少字（期望 0140）
//            ★ 13 和 14 一比就知道"是读回来就偏了，还是显示的时候才偏"
//            ★★ 这四个值在【每个帧开头冻结在同一拍】，所以它们一定来自
//               【同一行的那一次搬运】，可以放心对比
//      17  : 当前"在途请求上限"档位（key1 每按一次 +1，0..4 循环）
//            0=8  1=16（原来的）  2=32  3=64  4=128
//      18  : key1 一共按了多少次（用来确认按键真的被采到了）
//      19  : 逐字校验：上一趟收到的【第 1 个字】比请求行首偏了几个字
//      20  : 逐字校验：上一趟有【几个字】和期望地址对不上（0 = 逐字全对）
//            ★ 这两个数只对"地址图"有意义（地址图里字的值 = 它的地址）。
//            ★ 期望：上限 16 时 19=+3、20=320（整行全偏）；
//                    调到某个档（怀疑 64）后 19=0、20=0 → 图就逐像素正确了。
//      21  : 读口自测（M0 读法移植）：收到多少个"有效"（期望 0800 = 2048）
//      22  :                          其中多少个和期望地址对不上（0 = 全对）
//      23  :                          第 1 个字偏几个（0 = 无偏移）
//      24  :                          第 1 个字的低 16 位
//      25..28 : 自测头 4 个字的低 16 位（看"每 4 个字重复一次"的花样还在不在）
//            ★ 这四个数在开机后 50ms 跑一次就固定了：
//              22=0 → "M0 读法"在这套布局布线下是准的（问题在驱动方式）
//              22≠0 → 这一版的布局布线/约束有问题（问题不在代码）
//      29 : ★★ 2026-10-01 实验一【SDRAM 忙 / 刷新 sticky 位图】
//              bit0  Sdr_init_ref_vld 曾经高过（刷新标志真的会动吗）
//              bit1  Sdr_busy         曾经高过（忙标志真的会动吗）
//              bit2  写使能有效期间 Sdr_init_ref_vld 也高过  ← 撞车
//              bit3  写使能有效期间 Sdr_busy         也高过  ← 撞车
//              bit4  写使能曾经有效过（量的是不是东西，自检用）
//            → bit0=bit1=0 就是"SDRAM 这两根线根本不动"，
//              那"读写没管 busy 所以丢字"这条猜测当场就被否掉。
//      30 : Sdr_busy 拉高的次数（16 位，饱和）
//      31 : 写使能有效期间 Sdr_busy 高的拍数（16 位，饱和）  ← 关键数
//      32 : 写使能有效期间 Sdr_init_ref_vld 高的拍数（16 位，饱和）
//            ★ 29..32 全部在 clk（50MHz）域统计：先把三根线各同步两拍再数。
//              所以"拍数"的单位是 50MHz 拍（125MHz 拍的 2.5 倍），
//              绝对值差 2.5 倍，但"0 / 非 0"和数量级不受影响。
//
//  ★ 用 lib 里的 UART_sendchar（en 一拍脉冲、busy 高时不能重复触发）
//  ★ 索引 idx 的位宽必须装得下 NB —— 这个坑踩过两次了
// ============================================================
`timescale 1ns / 1ps

module dbg_report #(
    parameter integer CLK_HZ    = 50_000_000,
    parameter integer PERIOD_MS = 500
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [23:0] val,          // ① ② W
    input  wire [7:0]  status,       // ③
    input  wire [7:0]  frm,          // ④
    input  wire [23:0] bad,          // ⑤ ⑥

    input  wire [15:0] row0, row1, row2, row3,   // A 组
    input  wire [15:0] row4, row5, row6, row7,   // B 组

    input  wire [15:0] drop_cnt,     // ⑲
    input  wire [15:0] abort_cnt,    // ⑳
    // 行缓冲自己的探针（盯住"行首 = 0x10400"那一次搬运）
    input  wire [15:0] lb_wbase,     // ㉒ 我请求的行首地址（期望 0400）
    input  wire [15:0] lb_rd0,       // ㉓ 实际收到的第 1 个字（期望 0400）
    input  wire [15:0] lb_rd1,       // ㉔ 实际收到的第 2 个字（期望 0401）
    input  wire [15:0] lb_words,     // ㉕ 要读多少个字（期望 0140）
    input  wire [15:0] lb_off,       // 第 1 个字比请求行首偏了几个字（地址图专用）
    input  wire [15:0] lb_alignbad,  // 上一趟几个字对不上（0 = 逐字全对）
    input  wire [15:0] cmp_sel,      // 当前读口偏移补偿值（key1 调）
    input  wire [15:0] key_cnt,      // key1 一共按了多少次
    // ★★ 2026-10-05：音频仲裁 tag 队列"脱钩过"的 sticky 标志
    //    字段 12 的 bit1（bit0 仍是 reppar，解释字段 6..9 时要看它）
    input  wire        tag_bad,
    // ---- 读口自测（M0 读法移植，见 rtl\rd_selftest.v）----
    input  wire [15:0] st_read_cnt,  // 自测一共收到多少个"有效"
    input  wire [15:0] st_bad,       // 其中多少个和期望地址对不上（0 = 逐字全对）
    input  wire [15:0] st_off,       // 自测第 1 个字偏几个
    input  wire [15:0] st_first,     // 自测第 1 个字的低 16 位
    input  wire [15:0] st_w0, st_w1, st_w2, st_w3,   // 自测头 4 个字（看重复花样）
    // ---- ★★ 2026-10-01 实验一：SDRAM 忙 / 刷新 与写使能的关系 ----
    input  wire [15:0] sb_flags,     // ㉚ sticky 位图（见文件头 29 的说明）
    input  wire [15:0] sb_rise,      // ㉛ Sdr_busy 拉高次数
    input  wire [15:0] sb_col,       // ㉜ 写使能有效期间 Sdr_busy 高的拍数
    input  wire [15:0] rv_col,       // ㉝ 写使能有效期间 Sdr_init_ref_vld 高的拍数
    output wire        uart_tx
);

    // ★★ 2026-10-01：29 → 33。加字段必须同时改下面四处，少一处就发不出帧：
    //      NV / NB、idx 的位宽、IDX_CR|LF 的位宽、case 里的新分支。
    //      33*4+2 = 134 > 127 ⇒ idx 必须是 8 位（[6:0] 装不下，这就是那个
    //      "索引位宽"的老坑；CR/LF 的常量也一样，132/133 需要 8 位）。
    localparam integer NV = 33;                  // 33 个 16 位数
    localparam integer NB = NV * 4 + 2;          // 132 个字符 + CR + LF = 134 字节
    localparam [7:0]   IDX_CR = NB - 2;
    localparam [7:0]   IDX_LF = NB - 1;

    // ---- 半秒一次的心跳 ----
    localparam integer TICKS = (CLK_HZ / 1000) * PERIOD_MS;
    reg [31:0] tick;
    reg        trig;
    reg        reppar;               // 每发一帧翻一次：选 A 组还是 B 组行探针
    // ★ 心跳和发送必须在【同一个 always 块】里 —— reppar 只在这里赋值。
    //   分成两块写，TD 综合会直接报 "net 'reppar' is constantly driven
    //   from multiple places"（多驱动），ModelSim 却只当个警告放过。
    //   踩过一次，别再把它们拆开。

    function [7:0] hx;
        input [3:0] h;
        begin
            hx = (h < 4'd10) ? (8'h30 + {4'd0, h}) : (8'h37 + {4'd0, h});
        end
    endfunction

    // ---- 帧的位置 -> 取哪个值 ----
    reg [7:0] idx;                               // ★ 必须装得下 NB-1 = 133
    // ★★ 行缓冲探针那四个值【必须在同一拍冻结】再发：
    //    它们一行就刷新一次（26us），而一条帧要发 7ms —— 不冻结的话，
    //    一条帧里四个字段会被不同的行混着刷，读数就没法解释了
    //    （仿真里已经看到过这种"asked 是 A 行、rd0 是 B 行"的怪值）。
    //    其余字段变化很慢（每帧才变一次），不冻结没关系。
    reg [15:0] lb_wbase_q, lb_rd0_q, lb_rd1_q, lb_words_q;
    reg [15:0] lb_off_q, lb_alignbad_q;
    // ★★ 2026-09-28 第五轮：整行扫描那 9 个数（8 个字 + 组号）也必须在【同一拍】
    //    冻结再发。理由和上面一样，而且更狠：扫描值每帧就换一组，
    //    而一条帧要发 ~10ms —— 不冻结的话，同一条帧里"前四个字"和"后四个字"
    //    会来自不同的组（上板实测到过这种混帧，读数没法解释）。
    reg [15:0] fz_r0, fz_r1, fz_r2, fz_r3, fz_r4, fz_r5, fz_r6, fz_r7;
    reg [15:0] fz_grp, fz_w0, fz_w1, fz_w2, fz_w3;
    reg [15:0] fz_pass, fz_half, fz_row;
    // ★ 2026-10-01 实验一：这四个也在同一拍冻结（计数器在增长，不冻结会读到
    //    "半个帧期间涨上去的值"，各位十六进制来自不同时刻）
    reg [15:0] fz_sbf, fz_sbr, fz_sbc, fz_rvc;
    reg        fz_tagbad;            // ★ 2026-10-05：音频 tag 队列脱钩 sticky
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lb_wbase_q <= 16'd0; lb_rd0_q <= 16'd0;
            lb_rd1_q   <= 16'd0; lb_words_q <= 16'd0;
            lb_off_q   <= 16'd0; lb_alignbad_q <= 16'd0;
            fz_r0 <= 16'd0; fz_r1 <= 16'd0; fz_r2 <= 16'd0; fz_r3 <= 16'd0;
            fz_r4 <= 16'd0; fz_r5 <= 16'd0; fz_r6 <= 16'd0; fz_r7 <= 16'd0;
            fz_grp <= 16'd0;
            fz_w0 <= 16'd0; fz_w1 <= 16'd0; fz_w2 <= 16'd0; fz_w3 <= 16'd0;
            fz_pass <= 16'd0; fz_half <= 16'd0; fz_row <= 16'd0;
            fz_sbf <= 16'd0; fz_sbr <= 16'd0; fz_sbc <= 16'd0; fz_rvc <= 16'd0;
            fz_tagbad <= 1'b0;
        end
        else if (trig) begin
            lb_wbase_q <= lb_wbase;
            lb_rd0_q   <= lb_rd0;
            lb_rd1_q   <= lb_rd1;
            lb_words_q <= lb_words;
            lb_off_q   <= lb_off;
            lb_alignbad_q <= lb_alignbad;
            fz_r0 <= row0; fz_r1 <= row1; fz_r2 <= row2; fz_r3 <= row3;
            fz_r4 <= row4; fz_r5 <= row5; fz_r6 <= row6; fz_r7 <= row7;
            fz_grp <= st_read_cnt;
            fz_w0 <= st_w0; fz_w1 <= st_w1; fz_w2 <= st_w2; fz_w3 <= st_w3;
            fz_pass <= st_bad; fz_half <= st_off; fz_row <= st_first;
            fz_sbf <= sb_flags; fz_sbr <= sb_rise;
            fz_sbc <= sb_col;   fz_rvc <= rv_col;
            fz_tagbad <= tag_bad;
        end
    end
    wire [6:0] vi    = idx[7:2];                        // 值序号 0..33
    wire [1:0] dp    = idx[1:0];                        // 第几个十六进制位（0 = 最高）
    wire [4:0] shamt = (5'd3 - {3'd0, dp}) << 2;        // 12 / 8 / 4 / 0

    reg [15:0] vsel;
    always @(*) begin
        case (vi)
        7'd0:  vsel = val[15:0];
        7'd1:  vsel = {8'd0, val[23:16]};
        7'd2:  vsel = {8'd0, status};
        7'd3:  vsel = {8'd0, frm};
        7'd4:  vsel = {8'd0, bad[23:16]};
        7'd5:  vsel = bad[15:0];
        // ★ 第五轮：这四个整行扫描字用【冻结后】的值（见上面 fz_* 的说明）
        7'd6:  vsel = reppar ? fz_r4 : fz_r0;
        7'd7:  vsel = reppar ? fz_r5 : fz_r1;
        7'd8:  vsel = reppar ? fz_r6 : fz_r2;
        7'd9:  vsel = reppar ? fz_r7 : fz_r3;
        7'd10: vsel = drop_cnt;
        7'd11: vsel = abort_cnt;
        // ★★ 2026-10-05：bit0 = reppar（解释字段 6..9 用），
        //    bit1 = 音频仲裁 tag 队列【脱钩过】（sticky，1 = 是仲裁的锅）
        7'd12: vsel = {14'd0, fz_tagbad, reppar};
        7'd13: vsel = lb_wbase_q;
        7'd14: vsel = lb_rd0_q;
        7'd15: vsel = lb_rd1_q;
        7'd16: vsel = lb_words_q;
        7'd17: vsel = cmp_sel;
        7'd18: vsel = key_cnt;
        7'd19: vsel = lb_off_q;
        7'd20: vsel = lb_alignbad_q;
        7'd21: vsel = fz_grp;          // ★ 整行扫描组号（冻结）
        7'd22: vsel = fz_pass;         // ★ 边缘巡检：趟号（冻结）
        7'd23: vsel = fz_half;         // ★ 0=偶数像素 1=奇数像素（冻结）
        7'd24: vsel = fz_row;          // ★ 这一趟看的窗口行（冻结）
        7'd25: vsel = fz_w0;           // ★ 扫描第 5..8 个字（冻结）
        7'd26: vsel = fz_w1;
        7'd27: vsel = fz_w2;
        7'd28: vsel = fz_w3;
        // ★★ 2026-10-01 实验一
        7'd29: vsel = fz_sbf;          // sticky 位图
        7'd30: vsel = fz_sbr;          // Sdr_busy 拉高次数
        7'd31: vsel = fz_sbc;          // 写使能期间 Sdr_busy 高的拍数
        default: vsel = fz_rvc;        // 32：写使能期间 Sdr_init_ref_vld 高的拍数
        endcase
    end

    wire [3:0] nib = vsel >> shamt;
    reg  [7:0] nb_byte;
    always @(*) begin
        if      (idx == IDX_CR) nb_byte = 8'h0D;
        else if (idx == IDX_LF) nb_byte = 8'h0A;
        else                    nb_byte = hx(nib);
    end

    reg       sending;
    reg [7:0] byte_out;
    reg       byte_en;
    wire      tx_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick <= 32'd0; trig <= 1'b0; reppar <= 1'b0;
            idx <= 7'd0; sending <= 1'b0; byte_out <= 8'd0; byte_en <= 1'b0;
        end
        else begin
            // ---- 半秒一次的心跳（trig 是一拍脉冲）----
            if (tick >= TICKS[31:0]) begin
                tick <= 32'd0;
                trig <= 1'b1;
            end
            else begin
                tick <= tick + 32'd1;
                trig <= 1'b0;
            end

            // ---- 发射一帧 ----
            byte_en <= 1'b0;
            if (sending) begin
                // ★ !byte_en 必须有：en 拉高那一拍 UART 还没忙起来
                if (!tx_busy && !byte_en) begin
                    byte_out <= nb_byte;
                    byte_en  <= 1'b1;
                    if (idx == IDX_LF) sending <= 1'b0;
                    else               idx     <= idx + 8'd1;
                end
            end
            else if (trig) begin
                sending <= 1'b1;
                idx     <= 7'd0;
                reppar  <= ~reppar;   // ★ 只在"这一帧开始时"翻，发帧期间不许变
            end
        end
    end

    UART_sendchar #(.baud(115200), .sys_clk(CLK_HZ)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .str(byte_out), .en(byte_en),
        .UART_out(uart_tx), .busy(tx_busy)
    );

endmodule
