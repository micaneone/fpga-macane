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
//  模块名 : sdr_arb
//  作用   : SDRAM 的【对外接口层】—— A 往里写、B 往外读。
//           存储本体 `sdram` 例化在顶层（和官方例程 / M0 一样）。
//  层次   : 显示链最底层（B 轨）；A 轨通过它把图写进 SDRAM
//  时钟域 : 两个 —— 写口 A 侧在【控制域 50 MHz】，SDRAM 侧在【显存域 125 MHz】
//
// ============================================================
//  ★★ 2026-09-28 第四版（定稿）：**写口直接例化原厂的写引擎**
//
//  为什么走到这一步（每一步都有上板数据，见 M1_读口问题_诊断记录.md §8~16）：
//    自己写的突发引擎试了四版：
//      ① 每字只举 4 拍 en           → 内容成组错乱（错 1536）
//      ② 攒 16 字写一串（一个 FIFO）  → 还错（错 1857）
//      ③ 攒 256 字写 256 字 + 预取一级 → 开头 8 个字对了，后面 65% 错（错 1272），
//         而且错的位置读回来是**旧内容** ⇒ 有些写根本没进 DRAM
//    原厂的写引擎 `frame_fifo_write.v`（+ 数据 FIFO `wfifo_32_32_512`）是
//    **在这块板上跑通过**的（官方例程能正常显图），所以不再自己写：
//      · 数据 FIFO：A 在 50 MHz 侧推；
//      · `frame_fifo_write`：在 125 MHz 侧，一件一件地写（BURST_SIZE = 256），
//        `App_wr_en` 由它自己产生，`App_wr_addr` 它自己数（从 write_addr_x 起 +1）。
//
//  ★ A 的用法（三拍：请求 → 填数据 → 收 finish）：
//     1) 等 sdr_ready = 1
//     2) **请求**：摆好 a_wr_base（这段从哪写）和 a_wr_len（这段多少个字），
//        把 a_wr_req 拉高**举着**，直到看见 a_wr_ack（一拍）
//        —— ★ ack 之前**别推数据**（引擎受理时会清 FIFO）
//     3) **填数据**：一个字一个字推：a_wr_data + a_wr_we 给一拍；
//        a_wr_full = 1 就先停（背压）。一共推 a_wr_len 个字
//     4) **收尾**：等 a_wr_done（一拍脉冲）= 这一整段真的写进 SDRAM 了
//        （这时才能报 frame_done / 置描述符 valid）
//
//  ★ 读口：M1 阶段只有"B 的显示"一个申请人，直通。
//     `App_rd_busy` 先给 0（我们的读口是一拍一字的直通，不是突发）。
// ============================================================
`timescale 1ns / 1ps

module sdr_arb #(
    // ★★ 2026-10-02：恢复成 256（原厂验证过的配置）。
    //   09-28 曾把它临时改成 128 当诊断旋钮（"看坏行周期是否减半，用来确认/排除
    //   写串边界"），结论是"不变"，但这颗旋钮**一直没拧回去** —— 交付版就停在
    //   128 上了，而原厂能跑通的那套是 256：
    //     · frame_fifo_write.v 的【模块默认值】才是 128；
    //       frame_read_write.v 显式把它覆盖成 256；
    //     · 官方能正常显图的例程（lab_ex4_tf）用的也是 256。
    //   改回 256 不需要动别处：BURST_BITS=9 装得下 256，
    //   FIFO 512 深也够（引擎的开工条件是 rdusedw > BURST_SIZE）。
    parameter integer BURST_SIZE = 256
)(
    // ---------------- 控制域 50 MHz：A 的写口 ----------------
    input  wire        clk_ctl,
    input  wire        rst_ctl_n,
    input  wire        a_wr_req,       // 一段的写请求（举着，直到 a_wr_ack）
    input  wire [20:0] a_wr_base,      // 这一段从哪个字地址开始（req 期间保持）
    input  wire [20:0] a_wr_len,       // 这一段一共多少个字（req 期间保持）
    output reg         a_wr_ack,       // 一拍脉冲：请求受理了，可以开始推数据
    input  wire [31:0] a_wr_data,      // 推一个字（= 两个相邻像素，[31:16] 靠前）
    input  wire        a_wr_we,        // 推字（FIFO 写使能）
    output wire        a_wr_full,      // 1 = FIFO 满，先别推
    output reg         a_wr_done,      // 一拍脉冲：这一段全写进 SDRAM 了
    output wire        sdr_ready,      // 1 = SDRAM 初始化完成（已同步到本域）

    // ---------------- 显存域 125 MHz ----------------
    input  wire        clk_mem,        // 125 MHz（PLL_SDR 的 C1）
    input  wire        clk_mem_180,    // 125 MHz 相位差 180°（PLL_SDR 的 C2 → SDRAM 的 Clk_sft）
    input  wire        rst_mem_n,

    // ---------------- 读申请人（M1 只有显示 / 自测）----------------
    input  wire        disp_rd_en,
    input  wire [20:0] disp_rd_addr,

    // ---------------- ★ 写引擎活动状态（给顶层做读口握手用）----------------
    output wire        o_wr_burst,     // 写引擎正在突发
    output wire        o_wr_guard,     // 突发刚结束的几拍
    // ---------------- ★ 诊断：我们自己估的占用是否"满"（occ ≥ 512）----------------
    //   ★ 2026-10-04：上板抓到的病根线索 —— 引擎的开工条件是
    //     `into_burst = (rdusedw > BURST_SIZE)`，而 rdusedw 就是我们估的 occ。
    //     这一位为 1 就代表"引擎认为管道满、会开工"。压成 1 位是因为
    //     多位总线在 ChipWatcher 的 CSV 里导不准。
    output wire        o_occ_hi,
    // ---------------- ★ 提前让路阈值：占用快到"该突发了"（occ ≥ 240）----------------
    //   ★★ 2026-10-04：引擎攒够 BURST_SIZE(256) 就突发，突发约 2 µs。
    //     要"读写不撞"，显示必须**提前**让路（请求是寄存的，等突发开始再让已经晚了）。
    //     240 = 256 提前 16 个字；SD 现在 25 MHz（~780k 字/秒）⇒ 16 个字 ≈ **20 µs**，
    //     比一行 26.4 µs 还小，显示完全吃得下（每 330 µs 才让一次）。
    output wire        o_occ_pre,

`ifdef B_DEBUG_PROBE
    // ---------------- 诊断（**只在 B_DEBUG_PROBE 定义时才存在**）----------------
    //  ★ 2026-10-01：这个口只为【上板串口报告的 W】服务，默认不综合、端口不存在。
    //    要读串口就在工程里加宏 B_DEBUG_PROBE（仿真脚本 / M1 调试工程都加好了，
    //    说明见 line_buf.v 里那一段）。
    output wire [23:0] o_wr_cnt,
