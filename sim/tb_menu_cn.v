// ============================================================
//  tb_menu_cn —— 【menu_ovl_cn 的离线看图台】把左上角 4 个小格逐像素扫一遍，导成 PPM
// ------------------------------------------------------------
//  为什么要这个台子：2026-10-21 一天之内上板两次，两次都是"屏上字全空"
//  （第一次 BRAM 初值没进比特流，第二次字库缺字）。字模这种东西**必须先在
//  仿真里看见**，不能靠烧板子猜。
//
//  2026-10-24 版式改版（中心面板 → 左上角 4 个独立描边小格）后同步改扫描窗口：
//      扫 x=0..200、y=0..196（第 4 格底边 y=190，四周留 6 px 看是否漏出底色）。
//
//  产出：sim/menu_cn.ppm（P3 文本格式，灰阶映射，已裁到左上角小格范围内）
//        外层用 PIL 转 PNG 直接看。
//
//  两个检查：
//    ① 图像：4 个描边框/汉字标签/数值/选中格粗蓝框，肉眼逐步对；
//    ② 直通：menu_on=0 时把同一片区域再扫一遍，px_out 必须**逐像素等于**输入。
// ============================================================
`timescale 1ns / 1ps

module tb_menu_cn;

    // ---- 扫描窗口（4 格占 x=12..196、y=12..190，四周留余量）----
    localparam integer X0 = 0,   X1 = 200;
    localparam integer Y0 = 0,   Y1 = 196;

    localparam [15:0] BG      = 16'h1082;   // 背景（深蓝灰，用来区分"直通"）
    localparam [15:0] C_INK   = 16'hFFC2;   // 文字
    localparam [15:0] C_SEL   = 16'h20FF;   // 选中格描边
    localparam [15:0] C_FRAME = 16'h8410;   // 未选中格描边
    localparam [15:0] C_RED   = 16'hF800;   // ★ 确认后（调节态）选中格描边 = 亮红
    // 半透明底 = 画面压到 50% 亮度：(BG>>1)&0x7BEF（RGB565 没有 alpha 的近似）
    localparam [15:0] C_FILL  = (BG >> 1) & 16'h7BEF;

    reg clk = 0, rst_n = 0, de = 0;
    reg [11:0] x = 0, y = 0;
    reg [15:0] px_in = BG;

    reg        menu_on  = 1;
    reg        menu_edit = 1'b0;   // ★ 0 = 候选态（蓝框）/ 1 = KEY2 确认后的调节态（红框）
    reg [2:0]  menu_sel = 3'd1;    // 选中「可视」行
    reg [2:0]  zoom_lv  = 3'd2;    // 缩放 = 2
    reg [1:0]  sel_aud  = 2'd2;    // 不再显示（端口保留）
    reg        viz_on   = 1'b1;    // 可视 = 开
    reg [3:0]  vol_lv   = 4'd10;   // 音量 = 100%（4 个字形，测右对齐）
    reg [3:0]  bri_lv   = 4'd7;    // 亮度 = 70%

    wire [15:0] px_out;
    wire        de_out, vs_out;

    always #12.5 clk = ~clk;       // 40 MHz

    menu_ovl_cn dut (
        .clk_pix(clk), .rst_pix_n(rst_n),
        .de_in(de), .vs_in(1'b0),
        .x_in(x), .y_in(y),
        .px_in(px_in),
        .px_out(px_out), .de_out(de_out), .vs_out(vs_out),
        .menu_on(menu_on), .menu_sel(menu_sel), .menu_edit(menu_edit),
        .zoom_lv(zoom_lv), .sel_aud(sel_aud), .viz_on(viz_on),
        .vol_lv(vol_lv), .bri_lv(bri_lv)
    );

    integer fd, i, j, bad, errs;
    reg [15:0] got;

    // 送一个像素进去，等两拍把结果取回来
    task scan_px(input [11:0] tx, input [11:0] ty, input [15:0] bg, output [15:0] q);
        begin
            x = tx; y = ty; px_in = bg; de = 1'b1;
            @(posedge clk); @(posedge clk);
            #1 q = px_out;
        end
    endtask

    // 扫一张图导 PPM（调用前设好 menu_edit：0 = 蓝框，1 = 红框）
    task dump_ppm(input [8*32-1:0] fname);
        begin
            fd = $fopen(fname, "w");
            $fwrite(fd, "P3\n%d %d\n255\n", X1 - X0, Y1 - Y0);
            for (j = Y0; j < Y1; j = j + 1) begin
                for (i = X0; i < X1; i = i + 1) begin
                    scan_px(i[11:0], j[11:0], BG, got);
                    if      (got == BG)      $fwrite(fd, "128 ");   // 直通
                    else if (got == C_INK)   $fwrite(fd, "255 ");   // 文字
                    else if (got == C_SEL)   $fwrite(fd, "200 ");   // 选中描边（蓝）
                    else if (got == C_RED)   $fwrite(fd, "220 ");   // 确认后描边（红）
                    else if (got == C_FRAME) $fwrite(fd, "160 ");   // 未选中描边
                    else if (got == C_FILL)  $fwrite(fd, "64 ");    // 半透明底
                    else                     $fwrite(fd, "0 ");     // 其它颜色（不该出现）
                end
                $fwrite(fd, "\n");
            end
            $fclose(fd);
            $display("WROTE %0s", fname);
        end
    endtask

    initial begin
        errs = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---------------- ① 画两张：menu_edit=0（蓝框）/ =1（KEY2 确认后红框）----------------
        menu_edit = 1'b0;
        @(posedge clk);
        dump_ppm("menu_cn.ppm");
        menu_edit = 1'b1;
        @(posedge clk);
        dump_ppm("menu_cn_edit.ppm");

        // ---------------- ② 直通检查（menu_on=0） ----------------
        menu_on = 1'b0;
        @(posedge clk);
        bad = 0;
        for (j = Y0; j < Y1; j = j + 1) begin
            for (i = X0; i < X1; i = i + 1) begin
                scan_px(i[11:0], j[11:0], 16'h3C1E, got);
                if (got !== 16'h3C1E) bad = bad + 1;
            end
        end
        $display("PASSTHRU (menu_on=0): bad=%0d", bad);
        if (bad != 0) errs = errs + 1;

        // ---------------- ③ 格与格之间的空隙也必须直通（menu_on=1）----------------
        menu_on = 1'b1;
        @(posedge clk);
        bad = 0;
        // 第 1/2 格之间的 6 px 缝（y = 52..57），以及右侧空白（x = 197..199）
        for (j = 52; j < 58; j = j + 1) begin
            for (i = X0; i < X1; i = i + 1) begin
                scan_px(i[11:0], j[11:0], 16'h3C1E, got);
                if (got !== 16'h3C1E) bad = bad + 1;
            end
        end
        $display("PASSTHRU (gap rows, menu_on=1): bad=%0d", bad);
        if (bad != 0) errs = errs + 1;

        $display("RESULT: %s", (errs == 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
