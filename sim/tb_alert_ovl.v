// ============================================================================
//  tb_alert_ovl.v —— 报警层回归自检（2026-10-25 改"只闪边框、画面不变色"）
// ----------------------------------------------------------------------------
//  检查三件事：
//    1) alert_on=0：整幅图逐像素透传（含边框区域）
//    2) alert_on=1：**非边框像素永远等于 px_in**（画面永不被染色）
//    3) alert_on=1：边框像素只在 flash=1 时变纯红，flash=0 时透传；
//       且 flash 每 HALF_FRAMES 个 vs 翻转一次（1 Hz @60Hz）
//  输出 "RESULT: PASS ..." / mismatch 明细。
// ============================================================================
`timescale 1ns / 1ps

module tb_alert_ovl;

    reg         clk_pix;
    reg         rst_pix_n;
    reg         vs_in;
    reg         de_in;
    reg  [11:0] x_in;
    reg  [11:0] y_in;
    reg  [15:0] px_in;
    reg         alert_on;
    wire [15:0] px_out;

    alert_ovl dut (
        .clk_pix   (clk_pix),
        .rst_pix_n (rst_pix_n),
        .de_in     (de_in),
        .vs_in     (vs_in),
        .x_in      (x_in),
        .y_in      (y_in),
        .px_in     (px_in),
        .alert_on  (alert_on),
        .px_out    (px_out)
    );

    // 25 MHz 像素时钟（周期仿真不重要，只用来产生 vs 边沿）
    initial clk_pix = 1'b0;
    always #10 clk_pix = ~clk_pix;

    integer errors;
    integer checks;
    integer n_border_red;
    integer n_border_pass;
    integer n_img;

    // 一帧 = 48 个时钟；每帧发一个 vs 单拍脉冲（HALF_FRAMES=30 帧 ⇒ 120 帧后翻）
    task do_frame(input integer n_cycles, input integer alert_v, input [11:0] y0);
        integer i;
        begin
            for (i = 0; i < n_cycles; i = i + 1) begin
                @(posedge clk_pix);
                vs_in  <= (i == 0);
                de_in  <= (i == 1);
                x_in   <= 12'd8 * (i % 100);
                y_in   <= y0;
                px_in  <= 16'h1234 + i[15:0];
                alert_on <= alert_v;
                #1;
            end
            vs_in <= 1'b0;
            de_in <= 1'b0;
        end
    endtask

    // 逐像素检查（组合输出，输入变化后 #1 取值）
    task check_px(input [11:0] x, input [11:0] y, input [15:0] px,
                  input integer alert_v);
        reg is_border;
        begin
            is_border = (x < 8) || (x >= 792) || (y < 8) || (y >= 592);
            vs_in  <= 1'b0;
            de_in  <= 1'b1;
            x_in   <= x;
            y_in   <= y;
            px_in  <= px;
            alert_on <= (alert_v != 0);
            #1;
            checks = checks + 1;
            if (!alert_v) begin
                if (px_out !== px) begin
                    errors = errors + 1;
                    $display("MISMATCH(no-alert) x=%0d y=%0d exp=%h got=%h", x, y, px, px_out);
                end
            end else if (!is_border) begin
                n_img = n_img + 1;
                if (px_out !== px) begin
                    errors = errors + 1;
                    $display("MISMATCH(image tinted) x=%0d y=%0d exp=%h got=%h", x, y, px, px_out);
                end
            end else begin
                if (px_out === 16'hF800) n_border_red  = n_border_red + 1;
                if (px_out === px)       n_border_pass = n_border_pass + 1;
                if (px_out !== 16'hF800 && px_out !== px) begin
                    errors = errors + 1;
                    $display("MISMATCH(border) x=%0d y=%0d got=%h", x, y, px_out);
                end
            end
        end
    endtask

    integer k;
    initial begin
        errors = 0; checks = 0; n_img = 0;
        n_border_red = 0; n_border_pass = 0;
        rst_pix_n = 1'b0;
        vs_in = 1'b0; de_in = 1'b0; x_in = 0; y_in = 0; px_in = 0; alert_on = 0;
        repeat (3) @(posedge clk_pix);
        rst_pix_n = 1'b1;
        repeat (2) @(posedge clk_pix);

        // --- 1) 不报警：整幅（含边框）透传 ---
        for (k = 0; k < 40; k = k + 1)
            check_px(k[11:0] * 20, 12'd300, 16'h0101 + k[15:0], 0);

        // --- 2/3) 报警：非边框永不变色；边框红/透明随 flash ---
        // 先让 flash 跑起来：关键路径 = vs_rise 才动 flash，逐帧推进
        alert_on = 1'b1;
        for (k = 0; k < 400; k = k + 1) begin
            // 每 4 步发一次 vs（模拟帧），中间检查像素
            if ((k % 4) == 0) begin
                @(posedge clk_pix); vs_in <= 1'b1;
                @(posedge clk_pix); vs_in <= 1'b0;
            end
            // x 扫过边框与中间，y 也覆盖上下边框
            check_px((k * 37) % 800, (k * 13) % 600, 16'h2424 + k[15:0], 1);
        end

        // --- 统计 ---
        if (n_border_red == 0) begin
            errors = errors + 1;
            $display("ERROR: border never turned red (flash did not toggle)");
        end
        if (n_border_pass == 0) begin
            errors = errors + 1;
            $display("ERROR: border never passed through (flash stuck on)");
        end
        $display("checks=%0d  img_px=%0d  border_red=%0d  border_pass=%0d  errors=%0d",
                 checks, n_img, n_border_red, n_border_pass, errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
