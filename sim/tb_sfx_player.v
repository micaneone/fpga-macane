// ============================================================
//  tb_sfx_player —— 只为看"放完那一刻"的输出波形
//
//  目的：上板听到"放完一声爆音"，但读回来的音频字数/校验和都对，
//  说明数据没问题、问题在消费端收尾。这里把 sfx_player 单独喂一段
//  已知数据（恒定 0x4000 = 满幅一半的直流），喂完就断供，把每个
//  采样打出来，直接看尾巴是台阶、直流保持、还是重复。
//
//  喂 200 个字（= 400 个采样，每个采样 256 个 clk_aud）。
//  第 199 个字喂完以后 aud_vld 拉低、data_done 拉高（= 上板时 run 已落）。
//
//  输出：sim\sfx_tail.txt，每行 = 一个采样（有符号十进制）。
//  ★ 本文件保持纯 ASCII。
// ============================================================
`timescale 1ns / 1ps

module tb_sfx_player;

    localparam integer NW = 200;    // 喂多少个字（1 个字 = 2 个采样）

    localparam [15:0] SAMP = 16'h4000;      // 恒定采样值（0.5 满幅）

    reg clk_aud = 1'b0;
    reg clk_pix = 1'b0;
    reg clk_ctl = 1'b0;
    reg rst_n   = 1'b0;

    always #40.69  clk_aud = ~clk_aud;      // 12.288 MHz
    always #162.76 clk_pix = ~clk_pix;      // 3.072 MHz（够采样 toggle 就行）
    always #40.69  clk_ctl = ~clk_ctl;

    // ---- 被测 ----
    reg  [31:0] din  = 32'd0;
    reg         dval = 1'b0;
    reg         done = 1'b0;
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
        .volume    (8'hFF),
        .aud_dout  (din),
        .aud_vld   (dval),
        .aud_next  (nx),
        .data_done (done),
        .busy      ()
    );

    // ---- 喂数据 ----
    integer k;
    always @(posedge clk_aud or negedge rst_n) begin
        if (!rst_n) begin
            k    <= 0;
            din  <= 32'd0;
            dval <= 1'b0;
            done <= 1'b0;
        end
        else begin
            if (k < NW) begin
                dval <= 1'b1;
                din  <= {SAMP, SAMP};
                if (nx) k <= k + 1;
                if (k == NW - 1 && nx) begin
                    // 最后一个字已经交出去：下一拍断供
                    dval <= 1'b0;
                    done <= 1'b1;
                end
            end
            else begin
                dval <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    // ---- 打采样 ----
    integer f, n;
    initial begin
        f = $fopen("sfx_tail.txt", "w");
        n = 0;
    end

    always @(posedge clk_pix) begin
        if (a_valid && n < 1200) begin
            $fdisplay(f, "%0d", $signed(a_l[23:8]));
            n = n + 1;
        end
    end

    initial begin
        #1000 rst_n = 1'b1;
        // 喂 200 个字 = 400 个采样（每个采样 256 个 clk_aud = 20.8 us），
        // 再额外跑 600 个采样专门看尾巴。
        #(1000 * 256 * 81.38);
        $fclose(f);
        $display("=== tb_sfx_player done, samples written = %0d ===", n);
        $finish;
    end

endmodule
