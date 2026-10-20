// ============================================================
//  模块名 : menu_ovl —— 【参数菜单面板 + 文字】（像素流水第 ④' 级）
//  层次   : `subtitle_ovl` 之后、RGB565→RGB888 之前（disp_top 里压在最上面那一层）
//  时钟域 : 单域 —— clk_pix（40 MHz），和 subtitle_ovl 的像素侧**同一个域**
//  依据   : 用户 2026-10-15 定稿的「参数菜单·第 1 步」（骨架）+「第 2 步」（加字模/文字）
// ------------------------------------------------------------
//  ★★★ 2026-10-15【参数菜单·第2步】本步加了什么（一句话）：
//      在第 1 步那个**纯色面板**上，给 4 行各画一行"**名字 + 数值**"，再给选中行左侧画
//      一个 `>` 光标；字形来自本文件底部例化的 `font_rom`（5×7 点阵、写在 RTL 里的
//      常数 case ⇒ **不落 BRAM**，见 font_rom.v 文件头）。
//
//  ★★★ 2026-10-15【参数菜单·第1步】原有行为（一个字都没变）：
//      `menu_on`=1 时画面板（外框 + 面板底 + 3 条等高行分隔线 + 选中行高亮条）；
//      `menu_on`=0 时**一个像素都不改**（逐位透传）。
//
//  ★ 硬约束（本步仍然最重要的一条）：**面板外一个像素都不许改**
//      · 所有画的动作（含本步新加的文字/光标）都先与 `in_panel` 相与，`in_panel` 又含
//        `de_in`（消隐期恒 0）⇒ 面板矩形以外（含消隐区）输出**就是输入本身**，逐位相同。
//      · `menu_on=0` 时 `draw_*` 全 0 ⇒ `px_out <= px_in`；而且 `menu_on` 是**慢变电平**，
//        综合时能被常数传播 ⇒ 菜单这一级退化成一串纯寄存器 ⇒ 对既有画面零影响。
//
//  ★ 两张表（文字内容 / 数值显示，**都在这一个文件里，改内容不用碰别的文件**）：
//      行 0 `ZOOM`   + `zoom_lv`（0..5，**实时**跟着 KEY2 的档位变）
//      行 1 `AUDIO`  + `sel_aud+1`（1..4，**实时**跟着 SW3 切的那条音频变）
//      行 2 `VOLUME` + `vol_lv`（0..15，**两位十进制**；★★★ 2026-10-17 起是真音量档，
//                     由"菜单开 + 光标在 VOLUME 行 + KEY2 进调节态 + KEY3 步进"改）
//      行 3 `BRIGHT` + `bri_lv`（0..15，**两位十进制**；★★★ 2026-10-17 起是真亮度档，
//                     手势和 VOLUME 完全一样；原来的占位行 `EXIT` 已被它顶替 ——
//                     退菜单本来就是 SW2 拨一下，不需要 `EXIT` 这一行）
//      ★★★ 2026-10-20【D1 · A2】：行 4 `VISUAL` 已删除 ⇒ 面板回到 4 行
//                     （ZOOM / AUDIO / VOLUME / BRIGHT），ROW_H = 200/4 = 50。
//      ⇒ 名字是"按 (行, 列) 查字符码"的**纯组合常量表**（`ch_code`），数值是
//        "0..9 直接 + '0'"（两位以内 ⇒ 不需要除法器/BCD，省面积）。
//      ⇒ ★ 本模块仍然是**只读显示**：所有活值进来只用于查字，**绝不写回**
//        （音量/亮度/可视化开关的寄存器在 `rtl\top_m2.v` 里，改它们的只有 KEY3 那一步进逻辑）。
//
//  ★★ 文字的位置/尺寸全部是**文件头 localparam 常量**（用户要求"位置做成常量好调"）：
//      `TXT_W/TXT_H/TXT_SP`（字形尺寸与字间距）、`TXT_LM`（名字左缩进）、
//      `TXT_VM`（数值左缩进）、`TXT_CUR`（光标左缩进）、`TXT_TOP`（行内垂直居中偏移）。
//      改位置只动这几个数，下面的画字逻辑一行都不用碰。
//
//  ★★ 坐标对齐（这一条最容易错，写下来免得后人再猜）：
//      `subtitle_ovl` 的输出比它的输入**晚两拍**（`px_1`/`de_1` + 输出寄存，见其文件说明）。
//      本模块也照同样的规矩：输入侧 `de_s/px_s` 进来 → 打一拍成 `de_p/px_p/x_p/y_p`
//      → 再寄存一拍出 `px_out`。因此：
//        · 送进来的 `x_in/y_in` 必须**和数据是同一个像素**；
//        · 本模块内部自己把坐标跟着数据一起打两拍，**不向外要延迟过的坐标**。
//      顶层（`disp_top`）为此专门准备了 `mx1/mx2`、`my1/my2` 两组延迟坐标
//      （= `o_dbg_x/o_dbg_y` 再打两拍），绝对不要图省事直接接 `o_dbg_x/o_dbg_y`。
//
//  ★★★ 2026-10-16【菜单字模·修正】上板反馈"字模没做好，可以看到背景"的**根因**与修法：
//   ① 根因（**不透明性**）：上一版把"字符格里没点灯的像素"判成了"面板底以外的像素"——
//      `draw_base` 里带了 `&& !text_hit` ⇒ 凡是落在字符格矩形内的像素**一律不铺面板底色**，
//      字形缝隙/字符四周就**原样透出照片**（面板不透明这一条被破坏）。
//      ⇒ 现在改成**先铺不透明底色**，文字只在 `font_px=1` 的像素上覆盖颜色：
//         `draw_base = 面板内 && !外框 && !分隔线`  ← **不再看 text_hit**。
//   ② 本步同时按用户要求给字号加**点阵放大倍数** `TXT_SCALE`（默认 2 ⇒ 10×14）。
//   ③ 字形极性（A）**本来就是对的**，下面把约定**写死**防再犯：
//      · `font_rom.v`：`px = 1` 表示**点灯**（墨色 `CLR_INK`），`px = 0` 表示**该点保持已有颜色**
//        （即已经铺好的面板底/高亮条，**绝不透出照片**）。
//      · `menu_ovl.v`：**只在 `font_px == 1` 时**把该像素改成 `CLR_INK`；`font_px == 0` 时
//        **什么都不做**（由下面的 `draw_*` 链决定，落到 `draw_base`/`draw_sel`）。
//      · ⇒ 两边约定一致：**1 = 墨、0 = 保留底色**；**任何一边都不要取反**。
//
//  ★ 画面元素与优先级（**高者覆盖低者**，同一像素只会命中一个）：
//    修正后是 6 层（底色被提到最底层、且**不透明**）：
//        ① 文字（`CLR_INK`，含 `>` 光标）       ← 最高：只在字形点灯处覆盖
//        ② 行分隔线     画 `CLR_SEP`
//        ③ 面板外框     画 `CLR_FRAME`
//        ④ 选中行高亮条 画 `CLR_SEL`
//        ⑤ 面板底       画 `CLR_PANEL`          ← **铺满整个面板内侧**（不透明，挡住照片）
//      ⇒ 从内到外逐层盖：底色 → 高亮条 → 外框 → 分隔线 → 文字。
//        ★ 文字必须排在最上面：否则选中行的高亮条会把字盖住，
//          看起来就是"选中那一行字消失了"。
//        ★ 底色必须**先铺满**（不再因为"这里将来要画字"而留空）：这是本次上板
//          "能看到背景"的直接原因。
//
//  ★ 尺寸/坐标全部是**文件头 localparam 常量**（用户要求"坐标做成文件头常量"）：
//      改面板大小/位置只动这几个数，RTL 一行不用碰。
// ============================================================
`timescale 1ns / 1ps

module menu_ovl #(
    // ---- 屏幕（和 disp_top 的 pic_wide/pic_high 一致：800×600）----
    parameter integer SCR_W = 800,
    parameter integer SCR_H = 600,
    // ---- 面板：居中矩形，320 × 200 ----
    parameter integer PANEL_W = 320,
    parameter integer PANEL_H = 200,
    // ---- 面板内部：5 条等高行（和顶层 MENU_N=5 一致；改这里也要改顶层那个）----
    //   ★ 2026-10-18：第 5 行 = `VISUAL` 可视化总开关（ON/OFF）
    //      ⇒ ROW_N 4→5、ROW_H = 200/5 = 40，字形仍 14 高（上下各留 13），装得下。
    //   ★★★ 2026-10-20【D1 · A2 删 VISUAL 行】：ROW_N 5→4，ROW_H 回到 200/4 = 50，
    //     字形仍 14 高（上下各留 18）—— 行距比 5 行那版更松，和 10-17 的版面一致。
    parameter integer ROW_N = 4,
    // ---- 外框线宽（像素）；分隔线宽同样用它 ----
    parameter integer FRAME_T = 2,
    // ============================================================
    //  ★★★ 2026-10-16【菜单字模·修正】文字排版常量（**调位置/字号只改这里**）
    // ------------------------------------------------------------
    //  坐标系：所有偏移都是"**相对面板左上角**（PANEL_X0 / PANEL_Y0）"的像素数，
    //          除 TXT_W/TXT_H/TXT_SP/TXT_LM/TXT_VM/TXT_CUR 是**点阵单位**（会被 TXT_SCALE 放大）。
    //  · TXT_SCALE     ：★ **点阵放大倍数**（本步新增）。1 个点阵像素 = TXT_SCALE×TXT_SCALE
    //                    个屏幕像素 ⇒ 默认 2 时，5×7 字形在屏上是 **10×14**，在 320×200
    //                    面板 / 电视上才看得清（原来 5×7 太小 —— 上板反馈的 (D) 项）。
    //                    ★ 行高/行间距/左边距/数值列/高亮条高度/光标位置**全部由它推导**，
    //                      下面没有任何"写死"的排版像素常量（改这一个数，整套排版跟着走，
    //                      见下面几何段的 `localparam` 推导）。
    //                    ★ 取值 1/2/4 时除法是移位，最省；3 也能跑（除法器），但 HILITE_H
    //                      要跟着调（下面有约束检查）。默认 2。
    //  · TXT_W / TXT_H ：一个字形**点阵**的宽/高（和 font_rom.v 的 5×7 一致，不含放大）
    //  · TXT_SP        ：字与字之间的间隔**点阵列数**（⇒ 步进 = (TXT_W+TXT_SP)*TXT_SCALE）
    //  · TXT_LM        ：**名字**（ZOOM/AUDIO/...）离面板左边的距离（点阵单位）
    //  · TXT_VM        ：**数值**离面板左边的距离（点阵单位）；> TXT_LM 才不会被名字压住
    //  · TXT_CUR       ：`>` 光标离面板左边的距离（点阵单位，比 TXT_LM 再往左）
    // ============================================================
    parameter integer TXT_SCALE = 2,
    parameter integer TXT_W   = 5,
    parameter integer TXT_H   = 7,
    parameter integer TXT_SP  = 2,
    parameter integer TXT_LM  = 12,
    parameter integer TXT_VM  = 96,
    parameter integer TXT_CUR = 2,
    // ---- 高亮条高度：基高 16 点阵行 × TXT_SCALE ⇒ 默认 32 屏幕像素 ----
    //   ★ 必须 ≥ 放大后的字高 (TXT_H*TXT_SCALE=14) + 2，否则字会露出高亮条外；
    //     同时必须 < 行高 ROW_H(=38) —— 面板只有 200 高，这两条是硬边界。
    parameter integer HILITE_H = 16 * TXT_SCALE,
    // ---- 颜色（RGB565）----
    //    面板底 : 深灰   R=8  G=16 B=8   → 16'h4104
    //    外框   : 近白   R=31 G=63 B=31  → 16'hFFFF
    //    分隔线 : 中灰   R=16 G=32 B=16  → 16'h8410
    //    高亮条 : 亮蓝   R=4  G=32 B=31  → 16'h20FF（对深灰底反差极大）
    //    ★ 文字 : 亮黄白 R=31 G=63 B=8   → 16'hFFC2（高亮条是亮蓝 ⇒ 字在上面也清楚）
    parameter [15:0] CLR_PANEL = 16'h4104,
    parameter [15:0] CLR_FRAME = 16'hFFFF,
    parameter [15:0] CLR_SEP   = 16'h8410,
    parameter [15:0] CLR_SEL   = 16'h20FF,
    parameter [15:0] CLR_INK   = 16'hFFC2
)(
    // ---------------- 像素域 40 MHz ----------------
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        de_in,        // 和 px_in 同一像素
    input  wire        vs_in,        // 跟着一起打拍（本步没用到，留接口给第 2 步）
    input  wire [11:0] x_in,         // 屏幕坐标（必须和 px_in 同一像素，见文件头 ★★）
    input  wire [11:0] y_in,
    input  wire [15:0] px_in,        // RGB565（subtitle_ovl 之后）
    output reg  [15:0] px_out,       // ★ 比输入晚【两拍】（和 subtitle_ovl 同一口径）
    output reg         de_out,
    output reg         vs_out,

    // ---------------- 菜单状态（慢变电平，顶层已同步到 clk_pix）----------------
    input  wire        menu_on,      // 1 = 画菜单；0 = 逐位透传（一个门都不画）
    input  wire [2:0]  menu_sel,     // 选中行 0..4（★ 2026-10-18：5 行 ⇒ 3 位）
    // ---------------- ★★★ 2026-10-15【参数菜单·第2步】要显示的"活值" ----------------
    //   ★ 两根都是**只读**：本模块只拿它们去查字模（`zoom_lv`→'0'..'5'、
    //     `sel_aud`→'1'..'4'），**绝不写回、不产生任何握手** ⇒ 不改变任何既有语义。
    //   ★ 域：和 menu_on/menu_sel 一样，是**顶层在 clk_pix 域同步好的慢变电平**
    //     （top_m2 里 zoom_lv / sel_aud 各打了两级），这里不再打拍。
    input  wire [2:0]  zoom_lv,      // 缩放档 0..5（KEY1/KEY2 循环）
    input  wire [1:0]  sel_aud,      // 音频条号 0..3（SW3 切）；要显示的是 **sel_aud + 1** = 1..4
    // ★★★ 2026-10-17【音量进菜单】行 2 `VOLUME` 的活值：0..15，用**两格**显示十进制。
    //   只读（本模块仍然不写回任何东西）；像素域慢变电平，top_m2 里已打两级同步。
    input  wire [3:0]  vol_lv,       // 音量档 0..15（15 = 满，0 = 静音）
    // ★★★ 2026-10-17【亮度进菜单】行 3 `BRIGHT` 的活值：0..15（15 = 原样），
    //   同样**两格**十进制、同样只读、同样像素域慢变电平（top_m2 打两级）。
    //   ★ 行 3 原来是占位用的 `EXIT`（按 KEY2 什么也不做）⇒ 现在改成真功能。
    //   ★ 2026-10-20【D1 · A2】：原 `viz_on` 端口已删（行 4 VISUAL 删除，可视化常开）
    input  wire [3:0]  bri_lv        // 亮度档 0..15（15 = 原样，0 = 最暗）
);

    // ============================================================
    //  面板几何（全部由上面的参数算出，不写死坐标）
    //  ★★★ 2026-10-16【菜单字模·修正】：下面这一段是本步的核心 ——
    //     **行高 / 行间距 / 左边距 / 数值列 / 高亮条 / 光标位置全部由 TXT_SCALE 推导**，
    //     改 TXT_SCALE 一个数，整套排版跟着走（不再有写死的像素常量）。
    // ============================================================
    localparam integer PANEL_X0 = (SCR_W - PANEL_W) / 2;      // 800/320 ⇒ 240
    localparam integer PANEL_Y0 = (SCR_H - PANEL_H) / 2;      // 600/200 ⇒ 200
    localparam integer PANEL_X1 = PANEL_X0 + PANEL_W;         // 560（右开区间）
    localparam integer PANEL_Y1 = PANEL_Y0 + PANEL_H;         // 400（右开区间）
    // ---- 行高：4 行等分面板（200/4 ⇒ 50）----
    //      ★ 这个数只跟 PANEL_H / ROW_N 走，**与 TXT_SCALE 无关**（面板高度是硬的）；
    //        但"行内"的每一个偏移（字形顶端、高亮条上下沿）都由 TXT_SCALE 推出来。
    //      ★ 装得下 4 行的校验（TXT_SCALE=2）：字高 14 + 上下各留 18 = 50 正好一行；
    //        4 行 × 50 = 200 = PANEL_H ⇒ **刚好装满，不溢出**（数值见交付报告）。
    localparam integer ROW_H    = PANEL_H / ROW_N;            // 200/4 ⇒ 50
    // ---- 放大后的字形在屏幕上的尺寸：5×7 × 2 ⇒ **10×14** ----
    localparam integer TXT_GW   = TXT_W * TXT_SCALE;          // 字形宽（屏幕像素）⇒ 10
    localparam integer TXT_GH   = TXT_H * TXT_SCALE;          // 字身高（屏幕像素）⇒ 14
    // ---- 字距步进（(字形宽 + 字间距) × 放大倍数）：(5+2)*2 ⇒ 14 ----
    localparam integer TXT_STEP = (TXT_W + TXT_SP) * TXT_SCALE;
    // ---- 高亮条的上下沿（按行居中；和字高无关，只由 HILITE_H 决定）----
    localparam integer HIL_TOP  = (ROW_H - HILITE_H) / 2;     // (50-32)/2 ⇒ 9
    localparam integer HIL_BOT  = HIL_TOP + HILITE_H;         // 41
    // ---- 字形顶端在**行内**的偏移（屏幕像素）：行内垂直居中 ⇒ (50-14)/2 ⇒ 18 ----
    //      ★ 这一条原来是写死的 21；现在由 ROW_H 与放大后的字高算出 ⇒ 改 TXT_SCALE
    //        字自动重新居中。放大后的字必须**完整落在高亮条里**：
    //        TXT_TOP(=18) ≥ HIL_TOP(=9) 且 TXT_TOP+TXT_GH(=32) ≤ HIL_BOT(=41)  ✔
    localparam integer TXT_TOP  = (ROW_H - TXT_GH) / 2;
    localparam [11:0] TXT_GY1   = TXT_TOP + TXT_GH;           // 字形区间下界（右开）⇒ 32
    // ---- 左边距 / 数值列 / 光标列（点阵单位 ⇒ 乘放大倍数；都相对面板左上角）----
    localparam integer TXT_LM_P = TXT_LM  * TXT_SCALE;        // 名字左缩进 ⇒ 24
    localparam integer TXT_VM_P = TXT_VM  * TXT_SCALE;        // 数值左缩进 ⇒ 192
    localparam integer TXT_CU_P = TXT_CUR * TXT_SCALE;        // 光标左缩进 ⇒ 4
    // ---- 名字段总宽（6 格，够 'VOLUME' 用）⇒ 6*14 = 84 ----
    localparam integer LAB_ZONE = 6 * TXT_STEP;

    // ============================================================
    //  第一拍：把像素 + 坐标 + de/vs 一起打一拍（和 subtitle_ovl 的 `_1` 级同拍）
    //    ★ 坐标**必须**跟着打，否则画的矩形会整体偏左上
    // ============================================================
    reg        de_p, vs_p;
    reg [11:0] x_p, y_p;
    reg [15:0] px_p;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            de_p <= 1'b0;  vs_p <= 1'b0;
            x_p  <= 12'd0; y_p  <= 12'd0;
            px_p <= 16'd0;
        end
        else begin
            de_p <= de_in;  vs_p <= vs_in;
            x_p  <= x_in;   y_p  <= y_in;
            px_p <= px_in;
        end
    end

    // ============================================================
    //  第二拍：算"这一拍是不是在面板里 / 在哪一行"，然后**寄存输出**
    // ============================================================
    // ---- 行号：用比较链而不是除法（4 行 ⇒ 3 个常数比较器，比 ^/ 便宜得多）----
    //   ★ 2026-10-20【D1 · A2】：`ROW_H*4` 那一支（行 4 VISUAL）已删。
    wire [2:0] row_now = (y_p >= (PANEL_Y0 + ROW_H * 3)) ? 3'd3 :
                         (y_p >= (PANEL_Y0 + ROW_H * 2)) ? 3'd2 :
                         (y_p >= (PANEL_Y0 + ROW_H * 1)) ? 3'd1 : 3'd0;

    // ---- 面板内 / 外框 / 分隔线 / 高亮条 ----
    //   ★ 省门的写法（每一条都写在注释里，"为什么这样等价"一目了然）：
    //     · `in_sep` 故意**只判 y、不判 x** —— 分隔线横跨整条面板；左右两端那
    //       FRAME_T 列会被优先级更高的 `draw_frame` 盖掉 ⇒ 与"只画在框内侧"等价，
    //       省掉 2 个 12 位比较器。
    //     · `in_hilite` 用两个单减法 —— `y_p - PANEL_Y0 - ROW_H*row_now` 两次都是
    //       减常量，综合成"减 ROW_H 的倍数"一个减法器复用；再和两个常量比。
    //     · `row_now` 用比较链（常数比较器）而不是除法。
    wire in_x       = (x_p >= PANEL_X0) && (x_p < PANEL_X1);
    wire in_y       = (y_p >= PANEL_Y0) && (y_p < PANEL_Y1);
    wire in_panel   = de_p && in_x && in_y;              // ★ 含 de：消隐期一个像素都不碰
    wire in_frame   = (x_p < (PANEL_X0 + FRAME_T)) || (x_p >= (PANEL_X1 - FRAME_T)) ||
                      (y_p < (PANEL_Y0 + FRAME_T)) || (y_p >= (PANEL_Y1 - FRAME_T));
    //   分隔线：每一条行尾线的**最上面那一行**（1 像素宽），横跨整条面板
    //   ★ 行尾线 y = PANEL_Y0 + ROW_H*k + (ROW_H-1)，和列无关 ⇒ 只和 y_p 比
    wire in_sep     = (y_p == (PANEL_Y0 + ROW_H * 1 - 1)) ||
                      (y_p == (PANEL_Y0 + ROW_H * 2 - 1)) ||
                      (y_p == (PANEL_Y0 + ROW_H * 3 - 1));  // ★ 4 行 ⇒ 3 条内部线（A2 删第 4 条）
    //   高亮条：在选中行里，相对该行顶的偏移落在 [HIL_TOP, HIL_BOT)；
    //   横向从框内侧起，左右各留 `HIL_MARGIN` 的缝。
    //   ★★★ 2026-10-16【菜单字模·修正】：这个缝原来是写死的 4，现在跟着放大倍数走
    //      （`HIL_MARGIN = FRAME_T + TXT_SCALE*2`）⇒ 字号变大时留白一起变，不会显得挤。
    //   ★ `hy` 这个减法一次就够：两次减的都是常量 ⇒ 综合成一个减法器复用。
    localparam integer HIL_MARGIN = FRAME_T + TXT_SCALE * 2;   // 2 + 4 ⇒ 6
    wire [11:0] hy = y_p - (PANEL_Y0 + ROW_H * row_now);
    // ★★★ 2026-10-17【用户要求：**去掉高亮条**】
    //   选中行不再铺高亮底色，选中状态只看行首那个 `>` 光标（`cur_hit`，跟着 `menu_sel` 走）。
    //   ⇒ `in_hilite` / `draw_sel` 一并删掉（不留死逻辑，否则 TD 会留一堆比较器）。
    //   ★ 原来这两段是：
    //       wire in_hilite = (row_now == menu_sel) && (hy >= HIL_TOP) && (hy < HIL_BOT) &&
    //                        (x_p >= (PANEL_X0 + HIL_MARGIN)) && (x_p < (PANEL_X1 - HIL_MARGIN));
    //       wire draw_sel  = menu_on && in_panel && in_hilite;
    //       ... else if (draw_sel) px_out <= CLR_SEL;

    // ============================================================
    //  ★★★ 2026-10-16【菜单字模·修正】文字层（字形取自 font_rom，5×7 点阵 × TXT_SCALE 放大）
    // ------------------------------------------------------------
    //  ① 把屏幕坐标换成"**面板内局部坐标**"（都减同一个常数 PANEL_X0/PANEL_Y0 ⇒
    //     综合成一个减法器就够；纵向再用行号的倍数把 y 折到"行内偏移"）。
    //     ★ 因为整段都先与 `in_panel` 相与，所以这些减法在面板外算出来的"垃圾值"
    //       不会影响任何像素（面板外照旧逐位透传）。
    //  ② 判断"这一拍在不在**某个字符格里**"：
    //       lx - TXT_LM_P - k*TXT_STEP ∈ [0, TXT_W*TXT_SCALE)  ⇒ 第 k 个名字字符
    //       lx - TXT_VM_P ∈ [0, TXT_W*TXT_SCALE)               ⇒ 数值字符（每行最多 1 个数字）
    //     ★ `lx` 是 12 位、减的是常量：这里用 `-` 而不是先算"第几个字符"再乘 ⇒
    //       综合成 6 个常数比较器（k 只有 0..5），不生成乘法器。
    //  ②' ★★ 放大（TXT_SCALE）怎么做的（**这就是 (B)/(D) 两问的答案**）：
    //       先判"在**放大后**的字符格里"（格宽 = TXT_GW = TXT_W*TXT_SCALE），
    //       再把格内偏移**整除 TXT_SCALE** 折回点阵列/行：
    //         gy_scaled = (ly - TXT_TOP) / TXT_SCALE   ⇒ 0..TXT_H-1（点阵行）
    //         glx       = (lx - TXT_LM_P - k*TXT_STEP) / TXT_SCALE ⇒ 0..TXT_W-1
    //       ★ 整数除法在 TXT_SCALE=1/2/4 时就是**右移**（`/2` ⇒ 丢最低位），综合器
    //         直接出移位、不出除法器；TXT_SCALE=3 才要真除法器（能用但更贵）。
    //       ★ 顺序很关键：**先减常数、后除**。反过来（先除后减）会让每个点阵像素的
    //         边界对不齐（TXT_STEP 除不尽就会串列 ⇒ 字粘连），就是上一版最容易踩的坑。
    //  ③ 字符码表 `ch_code`：**纯组合常量**，一个 LUT 就是一张小表。
    //  ④ `font_rom` 只做"行 + 列 + 字符码 → 这一位亮不亮"，**组合输出、不打拍**
    //     ⇒ 和面板几何、高亮条**天然同拍**，坐标链一拍都不用动（这是本步的关键：
    //       如果给字模打了拍，就必须再给坐标补一拍，很容易画歪一个像素）。
    //  ⑤ ★★★ 极性约定（(A) 问的答案，**写死在这里防再犯**）：
    //       `font_px = 1` ⇒ 这一位是**墨**，本模块把它改成 `CLR_INK`；
    //       `font_px = 0` ⇒ **什么都不做**，保持该点**已经有**的颜色
    //                        （面板底 / 高亮条）——**绝不透出照片**。
    //     ⇒ font_rom.v 的注释也写着"bit = 1 表示前景，不要取反"，两边口径一致。
    //     ★ 面积/时序：这条链是 "12 位减法 → 6 个比较器 → 右移 → case → 5:1 mux → 输出寄存"，
    //       比旁边的缩放/插值链短得多，不会成为关键路径。
    // ============================================================
    wire [11:0] lx = x_p - PANEL_X0;                       // 面板内横向坐标（0..319）
    //   行内纵向偏移 `ly`：0..(ROW_H-1)，即"字形顶端"相对**行顶**的位置。
    //   ★★ 这里**绝不能**写 `gy = ly - TXT_TOP` 再去判 `gy < TXT_H`：
    //      `ly` 是无符号 12 位 ⇒ ly < 18 时 `ly-18` 会**回绕成 4078 这类大数**，
    //      `gy_ok` 恒假 ⇒ **一个字都画不出来**（本步早期在 ModelSim 里就是这么被抓住的，
    //      上板后的现象是"面板里空空如也、只有高亮条"）。
    //      ⇒ 改成"**区间比较**"：`TXT_TOP <= ly < TXT_TOP + TXT_GH`，两个比较器，
    //        既不会回绕，面积也更小。
    //   ★★ 另外：这里**一律不用 SystemVerilog 的 `N'(expr)` 尺寸转换语法**！
    //      ModelSim 认，但 **TD 的综合前端不认**（报 HDL-8007 syntax error near "'"，
    //      整个文件一个模块都进不去）。要用常量就写成上面那些 `localparam`，
    //      比较的位宽让 Verilog 自己按"操作数最大位宽"对齐 —— 两种工具都认。
    wire [11:0] ly = (y_p - PANEL_Y0) - ROW_H * row_now;
    //   ① 纵向：先在**屏幕像素**域判"在不在放大后的字形带里"，再折回点阵行
    wire        gy_ok     = (ly >= TXT_TOP) && (ly < TXT_GY1);
    wire [11:0] gy_scaled = (ly - TXT_TOP) / TXT_SCALE;    // ★ 先减后除 ⇒ 0..TXT_H-1
    //   ② 横向：名字段总宽 = 6 格（够 'VOLUME' 用）⇒ 6 * TXT_STEP
    //      ★ 先判"在不在名字那一段里"（**常数区间**比较，就 2 个比较器），再在段内比对；
    //        否则左边界（lx < TXT_LM_P ⇒ 减出来是大数 4090+）会绕回来报"命中最后一格"。
    wire [11:0] gx_lab = lx - TXT_LM_P;
    wire        in_lab_zone = (gx_lab < LAB_ZONE);
    wire        l0 = in_lab_zone && (gx_lab <  TXT_STEP);
    wire        l1 = in_lab_zone && (gx_lab >= TXT_STEP)   && (gx_lab < 2 * TXT_STEP);
    wire        l2 = in_lab_zone && (gx_lab >= 2*TXT_STEP) && (gx_lab < 3 * TXT_STEP);
    wire        l3 = in_lab_zone && (gx_lab >= 3*TXT_STEP) && (gx_lab < 4 * TXT_STEP);
    wire        l4 = in_lab_zone && (gx_lab >= 4*TXT_STEP) && (gx_lab < 5 * TXT_STEP);
    wire        l5 = in_lab_zone && (gx_lab >= 5*TXT_STEP) && (gx_lab < 6 * TXT_STEP);
    wire        in_lab = l0 || l1 || l2 || l3 || l4 || l5;
    //   字形内点阵列号：格内偏移 / TXT_SCALE ⇒ 0..TXT_W-1（TXT_W..TXT_STEP-1 = 字间距，
    //   落在字形外 ⇒ 查出来是全 0，不会点亮）
    //
    //   ★★★ 2026-10-17【菜单字距修正 · 既有 bug】原来是 `glx = gx_lab / TXT_SCALE`
    //     再取 `glx[2:0]` 当列号 —— 那是**模 8**，而一格只有 TXT_STEP(=14 px = **7 点**) 宽
    //     ⇒ 每个字母都往右多走 1 点（实测 6 个字母的起点 = 12/20/28/36/44/52，
    //     正确应为 12/19/26/33/40/47），到第 6 个字母就撞上 `LAB_ZONE`(42 点) 的右边界，
    //     **被截掉大半**（'VOLUME' 的 'E' 只剩 2 列）—— 这就是交接文档里
    //     "恢复版渲染与 10-17 参考差 448 行 / 字形格步进不同" 的真正原因。
    //   ⇒ 先按 l0..l5 减掉**本格起点**（常数减法 mux，一个小 mux，不做除法器），
    //     再除放大倍数 ⇒ 真正的格内点列 0..6（5、6 是字间距 ⇒ 查出来全 0）。
    wire [11:0] gx_cell = l0 ? gx_lab :
                          l1 ? (gx_lab - TXT_STEP) :
                          l2 ? (gx_lab - 2 * TXT_STEP) :
                          l3 ? (gx_lab - 3 * TXT_STEP) :
                          l4 ? (gx_lab - 4 * TXT_STEP) :
                               (gx_lab - 5 * TXT_STEP);
    wire [11:0] glx   = gx_cell / TXT_SCALE;

    // ---- 数值层：每行最右一个数字（0..5 / 1..4 / 占位 '-'）----
    //   ★ 格宽 = TXT_GW（放大后的字形宽），不是 TXT_W —— 这是 (D) 放大之后必须同改的一处。
    wire [11:0] gx_val = lx - TXT_VM_P;
    wire        in_val = (gx_val < TXT_GW);
    wire [11:0] gvx    = gx_val / TXT_SCALE;

    // ★★★ 2026-10-17【音量进菜单】数值列的**第二格**（紧挨在右边，步进 = TXT_STEP）
    //   为什么需要：VOLUME 是 0..15，要两位十进制；其它行（ZOOM/AUDIO）只用第一格。
    //   ★ 几何：TXT_VM_P(192) + TXT_STEP(14) = 206，再加 TXT_GW(14) = 220 < 318(内框)
    //     ⇒ 不会碰外框；也和 `>` 光标（TXT_CU_P=4）离得远，互不干扰。
    //   ★ 对 ZOOM/AUDIO 行完全无影响：那两行的 `ch_code` 在第二格里只会落到兜底 ' '（全 0 点阵）。
    wire [11:0] gx_val2 = lx - (TXT_VM_P + TXT_STEP);
    wire        in_val2 = (gx_val2 < TXT_GW);
    wire [11:0] gvx2    = gx_val2 / TXT_SCALE;
    // ★ 2026-10-20【D1 · A2 删 VISUAL 行】：数值列第三格（只为 `ON`/`OFF` 存在）一并删除。

    // ---- VOLUME 的两位十进制（0..15：十位只会是 0 或 1）----
    wire        vol_ge10 = (vol_lv >= 4'd10);
    wire [3:0]  vol_one  = vol_ge10 ? (vol_lv - 4'd10) : vol_lv;

    // ---- ★★★ 2026-10-17【亮度进菜单】BRIGHT 的两位十进制（0..15，同 VOLUME 口径）----
    wire        bri_ge10 = (bri_lv >= 4'd10);
    wire [3:0]  bri_one  = bri_ge10 ? (bri_lv - 4'd10) : bri_lv;

    // ---- `>` 光标层：只画在选中行 ----
    wire [11:0] gx_cur = lx - TXT_CU_P;
    wire        in_cur = (gx_cur < TXT_GW);
    wire [11:0] gcx    = gx_cur / TXT_SCALE;

    // ---- ★★★ 字符码表（内容全在这里；ASCII 码值直接当常量写，一眼对得上）----
    //   字母：'A'=6'd33 … 'Z'=6'd58（见 font_rom.v 码表）；'-'=6'd13；'>'=6'd29。
    //   ★ 本步**没有 'V' 开关**：'V' = 'A' + 21 ⇒ 6'd33 + 6'd21。
    //     写死成常量只是为了让这张表"一眼能读"；要改成 'V' 或别的字改这一行即可。
    reg [5:0] ch_code;
    always @(*) begin
        case (row_now)
            // 行 0：`ZOOM` —— Z='Z' O='O' O='O' M='M'；数值 = '0'..'5'
            3'd0:    ch_code = l0 ? 6'd58 : l1 ? 6'd47 : l2 ? 6'd47 : l3 ? 6'd45 :
                               in_val ? (6'd16 + {3'd0, zoom_lv}) : 6'd0;
            // 行 1：`AUDIO` —— A U D I O；数值 = '1'..'4' = '0' + (sel_aud + 1)
            3'd1:    ch_code = l0 ? 6'd33 : l1 ? 6'd53 : l2 ? 6'd36 : l3 ? 6'd41 : l4 ? 6'd47 :
                               in_val ? (6'd16 + {1'b0, sel_aud} + 6'd1) : 6'd0;
            // 行 2：`VOLUME` —— 第 2 个字是 'O'（不是 'V'）：V O L U M E
            //        ★★★ 2026-10-17【音量进菜单】：数值改成**两位十进制**（0..15）
            //        · 第一格 = 十位：≥10 画 '1'，否则画 ' '（留白，不画前导 0）；
            //        · 第二格 = 个位：'0' + vol_one。
            //        （原来这里是两个 '-' 占位，表示"这一项还没接"—— 现在真接上了。）
            3'd2:    ch_code = l0 ? 6'd54 : l1 ? 6'd47 : l2 ? 6'd44 : l3 ? 6'd53 : l4 ? 6'd45 : l5 ? 6'd37 :
                               in_val  ? (vol_ge10 ? (6'd16 + 6'd1) : 6'd0) :
                               in_val2 ? (6'd16 + {2'd0, vol_one})          : 6'd0;
            // 行 3：`BRIGHT` —— B R I G H T（6 字母，正好用满 6 格）
            //        ★★★ 2026-10-17【亮度进菜单】：这一行原来是占位 `EXIT`（按 KEY2 无动作），
            //        现在改成真功能，数值同样是**两位十进制**（0..15，15 = 原样）：
            //        · 第一格 = 十位：≥10 画 '1'，否则留白；
            //        · 第二格 = 个位：'0' + bri_one。
            //        码值：B=34 R=50 I=41 G=39 H=40 T=52（'A'=33 ⇒ 'B'=34 …）
            3'd3:    ch_code = l0 ? 6'd34 : l1 ? 6'd50 : l2 ? 6'd41 : l3 ? 6'd39 : l4 ? 6'd40 : l5 ? 6'd52 :
                               in_val  ? (bri_ge10 ? (6'd16 + 6'd1) : 6'd0) :
                               in_val2 ? (6'd16 + {2'd0, bri_one})          : 6'd0;
            // 行 4 `VISUAL` ★★★ 2026-10-20【D1 · A2 已删除】：菜单回到 4 行
            //   （ZOOM / AUDIO / VOLUME / BRIGHT）。理由：频域砍掉后可视化只剩时域 32 柱，
            //   属于常开效果，不再需要总开关（顺带省掉一行的比较器和第三格）。
            //   ROW_N=4 ⇒ row_now 只会是 0..3；留这一支只为不留锁存。
            default: ch_code = 6'd0;
        endcase
    end

    // ============================================================
    //  ★★★ 2026-10-16【菜单字模·修正】画字的最终判据（**本次上板问题的正主**）
    // ------------------------------------------------------------
    //  ① ★★★ 透明性修正：上一版 `draw_base` 里带了 `&& !text_hit` ⇒ **字符格矩形内**
    //     （哪怕字形那一位是 0）**一律不铺面板底色** ⇒ 字缝/字符四周**原样透出照片**，
    //     用户看到的就是"字模没做好、能看到背景"。现在：
    //        · `draw_base` **不再看 text_hit** ⇒ 面板内侧先被 `CLR_PANEL` 铺成**不透明**；
    //        · 文字**只在 `font_px = 1` 时**把该像素改成 `CLR_INK`；`font_px = 0` 时
    //          不产生任何"画"的动作 ⇒ 保持已铺好的底色/高亮条（(C) 项要求）。
    //  ② 分层不再靠"text_hit 排除"，而是靠**优先级 if 链**（高的在前）：
    //       文字 > 分隔线 > 外框 > 高亮条 > 面板底 。
    //     ★ 高亮条排在**底色之上、外框/分隔线之下**：选中行的条子不会把外框/行线吃掉；
    //     ★ 文字排**最上**：选中行的高亮条不会把字盖掉（否则"选中哪行哪行字没了"）。
    //  ③ 一个像素只会命中一层：`draw_text` 命中时 `draw_base` 的 `!in_frame && !in_sep`
    //     可能同时为真，但 if 链**先**取 draw_text ⇒ 行为唯一、与综合无关。
    // ============================================================
    //   ★ 三个"格子"各自的有效条件（**这就是"哪一行显示什么"的唯一一处判断**）：
    //       · 名字：5 行都有（行 0..4），名字本身存在 ⇒ 带字符码表兜底 ' '，不会画出乱码；
    //       · 数值：5 行都有（行 0..4）—— 行 3 = BRIGHT 两位十进制、行 4 = VISUAL 的 ON/OFF；
    //       · 光标：只有**选中行**才有（跟着 `menu_sel` 走 —— 验收第 ③ 条）。
    wire        lab_hit   = in_lab;
    // ★ 2026-10-18：数值格是**三格**（192 / 206 / 220 起，各 14px 宽）。
    //   行 0/1 只用第一格，行 2/3 用两格十进制，行 4 用三格画 `ON` / `OFF`。
    //   ★ 行 3 原来是占位 `EXIT`（没有数值），那句 `&& (row_now != 3)` 必须去掉，
    //     否则亮度值一个都画不出来 —— 现在三格全开，靠 `ch_code` 的兜底 ' ' 保证
    //     其它行不会多画东西。
    wire        val_hit   = (in_val || in_val2);          // ★ A2：第三格已删
    wire        cur_hit   = in_cur && (row_now == menu_sel);
    //   ②' 查字模的三个"入口"：先按"在哪个**点阵格**里"定字符码和列号，不命中就是"不画"。
    //      ★ 光标格在几何上和名字格/数值格**互斥**（TXT_CU_P=4 起、TXT_LM_P=24 起、
    //        TXT_VM_P=192）⇒ 三路不会打架；`ch_code` 表里的兜底是 ' '（6'd0）⇒ 短名字
    //        后面那几格查出来是全 0，**不会误点亮**。
    wire        lab_on    = in_panel && gy_ok && lab_hit;
    wire        val_on    = in_panel && gy_ok && val_hit;
    wire        cur_on    = in_panel && gy_ok && cur_hit;
    wire [5:0]  font_ch   = lab_on ? ch_code : (val_on ? ch_code : 6'd29);
    // ★ 数值列两格：第一格 `gvx` / 第二格 `gvx2`（A2 删 VISUAL 行后第三格已去掉）
    wire [11:0] font_gx   = in_val ? gvx : gvx2;          // ★ A2：只有两格
    wire [2:0]  font_col  = lab_on ? glx[2:0] : (val_on ? font_gx[2:0] : gcx[2:0]);
    wire        font_px;

    font_rom u_font (
        .ch(font_ch), .row(gy_scaled[2:0]), .col(font_col), .px(font_px)
    );

    // ★★★ 文字（含 `>` 光标）：**只在字形那一位点灯时才改颜色**（这就是"不透明又不糊成方块"）
    wire draw_text = menu_on && (lab_on || val_on || cur_on) && font_px;

    // ---- 优先级（高覆盖低）：文字 > 分隔线 > 外框 > 面板底 ----
    //   ★ 2026-10-17：高亮条这一级已删（用户要求），选中靠行首 `>` 光标表示。
    wire draw_sep   = menu_on && in_panel && in_sep;
    wire draw_frame = menu_on && in_panel && in_frame;
    //  面板底 = 在面板内、且**不是外框也不是分隔线**（★ **不再**排除文字格！见上面 ①）
    wire draw_base  = menu_on && in_panel && !in_frame && !in_sep;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            px_out <= 16'h0000;
            de_out <= 1'b0;
            vs_out <= 1'b0;
        end
        else begin
            de_out <= de_p;                          // ★ de/vs 和像素一起打第二拍，绝不拆开
            vs_out <= vs_p;
            if      (draw_text)  px_out <= CLR_INK;   // ★ 文字（字形点灯处）盖在最上面
            else if (draw_sep)   px_out <= CLR_SEP;
            else if (draw_frame) px_out <= CLR_FRAME;
            else if (draw_base)  px_out <= CLR_PANEL; // ★ 面板内侧铺满 ⇒ 照片透不进来
            else                 px_out <= px_p;      // ★ 面板外 / 菜单关 ⇒ 逐位透传
        end
    end

endmodule
