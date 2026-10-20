// ============================================================
//  tb_menu_font.v —— 【一次性离线检查】menu_ovl + font_rom 的"画字"自检台
// ------------------------------------------------------------
//  不是工程的一部分（TD 的 M2.al 里**没有**这个文件），只在本机用 ModelSim 跑，
//  目的有四个：
//    ① 把新加的 font_rom.v / menu_ovl.v 编过（语法 + 位宽）；
//    ② 把面板上的**文字真正渲染出来**，用 ASCII 打印 ⇒ 肉眼核对字形/位置/十进制数值
//       （不用上板就能看出"黑白反相 / 字符错位 / 数值不刷新"这类问题）；
//    ③ 逐像素核对硬约束：`menu_on=0` 时 `px_out === px_in`（面板内和面板外都核）。
//    ④ ★★★ 2026-10-16【菜单字模·修正】新增：**整块面板（320×200）全像素 dump**
//       ⇒ 一次就能看出"面板有没有铺满不透明底色"（上板反馈"能看到背景"的根因），
//          以及放大 `TXT_SCALE=2` 之后的字是不是 10×14、有没有串列/错行。
//    ⑤ ★★★ 2026-10-17【菜单字模·修正与放大】再加两项**自动黄金对照**（人工看图容易漏）：
//       · `verify_menu_text`：按"点阵 × TXT_SCALE + 格步进 TXT_STEP + 字间距 TXT_SP +
//         高亮条/底色分层"把 4 行的名字/数值/光标**逐像素算一遍**，和 DUT 输出**逐位**比
//         ⇒ 列索引漂移/丢列/串列会直接报 `GOLD BAD`（本次上板的 (B) 项就是靠它定位的）；
//       · `passthru_sweep`：`menu_on=0` 时扫**整块面板 320×200 + 面板外一圈 + 消隐期**，
//         逐位核对 `px_out === px_in`（硬约束"逐位不变"）。
//
//  坐标系与真机一致：输入 de/x/y/px 与输出 px_out 差**两拍**（menu_ovl 的口径），
//  所以本台子给 x/y 的同时记下 px_in，两拍后和 px_out 比。
//
//  ★ 本台子的几何**必须**和 menu_ovl.v 文件头的 localparam 对齐（改那边就要改这边）：
//     PANEL 320×200、ROW_H = 200/4 = 50、TXT_SCALE = 2、TXT_H = 7 ⇒ 字高 14、
//     TXT_TOP = (50-14)/2 = 18 ⇒ 字形带在行内 y = [18, 32)，4 行 ⇒ 行顶 = 50*i。
// ============================================================
`timescale 1ns / 1ps

module tb_menu_font;

    reg clk = 0, rst_n = 0;
    always #12.5 clk = ~clk;                 // 40 MHz

    // ---- 屏幕 / 面板（和 menu_ovl 的默认参数一致）----
    localparam integer SCR_W    = 800;
    localparam integer SCR_H    = 600;
    localparam integer PANEL_X0 = 240;
    localparam integer PANEL_Y0 = 200;
    localparam integer PANEL_W  = 320;
    localparam integer PANEL_H  = 200;
    localparam integer ROW_H    = 50;        // ★ 2026-10-20【D1·A2】：回到 4 行 ⇒ 200/4
    localparam integer TXT_TOP  = 18;        // (50 - 7*2)/2 ★ 2026-10-20 随 ROW_H=50 同步
    localparam integer TXT_GH   = 14;        // 7 * TXT_SCALE

    reg  [11:0] x = 0, y = 0;
    //   ★ 面板外/未命中时 menu_ovl 会逐位透传 px_in ⇒ 打样时故意给 16'h0000，
    //     这样"出现在图里的 ? "就一定是 bug（而不是被透传的假画面颜色）。
    reg  [15:0] px = 16'h0000;
    reg         de = 0;
    reg         menu_on = 0;
    reg  [2:0]  menu_sel = 0;
    reg  [2:0]  zoom_lv = 0;
    reg  [1:0]  sel_aud = 0;
    reg  [3:0]  vol_lv  = 15;   // 2026-10-17 音量进菜单：行 2 的活值
    reg  [3:0]  bri_lv  = 15;   // 2026-10-17 亮度进菜单：行 3 的活值

    wire [15:0] px_out;
    wire        de_out, vs_out;

    menu_ovl u_dut (
        .clk_pix(clk), .rst_pix_n(rst_n),
        .de_in(de), .vs_in(1'b0), .x_in(x), .y_in(y), .px_in(px),
        .px_out(px_out), .de_out(de_out), .vs_out(vs_out),
        .menu_on(menu_on), .menu_sel(menu_sel),
        .zoom_lv(zoom_lv), .sel_aud(sel_aud), .vol_lv(vol_lv), .bri_lv(bri_lv)
        // ★ 2026-10-20【D1·A2】：`.viz_on` 端口已从 menu_ovl 删除（行 4 VISUAL 下线）
    );

    // ---- 颜色分类（和 menu_ovl 的 CLR_* 一致）----
    localparam [15:0] C_PANEL = 16'h4104;
    localparam [15:0] C_FRAME = 16'hFFFF;
    localparam [15:0] C_SEP   = 16'h8410;
    localparam [15:0] C_SEL   = 16'h20FF;
    localparam [15:0] C_INK   = 16'hFFC2;

    integer fd, n_pt, n_pt_bad, n_mismatch, i, jj, n_hole;
    reg [7:0] ch;

    // ============================================================
    //  ★★★ 2026-10-17【菜单字模·修正与放大】黄金对照用的几何（**必须**和 menu_ovl.v 对齐）
    // ============================================================
    localparam integer LAB_X0   = 24;        // = TXT_LM_P = TXT_LM * TXT_SCALE
    localparam integer LAB_DOTS = 42;        // = 6 格 * (TXT_W + TXT_SP) = 6*7
    localparam integer VAL_X0   = 192;       // = TXT_VM_P
    localparam integer TXT_STEP = 14;        // = (TXT_W + TXT_SP) * TXT_SCALE（★ 数值第二格用它）
    localparam integer CUR_X0   = 4;         // = TXT_CU_P
    localparam integer HIL_M    = 6;         // = FRAME_T + TXT_SCALE*2
    localparam integer HIL_T    = 9;         // = (ROW_H - 16*TXT_SCALE)/2
    localparam integer HIL_B    = 41;        // = HIL_T + 16*TXT_SCALE
    localparam integer TXT_GW   = 10;        // = TXT_W * TXT_SCALE

    // 期望的"墨点图"：先算出这一行每个点阵位该不该亮，再和真机逐像素比
    reg     exp_lab [0:511];                 // [dr*64 + 点列号(0..41)]（名字段）
    reg     exp_val [0:63];                  // [dr*8  + 点列号(0..4)]（数值段）
    reg     exp_val2[0:63];                  // ★ 2026-10-17 数值段【第二格】（VOLUME 十位/个位用）
    reg     exp_val3[0:63];                  // ★ 2026-10-18 数值段【第三格】（VISUAL 的 OFF 用）
    reg     exp_cur [0:63];                  // [dr*8  + 点列号(0..4)]（'>' 光标）
    reg [5:0] chs [0:5];
    integer n_gold, n_gold_bad, n_ps, n_ps_bad;

    // ---- 第二块 font_rom，专门给"打样/黄金对照"用（可直接驱动它的输入）----
    //   ★★★ 2026-10-17：这块**必须**声明在用到它的 task 之前（ModelSim 对
    //      "先用后声明"的 reg 会直接报 vlog-2730 Undefined variable）。
    reg  [5:0] pr_ch;
    reg  [2:0] pr_row, pr_col;
    wire       pr_px;
    font_rom u_probe (.ch(pr_ch), .row(pr_row), .col(pr_col), .px(pr_px));

    // ============================================================
    //  ★★★ 2026-10-17【菜单字模·修正与放大】① 黄金"点阵图"生成
    //    用第二块 font_rom（u_probe）算出**期望**的字形位，不重复字模数据本身。
    //    ★ 关键：格子按 TXT_STEP 步进、字形只占前 TXT_W 列、后 TXT_SP 列是字间距（恒不亮）。
    // ============================================================
    integer bg_dr, bg_d, bg_k;
    reg [5:0] bg_cc;
    task build_expect;
        input [5:0] c0, c1, c2, c3, c4, c5, cv;
        input [5:0] cv2;                        // ★ 数值段第二格（VOLUME 的个位）
        input [5:0] cv3;                        // ★ 数值段第三格（VISUAL 的 OFF 末位）
        begin
            chs[0] = c0; chs[1] = c1; chs[2] = c2;
            chs[3] = c3; chs[4] = c4; chs[5] = c5;
            // 名字段：42 个点列 = 6 格 × 7 点列（前 5 列是字形，后 2 列是字间距）
            for (bg_d = 0; bg_d < LAB_DOTS; bg_d = bg_d + 1) begin
                bg_k  = bg_d / 7;                       // 第几格
                bg_cc = bg_d - bg_k * 7;                // 格内点列号 0..6
                for (bg_dr = 0; bg_dr < 7; bg_dr = bg_dr + 1) begin
                    pr_ch = chs[bg_k]; pr_row = bg_dr[2:0]; pr_col = bg_cc[2:0];
                    #1;
                    exp_lab[bg_dr * 64 + bg_d] = (bg_cc < 5) ? pr_px : 1'b0;
                end
            end
            // 数值段（第一格，5 列宽）
            for (bg_d = 0; bg_d < 5; bg_d = bg_d + 1)
                for (bg_dr = 0; bg_dr < 7; bg_dr = bg_dr + 1) begin
                    pr_ch = cv; pr_row = bg_dr[2:0]; pr_col = bg_d[2:0];
                    #1;
                    exp_val[bg_dr * 8 + bg_d] = pr_px;
                end
            // 数值段（第二格）
            for (bg_d = 0; bg_d < 5; bg_d = bg_d + 1)
                for (bg_dr = 0; bg_dr < 7; bg_dr = bg_dr + 1) begin
                    pr_ch = cv2; pr_row = bg_dr[2:0]; pr_col = bg_d[2:0];
                    #1;
                    exp_val2[bg_dr * 8 + bg_d] = pr_px;
                end
            // 数值段（第三格）
            for (bg_d = 0; bg_d < 5; bg_d = bg_d + 1)
                for (bg_dr = 0; bg_dr < 7; bg_dr = bg_dr + 1) begin
                    pr_ch = cv3; pr_row = bg_dr[2:0]; pr_col = bg_d[2:0];
                    #1;
                    exp_val3[bg_dr * 8 + bg_d] = pr_px;
                end
            // '>' 光标（6'd29）
            for (bg_d = 0; bg_d < 5; bg_d = bg_d + 1)
                for (bg_dr = 0; bg_dr < 7; bg_dr = bg_dr + 1) begin
                    pr_ch = 6'd29; pr_row = bg_dr[2:0]; pr_col = bg_d[2:0];
                    #1;
                    exp_cur[bg_dr * 8 + bg_d] = pr_px;
                end
        end
    endtask

    // ============================================================
    //  ★★★ 2026-10-17【菜单字模·修正与放大】② 一行文字带的**逐像素**黄金对照
    //    层次和 menu_ovl.v 完全一致：外框 > 高亮条 > 面板底，最后"只在字形=1 处"盖 CLR_INK。
    // ============================================================
    integer vb_xl, vb_yl, vb_dr;
    reg     vb_ink, vb_hil;
    reg [15:0] vb_want;
    task verify_band;
        input integer ri;
        begin
            for (vb_yl = 0; vb_yl < TXT_GH; vb_yl = vb_yl + 1) begin
                vb_dr = vb_yl / 2;                       // 点阵行号（放大倍数 = 2）
                for (vb_xl = 0; vb_xl < PANEL_W; vb_xl = vb_xl + 1) begin
                    //   ★★★ 2026-10-17【高亮条已删】：用户要求"选中行只看行首 `>` 光标"，
                    //     `menu_ovl` 里 `in_hilite` / `draw_sel` 整段删除 ⇒ 选中行**不再是** CLR_SEL，
                    //     和别的行一样是面板底色。这里跟着改（原来按 C_SEL 期望 ⇒ 全是假失配）。
                    vb_hil  = 1'b0;
                    vb_want = C_PANEL;
                    if (vb_xl < 2 || vb_xl >= PANEL_W - 2) vb_want = C_FRAME;
                    vb_ink = 1'b0;
                    if ((vb_xl >= LAB_X0) && (vb_xl < LAB_X0 + LAB_DOTS * 2))
                        vb_ink = exp_lab[vb_dr * 64 + (vb_xl - LAB_X0) / 2];
                    else if ((vb_xl >= VAL_X0) && (vb_xl < VAL_X0 + TXT_GW))
                        vb_ink = exp_val[vb_dr * 8 + (vb_xl - VAL_X0) / 2];
                    //   ★ 2026-10-17 起行 3 `BRIGHT` 也用第二格 ⇒ 行 2/3 都查
                    else if ((vb_xl >= VAL_X0 + TXT_STEP) && (vb_xl < VAL_X0 + TXT_STEP + TXT_GW) && ((ri == 2) || (ri == 3)))
                        vb_ink = exp_val2[vb_dr * 8 + (vb_xl - VAL_X0 - TXT_STEP) / 2];
                    //   ★ 2026-10-20【D1·A2】：行 4 VISUAL 删除 ⇒ 第三格（ON/OFF）不再存在
                    else if ((vb_xl >= CUR_X0) && (vb_xl < CUR_X0 + TXT_GW) && (ri == menu_sel))
                        vb_ink = exp_cur[vb_dr * 8 + (vb_xl - CUR_X0) / 2];
                    if (vb_ink) vb_want = C_INK;
                    step_px(12'(PANEL_X0 + vb_xl),
                            12'(PANEL_Y0 + ri * ROW_H + TXT_TOP + vb_yl), 16'h0000, 1'b1);
                    n_gold = n_gold + 1;
                    if (px_out !== vb_want) begin
                        n_gold_bad = n_gold_bad + 1;
                        if (n_gold_bad <= 12)
                            $display("GOLD BAD row=%0d x=%0d y=%0d got=%h want=%h",
                                     ri, vb_xl, vb_yl, px_out, vb_want);
                    end
                end
            end
        end
    endtask

    // 4 行全查：名字/数值/光标都按当前 zoom_lv / sel_aud / menu_sel 现算
    integer vmr_ri;
    reg [5:0] vmr0, vmr1, vmr2, vmr3, vmr4, vmr5, vmrv, vmrv2, vmrv3;
    task verify_menu_text;
        begin
            for (vmr_ri = 0; vmr_ri < 4; vmr_ri = vmr_ri + 1) begin
                vmr0 = 6'd0; vmr1 = 6'd0; vmr2 = 6'd0;
                vmr3 = 6'd0; vmr4 = 6'd0; vmr5 = 6'd0;
                vmrv = 6'd0; vmrv2 = 6'd0; vmrv3 = 6'd0;
                case (vmr_ri)
                    0: begin vmr0=6'd58; vmr1=6'd47; vmr2=6'd47; vmr3=6'd45;
                             vmrv = 6'd16 + {3'd0, zoom_lv}; end
                    1: begin vmr0=6'd33; vmr1=6'd53; vmr2=6'd36; vmr3=6'd41; vmr4=6'd47;
                             vmrv = 6'd16 + {4'd0, sel_aud} + 6'd1; end
                    2: begin vmr0=6'd54; vmr1=6'd47; vmr2=6'd44; vmr3=6'd53; vmr4=6'd45; vmr5=6'd37;
                             // ★ 2026-10-17 音量进菜单：两位十进制（十位 = '1' 或留白，个位 = '0'..'9'）
                             vmrv  = (vol_lv >= 4'd10) ? (6'd16 + 6'd1) : 6'd0;
                             vmrv2 = 6'd16 + {2'd0, ((vol_lv >= 4'd10) ? (vol_lv - 4'd10) : vol_lv)}; end
                    3: begin vmr0=6'd34; vmr1=6'd50; vmr2=6'd41; vmr3=6'd39; vmr4=6'd40; vmr5=6'd52;
                             vmrv  = (bri_lv >= 4'd10) ? (6'd16 + 6'd1) : 6'd0;
                             vmrv2 = 6'd16 + {2'd0, ((bri_lv >= 4'd10) ? (bri_lv - 4'd10) : bri_lv)}; end
                    // ★ 2026-10-20【D1·A2】行 4 `VISUAL` 已删 ⇒ 这里只是 case 的兜底（永不命中）
                    default: begin vmr0=6'd0; vmr1=6'd0; vmr2=6'd0; vmr3=6'd0; vmr4=6'd0; vmr5=6'd0;
                              vmrv=6'd0; vmrv2=6'd0; vmrv3=6'd0; end
                endcase
                build_expect(vmr0, vmr1, vmr2, vmr3, vmr4, vmr5, vmrv, vmrv2, vmrv3);
                verify_band(vmr_ri);
            end
        end
    endtask

    // ============================================================
    //  ★★★ 2026-10-17【菜单字模·修正与放大】③ menu_on=0 的"逐位不变"全扫
    //    覆盖：面板内 320×200 全部 + 面板四周各 4 行的外圈 + 消隐期（de=0）采样点。
    // ============================================================
    integer ps_x, ps_y;
    task passthru_sweep;
        begin
            // 面板内 + 外圈（y 从 PANEL_Y0-4 到 PANEL_Y0+PANEL_H+3，x 从 PANEL_X0-4 到 +PANEL_W+3）
            for (ps_y = PANEL_Y0 - 4; ps_y < PANEL_Y0 + PANEL_H + 4; ps_y = ps_y + 1)
                for (ps_x = PANEL_X0 - 4; ps_x < PANEL_X0 + PANEL_W + 4; ps_x = ps_x + 1) begin
                    step_px(12'(ps_x), 12'(ps_y), 16'hA5A5, 1'b1);
                    n_ps = n_ps + 1;
                    if (px_out !== 16'hA5A5) begin
                        n_ps_bad = n_ps_bad + 1;
                        if (n_ps_bad <= 6)
                            $display("PASSTHRU BAD: x=%0d y=%0d got %h", ps_x, ps_y, px_out);
                    end
                end
            // 消隐期（de=0）：面板内也一个像素都不许改
            for (ps_y = PANEL_Y0; ps_y < PANEL_Y0 + PANEL_H; ps_y = ps_y + 7)
                for (ps_x = PANEL_X0; ps_x < PANEL_X0 + PANEL_W; ps_x = ps_x + 7) begin
                    step_px(12'(ps_x), 12'(ps_y), 16'h5A5A, 1'b0);
                    n_ps = n_ps + 1;
                    if (px_out !== 16'h5A5A) begin
                        n_ps_bad = n_ps_bad + 1;
                        if (n_ps_bad <= 8)
                            $display("PASSTHRU BAD(blank): x=%0d y=%0d got %h", ps_x, ps_y, px_out);
                    end
                end
        end
    endtask

    // ---- 第二块 font_rom 的声明见上面（已提前到黄金对照 task 之前）----

    // ---- 颜色 → 一个 ASCII 字符（面板内拿来"看图"）----
    function [7:0] glyph_of;
        input [15:0] c;
        begin
            if      (c === C_INK)   glyph_of = "#";   // 文字（前景）
            else if (c === C_SEL)   glyph_of = "=";   // 高亮条
            else if (c === C_FRAME) glyph_of = "*";   // 外框
            else if (c === C_SEP)   glyph_of = "-";   // 分隔线
            else if (c === C_PANEL) glyph_of = ".";   // 面板底
            else if (c === 16'h0000) glyph_of = " ";   // 透传的"假画面"（测试台给的黑）
            else                    glyph_of = "?";   // 不该出现
        end
    endfunction

    // ---- 走一个像素：给输入、等两拍、返回输出 ----
    task step_px;
        input  [11:0] tx, ty;
        input  [15:0] tpx;
        input         tde;
        begin
            @(negedge clk);
            x = tx; y = ty; px = tpx; de = tde;
            @(posedge clk); @(posedge clk); #1;
        end
    endtask

    // ---- 渲染面板内 [ry0,ry1) × 全宽：按真机的连续扫描顺序喂 ----
    //   ★ 循环变量**必须**在 task 里自己声明（rail_/col_），
    //     否则会和调用点的同名变量撞车（Verilog 静态作用域 ⇒ 调用点的值被改掉，
    //     屏上就"画到别的行去了"。本台子就是这么被坑过一次。）
    task render_rows;
        input integer ry0, ry1;
        integer rail_, col_;
        begin
            for (rail_ = ry0; rail_ < ry1; rail_ = rail_ + 1) begin
                // ★ 每行开头打一次"面板内行号"（rail_-PANEL_Y0），竖着看就是 ASCII 图
                $fwrite(fd, "%3d|", rail_ - PANEL_Y0);
                for (col_ = 0; col_ < PANEL_W; col_ = col_ + 1) begin
                    step_px(PANEL_X0 + col_, rail_, 16'h0000, 1'b1);
                    $fwrite(fd, "%c", glyph_of(px_out));
                end
                $fwrite(fd, "\n");
            end
        end
    endtask

    // ---- ★★★ 2026-10-16【菜单字模·修正】新加：整块面板 320×200 全 dump ----
    //   ★ 一次跑完 200 行会喂 200*320 = 64000 个像素（每个 2 拍），本机约几秒，可以接受。
    //   ★ 用途：肉眼确认**面板内侧一个空格都没有**（全是 `.`/`=`/`*`/`-`/`#`）——
    //     只要有空格，就是"该铺底色没铺"，也就是上板反馈的"能看到背景"。
    task render_panel_full;
        begin
            $fwrite(fd, "=== 整块面板 320(W) x 200(H) 全像素 dump ===\n");
            $fwrite(fd, "    # = 文字墨色(CLR_INK)   = = 选中行高亮条(CLR_SEL)\n");
            $fwrite(fd, "    * = 外框(CLR_FRAME)     - = 行分隔线(CLR_SEP)   . = 面板底(CLR_PANEL)\n");
            $fwrite(fd, "    (空格) = **透传了面板外的画面 ⇒ 面板不透明性被破坏 = bug**\n");
            render_rows(PANEL_Y0, PANEL_Y0 + PANEL_H);
            $fwrite(fd, "=== 全 dump 结束 ===\n");
        end
    endtask

    // ---- 统计：面板内侧有没有"漏底"（透传）的像素 ----
    task count_holes;
        input integer ry0, ry1;
        integer rail_, col_;
        begin
            n_hole = 0;
            for (rail_ = ry0; rail_ < ry1; rail_ = rail_ + 1) begin
                for (col_ = 0; col_ < PANEL_W; col_ = col_ + 1) begin
                    step_px(PANEL_X0 + col_, rail_, 16'h0000, 1'b1);
                    if (px_out === 16'h0000) n_hole = n_hole + 1;
                end
            end
        end
    endtask

    initial begin
        fd = $fopen("menu_render.txt", "w");
        n_pt = 0; n_pt_bad = 0; n_mismatch = 0;
        n_gold = 0; n_gold_bad = 0; n_ps = 0; n_ps_bad = 0;

        // 复位（menu_ovl 的寄存器复位需要 2 拍才把 x_p/px_p 清干净）
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ============================================================
        //  ① menu_on = 0：逐像素核对"面板内也逐位透传"（本步硬约束）
        //     ★★★ 2026-10-17：换成 `passthru_sweep` —— 整块面板 320×200 +
        //        面板外一圈 4 行 + 消隐期，逐位核对 px_out === px_in。
        // ============================================================
        menu_on = 0; menu_sel = 0; zoom_lv = 5; sel_aud = 3;
        passthru_sweep;
        $display("PASSTHRU(menu_on=0, full panel + ring + blank): %0d/%0d pixels differ",
                 n_ps_bad, n_ps);
        $fwrite(fd, "=== menu_on=0 逐位透传全扫：%0d / %0d 像素不同（**必须为 0**）===\n\n",
                n_ps_bad, n_ps);

        // ============================================================
        //  ② menu_on = 1：渲染 4 行文字，逐行打印到 menu_render.txt
        //     行 0 ZOOM  : zoom_lv = 3          -> 期望 "3"
        //     行 1 AUDIO : sel_aud = 3 (第4条)  -> 期望 "4"
        //     行 2 VOLUME: 占位                 -> 期望 "--"
        //     行 3 EXIT  : 无值
        //     选中行 menu_sel = 1               -> 高亮条 + ">" 在行 1
        // ============================================================
        menu_on = 1; zoom_lv = 3; sel_aud = 3; menu_sel = 1;
        //   先空扫一整帧，让内部同步/坐标链稳定
        for (i = 0; i < 24; i = i + 1) step_px(12'(i), 12'(i), 16'h0000, 1'b1);
        $fwrite(fd, "=== menu_on=1  zoom_lv=3  sel_aud=3(->AUDIO 4)  menu_sel=1 ===\n");
        $fwrite(fd, "   (每行只打该行字形带 y = 行顶+%0d .. +%0d，共 320 列；\n",
                TXT_TOP, TXT_TOP + TXT_GH - 1);
        $fwrite(fd, "    # = 文字  = = 高亮条  . 面板底  ** 空格 = 漏底/bug **)\n");
        //   ★★★ 2026-10-17【菜单字模·修正与放大】先跑黄金对照：设置 A（行 0 值 3 / 行 1 值 4 / sel=1）
        verify_menu_text;
        $display("GOLD(setA zoom=3 aud=4 sel=1): %0d bad / %0d px", n_gold_bad, n_gold);
        for (i = 0; i < 4; i = i + 1) begin
            $fwrite(fd, "--- row %0d  (行顶 y = PANEL_Y0+%0d) ---\n", i, i * ROW_H);
            render_rows(PANEL_Y0 + i * ROW_H + TXT_TOP,
                        PANEL_Y0 + i * ROW_H + TXT_TOP + TXT_GH);
        end

        //   ★★★ 2026-10-16【菜单字模·修正】整块面板全 dump + 漏底统计
        //      ★ 先空扫一整帧（连续扫描顺序），避免跨行残留
        for (i = 0; i < 24; i = i + 1) step_px(12'(i), 12'(i), 16'h0000, 1'b1);
        render_panel_full;
        count_holes(PANEL_Y0, PANEL_Y0 + PANEL_H);
        $display("FULLPANEL(menu_on=1): %0d / %0d pixels still transparent (must be 0)",
                 n_hole, PANEL_W * PANEL_H);
        $fwrite(fd, ">>> 面板内\"漏底\"(透传)像素 = %0d / %0d （**必须为 0**）\n\n",
                n_hole, PANEL_W * PANEL_H);

        //   换一组值：zoom_lv = 0 / sel_aud = 0（第 1 条）⇒ 期望 "0" 和 "1"
        menu_sel = 0; zoom_lv = 0; sel_aud = 0;
        for (i = 0; i < 24; i = i + 1) step_px(12'(i), 12'(i), 16'h1234, 1'b1);
        verify_menu_text;
        $display("GOLD(setB zoom=0 aud=1 sel=0): %0d bad / %0d px", n_gold_bad, n_gold);
        $fwrite(fd, "=== zoom_lv=0  sel_aud=0(->AUDIO 1)  menu_sel=0 ===\n");
        for (i = 0; i < 4; i = i + 1) begin
            $fwrite(fd, "--- row %0d ---\n", i);
            render_rows(PANEL_Y0 + i * ROW_H + TXT_TOP,
                        PANEL_Y0 + i * ROW_H + TXT_TOP + TXT_GH);
        end

        //   换一组值：zoom_lv = 5 / sel_aud = 2（第 3 条）⇒ 期望 "5" 和 "3"
        menu_sel = 3; zoom_lv = 5; sel_aud = 2;
        for (i = 0; i < 24; i = i + 1) step_px(12'(i), 12'(i), 16'h1234, 1'b1);
        verify_menu_text;
        $display("GOLD(setC zoom=5 aud=3 sel=3): %0d bad / %0d px", n_gold_bad, n_gold);
        $fwrite(fd, "=== zoom_lv=5  sel_aud=2(->AUDIO 3)  menu_sel=3 ===\n");
        for (i = 0; i < 4; i = i + 1) begin
            $fwrite(fd, "--- row %0d ---\n", i);
            render_rows(PANEL_Y0 + i * ROW_H + TXT_TOP,
                        PANEL_Y0 + i * ROW_H + TXT_TOP + TXT_GH);
        end

        // ============================================================
        //  ★★★ 2026-10-17【音量进菜单】setD：音量 < 10 ⇒ 十位留白、个位一个数字，
        //    而且光标停在 **VOLUME 行**（menu_sel = 2）⇒ 同时验 `>` 光标落在第 2 行。
        // ============================================================
        menu_sel = 2; zoom_lv = 5; sel_aud = 2; vol_lv = 7;
        for (i = 0; i < 24; i = i + 1) step_px(12'(i), 12'(i), 16'h1234, 1'b1);
        verify_menu_text;
        $display("GOLD(setD vol=7 sel=2): %0d bad / %0d px", n_gold_bad, n_gold);
        $fwrite(fd, "=== vol_lv=7(->\" 7\")  menu_sel=2(VOLUME 行) ===\n");
        for (i = 0; i < 4; i = i + 1) begin
            $fwrite(fd, "--- row %0d ---\n", i);
            render_rows(PANEL_Y0 + i * ROW_H + TXT_TOP,
                        PANEL_Y0 + i * ROW_H + TXT_TOP + TXT_GH);
        end

        // ============================================================
        //  ★★★ 2026-10-17【亮度进菜单】setE：亮度 < 10 ⇒ 十位留白、个位一个数字，
        //    光标停在 **BRIGHT 行**（menu_sel = 3）⇒ 同时验 > 光标落在第 3 行、
        //    以及行 3 的名字确实是 BRIGHT（B R I G H T）而不是旧的 EXIT。
        // ============================================================
        menu_sel = 3; zoom_lv = 1; sel_aud = 1; vol_lv = 15; bri_lv = 7;
        for (i = 0; i < 24; i = i + 1) step_px(12'(i), 12'(i), 16'h1234, 1'b1);
        verify_menu_text;
        $display("GOLD(setE bri=7 sel=3): %0d bad / %0d px", n_gold_bad, n_gold);
        $fwrite(fd, "=== bri_lv=7    menu_sel=3(BRIGHT row) ===\n");
        for (i = 0; i < 4; i = i + 1) begin
            $fwrite(fd, "--- row %0d ---\n", i);
            render_rows(PANEL_Y0 + i * ROW_H + TXT_TOP,
                        PANEL_Y0 + i * ROW_H + TXT_TOP + TXT_GH);
        end

        // ============================================================
        //  setF：亮度 >= 10 ⇒ 十位画 1、个位 2（12），同时音量 3
        // ============================================================
        menu_sel = 2; zoom_lv = 5; sel_aud = 0; vol_lv = 3; bri_lv = 12;
        for (i = 0; i < 24; i = i + 1) step_px(12'(i), 12'(i), 16'h1234, 1'b1);
        verify_menu_text;
        $display("GOLD(setF bri=12 vol=3 sel=2): %0d bad / %0d px", n_gold_bad, n_gold);
        $fwrite(fd, "=== bri_lv=12  vol_lv=3  menu_sel=2(VOLUME row) ===\n");
        for (i = 0; i < 4; i = i + 1) begin
            $fwrite(fd, "--- row %0d ---\n", i);
            render_rows(PANEL_Y0 + i * ROW_H + TXT_TOP,
                        PANEL_Y0 + i * ROW_H + TXT_TOP + TXT_GH);
        end

        // ============================================================
        //  ★ 2026-10-20【D1·A2】原 setG / setH（VISUAL ON / OFF，menu_sel=4）已删：
        //    行 4 VISUAL 下线后菜单只剩 4 行。这里换成"光标停在第 4 行（BRIGHT）"
        //    的收尾对照，保证 4 行的四种光标位置都过一遍黄金对照。
        // ============================================================
        menu_sel = 3; zoom_lv = 0; sel_aud = 0; vol_lv = 15; bri_lv = 15;
        for (i = 0; i < 24; i = i + 1) step_px(12'(i), 12'(i), 16'h1234, 1'b1);
        verify_menu_text;
        $display("GOLD(setH sel=3 末行): %0d bad / %0d px", n_gold_bad, n_gold);
        $fwrite(fd, "=== 收尾对照 menu_sel=3（末行 BRIGHT）===\n");
        for (i = 0; i < 4; i = i + 1) begin
            $fwrite(fd, "--- row %0d ---\n", i);
            render_rows(PANEL_Y0 + i * ROW_H + TXT_TOP,
                        PANEL_Y0 + i * ROW_H + TXT_TOP + TXT_GH);
        end

        // ============================================================
        //  ③ 字形全表打样：把 40 个字形的点阵直接打印出来（核对 font_rom 本身）
        // ============================================================
        $fwrite(fd, "\n=== font_rom 字形打样 (# = 点灯) ===\n");
        i = 0;
        dump_glyph(6'd16); dump_glyph(6'd17); dump_glyph(6'd18); dump_glyph(6'd19);
        dump_glyph(6'd20); dump_glyph(6'd21); dump_glyph(6'd22); dump_glyph(6'd23);
        dump_glyph(6'd24); dump_glyph(6'd25);
        dump_glyph(6'd33); dump_glyph(6'd34); dump_glyph(6'd35); dump_glyph(6'd36);
        dump_glyph(6'd37); dump_glyph(6'd38); dump_glyph(6'd39); dump_glyph(6'd40);
        dump_glyph(6'd41); dump_glyph(6'd42); dump_glyph(6'd43); dump_glyph(6'd44);
        dump_glyph(6'd45); dump_glyph(6'd46); dump_glyph(6'd47); dump_glyph(6'd48);
        dump_glyph(6'd49); dump_glyph(6'd50); dump_glyph(6'd51); dump_glyph(6'd52);
        dump_glyph(6'd53); dump_glyph(6'd54); dump_glyph(6'd55); dump_glyph(6'd56);
        dump_glyph(6'd57); dump_glyph(6'd58);
        dump_glyph(6'd13); dump_glyph(6'd26); dump_glyph(6'd29);

        $fclose(fd);
        $display("=== DONE: menu_render.txt written; passthru(menu_on=0) bad = %0d ; GOLD text bad = %0d ===",
                 n_ps_bad, n_gold_bad);
        $finish;
    end

    // ---- 打一个字形（5 列 × 7 行）----
    task dump_glyph;
        input [5:0] c;
        integer r, cc;
        begin
            pr_ch = c;
            $fwrite(fd, "ch=%0d :\n", c);
            for (r = 0; r < 7; r = r + 1) begin
                pr_row = r[2:0];
                $fwrite(fd, "   ");
                for (cc = 0; cc < 5; cc = cc + 1) begin
                    pr_col = cc[2:0];
                    #1;
                    $fwrite(fd, "%c", pr_px ? "#" : ".");
                end
                $fwrite(fd, "\n");
            end
        end
    endtask

endmodule
