// ============================================================
//  模块名 : disp_top（M2 版：显示子顶层）
//  作用   : 把"行场时序 → 缩放取样 → 合成 → 565转888 → HDMI"串起来
// ------------------------------------------------------------
//  与 M1 版的唯一区别：合成器换成【可缩放】的 win_compositor（内部是 scaler_addr），
//  所以多接三个来自 zoom_sel 的输入：
//      step_q16   每个屏幕像素走多少源像素（Q16.16）
//      off_u/off_v窗口左上角对应的源坐标（Q16.16，居中偏移）
//  同时【删掉】M1 的 cmp_off 旋钮 —— 那个是抵读口偏移的实验旋钮，
//  现在由 scaler_addr 的行内 4 字对齐 + line_buf 的 RD_* 常数负责。
//
//  这里只做接线，不做逻辑（逻辑都在已经审过、有 tb 的模块里）：
//      video_timing   行场时序（800x600@60）
//      frame_gen      帧脉冲 + 帧号
//      win_compositor 合成器（命中 + 取样 + 底色 + 输出寄存一拍）
//      565→888        补低位再送 HDMI
//      my_hdmitop     成品 HDMI 发射核（lib 里的，别动）
//
//  ★ 延迟对齐：合成器输出的 rgb/de/vs 是【同一拍】的，直接一起送 my_hdmitop。
//    千万别在这里偷偷给某一个信号加一拍。
// ============================================================
`timescale 1ns / 1ps

module disp_top #(
    // 桌面底色（RGB565）。米白 ≈ RGB888 240,240,224。
    parameter [15:0] BG_COLOR = 16'hF79C,
    // 行缓冲容量：适配缩小时一行要装下整行源图（最大 1575 像素）→ 2048
    parameter integer LINE_MAX = 2048
)(
    // ---------------- 像素域 / 串化域时钟 ----------------
    input  wire        clk_pix,
    input  wire        clk_par,
    input  wire        clk_ser,
    input  wire        rst_pix_n,

    // ---------------- 源图参数（来自 desc_rx）----------------
    input  wire        src_valid,
    input  wire [20:0] src_base,
    input  wire [11:0] src_w,
    input  wire [11:0] src_h,

    // ---------------- ★ 第二路源图（转场：后台那一张）----------------
    //   ★ src_b_valid=0 时第二路一个请求都不发（综合里被常数传播掉）
    input  wire        src_b_valid,
    input  wire [20:0] src_b_base,
    input  wire [11:0] src_b_w,
    input  wire [11:0] src_b_h,

    // ---------------- ★ 第二路的缩放几何（来自 zoom_dual 的另一套）----------------
    input  wire [31:0]        step_b_q16,
    input  wire signed [31:0] off_ub_q16,
    input  wire signed [31:0] off_vb_q16,

    // ---------------- ★ 转场（③④）----------------
    input  wire        tr_req,        // 一拍脉冲：请求换下一张（顶层已经把按键同步到像素域）
    input  wire [1:0]  tr_fx,         // 淡入用哪种特效：0 划像 / 1 百叶窗 / 2 交叉淡化
    input  wire [15:0] tr_ver,        // 描述符版本号（desc_rx.o_version）—— 变了 = 新图装好了
    // ★ 2026-10-04：特效从"米白那一端"还是"旧图那一端"开始（见 transition_ctrl.v）
    input  wire        tr_from_white,
    // ★★★ 2026-10-08【预装 prefetch】：控制域给的"后台槽里已经是下一张了"（慢变电平）
    //   1 ⇒ 按键时 transition_ctrl 走快速路：跳过 LOAD、直接开始划像/百叶窗/淡化
    input  wire        tr_back_ready,
    output wire        tr_may_load,   // 电平：屏上已经全部米白，A 可以去写 SDRAM
    output wire        tr_active,     // 电平：正在转场
    output wire        tr_swap,       // 一拍脉冲：请把前台/后台对调
    // ★ 现在"该显示的是后台那张"（装载/淡入）—— 顶层拿它选缩放几何跟着谁
    output wire        tr_show_back,

    // ---------------- ★★★ 2026-10-08【字幕叠加（像素流水第 ④ 级）】----------------
    //   ★ 参数是【端口】不是常数：现在由顶层给暂定值，
    //     以后 C 轨的窗口表（`WIN_SUB` 那一条）直接接上来，本模块不用改。
    input  wire        sub_on,        // 1 = 这条字幕要显示（SDRAM 里已经有了）
    input  wire [11:0] sub_x0,
    input  wire [11:0] sub_y0,
    input  wire [11:0] sub_w,         // 契约固定 800
    input  wire [11:0] sub_h,         // 契约固定 64
    input  wire [20:0] sub_base,      // 字幕区基址（常数；一条 1600 字）
    // ★★★ 2026-10-23【字幕双缓冲】显示哪一槽（0 = +0，1 = +1600）。
    //   ★ 来源：top_m2 的 `sub_rd_sel`（50 MHz 控制域）。
    //   ★ 这里**只接线**；同步和"取字起点锁存"都在 subtitle_ovl 的 clk_mem 侧做。
    input  wire        sub_slot,
    input  wire [15:0] sub_ink,       // bit=1 画这个颜色（默认黑）
    input  wire        sub_tpat,      // ★ 一次性诊断：左半屏画自产方块（见 subtitle_ovl 注释）
    // ★★★ 2026-10-15【功能 · 开关4（SW4/C5）→ 字幕水平滚动】
    //   1 = 滚动；0 = 静止。**像素域电平**（顶层已把 sw4 同步到 clk_pix，见 top_m2）。
    //   ★ 它只往 subtitle_ovl 里传，本模块自己一个门都不加（纯接线）。
    //   ★ 域：和 sub_on 等一样是 clk_pix 域的慢变电平 ⇒ 直接接，不用再打拍。
    input  wire        sub_scroll,

    // ★★★ 2026-10-16【清理冗余 viz】：这里原来还有 8 个输入端口
    //   （viz_hist_mask/band/color、viz_freq_mask/band/color、dbg_viz_freq_win/dump），
    //   是队友那套 viz_top 的像素域输出与诊断线 —— 该套已摘除，端口一并删掉。
    //   ★ 它们**从来就没有驱动源**（顶层 top_m2 只是把它们声明成悬空网线再喂进来），
    //     所以删掉对任何既有画面、任何既有逻辑都是零影响。
    // ---------------- ★★★ 2026-10-15【参数菜单·第1步】菜单面板（像素流水第 ④' 级）----------------
    //   ★ 位置：**subtitle_ovl 之后、RGB565→RGB888 之前** —— 菜单盖在字幕之上。
    //   ★ 这两根都是 clk_pix 域的**慢变电平**（顶层把 sw2/sw1 两级同步 + 菜单状态机
    //     都在 50 MHz 控制域做好之后，再打两级同步送过来），本模块自己一个门都不加（纯接线）。
    //   ★ 参数**不给默认值**：和 sub_on 那一组同一口径 —— 顶层必须显式接，
    //     漏接会让综合报"端口未连接"而不是悄悄接 0（菜单那一路要的正是"漏接就报错"）。
    input  wire        menu_on,       // 1 = 画菜单面板；0 = 逐位透传
    input  wire [2:0]  menu_sel,      // 选中行 0..4（`>` 光标跟着它走；★ 2026-10-18 起 5 行 ⇒ 3 位）
    input  wire        menu_edit,     // ★ 2026-10-24：KEY2 确认（调节态）⇒ 选中格描边变红
    // ---------------- ★★★ 2026-10-15【参数菜单·第2步】要显示的"活值" ----------------
    //   ★ 这两根纯接线：本模块一个门都不加，直接透传给 `menu_ovl` 去查字模。
    //   ★ **只读**：菜单只是"显示"这两个值，本步**没有任何写回**（第 3 步才通过
    //     KEY2"确定"去改音量寄存器）。所以对既有画面/既有逻辑零影响。
    //   ★ 域：都是 clk_pix 域的慢变电平（top_m2 里各打了两级同步），不需要再打拍。
    //   ★ 同样**不给默认值**（与 menu_on 那一组同口径）：漏接直接报"端口未连接"。
    input  wire [2:0]  menu_zoom_lv,  // 缩放档 0..5 ⇒ 行 0 的数值
    input  wire [1:0]  menu_sel_aud,  // （2026-10-24 起行 1 不再显示音轨号；端口保留，top_m2 铺线不动）
    // ★★★ 2026-10-17【音量进菜单】：行 2 `VOLUME` 的活值 0..15（两位十进制显示）
    input  wire [3:0]  menu_vol,
    // ★★★ 2026-10-17【亮度进菜单】：行 3 `BRIGHT` 的活值 0..15（15 = 原样）。
    //   ★ 它不只是"显示"，还真的改变画面：本模块在**字幕之后、菜单之前**插一级
    //     `bri_scale`，把"画面 + 可视化 + 字幕"整体缩放 ⇒ **菜单面板本身不压暗**
    //     （否则亮度调到很低时菜单自己也看不清，就再也调不回来了）。
    //   ★ 0 拍延迟的纯组合，所以菜单的 `mx2/my2` 坐标对齐**不受影响**。
    input  wire [3:0]  menu_bri,
    // ★★★ 2026-10-18【可视化总开关进菜单】：行 4 `VISUAL` 的活值 1 = 显示 / 0 = 关闭。
    //   ★ 它同时决定"菜单里显示 ON 还是 OFF"，以及**本模块要不要把可视化层叠上去**
    //     （见下面 `viz_off` 的门）。0 拍延迟的纯组合门，不影响任何坐标对齐。
    //   ★ 关掉时：`viz_time` / `viz_freq` 照样在后台跑（只旁听音频，不占 CPU 概念），
    //     打开就能立刻有图 —— 不用等它重新统计一帧。
    input  wire        menu_viz_on,
    // ★★★ 2026-10-21【D2 · B1/B2 兜底页 / 上电自检页】
    //   `fs_on`  = 1 时把"最底层背景"换成兜底页（深底 + 三行 ASCII 说明），
    //              0 时逐位透传 ⇒ 正常出图时零影响（`failsafe_pg` 里整条链被常数传播消掉）。
    //   `fs_state`：0=OK 1=LOADING 2=BAD_IMG 3=NO_CARD（优先级在顶层定，本模块只画）。
    //   ★ 插在**合成器之后、可视化/字幕之前** ⇒ 它是最底层，字幕/菜单照样盖在上面。
    input  wire        fs_on,
    input  wire [1:0]  fs_state,
    // ★★★ 2026-10-21【D3 · C2/C3】失败原因：bit0 = 图像格式（非 24 位 BMP），
    //   bit1 = 音频格式（非 48 kHz / 非 16 位）。兜底页据此把第二行换成
    //   NEED 24BIT BMP / NEED 48KHZ WAV，否则现场只能看到干巴巴的 BAD IMAGE。
    input  wire [1:0]  fs_hint,
    // ★★★ 2026-10-21【D5 · S1 插播态】= 1 时在亮度级之后叠「红框 + 1 Hz 红闪」，
    //   位置在 bri_scale 之后、menu_ovl_cn 之前 ⇒ 报警罩压不住菜单（现场要边报边调）。
    //   ★ 0 时 alert_ovl 逐位透传 ⇒ 不报警时输出与改前完全一致。
    input  wire        alert_on,
    // ★★★ 2026-10-17【音频可视化（队友 viz_top）】：音频域那几根直接从顶层引进来。
    //   `aud_vld/aud_dout/aud_next` 是 `top_aud` 的**只读**握手副本（viz 只旁听，
    //   绝不驱动 aud_next —— 驱动了就是重复消费、音频会断，见队友文档 §5③）。
    input  wire        clk_aud,
    input  wire        rst_aud_n,
    input  wire        aud_viz_vld,
    input  wire [31:0] aud_viz_dout,
    input  wire        aud_viz_next,
    // 读口第三个客户（→ blk_rd_arb 的 s_* 那一组）
    output wire        s_blk_req,
    output wire [20:0] s_blk_base,
    output wire [20:0] s_blk_len,
    input  wire        s_blk_gnt,
    output wire        s_blk_next,
    input  wire        s_blk_dv,
    input  wire [31:0] s_blk_data,
    input  wire        s_blk_fin,
    output wire [15:0] o_sub_row_cnt,
    output wire        o_sub_hit,
    output wire [15:0] o_sub_sum16,   // ★ 指纹：片上字幕 RAM 求和的低 16 位
    output wire [10:0] o_sub_nz,      // ★ 指纹：第一个非零字的下标
    output wire        o_sub_nz_v,
    // ★★★ 2026-10-17【资源分配优化】：`o_sub_dump_idx` / `o_sub_dump_word`
    //   （2026-10-11 的"字幕 RAM 逐字倒出"调试口）已删 —— 顶层已无消费者。
    //   同名字段（串口 21/22/25）改送常量 0，帧格式/字段数一字未动。

    // ---------------- 窗口（来自 stub_win_table）----------------
    input  wire        win_on,
    input  wire [11:0] win_x0,
    input  wire [11:0] win_y0,
    input  wire [11:0] win_w,
    input  wire [11:0] win_h,

    // ---------------- 缩放（来自 zoom_sel，M2 新增）----------------
    input  wire [31:0]        step_q16,
    input  wire signed [31:0] off_u_q16,
    input  wire signed [31:0] off_v_q16,

    // ---------------- 显存域读口（接 sdr_arb）----------------
    input  wire        clk_mem,
    input  wire        rst_mem_n,
    // ★★★ 2026-10-06：改成【块级读通路】（见 line_buf 端口说明 + vendor_rd_path/blk_rd_arb）
    output wire        blk_req,
    output wire [20:0] blk_base,
    output wire [20:0] blk_len,
    input  wire        blk_gnt,
    output wire        blk_want,
    input  wire        blk_dv,
    input  wire [31:0] blk_data,
    // ★★★ 2026-10-06 诊断探针（透传给顶层位图 bit6/bit7）
    output wire        o_dbg_want_seen,
    output wire        o_dbg_lock_seen,

    // ---------------- HDMI 引脚 ----------------
    output wire        HDMI_CLK_P,
    output wire        HDMI_D0_P,
    output wire        HDMI_D1_P,
    output wire        HDMI_D2_P,
    output wire        HDMI_DDC_SCL,
    inout  wire        HDMI_DDC_SDA,

    // ---------------- ★★ 2026-10-05：HDMI 音频（来自顶层 top_aud）----------------
    //   ★ 这 6 根必须和本模块的 clk_pix 【同一个像素域】——
    //     ACR 是靠"数像素时钟"算 CTS 的，接错会变调/断续而且不报错。
    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_left,
    input  wire [23:0] I_audio_right,
    input  wire        I_acr_valid,
    input  wire [19:0] I_acr_cts,
    input  wire [19:0] I_acr_n,

    // ---------------- 诊断 ----------------
    output wire        o_video_locked,
    output wire        o_frame_start,
    output wire [15:0] o_frame_id,
    output wire        o_de,
    output wire        o_vs,
    output reg  [11:0] o_dbg_x,
    output reg  [11:0] o_dbg_y,
    output wire [15:0] o_rgb565,
    output wire [20:0] dbg_wbase,
    output wire [11:0] dbg_fwords,
    output wire [31:0] dbg_rd0,
    output wire [31:0] dbg_rd1,
    output wire [15:0] o_drop_cnt,
    output wire [15:0] o_abort_cnt,
    output wire [15:0] o_off_first,
    output wire [15:0] o_align_bad,
    output wire        frame_start_o     // ★ 2026-10-23：帧首单拍（clk_pix 域）
);

    // ============================================================
    //  行场时序
    // ============================================================
    wire        vs, de;
    wire [11:0] pix_x, pix_y;

    video_timing #(.pic_wide(1024), .pic_high(768)) u_timing (   // exp/res1024
        .clk(clk_pix), .rst_n(rst_pix_n),
        .hs(), .vs(vs), .de(de), .x(pix_x), .y(pix_y)
    );

    // ============================================================
    //  帧脉冲 + 帧号
    // ============================================================
    wire        frame_start;
    wire [15:0] frame_id;

    frame_gen u_fgen (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n), .vs(vs),
        .frame_start(frame_start), .frame_id(frame_id)
    );

    assign frame_start_o = frame_start;

    // ============================================================
    //  合成器（可缩放）
    // ============================================================
    wire [15:0] rgb565;
    wire        de_c, vs_c;
    wire [15:0] cmp_px_a, cmp_px_b;

    win_compositor #(.LINE_MAX(LINE_MAX), .MAX_OUT(16)) u_comp (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .vs(vs), .pix_x(pix_x), .pix_y(pix_y), .pix_de(de),
        .src_valid(src_valid), .src_base(src_base),
        .src_w(src_w), .src_h(src_h),
        // ★★ 2026-10-03（转场 ②b）：第二路正式接上（后台那一张）
        .src_b_valid(src_b_valid), .src_b_base(src_b_base),
        .src_b_w(src_b_w), .src_b_h(src_b_h),
        .step_b_q16(step_b_q16), .off_ub_q16(off_ub_q16), .off_vb_q16(off_vb_q16),
        .win_on(win_on),
        .win_x0(win_x0), .win_y0(win_y0), .win_w(win_w), .win_h(win_h),
        .step_q16(step_q16), .off_u_q16(off_u_q16), .off_v_q16(off_v_q16),
        .bg_color(BG_COLOR),
        // ★ 本模块自己的 rgb565 不再直接用（转场要两路）—— 留空，用下面两个
        .rgb565(),
        .o_win_a(), .o_win_b(), .o_px_a(cmp_px_a), .o_px_b(cmp_px_b),
        .de_out(de_c), .vs_out(vs_c),
        .clk_mem(clk_mem), .rst_mem_n(rst_mem_n),
        .blk_req(blk_req), .blk_base(blk_base), .blk_len(blk_len),
        .blk_gnt(blk_gnt), .blk_want(blk_want), .blk_dv(blk_dv), .blk_data(blk_data),
        .o_dbg_want_seen(o_dbg_want_seen), .o_dbg_lock_seen(o_dbg_lock_seen),
        .o_filling(),
        .o_dbg_wbase(dbg_wbase), .o_dbg_fwords(dbg_fwords),
        .o_dbg_rd0(dbg_rd0), .o_dbg_rd1(dbg_rd1),
        .o_drop_cnt(o_drop_cnt), .o_abort_cnt(o_abort_cnt)
        ,.o_off_first(o_off_first), .o_align_bad(o_align_bad)
    );

    // ============================================================
    //  转场（③④）：混合级 + 状态机
    //    混合级的两个输入就是合成器那两路（和 de_c/vs_c **同一拍**）；
    //    输出再寄存一拍送 HDMI，de/vs 跟着打同样的一拍 (§6.2)。
    // ------------------------------------------------------------
    //  ★ 划像/百叶窗要用【屏幕坐标】，而合成器给的是**寄存过一拍**的像素
    //    —— 所以坐标也得是打了一拍的（`x_cd/y_cd`，见文件末尾那一段，
    //    它和 de_c 同一拍）。★ 少打一拍界线就歪一行/一列。
    // ============================================================
    wire [1:0]  tr_mix_mode;
    wire        tr_wa, tr_wb;
    wire [8:0]  tr_prog;
    wire [15:0] px_mix;
    wire        de_mix, vs_mix;

    // ★★ 坐标打两拍，两级各用一份：
    //      x_cd/y_cd       = 和合成器那一拍（de_c / cmp_px_*）同一像素 → 转场划像/百叶窗用
    //      o_dbg_x/o_dbg_y = 再打一拍 = 和送 HDMI 的 de_mix/px_mix 同一像素 → 自检模块用
    //    （自检模块要拿"同一个像素"的坐标去算期望值；差一拍就全错。）
    //    ★ 声明必须在用之前 —— ModelSim 会把"先用后声明"当成重复定义报错。
    reg [11:0] x_cd, y_cd;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            x_cd    <= 12'd0;
            y_cd    <= 12'd0;
            o_dbg_x <= 12'd0;
            o_dbg_y <= 12'd0;
        end
        else begin
            x_cd    <= pix_x;
            y_cd    <= pix_y;
            o_dbg_x <= x_cd;
            o_dbg_y <= y_cd;
        end
    end

    transition_ctrl u_trc (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n), .vs(vs),
        .req(tr_req), .fx_sel(tr_fx), .ver(tr_ver), .from_white(tr_from_white),
        .back_ready(tr_back_ready),
        .mix_mode(tr_mix_mode), .white_a(tr_wa), .white_b(tr_wb), .prog(tr_prog),
        .may_load(tr_may_load), .swap(tr_swap), .active(tr_active),
        .show_back(tr_show_back)
    );

    transition u_tr (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .de_in(de_c), .vs_in(vs_c),
        .px_a(cmp_px_a), .px_b(cmp_px_b), .bg_color(BG_COLOR),
        .mode(tr_mix_mode), .white_a(tr_wa), .white_b(tr_wb), .prog(tr_prog),
        .pix_x(x_cd), .pix_y(y_cd),
        .rgb565(px_mix), .de_out(de_mix), .vs_out(vs_mix)
    );

    // ============================================================
    //  ★★★ 2026-10-17【音频可视化整层砍除】
    //     这里原来是**两级叠图**，现在都删了：
    //       ① 队友那套 24 级梯级 viz（viz_top → viz_time / viz_freq / 2×viz_render）
    //          实测 mslice 5564 > 硬墙 4900 ⇒ phy 报 PHY-9009，M2.bit 根本生不出来；
    //       ② 自研的 `b_display/viz_bars.v`（8 点 Goertzel 频谱柱）—— 修好之后能出谱了，
    //          但实拍效果不合格，且它吃 +2228 LUT / +551 mslice（mslice 只剩 200 出头）。
    //     ⇒ **整层砍掉**：例化、端口、`VIZ2_ON` 开关、`px_v` 合成 mux 全删。
    //     ⇒ 现在的像素流水是：转场输出 `px_mix` → subtitle_ovl → menu_ovl → 565→888。
    //     ⇒ 代码/仿真台/定参脚本都移到仓库外了：
    //        `E:\FPGA\ygcom\.viz_backup_20261017\`（要复活就去那里拿，M2.al 加一行就回来）。
    // ============================================================

    // ============================================================
    //  ★★★ 2026-10-08【字幕叠加】—— 像素流水第 ④ 级
    //    转场之后、565→888 之前。**1bpp 遮罩：bit=1 画黑（字）、bit=0 透传**。
    //    ★ 坐标用 `o_dbg_x/o_dbg_y`：那两行注释写着"和送 HDMI 的 de_mix/px_mix
    //      同一像素"（`x_cd/y_cd` 是早一拍的，给不了这一级用）。
    //    ★ 它自己会多打一拍 ⇒ 下面 de/vs 和 rgb 全部改用 *_z 那一组。
    // ============================================================
    wire [15:0] px_z;
    wire        de_z, vs_z;

    // ============================================================
    //  ★★★ 2026-10-17【音频可视化 · 只装时域那半边（试装）】
    //   整套（`viz_top` = viz_time + viz_freq + 2×viz_render）实测 **4,502 LUT**，
    //   而设备的 **mslice 上限 4900** 是独立预算：加完用 5249 ⇒ 超 349（硬报错
    //   `PHY-9009`，不是布线问题）⇒ 整套上不去。
    //   只装时域 → 1,284 LUT（viz_time 105 + 柱状渲染 1,179）⇒ 稳稳能装。
    //   ⇒ 这里**直接例化 viz_time + viz_render**，不经过 `viz_top`；
    //     频域那半边接常数 0（合成时自然被裁掉）。要整套就换回 `viz_top`，
    //     但先把 mslice 从别处腾出约 350（最大一块是 `win_compositor`+`scaler_addr`
    //     的双路缩放 = 16 DSP / 约 580 mslice）。
    // ============================================================
    wire        viz_hist_mask, viz_hist_band;
    wire [23:0] viz_hist_color;
    wire        viz_wr_en;
    wire [4:0]  viz_wr_addr;
    wire [5:0]  viz_wr_val;
    wire [15:0] viz_dbg_win;
    wire        viz_dbg_dump;
    //   频域那半边：★ 2026-10-17【已试过，**按用户判定撤下**】
    //   实测（整套 viz_top，24 段）：4,507 LUT；卡在独立预算 `mslice`（上限 4900）
    //   ⇒ `PHY-9009` 超 349，整套上不了。
    //   退一步试 12 段（C1）：能建，但 **96.23% slices + Hold WNS −41 ps（保持违例）**，
    //   而用户看过谱形后判定"一般，不值得" ⇒ **只保留时域那半边，频域接常数 0**。
    //   ★ 想再启用：把下面两条 `= 0` 换成 viz_freq + viz_render（参数见 `viz2/viz_top.v`
    //     的 `u_freq` / `u_freq_draw` 两段），代价见上面两个数字。
    wire        viz_freq_mask, viz_freq_band;
    wire [23:0] viz_freq_color;

    viz_time #(
        .N       (31),                // ★ 1024×768 实验：24 → 31 段
        .SMP_WIN (1500),
        .GAIN    (6'd16)
    ) u_viz_hist (
        .clk_aud   (clk_aud),
        .rst_aud_n (rst_aud_n),
        .aud_vld   (aud_viz_vld),
        .aud_dout  (aud_viz_dout),
        .aud_next  (aud_viz_next),
        .wr_en     (viz_wr_en),
        .wr_addr   (viz_wr_addr),
        .wr_val    (viz_wr_val),
        .dbg_addr  (),
        .dbg_peak  (),
        .dbg_cnt   (viz_dbg_win)
    );

    // ★★★ 2026-10-18【用户反馈"下降太慢"】：缓降速度 ×3、峰值回落同步加快
    //   viz_render 的口径：每隔 DECAY_DIV 拍降【一根】柱子 1 格，指针走一圈 = N×DECAY_DIV
    //   拍 ⇒ 满格 63 格掉光 = 63×N×DECAY_DIV / 12.288MHz
    //     改前 N=32、DECAY_DIV=36571 ⇒ 63×32×36571/12.288e6 ≈ **6.0 s**
    //     改后 DECAY_DIV=12200     ⇒ ≈ **2.0 s**（快 3 倍）
    //   峰值点原来落后 4 倍（≈24 s），跟 2 s 的柱子差太多 ⇒ PEAK_SLOW 4→2（≈4 s），
    //   仍然是"比柱子慢"，但一眼能看出它在回落。
    //   ★ 还想更快/更慢就只改这两个数：满格秒数 ≈ 63×N×DECAY_DIV/12.288e6
    // ★★★ 2026-10-20【用户 v1 反馈："还是不够长，左右只留出一点空隙，
    //   而且降低字幕和音谱加起来占整个图片的比例"】—— 第二版几何：
    //   · 横向：24 段 × 32 px（画 26 留 6）⇒ 带宽 **768**，两侧各余 **16 px**
    //     （v1 是 32×16=512、两侧各 144，显得"缩在中间"）。
    //   · 竖向：柱高满格 31 px（H_SHIFT=1）⇒ 音谱带 32 px，坐在字幕上沿 528 上，
    //     即 y = [496, 528)。字幕 64 + 音谱 32 = **96 px = 屏高 16%**（v1 是 128 px/21%）。
    //   ★ 面积不变（全是常数比较 + 移位）。
    //   ★ 2026-10-20【用户 v3 反馈："想要更高"】—— 第四版：条带拉高到 48 px
    //     带高 24 → **48 px**，满格柱 **43 px**（H_SHIFT 回 0，改用钳位到带顶）。
    //     字幕 64 + 音谱 48 = **112 px = 屏高 18.7%**（v2 16% → v3 14.7% → v4 18.7%）。
    viz_render #(
        .N          (31),                // ★ 1024×768 实验：24 → 31 段（31×32=992，两侧各 16）
        .CELL_SHIFT (5),                 // ★ 柱宽 16 → 32 px（画 26 px + 6 px 缝）
        .VIS_X      (10'd16),            // ★ 144 → 16（带宽 768，左右各 16 px）
        .VIS_Y      (10'd648),           // ★ 1024×768 实验：底边 696 = 字幕上沿（696-48）
        .BAR_H      (10'd48),            // ★ 64 → 32 → 24 → 48（带高）
        .H_SHIFT    (0),                 // ★ 0 = 不缩放（满格钳到带顶 47）
        .DECAY_DIV  (12000),
        .PEAK_SLOW  (4'd2),
        // ★★★ 2026-10-19【用户："太快了"】：浮标从 ≈1 s 放慢到 **≈3 s**（柱子仍 2 s）
        //   口径：满格落地 = 63×N×PEAK_DIV/12.288e6
        //         N=24、PEAK_DIV=18000 ⇒ 63×24×18000/12.288e6 ≈ **2.2 s**
        //   ★ 以后想微调只改 `PEAK_DIV`：N=24 时 秒数 ≈ 8127×(秒)
        .PEAK_FAST  (4'd0),
        .PEAK_DIV   (18000),
        .GAP        (6),                 // ★ 画 26 px，留 6 px 缝
        .COL_B      (8'd24)
    ) u_viz_hist_draw (
        .clk_aud   (clk_aud),
        .rst_aud_n (rst_aud_n),
        .wr_en     (viz_wr_en),
        .wr_addr   (viz_wr_addr),
        .wr_val    (viz_wr_val),
        .de        (de_mix),
        .x         (o_dbg_x[9:0]),
        .y         (o_dbg_y[9:0]),
        .mask      (viz_hist_mask),
        .in_band   (viz_hist_band),
        .color     (viz_hist_color)
    );

    // ★★★ 2026-10-20【D1 · A1 砍频域】：24 段频域整块下线
    //   · 为什么砍：它是面积里最贵的一块（+2,585 LUT / +1,386 slices / +1 DSP），
    //     而商显/应急定位下屏上两条柱子是视觉噪音（2026-10-19 评审结论）。
    //   · 砍完不再有实例驱动 viz_freq_mask/band/color ⇒ 下面三根接常数；
    //     时域 32 柱保留 ⇒ 评分项⑤“音频可视化”仍然成立。
    //   · ★ 想恢复：把 viz2/viz_top.v 的 u_freq / u_freq_draw 两段抄回来
    //     （N=24 / SMP_WIN=2048 / LOG_BIAS=16 / VIS_Y=312），再删掉下面三根 0。
    assign viz_freq_mask  = 1'b0;
    assign viz_freq_band  = 1'b0;
    assign viz_freq_color = 24'd0;

    // ★★★ 2026-10-21【D2 · B1】兜底页：把"最底层背景"换掉
    //   位置：合成器 `px_mix` 之后、`viz_*`/`subtitle_ovl` 之前 ⇒ 它就是最底层，
    //         上面几层（可视化、字幕、亮度、菜单）照旧往它上面叠。
    //   ★ 坐标用 `o_dbg_x/o_dbg_y`：它们和 `px_mix` 是**同一个像素**（见下面菜单那段注释），
    //     所以 `failsafe_pg` 里纯组合画、不打拍，格子边界才和屏幕对齐。
    //   ★ `fs_on=0` 时 `px_bg` 逐位等于 `px_mix` ⇒ 正常出图与改之前一模一样。
    wire [15:0] px_bg;
    failsafe_pg #(
        .SCALE(2)
    ) u_failsafe (
        .clk_pix  (clk_pix),
        .rst_pix_n(rst_pix_n),
        .de_in    (de_mix),
        .x_in     (o_dbg_x),
        .y_in     (o_dbg_y),
        .fs_on    (fs_on),
        .fs_state (fs_state),
        .fs_hint  (fs_hint),
        .px_in    (px_mix),
        .px_out   (px_bg)
    );

    // ★★★ 2026-10-18【菜单行 4 `VISUAL` = 可视化总开关】
    //   `viz_off` = 关掉时把"柱形遮罩"和"矩形压暗"一起门掉 ⇒ `px_v` 逐位等于 `px_mix`
    //   （= 屏幕上完全看不到可视化，连那块压暗的底也不会留）。
    //   ★ 用"门 mask/band"而不是"在最后 mux 上选" ：少一级 16 位 mux，面积更省。
    wire        viz_off = ~menu_viz_on;
    wire        viz_m   = (viz_hist_mask | viz_freq_mask) & ~viz_off;
    wire [23:0] viz_c24 = viz_hist_mask ? viz_hist_color : viz_freq_color;  // 重叠时历史优先
    wire [15:0] viz_c16 = {viz_c24[23:19], viz_c24[15:10], viz_c24[7:3]};
    wire        viz_dim = (viz_hist_band | viz_freq_band) & ~viz_m & ~viz_off;
    //  压暗：565 每个通道各右移 1 位
    wire [15:0] viz_dim16 = {1'b0, px_bg[15:12], 1'b0, px_bg[10:6], 1'b0, px_bg[4:1]}; // ★ D2：压暗的底跟着兜底页
    wire [15:0] px_v = viz_m   ? viz_c16
                     : viz_dim ? viz_dim16
                     :           px_bg;   // ★ D2：兜底页 = 最底层

    subtitle_ovl u_sub (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .de_in(de_mix), .vs_in(vs_mix),
        .x_in(o_dbg_x), .y_in(o_dbg_y),
        // ★ 2026-10-17：吃"转场输出 + 可视化叠加"这一级（`px_v`）。
        //   没有可视化时它逐位等于 `px_mix`。
        .px_in(px_v),
        .px_out(px_z), .de_out(de_z), .vs_out(vs_z),
        // ★★ 2026-10-09：整条字幕在【显存域】取回来（读口那个域），像素侧在 clk_pix
        .clk_mem(clk_mem), .rst_mem_n(rst_mem_n),
        .sub_on(sub_on), .sub_x0(sub_x0), .sub_y0(sub_y0),
        .sub_w(sub_w), .sub_h(sub_h),
        .sub_base(sub_base), .sub_slot(sub_slot), .ink(sub_ink),
        .tpat_half(sub_tpat),
        // ★★★ 2026-10-15【功能 · 开关4 → 字幕水平滚动】：像素域电平（顶层 sw4 的四级同步之后）
        //   ★ 时钟域：和 `clk_pix` 同域（它就是本模块的 clk_pix）；复位仍用 `rst_pix_n`
        //     （= 顶层的 disp_rst_n ⇒ 装载期间整块复位时它跟着复位 ⇒ 复位后 offset=0）。
        .scroll_en(sub_scroll),
        .mem_req(s_blk_req), .mem_base(s_blk_base), .mem_len(s_blk_len),
        .mem_gnt(s_blk_gnt), .mem_next(s_blk_next),
        .mem_dv(s_blk_dv), .mem_data(s_blk_data), .mem_fin(s_blk_fin),
        .o_row_cnt(o_sub_row_cnt), .o_hit(o_sub_hit)
        ,.o_sum16(o_sub_sum16), .o_nz(o_sub_nz), .o_nz_v(o_sub_nz_v)
        // ★★★ 2026-10-17【资源分配优化】：`.o_dump_idx/.o_dump_word` 两条接线已删
    );

    // ============================================================
    //  ★★★ 2026-10-15【参数菜单·第1步】菜单面板 —— 像素流水第 ④' 级
    // ------------------------------------------------------------
    //  位置：**subtitle_ovl 之后（px_z）、RGB565→RGB888 之前** —— 也就是菜单**盖在
    //        字幕上面**（字幕那条 800×64 的带子在屏底 y=528..592，菜单面板居中
    //        y=200..400，两者本来就不重叠；万一日后重叠，菜单在上是符合直觉的）。
    //  ★ `subtitle_ovl` 的取数/坐标/洗淡/滚动**一个字都没动** —— 菜单是**另一层**，
    //    `menu_ovl` 只做"面板内换成它的纯色、面板外逐位透传"。
    //  ★★ 坐标：`menu_ovl` 的输出比输入**晚两拍**（和 subtitle_ovl 同一口径，
    //    见它文件头）。而 `o_dbg_x/o_dbg_y` 是**只打了一拍**的。若直接用，画的矩形会
    //    整体**偏左上 2 个像素**（400 宽的画面里肉眼能看出来"框不方"）。
    //    ⇒ 这里专门为它把坐标**再多打两拍**（`mx1/mx2`、`my1/my2`），和 `px_z` 同拍。
    //    ★ 新加名字、**不动** `o_dbg_x/o_dbg_y` 这两个输出（其它自检模块在用）。
    //  ★ 菜单关闭（`menu_on`=0）时：`menu_ovl` 里所有 `draw_*` 恒 0 ⇒ `px_m` 与 `px_z`
    //    逐位相同 ⇒ 本模块输出与改前一模一样。
    // ============================================================
    reg [11:0] mx1, mx2, my1, my2;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            mx1 <= 12'd0; mx2 <= 12'd0;
            my1 <= 12'd0; my2 <= 12'd0;
        end
        else begin
            mx1 <= o_dbg_x; mx2 <= mx1;      // o_dbg_x 已经是"晚一拍" ⇒ 再两拍 = 共三拍
            my1 <= o_dbg_y; my2 <= my1;      // = 和 px_z / sub_*_z 同一像素
        end
    end

    // ============================================================
    //  ★★★ 2026-10-17【菜单·亮度】亮度缩放级（**组合、0 拍延迟**）
    // ------------------------------------------------------------
    //  位置：`subtitle_ovl` 的输出（px_z）→ **[本模块 bri_scale]** → `menu_ovl`
    //    ⇒ 被压暗的是"画面 + 可视化柱 + 字幕"；**菜单面板保持全亮**。
    //    ★ 为什么放在菜单之前（别挪到后面去）：亮度调到 0 时菜单还得看得见，
    //      否则用户没法把亮度调回来。
    //  ★ `bri_lv = 15`（上电默认）⇒ 系数 16 ⇒ `(c×16)>>4 = c` **逐位原样**
    //    ⇒ 不动菜单里这一项时，输出和改这一版之前**逐位相同**（仿真穷举过：
    //    `sim\tb_bri_scale.v`，17 档 × 65536 色，bad=0）。
    // ============================================================
    wire [15:0] px_b;
    bri_scale u_bri (
        .bri_lv (menu_bri),
        .px_in  (px_z),
        .px_out (px_b)
    );

    // ============================================================
    //  ★★★ 2026-10-21【D5 · S1 插播态】报警叠层（纯组合、0 拍延迟）
    // ------------------------------------------------------------
    //  位置：`bri_scale`(px_b) → **[本模块 alert_ovl]** → `menu_ovl_cn`
    //    ⇒ 报警红罩不压菜单（现场要能一边报警一边调音量/亮度）。
    //  ★ 0 拍 ⇒ 直接吃 `de_z / mx2 / my2`（和 px_b 同一像素），
    //    千万不要像 font32 那样补拍 —— 补拍会把整幅图右移一像素。
    // ============================================================
    wire [15:0] px_al;
    alert_ovl u_alert (
        .clk_pix  (clk_pix),
        .rst_pix_n(rst_pix_n),
        .de_in    (de_z),
        .vs_in    (vs_z),
        .x_in     (mx2),
        .y_in     (my2),
        .px_in    (px_b),
        .alert_on (alert_on),
        .px_out   (px_al)
    );

    wire [15:0] px_m;
    wire        de_m, vs_m;

    menu_ovl_cn u_menu (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .de_in(de_z), .vs_in(vs_z),
        .x_in(mx2), .y_in(my2),
        .px_in(px_al),
        .px_out(px_m), .de_out(de_m), .vs_out(vs_m),
        .menu_on(menu_on), .menu_sel(menu_sel), .menu_edit(menu_edit),
        // ★★★ 2026-10-15【参数菜单·第2步】把两个活值送进菜单层去查字模（纯接线、只读）
        .zoom_lv(menu_zoom_lv), .sel_aud(menu_sel_aud),
        // ★★★ 2026-10-24【行 1 换成可视化开关】：面板显示 ON/OFF 用（真实开关在 top_m2 的 viz_on）
        .viz_on(menu_viz_on),
        // ★★★ 2026-10-17【音量/亮度进菜单】行 2 的音量、行 3 的亮度
        .vol_lv(menu_vol),
        .bri_lv(menu_bri)
        // ★★★ 2026-10-20【D1 · A2 删 VISUAL 行】：`.viz_on` 端口已从 menu_ovl 删除
    );

    // ============================================================
    //  RGB565 → RGB888（低位补高位）
    // ============================================================
    wire [23:0] rgb888 = {
        px_m[15:11], px_m[15:13],
        px_m[10:5],  px_m[10:9],
        px_m[4:0],   px_m[4:2]
    };

    // ============================================================
    //  HDMI（成品核，别动）
    // ============================================================
    my_hdmitop #(
        .DEVICE("EG"), .pic_wide(1024), .pic_high(768)   // exp/res1024
    ) u_hdmi (
        .I_pixel_clk (clk_pix),
        .I_pclk      (clk_par),
        .I_serial_clk(clk_ser),
        .I_rst       (~rst_pix_n),
        .I_vs        (vs_m),           // ★ 改用菜单那一级之后的（和 rgb888 同拍）
        .I_de        (de_m),
        .I_rgb       (rgb888),
        .O_tmds_clk_p(HDMI_CLK_P),
        .O_tmds_d0_p (HDMI_D0_P),
        .O_tmds_d1_p (HDMI_D1_P),
        .O_tmds_d2_p (HDMI_D2_P),
        .O_ddc_scl   (HDMI_DDC_SCL),
        .IO_ddc_sda  (HDMI_DDC_SDA),
        // ★★ 2026-10-05：音频 6 根原样透传给 HDMI 核（像素域，和 I_pixel_clk 同域）
        .I_audio_valid(I_audio_valid),
        .I_audio_left (I_audio_left),
        .I_audio_right(I_audio_right),
        .I_acr_valid  (I_acr_valid),
        .I_acr_cts    (I_acr_cts),
        .I_acr_n      (I_acr_n),
        .O_video_locked(o_video_locked),
        .O_edid_read_valid(),
        .O_edid_read_data()
    );

    // ---- 诊断引出 ----
    assign o_frame_start = frame_start;
    assign o_frame_id    = frame_id;
    assign o_de          = de_m;        // ★ 送给 HDMI 的那一拍（转场 + 字幕 + 菜单之后）
    assign o_vs          = vs_m;
    assign o_rgb565      = px_m;

endmodule
