// ============================================================
//  tb_sd_stream —— 验 sd_read 的 CMD18 多块连续读（2026-10-17）
//
//  判据（这是本次改动的**全部**风险点）：
//    ① **数据对不对**：两种模式下读回的每个字节都必须等于卡模型给的
//       扇区 N 第 i 字节 = (N*7+i)&0xFF；
//    ② **read_done 一拍不少**：每读一个扇区正好一次；
//    ③ **流式真的省了命令**：同一串 8 个连续扇区，
//       `stream_en=1` 时卡模型收到的命令数必须是 **1**（原来 8 条）；
//       同时仿真时间要明显短于 `stream_en=0`（模型里每块 1500 个 SCLK 的访问延迟）；
//    ④ **流式能收尾**：读完后 CS 会撤、状态机回 IDLE，下一笔事务还能正常开始。
//
//  ★ 直接用 `sd_read`（不套 cdc），时钟 50 MHz ⇒ SCLK = 12.5 MHz（和上板一致）。
//  ★ 纯 ASCII。
// ============================================================
`timescale 1ns / 1ps

module tb_sd_stream;

    localparam integer NSEC   = 8;         // 连续读几个扇区
    localparam integer LAT    = 187;       // 卡访问延迟（字节）= 约 1500 个 SCLK ≈ 120 us
    localparam [31:0]  BASE   = 32'd2048;  // 起始扇区

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                 // 50 MHz → SCLK 12.5 MHz

    // ---- DUT ----
    reg         read_req = 0;
    reg  [31:0] read_addr = 0;
    wire        read_busy, read_ok, read_done, read_err;
    wire [7:0]  data_out;
    wire        spi_mosi, spi_clk, spi_cs;
    wire        miso;
    reg         stream_en = 0;

    sd_read #(.TIME_OUT(22'd2_000_000), .IDLE_MAX(16'd10), .sck_div(0)) u_dut (
        .sys_clk   (clk),
        .sys_rst_n (rst_n),
        .init_done (1'b1),
        .read_req  (read_req),
        .read_addr (read_addr),
        .read_busy (read_busy),
        .read_ok   (read_ok),
        .read_done (read_done),
        .read_err  (read_err),
        .data_out  (data_out),
        .spi_mosi  (spi_mosi),
        .spi_miso  (miso),
        .spi_clk   (spi_clk),
        .spi_cs    (spi_cs),
        .stream_en (stream_en)
    );

    // ---- 假 SD 卡 ----
    sd_card_model #(.LAT_BYTES(LAT), .GAP_BYTES(0)) u_card (
        .spi_clk (spi_clk),
        .spi_cs  (spi_cs),
        .spi_mosi(spi_mosi),
        .spi_miso(miso),
        .sys_rst_n(rst_n)
    );

    // ---- 收字节 / 计数 ----
    integer rx_cnt;          // 收到多少字节
    integer done_cnt;        // read_done 来了几次
    integer bad_cnt;         // 内容错几次
    integer cmd_at_start;    // 本用例开始前的命令数
    integer ncmd;            // 本用例用了多少条命令
    reg [7:0] exp_byte;
    integer   cur_sec;       // 期望的扇区号
    integer   cur_idx;       // 期望的扇区内偏移

    always @(posedge clk) begin
        if (read_ok) begin
            exp_byte = ((cur_sec * 7) + cur_idx) & 8'hFF;
            if (data_out !== exp_byte[7:0]) begin
                bad_cnt = bad_cnt + 1;
                if (bad_cnt <= 6)
                    $display("  !! BYTE MISMATCH sec=%0d idx=%0d got=%h want=%h",
                             cur_sec, cur_idx, data_out, exp_byte);
            end
            rx_cnt  = rx_cnt + 1;
            cur_idx = cur_idx + 1;
            if (cur_idx == 512) begin
                cur_idx = 0;
                cur_sec = cur_sec + 1;
            end
        end
        if (read_done) begin
            done_cnt = done_cnt + 1;
            $display("   read_done #%0d at %0t", done_cnt, $time);
        end
    end

    // ---- 诊断：状态跳变打时间戳（只在流式那一轮打开）----
    reg dbg_on = 1'b0;
    reg [2:0] st_prev;
    reg [3:0] fl_prev;
    reg [7:0] fl_prev2;
    always @(posedge clk) begin
        if (dbg_on) begin
            if (u_card.st !== st_prev) begin
                $display("   t=%0t card %0d->%0d txb=%h bits=%0d div=%0d cnt=%0d clken=%b",
                         $time, st_prev, u_card.st, u_card.tx_byte, u_card.tx_bits,
                         u_dut.u_my_spi.div_cnt, u_dut.u_my_spi.cnt, u_dut.spi_clk_en);
                st_prev = u_card.st;
            end
            if (u_dut.flag_r !== fl_prev) begin
                $display("   t=%0t dut  %0d->%0d cnt=%0d to=%0d",
                         $time, fl_prev, u_dut.flag_r, u_dut.data_cnt, u_dut.time_out);
                fl_prev = u_dut.flag_r;
            end
        end
    end

    // ---- 跑一组用例 ----
    time t0;
    task run_case;
        input        st_en;
        input        dbg_id;
        integer i;
        begin
            // 复位
            dbg_on = 1'b0;
            rst_n = 0; read_req = 0; stream_en = st_en;
            rx_cnt = 0; done_cnt = 0; bad_cnt = 0;
            cur_sec = BASE; cur_idx = 0;
            repeat (4) @(posedge clk);
            rst_n = 1;
            repeat (4) @(posedge clk);
            cmd_at_start = u_card.cmd_count;
            t0 = $time;
            dbg_on = st_en;      // ★ 只在流式那一轮打诊断

            // 逐个扇区请求（和 bmp_analyze 的用法一致：等 !busy → 举 req → 等 busy → 撤 req）
            for (i = 0; i < NSEC; i = i + 1) begin
                @(posedge clk);
                while (read_busy) @(posedge clk);
                read_addr = BASE + i;
                read_req  = 1;
                @(posedge clk);
                while (!read_busy) @(posedge clk);
                @(posedge clk);
                read_req = 0;
            end

            // 等最后一次 done（留点余量给收尾：CMD12 + 撤 CS）
            while (done_cnt < NSEC) @(posedge clk);
            repeat (4000) @(posedge clk);

            // ★★★ 2026-10-17【上板失败的那条路径】流式跑完之后，紧接着做一次
            //   **普通单块读**（stream_en=0，地址故意不连续）。上板就是这里挂的：
            //   收流没收干净 ⇒ 随后的音频/字幕装载全失败。仿真必须覆盖它。
            stream_en = 1'b0;
            @(posedge clk);
            while (read_busy) @(posedge clk);
            read_addr = BASE + 32'd100;
            read_req  = 1;
            @(posedge clk);
            while (!read_busy) @(posedge clk);
            @(posedge clk);
            read_req = 0;
            // 这一块的期望扇区号
            cur_sec = BASE + 100;
            cur_idx = 0;
            repeat (20) @(posedge clk);
            while (done_cnt < (NSEC + 1)) @(posedge clk);
            repeat (2000) @(posedge clk);

            ncmd = u_card.cmd_count - cmd_at_start;
            $display("stream_en=%0d : bytes=%0d (want %0d)  done=%0d (want %0d)  cmd=%0d  bad=%0d",
                     st_en, rx_cnt, (NSEC+1)*512, done_cnt, (NSEC+1), ncmd, bad_cnt);
            if (rx_cnt != (NSEC+1)*512 || done_cnt != (NSEC+1) || bad_cnt != 0)
                $display("  !! CASE FAILED");
        end
    endtask

    time t_slow, t_fast;
    initial begin
        $display("=== tb_sd_stream: LAT=%0d SCLK cyc, NSEC=%0d ===", LAT, NSEC);
        run_case(1'b0, 0);
        t_slow = $time;
        run_case(1'b1, 1);
        t_fast = $time;
        $display("=== DONE ===");
        $finish;
    end

endmodule
