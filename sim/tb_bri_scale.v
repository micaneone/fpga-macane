// ============================================================
//  tb_bri_scale —— 【穷举】验证 b_display\bri_scale.v
// ------------------------------------------------------------
//  这是纯组合函数，可以一次算完：
//    · bri_lv = 0..15  ×  px_in = 0..65535  ⇒ **17×65536 种组合全查**；
//    · 期望值用整数算式独立算一遍（不复制 DUT 的位拼接写法）：
//          want = floor(c * (bri+1) / 16)   每个通道各算
//    · 另外两条硬约束单独查：
//        ① bri_lv = 15 ⇒ px_out === px_in（**逐位原样**，默认档不许改画面）
//        ② 单调性：同一个 px_in，bri 越大输出通道值不减
//
//  本台子不进 TD 工程（M2.al 里没有它），只在本机 ModelSim 跑。
//  ★ 纯 ASCII。
// ============================================================
`timescale 1ns / 1ps

module tb_bri_scale;

    reg  [3:0]  bri;
    reg  [15:0] px;
    wire [15:0] pxo;

    bri_scale u_dut (.bri_lv(bri), .px_in(px), .px_out(pxo));

    integer b, p, n_bad, n_chk, n_mon_bad, prev_r, prev_g, prev_b;
    integer wr, wg, wb, gotr, gotg, gotb;

    task chk_all_bri_for_px;
        input integer pp;
        begin
            px = pp[15:0];
            prev_r = -1; prev_g = -1; prev_b = -1;
            for (b = 0; b <= 15; b = b + 1) begin
                bri = b[3:0];
                #1;
                wr = (pp[15:11] * (b + 1)) / 16;
                wg = (pp[10:5]  * (b + 1)) / 16;
                wb = (pp[4:0]   * (b + 1)) / 16;
                gotr = pxo[15:11];
                gotg = pxo[10:5];
                gotb = pxo[4:0];
                n_chk = n_chk + 1;
                if (gotr !== wr || gotg !== wg || gotb !== wb) begin
                    n_bad = n_bad + 1;
                    if (n_bad <= 10)
                        $display("BAD bri=%0d px=%h got R%0d G%0d B%0d want R%0d G%0d B%0d",
                                 b, pp, gotr, gotg, gotb, wr, wg, wb);
                end
                // 单调性（同一个 px，bri 递增）
                if (gotr < prev_r || gotg < prev_g || gotb < prev_b) begin
                    n_mon_bad = n_mon_bad + 1;
                    if (n_mon_bad <= 5)
                        $display("NOT MONOTONE bri=%0d px=%h", b, pp);
                end
                prev_r = gotr; prev_g = gotg; prev_b = gotb;
            end
        end
    endtask

    initial begin
        n_bad = 0; n_chk = 0; n_mon_bad = 0;
        bri = 4'd15; px = 16'h0000; #1;

        // ---- ① bri_lv = 15 必须逐位透传（65536 个色全查）----
        bri = 4'd15;
        for (p = 0; p < 65536; p = p + 1) begin
            px = p[15:0];
            #1;
            if (pxo !== px) begin
                n_bad = n_bad + 1;
                if (n_bad <= 10) $display("PASSTHRU BAD bri=15 px=%h got %h", px, pxo);
            end
            n_chk = n_chk + 1;
        end

        // ---- ② 17 × 65536 全组合逐位对照 ----
        for (p = 0; p < 65536; p = p + 1) chk_all_bri_for_px(p);

        $display("=== tb_bri_scale DONE: %0d 项检查（17 档 × 65536 色 + 透传档），bad=%0d，非单调=%0d ===",
                 n_chk, n_bad, n_mon_bad);
        if (n_bad == 0 && n_mon_bad == 0) $display("RESULT: PASS");
        else                              $display("RESULT: FAIL");
        $finish;
    end

endmodule