`endif

    // ---------------- SDRAM 的 App 口（本体在顶层）----------------
    output wire        App_wr_en,
    output wire [20:0] App_wr_addr,
    output wire [3:0]  App_wr_dm,
    output wire [31:0] App_wr_din,
    output wire        App_rd_en,
    output wire [20:0] App_rd_addr,
    input  wire        Sdr_init_done,
    input  wire        Sdr_init_ref_vld,
    input  wire        Sdr_busy,
    // ★★★ 2026-10-08【最小实验：把原厂的读写仲裁接上】（见 规划\B轨待改清单.md §22）
    //   读通路（官方 frame_fifo_read）的"读突发进行中"标志。原厂 frame_fifo_write
    //   本来就有这个输入：**读侧在突发时，写引擎不进入突发**（frame_fifo_write.v
    //   第 104 行 `into_burst = ... && ~App_rd_busy`）。我们以前一直喂 1'b0
    //   （"我们的读口是直通，不是突发"），等于告诉写引擎"读侧永远不忙" ⇒
    //   写突发可能在读突发中间开工 ⇒ 真重叠，这就是当年 8 版失败的配置。
    input  wire        rd_busy,
    // 写引擎的忙标志（= 它的 O_wr_busy，突发中或马上要突发）→ 给读通路做互锁
    output wire        o_wr_busy
);

    // ============================================================
    //  ★★ 2026-10-03（转场"不经过米白"）：把写引擎的活动状态引出来
    // ------------------------------------------------------------
    //  读口原来是**直通**的（`App_rd_en = disp_rd_en`），和写引擎完全没有仲裁；
    //  M0 实测"读写同时 = 数据错"，所以顶层只好在写的时候把显示读整段掐掉 →
    //  装载那几秒屏上是米白。**"不经过米白"要的就是这段别掐**，改成
    //  "只在写突发那几拍让读等一等"：
    //     · `o_wr_burst` = 写引擎正在突发（App_wr_en 还在拉高）
    //     · `o_wr_guard` = 突发刚结束后的几拍（让核内部状态静一静）
    //  顶层拿这两个（或起来）做 `mem_rd_ok`。
    //  ★ 为什么这样几乎不影响显示：SD 慢，写突发是 **512 字 / 约 20 ms 一次、
    //    每次约 4 µs**（0.02% 的时间），而一行有 26 µs 的余量。
    // ============================================================
    reg  [5:0] wr_guard_cnt;
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n)              wr_guard_cnt <= 6'd0;
        else if (App_wr_en)          wr_guard_cnt <= 6'd48;   // 突发期间一直在"守着"
        else if (wr_guard_cnt != 0)  wr_guard_cnt <= wr_guard_cnt - 6'd1;
    end
    assign o_wr_burst = App_wr_en;
    assign o_wr_guard = (wr_guard_cnt != 6'd0);

    // ============================================================
    //  ① 控制域：SDRAM 初始化完成同步过来
    // ============================================================
    reg sd1, sd2;
    always @(posedge clk_ctl or negedge rst_ctl_n) begin
        if (!rst_ctl_n) begin sd1 <= 1'b0; sd2 <= 1'b0; end
        else            begin sd1 <= Sdr_init_done; sd2 <= sd1; end
    end
    assign sdr_ready = sd2;

    // ============================================================
    //  ② 数据异步 FIFO（原厂 wfifo_32_32_512）
    //     A 在 clk_ctl 侧推；引擎在 clk_mem 侧用 App_wr_en 当读使能取
    //     rst 高有效：引擎每受理一次写请求会清一次（fifo_aclr），加上上电复位
    // ============================================================
    wire        fifo_full;
    wire [9:0]  fifo_rdusedw;
    // ★★★ 2026-09-28 根因 + 修法（写口仿真复现过）：
    //   写引擎唯一的"什么时候该突发"依据，是这颗原厂异步 FIFO 的 rdusedw。
    //   实测（写口仿真里把内部状态打出来）：**这个输出在这套例化下是高阻 Z**
    //   （文件里 assign rdusedw = rd_addr_diff，但这个 net 在这版网表里没被驱动）。
    //   于是引擎的判断是未定义值：推字快时刚好能跑对（原来用桩写入器测的就是
    //   这种"快推"，所以一直没暴露）；换成 SD 卡那种"一顿一顿"的慢推，引擎会
    //   比 FIFO 填得快 —— 把空 FIFO 当有数据的抽，抽够长度就收工，剩下 A 推一半
    //   的数据卡在"FIFO 满"上（真机上表现为：**最后一串 256 个字没写进 SDRAM**，
    //   图最上面几行读到旧内容；串口 W = 153344 = 153600−256）。
    //   ⇒ 不再用那个 Z 信号，改成我自己给一个可靠的"余量"：
    //       满(full)  → 报 511（让引擎开工）
    //       没满      → 报 0  （引擎等着，绝不去抽空 FIFO）
    //     ★ 代价是引擎只在 FIFO 满时突发，所以必须有下面那段"补喂"兜底。
    // ★ 自己数一份"FIFO 里现在有多少字"：推字事件用 toggle 从 A 侧跨过来，
    //   取走事件就是引擎的 App_wr_en（本来就在显存域）。
    //   ★ 这一份完全由本模块产生，不依赖那颗 FIFO 任何状态输出。
    //
    // ★★ 2026-10-02：上个月那段"Z 是位宽假象、FIFO 的 rdusedw 一直是好的"（见
    //    交接_M1显示调试.md §9.1）**是对的**，所以我试过把引擎改吃 FIFO 真值。
    //    **上板实测：坏点一个没少，而且右上角又多出一条花边** —— 右上角正是
    //    "一帧最后写的那些字"落的地方，说明引擎在收尾时反而等不到数据
    //    （尾巴上 `write_len_latch <= rdusedw + write_cnt` 这条判据需要 rdusedw
    //    偏大才触发）。**所以这一版已经回退**，引擎继续吃 occ 估计值。
    //    ⇒ 结论：occ 不是为了绕"Z"，而是**收尾必须要它**。别再改这里。
    reg        push_tgl;                  // ★ 声明放前面（赋值块在后面，见 fifo_we 附近）
    reg pt1, pt2, pt3;
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin pt1 <= 1'b0; pt2 <= 1'b0; pt3 <= 1'b0; end
        else begin pt1 <= push_tgl; pt2 <= pt1; pt3 <= pt2; end
    end
    wire       push_evt = pt2 ^ pt3;
    reg [21:0] occ;                       // 我自己数的占用（显存域）
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) occ <= 22'd0;
        else if (push_evt && App_wr_en) occ <= occ;                  // 同拍一进一出
        else if (push_evt)              occ <= occ + 22'd1;
        else if (App_wr_en)             occ <= (occ == 0) ? 22'd0 : (occ - 22'd1);
    end
    // ★★ 2026-10-25【P0-4】宽比较 → 位判断（语义完全等价，省掉 6 级 ADDER 比较链）：
    //   occ >= 512 ⟺ occ[21:9] != 0；occ >= 248 (=8'hF8) ⟺ occ[21:8] != 0 或 occ[7:3] 全 1。
    //   125 MHz 域唯一真违例（occ → o_occ_hi → u_wr/write_len_latch → App_rd_en）
    //   就是被这两条 22 位比较加法链拖出来的；数值判据一个字没改。
    wire        occ_hi_raw  = |occ[21:9];
    wire        occ_pre_raw = (|occ[21:8]) | (&occ[7:3]);
    wire [9:0]  fifo_rdusedw_eng = occ_hi_raw ? 10'd511 : occ[9:0];
    // ★ 诊断（见端口说明）：occ ≥ 512 = 引擎认为管道满、会开工。
    //   放在这里是因为 occ 在这一行上面才声明（ModelSim 不许先用后声明）。
    assign o_occ_hi = occ_hi_raw;
    // ★★ 2026-10-04 实测修正：原设 240（提前 16 个字）在 25 MHz SD 下要等约 20 µs，
    //    再加突发 2 µs，一次让路接近一整行（26.4 µs）→ 每撞一次掉一行
    //    ⇒ 上板看到"白色横条纹往上扫"。
    //    提前量其实只要覆盖读请求的几拍流水：8 个字 ≈ 10 µs + 突发 2 µs ≈ 12 µs，
    //    而一行里取数 6.4 µs + 让路 12 µs 仍在 26.4 µs 之内 ⇒ 不会掉行。
    assign o_occ_pre = occ_pre_raw;        // ★ 提前让路阈值：256 提前 8 个字（等价 occ>=248）

    // ---- ★ 收尾补喂（padding）------------------------------------------
    //  A 推完 a_wr_len 个字之后，由本模块继续往 FIFO 里补喂 PAD_WORDS 个 dummy 字
    //  （只在 !fifo_full 时补），并把【引擎看到的长度】加长同样的数量。
    //  这样最后几次突发一定有 ≥256 个字可写 → 真正写进 SDRAM 的字节数
    //  不再少一截。dummy 字落在图的后面（地址 = 基址+a_wr_len 之后），不碰图。
    localparam [20:0] PAD_WORDS = 21'd0;   // ★ 已经不需要补喂      // 512 + 128：够把"满"凑出来，又不多
    reg  [20:0] push_cnt;                       // ctl：A 已推多少个字
    reg  [10:0] pad_cnt;                        // ctl：已补喂多少个 dummy
    reg         padding;                        // 1 = 正在补喂
    wire        pad_we = 1'b0;   // ★ 整段补喂停用（已不再需要；上电误触发会把显示按在复位里）
    wire        fifo_we = a_wr_we | pad_we;
    wire [31:0] fifo_di = pad_we ? 32'd0 : a_wr_data;

    // ★ 推字事件翻 toggle（放在这里：要用到上面的 fifo_we；声明在前面）
    //   ★★ 必须数【上升沿】：推字使能有可能是电平（真 A 是单拍脉冲，但桩/测试台
    //   曾经拉成电平），按电平翻 toggle 会把同一个字数成好几次 → 余量虚高 →
    //   写引擎以为管道里一直有货 → 抽空 FIFO（上板"最后一串没写"的同一族毛病）。
    reg        fifo_we_d;
    wire       push_pulse = fifo_we & ~fifo_we_d;      // 真正推了一个字
    always @(posedge clk_ctl or negedge rst_ctl_n) begin
        if (!rst_ctl_n) begin
            push_tgl  <= 1'b0;
            fifo_we_d <= 1'b0;
        end
        else begin
            fifo_we_d <= fifo_we;
            if (push_pulse) push_tgl <= ~push_tgl;
        end
    end
    wire [31:0] fifo_dout;
    wire        fifo_aclr;
    wire        fifo_rst = fifo_aclr | ~rst_ctl_n | ~rst_mem_n;

    wfifo_32_32_512 u_fifo (
        .rst        (fifo_rst),
        .clkw       (clk_ctl),
        .clkr       (clk_mem),
        .we         (fifo_we),
        .di         (fifo_di),
        .re         (App_wr_en),        // 引擎写一个字 = 从 FIFO 取一个字
        .dout       (fifo_dout),
        .valid      (),
        .full_flag  (fifo_full),
        .empty_flag (),
        .afull      (),
        .aempty     (),
        .wrusedw    (),
        .rdusedw    (fifo_rdusedw)
    );
    // ★★★ 第十一轮【改用自己的占用给 A 背压】：上板实测残余 = "每 1024 字有一个地址
    //   从来没被写过"（读回来还是上一版旧图的内容）。1024 = 2×512（FIFO 深度），
    //   而 A 的背压一直用这颗 FIFO 自己的 full 标志 —— 那个标志在仿真里就不可靠
    //   （装 256 个字就报满），于是 A 一路推、把 FIFO 灌爆，被冲掉的字正对应那些
    //   "从没写进去"的地址。这里改成用【我自己数的占用 occ】来背压。
    reg        occ_hi;                        // 显存域：占用过高
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) occ_hi <= 1'b0;
        else            occ_hi <= (occ >= 22'd480);
    end
    reg oh1, oh2;                              // 控制域：两拍同步（慢变电平，够用）
    always @(posedge clk_ctl or negedge rst_ctl_n) begin
        if (!rst_ctl_n) begin oh1 <= 1'b0; oh2 <= 1'b0; end
        else begin oh1 <= occ_hi; oh2 <= oh1; end
    end
    assign a_wr_full = oh2 | fifo_full;        // ★ 谁报满都听（自己的占用 + 原厂标志）

    // ============================================================
    //  ③ 请求跨域：A 侧举 req（电平）+ base/len 摆稳 → 两级同步（电平信号够用）
    // ============================================================
    reg        req_s1, req_s2;
    reg [20:0] base_s1, len_s1;
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            req_s1  <= 1'b0;
            req_s2  <= 1'b0;
            base_s1 <= 21'd0;
            len_s1  <= 21'd0;
        end
        else begin
            req_s1  <= a_wr_req;
            req_s2  <= req_s1;
            base_s1 <= a_wr_base;          // A 保证 req 期间不动
            len_s1  <= a_wr_len;
        end
    end
    wire        wr_req_m  = req_s2;
    // ★★ 2026-09-28：写侧也要补那 3 个字！
    //    上板实测（抓 SDRAM 写口）：引擎举 (地址 A, 数据 D)，数据实际落在 **A+3**，
    //    所以 A 装的图整体往后挪了 3 个字，基址开头留着上一版（自测图）的残余。
    //    ★ 实测结论（2026-09-28 晚，最后一次量准）：
    //        关掉开机自测图、A 的基址给 3 之后，最后一笔写落在 0x25702 = 153346
    //        —— 正好是"举多少就落多少"（数据落在引擎举的地址上，偏移为 0）。
    //        所以写侧【不需要】任何补偿；之前那次"残余 3 个字"其实是开机自测图
    //        自己留下的旧内容，把我误导了一次。
    //      ⇒ 写侧基址原样透传（读侧的 +3 延迟照样用 cmp_off=3 抵）。
    wire [20:0] wr_base_m = base_s1;
    wire [20:0] wr_len_m  = len_s1;

    // ---- ★ 收尾补喂的时序（放在这里：要用到上面的 wr_len_m）----
    always @(posedge clk_ctl or negedge rst_ctl_n) begin
        if (!rst_ctl_n) begin
            push_cnt <= 21'd0;
            pad_cnt  <= 11'd0;
            padding  <= 1'b0;
        end
        else begin
            if (a_wr_we && !padding) push_cnt <= push_cnt + 21'd1;
            // A 把请求的字数推完 → 开始补喂（引擎的长度已经在上面 +PAD_WORDS）
            if (!padding && ((push_cnt + (a_wr_we ? 21'd1 : 21'd0)) >= wr_len_m))
                padding <= 1'b1;
            else if (pad_we) pad_cnt <= pad_cnt + 11'd1;
            // 引擎报收工、或补喂够了 → 结束
            if (padding && (a_wr_done || (pad_cnt >= PAD_WORDS[10:0])))
                padding <= 1'b0;
        end
    end

    // ============================================================
    //  ④ 原厂写引擎（照抄 frame_read_write 里的接法）
    //     · write_req / write_addr_x / write_len 是请求侧（mem_clk 域）
    //     · App_wr_en / App_wr_addr 由它自己产生
    //     · write_finish = 这一段写完了
    // ============================================================
    wire        wr_ack_m, wr_finish_m, wr_busy_m;
    // ★ 2026-10-08：写引擎自己的忙标志（突发中 / 马上要突发）引出去，给读通路做互锁
    //   （★ 声明必须在这里——`wr_busy_m` 是下面那个例化的输出，
    //     "先用后声明"这个工程踩过五次，见 AGENTS）
    assign o_wr_busy = wr_busy_m;

    frame_fifo_write #(
        .MEM_DATA_BITS (32),
        .ADDR_BITS     (21),
        .BURST_BITS    (9),
        .BURST_SIZE    (BURST_SIZE),
        .WRITE_V_FLIP  (0),             // 不翻转（我们要的地址顺序自己给）
        .FRAME_WIDTH   (2),             // V_FLIP=0 时用不到，给最小值
        .FRAME_HEIGHT  (2)
    ) u_wr (
        .rst              (~rst_mem_n),
        .mem_clk          (clk_mem),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (Sdr_init_ref_vld),
        .Sdr_busy         (Sdr_busy),
        // ★★★ 2026-10-08：原来是 1'b0（= "读侧永远不忙"）。现在接上读通路的
        //   `o_rd_busy`（官方读控制器"读突发进行中"）⇒ 恢复原厂的**突发级互锁**：
        //   读在突发时，写引擎**不进入**突发（它会在 S_CHECK_FIFO 里等着）。
        .App_rd_busy      (rd_busy),
        .O_wr_busy        (wr_busy_m),
        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .write_req        (wr_req_m),
        .write_req_ack    (wr_ack_m),
        .write_finish     (wr_finish_m),
        .write_addr_0     (wr_base_m),
        .write_addr_1     (21'd0),
        .write_addr_2     (21'd0),
        .write_addr_3     (21'd0),
        .write_addr_index (2'd0),
        // ★ 长度加 PAD_WORDS：补喂的 dummy 字也算在引擎的账上，
        //   引擎才会一直搬到"最后一段真数据"写完为止
        .write_len        (wr_len_m),
        .fifo_aclr        (fifo_aclr),
        .rdusedw          (fifo_rdusedw_eng)
    );

    // ---- ack：mem 域的一拍脉冲 → 翻 toggle → 控制域检边沿
    //      ★ 再往后拖 ACK_DELAY 拍才报给 A：引擎受理的那几拍还在清 FIFO，
    //        A 收到 ack 就会开始推数据，所以 ack 必须等清干净了再给。
    // ------------------------------------------------------------------
    localparam [7:0] ACK_DELAY = 8'd64;
    reg        ack_tgl;
    reg        ack_d;
    reg        ack_seen;                 // 控制域：已经看到这次受理
    reg  [7:0] ack_cnt;
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) ack_tgl <= 1'b0;
        else begin
            ack_d <= wr_ack_m;
            if (wr_ack_m & ~ack_d) ack_tgl <= ~ack_tgl;
        end
    end
    reg [2:0] at_s;
    always @(posedge clk_ctl or negedge rst_ctl_n) begin
        if (!rst_ctl_n) begin
            at_s      <= 3'd0;
            a_wr_ack  <= 1'b0;
            ack_seen  <= 1'b0;
            ack_cnt   <= 8'd0;
        end
        else begin
            at_s <= {at_s[1:0], ack_tgl};
            a_wr_ack <= 1'b0;
            if (at_s[1] ^ at_s[2]) begin    // 引擎受理了
                ack_seen <= 1'b1;
                ack_cnt  <= 8'd0;
            end
            else if (ack_seen) begin
                if (ack_cnt >= ACK_DELAY) begin
                    a_wr_ack <= 1'b1;       // 拖够了，才告诉 A 可以推
                    ack_seen <= 1'b0;
                end
                else ack_cnt <= ack_cnt + 8'd1;
            end
        end
    end

    // ---- done：mem 域 write_finish（电平几拍）→ 翻 toggle → 控制域检边沿 ----
    reg        fin_tgl;
    reg        fin_d;
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) fin_tgl <= 1'b0;
        else begin
            fin_d <= wr_finish_m;
            if (wr_finish_m & ~fin_d) fin_tgl <= ~fin_tgl;
        end
    end
    reg [2:0] ft_s;
    always @(posedge clk_ctl or negedge rst_ctl_n) begin
        if (!rst_ctl_n) begin
            ft_s        <= 3'd0;
            a_wr_done   <= 1'b0;
        end
        else begin
            ft_s <= {ft_s[1:0], fin_tgl};
            // ★★ 锁存电平（不是一拍脉冲）：写引擎的 write_finish 只有一拍，
            //    如果写入器那一拍还没准备好就会漏掉，然后永远等下去。
            //    这里"置上就不撤"，直到下一次请求被受理（ack）才清。
            if (ft_s[1] ^ ft_s[2]) a_wr_done <= 1'b1;   // 引擎报 finish
            else if (a_wr_ack)     a_wr_done <= 1'b0;   // 新一段开始时清
        end
    end

`ifdef B_DEBUG_PROBE
    // ---- 诊断：写了多少字（mem 域自己数；只在 B_DEBUG_PROBE 时存在）----
    reg [23:0] wr_cnt_r;
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) wr_cnt_r <= 24'd0;
        else if (App_wr_en) wr_cnt_r <= wr_cnt_r + 24'd1;
    end
    assign o_wr_cnt = wr_cnt_r;
`endif

    assign App_wr_dm   = 4'b0000;      // 整字写
    assign App_wr_din  = fifo_dout;    // 和原厂一样：FIFO 输出直接送 SDRAM

    // ============================================================
    //  ④ 读口：直通（M1 只有一个申请人）
    // ============================================================
    assign App_rd_en   = disp_rd_en;
    assign App_rd_addr = disp_rd_addr;

endmodule







