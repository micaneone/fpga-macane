// ============================================================
//  模块名 : font32_rom —— 【32×32 字模库】（★ 与 5×7 的 font_rom.v 两个模块，别混）
//  来源   : 用户 2026-10-18 交付的 `font_rom.v` + `font.mem`（tools/make_font.py 生成）
//  用途   : 菜单 `menu_ovl` 的 图标 + 两位数字（见 menu_ovl.v 文件头）
// ------------------------------------------------------------
//  ── 字模库内容（20 个，每个 32 行 × 32 位 = 32 个字，共 640 字）──
//      序号  0..9  = '0'..'9'
//      序号 10..16 = 亮 度 对 比 尺 寸 图
//      序号 17     = icon_sun（太阳 / 亮度）
//      序号 18     = icon_volume（喇叭 / 音量）
//      序号 19     = icon_contrast（对比度）
//
//  ── 打包规则（和 `sub_analyze` 的字幕位图**完全一致**，也是 `font_rom.v` 的口径）──
//      · 1 bit / 像素，**黑 = 1（画），白 = 0（透过去）**
//      · bit31 = 这一组 32 像素里【最左边】的那个
//      · 行序【自下而上】：第 r 行 = 屏幕第 (H-1-r) 行
//        ⇒ 屏幕行号 `gy`（0 = 字形最上面）对应 `addr = gidx*32 + (31-gy)`
//      · 每 32 像素 = 1 个 32 位字
//
//  ── 地址 ──
//      addr[9:0] = gidx*32 + row，gidx 0..19 ⇒ addr 0..639
//
//  ── ★★★ 为什么必须是 BRAM（不能再用 font_rom.v 那种纯组合 case）──
//      640 字 × 32 位 = 20,480 bit。5×7 那个字模只有 ~60 个 8 位字（几百 bit），
//      写成组合 case 就是几十个 LUT；这个 20 kbit 若写成组合 case，综合器要拿
//      5,000 个 LUT4 去拼 —— 而本工程 slices 已经到 81%，直接爆掉。
//      ⇒ 只能落 BRAM（EG4S20 还有 18 块空闲），初值靠 `$readmemh` 在综合时写进
//        比特流（**上电即有效，不需要运行时装载**）。
//      ★ 若 TD 不支持 $readmemh 初始化 BRAM，综合日志里会报；退路见文件尾。
//
//  ── ★ BRAM 推断的四个要点（照抄不会被工具改成 LUT）──
//      ① 只写 `posedge clk` + 非阻塞赋值，**不加异步复位**
//      ② 不加读使能
//      ③ 输出**必须寄存**（BRAM 只有寄存读）⇒ dout 比 addr 晚 1 拍
//      ④ 加综合属性让它别优化回 LUT
//
//  ── 时序（用的人必须知道）──
//      `dout` 比 `addr` 晚 **1 拍**。menu_ovl 里用"**第 0 拍给地址**（用 x_in/y_in）、
//      第 1 拍用数据（配 x_p/y_p）"的办法把这 1 拍吃掉，整条流水线的总延迟
//      **一点没变**（仍是 2 拍），所以 hs/vs 不用动。
// ============================================================
`timescale 1ns / 1ps

module font32_rom #(
    // 初始化文件。★ 用**绝对路径**：TD 综合时的当前目录是 prj/M2_Runs/syn_1，
    //   相对路径会找不到文件（且 $readmemh 找不到时只警告、不报错 ⇒ 屏幕全空，极难查）。
    parameter MEMF = "E:/FPGA/ygcom/pre-release-testing/b_display/font.mem",
    parameter integer DEPTH = 640,
    parameter integer ADDRW = 10
)(
    input  wire             clk,
    input  wire [ADDRW-1:0] addr,
    output reg  [31:0]      dout
);

    // ★ 三条属性一起写：Vivado / Synplify / TD 各认一条，不认识的忽略
    (* rom_style = "block", syn_ramstyle = "block_ram", ramstyle = "block_ram" *)
    reg [31:0] rom [0:DEPTH-1];

    // ★ 综合时把 font.mem 烧进 BRAM 初值（不占逻辑、上电即有效）
    initial begin
        $readmemh(MEMF, rom);
    end

    // ★ 只有这一段：纯同步读，不带上复位/使能
    always @(posedge clk) begin
        dout <= rom[addr];
    end

endmodule
