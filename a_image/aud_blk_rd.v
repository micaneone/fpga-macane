// ============================================================
//  aud_blk_rd —— 音频读的【块级客户端】（B 侧集成模块，2026-10-06）
//
//  它替代 A 的 `sdr_rd_arb`：**读口不再和显示逐拍抢**，而是像显示一样
//  用【一整块】去申请读口（`blk_rd_arb` 的音频口），块与块之间不交叠。
//
//  为什么要换（这是这一周的结论，证据见 规划\B轨待改清单.md §18）：
//    · 旧做法是"音频趁显示没发读的那一拍插一个地址进去"，回来的数据靠
//      一条 **tag 队列** 分清谁是谁。两个问题：
//        ① 这颗 SDRAM 核受不了两个地址流被逐拍交织 —— 偶尔读回错值：
//           对显示 = 一个看不见的错像素（白条闪），对音频 = 一声"沙"；
//           而且**杂音随显示的读流量走**（1536 宽的图最响，正好 2.4 倍）。
//        ② tag 队列一旦和读返回脱钩就永久回不来（虽然实测没脱钩过）。
//    · 新做法：**谁拿到读口谁整块读完**，回来的数据只可能属于当前这一块
//      ⇒ 既不需要 tag 队列，也不会交织。
//
//  数据流：
//    控制域 play 命令（toggle）→ 本模块（显存域）排块：
//      一次要 BLK_WORDS 个字（默认 64），凑不满就少要点（最后一块）
//      → blk_rd_arb 音频口 → 官方读通路 → SDRAM
//    每收到一个字（a_dv 脉冲 + a_data）就写进下面这个【跨时钟 FIFO】，
//    音频域按 aud_next 消费 —— 接口和 A 原来那版一模一样，
//    `sfx_player` / `sfx_ctrl` 一个字都不用改。
//
//  ★ 三个安全设计（都是"绝不让显示被音频拖住"）：
//    ① **有空间才要块**：FIFO 必须装得下一整块才发申请
//       （否则申请方收不动 ⇒ 块永远收不满 ⇒ 仲裁器卡在服务态 ⇒ 显示被堵死）。
//    ② `a_next` 在收集期间**恒为 1**：仲裁器数够 blk_len 自己会停，
//       不靠申请方的"还要不要"来收尾，少一个卡死的入口。
//    ③ 看门狗：一块收超过 SERV_MAX 拍就放弃、把状态机放回 IDLE
//       （仲裁器那边另有一个同样的看门狗，两头都兜底）。
//
//  ★ 时钟：FIFO 是**手写的双时钟 FIFO**（格雷码指针），和 A 原来那版逐行
//    一致 —— 它已经上板跑通过（能听出音乐），不改成厂商 IP 是为了不引入
//    新变量（SHOW_AHEAD/OUTREG 那些性子会牵动 sfx_player 的取数协议）。
//
//  ★★★ 2026-10-15【存储搬 BRAM，协议不动】（本次改动，见第三节注释）
//    · afifo 256x32 之前被推成分布式 RAM（音频域 LUT-As-Dram = 480），
//      器件 BRAM 只用了 44/64 ⇒ 把它搬进 BRAM（BRAM 必须寄存读）。
//    · 只在【本文件内】加一套 show-ahead 输出寄存器（dout_r/dout_v），
//      对外仍是"vld=1 ⇒ dout 就是下一个字，当拍 next 取走"，sfx_player 不改。
//    · 厂商 FIFO (lib/sdram/afifo_16_32_256.v 里定义的 wfifo_32_32_512)
//      **不能用**：它只有一个 `rst`，会同时清掉读写两侧指针
//      （写指针被清 = 和"开播清空 FIFO"（arp <= wrp_bin）以及显存域的
//       afifo_used_m 记账冲突）。已确认 ⇒ 坚持手写。
//
//  ★★★ 声明全部前置（这个工程踩过五次"先用后声明"）
// ============================================================
`timescale 1ns / 1ps

module aud_blk_rd #(
    parameter integer BLK_WORDS = 64,       // 一次块请求多少字
    // ★★★ 2026-10-09 晚【A/B 实验】：7 → 回到 **9**（512 字）。
    //   上午为了省面积把它缩到 128 字（省 ~1,200 LUT），可上板之后**音频只有沙沙声**。
    //   现在设计 LUT 只有 68%（字幕 RAM 进了 BRAM，面积反而降了），所以先把它
    //   **恢复成 512 字**做对照：如果音乐回来 ⇒ 就是 FIFO 太小（那以后保持 9）；
    //   如果还是沙沙声 ⇒ 与 FIFO 无关，看 `o_underrun`（饿死探针）。
    parameter integer AFIFO_AW  = 9,        // 跨域 FIFO 深度 = 2^9 = 512 字
    parameter integer SERV_MAX  = 20000     // 看门狗：一块最多等多少拍（@125MHz ≈ 160 µs）
)(
    // ---------------- 显存域 125 MHz ----------------
    input  wire        clk_mem,
    input  wire        rst_mem_n,
    input  wire        rd_ok,           // 1 = 现在允许读（装载期间由顶层压 0）

    // ---- 播放命令（控制域 sfx_ctrl 的 toggle + 基址/字数）----
    input  wire        aud_play_tgl,
    input  wire [20:0] aud_base,
    input  wire [20:0] aud_words,

    // ---- 块口 → blk_rd_arb 的音频口 ----
    output wire        a_req,
    output reg  [20:0] a_base,
    output reg  [20:0] a_len,
    input  wire        a_gnt,
    output wire        a_next,
    input  wire [31:0] a_data,
    input  wire        a_dv,

    // ---------------- 音频域（12.288 MHz）----------------
    input  wire        clk_aud,
    input  wire        rst_aud_n,
    output wire [31:0] aud_dout,
    output wire        aud_vld,
    input  wire        aud_next,
    output wire        aud_busy,

    // ★★ 2026-10-09【饿死探针】：消费端要一个字、而 FIFO 当时是空的 ⇒ sticky 置起。
    //   上板一句话就能判"沙沙声是不是因为 SDRAM 读没跟上（FIFO 被饿穿）"。
    output reg         o_underrun,

    // ---------------- 诊断 ----------------
    output reg  [15:0] dbg_cnt,         // 本次播放从 SDRAM 收了多少个字（饱和）
    output reg  [31:0] dbg_sum,         // 这些字的 32 位累加和
    output reg  [15:0] dbg_blk_cnt,     // 一共服务完多少块
    output reg         o_stall          // 1 = 看门狗掐断过（sticky）
);

    // ============================================================
    //  ★ 声明全部前置
    // ============================================================
    localparam integer AFIFO_DEPTH = (1 << AFIFO_AW);
    // 发块之前 FIFO 里最多允许多少字（保证整块装得下）
    localparam [AFIFO_AW:0] ROOM_LIMIT = (1 << AFIFO_AW) - BLK_WORDS;

    localparam [1:0] S_IDLE = 2'd0,
                     S_REQ  = 2'd1,
                     S_COL  = 2'd2;

    reg  [1:0]  st;
    reg         run;                        // 一次播放还没发够请求
    reg         a_req_r;                    // 内部请求（再过 rd_ok 出门）
    reg  [20:0] a_base_r, a_words_r;        // 本次播放的基址/字数（同步过来的）
    reg  [20:0] issued;                     // 已经申请出去多少个字
    reg  [20:0] got;                        // 当前这一块已经收到多少个字
    reg  [20:0] cur_len;                    // 当前这一块要多少字
    reg  [15:0] wait_cnt;                   // 看门狗

    // ---- 跨域 FIFO（手写，格雷码指针）----
    reg  [31:0] afifo [0:AFIFO_DEPTH-1];
    reg  [AFIFO_AW:0] awp;                  // 写指针（显存域）
    reg  [AFIFO_AW:0] arp;                  // 读指针（音频域）
    reg  [AFIFO_AW:0] argray_sync;          // 读指针同步回显存域
    reg  [AFIFO_AW:0] wgray_s1, wgray_s2;   // 写指针同步到音频域

    // ---- ★★★ 2026-10-15【把这块 FIFO 从 LUTRAM 搬进 BRAM】----
    //   原来 afifo 被推成【分布式 RAM】（异步读）：`aud_dout = afifo[arp]` 是组合输出，
    //   面积报告里音频域 "LUT As Dram = 480"。BRAM 只有【寄存读】，所以这里补一套
    //   标准 show-ahead：dout_r 里始终握着"下一个要吐的字"，dout_v 是它的有效位。
    //   对外语义不变：`aud_vld=1` ⇒ `aud_dout` 就是下一个字，消费端当拍取走 + 当拍 aud_next。
    reg  [31:0] dout_r;                     // BRAM 寄存读输出（show-ahead）
    reg         dout_v;                     // 1 = dout_r 里的字有效、且还没被取走
    // ★ 读地址必须【组合选择】（上次搬 BRAM "上板没声音" 就是栽在这一条）：
    //   要预读下一个字时指向 arp+1，否则停在 arp（继续握着当前这个字）。
    //   ✗ 若写成 `if (预读) raddr <= arp;` 再 `dout_r <= afifo[raddr];`
    //     非阻塞右值用的是【旧】raddr ⇒ 数据比有效位晚 2 拍 ⇒ 重复吐字/错位。
    wire [AFIFO_AW-1:0] aud_rd_addr =
        (dout_v && aud_next) ? (arp[AFIFO_AW-1:0] + 1'b1) : arp[AFIFO_AW-1:0];

    // ---- ★★★ 2026-10-14 深夜【开播清空 FIFO】----
    reg               flush_tgl;            // 显存域：播放命令时翻转（跨域用）
    reg               fl1, fl2, fl3;        // 音频域：同步 + 检边沿
    wire              flush_pulse = fl2 ^ fl3;   // 翻转 = 一条"清空"命令（声明在用它的 always 之前）

    // ---- 命令同步（显存域）----
    reg         ap1, ap2, ap3;
    reg  [20:0] a_base_s1, a_base_s2;
    reg  [20:0] a_words_s1, a_words_s2;
    integer     i;

    wire        a_play_pulse = ap2 ^ ap3;   // toggle 变化 = 一条新命令
    wire [AFIFO_AW:0] argray_bin = gray2bin(argray_sync);
    wire [AFIFO_AW:0] wrp_bin    = gray2bin(wgray_s2);
    wire [AFIFO_AW:0] afifo_used_m = awp - argray_bin;    // 显存域口径（偏保守）
    wire [AFIFO_AW:0] afifo_cnt    = wrp_bin - arp;       // 音频域口径

    // 下一块要多少字：够 BLK_WORDS 就给整块，最后一块少给点
    wire [20:0] words_left = a_words_r - issued;
    wire [20:0] next_len   = (words_left > BLK_WORDS[20:0]) ? BLK_WORDS[20:0] : words_left;
    // 有空间才要（★ 保证整块装得下，见文件头安全设计①）
    wire        room_now   = (afifo_used_m <= ROOM_LIMIT);

    // ---- 工具函数（和 A 那版一致）----
    function [AFIFO_AW:0] bin2gray;
        input [AFIFO_AW:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
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
    //  一、命令 / 基址 / 字数同步到显存域
    // ============================================================
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            a_base_s1 <= 21'd0;  a_base_s2 <= 21'd0;
            a_words_s1<= 21'd0;  a_words_s2<= 21'd0;
            ap1 <= 1'b0; ap2 <= 1'b0; ap3 <= 1'b0;
        end
        else begin
            a_base_s1  <= aud_base;   a_base_s2  <= a_base_s1;
            a_words_s1 <= aud_words;  a_words_s2 <= a_words_s1;
            ap1 <= aud_play_tgl; ap2 <= ap1; ap3 <= ap2;
        end
    end
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) argray_sync <= {(AFIFO_AW+1){1'b0}};
        else            argray_sync <= bin2gray(arp);
    end

    // ============================================================
    //  二、显存域：排块 + 收字进 FIFO
    // ============================================================
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            st          <= S_IDLE;
            run         <= 1'b0;
            a_req_r     <= 1'b0;
            a_base      <= 21'd0;
            a_len       <= 21'd0;
            a_base_r    <= 21'd0;
            a_words_r   <= 21'd0;
            issued      <= 21'd0;
            got         <= 21'd0;
            cur_len     <= 21'd0;
            wait_cnt    <= 16'd0;
            awp         <= {(AFIFO_AW+1){1'b0}};
            dbg_cnt     <= 16'd0;
            dbg_sum     <= 32'd0;
            dbg_blk_cnt <= 16'd0;
            o_stall     <= 1'b0;
        end
        else begin
            // ---- ① 收一条播放命令：重排这一次的全部块 ----
            if (a_play_pulse) begin
                a_base_r  <= a_base_s2;
                a_words_r <= a_words_s2;
                issued    <= 21'd0;
                got       <= 21'd0;
                a_req_r   <= 1'b0;
                st        <= S_IDLE;
                run       <= 1'b1;
                dbg_cnt   <= 16'd0;
                dbg_sum   <= 32'd0;
            end

            // ---- ② 收数据：一个 a_dv 一个字 ----
            //   ★ 命令那一拍不收（避免和上面的清零打架）
            // ★★★ 2026-10-11：这里原来加过"多要 2 个字、丢掉头 2 个"的补偿（顶"块开头
            //   多 2 个陈旧字"）。那条病根已经在**读通路本身**修好了 —— `blk_rd_arb`
            //   改成认官方 FIFO 的 `valid`（丢空的 pop 不再被误当成交付），
            //   见《B轨待改清单》§28 ⇒ 补偿撤销，回到原来的写法。
            if (a_dv && !a_play_pulse) begin
                afifo[awp[AFIFO_AW-1:0]] <= a_data;
                awp                      <= awp + 1'b1;
                got                      <= got + 21'd1;
                wait_cnt                 <= 16'd0;
                if (dbg_cnt != 16'hFFFF) dbg_cnt <= dbg_cnt + 16'd1;
                dbg_sum                  <= dbg_sum + a_data;
            end
            else if (wait_cnt != 16'hFFFF) wait_cnt <= wait_cnt + 16'd1;

            // ---- ③ 块调度状态机 ----
            case (st)
            // ---- 等"还要不要块" ----
            S_IDLE: begin
                a_req_r <= 1'b0;
                if (run && (issued < a_words_r)) begin
                    if (room_now) begin
                        a_base  <= a_base_r + issued;
                        a_len   <= next_len;
                        cur_len <= next_len;
                        a_req_r <= 1'b1;
                        wait_cnt<= 16'd0;
                        st      <= S_REQ;
                    end
                end
                else if (run) begin
                    run <= 1'b0;            // 全部申请完了
                end
            end
            // ---- 等仲裁器受理 ----
            S_REQ: begin
                if (a_gnt) begin
                    a_req_r  <= 1'b0;
                    got      <= 21'd0;
                    wait_cnt <= 16'd0;
                    if (dbg_blk_cnt != 16'hFFFF) dbg_blk_cnt <= dbg_blk_cnt + 16'd1;
                    st       <= S_COL;
                end
            end
            // ---- 收这一块（a_next 恒 1，见文件头安全设计②）----
            S_COL: begin
                if (a_dv && !a_play_pulse && ((got + 21'd1) >= cur_len)) begin
                    issued <= issued + cur_len;
                    st     <= S_IDLE;
                end
                else if (wait_cnt >= SERV_MAX[15:0]) begin
                    // ★ 看门狗：这一块收不齐了。已经收的先认账，剩下的跳过；
                    //   仲裁器那边的看门狗会把读口放回去（绝不会堵死显示）。
                    o_stall <= 1'b1;
                    issued  <= issued + got;
                    a_req_r <= 1'b0;
                    st      <= S_IDLE;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // ★ 请求电平：装载期间由顶层 `rd_ok` 压住（仲裁器只在 S_IDLE 看这一拍，
    //   所以"压住又放开"不会丢请求）
    assign a_req  = a_req_r & rd_ok;
    assign a_next = (st == S_COL);
    assign aud_busy = run;

    // ============================================================
    //  三、音频域：从 FIFO 取
    //     ★★★ 2026-10-15【存储换成 BRAM ⇒ 这一段改成寄存读 + show-ahead】
    //     协议一个字没变：`aud_vld=1` ⇒ `aud_dout` 就是下一个字，
    //     消费端（sfx_player）当拍取走、当拍拉 `aud_next`。
    //     唯一区别：FIFO 从"空"变"有"时，第一个字晚 1 拍 clk_aud（寄存读的固有代价，
    //     81 ns；消费端 buf0/buf1 顶得住，字序/字数/校验和都不受影响）。
    // ============================================================
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) begin
            arp      <= {(AFIFO_AW+1){1'b0}};
            wgray_s1 <= {(AFIFO_AW+1){1'b0}};
            wgray_s2 <= {(AFIFO_AW+1){1'b0}};
            dout_v   <= 1'b0;
        end
        else begin
            wgray_s1 <= bin2gray(awp);
            wgray_s2 <= wgray_s1;
            if (flush_pulse) begin
                arp    <= wrp_bin;         // ★ 清空：读指针追上写指针 = 丢弃上一轮残留
                dout_v <= 1'b0;            // ★ 输出寄存器里那个字也一并作废
            end
            else if (dout_v) begin
                // ---- 手里有一个字：消费端取走时，预读下一个 ----
                //   ★ 有效位与数据严格对齐：预读在【这一拍】发起（数据下一拍进 dout_r），
                //     所以 dout_v 也在这一拍置位 —— 下一拍 dout_r / dout_v 同时到位。
                //     ✗ 不能把"刚发出的预读"或进 aud_vld（那样会早一拍报有效）。
                if (aud_next) begin
                    arp    <= arp + 1'b1;
                    dout_v <= (afifo_cnt > {{AFIFO_AW{1'b0}}, 1'b1});   // 还有第 2 个字吗
                end
            end
            else if (afifo_cnt != {(AFIFO_AW+1){1'b0}}) begin
                // ---- 手里空着、FIFO 里有字：装载头一个字（下一拍 dout_r/dout_v 到位）----
                dout_v <= 1'b1;
            end
        end
    end

    // ★ BRAM 的寄存读：**无条件、无复位、无使能**（有一样 TD 都可能退回 LUTRAM）。
    //   地址由上面 aud_rd_addr 组合选出 —— 这是上一次搬 BRAM 失败的那个坑。
    always @(posedge clk_aud) begin
        dout_r <= afifo[aud_rd_addr];
    end

    // ★★★ 2026-10-14 深夜【开播清空 FIFO —— 治"播放开头那一声噪点"】
    //   机理：每次播放**结束时 FIFO 里还留着若干字**（块长 = 深度，收尾时总有余量），
    //   下一次播放会**先放这些陈旧字** ⇒ 开头一声噪；剩几个取决于上次结束时的仲裁时序
    //   ⇒ 概率性；时序裕量随布局浮动 ⇒ 次数随版本变。
    //   修法：播放命令跨到音频域后，把读指针追到写指针（arp <= wrp_bin）⇒ 视为空。
    //   ★ 新请求的块至少几百 ns 才回来，清空吃不掉新数据。
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n)        flush_tgl <= 1'b0;
        else if (a_play_pulse) flush_tgl <= ~flush_tgl;
    end
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) begin fl1 <= 1'b0; fl2 <= 1'b0; fl3 <= 1'b0; end
        else            begin fl1 <= flush_tgl; fl2 <= fl1; fl3 <= fl2; end
    end

    // ---- 对外输出：全部来自输出寄存器（和 BRAM 那套 show-ahead 配套）----
    //   ★ 占用口径一个字没改：`arp` 仍然指向"还没被取走的那个字"，所以
    //     afifo_used_m = awp - argray_bin 天然把"已预读、还在 dout_r 里没被取走"
    //     的字算在内（宁多不少）。★ 千万别再加 +1/+2 的保守量：
    //     ROOM_LIMIT = 0 ⇒ room_now = (used_m <= 0)，一加就永远申请不出块 = 死锁。
    assign aud_dout = dout_r;
    assign aud_vld  = dout_v;

    // ★★ 2026-10-09【饿死探针】：消费端 `aud_next` 要字、而这一拍 FIFO 里没有 ⇒ sticky。
    //   注意：只在"这一拍确实在消费"时才算（`aud_next` 本来就是消费脉冲）。
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n)         o_underrun <= 1'b0;
        else if (aud_next && !aud_vld) o_underrun <= 1'b1;
    end

    // ---- 初始化一下 FIFO 内容（只给仿真用；上电别读 X）----
    //   ★★★ 2026-10-15【搬 BRAM 的硬前提】：数组上**不能有整块 initial 赋值**，
    //   否则 TD 不肯把它推断成 BRAM（会退回 LUTRAM）。TD 工程里没有全局宏
    //   （见 check_compile.ps1 顶部说明）⇒ 综合时这块**根本不存在**。
    `ifdef AFIFO_SIM_INIT
    initial begin
        for (i = 0; i < AFIFO_DEPTH; i = i + 1) afifo[i] = 32'd0;
    end
    `endif

endmodule
