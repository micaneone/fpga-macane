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
    parameter integer AUTO_START    = 1        // 0 = 上电不自动装（只等 key1）
                                               //   ★ B 自测图模式要设 0，
                                               //     否则 A 会把自测图覆盖掉
)(
    input  wire        clk,
    input  wire        rst_n,          // 引脚复位（硬复位）
    input  wire        key1,           // 低有效
    input  wire        key2,           // 低有效
    input  wire        sd_ready,       // A：SD 卡初始化完成
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
    output reg         soft_rst        // 1 = 请全设计软复位
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
        else if (k2_press) begin
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
        end
        else begin
            a_start <= 1'b0;                       // 默认不给脉冲

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
            if (sd_ready && !tr_active && !req_pend && !hold) begin
                if (AUTO_START && !auto_fired && (auto_cnt >= AUTO_TICKS[31:0])) begin
                    req_pend   <= 1'b1;
                    req_tgl    <= ~req_tgl;
                    fx_sel     <= 2'd0;                    // 上电第一张：划像
                    auto_fired <= 1'b1;
                end
                else if (k1_press) begin
                    req_pend <= 1'b1;
                    req_tgl  <= ~req_tgl;
                    // 每换一张轮换一种特效：划像 → 百叶窗 → 交叉淡化 → 划像…
                    // ★ 板上只剩三个可用按键，特效就按"第几张"自动轮 —— 三种都看得到。
                    fx_sel   <= (fx_sel == 2'd2) ? 2'd0 : (fx_sel + 2'd1);
                end
            end

            // ============================================================
            //  ② 真的开始装载 —— 必须等转场说"屏上已经全米白"
            // ============================================================
            if (may_load && req_pend && !a_busy && !hold) begin
                a_start  <= 1'b1;
                a_skip   <= next_no[3:0];
                a_img_no <= next_no + 8'd1;
                next_no  <= next_no + 8'd1;
                req_pend <= 1'b0;
            end
        end
    end

    // 槽位：由顶层按"非前台那个槽"给（见文件头）
    assign a_use_slot  = slot_in;
    assign a_slot_base = (slot_in == 3'd1) ? SLOT1_BASE[20:0] : SLOT_BASE[20:0];

    // ★ 探针：把消抖后的 KEY3 脉冲引出去（串口报告数它 → 判断"键到底有没有被看到"）
    assign k1_press_o = k1_press;
    assign req_pend_o = req_pend;

endmodule
