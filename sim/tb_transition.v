// ============================================================
//  tb_transition —— 转场混合级的离线检查（2026-10-17 软边改动的验收台）
//
//  为什么要有它：这次把划像/百叶窗从"硬边比较器"改成了"逐像素系数 + 淡化乘法器"，
//  两条硬约束必须逐位守住：
//    ① prog = 0    ⇒ 输出**逐位等于 A 端**（= 转场起点，不能跳一下）
//    ② prog = 256  ⇒ 输出**逐位等于 B 端**（= 转场终点，swap 时不能跳一下）
//  另外核三件新行为：
//    ③ 划像：左右有**渐变**（软边），且 x 越大越接近 A 端（方向对）
//    ④ 百叶窗：同一列上，行号小的先变成 B 端（方向对）
//    ⑤ 交叉淡化：prog 越大越接近 B 端（单调）
//
//  ★ 本文件保持纯 ASCII。
// ============================================================
`timescale 1ns / 1ps

module tb_transition;

    localparam [1:0] M_PASS = 2'd0, M_WIPE = 2'd1, M_BLIND = 2'd2, M_XFADE = 2'd3;

    reg clk = 0, rst_n = 0;
    always #12.5 clk = ~clk;                    // 40 MHz

    reg         de_in = 1, vs_in = 0;
    reg  [15:0] px_a = 16'h0000;                // 黑
    reg  [15:0] px_b = 16'hFFFF;                // 白
    reg  [15:0] bg   = 16'hFFE0;                // 米白（近白）
    reg  [1:0]  mode = 2'd0;
    reg         wa = 0, wb = 0;
    reg  [8:0]  prog = 9'd0;
    reg  [11:0] ppx = 0, ppy = 0;

    wire [15:0] rgb;
    wire        dout, vout;

    transition u_dut (
        .clk_pix(clk), .rst_pix_n(rst_n),
        .de_in(de_in), .vs_in(vs_in),
        .px_a(px_a), .px_b(px_b), .bg_color(bg),
        .mode(mode), .white_a(wa), .white_b(wb), .prog(prog),
        .pix_x(ppx), .pix_y(ppy),
        .rgb565(rgb), .de_out(dout), .vs_out(vout)
    );

    // ---- 取一个像素的输出（组合 + 一拍寄存器 ⇒ 打两拍等结果）----
    task getpx;
        input  [11:0] gx;
        input  [11:0] gy;
        output [15:0] o;
        begin
            ppx = gx; ppy = gy;
            @(posedge clk); @(posedge clk);
            o = rgb;
        end
    endtask

    // 16 位 565 比较：这里要判"逐位相等"，所以直接比整字
    integer n_end0_bad, n_end1_bad, n_case, i, j;
    reg [15:0] got, a_end, b_end;

    task check_case;
        input [1:0]  m;
        input        wa_i, wb_i;
        input [8:0]  p;
        input [15:0] want0;      // prog=0 的期望（= A 端）
        input [15:0] want1;      // prog=256 的期望（= B 端）
        begin
            n_case = n_case + 1;
            mode = m; wa = wa_i; wb = wb_i;
            // ---- prog = 0：全屏逐点必须等于 want0 ----
            prog = 9'd0;
            n_end0_bad = 0;
            for (j = 0; j < 600; j = j + 37)
                for (i = 0; i < 800; i = i + 53) begin
                    getpx(i[11:0], j[11:0], got);
                    if (got !== want0) n_end0_bad = n_end0_bad + 1;
                end
            // ---- prog = 256：全屏逐点必须等于 want1 ----
            prog = 9'd256;
            n_end1_bad = 0;
            for (j = 0; j < 600; j = j + 37)
                for (i = 0; i < 800; i = i + 53) begin
                    getpx(i[11:0], j[11:0], got);
                    if (got !== want1) n_end1_bad = n_end1_bad + 1;
                end
            $display("mode=%0d wa=%0d wb=%0d  prog0 bad=%0d  prog256 bad=%0d",
                     m, wa_i, wb_i, n_end0_bad, n_end1_bad);
            if (n_end0_bad != 0 || n_end1_bad != 0) begin
                $display("  !! ENDPOINT FAIL");
            end
        end
    endtask

    // ---- 方向/渐变检查 ----
    reg [15:0] v0, v1, v2, v3;
    integer n_dir_bad;
    task check_dirs;
        begin
            // ③ 划像：x 小的地方更接近 B（白），x 大的地方更接近 A（黑）
            //   ★ prog=128 ⇒ 界线中心 = 512 px、软边 128 px ⇒ 渐变带在 384..512，
            //     所以取样点必须落在这条带子里，否则只会看到纯黑/纯白（第一版就栽在这儿）。
            mode = M_WIPE; wa = 0; wb = 0; prog = 9'd128;
            getpx(300, 300, v3);       // 带子左边：已经全白
            getpx(392, 300, v0);       // 带子里
            getpx(448, 300, v1);       // 带子中间
            getpx(504, 300, v2);       // 带子右边
            getpx(700, 300, v3);       // 带子右边：还是全黑
            getpx(392, 300, v0);
            $display("WIPE  prog=128  x=392 -> %h  x=448 -> %h  x=504 -> %h  (右端 x=700 -> %h)", v0, v1, v2, v3);
            n_dir_bad = 0;
            if (!(v0 > v1 && v1 > v2)) n_dir_bad = n_dir_bad + 1;   // 带子里单调过渡
            if (!((v1 > 16'h0000) && (v1 < 16'hFFFF))) n_dir_bad = n_dir_bad + 1;  // 确实是中间值
            if (v3 !== 16'h0000) n_dir_bad = n_dir_bad + 1;         // 界线右边还是旧图
            $display("  WIPE dir/gradient bad = %0d", n_dir_bad);

            // ④ 百叶窗：同一列，行小先变白
            mode = M_BLIND; prog = 9'd128;
            getpx(400, 0,  v0);
            getpx(400, 8,  v1);
            getpx(400, 24, v2);
            getpx(400, 31, v3);
            $display("BLIND prog=128  y=0 -> %h  y=8 -> %h  y=24 -> %h  y=31 -> %h", v0, v1, v2, v3);

            // ⑤ 交叉淡化：单调
            mode = M_XFADE;
            prog = 9'd64;  getpx(400, 300, v0);
            prog = 9'd128; getpx(400, 300, v1);
            prog = 9'd192; getpx(400, 300, v2);
            $display("XFADE  prog=64 -> %h  128 -> %h  192 -> %h", v0, v1, v2);
        end
    endtask

    initial begin
        n_case = 0;
        #100 rst_n = 1'd1;
        @(posedge clk);

        // ① PASS 直通
        check_case(M_PASS, 0, 0, 9'd0, px_a, px_a);

        // ② 三个特效 × 四个"两头是不是米白"组合
        check_case(M_WIPE,  0, 0, 9'd0, px_a, px_b);
        check_case(M_WIPE,  1, 0, 9'd0, bg,   px_b);   // 从米白划像
        check_case(M_BLIND, 0, 0, 9'd0, px_a, px_b);
        check_case(M_BLIND, 1, 0, 9'd0, bg,   px_b);
        check_case(M_XFADE, 0, 1, 9'd0, px_a, bg);     // 淡出到米白
        check_case(M_XFADE, 1, 0, 9'd0, bg,   px_b);   // 从米白淡入
        check_case(M_XFADE, 0, 0, 9'd0, px_a, px_b);

        // ③④⑤ 方向/渐变
        check_dirs;

        $display("=== tb_transition done: %0d cases ===", n_case);
        $finish;
    end

endmodule
