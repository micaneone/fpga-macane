// ============================================================
//  tb_failsafe_pg —— 兜底页自检台（离线，不需要 TD）
//  干什么：
//    ① 把 4 个状态的文字区**打成 ASCII 点阵**打出来 —— 人眼一看就知道
//       字模/居中/间距对不对（这是唯一能"看见"兜底页的办法，本机没法抓 HDMI）；
//    ② 逐像素核对：`fs_on=0` 时必须**逐位透传**（px_out === px_in）；
//    ③ 核对底色/分隔条：文字格之外必须是 BG，不是黑也不是白。
//  怎么跑：sim\run_fs.bat
// ============================================================
`timescale 1ns / 1ps

module tb_failsafe_pg;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         de_in = 1;
    reg  [11:0] x_in = 0, y_in = 0;
    reg         fs_on = 0;
    reg  [1:0]  fs_state = 0;
reg  [1:0]  fs_hint  = 0;   // D3 C2/C3：0 = 正常 FW 行
    reg  [15:0] px_in = 16'h2222;
    wire [15:0] px_out;

    // 采样 DUT 的 BG（和模块默认参数一致）
    localparam [15:0] BG = 16'h1082;

    always #5 clk = ~clk;      // 100 MHz，频率无所谓（纯组合）

    failsafe_pg #(.SCALE(2)) dut (
        .clk_pix(clk), .rst_pix_n(rst_n),
        .de_in(de_in), .x_in(x_in), .y_in(y_in),
        .fs_on(fs_on), .fs_state(fs_state), .fs_hint(fs_hint),
        .px_in(px_in), .px_out(px_out)
    );

    integer bad = 0;
    integer i, s, xx, yy;
    integer r, c;
    reg [15:0] v;

    // 取一个像素
    task px_at;
        input [11:0] tx;
        input [11:0] ty;
        begin
            x_in = tx; y_in = ty; #1;
            v = px_out;
        end
    endtask

    // 把一块文字区打成 ASCII（每 2 像素采 1 点 ⇒ 正好还原 5×7 字形）
    task dump_line;
        input [11:0] x0;
        input [11:0] y0;
        input integer ncol;          // 字符数
        input integer nrow;          // 行数（每行 7 个字形行）
        integer cc, rr, pcx, pcy;
        begin
            for (rr = 0; rr < nrow*7; rr = rr + 1) begin
                $write("    ");
                for (cc = 0; cc < ncol*6; cc = cc + 1) begin
                    pcy = y0 + rr*2;
                    pcx = x0 + cc*2;
                    x_in = pcx; y_in = pcy; #1;
                    if (px_out != BG) $write("#");
                    else              $write(".");
                end
                $write("\n");
            end
        end
    endtask

    initial begin
        $display("========== tb_failsafe_pg ==========");
        rst_n = 0; #20; rst_n = 1; #10;

        // ---------- ① fs_on=0 必须逐位透传 ----------
        fs_on = 0;
        for (i = 0; i < 200; i = i + 1) begin
            px_in = i[15:0];
            px_at(i[11:0], i[11:0]);
            if (px_out !== px_in) begin
                bad = bad + 1;
                if (bad < 5) $display("FAIL passthru i=%0d px_out=%h px_in=%h", i, px_out, px_in);
            end
        end
        $display("passthru: bad=%0d (期望 0)", bad);

        // ---------- ② 四个状态各打一遍点阵 ----------
        fs_on = 1;
        for (s = 0; s < 4; s = s + 1) begin
            fs_state = s[1:0];
            $display("\n---- fs_state=%0d ----", s);
            $display("  品牌行 HX4S20C:");
            dump_line(12'd344, 12'd212, 7, 1);
            $display("  状态行:");
            // 状态行 x0 = 400 - len*8：5/7/9/10 字符 ⇒ 360/344/328/320
            case (s)
                0: dump_line(12'd360, 12'd244, 5,  1);
                1: dump_line(12'd344, 12'd244, 7,  1);
                2: dump_line(12'd328, 12'd244, 9,  1);
                default: dump_line(12'd320, 12'd244, 10, 1);
            endcase
            $display("  固件行 FW 3.0  2026-10-20:");
            dump_line(12'd264, 12'd276, 17, 1);
        end

        // ---------- ②b D3 · C2/C3：失败原因行 ----------
        fs_on = 1; fs_state = 2'd2;
        fs_hint = 2'b01;                       // 图像格式坏
        $display("\n---- fs_hint=01（图像格式）----");
        dump_line(12'd264, 12'd276, 17, 1);
        fs_hint = 2'b10;                       // 音频格式坏
        $display("\n---- fs_hint=10（音频格式）----");
        dump_line(12'd264, 12'd276, 17, 1);
        fs_hint = 2'b00;

        // ---------- ③ 文字区外必须是底色 ----------
        fs_state = 1'b0; fs_on = 1'b1;
        px_at(12'd100, 12'd100);
        if (px_out !== BG) begin bad = bad + 1; $display("FAIL 左上角应为 BG，实为 %h", px_out); end
        px_at(12'd700, 12'd560);
        if (px_out !== BG) begin bad = bad + 1; $display("FAIL 右下角应为 BG，实为 %h", px_out); end
        // de=0 时也要透传
        de_in = 0; px_in = 16'hAAAA; px_at(12'd400, 12'd250);
        if (px_out !== 16'hAAAA) begin bad = bad + 1; $display("FAIL de=0 未透传，实为 %h", px_out); end
        de_in = 1;

        $display("\n========== RESULT: bad=%0d ==========", bad);
        if (bad == 0) $display("PASS: 兜底页自检全绿");
        else          $display("FAIL");
        $finish;
    end

endmodule
