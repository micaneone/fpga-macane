// ============================================================
//  ★★ 2026-10-02 集成临时改动（见 交接_M1显示调试.md §12 第 1 条）
//     M1 调试工程要把探针打开。TD 里【没有】全局 Verilog 宏 ——
//     磁盘上所有 .al 的 <Project_Settings> 都是空的，也没有别处存宏，
//     所以"在 TD 编译选项里加宏"这条路走不通（实测报
//     "模块 win_compositor 没有端口 o_dbg_wbase"）。
//     改成本地打开：效果和 ModelSim 的 +define+B_DEBUG_PROBE 完全一样。
//     交付仓库里那三份【没有这 5 行】，所以作品版照样是干净的。
//     ★ sync_from_repo.ps1 会把这个头冲掉 → 刷完要重新加。
// ============================================================
`ifndef B_DEBUG_PROBE
`define B_DEBUG_PROBE
`endif
// ============================================================
//  模块名 : line_buf
//  作用   : 【行缓冲 + 预取引擎】—— 把"从 SDRAM 搬一行"这件事做成一个能反复用的模块
//  层次   : 显示链第 ③ 级"取样"的核心（合成器 / 缩放器都要用）
//  时钟域 : 两个 —— 显存域 125 MHz 负责读且写进缓冲；
//                    像素域 40 MHz 负责按像素序号读出来
//  依据   : B轨说明书 §2（像素流水七级）、§5.2（带宽标定）、§4.9（跨时钟域）
// ------------------------------------------------------------
//  它干什么（一句话）：屏幕要显示第 N 行时，它正在悄悄把第 N+1 行搬进来。
//
//  为什么按"行"搬，而不是一个像素一个像素地读：
//    SDRAM 控制器跑 125 MHz，HDMI 像素是 40 MHz，两者没法一个像素一个像素握手
//    （一次往返就把时间花光了）。所以按【行】搬：
//      一行 400 个字 @125MHz ≈ 3.2~6.4 us，而一行显示时间是 26.4 us
//      —— 搬运只占一行时间的 1/8 到 1/4，非常宽裕。
//
//  ★★ 一个 32 位字 = 【两个】RGB565 像素（契约第二节）：
//      word[31:16] = 靠前（左边）那个像素，word[15:0] = 后一个
//      所以"读 1 个字"就够显示 2 个像素，容量省一半。
//      缓冲里存的是【整个字】，输出时按 rd_index 的最低位选高低半字 ——
//      一次读、一个写口，不用为"两个像素写两次"发愁。
//
//  双缓冲怎么切（和 M0 上板验过的 sdr_line_view 同一套手法）：
//    像素域：行首（line_go 那一拍）
//              ① 把"下一行"的参数（行起始字地址 / 读多少字）记下来
//              ② 翻 req_tgl，通知显存域去搬；目标是【另一块】缓冲
//              ③ 把"另一块"的 ready 清掉（它马上要被重写）
//    显存域：看到 req_tgl 变了 -> 按信用流控发读请求 -> 边收边写进那一块
//            -> 收满最后一个字，翻 done_tgl，并用 done_buf 说明填的是哪一块
//    像素域：看到 done_tgl 变了 -> 把那块标成 ready
//
//  ★ 显示用哪一块，是拿【当前屏幕行号的奇偶】算的，不是一个"每行翻一次"的寄存器：
//    寄存器版本在行首那一拍还是旧值，于是每行第一个像素读的是上一行
//    （M0 的 tb 里就是差 1 个像素 —— 格子图上几乎看不出来，但这种"差一拍"
//     正是 B轨说明书 §6.2 重点提醒的那一类，能消掉就消掉）。
//    所以调用方要把当前行的奇偶（一般是 pix_y[0]）接在 line_parity 上。
//
//  ★ 关于"串"（上板踩出来的规矩，见 rtl\b_display\README.md）：
//    连续狂灌几十万个读请求时，控制器照常报"数据有效"但数据是错的；
//    仿真里完全看不出来。所以这里**限制在途请求数**（MAX_OUT 个），
//    发出的和收回的差不超过 MAX_OUT —— 等于天然把请求分成一小串一小串。
//    M0 上板显示正确的那个版本用的就是这套（当时 MAX_OUT=64）。
//    ★ 别把这个限制去掉。
//
//  ★ 万一请求在正忙时到达（理论上不会：搬一行 6.4us、行周期 26.4us），
//    这一次请求会被丢掉 —— 后果是那一行显示底色，下一行自动补上，不会卡死。
//
//  ★★ 2026-09-26 补【看门狗】（上板踩出来的）：
//    上面那句"不会卡死"只在"请求被丢在开头"时成立。如果一次搬运已经开始了、
//    却在半路被掐断（比如上层为了给写口让路，把 disp_rd_en 拉了低），
//    那 frcv 永远追不上 fwords → filling 永久停在 1 → 之后所有请求都被丢掉
//    → 屏上只剩底色、再也出不来图（实测就是这现象）。
//    对策：一次搬运里【超过 STALL_MAX 拍一个字都没回来】就判定这趟废了，
//    主动放掉 filling（不置 done）——那一行显示底色，下一行重新来过，自愈。
//    ★ 这个看门狗在 M2 加读写仲裁之后会更重要：仲裁一定会掐断搬运。
//
//  ★ 时序约定：pix_out / pix_ready 是【组合读出】，和 rd_index 同一拍。
//    调用方要拿它去送 HDMI 的话，自己在自己那一级寄存（和 de 一起打拍）。
//
//  ★★ 2026-09-27 上板实测后的两处改动（都在这个文件里，改完要上板复测）：
//    ① 【数据先稳、下一拍再翻 toggle】
//       行首原来在同一拍里既摆 req_wbase/req_words/req_buf、又翻 req_tgl。
//       40 MHz 和 125 MHz 是两个 PLL 来的异步时钟，125 侧最早可能在翻 toggle
//       之后 1 个时钟就去采那几个多 bit 信号 —— 那正是数据跳变的瞬间，
//       采到半个旧值半个新值 → 行首地址变成乱数 → 屏上就是"有的行整行横移、
//       位移还各不相同"的横条。现在数据先摆一拍，下一拍才翻 toggle。
//    ② 【去掉"排空"那一段】
//       它当初是为了丢上一趟的响应尾巴加的。但一趟填满之后，
//       在途请求数一定是 0（发出去多少就收回来多少），本来就没有尾巴；
//       而两次搬运之间隔着整整一行（26 us ≈ 3300 个显存时钟），
//       任何迟到的响应也早就走完了。实测"静 16 拍"和"静 240 拍"读数完全一样，
//       证明它没用 —— 去掉，少一个变量。
//    另外加的两个计数器（o_drop_cnt / o_abort_cnt）和那个定点探针都只用于诊断，
//    正式版可以把它们连到常量上，逻辑一行都不用改。
//    ③ 【在途请求上限做成现场可调】（2026-09-27，见下面 mo_sel 那段）
//       已有的硬线索：M0 用"写死图案→读回→逐字比对"验过，F=000000 全对；
//       而 M0 显示正确的那版 line view 用的在途上限是 64，我们现在给 16。
//       上限太小 → 一趟搬运中间会"发满就停一下等回数据" → 请求流有停顿
//       → 控制器"数据"和"数据有效脉冲"两条流线的相对位置就会错开
//       → 我们按脉冲取数就取偏了（实测恒定 +3 个字 = 6 像素）。
//       所以把上限做成 key1 现场可调（8/16/32/64/128），试出取数取准的那个值。
//       ★ 附带的"逐字对齐校验"就是为这件事准备的：地址图里字的值 = 它的地址，
//         所以每个字都能当场判对错，直接报"第 1 个字偏几个 / 本趟几个字不对"。
//
//  ★★★ 2026-09-28 第五轮【根因已定 —— 本文件就是修法】：
//    用"整行扫描"探针把一行 320 个字全读回来之后，读口的两条固定脾气看清了：
//      ① **起始地址必须是 4 个字的整数倍。**
//         不是的话，核内部"4 个字一包"的分组就和我们的读流错开：每 4 个字里
//         顺序被转一位（第 4 个先出来）→ 屏上就是"每隔几列一小条、整体挪
//         4 个像素"（用户看到的"等距偏移"就是这个）。
//         实测：行首本身（238×320，4 的整数倍）直接读 → 顺序全对；
//         行首减 1 个字（cmp_off=1）→ 立刻错乱。
//         ⇒ 前面"补 1 个字 / 补 3 个字"全是在追这个假象。
//      ② **一趟读的第 1 个字会丢。** 对齐起点时，送出来的第 1 个字 =
//         请求的第 4 个字 —— 也就是前 3 个字没吐出来（恒定 +3 个字 = 6 像素）。
//    ⇒ 本文件的统一抵消办法（下面 RD_PRE / RD_EXTRA / RD_LAG 三个常数）：
//         请求地址 = 上层给的行首 − 4（还是 4 的整数倍 ✓）
//         多读 1 个字（一共 req_words + 1 个）
//         收到的第 1 个字丢掉；第 k 个（k ≥ 1）写进缓冲的第 k−1 个位置
//       结果：缓冲里正好是这一行 req_words 个字、顺序正确、一个像素都不差。
//       ★ 逐字校验的期望值也改成 (行首 + 3 + k)：校验 = 0 就说明
//         "起点 4 字对齐 + 数据晚 3 个字"这条规律仍然成立（改代码/重新布局
//         会立刻显形，不会再被当成"随机错位"）。
// ============================================================
`timescale 1ns / 1ps

