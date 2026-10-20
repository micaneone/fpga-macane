// ============================================================
//  tb_menu_cn —— 【menu_ovl_cn 的离线看图台】把面板区域逐像素扫一遍，导成 PPM
// ------------------------------------------------------------
//  为什么要这个台子：2026-10-21 一天之内上板两次，两次都是"屏上字全空"
//  （第一次 BRAM 初值没进比特流，第二次字库缺字）。字模这种东西**必须先在
//  仿真里看见**，不能靠烧板子猜。
//
//  产出：sim/menu_cn.ppm（P3 文本格式，灰阶 0/255，已裁到面板外框范围内）
//        外层用 PIL 转 PNG 直接看。
//
//  两个检查：
//    ① 图像：面板底/外框/分隔线/选中行方框/汉字标签/数字，肉眼逐步对；
//    ② 直通：menu_on=0 时把同一片区域再扫一遍，px_out 必须**逐像素等于**输入。
// ============================================================
`timescale 1ns / 1ps

module tb_menu_cn;

    // ---- 扫描窗口（面板 240..560 × 200..400，两边各留 4 px 看外框）----
    localparam integer X0 = 236, X1 = 564;
    localparam integer Y0 = 196, Y1 = 404;

    reg clk = 0, rst_n = 0, de = 0;
    reg [11:0] x = 0, y = 0;
    reg [15:0] px_in = 16'h0000;

    reg        menu_on = 1;
    reg [2:0]  menu_sel = 3'd1;
    reg [2:0]  zoom_lv = 3'd2;
    reg [1:0]  sel_aud = 2'd2;     // 显示 3
    reg [3:0]  vol_lv  = 4'd10;    // 显示 10（两位）
    reg [3:0]  bri_lv  = 4'd7;     // 显示 7（个位，十位空）

    wire [15:0] px_out;
    wire        de_out, vs_out;

    always #12.5 clk = ~clk;       // 40 MHz

    menu_ovl_cn dut (
        .clk_pix(clk), .rst_pix_n(rst_n),
        .de_in(de), .vs_in(1'b0),
        .x_in(x), .y_in(y),
        .px_in(px_in),
        .px_out(px_out), .de_out(de_out), .vs_out(vs_out),
        .menu_on(menu_on), .menu_sel(menu_sel),
        .zoom_lv(zoom_lv), .sel_aud(sel_aud),
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

    initial begin
        errs = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---------------- ① 画一张 ----------------
        fd = $fopen("menu_cn.ppm", "w");
        $fwrite(fd, "P3\n%d %d\n255\n", X1 - X0, Y1 - Y0);
        for (j = Y0; j < Y1; j = j + 1) begin
            for (i = X0; i < X1; i = i + 1) begin
                scan_px(i[11:0], j[11:0], 16'h1082, got);
                // 灰度：面板区域外 = 128（背景参考），区域内按亮度压成 0/255
                if (got == 16'h1082) $fwrite(fd, "128 ");
                else if (got[15:11] > 5'd16 || got[10:5] > 6'd40) $fwrite(fd, "255 ");
                else if (got == 16'h4104) $fwrite(fd, "96 ");
                else if (got == 16'h8410) $fwrite(fd, "160 ");
                else if (got == 16'h20FF) $fwrite(fd, "200 ");
                else $fwrite(fd, "0 ");
            end
            $fwrite(fd, "\n");
        end
        $fclose(fd);
        $display("WROTE menu_cn.ppm");

        // ---------------- ② 直通检查 ----------------
        menu_on = 1'b0;
        @(posedge clk);
        bad = 0;
        for (j = Y0; j < Y1; j = j + 1) begin
            for (i = X0; i < X1; i = i + 1) begin
                scan_px(i[11:0], j[11:0], 16'h3C1E, got);
                if (got !== 16'h3C1E) bad = bad + 1;
            end
        end
        $display("PASSTHRU: bad=%0d", bad);
        if (bad != 0) errs = errs + 1;

        $display("RESULT: %s", (errs == 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
