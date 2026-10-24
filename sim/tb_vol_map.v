// ============================================================
//  tb_vol_map —— 音量映射数值验证（2026-10-24 音量线性化）
//
//  目的：不动板子，先在仿真里把 sfx_player 的实际增益打出来，
//        确认 0..10 档 => 0/12.5/18.75/31.25/37.5/50/62.5/68.75/81.25/87.5/100%，
//        并且 10% 档不再静音、100% 档 == 满幅。
//
//  做法：恒定喂 0x4000（0.5 满幅）的直流，等淡入斜坡爬到满值，
//        逐档改 volume（= top_m2 的 vol_byte = (vol_lv*51)>>1），
//        打印 gain5 / fad5 / gain4 / out16 / 百分比。
//
//  ★ 本文件保持纯 ASCII。
// ============================================================
`timescale 1ns / 1ps

module tb_vol_map;

    reg clk_aud = 1'b0;
    reg clk_pix = 1'b0;
    reg clk_ctl = 1'b0;
    reg rst_n   = 1'b0;

    always #40.69  clk_aud = ~clk_aud;      // 12.288 MHz
    always #162.76 clk_pix = ~clk_pix;
    always #40.69  clk_ctl = ~clk_ctl;

    reg  [7:0]  volume = 8'd0;
    reg  [31:0] din    = 32'd0;
    reg         dval   = 1'b0;
    reg         done   = 1'b0;
    wire        nx;
    wire        a_valid;
    wire [23:0] a_l, a_r;

    sfx_player u_dut (
        .clk_aud   (clk_aud),
        .rst_aud_n (rst_n),
        .clk_pix   (clk_pix),
        .rst_pix_n (rst_n),
        .o_audio_valid (a_valid),
        .o_audio_left  (a_l),
        .o_audio_right (a_r),
        .clk_ctl   (clk_ctl),
        .rst_ctl_n (rst_n),
        .volume    (volume),
        .aud_dout  (din),
        .aud_vld   (dval),
        .aud_next  (nx),
        .data_done (done),
        .busy      ()
    );

    // 恒定供数：0x4000 = 16384（0.5 满幅），feed_on=0 时断供（看淡出尾）
    reg feed_on = 1'b1;
    always @(posedge clk_aud) begin
        dval <= feed_on;
        din  <= feed_on ? 32'h4000_4000 : 32'd0;
    end

    integer lv;
    integer vb;
    real    pct;

    initial begin
        $display("=== tb_vol_map start ===");
        #1000 rst_n = 1'b1;

        // 先让淡入斜坡爬到 255（有数据就自动爬，约 256 个采样）
        repeat (600 * 256) @(posedge clk_aud);
        $display("fade=%0d (expect 255)  vol_s2=%0d", u_dut.fade, u_dut.vol_s2);

        $display("---- vol_lv / vol_byte -> gain ----");
        for (lv = 0; lv <= 10; lv = lv + 1) begin
            vb = (lv * 51) >> 1;             // top_m2.v:1309 同一个公式
            volume = vb[7:0];
            repeat (400 * 256) @(posedge clk_aud);   // 等跨域同步 + 稳定
            pct = u_dut.out16 * 100.0 / 16384.0;
            $display("lv=%0d vol_byte=%0d gain5=%0d fad5=%0d gain4=%0d out16=%0d pct=%0.2f%%",
                     lv, vb, u_dut.gain5, u_dut.fad5, u_dut.gain4, u_dut.out16, pct);
        end

        // 报警强制满档
        volume = 8'hFF;
        repeat (400 * 256) @(posedge clk_aud);
        pct = u_dut.out16 * 100.0 / 16384.0;
        $display("ALERT vol_byte=255 gain5=%0d fad5=%0d gain4=%0d out16=%0d pct=%0.2f%%",
                 u_dut.gain5, u_dut.fad5, u_dut.gain4, u_dut.out16, pct);

        // 断供后的淡出尾（data_done=1 -> 指数衰减到 0）
        done   = 1'b1;
        feed_on = 1'b0;
        repeat (4000) @(posedge clk_aud);
        $display("after data_done: fade=%0d out16=%0d samp=%0d",
                 u_dut.fade, u_dut.out16, $signed(u_dut.samp));

        $display("=== tb_vol_map done ===");
        $finish;
    end

endmodule
