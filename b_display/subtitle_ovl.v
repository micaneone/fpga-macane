// ============================================================
//  模块名 : subtitle_ovl —— 【字幕叠加】（像素流水第 ④ 级）
//  层次   : 转场之后、565→888 之前（disp_top 里的最后"画"一下）
//  时钟域 : 两个 —— 取字侧 clk_mem(125 MHz，读口在这个域) / 像素侧 clk_pix(40 MHz)
//  依据   : 规划\B轨待改清单.md §24/§26/§27；artwork_def.v 的
//           SDR_SUBTITLE_BASE / _STRIDE / ART_SUB_W / ART_SUB_H
// ------------------------------------------------------------
//  干什么（一句话）：把 SDRAM 字幕区里的 **1bpp 遮罩**叠到画面上 ——
//      **bit = 1 画 ink（默认黑 = 文字）**；**bit = 0 透传**（白底不画）。
//
//  ★★★ 2026-10-09 第二版【整条字幕一次性取回片上】—— 为什么改：
//    第一版是"每条扫描线取一行（25 字）"。上板实测（§26）：字幕只有 25 字的**短块**，
//    在 `blk_rd_arb` 里会**错过官方那个一拍宽的 read_finish** ⇒ 收尾死等到看门狗
//    （8192 拍 = 65 µs）才放读口 ⇒ 显示那一行被行缓冲看门狗放弃（**屏幕底部变米白 +
//    黑横线**）、音频也被饿成一片沙沙声；而且字幕自己被饿到"每帧只取到几行"。
//    现在改成：**每帧（vs 上升沿）把整条 1600 字一次取进片上 RAM**（1600 字 ≈ 13 µs，
//    一帧 16.6 ms 里占 0.08%），**每条扫描线再也不碰读口** ⇒ 谁都不饿。
//
//  ★ 片上 RAM 怎么写才进 BRAM（这是 §26 讨论过的）：
//      · **写侧 clk_mem**：`cmem[w] <= mem_data`（块取回来的字）
//      · **读侧 clk_pix**：**寄存读** `mword_q <= cmem[addr]`（BRAM 读必须同步！）
//      · 形状照 `line_buf.v` 抄（它就是这么写的，TD 布成 8 块 BRAM）
//    ★ 寄存读的代价 = 地址要**提前一拍**算：这里算的是"**下一个像素**"的地址，
//      所以数据在下一拍正好配那个像素；之后我们再多打一拍出像素（**总共 2 拍延迟**）。
//
//  数据长什么样（★ A 轨 sub_analyze 定的）：1600 字 = 25 字/行 × 64 行；
//      bit31 = 这 32 个像素里最左边那个；行序**自下而上** ⇒ 屏幕第 k 行用第 (63-k) 行。
//
//  ★★ 位置是【端口】不是常数 —— 现在顶层给暂定值，以后 C 轨的 WIN_SUB 直接接上来。
//  ★ 声明全部前置（这个工程踩过五次"先用后声明"）
// ============================================================
`timescale 1ns / 1ps

module subtitle_ovl (
    // ---------------- 像素域 40 MHz ----------------
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire [11:0] x_in,        // 屏幕坐标（disp_top 给 o_dbg_x：和 px_in 同一像素）
    input  wire [11:0] y_in,        // （o_dbg_y）
    input  wire [15:0] px_in,       // RGB565（转场之后的像素）
    output reg  [15:0] px_out,      // ★ 比输入晚【两拍】（de/vs 跟着一起打两拍）
    output reg         de_out,
    output reg         vs_out,

    // ---------------- 显存域 125 MHz（读口：整条字幕从这里取回来）----------------
    input  wire        clk_mem,
    input  wire        rst_mem_n,
    output wire        mem_req,
    output wire [20:0] mem_base,
    output wire [20:0] mem_len,
    input  wire        mem_gnt,
    output wire        mem_next,
    input  wire        mem_dv,
    input  wire [31:0] mem_data,
    input  wire        mem_fin,

    // ---------------- ★ 字幕参数（接口留出来：以后由 C 的窗口表驱动）----------------
    input  wire        sub_on,      // 1 = 这条字幕要显示
    input  wire [11:0] sub_x0,      // 字幕左上角（屏幕坐标）
    input  wire [11:0] sub_y0,
    input  wire [11:0] sub_w,       // 契约固定 800
    input  wire [11:0] sub_h,       // 契约固定 64
    input  wire [20:0] sub_base,    // 字幕区基址 + 条号×1600
    input  wire [15:0] ink,         // bit=1 画这个颜色（默认 16'h0000 = 黑）
    // ★★★ 2026-10-15【功能 · 开关4（SW4 / C5）→ 字幕水平滚动】—— 使能（**电平**，不是脉冲）
    //   1 = 滚动（每帧把"取字/取位的列"偏移 +STEP）；0 = 不滚动且**帧首把偏移清 0** ⇒
    //   字幕立刻回到"改之前的静止原位"。
    //   ★ 由顶层 `top_m2` 的 `sw4` 经过同步（50 MHz 两级 + 像素域两级）后给进来 ——
    //     "拨到哪一侧是 1"见 `top_m2.v` 端口表那一段（约 65 行）。
    input  wire        scroll_en,
    // ★★★ 2026-10-09【一次性诊断开关】：=1 时**左半屏画"自产方块"、右半屏画真字幕**。
    //   上板看到"斜着的黑块"时，用它一句话分开：
    //     左半屏的方块**整齐** ⇒ 几何/位置/位序都对 ⇒ 问题在**字幕数据**（卡上的素材）；
    //     左半屏也歪/也斜 ⇒ 问题在**显示这一级**。
    input  wire        tpat_half,

    // ---------------- 诊断 ----------------
    output reg  [15:0] o_row_cnt,   // 取回整条字幕的次数（≈ 帧数）
    output reg         o_hit,       // sticky：真的画过（bit=1）至少一次
    // ★★★ 2026-10-09【决定性指纹】：取完一条之后在垂直消隐里把片上字幕 RAM 扫一遍
    //   o_sum16 = 1600 个字**求和**的低 16 位（对"位序 / 极性"敏感）
    //   o_nz    = **第一个非零字的下标**（对"行序 / 内容"敏感）+ o_nz_v 有效位
    //   ★ 电脑上按同一套规则（bit31=最左、黑=1、自下而上）算 SUB1.SUB 的期望值，
    //     和串口这两个数一比：**对上 ⇒ 片上数据是对的**（问题在显示级）；对不上 ⇒ 数据级。
    output reg  [15:0] o_sum16,
    output reg  [10:0] o_nz,
    //   ★★★ 2026-10-17【资源分配优化】：探针输出口 `o_dump_idx` / `o_dump_word`
    //     （2026-10-11 的"字幕 RAM 逐字倒出"）已从这里删除 —— 顶层已无消费者
    //     （串口字段 21/22/25 改送常量 0，帧格式/字段数一字未动）。它们的产生逻辑
    //     （`dp` 抓字指针、`dump_w`、每遍扫描的比对/发布）随下面那句注释一起删掉；
    //     ★ 保留的 o_sum16 / o_nz / o_nz_v（字幕指纹，字段 19/20）**一个字没动**。
    output reg         o_nz_v
);

    // ============================================================
    //  契约常数
    // ============================================================
    localparam integer SUB_WORDS = 1600;                 // 25 字/行 × 64 行
    localparam [11:0]  WPR       = 12'd25;               // 每行 25 个字
    localparam [10:0]  LAST_W    = 11'd1599;
    // ★★★ 2026-10-11【2 字补偿已撤】：原来这里多要 2 个字、丢掉头 2 个，是顶
    //   "块开头多出 2 个陈旧字"的（§27）。那个毛病现在在**读通路本身**修好了
    //   （`blk_rd_arb` 改成认官方 FIFO 的 valid ⇒ 丢空的 pop 不再被当成交付），
    //   所以这里必须回到 0，否则字幕会反过来整体左移 64 像素。
    localparam [11:0]  RD_EXTRA  = 12'd0;                // 多要几个字（= 要丢的那几个）
    localparam [20:0]  WLEN      = 21'd1600;             // 一共取回多少字
    localparam [11:0]  RD_SKIP   = 12'd0;                // 丢掉本趟收到的头几个字

    // ============================================================
    //  ★★★ 2026-10-15【字幕带洗淡】—— 把"字幕占据的那 64 行横带"上的**底图**往
    //     **白**的方向洗淡（让黑字更好认）；**字幕文字本身 / 位置 / 大小 / 时序一概不动**。
    //  ------------------------------------------------------------
    //  作用范围（两条边界都是"与"，越界一个像素都不碰）：
    //     · 竖直：遮罩那 64 行 —— y ∈ [sub_y0, sub_y0+sub_h)
    //     · 水平：**整行**（0..799，不看 x）⇒ 天然是一条横带（不是只洗有字的地方）
    //     · 再与 de_1 相与 ⇒ **消隐期/非显示区一个像素都不算**（y 以 de 内的行计数为准）
    //     · 再与 sub_on 相与 ⇒ 字幕没装/不显示时，整帧原样透传
    //  ------------------------------------------------------------
    //  算法（逐通道，**纯移位 + 加法，绝不引乘法器**）：
    //        out = img + ((max - img) >> K)        max = 31(R/B) / 63(G)
    //      ★ max ≥ img 恒成立（两者都是 5/6 位无符号）⇒ 减法不下溢、加法不溢出
    //        ⇒ **不需要饱和逻辑**（K=1 时 out 最大 31/63，正好是满白）
    //      ★ 为什么在 RGB565 上做：这一级（px_1/px_out）**就是 565**，
    //        565→888 的展开在 disp_top 里、是这一级的下一站（见像素级注释）。
    //        在 565 上洗 = 每通道 5/6 位；在 888 上洗 = 每通道 8 位 ⇒ 白白多花 LUT。
    //  ------------------------------------------------------------
    //  ★★ 档位：**只改下面这一行 SUB_FADE_SEL**。★ 注意方向：**数字越小洗得越狠**
    //     （1 = 混白 1/2 最白 ⇒ 黑字最醒目；数字越大越含蓄；0 = 整个功能关掉）：
    //        0 = 关（整帧一个像素都不变）
    //        1 = 混白 1/2    ← **默认（最强的一档 · 明显但不刺眼）**
    //        2 = 混白 1/4
    //        3 = 混白 1/8
    //        4 = 混白 1/16
    //        ≥5 = 混白 1/32（几乎看不出来）
    //     ★ 想比 1/2 还白（比如 3/4）就得改算式（`>>K` 换成两次混合），当前不需要。
    // ============================================================
    localparam [2:0]  SUB_FADE_SEL = 3'd1;               // ★★ 就是这一行（0=关 1=1/2最白 2=1/4 3=1/8 4=1/16）
    localparam        SUB_FADE_ON  = (SUB_FADE_SEL != 3'd0);
    localparam integer SUB_FADE_K  = (SUB_FADE_SEL == 3'd1) ? 1 :
                                     (SUB_FADE_SEL == 3'd2) ? 2 :
                                     (SUB_FADE_SEL == 3'd3) ? 3 :
                                     (SUB_FADE_SEL == 3'd4) ? 4 : 5;

    // ★★★ 2026-10-15【备选解释 · 字幕"文字"本身洗淡】—— 默认 **关**（0）。
    //   若你要的其实是"**字**变淡"（黑字→灰字），把这一行改成 3'd1/2/3/4（档位同上）。
    //   ★ 它是"文字颜色往白洗"，与上面的"底图带子往白洗"**互相独立**，可以只开一个、
    //     也可以两个都开（两个都开 = 带子发白 + 字发灰，字反而可能更难认，慎用）。
    //   ★ SUB_INK_FADE_SEL = 0 时，下面那套 ink 洗淡的组合逻辑被**常数传播全部消掉**
    //     （`ink_use` 恒等于 `ink`），不多一个门。
    localparam [2:0]  SUB_INK_FADE_SEL = 3'd0;           // ★★ 0=文字颜色不变（默认）1..4=文字洗淡
    localparam        SUB_INK_FADE_ON  = (SUB_INK_FADE_SEL != 3'd0);
    localparam integer SUB_INK_FADE_K  = (SUB_INK_FADE_SEL == 3'd1) ? 1 :
                                         (SUB_INK_FADE_SEL == 3'd2) ? 2 :
                                         (SUB_INK_FADE_SEL == 3'd3) ? 3 :
                                         (SUB_INK_FADE_SEL == 3'd4) ? 4 : 5;

    // ============================================================
    //  ★★★ 2026-10-15【功能 · 开关4 → 字幕水平滚动】
    //  ------------------------------------------------------------
    //  需求（用户原话）："按下开关4后，字幕水平滚动"。
    //  做法（**只偏移"取位下标"**，别的什么都不动）：
    //     · 一个"每帧 +STEP"的水平偏移 `scroll_x`（0..799，按 800 回绕）；
    //     · 取字号用 `col_eff = (col + scroll_x) % 800`（行内回绕，"加完 ≥800 就减 800"）；
    //     · **行号、字幕位置、遮罩内容、SDRAM 取数、洗淡带子全部一个比特都没动**。
    //  ★ `scroll_en = 0` ⇒ `scroll_x` 在**帧首**被清 0 ⇒ 与"加这个功能之前"逐比特一致。
    //  ★ 三个旋钮就在下面三行（速度 / 方向 / 总开关），别的地方都不用改。
    //  ------------------------------------------------------------
    //  ★ 为什么"帧首清 0"而不是"停在半路"（这是刻意选的）：
    //     验收要求"拨回去 ⇒ 立刻回到静止**且位置与改之前逐像素一致**"；
    //     若停半路，字就永久停在一个偏移上（虽然再拨开时不会跳），但那不符合本条验收。
    //     而且清 0 只发生在 vs 上升沿（帧与帧之间）⇒ 不会撕画面。
    // ============================================================
    localparam        SCROLL_FEAT_ON = 1'b1;    // ★★ 总开关：0 = 整个功能从综合里消失（回到与今天**逐比特一致**的旧逻辑）
    localparam integer SCROLL_STEP   = 1;       // ★★ 速度：每帧走几个像素（1 像素/帧 @60 Hz ≈ 60 px/s）
    localparam        SCROLL_LEFT    = 1'b1;    // ★★ 方向：1 = 字幕向左跑（scroll_x 每帧 +STEP）；0 = 向右跑
    localparam [9:0]  SCROLL_STEP_U  = SCROLL_STEP;               // STEP 的 10 位形式（STEP 必须是 ≥1 的整数）
    localparam [9:0]  SCROLL_LIM_UP  = 10'd800 - SCROLL_STEP_U;   // 向上回绕阈值（STEP=1 ⇒ 799 ⇒ 正好遍历 0..799）
    localparam [9:0]  SCROLL_LIM_DN  = SCROLL_STEP_U;             // 向下回绕阈值

    // ============================================================
    //  片上字幕 RAM（1600×32 = 51,200 比特）
    //    ★ 形状 = line_buf 那一套：clk_mem 写、clk_pix 寄存读 ⇒ TD 会布成 BRAM
    // ============================================================
    reg [31:0] cmem [0:SUB_WORDS-1];

    // ============================================================
    //  一、取字侧（clk_mem）：每帧把整条字幕取回来
    //     触发 = 像素域每帧翻一次 toggle（跨域用 toggle，不用脉冲）
    // ============================================================
    reg        vs_d;
    reg        fetch_tgl;        // 像素域：每帧翻一次
    reg        ft1, ft2, ft3;    // 显存域：三级同步 + 检边沿
    wire       fetch_start = ft2 ^ ft3;
    reg        fetch_done_tgl;   // ★ 显存域：每次取完一条翻一次（给像素域做自检扫描用）

    // ★★★ 2026-10-15【字幕水平滚动 · 帧首信号到底用哪一根】
    //   `vs_rise` = vs 的**上升沿**，`vs_d` 就是上面那个"打了一拍"的 vs
    //   ⇒ 宽度**正好一个 clk_pix**、**一帧只出现一次**（判据与下面 `fetch_tgl` 那一行完全相同，
    //     那一行是已经在板上跑通的"每帧取一次整条字幕"的触发）。
    //   ★ 这是本功能**唯一**的"每帧一次"信号：绝不用电平（那就是每拍都加，飞快）、
    //     绝不用组合中间量（可能一帧抖出多个脉冲，那就一帧加好几次）。
    //   ★ 它落在**垂直消隐**里（video_timing：v_cnt 数到 VPORCH+pic_high 才起 vsync）
    //     ⇒ 偏移量只在"帧与帧之间"改，**帧内一个像素都不变** ⇒ 不会撕画面。
    wire       vs_rise = vs_in & ~vs_d;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            vs_d      <= 1'b0;
            fetch_tgl <= 1'b0;
        end
        else begin
            vs_d <= vs_in;
            // ★ 每帧开头（vs 上升沿）且这条字幕要显示 ⇒ 翻一次，让显存域去取
            if (sub_on && vs_in && !vs_d) fetch_tgl <= ~fetch_tgl;
        end
    end

    // ============================================================
    //  ★★★ 2026-10-15【功能 · 开关4（SW4/C5）→ 字幕水平滚动】—— 偏移量生成（像素域）
    // ------------------------------------------------------------
    //  这里只干一件事：维护"每帧 +STEP、按 800 回绕"的水平偏移 `scroll_x`（0..799）。
    //     · `scroll_x` 的语义：**屏幕第 0 列去看遮罩的第 scroll_x 列**（见下面取位那一段）；
    //       ⇒ scroll_x 每帧 +1 时，遮罩内容看起来**向左跑**一个像素（跑马灯）。
    //     · 开（`scroll_en`=1）：帧首 +STEP；到 800-STEP 就回 0（STEP=1 时是 0..799 全遍历，
    //       **不跳一个、不重一个**）。
    //     · 关（`scroll_en`=0）：**帧首清 0** ⇒ 下一帧起就是静止原位（选"清 0"的理由见文件上面
    //       那段 localparam 注释）；清 0 也只发生在帧首 ⇒ 关的那一瞬间画面不撕。
    //   ★ 为什么不需要 `sw_edge_debounce` / 专门的边沿模块：
    //     ① 触发就用 `vs_rise`（本身已经是"一拍宽"的脉冲）；
    //     ② 开关的机械抖动（几十 µs~ms）**天然被滤掉**：`scroll_x` 一帧（16.6 ms）
    //        只在启用的那一拍"看"`scroll_en` 一眼 ⇒ 抖动最多让"开始/结束"差一帧，肉眼无感，
    //        而且**绝不会**在帧内把偏移改掉（那才会看到跳/撕裂）。
    // ============================================================
    wire       scroll_on = SCROLL_FEAT_ON & scroll_en;      // ★ 总开关=0 时恒 0 ⇒ 下面整块被常数传播消掉
    reg [9:0]  scroll_x;                                    // 0..799：屏幕第 0 列去看遮罩的第几列
    wire [9:0] sc_next = SCROLL_LEFT ? (scroll_x + SCROLL_STEP_U)
                                     : (scroll_x - SCROLL_STEP_U);
    wire       sc_wrap = SCROLL_LEFT ? (scroll_x >= SCROLL_LIM_UP)
                                     : (scroll_x <  SCROLL_LIM_DN);
    wire       sc_go   = scroll_on & ~sc_wrap;              // 1 = 这一帧真的走一格

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n)   scroll_x <= 10'd0;
        else if (vs_rise) scroll_x <= sc_go ? sc_next : 10'd0;   // ★ 关掉/走到头 ⇒ 清 0（静止原位）
    end

    localparam [1:0] F_IDLE = 2'd0, F_GNT = 2'd1, F_COLL = 2'd2;
    reg  [1:0]  fst;
    reg         m_req, m_next;
    reg  [10:0] wcnt;
    reg  [11:0] rcnt;            // ★ 本趟【收到】了几个字（含要丢掉的那 RD_SKIP 个）

    assign mem_req  = m_req;
    assign mem_base = sub_base;      // ★ 常数，直接给（顶层就是 SUB_BASE）
    assign mem_len  = WLEN;
    assign mem_next = m_next;

    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            fst       <= F_IDLE;
            m_req     <= 1'b0;
            m_next    <= 1'b0;
            wcnt      <= 11'd0;
            rcnt      <= 12'd0;
            ft1       <= 1'b0;
            ft2       <= 1'b0;
            ft3       <= 1'b0;
            o_row_cnt <= 16'd0;
            fetch_done_tgl <= 1'b0;
        end
        else begin
            ft1 <= fetch_tgl;  ft2 <= ft1;  ft3 <= ft2;      // toggle 三级同步
            case (fst)
            F_IDLE: begin
                m_next <= 1'b0;
                if (fetch_start) begin
                    m_req <= 1'b1;
                    wcnt  <= 11'd0;
                    rcnt  <= 12'd0;
                    fst   <= F_GNT;
                end
            end
            F_GNT: begin
                if (mem_gnt) begin
                    wcnt <= 11'd0;
                    rcnt <= 12'd0;
                    fst  <= F_COLL;
                end
            end
            F_COLL: begin
                // ★ 一直要字，直到 WLEN（= 1600 + RD_EXTRA）个字都到手
                m_next <= (rcnt < WLEN[11:0]);
                if (mem_dv && (rcnt < WLEN[11:0])) begin
                    rcnt <= rcnt + 12'd1;
                    // ★★★ 头 RD_SKIP 个字丢掉（那 2 个字是写通路"晚 2 个字"留下的）
                    if (rcnt >= RD_SKIP) begin
                        if (wcnt <= LAST_W) cmem[wcnt] <= mem_data;  // ★ 写侧（clk_mem）
                        wcnt <= wcnt + 11'd1;
                        if (wcnt == LAST_W) begin
                            if (o_row_cnt != 16'hFFFF) o_row_cnt <= o_row_cnt + 16'd1;
                        end
                    end
                end
                if ((rcnt >= WLEN[11:0]) || mem_fin) begin
                    m_req  <= 1'b0;
                    m_next <= 1'b0;
                    fst    <= F_IDLE;
                    fetch_done_tgl <= ~fetch_done_tgl;   // ★ 取完一条 ⇒ 通知像素域去自检
                end
            end
            default: fst <= F_IDLE;
            endcase
        end
    end

    // ============================================================
    //  二、读侧（clk_pix）：**提前一拍**算"下一个像素"的地址
    //     BRAM 的读必须寄存 ⇒ addr(T) 的数据在 T+1 有效，正好配 T+1 那个像素
    // ============================================================
    // ★★ 这里算的是**当前像素**所在的字（不是下一个像素的）：
    //    `mword_q` 是寄存读（这一拍给地址、下一拍出数据），而 `de_1/x_1/y_1/px_1`
    //    也是同一拍打进去的 ⇒ 下一拍"字"和"坐标"正好是**同一个像素** ✓。
    //    ★ 第一版把地址算成了"下一个像素"的那个字，于是**每 32 个像素就会错一个**
    //      （组边界上 x 和 x+1 落在不同的字里）—— 被 tb_subtitle_ovl 一把逮住。
    wire [11:0] sx_cur = x_in - sub_x0;
    wire [11:0] sy_cur = y_in - sub_y0;
    // ★ 行序自下而上：屏幕第 k 行用 SDRAM 第 (63-k) 行
    wire [11:0] row_cur = (sub_h - 12'd1) - sy_cur;
    // ------------------------------------------------------------------
    // ★★★ 2026-10-15【滚动 · 只改"行内第几列"，**行号一个比特都没动**】
    //     col_eff = (sx_cur + scroll_x) % 800
    //   实现就是"**加完 ≥800 就减一次 800**"（一次比较 + 一次减法），没有别的花活：
    //     · **11 位**加法：矩形内 sx_cur ≤ 799、scroll_x ≤ 799 ⇒ 和 ≤ 1598，11 位正好装下
    //       （10 位会溢出！1598 > 1023）；
    //     · 800 = 512+256+32 ⇒ **低 5 位是 0** ⇒ 回绕**不改低 5 位**
    //       ⇒ 下面像素级那一拍要的"位号"直接用 `scol_sum[4:0]`；
    //         只有"行内第几个字"（[9:5]）需要过那次减法+选择 ⇒ 省掉一半的门。
    //     · 矩形外（消隐里 x 一直数到 1055）算出来是什么都**画不到**（像素级的 in_rect_1 挡着），
    //       所以这里的截断/越界都不影响屏上任何一个像素。
    //   ★ 行号 `row_cur` / `row_x25` 一个字符都没改 ⇒ 字幕的**竖直位置不受本功能影响**。
    // ------------------------------------------------------------------
    wire [10:0] scol_sum = {1'b0, sx_cur[9:0]} + {1'b0, scroll_x};
    // "和 ≥ 800" 的判据（对 11 位和逐段展开，比摆一个 11 位减法器省门）：
    //   [10]=1 ⇒ ≥1024 ✓；否则要 [9]=[8]=1（≥768）且 [7:0]≥32（即 [7]|[6]|[5]）
    wire        scol_ge  = scol_sum[10] |
                           (scol_sum[9] & scol_sum[8] & (scol_sum[7] | scol_sum[6] | scol_sum[5]));
    wire [10:0] scol_sub = scol_sum - 11'd800;      // 只有 [9:5] 会被用到（低 5 位恒等于 scol_sum[4:0]）
    wire [4:0]  scol_word = SCROLL_FEAT_ON ? (scol_ge ? scol_sub[9:5] : scol_sum[9:5])
                                           : sx_cur[9:5];   // ★ 总开关=0 ⇒ 逐比特回到旧写法
    // 字地址 = 行×25 + 行内第几个字   （×25 用移位相加，别找工具要乘法器）
    wire [11:0] row_x25 = (row_cur << 4) + (row_cur << 3) + row_cur;
    wire [11:0] widx_raw = row_x25 + {7'd0, scol_word};
    wire [10:0] widx    = (widx_raw < 12'd1600) ? widx_raw[10:0] : 11'd0;   // 越界就指 0

    // ★★ 2026-10-09：这唯一的读口现在由【显示】和【自检扫描】分时共用
    reg  [31:0] rd_q;                // 唯一读口的输出寄存器（显示用的字就是它）
    reg  [11:0] sc_idx;
    reg         sc_run;
    reg  [31:0] sc_sum;
    reg         sc_nz_v;
    reg  [10:0] sc_nz;
    // ★★★ 2026-10-17【资源分配优化】：`dp`（抓字指针）与 `dump_w`（抓到的字）
    //   随 o_dump_idx/o_dump_word 端口一起删除 —— 它们只服务那个探针，无其他消费者。
    reg         fd1, fd2, fd3;       // clk_mem 的"取完了"toggle → 像素域三级同步
    wire [10:0] rd_addr = sc_run ? ((sc_idx > 12'd1599) ? 11'd1599 : sc_idx[10:0])
                                 : widx;
    reg         de_1, vs_1;
    reg  [11:0] x_1, y_1;
    reg  [15:0] px_1;
    // ★★★ 2026-10-15【滚动】跟 `rd_q` / `x_1` **同一拍**打过来的"偏移后的列"的低 5 位
    //   （= col_eff mod 32 = 位号用到的那个数）。用寄存器扛一拍，比在像素级再摆一个
    //   5 位加法器省 5 个 LUT（FF 还有一半空的：9634/19600）。
    reg  [4:0]  col_lo_1;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            rd_q <= 32'd0;
            de_1 <= 1'b0; vs_1 <= 1'b0; x_1 <= 12'd0; y_1 <= 12'd0; px_1 <= 16'd0;
            col_lo_1 <= 5'd0;
            sc_idx <= 12'd0; sc_run <= 1'b0; sc_sum <= 32'd0;
            sc_nz_v <= 1'b0; sc_nz <= 11'd0;
            // ★★★ 2026-10-17【资源分配优化】：原 `dp/dump_w` 复位随探针一起删
            fd1 <= 1'b0; fd2 <= 1'b0; fd3 <= 1'b0;
            o_sum16 <= 16'd0; o_nz <= 11'd0; o_nz_v <= 1'b0;
        end
        else begin
            rd_q <= cmem[rd_addr];                   // ★ 读侧（clk_pix，寄存读 = BRAM 形状）
            // ★ 这一拍给的是"当前像素（x_in）"的偏移后列低 5 位 ⇒ 下一拍正好配 x_1/px_1/rd_q。
            //   `scol_sum` 用的是 x_in 那一套坐标，和 `widx` **同一拍、同一个像素**（见上面 ★★）。
            col_lo_1 <= scol_sum[4:0];
            de_1 <= de_in;  vs_1 <= vs_in;
            x_1  <= x_in;   y_1  <= y_in;
            px_1 <= px_in;

            // ---- 自检扫描：取完一条之后，趁垂直消隐把 1600 个字扫一遍 ----
            fd1 <= fetch_done_tgl; fd2 <= fd1; fd3 <= fd2;
            if (!sc_run && (fd2 ^ fd3)) begin
                sc_run <= 1'b1;
                sc_idx <= 12'd0;
                sc_sum <= 32'd0;
                sc_nz_v <= 1'b0;
            end
            else if (sc_run) begin
                // rd_q 这一刻是上一拍地址（= sc_idx-1）那个字
                if (sc_idx >= 12'd1) begin
                    sc_sum <= sc_sum + rd_q;
                    if (!sc_nz_v && (rd_q != 32'd0)) begin
                        sc_nz_v <= 1'b1;
                        sc_nz   <= sc_idx - 12'd1;
                    end
                    // ★★★ 2026-10-17【资源分配优化】：
                    //   原这里还有一句"正好走到第 dp 个字 ⇒ dump_w <= rd_q"（逐字倒出探针的
                    //   抓字比对）。探针已删 ⇒ 该比对连 12 位比较器一起删掉。
                    //   ★ 扫描本身一个字没动：sc_sum / sc_nz 照旧（字段 19/20 的生产者）。
                end
                if (sc_idx >= 12'd1600) begin
                    sc_run  <= 1'b0;
                    o_sum16 <= sc_sum[15:0];
                    o_nz    <= sc_nz;
                    o_nz_v  <= sc_nz_v;
                    // ★★★ 2026-10-17【资源分配优化】：原这里发布 dp 指向的那个字并把 dp+1
                    //   （o_dump_idx/o_dump_word）。探针已删 ⇒ dp 计数器一并删除。
                end
                else sc_idx <= sc_idx + 12'd1;
            end
        end
    end

    // ============================================================
    //  三、像素级（第 2 拍）：拿"这一拍的字 + 这一拍的坐标"取位
    //     bit = 31 - ((x-x0) mod 32)；1 → 画 ink，0 → 透传
    // ============================================================
    wire [11:0] sx_1  = x_1 - sub_x0;
    wire [11:0] sy_1  = y_1 - sub_y0;
    wire in_rect_1 = sub_on && de_1
                  && (x_1 >= sub_x0) && (x_1 < (sub_x0 + sub_w))
                  && (y_1 >= sub_y0) && (y_1 < (sub_y0 + sub_h));
    // ★★ 2026-10-15【滚动】：位号用"**偏移后**的列"的低 5 位（= col_eff mod 32）。
    //   ★ 800 是 32 的整数倍 ⇒ 那个 "%800 回绕"**不会改低 5 位** ⇒ 直接用 stage-1 算好、
    //     跟 `rd_q`/`x_1` 一起打过来的 `col_lo_1`（等于"再摆一个 5 位加法器"的结果，
    //     但省 5 个 LUT）。★ 总开关=0 时退回原来的 `sx_1[4:0]`（常数传播，不花门）。
    wire [4:0] col_eff_lo = SCROLL_FEAT_ON ? col_lo_1 : sx_1[4:0];
    // ★ 用"右移"取位，不用非常量位选（老工具对那种写法挑）
    wire ink_bit_1 = ((rd_q >> (5'd31 - col_eff_lo)) & 32'd1) == 32'd1;
    // ★ 自产方块（8×8 棋盘）：只在左半屏用它，用来和"真字幕"对照
    wire tpat_bit_1 = sx_1[3] ^ y_1[3];
    wire use_tpat   = tpat_half && (sx_1 < (sub_w >> 1));
    wire ink_draw   = use_tpat ? tpat_bit_1 : ink_bit_1;

    // ============================================================
    //  ★★★ 2026-10-15【字幕带洗淡】组合逻辑（全部在 clk_pix 域、纯移位/加法）
    //  ------------------------------------------------------------
    //  ① 横带判定 `band_1`：**只看 y，不看 x**（⇒ 整行同宽，是真"一条横带"）。
    //     · `sy_1` 就是上面算好的 (y_1 - sub_y0)，直接复用，不新加减法；
    //     · `sy_1 < sub_h` 天然把"行号 ≥ 64"的排掉（y_1 < sub_y0 时无符号回绕成
    //       很大的数 ⇒ 也是 false），再加 (y_1 >= sub_y0) 明写一遍 ⇒ 边界绝对精确。
    //     · `de_1` ⇒ 消隐期不算（de 只在 800×600 内为 1，见 video_timing）；
    //       `sub_on` ⇒ 没装字幕时整帧透传。
    //  ② 往白洗淡 `px_fade`：out = img + ((max - img) >> K)，**逐通道 R/G/B 各一套**。
    //     ★ 位宽：5 位(R) / 6 位(G) / 5 位(B)，结果恒 ≤ max ⇒ 不会溢出、不用饱和。
    //  ③ 备选 `ink_use`：文字颜色往白洗（SUB_INK_FADE_SEL=0 时恒等于 ink，被综合消掉）。
    //  ------------------------------------------------------------
    //  ★ 注意：这里**不动**遮罩取数/解码/位置/大小，也不动 ink_draw 的判据 ——
    //    "哪一像素是字"仍然是原来那一套；我们只改"不是字"的那些像素的颜色。
    // ============================================================
    wire band_1 = de_1 && sub_on && (y_1 >= sub_y0) && (sy_1 < sub_h);

    //  —— 每个中间量都写明位宽（5/6/5）：老工具就不会纠结"加法的上下文位宽" ——
    //  ②a "离满白还差多少" = max - img。
    //     ★ 省 LUT 的写法（**不是**"取反"那个语义，是恒等式）：满量程 max 全是 1
    //       （31 = 5'b11111 / 63 = 6'b111111；换成 888 就是 255）⇒ **max - img ≡ ~img**。
    //       例：img=20 ⇒ 31-20 = 11 = ~5'd20 ✓。写成 ~img 就不会再摆一套减法器。
    wire [4:0] fr_d = ~px_1[15:11];
    wire [5:0] fg_d = ~px_1[10:5];
    wire [4:0] fb_d = ~px_1[4:0];
    //  ②b 洗淡后的三个通道（R/B 满量程 31、G 满量程 63 ⇒ 结果恒 ≤ max，正好落在 5/6 位里）
    wire [4:0] fr_f = px_1[15:11] + (fr_d >> SUB_FADE_K);
    wire [5:0] fg_f = px_1[10:5]  + (fg_d >> SUB_FADE_K);
    wire [4:0] fb_f = px_1[4:0]   + (fb_d >> SUB_FADE_K);
    wire [15:0] px_fade = {fr_f, fg_f, fb_f};

    //  ③ 备选：文字颜色往白洗（SUB_INK_FADE_SEL=0 时 `ink_use` 恒 = `ink`，下面全被消掉）
    wire [4:0] kr_d = ~ink[15:11];
    wire [5:0] kg_d = ~ink[10:5];
    wire [4:0] kb_d = ~ink[4:0];
    wire [4:0] kr_f = ink[15:11] + (kr_d >> SUB_INK_FADE_K);
    wire [5:0] kg_f = ink[10:5]  + (kg_d >> SUB_INK_FADE_K);
    wire [4:0] kb_f = ink[4:0]   + (kb_d >> SUB_INK_FADE_K);
    wire [15:0] ink_use = SUB_INK_FADE_ON ? {kr_f, kg_f, kb_f} : ink;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            px_out <= 16'h0000;
            de_out <= 1'b0;
            vs_out <= 1'b0;
            o_hit  <= 1'b0;
        end
        else begin
            de_out <= de_1;                       // ★ de/vs 和像素一起打第二拍，绝不拆开
            vs_out <= vs_1;
            if (in_rect_1 && ink_draw) begin
                px_out <= ink_use;                // bit=1 → 画（黑 = 字；备选档才洗文字）
                o_hit  <= 1'b1;
            end
            else if (SUB_FADE_ON && band_1) begin
                px_out <= px_fade;                // ★★★ 2026-10-15 字幕带上的底图：往白洗淡
            end
            else begin
                px_out <= px_1;                   // bit=0（或不在字幕带里）→ 透传
            end
        end
    end

endmodule
