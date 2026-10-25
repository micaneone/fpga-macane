// ============================================================
//  文件   : tb_zoom_pipe.v
//  作用   : zoom_sel 三级流水改造的等价性验证（对拍旧实现 zoom_sel_ref）
//  说明   : 旧实现（zoom_sel_ref）是纯组合、同拍出结果；新实现（zoom_sel）
//            latency = 3 clk_pix。本 TB 把旧输出打 3 拍，与新输出逐拍比较：
//            step_q16 / off_u_q16 / off_v_q16 / bilin_en / step_fit_q16 全等才算 PASS。
//           激励覆盖：6 个档位、各种源尺寸、窗口尺寸随机变。
// ============================================================
`timescale 1ns / 1ps

module tb_zoom_pipe;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #12.5 clk = ~clk;            // 40 MHz

    reg  [2:0]  level;
    reg  [11:0] src_w, src_h, win_w, win_h;

    // 新实现
    wire [31:0]        n_step, n_offu, n_offv, n_fit;
    wire               n_bilin, n_busy;
    // 旧实现（参考）
    wire [31:0]        r_step, r_offu, r_offv, r_fit;
    wire               r_bilin, r_busy;

    zoom_sel u_new (
        .clk_pix     (clk),
        .rst_pix_n   (rst_n),
        .level       (level),
        .src_w       (src_w),
        .src_h       (src_h),
        .win_w       (win_w),
        .win_h       (win_h),
        .step_q16    (n_step),
        .off_u_q16   (n_offu),
        .off_v_q16   (n_offv),
        .bilin_en    (n_bilin),
        .step_fit_q16(n_fit),
        .fit_busy    (n_busy)
    );

    zoom_sel_ref u_ref (
        .clk_pix     (clk),
        .rst_pix_n   (rst_n),
        .level       (level),
        .src_w       (src_w),
        .src_h       (src_h),
        .win_w       (win_w),
        .win_h       (win_h),
        .step_q16    (r_step),
        .off_u_q16   (r_offu),
        .off_v_q16   (r_offv),
        .bilin_en    (r_bilin),
        .step_fit_q16(r_fit),
        .fit_busy    (r_busy)
    );

    // ============================================================
    //  旧结果延迟 3 拍（对齐新实现 latency）
    // ============================================================
    reg [31:0] d1_step, d1_offu, d1_offv, d1_fit;
    reg        d1_bilin;
    reg [31:0] d2_step, d2_offu, d2_offv, d2_fit;
    reg        d2_bilin;
    reg [31:0] d3_step, d3_offu, d3_offv, d3_fit;
    reg        d3_bilin;

    always @(posedge clk) begin
        d1_step <= r_step;  d1_offu <= r_offu;  d1_offv <= r_offv;  d1_fit <= r_fit;  d1_bilin <= r_bilin;
        d2_step <= d1_step; d2_offu <= d1_offu; d2_offv <= d1_offv; d2_fit <= d1_fit; d2_bilin <= d1_bilin;
        d3_step <= d2_step; d3_offu <= d2_offu; d3_offv <= d2_offv; d3_fit <= d2_fit; d3_bilin <= d2_bilin;
    end

    // ============================================================
    //  逐拍比较
    // ============================================================
    integer errs = 0;
    integer cyc  = 0;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (rst_n && cyc > 8) begin
            if (n_step  !== d3_step  || n_offu !== d3_offu ||
                n_offv  !== d3_offv  || n_bilin !== d3_bilin ||
                n_fit   !== d3_fit) begin
                errs <= errs + 1;
                if (errs < 8) begin
                    $display("MISMATCH @%0t: step %h/%h offu %h/%h offv %h/%h bilin %b/%b fit %h/%h",
                             $time,
                             n_step, d3_step, n_offu, d3_offu, n_offv, d3_offv,
                             n_bilin, d3_bilin, n_fit, d3_fit);
                end
            end
        end
    end

    // ============================================================
    //  激励①：定值档位扫一遍
    // ============================================================
    initial begin
        level = 3'd0;
        src_w = 12'd800; src_h = 12'd600;
        win_w = 12'd800; win_h = 12'd600;

        #100 rst_n = 1'b1;
        #100;

        level = 3'd0; #200;
        level = 3'd1; #200;
        level = 3'd2; #200;
        level = 3'd3; #200;
        level = 3'd4; #200;
        level = 3'd5; #200;

        // 再来一轮不同源尺寸（640×480 走适配档）
        src_w = 12'd640; src_h = 12'd480;
        level = 3'd0; #200;

        // 让激励②跑够时间后收尾
        #80000;
        if (errs == 0) $display("RESULT: PASS  (latency=3, no mismatch over %0d cycles)", cyc);
        else           $display("RESULT: FAIL  (mismatches=%0d over %0d cycles)", errs, cyc);
        $finish;
    end

    // ============================================================
    //  激励②：随机跳变（每 7~13 拍），故意在 rst 释放后 2 µs 才开始
    // ============================================================
    integer k;
    integer rv;
    initial begin
        #2000;
        for (k = 0; k < 400; k = k + 1) begin
            rv = $random & 32'h7FFFFFFF;
            #(25 * ((rv % 7) + 7));
            level = rv % 6;
            rv    = $random & 32'h7FFFFFFF;
            src_w = 12'd320 + (rv % 9) * 12'd80;
            rv    = $random & 32'h7FFFFFFF;
            src_h = 12'd240 + (rv % 9) * 12'd60;
            rv    = $random & 32'h7FFFFFFF;
            win_w = 12'd640 + (rv % 5) * 12'd80;
            rv    = $random & 32'h7FFFFFFF;
            win_h = 12'd480 + (rv % 4) * 12'd60;
        end
    end

endmodule
