// ============================================================
//  ★★ 2026-10-02 集成临时改动（和 line_buf / sdr_arb 那两处同源）
//     TD 里【没有】全局 Verilog 宏（所有 .al 的 <Project_Settings> 都是空的），
//     所以"在 TD 编译选项里加宏"这条路走不通 —— 会报
//     "模块 win_compositor 没有端口 o_dbg_wbase"。
//     改成本地打开：效果和 ModelSim 的 +define+B_DEBUG_PROBE 完全一样。
//     交付仓库里这一份【没有这几行】，所以作品版照样是干净的。
//     ★ 从仓库同步（sync_from_repo.ps1）会把这个头冲掉 → 刷完要重新加。
// ============================================================
`ifndef B_DEBUG_PROBE
`define B_DEBUG_PROBE
`endif
// ============================================================
//  模块名 : win_compositor
//  作用   : 【单窗口合成器】—— 把"一圈窗口里的那张图"输出成 HDMI 能吃的像素流
//  层次   : 像素流水七级的第 ②③ 级（窗口命中 + 取样），M1 只做单窗口
//  时钟域 : 像素域 40 MHz（搬运那半在 line_buf 里跨到显存域）
//  依据   : B轨说明书 §2（流水线七级）、§6.1（只画最上面那个）、§6.2（延迟对齐）
// ------------------------------------------------------------
//  它干的三件事：
//    ① 算窗口命中：这一拍这个屏幕像素在不在窗口里？（win_sample 里）
//    ② 在窗口里 → 显示源图像素；不在 → 显示桌面底色
//    ③ 把输出**寄存一拍**，de / vs 跟着打同样的拍数（§6.2 那类 bug 就靠这一步挡）
//
//  ★ 为什么必须先寄存一拍再送 HDMI：
//    line_buf 是【组合读出】（rd_index 一变，pix_out 立刻变），
//    这样的信号直接送 HDMI 会让建立时间紧张，而且和 de/vs 一差拍就是
//    "整幅图左移一个像素"这种最难查的现象。所以这里统一寄存一拍：
//      rgb565 / de_out / vs_out 三者永远同拍。
//
//  ★ M2（第一刀）：取样级从 win_sample（只做 1:1）换成 scaler_addr（可缩放）。
//     新增三个输入：step_q16（1/Z，Q16.16）、off_u_q16、off_v_q16（居中偏移）。
//     行缓冲 LINE_MAX 从 1024 提到 2048（适配缩小时候一行要装下整行源图）。
//     输出那一段（寄存一拍、底色兜底）一行都没动。
//    ★ 双线性是下一步：它要"同一行里相邻两个源像素同时在场"，
//      需要给 line_buf 加第二个读口（见 规划\B轨待改清单.md）。这一刀先最近邻。
//
//  ★ 只画最上面那一个（§6.1）：现在只有一个窗口，天然满足；
//    加多窗口时，在这一级前面插"z 序优先级选择"，选出来的那一个再接进来。
//
//  ★★ M2（转场·第二刀 2026-10-03）：**两路取样**。
//    转场（划像/百叶窗/交叉淡化）要同时拿到"前台那张"和"后台那张"的像素，
//    所以这里并排跑两套：
//      · scaler_addr 的第二路（地址/搬数/命中各算各的，几何共用 —— 见 scaler_addr 的说明）
//      · 第二个 line_buf（u_lb_b）：**8 块 BRAM**，41→49 / 64
//      · 一个"读口锁"：两条行缓冲共用 sdr_arb 的**同一个读口**，一趟搬完才换人
//    对外多给四个口：`o_win_a/o_px_a`（前台）和 `o_win_b/o_px_b`（后台），
//    和 de_out / vs_out **严格同拍**；本模块自己的 rgb565 仍然 = 前台那路，
//    所以没接转场之前，屏上行为和以前**一字不差**（`src_b_valid=0` 时第二路被
//    常数传播掉，综合出来一个 LUT 都不多）。
//    ★ 混合（划像/淡化）是下一级 transition.v 的事，这里只负责把两路的像素**备齐**。
// ============================================================
`timescale 1ns / 1ps

