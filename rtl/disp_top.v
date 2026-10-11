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
    input  wire [20:0] sub_base,      // 字幕区基址 + 条号×1600
    input  wire [15:0] sub_ink,       // bit=1 画这个颜色（默认黑）
    input  wire        sub_tpat,      // ★ 一次性诊断：左半屏画自产方块（见 subtitle_ovl 注释）
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
    output wire [10:0] o_sub_dump_idx,   // ★ 2026-10-11 调试：逐字倒出（下标）
    output wire [31:0] o_sub_dump_word,  // ★ 2026-10-11 调试：逐字倒出（值）

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
    output wire [15:0] o_align_bad
);

    // ============================================================
    //  行场时序
    // ============================================================
    wire        vs, de;
    wire [11:0] pix_x, pix_y;

    video_timing #(.pic_wide(800), .pic_high(600)) u_timing (
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
    //  ★★★ 2026-10-08【字幕叠加】—— 像素流水第 ④ 级
    //    转场之后、565→888 之前。**1bpp 遮罩：bit=1 画黑（字）、bit=0 透传**。
    //    ★ 坐标用 `o_dbg_x/o_dbg_y`：那两行注释写着"和送 HDMI 的 de_mix/px_mix
    //      同一像素"（`x_cd/y_cd` 是早一拍的，给不了这一级用）。
    //    ★ 它自己会多打一拍 ⇒ 下面 de/vs 和 rgb 全部改用 *_z 那一组。
    // ============================================================
    wire [15:0] px_z;
    wire        de_z, vs_z;

    subtitle_ovl u_sub (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .de_in(de_mix), .vs_in(vs_mix),
        .x_in(o_dbg_x), .y_in(o_dbg_y), .px_in(px_mix),
        .px_out(px_z), .de_out(de_z), .vs_out(vs_z),
        // ★★ 2026-10-09：整条字幕在【显存域】取回来（读口那个域），像素侧在 clk_pix
        .clk_mem(clk_mem), .rst_mem_n(rst_mem_n),
        .sub_on(sub_on), .sub_x0(sub_x0), .sub_y0(sub_y0),
        .sub_w(sub_w), .sub_h(sub_h), .sub_base(sub_base), .ink(sub_ink),
        .tpat_half(sub_tpat),
        .mem_req(s_blk_req), .mem_base(s_blk_base), .mem_len(s_blk_len),
        .mem_gnt(s_blk_gnt), .mem_next(s_blk_next),
        .mem_dv(s_blk_dv), .mem_data(s_blk_data), .mem_fin(s_blk_fin),
        .o_row_cnt(o_sub_row_cnt), .o_hit(o_sub_hit)
        ,.o_sum16(o_sub_sum16), .o_nz(o_sub_nz), .o_nz_v(o_sub_nz_v)
        ,.o_dump_idx(o_sub_dump_idx), .o_dump_word(o_sub_dump_word)
    );

    // ============================================================
    //  RGB565 → RGB888（低位补高位）
    // ============================================================
    wire [23:0] rgb888 = {
        px_z[15:11], px_z[15:13],
        px_z[10:5],  px_z[10:9],
        px_z[4:0],   px_z[4:2]
    };

    // ============================================================
    //  HDMI（成品核，别动）
    // ============================================================
    my_hdmitop #(
        .DEVICE("EG"), .pic_wide(800), .pic_high(600)
    ) u_hdmi (
        .I_pixel_clk (clk_pix),
        .I_pclk      (clk_par),
        .I_serial_clk(clk_ser),
        .I_rst       (~rst_pix_n),
        .I_vs        (vs_z),           // ★ 改用字幕那一级之后的（和 rgb888 同拍）
        .I_de        (de_z),
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
    assign o_de          = de_z;        // ★ 送给 HDMI 的那一拍（转场 + 字幕之后）
    assign o_vs          = vs_z;
    assign o_rgb565      = px_z;

endmodule
