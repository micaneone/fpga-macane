// ============================================================
//  模块名 : subtitle_ovl —— 【字幕叠加】（像素流水第 ④ 级）
//  层次   : 转场之后、565→888 之前（disp_top 里的最后"画"一下）
//  时钟域 : 像素域 40 MHz
//  依据   : 规划\B轨待改清单.md §24；artwork_def.v 的
//           SDR_SUBTITLE_BASE / SDR_SUBTITLE_STRIDE / ART_SUB_W / ART_SUB_H / FMT_MASK1
// ------------------------------------------------------------
//  干什么（一句话）：把 SDRAM 字幕区里的 **1bpp 遮罩**叠到画面上 ——
//      **bit = 1 画 ink（默认黑 = 文字）**；**bit = 0 透传**（白底不画）。
//      （用户 2026-10-08 定：就按这个极性，不再做可配的透传/反白）
//
//  数据长什么样（★ 由 A 轨 sub_analyze 定，别再自己猜）：
//      · 一条字幕 **1600 字 = 25 字/行 × 64 行**（800 = 32×25，没有一个像素跨字边界）
//      · **bit31 = 这 32 个像素里最左边那个**
//      · **行序是"自下而上"**（A 原样保留了 BMP 的存法）
//        ⇒ 屏幕第 k 行（从字幕顶算）要用 SDRAM 里的第 **(63-k)** 行 ★ 必须反一次
//      · 基址 = `SDR_SUBTITLE_BASE(2,085,760) + 条号 × 1600`
//
//  它是怎么读的（★ 为什么不逐拍读）：
//      字幕**不缩放**（800×64 原尺寸贴上去）⇒ **一条扫描线正好要一行遮罩**（25 字）。
//      所以：**在"上一条扫描线"结束的那一拍，把下一条线要用的那一行整行取回来**
//      （25 字的短块，走 blk_rd_arb）→ 下一个行周期里从行缓冲里取位。
//        一条行周期 26.4 µs，取一行 25 字 ≈ 0.4 µs ⇒ 余量非常大。
//      一帧只借 64 次 × 25 字 ≈ 2200 拍，占读口 0.1% —— 对显示毫无影响。
//
//  ★★ 位置是【端口】，不是写死的常数 —— 现在由顶层给一个暂定值，
//     以后 C 轨的窗口表（`WIN_SUB` 那一条）直接接上来就行，本模块不用改。
//
//  ★ 声明全部前置（这个工程踩过五次"先用后声明"）
// ============================================================
`timescale 1ns / 1ps

module subtitle_ovl (
    input  wire        clk_pix,
    input  wire        rst_pix_n,

    // ---------------- 像素流水（★ 这四根必须和 px_in 同拍）----------------
    input  wire        de_in,
    input  wire        vs_in,
    input  wire [11:0] x_in,        // 屏幕坐标（disp_top 给 o_dbg_x：和 de_in 同一像素）
    input  wire [11:0] y_in,        // 屏幕坐标（o_dbg_y）
    input  wire [15:0] px_in,       // RGB565（转场之后的像素）
    output reg  [15:0] px_out,      // ★ 比输入晚一拍（de/vs 跟着打同样一拍）
    output reg         de_out,
    output reg         vs_out,

    // ---------------- ★ 字幕参数（接口留出来：以后由 C 的窗口表驱动）----------------
    input  wire        sub_on,      // 1 = 这条字幕要显示（= SDRAM 里已经有了）
    input  wire [11:0] sub_x0,      // 字幕左上角（屏幕坐标）
    input  wire [11:0] sub_y0,
    input  wire [11:0] sub_w,       // 契约固定 800
    input  wire [11:0] sub_h,       // 契约固定 64
    input  wire [20:0] sub_base,    // 字幕区基址 + 条号×1600
    input  wire [15:0] ink,         // bit=1 画这个颜色（默认 16'h0000 = 黑）

    // ---------------- 读口（第三个客户 → blk_rd_arb）----------------
    output wire        mem_req,
    output wire [20:0] mem_base,
    output wire [20:0] mem_len,
    input  wire        mem_gnt,
    output wire        mem_next,
    input  wire        mem_dv,      // 数据这一拍有效（blk_rd_arb 的 o_dv bit2）
    input  wire [31:0] mem_data,
    input  wire        mem_fin,     // 单拍：这一块完了（blk_rd_arb 的 s_done）

    // ---------------- 诊断 ----------------
    output reg  [15:0] o_row_cnt,   // 一共取回来多少行
    output reg         o_hit        // sticky：真的画过（bit=1）至少一次
);

    // ============================================================
    //  契约常数
    // ============================================================
    localparam integer SUB_WORDS = 25;          // 800 / 32：一行遮罩 = 25 个字
    localparam [4:0]   LAST_W    = 5'd24;       // 最后一个字的序号
    localparam [4:0]   N_WORDS   = 5'd25;
    localparam [20:0]  WLEN      = 21'd25;      // 一次块请求要多少个字

    // ============================================================
    //  一、行缓冲（25 个字）+ 取数状态机
    // ============================================================
    reg [31:0] rb [0:SUB_WORDS-1];              // 当前这一行的遮罩
    reg        buf_valid;                       // 行缓冲里这一行是有效的

    localparam [1:0] F_IDLE = 2'd0,
                     F_GNT  = 2'd1,             // 举着 req 等 blk_rd_arb 受理
                     F_COLL = 2'd2;             // 受理了，逐字收

    reg  [1:0]  fst;
    reg         m_req, m_next;
    reg  [20:0] m_base;
    reg  [4:0]  wcnt;
    reg  [11:0] cur_y;                          // 现在画到第几行
    reg         de_d;
    reg [20:0]  off_r;                          // ★ 声明前置

    assign mem_req  = m_req;
    assign mem_base = m_base;
    assign mem_len  = WLEN;
    assign mem_next = m_next;

    // ---- 下一条线要不要字幕？要哪一行？----
    wire        de_fall = de_d & ~de_in;        // 一条活动线结束
    wire [11:0] y_next  = cur_y + 12'd1;
    wire        need_fetch = sub_on && (y_next >= sub_y0) &&
                             (y_next < (sub_y0 + sub_h));
    // ★ 自下而上：屏幕第 k 行用 SDRAM 的第 (63-k) 行
    //   ★★ 这里写成 `(sub_y0+sub_h)-1-(y_next-sub_y0)` 是错的（sub_y0 算了两遍）——
    //     第一版就是这么写的，被 tb_subtitle_ovl 一把逮住（码出来全是 X = 地址越界）。
    wire [11:0] srow_next = (sub_h - 12'd1) - (y_next - sub_y0);
    // ★ ×25 用"移位相加"写死，别让工具去推乘法器（DSP 已经 29/29 顶格）
    wire [20:0] off_next = {5'b0, srow_next, 4'b0}      // srow<<4
                         + {6'b0, srow_next, 3'b0}      // srow<<3
                         + {9'b0, srow_next};           // srow

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            fst       <= F_IDLE;
            m_req     <= 1'b0;
            m_next    <= 1'b0;
            m_base    <= 21'd0;
            wcnt      <= 5'd0;
            cur_y     <= 12'd0;
            de_d      <= 1'b0;
            buf_valid <= 1'b0;
            o_row_cnt <= 16'd0;
            off_r     <= 21'd0;
        end
        else begin
            de_d <= de_in;
            if (de_in) cur_y <= y_in;           // 记下"现在画到哪一行"

            case (fst)
            // ---- 空闲：等"上一条线画完"，再把下一条线要用的那一行取回来 ----
            F_IDLE: begin
                m_next <= 1'b0;
                if (de_fall && need_fetch) begin
                    m_base    <= sub_base + off_next;
                    off_r     <= off_next;
                    m_req     <= 1'b1;
                    buf_valid <= 1'b0;          // 新的一行还没到，先别画
                    fst       <= F_GNT;
                end
            end
            // ---- 等仲裁器受理 ----
            F_GNT: begin
                if (mem_gnt) begin
                    wcnt <= 5'd0;
                    fst  <= F_COLL;
                end
            end
            // ---- 逐字收（mem_dv 那一拍 = 数据有效）----
            F_COLL: begin
                m_next <= (wcnt < N_WORDS);
                if (mem_dv && (wcnt <= LAST_W)) begin
                    rb[wcnt] <= mem_data;
                    wcnt     <= wcnt + 5'd1;
                    if (wcnt == LAST_W) begin
                        buf_valid <= 1'b1;      // ★ 这一行齐了
                        if (o_row_cnt != 16'hFFFF) o_row_cnt <= o_row_cnt + 16'd1;
                    end
                end
                // 收满了、或仲裁器说这一块收了（/被看门狗掐断）→ 收手
                if ((wcnt >= N_WORDS) || mem_fin) begin
                    m_req  <= 1'b0;
                    m_next <= 1'b0;
                    fst    <= F_IDLE;
                end
            end
            default: fst <= F_IDLE;
            endcase
        end
    end

    // ============================================================
    //  二、像素级：在不在字幕矩形里；在就取那一位
    //      ★ 这四根（px_in / de_in / x_in / y_in）是同一拍 ⇒ 输出寄存一拍
    // ============================================================
    wire [11:0] sx = x_in - sub_x0;
    wire [11:0] sy = y_in - sub_y0;
    wire in_rect = sub_on && de_in
                && (x_in >= sub_x0) && (x_in < (sub_x0 + sub_w))
                && (y_in >= sub_y0) && (y_in < (sub_y0 + sub_h));
    wire [4:0]  wi = sx[9:5];                   // 第几个字（0..24）
    wire [4:0]  bi = sx[4:0];                   // 字里的第几位（0 = 最右）
    wire [31:0] sel_word = rb[wi];
    // ★ 用"右移"取位，不用非常量位选（老工具对那种写法挑）
    wire        ink_bit  = buf_valid &&
                           ((sel_word >> (5'd31 - bi)) & 32'd1) == 32'd1;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            px_out <= 16'h0000;
            de_out <= 1'b0;
            vs_out <= 1'b0;
            o_hit  <= 1'b0;
        end
        else begin
            de_out <= de_in;                    // ★ de/vs 和像素打同样一拍，绝不拆开
            vs_out <= vs_in;
            if (in_rect && ink_bit) begin
                px_out <= ink;                  // bit=1 → 画（黑 = 字）
                o_hit  <= 1'b1;
            end
            else begin
                px_out <= px_in;                // bit=0（或不在字幕里）→ 透传
            end
        end
    end

endmodule