module win_compositor #(
    parameter integer LINE_MAX = 2048,   // 一行最多显示多少像素（= line_buf 的容量）
    parameter integer MAX_OUT  = 16      // 在途读请求上限（"一小串"，见 line_buf）
)(
    // ---------------- 像素域 40 MHz ----------------
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        vs,             // 来自 video_timing（正极性）
    input  wire [11:0] pix_x,
    input  wire [11:0] pix_y,
    input  wire        pix_de,

    // ---------------- 源图（来自描述符；M1 可先写死，之后接 desc_rx）----------------
    input  wire        src_valid,
    input  wire [20:0] src_base,
    input  wire [11:0] src_w,
    input  wire [11:0] src_h,

    // ---------------- ★ 第二路源图（转场：后台那张）----------------
    //   ★ src_b_valid=0 -> 第二路完全不发请求（常数传播，资源零增长）
    input  wire        src_b_valid,
    input  wire [20:0] src_b_base,
    input  wire [11:0] src_b_w,
    input  wire [11:0] src_b_h,

    // ★★ 2026-10-03（转场·不经过米白）：第二路**自己的一套缩放几何**。
    //   两张图的适配缩放不一样，而直接划像/叠化要求两张图同时在屏上各自正确
    //   （共用几何时，进来的那张会被拿出去的 step/off 取样 → 只露左上角，
    //     见台账 §十五）。两套参数的资源账见 scaler_addr 文件头。
    input  wire [31:0]        step_b_q16,
    input  wire signed [31:0] off_ub_q16,
    input  wire signed [31:0] off_vb_q16,

    // ---------------- 窗口矩形（M1 来自桩；M2 来自 C 的窗口表）----------------
    input  wire        win_on,
    input  wire [11:0] win_x0,
    input  wire [11:0] win_y0,
    input  wire [11:0] win_w,
    input  wire [11:0] win_h,

    // ---------------- 缩放参数（来自 zoom_sel，M2 新增）----------------
    input  wire [31:0]        step_q16,    // 1/Z，Q16.16
    input  wire signed [31:0] off_u_q16,   // 窗口左上角对应的源列（Q16.16）
    input  wire signed [31:0] off_v_q16,   // 窗口左上角对应的源行（Q16.16）

    // ---------------- 桌面底色（窗口外面那圈）----------------
    input  wire [15:0] bg_color,       // RGB565

    // ---------------- 输出：和 de_out / vs_out 严格同拍 ----------------
    output wire [15:0] rgb565,      // ★ 改成组合输出（见下面③的说明）
    output reg         de_out,
    output reg         vs_out,

    // ---------------- ★ 两路取样结果（给 transition.v；和 de_out 同拍）----------------
    output wire        o_win_a,     // 1 = 这一拍【窗口里】有前台的像素（否则 o_px_a 是底色）
    output wire        o_win_b,     // 1 = 这一拍【窗口里】有后台的像素（否则 o_px_b 是底色）
    output wire [15:0] o_px_a,      // 前台像素；窗口外 = 底色
    output wire [15:0] o_px_b,      // 后台像素；窗口外 = 底色

    // ---------------- 显存域 125 MHz（接到 sdr_arb 的读口）----------------
    input  wire        clk_mem,
    input  wire        rst_mem_n,
    // ★★★ 2026-10-06：块级读通路（见《重构_读通路_施工说明》§5.5）
    //   两路 line_buf 共用这一套：**谁拿到读口（gnt_a/gnt_b）就发谁的块请求**
    output wire        blk_req,
    output wire [20:0] blk_base,
    output wire [20:0] blk_len,
    input  wire        blk_gnt,
    output wire        blk_want,
    input  wire        blk_dv,
    input  wire [31:0] blk_data,

    // ---------------- 诊断 ----------------
    output wire        o_filling       // 正在搬某一行（仲裁/状态用）
`ifdef B_DEBUG_PROBE
    // ---- ★ 调试探针 / 诊断计数（**只在 B_DEBUG_PROBE 定义时才存在**）----
    //  2026-10-01：这些口只为【上板串口报告】服务，默认【不综合、端口都不存在】
    //    （详细说明见 line_buf.v 的同一段）。
    //  ★ 逗号写在宏里面：不开宏时 o_filling 就是最后一个端口，不能留逗号。
    ,
    output wire [20:0] o_dbg_wbase,
    output wire [11:0] o_dbg_fwords,
    output wire [31:0] o_dbg_rd0,
    output wire [31:0] o_dbg_rd1,
    // 诊断计数（2026-09-27）：搬运请求被丢的次数 / 看门狗掐断的次数
    output wire [15:0] o_drop_cnt,
    output wire [15:0] o_abort_cnt,
    // 逐字对齐校验（地址图专用）：第 1 个字偏几个 / 本趟几个字不对
    output wire [15:0] o_off_first,
    output wire [15:0] o_align_bad
`endif
);

    // ============================================================
    //  ① 取样地址发生器
    // ============================================================
    wire        line_go;
    wire [20:0] line_wbase;
    wire [11:0] line_words;
    wire [11:0] rd_index;
    wire        hit;

    // ---- 第二路（转场用）----
    wire        line_go_b;
    wire [20:0] line_wbase_b;
    wire [11:0] line_words_b;
    wire [11:0] rd_index_b;
    wire        hit_b;

    // ★ VFLIP=1：SDRAM 里存的是自下而上的图（和 win_sample 那处同源）；
    //   A 修好行序之后把它改成 0（全项目唯一一处翻转）。
    // ★ bilin_en 先接 0：这一刀是最近邻，双线性等 line_buf 加双读口再接。
    scaler_addr #(.VFLIP(1)) u_scaler (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .src_valid(src_valid), .src_base(src_base),
        .src_w(src_w), .src_h(src_h),
        // ★★ 2026-10-03（转场·二路取样）：第二路正式接上。
        //    两路共用同一套窗口几何（step/off），只有基址/宽高各算各的。
        //    没接转场时调用方给 src_b_valid=0 -> 第二路一个请求都不发。
        .src_b_valid(src_b_valid), .src_b_base(src_b_base),
        .src_b_w(src_b_w), .src_b_h(src_b_h),
        .step_b_q16(step_b_q16), .off_ub_q16(off_ub_q16), .off_vb_q16(off_vb_q16),
        .win_on(win_on), .win_x0(win_x0), .win_y0(win_y0),
        .win_w(win_w), .win_h(win_h),
        .step_q16(step_q16), .off_u_q16(off_u_q16), .off_v_q16(off_v_q16),
        .bilin_en(1'b0),
        .pix_x(pix_x), .pix_y(pix_y), .pix_de(pix_de),
        .l0_go(line_go), .l0_wbase(line_wbase), .l0_words(line_words),
        .l1_go(), .l1_wbase(), .l1_words(),
        .l0b_go(line_go_b), .l0b_wbase(line_wbase_b), .l0b_words(line_words_b),
        .l1b_go(), .l1b_wbase(), .l1b_words(),
        .rd_index(rd_index), .hit(hit),
        .rd_index_b(rd_index_b), .hit_b(hit_b), .fu(), .fv()
    );

    // ============================================================
    //  ② 行缓冲 + 预取（搬运在显存域那半）
    //     显示用哪一块 = 当前屏幕行号的奇偶（line_buf 内部按这个选）
    // ============================================================
    wire [15:0] pix_out;
    wire        pix_ready;

    // ---- 两路各自的读口 + 那把"读口锁" ----
    wire        en_a, en_b;
    wire [20:0] addr_a, addr_b;
    wire        vld_a, vld_b;
    wire        want_a, want_b;
    wire        gnt_a, gnt_b;
    // ★ 块级：两路各自的 块请求 / 想不想要字
    wire        breq_a, breq_b, bwant_a, bwant_b;
    wire [20:0] bbase_a, bbase_b, blen_a, blen_b;

    line_buf #(.LINE_MAX(LINE_MAX), .MAX_OUT(MAX_OUT)) u_lb (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .line_parity(pix_y[0]),
        .line_go(line_go), .line_wbase(line_wbase), .line_words(line_words),
        .rd_index(rd_index), .pix_out(pix_out), .pix_ready(pix_ready),
        .o_filling(o_filling),
        .o_want(want_a), .rd_gnt(gnt_a),
