// ============================================================
//  模块名 : transition
//  作用   : 【转场混合级】—— 把"前台那张"和"后台那张"按进度混成一个像素
//  层次   : 像素流水第 ④ 级（取样之后、送 HDMI 之前）
//  时钟域 : 像素域 40 MHz（纯组合混合 + 输出寄存一拍）
//  依据   : 规划\B轨待改清单.md §九（转场工作清单 ③）、§十一（两路取样）
// ------------------------------------------------------------
//  它怎么进来的：win_compositor 已经把两路的像素都备好了，而且是**同一拍**的：
//      px_a / px_b  —— 窗口里是那张图、窗口外已经是桌面底色
//      de_in/vs_in  —— 和这两个像素同拍
//    所以这里**不需要窗口信息**：窗口外 a 和 b 都是底色，怎么混都还是底色 ✓
//
//  ★★ 接口就两样东西：**怎么切**（mode）+ **两头是不是米白**（white_a / white_b）
//       mode   0 PASS   直通 A 那一端（没转场时就是这个，屏上行为和以前一字不差）
//              1 WIPE   划像：界线从左往右扫，扫过的部分显示 B 那一端
//              2 BLIND  百叶窗：横向条纹自上而下展开（32 行一个周期）
//              3 XFADE  交叉淡化：out = A端 + (B端−A端)·prog/256
//       white_a 1 = 把 A 那一端当成米白底色（内容不看）
//       white_b 1 = 把 B 那一端当成米白底色（内容不看）
//    ★ 有了这两个掩码，"淡出/淡入"就不用单开模式了 ——
//         淡出到米白   = XFADE + white_b   （旧图 → 米白）
//         从米白淡入   = XFADE + white_a   （米白 → 新图）
//         从米白划像   = WIPE  + white_a
//         装载期屏上全米白 = PASS + white_a（**和两路内容无关**，所以这段时间
//                             可以放心把 SDRAM 读口整个静音，不会闪东西）
//    ★ 两个掩码只在"两端"上做一次 16 位 2 选 1，比单开 4 个 FADE 模式便宜，
//      而且 tb 里 6 种组合都能单独验。
//
//  ★ 为什么淡化放在这里算、而不是在别处拼：
//    整条链只有这一级**同时**握着 a 和 b。淡化每个通道一次"差值 × 系数"，
//    R/G/B 各一个 18×18 乘法器 —— 一共 3 个 DSP（预算见 §11.7）。
//
//  ★ 进度 prog 是 9 位 [0,256]（**不是** 8 位）：
//      · 256 才让 prog/256 精确等于 1，两头（全 A / 全 B）一点误差都没有；
//      · 8 位的话最大只有 255/256，米白底色会差 1 个 LSB —— 而"装载期"整屏
//        都是米白，一差就是好几秒。这种"看着没事、其实不对"的量最容易被放过。
//
//  ★ 划像/百叶窗靠**比较器**，一个 DSP 都不花（这也正是它们比交叉淡化便宜的原因）：
//      · 划像：prog 单位 = 4 个屏幕像素（界线的粗细就是 4 像素）
//      · 百叶窗：prog 高 6 位 = "本周期已经展开到第几行"（32 行一个周期）
//
//  ★ 输出寄存一拍：和 win_compositor 同一个规矩 —— rgb565 / de_out / vs_out
//    必须永远同拍，差一拍就是"整幅图横移一个像素"那类最难查的毛病。
// ============================================================
`timescale 1ns / 1ps

module transition (
    input  wire        clk_pix,
    input  wire        rst_pix_n,

    // ---------------- 输入：合成器那两路（和 de_in / vs_in 严格同拍）----------------
    input  wire        de_in,
    input  wire        vs_in,
    input  wire [15:0] px_a,        // 前台像素（窗口外 = 底色）
    input  wire [15:0] px_b,        // 后台像素（窗口外 = 底色）
    input  wire [15:0] bg_color,    // 米白底色（淡出/淡入用它）

    // ---------------- 转场控制（来自 transition_ctrl，④）----------------
    input  wire [1:0]  mode,
    input  wire        white_a,     // 1 = A 那一端当米白
    input  wire        white_b,     // 1 = B 那一端当米白
    input  wire [8:0]  prog,        // 进度 0..256（256 = 完全到"另一端"）

    // ---------------- 划像/百叶窗的几何（屏幕坐标，和输入同拍）----------------
    input  wire [11:0] pix_x,
    input  wire [11:0] pix_y,

    // ---------------- 输出：和 de_out / vs_out 严格同拍（比输入晚一拍）----------------
    output reg  [15:0] rgb565,
    output reg         de_out,
    output reg         vs_out
);

    // ============================================================
    //  ① 模式编码 + 两头（是不是换成米白）
    //   ★ white_a / white_b 写反了不会报错，只会"淡出时把新图一起淡进来"——
    //     tb 里 6 种组合（含 white_a+white_b 同时为 1）都逐位核对。
    // ============================================================
    localparam [1:0] M_PASS  = 2'd0;
    localparam [1:0] M_WIPE  = 2'd1;
    localparam [1:0] M_BLIND = 2'd2;
    localparam [1:0] M_XFADE = 2'd3;

    wire [15:0] mix_from = white_a ? bg_color : px_a;
    wire [15:0] mix_to   = white_b ? bg_color : px_b;

    // ============================================================
    //  ② 软边混合（划像 / 百叶窗 / 交叉淡化 统一走"逐像素系数"）
    //
    //  ★★★ 2026-10-17【治"画面切换不够丝滑"】
    //   原来是**硬边**：划像 `pix_x/4 < prog`、百叶窗 `pix_y[4:0] < prog[8:3]`，
    //   而 transition_ctrl 每帧只让 prog 走 16（整场 16 帧 ≈ 0.27 s）：
    //     · 划像 = 800 px ÷ 12.5 步 ⇒ **每帧跳 64 px**，整幅只出现 12 个位置；
    //     · 百叶窗 = prog[8:3] 每帧 +2 行 ⇒ 每个条带只展开 8 档。
    //   肉眼看到的就是"一档一档地跳"，也就是用户说的不够丝滑。
    //   ⇒ 三个模式**全部**改走"每像素系数 + 淡化乘法器"，即**软边**：
    //     · 划像：界线中心还是 prog*4 px，但改成一个 **64 px 宽的渐变带**；
    //     · 百叶窗：每条带子的前沿也做成 **8 行宽的渐变带**；
    //     · 交叉淡化本来就是软的，系数直接就是 prog。
    //   ★ 一点面积都不加：`mix565` 那 3 个乘法器**本来就在**（交叉淡化用），
    //     这里只是把喂给它的系数从"常数 prog"换成"逐像素系数"。
    //   ★ 两头仍然**精确**：prog=0 ⇒ 系数 0 ⇒ 输出逐位等于 A 端；
    //     prog=256 ⇒ 系数 256 ⇒ 输出逐位等于 B 端
    //     （mix565 的除法带四舍五入，两头误差为 0 —— 这正是本文件"9 位 prog"的理由）。
    // ============================================================
    //  划像（软边 128 px ⇒ 屏幕宽度的 16%）：中心 = prog*4，系数 = clamp(中心 − x, 0, 128) × 2
    wire [11:0] wipe_pos = {2'b00, prog} * 12'd4;                 // 0..1024
    wire [11:0] wipe_dx  = (wipe_pos > {1'b0, pix_x}) ? (wipe_pos - {2'b00, pix_x})
                                                     : 12'd0;
    wire [8:0]  k_wipe   = (wipe_dx >= 12'd128) ? 9'd256
                                               : {2'b00, wipe_dx[6:0], 1'b0};     // ×2 ⇒ ≤254

    //  百叶窗（软边 8 行）：展开到第 pos 行，系数 = clamp(pos − y[4:0], 0, 8) × 32
    //   ★ pos = prog[8:3] + prog[8:5]（= 原值 ×1.25，0..40，不是 0..32）：仿真抓到过——
    //     pos 最大只有 32 时，最下面那条带子（y[4:0]=31）要 pos ≥ 39 才能到 100%，
    //     于是 prog=256 时还有一批点没变成新图，swap 那一拍就会"跳一下"。
    //     （★ 除法别写错：prog[8:3]/4 = prog[8:5]，不是 prog[7:5] —— 第一版写错，仿真又抓了一次。）
    wire [5:0]  blind_pos = {1'b0, prog[8:3]} + {2'b00, prog[8:5]};   // 0..40
    wire [5:0]  blind_y   = {1'b0, pix_y[4:0]};                   // 0..31
    wire [5:0]  blind_d   = (blind_pos > blind_y) ? (blind_pos - blind_y) : 6'd0;
    wire [8:0]  k_blind   = (blind_d >= 6'd8) ? 9'd256
                                              : {1'b0, blind_d[2:0], 5'b00000};   // ×32 ⇒ ≤224

    //  逐像素系数：交叉淡化直接用 prog
    wire [8:0]  k_pix = (mode == M_WIPE)  ? k_wipe
                      : (mode == M_BLIND) ? k_blind
                      : prog;

    // ============================================================
    //  ③ 淡化：R/G/B 三个通道各一次"差值 × 系数"
    //      out = a + ((b − a) · prog + 128) >> 8      （prog = 0..256）
    //      · 加 128 是四舍五入，避免整体偏暗半格；
    //      · >> 8 是**算术**右移（负数向下取整），所以 32 位有符号再移。
    //      · prog=0 精确等于 a、prog=256 精确等于 b（tb 里两头都逐位核对）。
    // ============================================================
    function [15:0] mix565;
        input [15:0] a;
        input [15:0] b;
        input [8:0]  k;
        reg signed [15:0] dr, dg, db;
        reg signed [15:0] ks;
        reg signed [31:0] pr, pg, pb;
        reg signed [15:0] er, eg, eb;
        reg [15:0] ar, ag, ab;
        begin
            ks = $signed({7'd0, k});                       // 0..256
            dr = $signed({11'd0, b[15:11]}) - $signed({11'd0, a[15:11]});
            dg = $signed({10'd0, b[10:5]})  - $signed({10'd0, a[10:5]});
            db = $signed({11'd0, b[4:0]})   - $signed({11'd0, a[4:0]});
            pr = dr * ks;
            pg = dg * ks;
            pb = db * ks;
            er = (pr + 32'sd128) >>> 8;
            eg = (pg + 32'sd128) >>> 8;
            eb = (pb + 32'sd128) >>> 8;
            ar = a[15:11] + er;                            // 数学上一定落在 [0,31]
            ag = a[10:5]  + eg;                            //                [0,63]
            ab = a[4:0]   + eb;                            //                [0,31]
            mix565 = {ar[4:0], ag[5:0], ab[4:0]};
        end
    endfunction

    // ★ 2026-10-17：系数改成逐像素（软边）。PASS 仍直通 A 端（一个乘法器都不走）。
    // 2026-10-31 timing: register the mixer inputs (65 MHz pixel domain).
    // One extra pixel of latency only shifts the wipe edge by 1 px (invisible).
    reg [15:0] mf_r, mt_r;
    reg [8:0]  k_r;
    reg        de_r, vs_r;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            mf_r <= 16'd0; mt_r <= 16'd0; k_r <= 9'd0;
            de_r <= 1'b0;  vs_r <= 1'b0;
        end else begin
            mf_r <= mix_from; mt_r <= mix_to; k_r <= k_pix;
            de_r <= de_in;    vs_r <= vs_in;
        end
    end

    wire [15:0] fade_out = mix565(mf_r, mt_r, k_r);

    // ============================================================
    //  ④ 选一个 + 寄存一拍
    // ============================================================
    wire [15:0] mix = (mode == M_PASS) ? mf_r : fade_out;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            rgb565 <= 16'd0;
            de_out <= 1'b0;
            vs_out <= 1'b0;
        end
        else begin
            rgb565 <= mix;
            de_out <= de_r;
            vs_out <= vs_r;
        end
    end

endmodule
