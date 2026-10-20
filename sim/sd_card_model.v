// ============================================================
//  sd_card_model —— 离线用的假 SD 卡（SPI 从机），只为验 sd_read 的 CMD18 流式
//
//  支持：
//    · CMD17 READ_SINGLE_BLOCK：R1 + 卡访问延迟 + token + 512B + 2B CRC，然后回"等命令"
//    · CMD18 READ_MULTIPLE_BLOCK：R1 + 卡访问延迟 + 一块接一块连续发，
//      直到 CS 拉高（模拟真卡：SPI 模式下主机撤 CS 就不再发）
//  数据内容：扇区 N 的第 i 个字节 = (N*7 + i) & 0xFF（测试台照这个核对）
//
//  ★★ MISO 用**组合**输出：CS 一拉低就立刻把当前字节的最高位摆出去。
//     为什么不能只在 SCLK 下降沿赋值：主机在**第一个上升沿**就采样第一位，
//     而第一个上升沿**早于**第一个下降沿 ⇒ 只靠下降沿赋值会整体错一位
//     （本台子第一版就是这么错的：主机读到的每个字节都左移 1 位）。
//     组合输出 + "下降沿推进 tx_bits" 正好就是 SPI 模式 0 的约定。
//
//  ★ 两个 always 块分工：posedge 只收 MOSI，negedge 只推进 tx_bits/状态
//    （绝不能两个块同时写同一个 reg）。
// ============================================================
`timescale 1ns / 1ps

module sd_card_model #(
    parameter integer LAT_BYTES = 187,    // 每条读命令的"卡访问延迟"，按**字节**算
                                          // 真卡实测每块约 120 us；12.5 MHz 下 1 字节 = 8 SCLK
                                          // ⇒ 约 1500 个 SCLK ≈ 187 字节
    parameter integer GAP_BYTES = 0       // 多块时块与块之间插几个 0xFF 字节
)(
    input  wire spi_clk,
    input  wire spi_cs,
    input  wire spi_mosi,
    output wire spi_miso,
    input  wire sys_rst_n
);

    localparam M_IDLE  = 3'd0,
               M_CMD   = 3'd1,
               M_R1    = 3'd2,
               M_LAT   = 3'd3,
               M_TOKEN = 3'd4,
               M_DATA  = 3'd5,
               M_CRC   = 3'd6,
               M_GAP   = 3'd7;

    reg [47:0] rx;            // 收到的 6 个命令字节（rx[47:40] = 命令码）
    reg [2:0]  rx_bits;
    reg [2:0]  rx_bytes;

    reg [7:0]  tx_byte;
    reg [2:0]  tx_bits;

    reg [2:0]  st;
    reg [31:0] lat_cnt;
    reg [9:0]  data_idx;
    reg [1:0]  crc_idx;
    reg [31:0] sec;
    reg        multi;
    reg        stop_cmd;    // ★ 本条命令是不是 CMD12（STOP_TRANSMISSION）
    reg [7:0]  gap_cnt;

    integer    cmd_count;     // 一共收到几条命令（测试台用它判"是不是每扇区一条"）

    // 数据字节内容
    function [7:0] sec_byte;
        input [31:0] s;
        input [9:0]  i;
        begin
            sec_byte = ((s * 32'd7) + {22'd0, i}) & 32'hFF;
        end
    endfunction

    // ---- MISO：组合输出（见文件头的说明）----
    assign spi_miso = spi_cs ? 1'b1 : tx_byte[3'd7 - tx_bits];

    // ============================================================
    //  上升沿：采样 MOSI（收命令）
    //  ★ 敏感表里必须带 `posedge spi_cs`：主机撤 CS 之后 **spi_clk 就不跳了**
    //    （my_spi 在 CS 高时把 SCLK 拉低），只靠 spi_clk 的边沿永远清不掉接收计数器
    //    ⇒ 第二笔事务会被"上一笔的 rx_bytes==6"直接吞掉（本台子第三版就是这么错的）。
    // ============================================================
    always @(posedge spi_clk or posedge spi_cs or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx       <= 48'd0;
            rx_bits  <= 3'd0;
            rx_bytes <= 3'd0;
        end
        else if (spi_cs) begin
            rx       <= 48'd0;
            rx_bits  <= 3'd0;
            rx_bytes <= 3'd0;
        end
        // ★ 必须把 M_IDLE 也算进来：CS 一拉低，模型是靠"字节边界"从 M_IDLE 进 M_CMD 的，
        //   而**第一个字节在这之前就已经在线上发了** ⇒ 只认 M_CMD 会漏掉第一个字节，
        //   整套命令/数据整体错开一个字节（本台子第二版就是这么错的）。
        else if (st == M_CMD || st == M_IDLE) begin
            rx      <= {rx[46:0], spi_mosi};
            rx_bits <= rx_bits + 3'd1;
            if (rx_bits == 3'd7) begin
                rx_bytes <= (rx_bytes == 3'd7) ? 3'd7 : (rx_bytes + 3'd1);
                rx_bits  <= 3'd0;
            end
        end
    end

    // ============================================================
    //  下降沿：推进 tx_bits / 状态机（MISO 由组合 assign 输出）
    // ============================================================
    always @(negedge spi_clk or posedge spi_cs or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_bits   <= 3'd0;
            tx_byte   <= 8'hFF;
            st        <= M_IDLE;
            lat_cnt   <= 32'd0;
            data_idx  <= 10'd0;
            crc_idx   <= 2'd0;
            sec       <= 32'd0;
            multi     <= 1'b0;
            stop_cmd  <= 1'b0;
            gap_cnt   <= 8'd0;
            cmd_count <= 0;
        end
        else if (spi_cs) begin
            // CS 撤了：本次传输作废，等下一次 CS 下降沿
            tx_bits  <= 3'd0;
            tx_byte  <= 8'hFF;
            st       <= M_IDLE;
            sec      <= 32'd0;
            multi    <= 1'b0;
            stop_cmd <= 1'b0;
            data_idx <= 10'd0;
            crc_idx  <= 2'd0;
            lat_cnt  <= 32'd0;
            gap_cnt  <= 8'd0;
        end
        else begin
            if (tx_bits != 3'd7)
                tx_bits <= tx_bits + 3'd1;
            else begin
                // ---- 一个字节发完 ⇒ 推进状态、装下一个字节 ----
                tx_bits <= 3'd0;
                case (st)
                M_IDLE: begin
                    st      <= M_CMD;
                    tx_byte <= 8'hFF;
                end
                M_CMD: begin
                    tx_byte <= 8'hFF;
                    if (rx_bytes == 3'd6) begin
                        cmd_count <= cmd_count + 1;
                        // rx = {b0,b1,b2,b3,b4,b5}，b1..b4 是扇区地址（大端）
                        sec      <= {rx[39:32], rx[31:24], rx[23:16], rx[15:8]};
                        multi    <= (rx[47:40] == 8'h52);      // CMD18
                        // ★ CMD12（0x4C）= STOP_TRANSMISSION：只回 R1(＋stuff)，不发数据
                        stop_cmd <= (rx[47:40] == 8'h4C);
                        lat_cnt  <= 32'd0;
                        st       <= M_R1;
                    end
                end
                M_R1: begin
                    tx_byte <= 8'h00;                        // R1 = 0x00（就绪）
                    lat_cnt <= 32'd0;
                    // ★ CMD12 之后不发 token/LAT，直接回去等命令
                    st      <= stop_cmd ? M_CMD : M_LAT;
                end
                M_LAT: begin
                    tx_byte <= 8'hFF;
                    if (lat_cnt >= LAT_BYTES[31:0]) st <= M_TOKEN;
                    else                            lat_cnt <= lat_cnt + 32'd1;
                end
                M_TOKEN: begin
                    tx_byte  <= 8'hFE;
                    data_idx <= 10'd0;
                    st       <= M_DATA;
                end
                M_DATA: begin
                    tx_byte  <= sec_byte(sec, data_idx);
                    data_idx <= data_idx + 10'd1;
                    if (data_idx == 10'd511) st <= M_CRC;
                end
                M_CRC: begin
                    tx_byte <= 8'hFF;
                    crc_idx <= crc_idx + 2'd1;
                    if (crc_idx == 2'd1) begin
                        crc_idx <= 2'd0;
                        if (multi) begin
                            // 多块：不重发命令，直接准备下一块（可插 GAP 个空字节）
                            sec     <= sec + 32'd1;
                            gap_cnt <= 8'd0;
                            st      <= M_GAP;
                        end
                        else begin
                            st <= M_CMD;                     // 单块：回去等命令
                        end
                    end
                end
                M_GAP: begin
                    tx_byte <= 8'hFF;
                    gap_cnt <= gap_cnt + 8'd1;
                    if (gap_cnt >= GAP_BYTES[7:0]) st <= M_TOKEN;
                end
                default: st <= M_IDLE;
                endcase
            end
        end
    end

endmodule
