// ============================================================
//  sdr_rd_arb —— SDRAM 【读口】仲裁 + 分流（A 轨，给音频借读口用）
//
//  ★ 它解决的问题
//      SDRAM 读口只有一路（sdr_arb 的 disp_rd_en/addr），现在是显示的。
//      音频播放也要从 SDRAM 取 PCM → 两路不能同时接同一个口。
//
//  ★ 它【不改】队友的任何模块，只在顶层插一层转接：
//      line_buf ──disp_rd_en/addr──►┐
//                                    ├─► sdr_rd_arb ──rd_en/addr──► sdr_arb
//      音频读调度 ──aud_rd_en/addr─►┘                      （sdr_arb 一行不改）
//                                    ◄─sdr_rd_dout/en──
//
//  ★★ 两个关键设计
//      ① 【绝不压 disp_rd_en】
//         line_buf 的 fsent 是自己数的，我要是把它某一拍压掉，
//         它就少收一个字 → 那一行错位 ✗
//         ⇒ 仲裁只能是"音频让显示"：aud_win = aud_req & ~disp_rd_en
//
//      ② 【tag 队列分流，不需要知道读延迟】
//         每发一个读请求推一个 bit 进 tag 队列（0=显示 1=音频）；
//         每次 Sdr_rd_en 回来就弹一个 bit → 决定这份数据给谁。
//         队列顺序 = 数据回来顺序（SDRAM 顺序处理）⇒ 与延迟无关 ✓
//         而且显示的 vld 只在 tag=0 时拉高 ⇒ 显示的流水线【永远吃不到】音频的数据 ✓
//
//  ★ 时钟域
//      clk_mem  125 MHz    显存域 —— 显示读口在这边，仲裁器也在这边
//      clk_aud  12.288 MHz 音频域 —— sfx_player 在那边，数据用异步 FIFO 跨过去
//
//  ★★★ 声明全部前置（这个工程踩过五次"先用后声明"了）
// ============================================================
`timescale 1ns / 1ps

module sdr_rd_arb #(
    // ★★ 集成临时改动（见 规划\A轨待改清单.md 2026-10-05 第 5 条）——
    //    上板"杂音 + 白线扫屏"，定位到【这一版没通过时序】：
    //    40MHz 像素域 setup 从 +6.85ns 掉到 -1.87ns、50MHz 控制域从 +1.04 掉到 -2.90，
    //    布线后 slices 4807 -> 8399（85.7%）。病根是下面这颗 512×32 的 LUTRAM
    //    （TD 没推断成 BRAM，一个人吃掉 1814 LUT），把布局挤坏了。
    //    ⇒ AFIFO_AW 9 -> 7（512 -> 128 字）。128 对 LOW_MARK=48 仍有足够余量
    //      （音频只要 ~1 字 / 42µs，占用只在 48~75 之间摆动），换来 ~1300 LUT。
    //      ★ 想再省：换 lib/sdram 的 afifo_* 原语（BRAM 还剩 9 块）。
    parameter integer TAG_AW   = 7,             // tag 队列深度 = 128
                                                //  ★ 原来 6（=64）刚好等于 line_buf 的
                                                //    WORD_CREDIT（也是 64）⇒ 显示满载时
                                                //    音频再推一个 tag 就会回卷覆盖显示的表项。
                                                //    128 留出余量；再配下面 aud_win 的
                                                //    ~tag_full 兜底（只挡音频，绝不挡显示）。
    parameter integer AFIFO_AW = 7,             // 音频数据 FIFO 深度 = 128 字（原 512）
    parameter integer LOW_MARK = 22'd48         // 音频 FIFO 低于这个数就去读
)(
    input  wire        clk_mem,
    input  wire        rst_mem_n,

    input  wire        disp_rd_en,
    input  wire [20:0] disp_rd_addr,
    output wire [31:0] disp_rd_data,
    output wire        disp_rd_vld,

    output wire        rd_en,
    output wire [20:0] rd_addr,

    input  wire [31:0] sdr_rd_dout,
    input  wire        sdr_rd_en,
    // ★★ 集成临时改动（见 规划\A轨待改清单.md 2026-10-05 第 6 条）：
    //    SDRAM 核的"忙 / 刷新"标志。手册 2.3 和"移植注意"第 3 条都是让你
    //    **读写之前先看忙不忙** —— 忙的时候发出去的读请求，核可能不受理；
    //    对音频这种"重发一次不要紧"的请求，宁可不发（见下面 aud_win）。
    //    ★ 只用它推迟【音频】的读，绝不去挡【显示】的读。
    input  wire        sdr_busy,
    input  wire        sdr_init_ref_vld,

    input  wire        aud_play_tgl,        // ★ 控制域来的【toggle】（不是单拍脉冲）
                                            //   单拍脉冲跨到 125MHz 用两级同步会漏 ✗
    input  wire [20:0] aud_base,
    input  wire [20:0] aud_words,

    input  wire        clk_aud,
    input  wire        rst_aud_n,
    output wire [31:0] aud_dout,
    output wire        aud_vld,
    input  wire        aud_next,

    output wire        aud_busy,
    output wire        o_tag_bad,            // 1 = tag 队列脱钩过（sticky，上板诊断）
    // ★★★ 2026-10-05（第 8 条）：音频数据【自检】——把"从 SDRAM 读出来、
    //    准备喂给 sfx_player 的那些字"边收边累加：个数 + 32 位和。
    //    每次 play 命令（a_play_pulse）清零。上位机拿它与 WAV 算出的期望值比：
    //      个数对 + 和对  ⇒ SDRAM 读回来的音频数据【逐字正确】（= 沙沙声不是数据错）
    //      对不上        ⇒ 直接量出错字率，不用再猜
    output wire [15:0] aud_dbg_cnt,          // 本次播放已收多少个字
    output wire [31:0] aud_dbg_sum           // 这些字的 32 位累加和
);

    // ============================================================
    //  ★ 所有声明（寄存器 / 存储器 / 线 / 函数）全部放这里
    // ============================================================
    localparam integer TAG_DEPTH   = (1 << TAG_AW);
    localparam integer AFIFO_DEPTH = (1 << AFIFO_AW);
    localparam [TAG_AW:0] TAG_FULLVAL = TAG_DEPTH;

    // ---- tag 队列 ----
    reg  tag_mem [0 : TAG_DEPTH-1];
    reg  [TAG_AW:0] tag_wp, tag_rp;
    integer i;
    // ★★ 2026-10-05：静默重同步 + 脱钩诊断（见下面"二、tag 队列"）
    // ★★★ 第 10 条：这个阈值的意思是"【核确实空闲】连续这么多拍"。
    //   ★ 为什么从 1024 改成 256：既要有足够长的空闲（远大于读回来的延迟），
    //     又要能在两次刷新之间真的等到（SDRAM 每 7.8µs 刷新一次，
    //     125MHz 下刷新之间 ~965 拍，取 256 拍又稳又等得到）。
    localparam integer RSYNC_QUIET = 256;
    reg  [15:0] quiet_cnt;
    reg         tag_bad;                     // sticky：脱钩过一次
    // ★★ 第 8 条：音频数据自检累加器
    reg  [15:0] aud_cnt_r;
    reg  [31:0] aud_sum_r;
    // ★★★ 第 10 条：冗余读（同地址读两次、两次一致才收）
    //   为什么：自检已证明【路由是对的、但有低概率的"数据值被采错"】——
    //   显示错一个像素看不见，音频就是一声"沙"。音频的读流量只有读口的 ~0.02%，
    //   所以完全读得起两遍：**两次读回同一个值才收下**，不一致就再读（最多 4 次）。
    //   随机单次错的概率本来就低，两次都错成同一个值 ≈ 概率平方 ⇒ 基本消掉。
    //   ★ 每次只放一个读请求出去（等回来再发下一个），所以音频在途永远 ≤1，
    //     顺带把"音频和显示在总线上交织"的机会也压到最小。
    localparam integer A_TRIES = 3'd4;      // 一个字最多读 4 次
    reg  [20:0] a_word_idx;                  // 当前在第几个字（地址 = base + 这个）
    reg  [2:0]  a_try;                       // 这个字已经读回来几次
    reg  [31:0] a_prev;                      // 上一次读回来的值
    reg         a_prev_vld;                  // 上一次读回来的值有效吗
    reg         a_need_rd;                   // 现在要不要发一个读请求

    // ---- 音频命令同步（控制域 → 显存域）----
    reg  [20:0] a_base_s1, a_base_s2;
    reg  [20:0] a_words_s1, a_words_s2;
    reg         ap1, ap2, ap3;              // aud_play_tgl 的两级同步 + 检边沿

    // ---- 音频读调度（显存域）----
    reg  [20:0] a_base_r, a_words_r, a_iss;   // a_iss = 已【发出】多少个读请求
    reg         a_run;
    reg         aud_req;

    // ---- 音频数据 FIFO（显存域写 / 音频域读）----
    reg  [31:0] afifo [0 : AFIFO_DEPTH-1];
    reg  [AFIFO_AW:0] awp;                       // 写指针（显存域）
    reg  [AFIFO_AW:0] arp;                       // 读指针（音频域）
    reg  [AFIFO_AW:0] argray_sync;               // 读指针 gray（同步回显存域）
    reg  [AFIFO_AW:0] wgray_s1, wgray_s2;        // 写指针 gray（同步到音频域）

    // ---- 线 ----
    wire aud_win;
    wire [20:0] a_iss_eff;      // ★ 算上"这一拍正在授权的那一次"，防止多发一个
    wire [TAG_AW:0] tag_cnt;
    wire tag_full;
    wire tag_now;
    wire aud_rd_vld_m;
    wire a_play_pulse;
    wire [AFIFO_AW:0] argray_bin;
    wire [AFIFO_AW:0] wrp_bin;
    wire [AFIFO_AW:0] afifo_cnt;

    // ---- 函数（gray 编解码）----
    function [AFIFO_AW:0] bin2gray;
        input [AFIFO_AW:0] b;
        begin bin2gray = b ^ (b >> 1); end
    endfunction

    function [AFIFO_AW:0] gray2bin;
        input [AFIFO_AW:0] g;
        integer k;
        begin
            gray2bin[AFIFO_AW] = g[AFIFO_AW];
            for (k = AFIFO_AW-1; k >= 0; k = k - 1)
                gray2bin[k] = gray2bin[k+1] ^ g[k];
        end
    endfunction

    // ============================================================
    //  一、仲裁：音频只在【显示这一拍没请求】时用读口
    //     ★ 绝不压 disp_rd_en
    // ============================================================
    // ★★ 集成临时改动（见 规划\A轨待改清单.md 2026-10-05 第 5 条）：
    //    tag 队列满时【只挡音频】——显示的请求绝不能压（见本节开头①）。
    // ★★★ 2026-10-05 第 6 条：再加 ~sdr_busy & ~sdr_init_ref_vld。
    //   音频的请求是【电平】（aud_req 是寄存器，会一直保持），推迟几拍完全没事；
    //   而显示的是【逐拍脉冲】，一秒都不能压。所以这里只门控音频这一支。
    // ★★★ 2026-10-06【试过并否掉】`~sdr_busy & ~sdr_init_ref_vld`（第 6 条加的那道门）：
    //   上板验证 —— 把这颗核的 `Sdr_busy` 当"每一拍要不要发读"的门会把读口饿死
    //   （显示那条同样接法的实验直接导致"图完全不出来"）⇒ 这里也一起去掉。
    assign aud_win   = aud_req & ~disp_rd_en & ~tag_full;
    assign a_iss_eff = a_iss + (aud_win ? 21'd1 : 21'd0);

    assign rd_en   = aud_win ? 1'b1   : disp_rd_en;
    //  ★★ 地址必须【组合】算：a_iss 是授权的下一拍才加的，
    //     如果地址也寄存，连续两拍授权会读同一个地址 ✗（仿真抓到过）
    assign rd_addr = aud_win ? (a_base_r + a_iss) : disp_rd_addr;

    // ============================================================
    //  二、tag 队列
    // ============================================================
    assign tag_cnt  = tag_wp - tag_rp;
    assign tag_full = (tag_cnt == TAG_FULLVAL);

    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            tag_wp <= {(TAG_AW+1){1'b0}};
            tag_rp <= {(TAG_AW+1){1'b0}};
            for (i = 0; i < TAG_DEPTH; i = i + 1) tag_mem[i] <= 1'b0;
            quiet_cnt <= 16'd0;
            tag_bad   <= 1'b0;
        end
        else begin
            // ---- 脱钩诊断（sticky）------------------------------------
            //  ① 队列【空】却收到一个读返回  ⇒ 少推了一次（pop 多于 push）
            //  ② 队列【满】还要推一次        ⇒ 多推了一次
            //  两条都说明"tag 顺序"已经和"数据回来顺序"对不上了：
            //  显示会少收字（那一行露白线）、音频会收到【图像数据】（= 杂音）。
            if (sdr_rd_en && (tag_cnt == {(TAG_AW+1){1'b0}})) tag_bad <= 1'b1;
            if (rd_en && tag_full)                            tag_bad <= 1'b1;

            // ---- 静默重同步 --------------------------------------------
            //  连续 RSYNC_QUIET 拍没有请求、也没有返回 ⇒ 在途的读一定都回来了
            //  ⇒ 队列【本当为空】。若这时它还不是空，那它一定脱钩了：
            //    直接把 wp 拉回 rp（等于"清空"），一次治好，且以后自己会再治。
            //  ★ 显示每行之间本来就有 ~17µs（≈2100 拍）的空档，所以每行都会自动重同步一次。
            // ★★★ 第 10 条：只有"核自己都说不忙"的拍才算静默。
            //   ★ 为什么必须加 sdr_busy / sdr_init_ref_vld：上板出现"切图时又冒白条纹"。
            //     旧写法只数"没有请求也没有返回"，于是在"核正忙、读被压着没回来"的时候
            //     也误判成"队列本当为空"，把显示的【在途】表项清掉 ⇒ 那些字回来时被错分给
            //     音频 ⇒ 显示那一行取不满 ⇒ 看门狗放弃那一行 ⇒ **一条白条纹**。
            //   ⇒ 只在"核确实空闲"的拍上累计；空闲 256 拍后还没回来的读，才认定它丢了。
            if (rd_en || sdr_rd_en || sdr_busy || sdr_init_ref_vld) begin
                quiet_cnt <= 16'd0;
            end
            else if (quiet_cnt != 16'hFFFF) begin
                quiet_cnt <= quiet_cnt + 16'd1;
            end

            if (!rd_en && !sdr_rd_en && !sdr_busy && !sdr_init_ref_vld
                && (quiet_cnt >= RSYNC_QUIET[15:0])
                && (tag_cnt != {(TAG_AW+1){1'b0}})) begin
                tag_wp  <= tag_rp;          // ← 清空（这才是"应当是空"的那个状态）
                tag_bad <= 1'b1;            // 曾经脱钩，这就是证据
            end
            else if (rd_en) begin
                tag_mem[tag_wp[TAG_AW-1:0]] <= aud_win;   // 1 = 音频
                tag_wp <= tag_wp + 1'b1;
            end
            if (sdr_rd_en) tag_rp <= tag_rp + 1'b1;
        end
    end

    assign tag_now = tag_mem[tag_rp[TAG_AW-1:0]];         // 组合读，必须同拍
    assign o_tag_bad = tag_bad;
    assign aud_dbg_cnt = aud_cnt_r;                       // ★ 第 8 条：音频数据自检
    assign aud_dbg_sum = aud_sum_r;


    // ============================================================
    //  三、分流
    // ============================================================
    assign disp_rd_data = sdr_rd_dout;
    assign disp_rd_vld  = sdr_rd_en & ~tag_now;          // ★ 显示永远吃不到音频的数据
    assign aud_rd_vld_m = sdr_rd_en &  tag_now;

    // ============================================================
    //  四、音频读调度（显存域）
    // ============================================================
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            a_base_s1 <= 21'd0; a_base_s2 <= 21'd0;
            a_words_s1<= 21'd0; a_words_s2<= 21'd0;
            ap1 <= 1'b0; ap2 <= 1'b0; ap3 <= 1'b0;
        end
        else begin
            a_base_s1  <= aud_base;   a_base_s2  <= a_base_s1;
            a_words_s1 <= aud_words;  a_words_s2 <= a_words_s1;
            ap1 <= aud_play_tgl; ap2 <= ap1; ap3 <= ap2;
        end
    end
    assign a_play_pulse = ap2 ^ ap3;        // toggle 变化 = 一条新命令

    assign argray_bin = gray2bin(argray_sync);

    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            awp      <= {(AFIFO_AW+1){1'b0}};
            a_base_r <= 21'd0; a_words_r <= 21'd0; a_iss <= 21'd0;
            a_word_idx <= 21'd0; a_try <= 3'd0;
            a_prev <= 32'd0; a_prev_vld <= 1'b0; a_need_rd <= 1'b0;
            a_run    <= 1'b0;  aud_req <= 1'b0;
            aud_cnt_r <= 16'd0; aud_sum_r <= 32'd0;
        end
        else begin
    // ---- 收命令 ----
            if (a_play_pulse) begin
                a_base_r  <= a_base_s2;
                a_words_r <= a_words_s2;
                a_iss     <= 21'd0;
                a_run     <= 1'b1;
            end

            // ============================================================
            //  ★★★ 2026-10-06 回退：读回来的字【直接进 FIFO】（回到能喂饱的节奏）
            //   第 10 条那版"同地址读两次、两次一致才收"上板后音频几乎没声 ——
            //   因为它把读请求变成了"一次只发一个、等回来再发下一个"，
            //   供字速度掉到 FIFO 需求以下 ⇒ 喂不饱 ⇒ sfx_player 的淡入斜坡起不来
            //   ⇒ 整段被压得极轻（只有原本最响的地方透出一点"电流声"）。
            //   ⇒ 先把节奏恢复成"连发"（原来能听的那版），杂音问题另案处理
            //     （自检照旧在跑，改算法时有数据可依）。
            // ============================================================
            if (aud_rd_vld_m && !a_play_pulse) begin   // ★ 命令那一拍不收字（避免和清零打架）
                afifo[awp[AFIFO_AW-1:0]] <= sdr_rd_dout;
                awp        <= awp + 1'b1;
                aud_cnt_r  <= aud_cnt_r + 16'd1;
                aud_sum_r  <= aud_sum_r + sdr_rd_dout;
            end

            // ---- 自检累加器清零（跟着 play 命令走）----
            if (a_play_pulse) begin
                aud_cnt_r <= 16'd0;
                aud_sum_r <= 32'd0;
            end

            // ★ 授权了就把"已发出"计数加上（地址要立刻往前走，否则连续授权会重复读同一个地址）
            if (aud_win) a_iss <= a_iss + 21'd1;

            // ---- FIFO 低于水位、且还没发够 → 要读口（连发，喂饱 FIFO）----
            //  ★ 用 a_iss_eff（含本拍这一次）判，否则最后一拍会多发一个
            if (a_run && (a_iss_eff < a_words_r) && ((awp - argray_bin) < LOW_MARK))
                aud_req <= 1'b1;
            else
                aud_req <= 1'b0;

            // ---- 全部发完了 → 收工 ----
            if (a_run && (a_iss >= a_words_r)) a_run <= 1'b0;
        end
    end

    assign aud_busy = a_run;

    // ============================================================
    //  五、音频域：从 FIFO 取
    // ============================================================
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) begin
            arp      <= {(AFIFO_AW+1){1'b0}};
            wgray_s1 <= {(AFIFO_AW+1){1'b0}};
            wgray_s2 <= {(AFIFO_AW+1){1'b0}};
        end
        else begin
            wgray_s1 <= bin2gray(awp);
            wgray_s2 <= wgray_s1;
            if (aud_next) arp <= arp + 1'b1;
        end
    end

    assign wrp_bin   = gray2bin(wgray_s2);
    assign afifo_cnt = wrp_bin - arp;

    assign aud_dout = afifo[arp[AFIFO_AW-1:0]];
    assign aud_vld  = (afifo_cnt != 0);

    // 读指针 gray 同步回显存域
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) argray_sync <= {(AFIFO_AW+1){1'b0}};
        else            argray_sync <= bin2gray(arp);
    end

endmodule
