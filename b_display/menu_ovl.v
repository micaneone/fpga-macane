// ============================================================
//  模块名 : menu_ovl —— 【参数菜单面板】（像素流水第 ④' 级，本步**只画纯色，不写字**）
//  层次   : `subtitle_ovl` 之后、RGB565→RGB888 之前（disp_top 里压在最上面那一层）
//  时钟域 : 单域 —— clk_pix（40 MHz），和 subtitle_ovl 的像素侧**同一个域**
//  依据   : 用户 2026-10-15 定稿的「参数菜单·第 1 步」规格
// ------------------------------------------------------------
//  ★★★ 2026-10-15【参数菜单·第1步】本模块干什么（一句话）：
//      `menu_on`=1 时，在屏幕正中画一个**纯色面板**（外框 + 面板底 + 内部 4 条等高分
//      隔线 + 选中行一条**高亮条**）；`menu_on`=0 时**一个像素都不改**（逐位透传）。
//
//  ★ 硬约束（本步最重要的一条）：**面板外一个像素都不许改**
//      · 所有画的动作都先与 `in_panel` 相与，`in_panel` 又含 `de_in`（消隐期恒 0）
//        ⇒ 面板矩形以外（含消隐区）输出**就是输入本身**，逐位相同。
//      · `menu_on=0` 时 `draw_*` 全 0 ⇒ `px_out <= px_in`；而且 `menu_on` 是**慢变电平**，
//        综合时能被常数传播 ⇒ 菜单这一级退化成一串纯寄存器 ⇒ 对既有画面零影响。
//
//  ★ 本步**不写字**（用户明确"纯色面板（不写字）"）：
//      所以这里没有字形 ROM、没有取数、没有 BRAM/DSP —— 目标是 0 BRAM、0 DSP。
//      第 2 步要写字时，在这一层里再加一块字模 ROM 即可，**接口不用变**。
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
//  ★ 画面元素与优先级（**高者覆盖低者**，同一像素只会命中一个）：
//        ① 选中行高亮条 画 `CLR_SEL`
//        ② 面板外框     画 `CLR_FRAME`
//        ③ 行分隔线     画 `CLR_SEP`
//        ④ 面板底       画 `CLR_PANEL`
//      ⇒ 从外到内逐层盖：底色 → 分隔线 → 外框 → 高亮条（高亮条压在框内侧之上）。
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
    // ---- 面板内部：4 条等高行（和顶层 MENU_N=4 一致；改这里也要改顶层那个）----
    parameter integer ROW_N = 4,
    // ---- 外框线宽（像素）；分隔线宽同样用它 ----
    parameter integer FRAME_T = 2,
    // ---- 高亮条：比一行矮一点 ⇒ 行与行之间看得出缝（反差更明显）----
    parameter integer HILITE_H = 30,
    // ---- 颜色（RGB565）----
    //    面板底 : 深灰   R=8  G=16 B=8   → 16'h4104
    //    外框   : 近白   R=31 G=63 B=31  → 16'hFFFF
    //    分隔线 : 中灰   R=16 G=32 B=16  → 16'h8410
    //    高亮条 : 亮蓝   R=4  G=32 B=31  → 16'h20FF（对深灰底反差极大）
    parameter [15:0] CLR_PANEL = 16'h4104,
    parameter [15:0] CLR_FRAME = 16'hFFFF,
    parameter [15:0] CLR_SEP   = 16'h8410,
    parameter [15:0] CLR_SEL   = 16'h20FF
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
    input  wire [1:0]  menu_sel      // 选中行 0..3（第 2 步用它选参数；本步只挪高亮条）
);

    // ============================================================
    //  面板几何（全部由上面的参数算出，不写死坐标）
    // ============================================================
    localparam integer PANEL_X0 = (SCR_W - PANEL_W) / 2;      // 800/320 ⇒ 240
    localparam integer PANEL_Y0 = (SCR_H - PANEL_H) / 2;      // 600/200 ⇒ 200
    localparam integer PANEL_X1 = PANEL_X0 + PANEL_W;         // 560（右开区间）
    localparam integer PANEL_Y1 = PANEL_Y0 + PANEL_H;         // 400（右开区间）
    localparam integer ROW_H    = PANEL_H / ROW_N;            // 200/4 ⇒ 50
    // 高亮条的上下沿（按行居中）
    localparam integer HIL_TOP  = (ROW_H - HILITE_H) / 2;      // (50-30)/2 ⇒ 10
    localparam integer HIL_BOT  = HIL_TOP + HILITE_H;          // 40

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
    // ---- 行号：用比较链而不是除法（4 行只要 3 个比较器，比 ^/ 便宜得多）----
    wire [1:0] row_now = (y_p >= (PANEL_Y0 + ROW_H * 3)) ? 2'd3 :
                         (y_p >= (PANEL_Y0 + ROW_H * 2)) ? 2'd2 :
                         (y_p >= (PANEL_Y0 + ROW_H * 1)) ? 2'd1 : 2'd0;

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
                      (y_p == (PANEL_Y0 + ROW_H * 3 - 1));
    //   高亮条：在选中行里，相对该行顶的偏移落在 [HIL_TOP, HIL_BOT)；
    //   横向从框内侧起（左右各留 FRAME_T+4 的缝）。
    //   ★ `hy` 这个减法一次就够：两次减的都是常量 ⇒ 综合成一个减法器复用。
    wire [11:0] hy = y_p - (PANEL_Y0 + ROW_H * row_now);
    wire in_hilite  = (row_now == menu_sel) &&
                      (hy >= HIL_TOP) && (hy < HIL_BOT) &&
                      (x_p >= (PANEL_X0 + FRAME_T + 4)) && (x_p < (PANEL_X1 - FRAME_T - 4));

    // ---- 优先级（高覆盖低）：高亮条 > 外框 > 分隔线 > 面板底 ----
    //   ★ in_hilite/in_frame/in_sep 三个互斥只差一处：高亮条和分隔线**不可能同拍**
    //     （高亮条在行内居中、分隔线在行尾线上），但为了"优先级"明确，这里仍旧显式写
    //     成"高覆盖低"的 if 链，不依赖那个巧合。
    wire draw_sel   = menu_on && in_panel && in_hilite;
    wire draw_frame = menu_on && in_panel && in_frame;
    wire draw_sep   = menu_on && in_panel && in_sep;
    //  面板底 = 在面板内、且上面三层都没命中
    wire draw_base  = menu_on && in_panel && !in_hilite && !in_frame && !in_sep;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            px_out <= 16'h0000;
            de_out <= 1'b0;
            vs_out <= 1'b0;
        end
        else begin
            de_out <= de_p;                          // ★ de/vs 和像素一起打第二拍，绝不拆开
            vs_out <= vs_p;
            if      (draw_sel)   px_out <= CLR_SEL;
            else if (draw_frame) px_out <= CLR_FRAME;
            else if (draw_sep)   px_out <= CLR_SEP;
            else if (draw_base)  px_out <= CLR_PANEL;
            else                 px_out <= px_p;      // ★ 面板外 / 菜单关 ⇒ 逐位透传
        end
    end

endmodule
