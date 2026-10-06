// ============================================================
//  模块名 : scaler_addr
//  作用   : 【缩放取样地址发生器】—— 把屏幕像素映射成源图坐标，
//           算出"这一行要读哪儿、读多少字、每个屏幕像素对到缓冲哪个位置"
//  层次   : 像素流水七级的第 ③ 级"取样"（取代 win_sample 在流水线里的位置）
//  时钟域 : 像素域 40 MHz（只算地址；真正的搬运交给 line_buf）
//  依据   : 规划\B轨缩放器设计说明.md §3 §5；契约第二节第 ②③④ 条
// ------------------------------------------------------------
//  公式（step = 1/Z，Q16.16）：
//      u = off_u + x' * step          x' = pix_x - win_x0
//      v = off_v + y' * step          y' = pix_y - win_y0
//      源列 u_int = u>>16，源行 v_int = v>>16
//      字地址 = src_base + v_int*WPL + (u_int>>1)，WPL = (src_w+1)/2
//
//  ★ 与 win_sample 的三点区别：
//    ① 取样不再 1:1：x' 要乘 step 才得到源列，所以每行读的字数会变；
//    ② 起点必须 4 字对齐：行内起点 w_off = (u_first>>1) & ~3（见设计说明 §5.1），
//       rd_index 相应平移 (u_int - 2*w_off)；
//    ③ 放大要第二行：l1_* 是源图第 v+1 行的请求（bilin_en=0 时不发）。
//
//  ★ 水平取数范围是【整帧常量】：u 只跟 x'、step 有关，不跟行号走，
//    所以 w_off / line_words 一帧之内算一次就够（这里用组合逻辑现算）。
//
//  ★ 延迟：本模块的全部输出都是【组合】的（当拍给、当拍有效），
//    与 win_sample 一致 —— 这样 line_buf 的"同步读出 1 拍"+ 输出级 1 拍
//    这个现有节奏一点不用改。（若以后综合报时序紧，再在这里插流水，
//    并把 win_compositor 的 de/vs 同步延迟同样的拍数。）
//
//  ★ 本文件不 `include artwork_def.v（不依赖工具的 include 搜索路径）。
// ============================================================
`timescale 1ns / 1ps

module scaler_addr #(
    // ★ 行序翻转（临时兜底，和 win_sample 里那一处同源）：
    //   现在 SDRAM 里存的图是【自下而上】的（A 的装载顺序，见
    //   规划\A轨待改清单.md「BMP 上下翻转」那条），所以显示时要把行号翻过来。
    //   ★ A 把装载行序改正之后，把它改成 0 即可（此处是唯一一处翻转）。
    parameter integer VFLIP = 1
)(
    input  wire        clk_pix,
    input  wire        rst_pix_n,

    // ---------------- 源图参数（来自 desc_rx）----------------
    input  wire        src_valid,
    input  wire [20:0] src_base,
    input  wire [11:0] src_w,
    input  wire [11:0] src_h,

    // ---------------- ★★ 2026-10-03（转场·二路取样）第二路源图 ----------------
    //   第二路有**自己的一套缩放几何**（step_b / off_ub / off_vb）——
    //   因为两张图的适配缩放不一样，而"不经过米白"的转场要求两张图**同时在屏上**
    //   各自正确（见 规划\B轨待改清单.md §十五 的 bug 与 §十六 的做法）。
    //
    //   ★★ 预算账（DSP 只剩 3 个，只能多花 2 个）：
    //     · 每像素：u 必须各算各的 → 多一处 10×16 乘法 = **+2 个 DSP**；
    //     · 每行才用的两处（v_nxt、u_last）**同一时刻只有一个相位用得上**，
    //       所以按 pix_x 分相位共用同一套乘法器：
    //          pix_x == 0 → 算【前台】那套（老逻辑原样）
    //          pix_x == 1 → 算【后台】那套
    //       → 0 个额外 DSP；
    //     · v 在**一行里是常数**（只随屏幕行号变），所以后台的 v 按行寄存
    //       （v_b_q），不在像素级重算 → 也是 0 个 DSP。
    //   ★ 代价：后台的行请求比前台晚一拍发（pix_x==1 而不是 0）——
    //     一行两千多拍，晚一拍毫无影响。
    //   ★ 没做的：两条路各自的双线性权重（fu/fv）还是共用前台的；
    //     现在 bilin_en 恒 0（最近邻），等真要接双线性再补。
    input  wire        src_b_valid,
    input  wire [20:0] src_b_base,
    input  wire [11:0] src_b_w,
    input  wire [11:0] src_b_h,

    // ---------------- ★ 第二路的缩放几何（来自 zoom 那两套参数）----------------
    input  wire [31:0]        step_b_q16,   // 1/Z_b，Q16.16
    input  wire signed [31:0] off_ub_q16,   // 后台那张的居中偏移
    input  wire signed [31:0] off_vb_q16,

    // ---------------- 窗口矩形（屏幕坐标，来自窗口表）----------------
    input  wire        win_on,
    input  wire [11:0] win_x0,
    input  wire [11:0] win_y0,
    input  wire [11:0] win_w,
    input  wire [11:0] win_h,

    // ---------------- 缩放参数（来自 zoom_sel）----------------
    input  wire [31:0]        step_q16,     // 1/Z，Q16.16（1.0 = 0x0001_0000）
    input  wire signed [31:0] off_u_q16,    // 窗口左上角对应的源列，Q16.16
    input  wire signed [31:0] off_v_q16,    // 窗口左上角对应的源行，Q16.16
    input  wire               bilin_en,     // 1 = 放大档，要第二行（插值）

    // ---------------- 当前扫描位置（来自 video_timing）----------------
    input  wire [11:0] pix_x,
    input  wire [11:0] pix_y,
    input  wire        pix_de,

    // ---------------- 行请求 0：源图第 v 行（给 line_buf A）----------------
    output reg         l0_go,
    output reg  [20:0] l0_wbase,
    output reg  [11:0] l0_words,

    // ---------------- 行请求 1：源图第 v+1 行（给 line_buf B；bilin_en=0 时不发）----
    output reg         l1_go,
    output reg  [20:0] l1_wbase,
    output reg  [11:0] l1_words,

    // ---------------- 第二路的行请求（给第二个 line_buf）----------------
    output reg         l0b_go,
    output reg  [20:0] l0b_wbase,
    output reg  [11:0] l0b_words,
    output reg         l1b_go,
    output reg  [20:0] l1b_wbase,
    output reg  [11:0] l1b_words,

    // ---------------- 像素查找（组合给 line_buf 的读口）----------------
    output wire [11:0] rd_index,   // 像素在"搬进来的那一段"里的序号（0 起）
    output wire        hit,        // 这一拍这个像素该显示源图
    output wire [11:0] rd_index_b, // ★ 第二路在它自己那一段里的序号
    output wire        hit_b,      // ★ 第二路这一拍是否有有效像素
    output wire [7:0]  fu,         // 列插值权重（u 的小数高位）；最近邻时 = 0
    output wire [7:0]  fv          // 行插值权重（v 的小数高位）；最近邻时 = 0
);

    // ============================================================
    //  ① 每行字数（契约第二节第 ② 条）
    // ============================================================
    wire [11:0] wpl = (src_w + 12'd1) >> 1;

    // ============================================================
    //  ② 屏幕 -> 窗口内坐标
    //     ★ 加法必须扩到 13 位再比：win_x0 + win_w 可能超过 12 位
    // ============================================================
    wire [12:0] win_x1 = {1'b0, win_x0} + {1'b0, win_w};
    wire [12:0] win_y1 = {1'b0, win_y0} + {1'b0, win_h};
    wire        in_x   = ({1'b0, pix_x} >= {1'b0, win_x0}) && ({1'b0, pix_x} < win_x1);
    wire        in_y   = ({1'b0, pix_y} >= {1'b0, win_y0}) && ({1'b0, pix_y} < win_y1);
    wire [11:0] xp     = pix_x - win_x0;      // 仅在 in_x 时有意义
    wire [11:0] yp     = pix_y - win_y0;      // 仅在 in_y 时有意义

    // ============================================================
    //  ③ 定点映射：u = off_u + x'*step、v = off_v + y'*step
    //     ★ 显式扩到 32 位再相加；u_q/v_q 按 32 位补码看
    // ============================================================
    // ★★★ 2026-10-03 乘法器瘦身【第二版，真正起作用的一版】（为四窗口腾 DSP）
    //
    //  ★ 第一版（只把 xp/yp 从 12 位收到 10 位）**没用**：实测还是 28 个 DSP。
    //    原因：TD 的 DSP 用量是被【32 位那个操作数】撑起来的 —— 10 位 × 32 位
    //    一样要拆 2~3 块，每处乘法仍是 3 个 DSP（scaler_addr 一共 9 个）。
    //    ⇒ **必须把 step 本身压窄**，一次乘法才会落进 1 个 18×18 DSP。
    //
    //  ★ 压法：step 用【Q4.12】—— 16 位、4 位整数 + 12 位小数，范围 [0, 16.0)。
    //     · 范围够：step = 1/Z，16.0 对应 Z = 0.0625；档位、适配（通常 ≥ 0.25）、
    //       以及我们 tb 里最极端的 step = 8.0（Z = 0.125）都在范围内；真超了就饱和。
    //     · 精度够：分辨率 1/4096 → 屏幕最右边（x'=799）累计位置误差
    //       ≤ 799/4096 = 0.195 像素 —— 纯亚像素，肉眼不可见。
    //     · 档位表那五档（1×/1.5×/2×/3×/4×）的 step 都是 8 的整数倍，
    //       Q16.16 → Q4.12 的换算是【精确】的，那几档一点误差都没有。
    //   换算：Q16.16 右移 4 位 = 乘 4096 = Q4.12 ✓；乘法结果再左移 4 位回到 Q16.16。
    wire [15:0] step12 = (step_q16[31:20] != 0) ? 16'hFFFF : step_q16[19:4];

    // xp / yp 只要 10 位：窗口宽 ≤ 800、高 ≤ 600 → x'/y' ≤ 799。
    // （像素在窗口上方/左侧时 xp/yp 会回绕成大数，但那时 in_x/in_y=0、hit=0，
    //   算出来的 rd_index 被合成器丢弃 —— 回绕值不影响任何真实结果。）
    wire [9:0]  xp10 = xp[9:0];
    wire [9:0]  yp10 = yp[9:0];

    wire [25:0] prod_u = xp10 * step12;                        // ≤ 799×65535 < 2^26
    wire [25:0] prod_v = yp10 * step12;
    wire [31:0] u_q    = off_u_q16 + {2'd0, prod_u, 4'b0000};   // Q4.12 → Q16.16
    wire [31:0] v_q    = off_v_q16 + {2'd0, prod_v, 4'b0000};

    // ---- ★ 第二路（后台）的每像素 u：自己一套 step12/off ----
    wire [15:0] step12_b = (step_b_q16[31:20] != 0) ? 16'hFFFF : step_b_q16[19:4];
    wire [25:0] prod_u_b = xp10 * step12_b;
    wire [31:0] u_q_b    = off_ub_q16 + {2'd0, prod_u_b, 4'b0000};
    wire [15:0] u_int_b  = u_q_b[31:16];

    wire [15:0] u_int  = u_q[31:16];        // 源列（无符号看；负值会 ≥ 0x8000）
    wire [15:0] v_int  = v_q[31:16];        // 源行
    wire [15:0] src_w16 = {4'd0, src_w};
    wire [15:0] src_h16 = {4'd0, src_h};
    wire [15:0] src_b_w16 = {4'd0, src_b_w};
    wire [15:0] src_b_h16 = {4'd0, src_b_h};

    // ★ 负值（2's complement）会变成 ≥ 0x8000 的大无符号数，
    //   而 src_w/src_h ≤ 4095，所以这一个"<"同时挡掉负数和越界。
    wire u_in = (u_int < src_w16);
    wire v_in = (v_int < src_h16);

    assign hit = pix_de && win_on && src_valid && in_x && in_y && u_in && v_in;


    // ============================================================
    //  ④ 整帧常量：水平取数范围 + 4 字对齐起点
    // ============================================================
    wire [11:0] xp_last     = (win_w == 12'd0) ? 12'd0 : (win_w - 12'd1);
    // ★ 同一套窄定点：xp_last = win_w-1 ≤ 799（10 位）× step(Q4.12)
    // ★★ 每行那两处乘法按 pix_x 分相位共用（**0=后台 1=前台**）：
    //    "同一时刻只有一个相位用得上" —— 后台的都读在 pix_x==0 那一拍，
    //    前台的都读在 pix_x==1 那一拍。
    //    ★ 为什么后台放 0：后台的 v 要"这一行一直用同一个值"，
    //      所以必须在行首那一刻就算出来（然后行内取寄存器，
    //      行首那一拍直接旁路用组合值）；放 1 会差一拍。
    //    ★ 前台挪到 pix_x==1 完全没关系：它只是"下一行的行请求"晚一拍发，
    //      一行两千多拍，晚一拍不算什么。
    wire        ph_b     = (pix_x == 12'd0);
    wire [15:0] step12_m = ph_b ? step12_b : step12;
    wire [31:0] step_m   = ph_b ? step_b_q16 : step_q16;
    wire signed [31:0] offu_m = ph_b ? off_ub_q16 : off_u_q16;
    wire signed [31:0] offv_m = ph_b ? off_vb_q16 : off_v_q16;

    wire [25:0] prod_u_last = xp_last[9:0] * step12_m;
    wire [31:0] u_last_q    = offu_m + {2'd0, prod_u_last, 4'b0000};

    wire [15:0] u_first_raw = off_u_q16[31:16];
    wire [15:0] u_last_raw  = u_last_q[31:16];

    // 钳到 [0, src_w-1]：负 -> 0；≥src_w -> src_w-1
    function [11:0] clamp_sw;
        input [15:0] v;
        input [15:0] sw;
        begin
            if (sw == 16'd0)              clamp_sw = 12'd0;
            else if (v[15])               clamp_sw = 12'd0;          // 负数
            else if (v < sw)              clamp_sw = v[11:0];
            else                          clamp_sw = sw[11:0] - 12'd1;
        end
    endfunction

    wire [11:0] u_first = clamp_sw(u_first_raw, src_w16);
    wire [11:0] u_last  = clamp_sw(u_last_raw,  src_w16);

    wire [11:0] u_first_w = u_first >> 1;              // 行内第一个字（未对齐）
    // 覆盖到 u_last+1 那个像素所在的字（双线性要用右邻居）
    wire [11:0] u_last_w  = (u_last + 12'd1) >> 1;
    // ★★ 2026-10-03 绝对 4 字对齐（转场前置：大槽 1 的基址 930830 不是 4 的倍数）
    //   以前只把"行内偏移"对齐 = 隐含要求行起点本身是 4 的倍数。
    //   现在按【绝对地址】向下取到 4 的倍数：
    //       abs    = row_start + (u_first>>1)
    //       wbase  = abs & ~3              ← 绝对 4 字对齐
    //       align_w= row_start − wbase     ← 往前退了多少个字（有符号）
    //   align_w 随行变化（看 row_start mod 4），所以必须跟着搬运【按行寄存】；
    //   rd_index = u_int + align_w×2（符号相反：退多了就往后挪）。
    reg  signed [15:0] align_px_cur;                   // 本行用（上一行发请求时算好的）
    reg  [20:0]        row_s0, abs_w0, wbase0;         // 行 0：行首 / 未对齐字 / 对齐起点
    reg  [20:0]        row_s1, abs_w1, wbase1;         // 行 1（v+1，双线性用）
    reg  signed [15:0] align_w0, align_w1, words_s0;   // 退几个字 / 本行读多少字

    // ---- 第二路：同样的量，各算各的 ----
    //   ★ 为什么 钳位 / 命中 / 字数 都要按 src_b_w 重算一遍：
    //     转场两幅图【共用窗口几何】（step/off 一样），但两幅图的源宽高可以不同
    //     （比如 640×480 对 600×800）。于是 u_first/u_last 钳到各自 src_w 之后
    //     就可能不一样 —— 第二路按自己的宽度判命中、按自己的宽度算"这一行读多少字"，
    //     源图没盖到的地方（hit_b=0）自然露出前一幅图 / 底色，划像才不会串。
    reg  signed [15:0] b_align_px_cur;
    reg  [20:0]        b_row_s0, b_abs_w0, b_wbase0;
    reg  [20:0]        b_row_s1, b_abs_w1, b_wbase1;
    reg  signed [15:0] b_align_w0, b_align_w1, b_words0;
    reg  [11:0]        b_v_store0;
    wire [11:0]        b_wpl      = (src_b_w + 12'd1) >> 1;
    // ★★ 后台这一路的 u_first/u_last 用【自己那张图】的 off/step 算：
    //    u_last_q 在 pix_x==1 那一拍正好是后台的值（相位共用，见上）。
    wire [11:0]        b_u_first   = clamp_sw(off_ub_q16[31:16], src_b_w16);
    wire [11:0]        b_u_last    = clamp_sw(u_last_q[31:16],   src_b_w16);
    wire [11:0]        b_u_first_w = b_u_first >> 1;
    wire [11:0]        b_u_last_w  = (b_u_last + 12'd1) >> 1;

    // ============================================================
    //  ⑤ 行请求：在行首（pix_x==0）算"下一屏幕行"要的源行
    //     ★★ 必须直接用 y' = (pix_y+1) − win_y0 算，不能拿"当前行的 v + step"凑：
    //        窗口还没开始的那几行，y' 是【负数】，而 pix_y−win_y0 在 12 位里会
    //        回绕成极大值 —— 用它当"当前行"再去加 step，算出来的 v_nxt 巨大，
    //        nxt_valid 永远是 0，于是【第一行请求根本发不出去】（tb 抓到的 bug）。
    //        所以这里用 13 位带符号的 y'，负数就明确地"不发请求"。
    // ============================================================
    wire signed [12:0] yp_nxt_s = $signed({1'b0, pix_y}) + 13'sd1
                                  - $signed({1'b0, win_y0});
    // 当前屏幕行的 y'（后台用；前台那一拍用的是 yp_nxt_s）
    wire signed [12:0] yp_cur_s = $signed({1'b0, pix_y}) - $signed({1'b0, win_y0});
    // ★ 同一处乘法分相位共用：
    //     pix_x==0 → yp_cur × 后台几何 = **后台本行的 v**（vq_m）
    //     pix_x==1 → yp_nxt × 前台几何 = 前台下一行的 v
    wire signed [12:0] yp_m = ph_b ? yp_cur_s : yp_nxt_s;
    // ★ 这里必须【带符号扩展】（$signed(yp_m) 而不是 {19'd0, yp_m}）：
    //   B 的"本行 v"在窗口上方时 y' 是负的，必须算成真的负数（否则会变成
    //   一个"看起来合法"的大正数 → v_b_nxt 落在源图范围内 → 发一次不该发的
    //   行请求）。前台那条老写法（零扩展）之所以没事，是因为 y' 为负时它
    //   本来就不发请求，两种写法结果一样。
    wire signed [31:0] vq_m = offv_m + $signed(yp_m) * $signed(step_m);
    // ★ 后台"下一行"的 v = 本行 v + step（数学上完全等价，省掉一次乘法）
    wire signed [31:0] vq_b_nxt = vq_m + step_m;
    wire [15:0] v_b_nxt = vq_b_nxt[31:16];

    // ---- 第二路"本行"的 v：行内取寄存器，行首那一拍旁路用组合值 ----
    reg  [31:0] v_b_q;
    wire [31:0] v_b_use = (pix_x == 12'd0) ? vq_m : v_b_q;
    wire [15:0] v_int_b = v_b_use[31:16];
    wire        u_in_b  = (u_int_b < src_b_w16);
    wire        b_v_in  = (v_int_b < src_b_h16);

    wire signed [31:0] v_q_nxt  = vq_m;          // 前台那一拍（pix_x==1）的值
    wire [15:0] v_nxt = v_q_nxt[31:16];

    wire nxt_valid = win_on && src_valid
                   && (!yp_nxt_s[12])                // y' >= 0（13 位带符号，最高位是符号位）
                   && (v_nxt < src_h16);             // 含"负值"和"越界"

    // ★ 第二路的"下一行该不该发请求"：用后台自己的下一行 v（v_b_nxt）
    //   （★ 这条求值的相位在下面 B 的行请求块里，pix_x==0）
    wire b_nxt_valid = win_on && src_b_valid
                     && (!yp_nxt_s[12]) && (v_b_nxt < src_b_h16);

    reg [11:0] v_store0;     // 逻辑行号 -> 存储行号（VFLIP），行首算一次的临时量

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            l0_go <= 1'b0; l0_wbase <= 21'd0; l0_words <= 12'd0;
            l1_go <= 1'b0; l1_wbase <= 21'd0; l1_words <= 12'd0;
            l0b_go <= 1'b0; l0b_wbase <= 21'd0; l0b_words <= 12'd0;
            l1b_go <= 1'b0; l1b_wbase <= 21'd0; l1b_words <= 12'd0;
            v_b_q  <= 32'd0;
        end
        else begin
            l0_go <= 1'b0;                    // 默认不给脉冲
            l1_go <= 1'b0;
            l0b_go <= 1'b0;
            l1b_go <= 1'b0;

            // ★★ 前台的行请求挪到 pix_x==1（见上面分相位共用那一段）
            if (pix_de && (pix_x == 12'd1) && nxt_valid) begin
                // ★ 逻辑行号 -> 存储行号（VFLIP=1 时翻过来）
                v_store0 = VFLIP ? (src_h - 12'd1 - v_nxt[11:0]) : v_nxt[11:0];

                row_s0   = src_base + ({9'd0, v_store0} * {9'd0, wpl});
                abs_w0   = row_s0 + {9'd0, u_first_w};
                wbase0   = {abs_w0[20:2], 2'b00};               // 绝对 4 字对齐
                align_w0 = row_s0 - wbase0;                     // 可为负
                words_s0 = u_last_w + align_w0 + 16'sd1;
                align_px_cur <= align_w0 <<< 1;                 // ×2 = 像素偏移
                l0_wbase <= wbase0;
                l0_words <= words_s0[11:0];
                l0_go    <= 1'b1;

                // 放大档才要第二行（逻辑行 v+1，翻转后就是存储行 v_store-1）；
                // v+1 越界就不发（插值时 fv 会被钳成 0）
                if (bilin_en && (v_store0 != 12'd0)) begin
                    row_s1   = src_base + ({9'd0, (v_store0 - 12'd1)} * {9'd0, wpl});
                    abs_w1   = row_s1 + {9'd0, u_first_w};
                    wbase1   = {abs_w1[20:2], 2'b00};
                    align_w1 = row_s1 - wbase1;
                    l1_wbase <= wbase1;
                    l1_words <= (u_last_w + align_w1 + 16'sd1);
                    l1_go    <= 1'b1;
                end
            end

            // ★★ 第二路（后台）：在 pix_x==0 那一拍干活 ——
            //    这一拍上 vq_m / u_last_q 才是【后台】那套的值（分相位共用），
            //    同时把后台"本行"的 v 寄存下来（行内用它，行首那次旁路）。
            if (pix_de && (pix_x == 12'd0)) begin
                v_b_q <= vq_m;                        // 后台本行的 v（行内用）

                if (b_nxt_valid) begin
                    b_v_store0 = VFLIP ? (src_b_h - 12'd1 - v_b_nxt[11:0]) : v_b_nxt[11:0];
                    b_row_s0   = src_b_base + ({9'd0, b_v_store0} * {9'd0, b_wpl});
                    b_abs_w0   = b_row_s0 + {9'd0, b_u_first_w};
                    b_wbase0   = {b_abs_w0[20:2], 2'b00};
                    b_align_w0 = b_row_s0 - b_wbase0;
                    b_words0   = b_u_last_w + b_align_w0 + 16'sd1;
                    b_align_px_cur <= b_align_w0 <<< 1;
                    l0b_wbase <= b_wbase0;
                    l0b_words <= b_words0[11:0];
                    l0b_go    <= 1'b1;

                    if (bilin_en && (b_v_store0 != 12'd0)) begin
                        b_row_s1   = src_b_base + ({9'd0, (b_v_store0 - 12'd1)} * {9'd0, b_wpl});
                        b_abs_w1   = b_row_s1 + {9'd0, b_u_first_w};
                        b_wbase1   = {b_abs_w1[20:2], 2'b00};
                        b_align_w1 = b_row_s1 - b_wbase1;
                        l1b_wbase <= b_wbase1;
                        l1b_words <= (b_u_last_w + b_align_w1 + 16'sd1);
                        l1b_go    <= 1'b1;
                    end
                end
            end
        end
    end

    // ============================================================
    //  ⑥ 像素查找序号 + 插值权重
    //     rd_index = u_int - 2*w_off（搬进来的那一段从 word w_off 开始）
    // ============================================================
    // ★ 绝对对齐后：缓冲第 0 个像素对应的行内列 = −align_px_cur
    wire signed [16:0] rd_s = $signed({5'd0, u_int}) + align_px_cur;
    assign rd_index = (rd_s >= 17'sd0) ? rd_s[11:0] : 12'd0;

    // ★ 后台用自己的 u（u_int_b，按自己那张图的 step/off 算出来的）
    wire signed [16:0] rd_s_b = $signed({5'd0, u_int_b}) + b_align_px_cur;
    assign rd_index_b = (rd_s_b >= 17'sd0) ? rd_s_b[11:0] : 12'd0;

    // ★ 第二路自己的"有没有有效像素"：范围用 src_b_w / src_b_h 判
    assign hit_b = pix_de && win_on && src_b_valid && in_x && in_y && u_in_b && b_v_in;

    // 最近邻（bilin_en=0）时权重全 0 —— 双线性通路退化成"取 p00"，
    // 正好就是缩小档要的"抽点"，两条路共用一个数据通路。
    assign fu = bilin_en ? u_q[15:8] : 8'd0;
    // v+1 不在源图里时，只用第 v 行（fv=0）
    assign fv = (bilin_en && ((v_int + 16'd1) < src_h16)) ? v_q[15:8] : 8'd0;

endmodule