module line_buf #(
    parameter integer LINE_MAX = 1024,      // 一行最多多少像素（必须偶数）
    parameter integer MAX_OUT  = 16,        // 在途读请求上限 = "一小串"的长度
    parameter integer STALL_MAX = 8192      // 看门狗：多少拍没收到数据就放弃这一趟
                                            //   （8192 拍 @125MHz ≈ 65us，比一行还长）
)(
    // ---------------- 像素域 40 MHz ----------------
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        line_parity,     // 当前屏幕行的奇偶（接 pix_y[0]）
    input  wire        line_go,         // 一拍脉冲（行首）：开始搬"下一行"
    input  wire [20:0] line_wbase,      // 下一行的起始【字】地址
    input  wire [11:0] line_words,      // 下一行读多少个字（1 .. LINE_MAX/2）
    input  wire [11:0] rd_index,        // 组合读：像素在行内的序号（0 起，必须 < LINE_MAX）
    output wire [15:0] pix_out,         // 组合读出（RGB565）
    output wire        pix_ready,       // 当前行这一块已经填好了
    output wire        o_filling,       // 显存域正在搬（给仲裁/诊断看）

    // ---------------- ★ 读口仲裁（2026-10-03：转场两路取样才用）----------------
    //  两条行缓冲要共用 sdr_arb 的**同一个读口**时用这一对信号做"整趟独占"：
    //    o_want = 1 : 有一个"搬一行"的请求在**等**读口（还没开始搬）
    //    rd_gnt = 1 : 读口归我 → 请求可以开始搬
    //  ★ 为什么不能"先把请求发出去、不给了就掐掉"：
    //    行缓冲是**信用流控**的 —— 发一个请求就把 fsent 加一，只等着收同样多的字。
    //    中途被掐掉的那个字永远收不回来 → 这趟只能等看门狗放弃（那一行变底色）。
    //    所以仲裁必须做成"先给读口、再开始搬"：没拿到 rd_gnt 时请求**原地等着**，
    //    一个请求都不会丢。单路用户把 rd_gnt 接 1'b1 即可（行为与以前逐位相同）。
    output wire        o_want,
    input  wire        rd_gnt,

    // ★★★ 2026-10-06：原来的 `rd_ok`（逐拍握手）**已删** —— 换成下面的【块级读通路】。
    //    （上板结论：拿 `rd_ok` 当节流旋钮会让整行取不完 ⇒ 白屏，不能再这么用。）
    // ---- ★ 调试探针 / 上板诊断计数（**只在 B_DEBUG_PROBE 定义时才存在**）----
    //  2026-10-01：这些口只为【上板串口报告】服务，默认【不综合、端口都不存在】。
    //    要上板读串口探针（W/S/F、逐行扫描那些）就在工程里加宏 B_DEBUG_PROBE：
    //      · 仿真：run_sim.ps1 / check_compile.ps1 已经替你加好了；
    //      · TD 工程：在 Verilog 编译选项里加 B_DEBUG_PROBE（见 M1_show\README.md）。
    //    这样交付/作品版是干净的，调试版照样能读串口。
`ifdef B_DEBUG_PROBE
    // 探针：★ 只抓【起始地址 = PROBE_WBASE 那一次填充】，不改任何逻辑。
    //    抓的是"我请求的行首地址"和"我实际收到的头两个字"：
    //      请求的 = 0x10400、收到的也是 0x10400 → 读口是准的，错在别处
    //      请求的 = 0x10400、收到的是 0x10401 → SDRAM 读回来的整体晚了一个字
    output reg  [20:0] o_dbg_wbase,     // 那一次填充请求的起始字地址（期望 0x10400）
    output reg  [11:0] o_dbg_fwords,    // 那一次要读多少个字（期望 0x140 = 320）
    output reg  [31:0] o_dbg_rd0,       // 那一次收到的第 1 个字
    output reg  [31:0] o_dbg_rd1,       //                              第 2 个字
    output reg         o_dbg_frozen,    // 1 = 上面几个数已经抓定

    // 上板诊断计数（2026-09-27 加，专门用来找"横条错位"）
    output reg  [15:0] o_drop_cnt,      // 请求在"正在搬"的时候到达 → 被丢掉（那一行显示底色）
    output reg  [15:0] o_abort_cnt,     // 看门狗掐断的次数（一次搬运半路没数据了）
`endif

    // ---------------- 显存域 125 MHz ----------------
    input  wire        clk_mem,
    input  wire        rst_mem_n,
    // ★★★ 2026-10-06 块级读通路（配合 rtl\vendor_rd_path.v + rtl\blk_rd_arb.v）
    //   ① 一行一次块请求：blk_req 举着 → blk_gnt 受理 → 之后"要字"
    //   ② blk_want 拉高表示"还要字"；仲裁器**有字才给**（FIFO 非空），
    //      每交付一个字拉一次 blk_dv，数据就在同一拍的 blk_data 上
    //   ★ RD_PRE / RD_EXTRA / RD_SKIP 的补偿口径**一个字都没改**（见文件头）
    output reg         blk_req,
    output reg  [20:0] blk_base,
    output reg  [20:0] blk_len,
    input  wire        blk_gnt,
    output reg         blk_want,
    input  wire        blk_dv,
    input  wire [31:0] blk_data,

    // ---- 取数"组内相位"现场可调（mo_sel 0..3，用 key1 试）----
    //  ★★ 2026-09-27 实测把读口的节奏定死了（地址图喂进去，第 208 行打印）：
    //        第 0,1,2,3 个字 = 0403 0403 0403 0403   ← 四个【一模一样】
    //        第 4,5,6,7 个字 = 0407 0407 0407 0407   ← 四个【一模一样】
    //     结论：这颗核【每 4 拍才更新一次读数据】，而"数据有效"脉冲却每拍都发；
    //     那一个新数据 = 【那一拍总线上地址】对应的字（不是这一组开头的地址）。
    //     我们把地址每拍推进 1 格，它就每组取到"组尾那个地址" → 恒定 +3，
    //     而且前 3 拍重复旧值 → "每 4 个字里错 3 个"。
    //
    //  对策（按它的节奏来）：
    //    ① en 一直拉高（连续发，不能停 —— 停一下就全是 FFFF）
    //    ② 地址每 4 拍才推进 1 个字（每个字在总线上举 4 拍）→ "组尾地址"就是
    //       我们要的那个字，+3 自然消失
    //    ③ 有效脉冲每 4 个只取 1 个，取哪一拍由本旋钮现场试（0~3）
    input  wire [1:0]  mo_sel

`ifdef B_DEBUG_PROBE
    // ---- 逐字对齐校验（只对【地址图】有意义：地址图里"字的值 = 它的地址"）----
    //      ★ 这一段的逗号写在宏里面：不开宏时上一个端口就是最后一个，不能留逗号
    ,
    output reg  [15:0] o_off_first,     // 上一趟收到的第 1 个字比请求行首偏了几个字
    output reg  [15:0] o_align_bad      // 上一趟里"值 ≠ 期望地址"的字数（0 = 逐字全对）
`endif
);

    // 缓冲深度：一行 LINE_MAX 个像素 = LINE_MAX/2 个字
    localparam integer W_DEPTH = LINE_MAX / 2;

    // 小工具：算"索引 W_DEPTH 个位置要几位"
    function integer clog2;
        input integer n;
        integer i;
        begin
            clog2 = 0;
            for (i = 1; i < n; i = i * 2) clog2 = clog2 + 1;
        end
    endfunction
    localparam integer W_ADDR_W = clog2(W_DEPTH);

    // ============================================================
    //  两块行缓冲。写口在显存域、读口在像素域 —— 双口 RAM 天生就是跨域用的。
    // ============================================================
    reg [31:0] lb0 [0:W_DEPTH-1];
    reg [31:0] lb1 [0:W_DEPTH-1];

    // ============================================================
    //  跨域的一对握手
    // ============================================================
    reg        req_tgl;          // 像素域 -> 显存域：翻一次 = 搬一行的请求
    reg [20:0] req_wbase;        // 搬哪一行（翻 toggle 之前就稳住）
    reg [11:0] req_words;        // 读多少个字
    reg        req_buf;          // 搬进哪一块

    reg        done_tgl_m;       // 显存域 -> 像素域：翻一次 = 一次搬运完成
    reg        done_buf_m;       // 完成的是哪一块（翻 toggle 之前就稳住）

    // ============================================================
    //  像素域
    // ============================================================
    reg  ready0, ready1;
    reg  ds1, ds2, ds3;
    reg  pend_tgl;                      // ★ 见下面②：数据先摆好，下一拍再翻 toggle
    wire done_edge = ds2 ^ ds3;

    // ★★ 2026-09-27：读口从【组合读出】改成【同步读出】—— 这一改有两个硬理由：
    //    [1] 组合读出，综合器做不了 BRAM，只能拿 LUT 拼"分布式 RAM"：
    //        两张 512x32 的表 = 两千多个 LUT 白扔，而且白扔的这些 LUT
    //        在 TD 里生成了一堆 ramread0_syn_xxx 节点；
    //    [2] TD 在给那些节点修 hold 时当场崩了（phy_1 的 coredump，
    //        2026-09-27 两次复现，日志点名的就是 frcv -> ramread0_syn_xxx）。
    //    同步读出之后综合器用真 BRAM，这两个问题一起消掉。
    //
    //  ★ 代价是数据晚一拍，所以：
    //      · 地址在 t 拍给出（rd_index 由【未延迟】的 pix_x 算，没变）
    //      · 数据在 t+1 拍出来（这里是 rd0_q/rd1_q + par_q + lsb_q）
    //      · 调用方的 de_out/vs_out 正好也是 pix_de/vs 延迟一拍
    //    两边对的都是【同一个像素 x(t)】。
    //    ★ 所以 win_compositor 那边数据那一路【不能再寄存第二次】，
    //      否则比 de 晚一拍 = 整幅图左移一个像素（这类 bug 见 B轨说明书 §6.2）。
    //      ★ 改完必须跑 sim\tb_disp_map.v：它逐像素比对 + 8 个行探针，
    //        差一个像素就会 red（这次改动的安全网就是它）。
    wire [W_ADDR_W-1:0] rd_word = rd_index[W_ADDR_W:1];
    reg  [31:0] rd0_q, rd1_q;        // 两块各自的读出寄存器（给 BRAM 用）
    reg         par_q, lsb_q;        // 与数据同拍：当时显示哪一块 / 取高还是低半字

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            rd0_q <= 32'd0;
            rd1_q <= 32'd0;
            par_q <= 1'b0;
            lsb_q <= 1'b0;
        end
        else begin
            rd0_q <= lb0[rd_word];
            rd1_q <= lb1[rd_word];
            par_q <= line_parity;
            lsb_q <= rd_index[0];
        end
    end

    wire [31:0] cur_word = par_q ? rd1_q : rd0_q;
    assign pix_out   = lsb_q ? cur_word[15:0] : cur_word[31:16];
    // ★ pix_ready 用【当前】的 line_parity（不是 par_q）：它是给
    //   "这一拍的 hit" 配套用的，调用方会把它和数据一起打拍，才能对上。
    assign pix_ready = line_parity ? ready1 : ready0;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            ready0    <= 1'b0;
            ready1    <= 1'b0;
            req_tgl   <= 1'b0;
            req_wbase <= 21'd0;
            req_words <= 12'd0;
            req_buf   <= 1'b0;
            pend_tgl  <= 1'b0;
            ds1       <= 1'b0;
            ds2       <= 1'b0;
            ds3       <= 1'b0;
        end
        else begin
            // ---- ① 先收"这一块填好了"的通知 ----
            ds1 <= done_tgl_m;
            ds2 <= ds1;
            ds3 <= ds2;
            if (done_edge) begin
                if (done_buf_m) ready1 <= 1'b1;
                else            ready0 <= 1'b1;
            end

            // ---- ② 行首：请搬下一行，并清掉"将要被重写的那一块" ----
            //  ★★ 2026-09-27 修（上板实测"每行错位量不一样"之后）：
            //     原来"摆数据"和"翻 toggle"是【同一拍】做的。
            //     像素域 40 MHz、显存域 125 MHz 是两个不同 PLL 来的异步时钟，
            //     125 侧最早可能在翻 toggle 之后 1 个时钟（8 ns）就去采
            //     req_wbase —— 那一拍它可能正好采在数据跳变的瞬间，
            //     采到半个旧值半个新值 → **行首地址变成一个乱数**。
            //     症状正是"有的行整行横移，位移还不一样"（横条错位）。
            //     修法：行首这一拍只摆数据；【下一拍】才翻 toggle。
            //     这样 125 侧看到 toggle 变化时，数据已经稳稳地站着 ≥1 个像素时钟（25 ns）。
            if (line_go) begin
                req_wbase <= line_wbase;
                req_words <= line_words;
                req_buf   <= ~line_parity;      // 下一行用另一块
                pend_tgl  <= 1'b1;              // ★ 只登记"待翻"，不马上翻
                if (~line_parity) ready1 <= 1'b0;
                else              ready0 <= 1'b0;
            end
            else if (pend_tgl) begin
                pend_tgl <= 1'b0;
                req_tgl  <= ~req_tgl;           // ★ 数据已经稳了一整拍，现在翻
            end
        end
    end

    // ============================================================
    //  显存域：把请求的那一行读进来，填进指定的一块
    // ============================================================
    reg        ms1, ms2, ms3;
    wire       req_edge = ms2 ^ ms3;

    reg        filling;
    // ---- ★ 请求"挂着等读口"（见端口那一段的说明）----
    reg        rd_pend;
    // 有待受理的请求（本拍刚来的 或 上一拍没拿到读口记下的）
    wire       req_go   = (req_edge || rd_pend) && ~filling && rd_gnt;
    // 正在等读口（给上级仲裁看）
    assign     o_want   = (req_edge || rd_pend) && ~filling && ~rd_gnt;

    reg        fbuf;                 // 本轮填哪一块
    reg [11:0] fsent;                // 已发出多少个读请求
    reg [11:0] frcv;                 // 已收回多少个字
    reg [11:0] fwords;               // 本轮一共要读多少个字
    reg [20:0] faddr;                // 下一个要读的字地址
    reg [15:0] stall_cnt;            // 这一趟里"连续多少拍没收到字"
    // ---- 取数相位旋钮同步到显存域 ----
    reg [1:0]  mo1, mo2;
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin mo1 <= 2'd0; mo2 <= 2'd0; end
        else            begin mo1 <= mo_sel; mo2 <= mo1; end
    end
    // 在途"字数"上限（每个字占 4 拍，所以这个上限按字算）
    localparam [8:0] WORD_CREDIT = 9'd64;
    // 组内计数：0..3 循环。地址在这一组的 4 拍里举着不动。
    reg [1:0] gp_cnt;

    // ============================================================
    //  ★★★ 第五轮：读口抵消常数（见文件头）—— 全项目就这三行定义这套规矩
    // ============================================================
    localparam [20:0] RD_PRE   = 21'd4;    // 请求地址提前 4 个字（★ 必须是 4 的整数倍）
    localparam [11:0] RD_EXTRA = 12'd3;    // 一共多读 3 个字（前 3 个会被丢掉）
    localparam [20:0] RD_LAG   = 21'd3;    // 实测：起点对齐时，数据整体晚 3 个字
    localparam [1:0]  RD_SKIP  = 2'd3;     // 丢掉本趟收到的前几个字
    // ★★ 集成临时补偿（见 规划\A轨待改清单.md 第 7 条）：
    //   上板实测（整行 320 个字 vs 卡里原图逐像素比对，318/318 = 100%）：
    //   A 装进来的整幅图【整体晚 2 个字 = 4 个像素】—— 行映射、读口都没问题，
    //   是写入侧（A 的装载机）的偏移。这里把读起点往后挪 2 个字先顶上：
    //       偏移 = RD_LAG + RD_SKIP − RD_PRE = 3 + 3 − 4 = +2 个字
    //   ⇒ 缓冲里的第 j 个字 = 存储里 (行首 + 2 + j) 那个字 = 图上第 j 个字 ✓
    //   ★★ A 把装载机的偏移修好之后：把 RD_EXTRA 改回 1、RD_SKIP 改回 1
    //      （偏移就回到 0），否则图会反过来偏 −2 个字。

    // ---- 逐字对齐校验（地址图专用）----
    //   地址图里"字的值 = 它的地址"，所以每收到一个字都能直接算出对不对：
    //     期望值 = (本趟实际请求的行首 + 3 + 第几个字) 的低 16 位
    //     ★ 那个 +3 就是 RD_LAG：起点对齐时数据整体晚 3 个字（见文件头）。
    //   一趟填完把结果发布出去（两种数：第 1 个字偏了几个、本趟几个字不对）
    reg [20:0] fbase_r;               // 本趟请求的行首（显存域用）
    reg [15:0] f_off, f_bad;
    reg [1:0]  skip_r;                // ★ 本趟实际丢几个字（下边界那一行要变，见下）
    reg [20:0] fcur;                  // 当前这一组总线上举着的地址
    // ★★★ 2026-09-28 第七轮【每趟起步"静一静"】：上板残余是"每行行首那个字会隔行
    //   差一个字"（整行平移 2 像素，对平滑照片只在左右边缘看得见）。这是上一趟读的
    //   尾巴/起步残留被当成这一趟头几个字数进去造成的。上一版删掉这段是因为当时写
    //   通路还坏着量不出差别；现在写通路已修好，这一手正好补回来。
    reg [7:0]  drain_cnt;             // 接受请求后先安静这么多拍，再开始发读请求
    // ★★★ 第九轮【两遍读】：主搬运改成一趟读两遍 ——
    //   第一遍只是把读管线"跑热"（数据全部丢掉，一个字都不写缓冲）；
    //   紧接着第二遍按同一串地址再读一次，这一遍没有冷启动，
    //   头一个字就是有效值 → 行首再也不会读到旧值。
    //   带宽够：一行读两遍 640 字 ≈ 5µs，行周期 26µs（实测顺序读 ~500MB/s，
    //   显示只需要 160MB/s）。
    reg        pass_warm;             // 0 = 第一遍（预热、丢弃），1 = 第二遍（真填）
    // ★★★ 第八轮【行首复核】：上板实测每行只有"第一个字"是旧值（后面全对）。
    //   所以主搬运读完整行后，紧接着再读行首那 2 个字（这时读管线是热的，
    //   头一个字就是有效值），用它们覆盖缓冲槽 0、1。只影响每行头 4 个像素。
    // ★★ 2026-10-03 修：槽号必须跟着 W_DEPTH 的位宽走，不能写死 9 位。
    //    原来写死 [8:0]（0..511）是为 LINE_MAX=1024（W_DEPTH=512）配的；
    //    把 LINE_MAX 提到 2048 之后缓冲有 1024 个槽，但槽号还在 512 回绕 ——
    //    超过 512 字的行（= 一行源图宽于 1024 像素）会把前半行覆盖掉。
    //    屏上症状：左中右三段、只有中段对、右段是花屏（读的是没写过的槽）。
    //    ★ 读那边的 rd_word 一直用的是 W_ADDR_W，所以是"写窄读宽"的不对称。
    wire [W_ADDR_W-1:0] slot_w = (frcv >= fwords)
                                 ? (frcv[W_ADDR_W-1:0] - fwords[W_ADDR_W-1:0])
                                 : (frcv[W_ADDR_W-1:0] - skip_r);
    wire [20:0] exp_addr = fbase_r + RD_LAG + {9'd0, frcv};   // 第 frcv 个字期望的地址
    // ★ 信用用"发出 - 收回"，必须防下溢（万一核多回脉冲，12 位减会绕成大值 → 卡死）
    wire [12:0] f_inflight = ({1'b0, fsent} > {1'b0, frcv}) ?
                             ({1'b0, fsent} - {1'b0, frcv}) : 13'd0;
    // ★ 探针（一次性的，抓完就冻住 —— 关键：四个值同拍发布、且之后不再变，
    //   所以 50MHz 那边怎么读都不会撕裂）：
    //   盯住"请求的行首 = PROBE_WBASE"的那一次搬运，记下我请求的地址
    //   和实际收到的头两个字。上电时补偿=0，所以一定能命中一次。
    localparam [20:0] PROBE_WBASE = 21'h10400;   // 第 208 行（= 208 x 320）
    reg        p_arm, p_got;
    reg [20:0] p_wbase;
    reg [31:0] p_w0, p_w1;

    assign o_filling = filling;

    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            ms1         <= 1'b0;
            ms2         <= 1'b0;
            ms3         <= 1'b0;
            rd_pend     <= 1'b0;
            filling     <= 1'b0;
            fbuf        <= 1'b0;
            fsent       <= 12'd0;
            frcv        <= 12'd0;
            fwords      <= 12'd0;
            faddr       <= 21'd0;
        // ★★★ 2026-10-06：块级读通路（原来这里是 mem_rd_en / mem_rd_addr）
        blk_req   <= 1'b0;
        blk_base  <= 21'd0;
        blk_len   <= 21'd0;
        blk_want  <= 1'b0;
            done_tgl_m  <= 1'b0;
            done_buf_m  <= 1'b0;
            stall_cnt   <= 16'd0;
            p_arm       <= 1'b0;
            p_got       <= 1'b0;
            p_wbase     <= 21'd0;
            p_w0        <= 32'd0;
            p_w1        <= 32'd0;
            fbase_r     <= 21'd0;
            f_off       <= 16'd0;
            f_bad       <= 16'd0;
            skip_r      <= RD_SKIP;
            pass_warm   <= 1'b1;
            fcur        <= 21'd0;
            gp_cnt      <= 2'd0;
`ifdef B_DEBUG_PROBE
            o_dbg_wbase <= 21'd0;
            o_dbg_fwords<= 12'd0;
            o_dbg_rd0   <= 32'd0;
            o_dbg_rd1   <= 32'd0;
            o_dbg_frozen<= 1'b0;
            o_drop_cnt  <= 16'd0;
            o_abort_cnt <= 16'd0;
            o_off_first <= 16'd0;
            o_align_bad <= 16'd0;
`endif
        end
        else begin
            // ---- 请求同步 + 边沿检测 ----
            ms1 <= req_tgl;
            ms2 <= ms1;
            ms3 <= ms2;

            // ---- 受理一次搬运请求 ----
            //   ★ 正在搬的时候来的请求只能丢（那一行显示底色，下一行自动补）
            //   ★ o_drop_cnt 记它：上板如果这个数一直在涨，横条错位就有来源了
            // ★★ 2026-10-03（转场两路取样）：受理条件从"来了边沿"改成
            //    "来了边沿（或上一拍没受理，见 rd_pend）+ 读口归我"。
            //    rd_gnt 恒为 1 时，rd_pend 永远不会置起 —— 和改动前逐位相同。
            if (!filling) begin
                if (req_edge) rd_pend <= 1'b1;     // 先记着（下面拿到了就清掉）
                if (req_go) begin
                    rd_pend <= 1'b0;
                    // ★★★ 2026-09-28 第五轮：请求地址提前 RD_PRE 个字（见文件头）。
                    //    为什么是"提前 4 个字"而不是"少读 3 个字"：
                    //    核要求起点是 4 的整数倍，行首本身就是；提前 4 个字
                    //    （4 的整数倍）能保持这个对齐，同时把"丢掉的第 1 个字"
                    //    挪到行外去 —— 行里 320 个字一个不少。
                    // ★★ 下边界保护（第六轮）：存储第 0 行（= 图的最后一行）行首就是 0，
                    //    "提前 4 个字"会变成负地址 —— 上板实测那一行会读出一段旧内容
                    //    （左下角 ~34 个像素乱）。这一行退化成"不提前、只丢 1 个字"：
                    //    整行变成"错 4 个像素"，比读出乱码好得多。
                    //    ★ A 把那个 +2 字偏移修好之后，这段保护连同上面的补偿一起删掉。
                    // ★★★ 2026-10-06：改成"一次块请求"（原来这里是逐字地址发生器）
                    //   边界保护（行首不足 RD_PRE）与补偿口径原样保留。
                    if (req_wbase >= RD_PRE) begin
                        fbase_r     <= req_wbase - RD_PRE;  // 逐字校验/探针用"实际请求起点"
                        fwords      <= req_words + RD_EXTRA;
                        skip_r      <= RD_SKIP;
                        blk_base    <= req_wbase - RD_PRE;
                        blk_len     <= req_words + RD_EXTRA;
                    end
                    else begin
                        fbase_r     <= 21'd0;
                        fwords      <= req_words + 12'd1;   // 只多读 1 个
                        skip_r      <= 2'd1;
                        blk_base    <= 21'd0;
                        blk_len     <= req_words + 12'd1;
                    end
                    blk_req     <= 1'b1;                // ★ 发块请求（等 blk_gnt）
                    blk_want    <= 1'b0;
                    fbuf        <= req_buf;
                    frcv        <= 12'd0;
                    f_bad       <= 16'd0;               // 本趟的错误字数清零
                    f_off       <= 16'd0;
                    gp_cnt      <= 2'd0;
                    stall_cnt   <= 16'd0;
                    pass_warm   <= 1'b0;                // ★ 从"预热那一遍"开始
                    filling     <= 1'b1;
                    // 探针：★ 每趟都刷新；p_wbase 记的是【上层要的行首】（不是
                    // 实际请求起点），这样串口里"asked / got1 / got2"三者好对照。
                    p_arm        <= 1'b1;
                    p_wbase      <= req_wbase;
`ifdef B_DEBUG_PROBE
                    o_dbg_fwords <= req_words + RD_EXTRA;
`endif
                end
            end
`ifdef B_DEBUG_PROBE
            else if (req_edge && (o_drop_cnt != 16'hFFFF)) o_drop_cnt <= o_drop_cnt + 16'd1;
`endif

            if (filling) begin
                // ---- 看门狗（见文件头）：太久没交付就放弃这一趟 ----
                if (blk_dv)                          stall_cnt <= 16'd0;
                else if (stall_cnt != 16'hFFFF)      stall_cnt <= stall_cnt + 16'd1;

                // ---- 块请求：受理了就撤 ----
                if (blk_gnt) blk_req <= 1'b0;

                // ---- 还要字就要（电平）----
                //   ★ 取多少不再由我们数信用：**仲裁器只在 FIFO 有字时才交付**
                //     （所以这里不需要 WORD_CREDIT / f_inflight / rd_ok 那一套了）
                blk_want <= (frcv < fwords);

                // ---- 收数据：blk_dv 单拍 + blk_data（一个交付一个字）----
                if (blk_dv) begin
                    // ★ 见一个有效脉冲收一个字（和 M0 / rd_selftest 一致）
                    // ---- 探针：这一趟的头两个字 ----
                    if (p_arm) begin
                        // ★ 第 RD_SKIP 个起才是"保留下来的"，探针取头两个保留下来的字
                        if (frcv == {10'd0, skip_r})         p_w0 <= blk_data;
                        if (frcv == {10'd0, skip_r} + 12'd1) p_w1 <= blk_data;
                    end
                    // ---- 逐字对齐校验（地址图里：字的值应当 = 它的地址）----
                    //   第 frcv 个字期望的值 = (实际请求起点 + 3 + frcv) 的低 16 位
                    if (pass_warm && (blk_data[15:0] != exp_addr[15:0])) begin
                        if (f_bad != 16'hFFFF) f_bad <= f_bad + 16'd1;
                    end
                    // ★ off 探针 = "第 1 个保留字 − 上层要的行首"：
                    //   地址图里它应当 = RD_LAG + RD_SKIP − RD_PRE
                    //   （没有 A 的临时补偿时 = 0；带着补偿时 = +2）
                    if (pass_warm && (frcv == {10'd0, skip_r})) f_off <= blk_data[15:0] - p_wbase[15:0];
                    // ★ 丢掉本趟收到的前 skip_r 个字；第 k 个（k ≥ skip_r）
                    //   写进缓冲的第 k−skip_r 个位置 → 缓冲正好是这一行的 req_words 个字
                    if (pass_warm && (frcv >= {10'd0, skip_r})) begin
                        if (fbuf) lb1[slot_w] <= blk_data;
                        else      lb0[slot_w] <= blk_data;
                    end
                    frcv <= frcv + 12'd1;
                    if (frcv == fwords - 12'd1) begin
                        if (!pass_warm) begin
                            // ★ 预热那一遍读完了 → **再发一次块请求**（同一串地址，管线是热的）
                            //   （原来是"把地址倒回去重发"，块级通路就是重新请求同一个块）
                            pass_warm <= 1'b1;
                            blk_req   <= 1'b1;
                            blk_want  <= 1'b0;
                            frcv      <= 12'd0;
                        end
                        else begin
                        filling    <= 1'b0;
                        blk_want   <= 1'b0;
                        done_buf_m <= fbuf;
                        done_tgl_m <= ~done_tgl_m;
`ifdef B_DEBUG_PROBE
                        // ★ 本趟的对齐结果发布（每趟刷新，供串口看）
                        o_off_first <= f_off;
                        o_align_bad <= f_bad;
                        // ★ 这一趟填完了：把探针值一次性发布，并永久冻住
                        if (p_arm) begin
                            o_dbg_wbase  <= p_wbase;
                            o_dbg_rd0    <= p_w0;
                            o_dbg_rd1    <= p_w1;
                            o_dbg_frozen <= 1'b1;
                            p_arm        <= 1'b0;
                            p_got        <= 1'b1;
                        end
`endif
                        end
                    end
                end
                else if (stall_cnt >= STALL_MAX[15:0]) begin
                    // 超时：这一趟作废（不置 done，那块保持"没准备好"）
                    filling   <= 1'b0;
                    blk_req   <= 1'b0;
                    blk_want  <= 1'b0;
                    if (p_arm) p_arm <= 1'b0;
`ifdef B_DEBUG_PROBE
                    if (o_abort_cnt != 16'hFFFF) o_abort_cnt <= o_abort_cnt + 16'd1;
`endif
                end
            end
            else begin
                blk_req  <= 1'b0;
                blk_want <= 1'b0;
            end
        end
    end

endmodule

