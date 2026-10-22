// ============================================================
//  模块名 : stub_ctrl（测试件，不进交付仓库）
//  作用   : 假装是 C —— 用按键驱动 A 的装载机
// ------------------------------------------------------------
//  按键约定（板子上的丝印是 key1~key4，没有 key0）：
//    key1（B2）：装载 / 换下一张 —— 每次按就 `start` 一次，同时 skip+1
//    key2（C1）：软复位重来 —— 整块设计复位约 5 ms，然后自动重装第 1 张
//    （硬复位还是 A2 那个 rst_n）
//
//  ★ 上电自动装第一张：SD 卡初始化完成后等 100 ms 自动 start 一次，
//    这样上板"什么都不按也能出图" —— 少一个要怀疑的环节。
//
//  ★ 软复位的做法：本模块里那个"发号器"只受【引脚复位】控制，
//    不受自己产生的 soft_rst 影响；其余逻辑吃的是 rst_n & ~soft_rst。
//    否则会出现"复位把自己也复了 → soft_rst 自己掉下来"的死循环。
//
//  ★★ 2026-10-03（转场前置 ⑥）：**交替使用两个大槽**。
//    每装一张换一个槽（槽 0 基址 0 / 槽 1 基址 930830），这样：
//      · 能上板验证"大槽 1 读得干净"（= 绝对 4 字对齐那一刀的上板证据）；
//      · 转场要的"前台 / 后台"两份源图，这就是它的雏形。
//    ★ 槽号在**发起装载那一拍**和 a_skip / a_img_no 一起寄存 ——
//      否则 next_no 已经自增，装载中途槽号会跳。
//    （显示那边要知道"该显示哪个槽"：top_m2 里改成取 img_no 更大的那个有效槽。）
//
//  ★★★ 2026-10-08【预装 prefetch】：让按键"只翻前台"。
//    问题：按键到看见新图 = 装载(0.3~1.8s) + 转场(0.27s)，前一段屏上一直是旧图，
//          用户感知到的"按下去没反应"就是它。
//    做法：**在 IDLE 期间就把"下一张"偷偷装进后台槽**（不翻 req_tgl、不转场）。
//          等用户真按键时后台槽里已经是新图 ⇒ 像素域的 transition_ctrl 走"快速路"
//          跳过 LOAD、直接进 FX ⇒ 转场立刻开始。
//    ★ 纯加法：后台没就绪（手快 / 上电第一张）就走**原来的 LOAD 老路**，
//      最坏情况 = 今天的 RC1。
//    ★ 回退：把 `pf_go` 接 0（或 `pf_armed` 恒 0）就回到 RC1 行为。
//    ★ 三个必须处理的竞态（见 规划\B轨待改清单.md §23.4）：
//      ① 预装的 a_start 和音频自检的 aud_load_pulse 撞拍 → `pf_go` 挡住；
//      ② swap 之后 a_slot_use 还有两拍是旧值 → `pf_settle` + `need_load` 挡住；
//      ③ 上电前台槽是空的（valid=0）→ `pf_armed` 挡住。
// ============================================================
`timescale 1ns / 1ps

module stub_ctrl #(
    parameter integer CLK_HZ        = 50_000_000,
    parameter integer AUTO_DELAY_MS = 100,     // SD 就绪后等多久自动装第一张
    parameter integer RST_HOLD_MS   = 5,       // 软复位按住多久
    parameter integer SLOT_BASE     = 0,       // 今晚固定大槽 0
    parameter integer USE_SLOT      = 0,
    // ★ 2026-10-03：跟着契约 v8 改 —— 大槽 0 补到 930,832 字，让大槽 1 的基址是 4 的倍数。
    //   原因（上板实测）：那颗 SDRAM 核"4 字一包"的分组**读写都认**，写侧没法补对齐，
    //   所以槽基址本身必须 4 对齐；否则写进大槽 1 的图会"每隔几列一小条"（竖条错位）。
    parameter integer SLOT1_BASE    = 930832,  // 大槽 1（转场要用的后台槽）
    parameter integer AUTO_START    = 1,       // 0 = 上电不自动装（只等 key1）
                                               //   ★ B 自测图模式要设 0，
                                               //     否则 A 会把自测图覆盖掉
    // ★★★ 2026-10-17【自动轮播】：卡上根目录里 .BMP 的**条数**，轮播数到第 IMG_N 张
    //   之后回绕到第 0 张。素材变了只改这一个参数。
    //   ★ 为什么要回绕：轮播会一直自己跑，`skip` 一旦超过卡上图片数，`find_bmp` 就查不到
    //     文件 ⇒ `a_fail` ⇒ 音频链一起停住（以前手动多按几次也是同一个坑）。
    parameter integer IMG_N         = 5
)(
    input  wire        clk,
    input  wire        rst_n,          // 引脚复位（硬复位）
    input  wire        key1,           // 低有效
    input  wire        key2,           // 低有效
    // ★★★ 2026-10-17【KEY3 改自动轮播】：顶层产生的"换下一张"请求（单拍脉冲）。
    //   和按键 `key1` 的消抖脉冲**同一个语义、同一条路**（下面 `adv_take` 把它们或起来）。
    //   顶层已经用 `!a_busy & !tr_active & !req_pend` 把脉冲挡在空闲窗口里，
    //   所以这里不需要额外判据 —— 落进来的脉冲一律按"换下一张"处理。
    //   ★ 按键那条路照旧保留（本模块内部一个字没删），只是顶层不再喂按键了。
    input  wire        adv_req,
    // ★ 2026-10-21【报警换图】：为 1 时**不走预装的快速路**，强制真去 SD 装一次。
    //   为什么需要：轮播靠后台槽预装「下一张」，受理请求时 need_load 会变 0
    //   ⇒ 转场直接拿后台槽那张老图，看起来就是"没换图"。报警要的是指定名字的图，
    //   后台槽里永远不会有它，必须强制真装载。和 adv_req 同拍有效。
    input  wire        force_load,
    input  wire        sd_ready,       // A：SD 卡初始化完成
    input  wire        sd_lost_i,      // ★ 2026-10-22：确认拔卡的单拍脉冲 ⇒ 触发一次整块软复位
    input  wire        alert_rst_i,    // ★ 2026-10-22：收到报警（SW4 上升沿）的单拍脉冲 ⇒ 同一套整块软复位
    input  wire        a_busy,         // A：正在装载（装载期间不再触发）
    input  wire        hold,           // 1 = 别触发（B 自测图正在写大槽 0）

    // ---- ★★ 2026-10-03（转场 ④）新增：和 transition_ctrl 打交道 ----
    //  触发被拆成【两段】，中间隔着一次转场：
    //    ① 收到请求（按键/上电自动）→ 翻 req_tgl 告诉像素域"开始转场"
    //    ② 等 may_load=1（屏上已经全米白）→ 这时才真的 a_start 去装
    //  ★ 为什么不能像以前那样"按下就直接装"：装的时候要写 SDRAM，
    //    而屏上那 0.9 秒还在读旧图 —— 读写一旦重叠，读出来的就是错的。
    input  wire        may_load,       // ← 转场：屏上全米白，可以去写 SDRAM 了
    input  wire        tr_active,      // ← 转场进行中（期间不接受新的换图请求）
    input  wire [2:0]  slot_in,        // ← 顶层：这一张装哪个槽（= 非前台那个）
    output reg         req_tgl,        // → 像素域：翻一次 = 请开始一次转场
    output reg  [1:0]  fx_sel,         // → 像素域：这次淡入用哪种特效
    output wire        k1_press_o,     // ★ 探针：消抖后的 KEY3 按下脉冲（给串口报告数）
    output wire        req_pend_o,     // ★ 探针：1 = 已经请求了转场、正等 A 装完

    output reg         a_start,        // 一拍脉冲：开始装一张
    output reg  [3:0]  a_skip,         // 第几张 BMP（0 = 第一个）
    output wire [2:0]  a_use_slot,
    output wire [20:0] a_slot_base,
    output reg  [7:0]  a_img_no,       // 图片序号（写进描述符）
    output reg         soft_rst,       // 1 = 请全设计软复位

    // ---- ★★★ 2026-10-08【预装 prefetch】新增四根 ----
    input  wire        pf_go,          // ← 顶层：允许预装（音频自检做完 / 音频关掉）
    input  wire        a_load_done,    // ← 顶层：A 装完一整张图（单拍）
    output wire        pf_ready_o,     // → 顶层：后台槽已装好"下一张"（电平）
    output wire        req_accept_o    // → 顶层：本次请求被受理（单拍，音效挂它）
);

    // ============================================================
    //  按键消抖（用官方那一套 key_press_debounce，别自己另写）
    //  ★ 它的 rst 是高有效；默认 CLK_FREQ_HZ 是 100MHz，我们得填 50MHz
    // ============================================================
    wire k1_press, k2_press;

    key_press_debounce #(.CLK_FREQ_HZ(CLK_HZ), .DEBOUNCE_MS(20)) u_k1 (
        .clk(clk), .rst(~rst_n), .button_in(key1), .press_pulse(k1_press)
    );

    key_press_debounce #(.CLK_FREQ_HZ(CLK_HZ), .DEBOUNCE_MS(20)) u_k2 (
        .clk(clk), .rst(~rst_n), .button_in(key2), .press_pulse(k2_press)
    );

    // ★★★ 2026-10-17【KEY3 改自动轮播】：换图触发 = 按键消抖脉冲 或 轮播请求
    //   ★ 只在两处消费（`req_take` 的受理判据、受理分支里的特效轮换），
    //     下面的状态机其余部分**一个字没动**。
    wire adv_take = k1_press | adv_req;

    // ============================================================
    //  软复位发生器：只受引脚复位控制（见文件头那段说明）
    // ============================================================
    localparam integer RST_TICKS = (CLK_HZ / 1000) * RST_HOLD_MS;

    reg [31:0] rst_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            soft_rst <= 1'b0;
            rst_cnt  <= 32'd0;
        end
        else if (k2_press | sd_lost_i | alert_rst_i) begin   // ★ 确认拔卡 / 收到报警：走同一条软复位（整块，含菜单/串口状态/装载锁存）
            soft_rst <= 1'b1;
            rst_cnt  <= RST_TICKS[31:0];
        end
        else if (soft_rst) begin
            if (rst_cnt == 32'd0) soft_rst <= 1'b0;
            else                  rst_cnt  <= rst_cnt - 32'd1;
        end
    end

    // ============================================================
    //  其余逻辑：吃 rst_n & ~soft_rst
    // ============================================================
    wire ctl_rst_n = rst_n & ~soft_rst;

    localparam integer AUTO_TICKS = (CLK_HZ / 1000) * AUTO_DELAY_MS;

    reg [31:0] auto_cnt;
    reg        auto_fired;
    reg [7:0]  next_no;               // 下一张要装的序号（0 起）
    reg        req_pend;              // ★ 已经请求了转场、正等 may_load

    // ============================================================
    //  ★★★ 2026-10-08【预装 prefetch】新增状态
    // ------------------------------------------------------------
    //   pf_ready      后台槽里已经装好"下一张"（预装只提前一张）
    //   load_inflight 已发 a_start、还没等到 a_load_done
    //   need_load     本次**已受理**的请求还需要装吗（NO 就是走快速路）
    //   pf_armed      受理过一次请求之后才允许预装（挡住上电那一次，竞态 ③）
    //   pf_settle     转场结束后再等这么多拍才允许预装（竞态 ②）
    //   req_accept / tr_done  给顶层的那一拍脉冲
    // ============================================================
    reg        pf_ready;
    reg        load_inflight;
    reg        need_load;
    reg        pf_armed;
    reg [15:0] pf_settle;
    reg        req_accept;
    reg        tr_active_d;

    // 转场刚走完的那一拍（tr_active 是顶层给的 ac2，控制域）
    wire tr_done = tr_active_d & ~tr_active;
    // 64 拍 @50MHz = 1.28 µs：够像素域的 fs1/fs2 把新的 a_slot_use 交过来
    localparam [15:0] PF_SETTLE = 16'd64;

    // ★ 受理请求的那一拍（自动 / k1_press 共用；原代码是同一个外闸门包住的两个分支）
    //   ★ 比原来多一个 `!tr_done`：转场刚走完那一拍**不受理**新请求。
    //     为什么（别删）：swap 之后像素域已经回 IDLE、能受理 req，而控制域这边的
    //     fs2（a_slot_use）刚好在这一拍才翻过来 —— 若同拍受理，`need_load` 会按
    //     旧的 pf_ready 算成 0（= 不装），可后台槽其实已经换成旧图了 ⇒
    //     屏上会划一次"回到上一张"。多挡这一拍就没有这个窗口。
    //     （代价：恰好落在这一拍上的按键被丢掉 —— 和今天"转场期间按键被忽略"
    //       完全一致，本来就是这样。）
    wire req_take = sd_ready && !tr_active && !tr_done && !req_pend && !hold &&
                    ((AUTO_START && !auto_fired && (auto_cnt >= AUTO_TICKS[31:0]))
                     || adv_take);

    always @(posedge clk or negedge ctl_rst_n) begin
        if (!ctl_rst_n) begin
            auto_cnt   <= 32'd0;
            auto_fired <= 1'b0;
            next_no    <= 8'd0;
            a_start    <= 1'b0;
            a_skip     <= 4'd0;
            a_img_no   <= 8'd0;
            req_pend   <= 1'b0;
            req_tgl    <= 1'b0;
            fx_sel     <= 2'd0;
            pf_ready      <= 1'b0;
            load_inflight <= 1'b0;
            need_load     <= 1'b0;
            pf_armed      <= 1'b0;
            pf_settle     <= 16'd0;
            req_accept    <= 1'b0;
            tr_active_d   <= 1'b0;
        end
        else begin
            a_start    <= 1'b0;                    // 默认不给脉冲
            req_accept <= 1'b0;                    // 默认不给脉冲
            tr_active_d <= tr_active;

            // ---- 上电自动装第一张 ----
            if (!sd_ready) begin
                auto_cnt   <= 32'd0;
                auto_fired <= 1'b0;
            end
            // ★ 2026-09-28：hold（自测图正在写）期间【不要】让计时器把这次机会用掉，
            //   否则 auto_fired 会被置上而 a_start 从来没发出去 —— A 就永远不装图。
            else if (!auto_fired && !hold) begin
                if (auto_cnt >= AUTO_TICKS[31:0]) auto_fired <= 1'b1;
                else                               auto_cnt   <= auto_cnt + 32'd1;
            end

            // ============================================================
            //  ① 请求转场（自动一次 + 每次按 key1）
            //     ★ 转场进行中、或上一次请求还没被受理（req_pend）时不重复请求 ——
            //       连按 key3 不会插队，也不会一次按出两场转场。
            // ============================================================
            if (req_take) begin
                // ★★★ 预装：这一拍把"本次请求还需要装吗"定下来 ——
                //   后台槽已经装好了（pf_ready）或正在装（load_inflight）⇒ 不用装，
                //   像素域那边会走快速路直接进 FX。
                need_load <= ~(pf_ready | load_inflight) | force_load;
                // ★ 预装的门栓：受理过一次请求之后才允许预装（竞态 ③）
                pf_armed  <= 1'b1;
                // ★ 给顶层的一拍脉冲：音效挂它（按键那一下响，不是预装那一刻响）
                req_accept <= 1'b1;
                if (AUTO_START && !auto_fired && (auto_cnt >= AUTO_TICKS[31:0])) begin
                    req_pend   <= 1'b1;
                    req_tgl    <= ~req_tgl;
                    fx_sel     <= 2'd0;                    // 上电第一张：划像
                    auto_fired <= 1'b1;
                end
                else if (adv_take) begin
                    req_pend <= 1'b1;
                    req_tgl  <= ~req_tgl;
                    // 每换一张轮换一种特效：划像 → 百叶窗 → 交叉淡化 → 划像…
                    // ★ 板上只剩三个可用按键，特效就按"第几张"自动轮 —— 三种都看得到。
                    fx_sel   <= (fx_sel == 2'd2) ? 2'd0 : (fx_sel + 2'd1);
                end
            end

            // ============================================================
            //  ② 真的开始装载 —— 必须等转场说"屏上已经全米白"
            //     ★ 预装加了 `need_load`：快速路（后台已就绪）这一拍不装，
            //       否则会把**刚预装好的后台槽重装一遍**，而转场已经开始了
            //       ⇒ 屏上出现半张图（竞态 ②）。
            // ============================================================
            if (may_load && req_pend && need_load && !a_busy && !hold) begin
                a_start  <= 1'b1;
                a_skip   <= next_no[3:0];
                a_img_no <= next_no + 8'd1;
                next_no  <= (next_no == (IMG_N-1)) ? 8'd0 : (next_no + 8'd1);   // ★ 轮播回绕
                req_pend <= 1'b0;
                need_load <= 1'b0;
                load_inflight <= 1'b1;                 // ★ 预装：记下"有一张在路上"
            end

            // ============================================================
            //  ③ ★★★【预装】IDLE 期间把"下一张"偷偷装进后台槽
            //     · 和 ② 天然互斥（② 要 req_pend，③ 要 !req_pend）
            //     · pf_go 挡住"和音频自检的 aud_load_pulse 撞拍"（竞态 ①）
            //     · !tr_active + pf_settle 挡住 swap 之后那两拍（竞态 ②）
            //     · pf_armed 挡住上电那一次（竞态 ③）
            //     · 不翻 req_tgl、不发起转场 —— 屏上什么都不变，只是后台槽换人了
            // ============================================================
            if (pf_armed && pf_go && !pf_ready && !load_inflight && !req_pend
                && !a_busy && !hold && !tr_active && (pf_settle == 16'd0)) begin
                a_start       <= 1'b1;
                a_skip        <= next_no[3:0];
                a_img_no      <= next_no + 8'd1;
                next_no       <= (next_no == (IMG_N-1)) ? 8'd0 : (next_no + 8'd1);  // ★ 轮播回绕
                load_inflight <= 1'b1;
            end

            // ============================================================
            //  ④ 收尾（每拍）
            //     · A 装完一张（不管是谁让它装的）⇒ 后台槽里就是"下一张"了
            //     · 转场走完 ⇒ 前台/后台刚对调过，后台槽里又变回旧图 ⇒ pf_ready 清了；
            //       同时把这次换图彻底收尾（req_pend 归零），否则快速路下没人清
            //       req_pend，第 151 行那个闸门会永久关死 ⇒ 按一次之后就再也按不动。
            //     ★ 顺序要紧：这两段在 ① ② ③ 之后，靠"后写的赢"覆盖同拍的情况。
            // ============================================================
            if (a_load_done) begin
                load_inflight <= 1'b0;
                pf_ready      <= 1'b1;
            end
            if (tr_done) begin
                pf_ready      <= 1'b0;
                req_pend      <= 1'b0;
                need_load     <= 1'b0;
                // ★★★ 2026-10-21 晚【D3 · C1c】转场收尾时把"有一张在路上"也清掉。
                //   否则 A 被看门狗复位（`a_load_done` 永远不来）⇒ `load_inflight`
                //   恒 1 ⇒ `need_load` 恒 0 ⇒ ② 再也不会发 `a_start` ⇒ 死锁；
                //   而像素域 S_LOAD 还在等 `ver` 变 ⇒ 屏幕永远停在旧图。
                //   转场都结束了，这笔账已无意义（快速路线本来 load_inflight=0）。
                load_inflight <= 1'b0;
            end
            pf_settle <= tr_done              ? PF_SETTLE :
                         (pf_settle != 16'd0) ? (pf_settle - 16'd1) : 16'd0;
        end
    end

    // 槽位：由顶层按"非前台那个槽"给（见文件头）
    assign a_use_slot  = slot_in;
    assign a_slot_base = (slot_in == 3'd1) ? SLOT1_BASE[20:0] : SLOT_BASE[20:0];

    // ★ 探针：把消抖后的 KEY3 脉冲引出去（串口报告数它 → 判断"键到底有没有被看到"）
    assign k1_press_o = k1_press;
    assign req_pend_o = req_pend;

    // ★★★ 2026-10-08【预装】给顶层
    assign pf_ready_o   = pf_ready;
    assign req_accept_o = req_accept;

endmodule
