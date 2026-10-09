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

    // ---------------- 诊断 ----------------
    output reg  [15:0] o_row_cnt,   // 取回整条字幕的次数（≈ 帧数）
    output reg         o_hit        // sticky：真的画过（bit=1）至少一次
);

    // ============================================================
    //  契约常数
    // ============================================================
    localparam integer SUB_WORDS = 1600;                 // 25 字/行 × 64 行
    localparam [11:0]  WPR       = 12'd25;               // 每行 25 个字
    localparam [10:0]  LAST_W    = 11'd1599;
    localparam [20:0]  WLEN      = 21'd1600;

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

    localparam [1:0] F_IDLE = 2'd0, F_GNT = 2'd1, F_COLL = 2'd2;
    reg  [1:0]  fst;
    reg         m_req, m_next;
    reg  [10:0] wcnt;

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
            ft1       <= 1'b0;
            ft2       <= 1'b0;
            ft3       <= 1'b0;
            o_row_cnt <= 16'd0;
        end
        else begin
            ft1 <= fetch_tgl;  ft2 <= ft1;  ft3 <= ft2;      // toggle 三级同步
            case (fst)
            F_IDLE: begin
                m_next <= 1'b0;
                if (fetch_start) begin
                    m_req <= 1'b1;
                    wcnt  <= 11'd0;
                    fst   <= F_GNT;
                end
            end
            F_GNT: begin
                if (mem_gnt) begin
                    wcnt <= 11'd0;
                    fst  <= F_COLL;
                end
            end
            F_COLL: begin
                m_next <= (wcnt <= LAST_W);
                if (mem_dv && (wcnt <= LAST_W)) begin
                    cmem[wcnt] <= mem_data;                  // ★ 写侧（clk_mem）
                    wcnt       <= wcnt + 11'd1;
                    if (wcnt == LAST_W) begin
                        if (o_row_cnt != 16'hFFFF) o_row_cnt <= o_row_cnt + 16'd1;
                    end
                end
                if ((wcnt > LAST_W) || mem_fin) begin
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
    // 字地址 = 行×25 + 行内第几个字   （×25 用移位相加，别找工具要乘法器）
    wire [11:0] row_x25 = (row_cur << 4) + (row_cur << 3) + row_cur;
    wire [11:0] widx_raw = row_x25 + {7'd0, sx_cur[9:5]};
    wire [10:0] widx    = (widx_raw < 12'd1600) ? widx_raw[10:0] : 11'd0;   // 越界就指 0

    reg  [31:0] mword_q;             // 下一拍 = "下一个像素"所在的那个 32 位字
    reg         de_1, vs_1;
    reg  [11:0] x_1, y_1;
    reg  [15:0] px_1;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            mword_q <= 32'd0;
            de_1 <= 1'b0; vs_1 <= 1'b0; x_1 <= 12'd0; y_1 <= 12'd0; px_1 <= 16'd0;
        end
        else begin
            mword_q <= cmem[widx];                   // ★ 读侧（clk_pix，寄存读 = BRAM 形状）
            de_1 <= de_in;  vs_1 <= vs_in;
            x_1  <= x_in;   y_1  <= y_in;
            px_1 <= px_in;
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
    // ★ 用"右移"取位，不用非常量位选（老工具对那种写法挑）
    wire ink_bit_1 = ((mword_q >> (5'd31 - sx_1[4:0])) & 32'd1) == 32'd1;

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
            if (in_rect_1 && ink_bit_1) begin
                px_out <= ink;                    // bit=1 → 画（黑 = 字）
                o_hit  <= 1'b1;
            end
            else begin
                px_out <= px_1;                   // bit=0（或不在字幕里）→ 透传
            end
        end
    end

endmodule