`ifdef B_DEBUG_PROBE
        .o_dbg_wbase(o_dbg_wbase), .o_dbg_fwords(o_dbg_fwords),
        .o_dbg_rd0(o_dbg_rd0), .o_dbg_rd1(o_dbg_rd1), .o_dbg_frozen(),
        .o_drop_cnt(o_drop_cnt), .o_abort_cnt(o_abort_cnt),
`endif
        // ★★ 2026-09-28：相位必须给 0（原来把旋钮接到这儿，等于每行丢掉头 3 个脉冲）
        .mo_sel(2'd0),
        .clk_mem(clk_mem), .rst_mem_n(rst_mem_n),
        .blk_req(breq_a), .blk_base(bbase_a), .blk_len(blen_a),
        .blk_gnt(gnt_a), .blk_want(bwant_a), .blk_dv(vld_a), .blk_data(blk_data)
`ifdef B_DEBUG_PROBE
        , .o_off_first(o_off_first), .o_align_bad(o_align_bad)
`endif
    );

    // ---- 第二条行缓冲（转场：后台那张）----
    wire [15:0] pix_out_b;
    wire        pix_ready_b;
    wire        filling_b;

    line_buf #(.LINE_MAX(LINE_MAX), .MAX_OUT(MAX_OUT)) u_lb_b (
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .line_parity(pix_y[0]),
        .line_go(line_go_b), .line_wbase(line_wbase_b), .line_words(line_words_b),
        .rd_index(rd_index_b), .pix_out(pix_out_b), .pix_ready(pix_ready_b),
        .o_filling(filling_b),
        .o_want(want_b), .rd_gnt(gnt_b),
        .mo_sel(2'd0),
        .clk_mem(clk_mem), .rst_mem_n(rst_mem_n),
        .blk_req(breq_b), .blk_base(bbase_b), .blk_len(blen_b),
        .blk_gnt(gnt_b), .blk_want(bwant_b), .blk_dv(vld_b), .blk_data(blk_data)
    );

    // ============================================================
    //  ②b-1 读口锁：两条行缓冲共用 sdr_arb 的**同一个读口**
    // ------------------------------------------------------------
    //  为什么必须"整趟独占 + 先给读口再搬"：行缓冲是**信用流控**的 ——
    //  它每发一个请求就把 fsent 加一，然后只等着收同样多的字。要是仲裁
    //  在这一趟中间把它的请求掐掉一拍，那个字就永远收不回来 → 看门狗放弃
    //  这一行 → 屏上那行变底色。所以：
    //    · 按【一趟】独占：谁在搬，读口整趟归谁，搬完（filling 落）再换人；
    //    · 没拿到读口的那一路**根本不开始搬** —— line_buf 多了一个 `rd_gnt`
    //      输入和 `o_want` 输出（请求挂着等读口，见 line_buf.v 端口那一段）。
    //      ★ 这一条是关键：第一版"先发请求、不给了就掐"的写法在 tb 里
    //        当场红 —— 后台那一路的请求被吃掉 → 它一直 filling 到看门狗
    //        超时 → 前台也跟着被饿死（只对了 24% 的像素）。
    //
    //  ★ 为什么还要等 RELEASE_GAP 拍才真放锁：万一是**看门狗掐断**的
    //    （filling 落了但还有在途响应），这些尾巴仍然算在原主人头上
    //    （原主人在 !filling 时本来就忽略 vld），不会串进另一条缓冲里。
    // ============================================================
    localparam integer RELEASE_GAP = 16;

    reg [1:0] rd_lock;         // 0 = 空 1 = 甲方(前台) 2 = 乙方(后台)
    reg [4:0] rel_cnt;

    assign gnt_a = (rd_lock == 2'd1);
    assign gnt_b = (rd_lock == 2'd2);
    wire idle_a = ~o_filling;              // 甲不在搬
    wire idle_b = ~filling_b;              // 乙不在搬

    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            rd_lock <= 2'd0;
            rel_cnt <= 5'd0;
        end
        else if (rd_lock == 2'd0) begin
            rel_cnt <= 5'd0;
            // ★ 两人同时开搬时【让甲方先】—— 甲方是现在屏上这位，
            //   错过了这一行就会露出一行底色；乙方这一行可以晚一点补。
            if (want_a)      rd_lock <= 2'd1;
            else if (want_b) rd_lock <= 2'd2;
        end
        else begin
            if ((gnt_a && idle_a) || (gnt_b && idle_b)) begin
                if (rel_cnt >= RELEASE_GAP[4:0]) begin
                    rd_lock <= 2'd0;
                    rel_cnt <= 5'd0;
                end
                else rel_cnt <= rel_cnt + 5'd1;
            end
            else rel_cnt <= 5'd0;
        end
    end

    // ★★★ 2026-10-06 块级：谁拿到读口（gnt_a/gnt_b），谁的 块请求/要字 就往上传；
    //   回来的 blk_dv/blk_data 同样按 gnt 分回那一路（和原来的分流结构一模一样）。
    assign blk_req  = gnt_b ? breq_b  : (gnt_a ? breq_a  : 1'b0);
    assign blk_base = gnt_b ? bbase_b : bbase_a;
    assign blk_len  = gnt_b ? blen_b  : blen_a;
    assign blk_want = gnt_b ? bwant_b : bwant_a;
    assign vld_a    = blk_dv && gnt_a;
    assign vld_b    = blk_dv && gnt_b;

    // ============================================================
    //  ③ 输出寄存一拍：窗口内给源图像素、窗口外给底色
    //     ★ 只在"命中"且"这一块已经填好"时才给图，否则给底色 ——
    //       这样即使某一行没来得及搬（或源图那一行不存在），屏上也只是底色，
    //       不会闪雪花。
    // ============================================================
    //  ★★ 2026-09-27 改（配合 line_buf 的"同步读出 = BRAM"）：
    //    数据那一路【不再寄存第二次】。line_buf 的读出已经寄存了一拍，
    //    这里要是再寄存一拍，就比 de_out / vs_out 晚一拍 ——
    //    屏上正是"整幅图左移/右移一个像素"那类最难查的毛病。
    //    所以现在是：
    //      · 选通 use_src_q：和 de_out / vs_out 一起打一拍
    //      · 数据 rgb565  ：由 use_src_q 组合选出（内容来自 line_buf 的读出寄存器）
    //    三者对着的是【同一个像素】，一个像素都不差。
    wire use_src = hit && pix_ready;
    reg  use_src_q;

    // ---- 第二路同款的一拍（和 use_src_q 完全对称，两者同拍）----
    wire use_src_b = hit_b && pix_ready_b;
    reg  use_src_b_q;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            use_src_q   <= 1'b0;
            use_src_b_q <= 1'b0;
            de_out      <= 1'b0;
            vs_out      <= 1'b0;
        end
        else begin
            use_src_q   <= use_src;
            use_src_b_q <= use_src_b;
            de_out      <= pix_de;
            vs_out      <= vs;
        end
    end

    assign o_win_a = use_src_q;
    assign o_win_b = use_src_b_q;
    assign o_px_a  = use_src_q   ? pix_out   : bg_color;
    assign o_px_b  = use_src_b_q ? pix_out_b : bg_color;

    // ★ 没接转场之前，本模块自己的输出仍然 = 前台那一路（一字不差）
    assign rgb565  = o_px_a;

endmodule
