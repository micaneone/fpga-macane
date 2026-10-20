// ============================================================
//  模块名 : transition_ctrl
//  作用   : 【转场状态机】—— 什么时候淡出、什么时候放 A 去写、什么时候淡入
//  层次   : 像素流水第 ④ 级（转场的"指挥"），transition.v 是它手里的"混音器"
//  时钟域 : 像素域 40 MHz（用行场时序的 vs 数帧）
//  依据   : 规划\B轨待改清单.md §九（转场工作清单 ④）、M2交接.md（用户已认可的三步方案）
// ------------------------------------------------------------
//  ★★ 为什么要有这个模块（一句话）：**SDRAM 的读和写绝不能重叠**，
//     而"换图"必须写 SDRAM。所以换图必须排在"屏上不需要读 SDRAM"的那段时间里。
//     用户认可的三步：
//        ① 淡出：旧图 → 米白（这 0.3 秒里读的是旧槽，A 还不许写）
//        ② 装载：屏上就是米白（**与两路内容无关**，读口可以整个静音，
//                 A 在这段时间写另一个槽 —— 读写自然不重叠）
//        ③ 淡入/划像/百叶窗：米白 → 新图（A 写完了，读新的那个槽）
//     这条链上唯一的"跨轨握手"就是 ①→② 那一下：
//        **may_load = 1**（电平）告诉 A："淡出放完了，可以开始写了。"
//
//  状态机（四个状态，全部靠 vs 数帧，不引入任何新的时钟域）：
//
//  ★★ 2026-10-03 改【直接转场】（"不经过米白"，见台账 §十七）：
//
//      IDLE ──req──> LOAD ──(ver变了，且米白/换图稳定 ≥ HOLD_MIN 帧)──> FX ──prog到256──> IDLE
//       │             │                                                  │
//     直通前台    旧图继续显示（A 在写后台槽）                     旧图 → 新图（划像/百叶窗/淡化）
//     may_load=0   may_load=1（★ 立刻允许写）                     may_load=0
//                                                              └─ 结束那一拍发 swap
//
//  ★ 和原来的三步（淡出米白 → 装载 → 淡入）比，少了两段 0.27 秒的淡化，
//    而且装载期间屏上是**旧图**而不是米白 —— 前提是"装载时显示还能读 SDRAM"
//    （顶层 `LOAD_WITH_READS`：只在写突发的几拍让读等一等）。
//    ★ 万一上板发现读写一起会花屏，把顶层那个 `define 关掉就回到
//      "整段禁读"：那时装载期间屏上会自己变米白（读被掐掉→行缓冲没数据→底色），
//      本状态机不用改 —— 两条路走同一套时序。
//  ★ `HOLD_MIN` 保留：等新图的**缩放几何**算稳（zoom_dual 一轮 512 拍）
//    再开始划像，免得头几帧拿旧几何去取样新图。
//
//  ★ "新图装好了没有"用【描述符版本号 ver】判断，而不是用一个脉冲：
//    描述符是 desc_rx 跨域送过来的，版本号是它现成的输出（每生效一次 +1）。
//    这里在发起转场那一拍把版本记下来（ver_l），到 HOLD 里等 `ver != ver_l` ——
//    ★ 这样"版本变化"发生在淡出期间、甚至发生在 req 之前都不怕：
//      我们等的是"比发起时更新的一份"，不会误判成旧图，也不会漏掉一个脉冲。
//
//  ★ 走完 fade-in 要发一个 **swap** 脉冲：顶层拿它对调"前台/后台"两个槽。
//    为什么这样不会闪：fade-in 结束时 prog=256，屏上**精确等于 B 端**（新图），
//    对调之后 A 就是新图、模式回到 PASS —— 同一个像素，一点跳变都没有。
//    （swap 落在 vs 之后的消隐期里，前面还有一整段空白行做缓冲。）
//
//  ★ 换图请求在转场期间是【忽略】的（只在 IDLE 受理）：连按 KEY3 不会插队。
//    连按的第二个请求要等这次转场走完 —— 顶层用 KEY 的消抖 + 这个 IDLE 门就够。
//
//  ★★★ 2026-10-08【预装 prefetch】—— 让按键"只翻前台"（见 规划\B轨待改清单.md §23）：
//    以前按键 → LOAD（等 A 把新图写进后台槽，0.3~1.8 s，屏上一直是旧图）→ FX。
//    用户感知到的"按下去没反应"就是 LOAD 那一段。
//    现在顶层会在 IDLE 期间**提前把下一张装进后台槽**（不翻 req_tgl、不转场），
//    于是按键时 `back_ready=1` ⇒ 本模块走【快速路】：跳过 LOAD、直接进 FX，
//    转场立刻开始（`may_load` 保持 0，别叫 A 再写一遍）。
//    ★ back_ready=0（手快 / 上电第一张 / 预装还没做完）就走**原来的 LOAD 老路**：
//      纯加法，最坏情况 = 今天的 RC1。
// ============================================================
`timescale 1ns / 1ps

module transition_ctrl #(
    // 每个 vs 边缘 prog 加多少。
    //  ★★★ 2026-10-17【治"画面切换不够丝滑"】原来 STEP=16 ⇒ 整场只有 **16 帧（0.27 s）
    //    、16 档**，划像一帧要跳 64 px，肉眼就是"一档一档地跳"。现在 STEP=8 ⇒
    //    **32 帧 ≈ 0.53 s**，而且 transition.v 里三个特效都换成了**软边混合**（逐像素系数）
    //    ⇒ 同样是 0.53 s，看起来连续得多。
    //  ★ 想再慢/再细就改这一个数：4 ⇒ 64 帧 ≈ 1.07 s（最丝滑）；16 ⇒ 回到原来的 0.27 s。
    parameter integer STEP     = 8,
    // 米白至少保持几帧：万一 ver 在发起之前就已经变过，也不至于"一闪而过"
    parameter integer HOLD_MIN = 2
)(
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        vs,          // 行场时序的帧同步（内部取上升沿，电平/脉冲都能给）

    // ---------------- ★ 特效从哪一端开始 ----------------
    //  ★★ 2026-10-04（上板现象：米白之后"先闪一下旧图"再出新图）：
    //     ·
    //     装载期间**整段禁读**（屏上是米白）→ 装载一结束读口放开，
    //     旧图会立刻被读回来，此时若"从旧图开始划像"就会先闪一下旧图。
    //     ⇒ 这一档要让特效**从米白那一端开始划**：from_white = 1。
    //     而"装载期间继续读、一直显示旧图"的那一档 → from_white = 0（从旧图划走）。
    input  wire        from_white,

    // ---------------- 上层 ----------------
    input  wire        req,         // 一拍脉冲：请求换下一张（板上是 KEY3）
    input  wire [1:0]  fx_sel,      // 淡入用哪种：0=划像 1=百叶窗 2=交叉淡化
    input  wire [15:0] ver,         // 描述符版本号（desc_rx 的 o_version）

    // ---------------- ★★★ 2026-10-08【预装】后台槽就绪 ----------------
    //  1 = 后台槽里已经是"下一张"了（顶层在 IDLE 期间预装完的，控制域电平）
    //  ⇒ 按键时走快速路：跳过 LOAD、直接进 FX
    input  wire        back_ready,

    // ---------------- 给 transition（混音器）----------------
    output reg  [1:0]  mix_mode,    // 编码必须和 transition.v 一致（0/PASS 1/WIPE 2/BLIND 3/XFADE）
    output reg         white_a,     // 1 = A 那一端当米白
    output reg         white_b,     // 1 = B 那一端当米白
    output reg  [8:0]  prog,        // 0..256

    // ---------------- 给 A（装载握手）----------------
    output reg         may_load,    // 电平：1 = 屏上已经全米白，可以去写 SDRAM 了

    // ---------------- 给顶层 ----------------
    output reg         swap,        // 一拍脉冲：转场走完，请对调前台/后台
    output reg         active,      // 1 = 正在转场
    // ---------------- ★ 给顶层：现在"该显示的是后台那张" ----------------
    //  ★ 2026-10-03 上板抓到的 bug 就靠这一位修（见台账 §十五）：
    //     淡入阶段屏上只有【后台那张】（另一端是米白），而缩放几何（step/off）
    //     原本一直按【前台】算 —— 于是新图被旧图的 step/off 取样，
    //     只露出左上角那一块，转场一结束切换前台才"闪"到自己该在的位置。
    //     现在顶层拿这一位去选"几何跟着谁走"：
    //       淡出/空闲 → 前台那张；  装载/淡入 → 后台那张。
    //     ★ 为什么这样就够（不用真的做两套几何）：这四个阶段里
    //       任何时刻**只有一张图在屏上**（另一端是米白），所以只要"显示谁，
    //       几何就是谁的"就永远不会张冠李戴。以后真要做"两张图之间直接划像"
    //       （不经过米白），那才需要两套几何（代价见台账 §十五）。
    output wire        show_back     // ★ 已不再使用（两套几何之后不需要它了），留着不动别人
);

    // 和 transition.v 同一套编码
    localparam [1:0] M_PASS  = 2'd0;
    localparam [1:0] M_WIPE  = 2'd1;
    localparam [1:0] M_BLIND = 2'd2;
    localparam [1:0] M_XFADE = 2'd3;

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_LOAD = 2'd1;      // 屏上还是旧图，A 在往后台槽写
    localparam [1:0] S_FX   = 2'd2;      // 旧图 → 新图（划像/百叶窗/淡化）

    reg [1:0]  st;
    reg        vs_r;
    wire       vs_e = vs & ~vs_r;          // 帧边缘
    reg [15:0] ver_l;                      // 发起转场时的描述符版本
    reg [15:0] hold_cnt;

    // ★ 两套缩放几何之后，"几何跟着谁"这件事由几何自己解决，这一位不再使用。
    //   （保留端口是为了不动顶层/测试台的接线；恒 0。）
    assign show_back = 1'b0;

    // fx_sel -> 淡入阶段用哪个特效（0 划像 1 百叶窗 2 交叉淡化）
    function [1:0] fx_mode;
        input [1:0] s;
        begin
            case (s)
            2'd0:    fx_mode = M_WIPE;
            2'd1:    fx_mode = M_BLIND;
            default: fx_mode = M_XFADE;
            endcase
        end
    endfunction

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            st       <= S_IDLE;
            vs_r     <= 1'b0;
            ver_l    <= 16'd0;
            hold_cnt <= 16'd0;
            mix_mode <= M_PASS;
            white_a  <= 1'b0;
            white_b  <= 1'b0;
            prog     <= 9'd256;
            may_load <= 1'b0;
            swap     <= 1'b0;
            active   <= 1'b0;
        end
        else begin
            vs_r <= vs;
            swap <= 1'b0;                  // 默认不给脉冲

            case (st)
            // ---------------- 空闲：直通前台 ----------------
            S_IDLE: begin
                mix_mode <= M_PASS;
                white_a  <= 1'b0;
                white_b  <= 1'b0;
                prog     <= 9'd256;
                may_load <= 1'b0;
                active   <= 1'b0;
                if (req) begin
                    ver_l    <= ver;       // ★ 记下发起时的版本
                    hold_cnt <= 16'd0;
                    active   <= 1'b1;
                    if (back_ready) begin
                        // ============================================================
                        //  ★★★【预装】快速路：后台槽里已经是"下一张" ⇒ 跳过 LOAD
                        //  mix_mode/white_a/prog 按"刚进 FX"摆好，S_FX 一个字都不用改
                        //  （它就是每次进 FX 时的样子：prog=0、从旧图那一端开始划）。
                        //  ★ may_load 保持 0：后台槽就是新图，不能再叫 A 去写
                        //    （写了会把正在显示的这张覆盖掉）。
                        // ============================================================
                        st       <= S_FX;
                        mix_mode <= fx_mode(fx_sel);
                        white_a  <= from_white;
                        white_b  <= 1'b0;
                        prog     <= 9'd0;
                        may_load <= 1'b0;
                    end
                    else begin
                        st       <= S_LOAD;
                        mix_mode <= M_PASS;    // ★ 屏上继续显示旧图（不淡出、不变米白）
                        white_a  <= 1'b0;
                        white_b  <= 1'b0;
                        prog     <= 9'd256;
                        // ★★ 跨轨握手：**立刻**允许 A 去写。
                        //    屏上这时是旧图、读还在继续 —— 依赖顶层"只在写突发的
                        //    几拍让读等一等"（LOAD_WITH_READS）。关掉那个开关时，
                        //    读被整段掐掉 → 屏上自然会变米白，时序不用改。
                        may_load <= 1'b1;
                    end
                end
            end

            // ---------------- 装载：屏上还是旧图，等新描述符 ----------------
            S_LOAD: begin
                mix_mode <= M_PASS;
                white_a  <= 1'b0;
                white_b  <= 1'b0;
                prog     <= 9'd256;
                may_load <= 1'b1;
                if (vs_e && (hold_cnt < HOLD_MIN[15:0])) hold_cnt <= hold_cnt + 16'd1;

                if ((ver != ver_l) && (hold_cnt >= HOLD_MIN[15:0])) begin
                    st       <= S_FX;
                    mix_mode <= fx_mode(fx_sel);   // 划像 / 百叶窗 / 淡化
                    white_a  <= from_white;              // ★ 直接从旧图开始（不经过米白）
                    white_b  <= 1'b0;
                    prog     <= 9'd0;
                    may_load <= 1'b0;              // 装载结束，A 该停手了
                end
            end

            // ---------------- 转场：旧图 → 新图 ----------------
            S_FX: begin
                mix_mode <= fx_mode(fx_sel);
                white_a  <= from_white;
                white_b  <= 1'b0;
                if (vs_e) begin
                    if (prog >= (9'd256 - STEP)) begin
                        prog     <= 9'd256;        // 精确等于 B 端（新图）
                        st       <= S_IDLE;
                        swap     <= 1'b1;          // ★ 请顶层对调前台/后台
                        active   <= 1'b0;
                        mix_mode <= M_PASS;
                    end
                    else prog <= prog + STEP[8:0];
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

