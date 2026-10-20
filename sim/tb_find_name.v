//==========================================================================
//  tb_find_name —— 验 `find_bmp_eng` 的【按名字分类找图】（2026-10-20 A 轨交付）
//
//  为什么要这个台子：名字匹配这段逻辑藏在共享引擎的 P_DIR 里，
//  `tb_bmp_decim` 把引擎整个假掉了（直接回"查到了"）⇒ 它一行都覆盖不到。
//  这里直接例化引擎，喂一个手工搭的 FAT32 镜像：
//
//      lba0  MBR   （分区 1，type 0x0C，起始 LBA=1）
//      lba1  BPB   （512B/扇区、1 扇区/簇、reserved=1、num_fats=2、fat_size=1、根簇=2）
//      lba4  根目录（data_start = 1+1+2 = 4；簇 2 → 扇区 4）
//             AD1.BMP  size=0x1000
//             MAP1.BMP size=0x2000
//             AD2.BMP  size=0x1100
//             ZZZ.BMP  size=0x3000
//             0x00 结束标记
//
//  六个用例（期望值就是"这一步必须挑中哪一条"，错了立刻能看出是"漏挑"还是"误挑"）：
//    ① name_en=0 skip=0            → 0x1000  （老行为：按扩展名数第 1 个）
//    ② name_en=0 skip=1            → 0x2000  （老行为：第 2 个 = MAP1）
//    ③ name_en=1 sel=0(AD)  skip=0 → 0x1000  （AD1）
//    ④ name_en=1 sel=0(AD)  skip=1 → 0x1100  （AD2 ⇒ 证明 AD 类内部计数、MAP 被跳过）
//    ⑤ name_en=1 sel=1(MAP) skip=0 → 0x2000  （MAP1 ⇒ 证明 AD 被跳过）
//    ⑥ name_en=1 sel=1(MAP) skip=1 → fail    （只有一个 MAP ⇒ 不能误挑 AD/ZZZ）
//==========================================================================
`timescale 1ns/1ps

module tb_find_name;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;          // 50 MHz

    // ---------------- DUT 端口 ----------------
    reg         fe_init_done = 1'b1;
    reg  [7:0]  fe_data  = 8'h00;
    reg         fe_ok    = 1'b0;
    reg         fe_done  = 1'b0;
    reg         fe_busy  = 1'b0;
    reg         fe_err   = 1'b0;

    reg         start = 1'b0;
    reg         cmd    = 1'b0;
    reg         owner  = 1'b1;
    reg  [31:0] in_cluster = 32'd0;
    reg  [23:0] target_ext = {"B","M","P"};
    reg  [3:0]  skip_cmd   = 4'd0;
    reg         name_en    = 1'b0;
    reg         name_sel   = 1'b0;

    wire        busy, done, fail;
    wire [31:0] eng_lba;
    wire        eng_req;
    wire        eng_busy;
    wire [31:0] eng_res_sector, eng_res_size, eng_res_cluster;
    wire        eng_res_done, eng_res_fail;

    find_bmp_eng u_eng (
        .sys_clk        (clk),
        .sys_rst_n      (rst_n),
        .fe_init_done   (fe_init_done),
        .fe_data        (fe_data),
        .fe_ok          (fe_ok),
        .fe_done        (fe_done),
        .fe_busy        (fe_busy),
        .fe_err         (fe_err),
        .start          (start),
        .owner          (owner),
        .target_ext     (target_ext),
        .name_en        (name_en),
        .name_sel       (name_sel),
        .cmd            (cmd),
        .skip           (skip_cmd),
        .in_cluster     (in_cluster),
        .busy           (busy),
        .done           (done),
        .fail           (fail),
        .eng_lba        (eng_lba),
        .eng_req        (eng_req),
        .eng_busy       (eng_busy),
        .eng_res_sector (eng_res_sector),
        .eng_res_size   (eng_res_size),
        .eng_res_cluster(eng_res_cluster),
        .eng_res_done   (eng_res_done),
        .eng_res_fail   (eng_res_fail)
    );

    //==========================================================================
    //  卡镜像：8 个扇区（0..7）
    //==========================================================================
    localparam NIMG = 4096;
    reg [7:0] img [0:NIMG-1];

    task put;                       // 往镜像里放一个字节
        input integer off;
        input [7:0]   val;
        begin
            img[off] = val;
        end
    endtask

    task put_name;                  // 8.3 名字（不足补空格）；base = 目录项在镜像里的偏移
        input integer base;
        input [7:0]  c0, c1, c2;
        begin
            put(base+0, c0);
            put(base+1, c1);
            put(base+2, c2);
            put(base+3, " ");
            put(base+4, " ");
            put(base+5, " ");
            put(base+6, " ");
            put(base+7, " ");
            put(base+8, "B");
            put(base+9, "M");
            put(base+10,"P");
        end
    endtask

    task put_size;                  // 目录项 28..31 = 文件长度
        input integer base;
        input [31:0]  sz;
        begin
            put(base+28, sz[7:0]);
            put(base+29, sz[15:8]);
            put(base+30, sz[23:16]);
            put(base+31, sz[31:24]);
        end
    endtask

    integer k;
    initial begin
        for (k = 0; k < NIMG; k = k + 1) img[k] = 8'h00;

        // ---- lba0：MBR（分区项在 446，起始 LBA 在 454）----
        put(450, 8'h0C);            // 类型 FAT32 LBA
        put(454, 8'd1);             // 起始 LBA = 1
        put(510, 8'h55);
        put(511, 8'hAA);

        // ---- lba1：BPB ----
        put(512+11, 8'h00);         // 512 字节/扇区
        put(512+12, 8'h02);
        put(512+13, 8'd1);          // 1 扇区/簇
        put(512+14, 8'd1);          // reserved = 1
        put(512+15, 8'd0);
        put(512+16, 8'd2);          // num_fats = 2
        put(512+36, 8'd1);          // fat_size = 1
        put(512+44, 8'd2);          // 根簇 = 2
        put(1022, 8'h55);
        put(1023, 8'hAA);

        // ---- lba4：根目录（4 条 + 结束）----
        put_name(2048+0,   "A","D","1"); put(2048+11, 8'h20); put(2048+26, 8'd3); put_size(2048+0,  32'h0000_1000);
        put_name(2048+32,  "M","A","P"); put(2048+43, 8'h20); put(2048+58, 8'd4); put_size(2048+32, 32'h0000_2000);
        put_name(2048+64,  "A","D","2"); put(2048+75, 8'h20); put(2048+90, 8'd5); put_size(2048+64, 32'h0000_1100);
        put_name(2048+96,  "Z","Z","Z"); put(2048+107,8'h20); put(2048+122,8'd6); put_size(2048+96, 32'h0000_3000);
        // 2048+128 起保持 0x00（结束标记）
    end

    //==========================================================================
    //  假前端：按 eng_req 一个扇区一个扇区地喂（和 tb_bmp_decim 同一套时序）
    //==========================================================================
    reg  [31:0] f_lba;
    reg  [9:0]  f_cnt;
    reg         f_busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_lba <= 32'd0; f_cnt <= 10'd0; f_busy <= 1'b0;
            fe_ok <= 1'b0; fe_done <= 1'b0; fe_err <= 1'b0; fe_data <= 8'h00;
        end
        else begin
            fe_ok   <= 1'b0;
            fe_done <= 1'b0;
            fe_err  <= 1'b0;
            if (!f_busy) begin
                if (eng_req) begin
                    f_lba  <= eng_lba;
                    f_cnt  <= 10'd0;
                    f_busy <= 1'b1;
                end
            end
            else begin
                if (f_cnt < 10'd512) begin
                    fe_data <= (f_lba < 8) ? img[f_lba*512 + f_cnt] : 8'h00;
                    fe_ok   <= 1'b1;
                    f_cnt   <= f_cnt + 10'd1;
                end
                else begin
                    f_busy  <= 1'b0;
                    fe_done <= 1'b1;
                end
            end
        end
    end
    always @(*) fe_busy = f_busy;

    //==========================================================================
    //  跑一个用例
    //==========================================================================
    integer n_pass, n_bad, tmo;
    reg [31:0] got_size;
    reg        got_fail;

    task run_case;
        input         en;
        input         sel;
        input  [3:0]  sk;
        input  [31:0] want;
        input         want_fail;
        input  [255:0] tag;
        begin
            name_en  = en;
            name_sel = sel;
            skip_cmd = sk;
            got_size = 32'hDEAD_BEEF;
            got_fail = 1'b0;
            // 单拍 start
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            // 等 done / fail
            tmo = 0;
            while (!done && !fail && tmo < 400000) begin
                @(posedge clk);
                tmo = tmo + 1;
            end
            if (done) begin
                got_size = eng_res_size;      // ★ res_* 是组合的，done 那拍取
            end
            else if (fail) begin
                got_fail = 1'b1;
            end
            else begin
                $display("  !! TIMEOUT  en=%0d sel=%0d skip=%0d", en, sel, sk);
                n_bad = n_bad + 1;
            end
            if (want_fail) begin
                if (got_fail) begin
                    $display("  OK   %0s  en=%0d sel=%0d skip=%0d -> FAIL（预期）", tag, en, sel, sk);
                    n_pass = n_pass + 1;
                end
                else begin
                    $display("  BAD  %0s  en=%0d sel=%0d skip=%0d -> size=%h（应 FAIL，误挑！）",
                             tag, en, sel, sk, got_size);
                    n_bad = n_bad + 1;
                end
            end
            else begin
                if (!got_fail && got_size === want) begin
                    $display("  OK   %0s  en=%0d sel=%0d skip=%0d -> size=%h", tag, en, sel, sk, got_size);
                    n_pass = n_pass + 1;
                end
                else begin
                    $display("  BAD  %0s  en=%0d sel=%0d skip=%0d -> size=%h（want %h）fail=%0d",
                             tag, en, sel, sk, got_size, want, got_fail);
                    n_bad = n_bad + 1;
                end
            end
            // 等引擎回 IDLE 再下一例
            tmo = 0;
            while (busy && tmo < 1000) begin @(posedge clk); tmo = tmo + 1; end
            repeat (5) @(posedge clk);
        end
    endtask

    initial begin
        n_pass = 0;
        n_bad  = 0;
        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (10) @(posedge clk);

        $display("=== tb_find_name start ===");
        run_case(1'b0, 1'b0, 4'd0, 32'h0000_1000, 1'b0, "old-skip0   ");
        run_case(1'b0, 1'b0, 4'd1, 32'h0000_2000, 1'b0, "old-skip1   ");
        run_case(1'b1, 1'b0, 4'd0, 32'h0000_1000, 1'b0, "AD-skip0    ");
        run_case(1'b1, 1'b0, 4'd1, 32'h0000_1100, 1'b0, "AD-skip1    ");
        run_case(1'b1, 1'b1, 4'd0, 32'h0000_2000, 1'b0, "MAP-skip0   ");
        run_case(1'b1, 1'b1, 4'd1, 32'h0000_0000, 1'b1, "MAP-skip1   ");

        $display("=== DONE: pass=%0d bad=%0d ===", n_pass, n_bad);
        if (n_bad == 0) $display("PASS: 名字分类找图 6/6 全对");
        else            $display("FAIL: %0d 个用例不对", n_bad);
        $finish;
    end

endmodule
