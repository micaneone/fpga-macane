// ============================================================
//  tb_bmp_decim —— 验 bmp_analyze 的【方案B v2：整数抽取 + seek】
//
//  为什么要这个台子：这个功能今晚已经两次上板失败（一次没提速、一次长宽比错）。
//  这次的低层改动是**读地址跳转**，必须逐像素核对，不能靠肉眼看板子。
//
//  台子做什么：
//    · 造一个合成 BMP 放在数组里（24 位、行首 padding 覆盖到 4 字节对齐）；
//    · 例化 bmp_analyze，假扮"共享前端"按 md_lba/md_req 一个扇区一个扇区地喂字节；
//    · 假扮"查文件引擎"，立刻回 done/sector/size；
//    · 逐像素核对：第 n 个吐出的像素，应当来自源图
//          src_row = (n / wd) << lg,  src_col = (n % wd) << lg
//      像素内容约定：B = src_row & 0xFF，G = src_col & 0xFF，R = 0xA5
//      ⇒ RGB565 = {5'b10100, G[7:2], B[7:3]}，比对即可抓到"行错位/漏行/漏列"。
//
//  用例：
//    ① 小图 40x30（不抽稀）→ 期望 px = 40*30、img_width/height = 40/30、无 seek
//    ② 大图 96x1300（H>1200 ⇒ lg=1）→ 期望 px = 48*650、img = 48/650
//    ③ 大图 96x2500（H>2400 ⇒ lg=2）→ 期望 px = 24*625、img = 24/625
//    ★★★ 2026-10-17【修 bug ① 的用例】W*3 % 4 != 0 的图（行尾真有 padding）：
//    ④ 39x30   （117 字节/行 ⇒ 补 3 字节，不抽稀）
//    ⑤ 101x1300（303 ⇒ 补 1，lg=1）
//    ⑥ 255x2500（765 ⇒ 补 3，lg=2）
//    上面 ①~③ 的 W*3 都能被 4 整除（旧代码一样过），只有 ④~⑥ 能抓到
//    "填充字节被当像素吃掉 ⇒ 整图错行" 这个 bug。
//
//  ★ 纯 ASCII。
// ============================================================
`timescale 1ns / 1ps

module tb_bmp_decim;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                 // 50 MHz

    // ---------------- 合成 BMP 内容 ----------------
    localparam integer MAXB = 260*2600*3 + 64;   // 够最大那个用例（W ≤ 260、H ≤ 2600）
    reg [7:0] mem [0:MAXB-1];
    integer   filesz;

    // 造文件：W x H，24bpp，data_off = 54，每行 padding 到 4 字节
    integer k, r, c;
    integer stride;
    task build_bmp;
        input integer W;
        input integer H;
        begin
            for (k = 0; k < MAXB; k = k + 1) mem[k] = 8'h00;
            // ---- 头 ----
            mem[0] = 8'h42; mem[1] = 8'h4D;             // 'B','M'
            mem[2]  = 8'd0; mem[3]  = 8'd0; mem[4]  = 8'd0; mem[5]  = 8'd0;
            mem[10] = 8'd54; mem[11] = 8'd0; mem[12] = 8'd0; mem[13] = 8'd0;
            mem[14] = 8'd40; mem[15] = 8'd0; mem[16] = 8'd0; mem[17] = 8'd0;
            mem[18] = W[7:0];   mem[19] = W[15:8];   mem[20] = 8'd0; mem[21] = 8'd0;
            mem[22] = H[7:0];   mem[23] = H[15:8];   mem[24] = 8'd0; mem[25] = 8'd0;
            mem[26] = 8'd1;     mem[27] = 8'd0;
            mem[28] = 8'd24;    mem[29] = 8'd0;
            // ---- 像素 ----
            stride = ((W * 3 + 3) >> 2) << 2;
            for (r = 0; r < H; r = r + 1) begin
                for (c = 0; c < W; c = c + 1) begin
                    mem[54 + r*stride + c*3 + 0] = r[7:0];      // B = 行号
                    mem[54 + r*stride + c*3 + 1] = c[7:0];      // G = 列号
                    mem[54 + r*stride + c*3 + 2] = 8'hA5;       // R
                end
                for (k = W*3; k < stride; k = k + 1) begin
                    mem[54 + r*stride + k] = 8'hFF;             // 行尾 padding
                end
            end
            filesz = 54 + H*stride;
        end
    endtask

    // ---------------- DUT ----------------
    reg         start = 0;
    reg  [3:0]  skip  = 0;
    wire        busy, done, fail;
    wire        seq_rd;
    wire [15:0] img_width, img_height;
    wire        img_valid;
    wire [15:0] px_data;
    wire        px_we;
    wire [31:0] px_addr;
    wire        led_init, sd_ready;
    wire [31:0] dbg_px_cnt, dbg_data_off;
    wire [15:0] dbg_first_px;
    wire [31:0] dbg_first_addr;

    // 前端（分析器这一侧）
    wire [31:0] fe_lba_bmp;
    wire        fe_req_bmp;
    reg  [7:0]  fe_data;
    reg         fe_ok, fe_done, fe_err;
    wire        fe_busy;
    wire        fe_owner_w;
    // 引擎
    wire [23:0] eng_ext; wire [3:0] eng_skip; wire eng_start, eng_owner;
    wire [31:0] eng_lba_i, eng_req_i;
    wire        eng_busy, eng_done, eng_fail;
    wire [31:0] eng_sector, eng_size, eng_cluster;

    bmp_analyze u_dut (
        .sys_clk      (clk),
        .sys_rst_n    (rst_n),
        .fe_init_done (1'b1),
        .fe_led       (),
        .fe_owner     (fe_owner_w),
        .fe_lba       (fe_lba_bmp),
        .fe_req       (fe_req_bmp),
        .fe_data      (fe_data),
        .fe_ok        (fe_ok),
        .fe_done      (fe_done),
        .fe_busy      (fe_busy),
        .fe_err       (fe_err),
        .eng_ext      (eng_ext),
        .eng_skip     (eng_skip),
        .eng_start    (eng_start),
        .eng_owner    (eng_owner),
        .eng_lba_i    (eng_lba_i),
        .eng_req_i    (eng_req_i),
        .eng_busy     (eng_busy),
        .eng_done     (eng_done),
        .eng_fail     (eng_fail),
        .eng_sector   (eng_sector),
        .eng_size     (eng_size),
        .eng_cluster  (eng_cluster),
        .start        (start),
        .skip         (skip),
        .busy         (busy),
        .done         (done),
        .fail         (fail),
        .img_width    (img_width),
        .img_height   (img_height),
        .img_valid    (img_valid),
        .px_data      (px_data),
        .px_we        (px_we),
        .px_addr      (px_addr),
        .led_init     (led_init),
        .sd_ready     (sd_ready),
        .seq_rd       (seq_rd),
        .dbg_px_cnt   (dbg_px_cnt),
        .dbg_data_off (dbg_data_off),
        .dbg_first_px (dbg_first_px),
        .dbg_first_addr (dbg_first_addr)
    );

    // ---------------- 引擎：立刻回"查到了" ----------------
    localparam [31:0] FILE_SEC = 32'd100;     // 文件起始扇区
    reg [3:0] eng_dly;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eng_dly <= 4'd0;
        end
        else if (eng_start) eng_dly <= 4'd1;      // 一拍后回 done
        else if (eng_dly != 4'd0 && eng_dly != 4'd15) eng_dly <= eng_dly + 4'd1;
    end
    assign eng_done    = (eng_dly == 4'd3);
    assign eng_fail    = 1'b0;
    assign eng_busy    = 1'b0;
    assign eng_lba_i   = 32'd0;
    assign eng_req_i   = 1'b0;
    assign eng_sector  = FILE_SEC;
    assign eng_size    = filesz;
    assign eng_cluster = 32'd0;

    // ---------------- 假前端：按 fe_req 一个扇区一个扇区喂 ----------------
    reg  [31:0] md_lba;
    reg  [9:0]  md_bcnt;
    reg         md_busy;
    integer     md_off;
    integer     n_sec;      // ★ 这次读了多少个扇区（= fe_done 次数）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            md_lba <= 32'd0; md_bcnt <= 10'd0; md_busy <= 1'b0;
            fe_ok <= 1'b0; fe_done <= 1'b0; fe_err <= 1'b0; fe_data <= 8'hFF;
        end
        else begin
            fe_ok   <= 1'b0;
            fe_done <= 1'b0;
            fe_err  <= 1'b0;
            if (!md_busy) begin
                if (fe_req_bmp) begin
                    md_lba  <= fe_lba_bmp;
                    md_bcnt <= 10'd0;
                    md_busy <= 1'b1;
                end
            end
            else begin
                if (md_bcnt < 10'd512) begin
                    md_off = (md_lba - FILE_SEC) * 512 + md_bcnt;
                    fe_data <= (md_off >= 0 && md_off < filesz) ? mem[md_off % MAXB] : 8'hFF;
                    fe_ok   <= 1'b1;
                    md_bcnt <= md_bcnt + 10'd1;
                end
                else begin
                    md_busy <= 1'b0;
                    fe_done <= 1'b1;
                    n_sec   = n_sec + 1;      // ★ 记一次"读了一个扇区"
                end
            end
        end
    end
    assign fe_busy    = md_busy;
    assign fe_owner_w = 1'b1;

    // ---------------- 逐像素核对 ----------------
    integer n_px, n_bad, exp_row, exp_col, wd_exp, hd_exp, lg_exp;
    reg [15:0] exp_px;
    always @(posedge clk) begin
        if (px_we) begin
            exp_row = (n_px / wd_exp) << lg_exp;
            exp_col = (n_px % wd_exp) << lg_exp;
            exp_px  = {5'b10100, exp_col[7:2], exp_row[7:3]};
            if (px_data !== exp_px) begin
                n_bad = n_bad + 1;
                if (n_bad <= 6)
                    $display("   !! PX MISMATCH n=%0d got=%h want=%h (exp src row=%0d col=%0d)",
                             n_px, px_data, exp_px, exp_row, exp_col);
            end
            n_px = n_px + 1;
        end
    end

    // ---------------- 跑一个用例 ----------------
    integer W, H, tmo;
    task run_case;
        input integer Wc;
        input integer Hc;
        begin
            W = Wc; H = Hc;
            lg_exp = (H > 1800) ? 2 : (H > 900) ? 1 : 0;
            wd_exp = W >> lg_exp;
            hd_exp = H >> lg_exp;
            build_bmp(W, H);
            n_px = 0; n_bad = 0; n_sec = 0;
            // 复位
            rst_n = 0; start = 0;
            repeat (5) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;
            // 等结束（给足时间：大图要读不少扇区，但抽稀后少很多）
            tmo = 0;
            while (!done && !fail && tmo < 4000000) begin
                @(posedge clk);
                tmo = tmo + 1;
            end
            $display("W=%0d H=%0d  lg=%0d  img=%0dx%0d (want %0dx%0d)  px=%0d (want %0d)  bad=%0d  done=%0b fail=%0b",
                     W, H, lg_exp, img_width, img_height, wd_exp, hd_exp,
                     n_px, wd_exp*hd_exp, n_bad, done, fail);
            $display("        读了 %0d 个扇区（全读要 %0d 个）⇒ 读量 %0d%%",
                     n_sec, (filesz+511)/512, (n_sec*100)/((filesz+511)/512));
            if (img_width != wd_exp || img_height != hd_exp ||
                n_px != wd_exp*hd_exp || n_bad != 0 || !done)
                $display("   !! CASE FAILED");
        end
    endtask

    initial begin
        $display("=== tb_bmp_decim start ===");
        run_case(40, 30);        // 不抽（无 padding）
        run_case(256, 1300);     // ÷2（行宽 768B ≈ 真实 1536 宽的情形）
        run_case(256, 2500);     // ÷4
        // ★★★ 2026-10-17【修 bug ①】行尾真有 padding 的三个用例
        run_case(39, 30);        // 117B/行 ⇒ 补 3，不抽稀（走 keep_rn 原地继续）
        run_case(101, 1300);     // 303B/行 ⇒ 补 1，÷2
        run_case(255, 2500);     // 765B/行 ⇒ 补 3，÷4
        $display("=== DONE ===");
        $finish;
    end

endmodule
