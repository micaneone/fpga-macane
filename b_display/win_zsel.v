// ============================================================
//  模块名 : win_zsel
//  作用   : 【多窗口命中 + z 序选择】—— 给定屏幕像素，选出"最上面那个命中窗口"
//  层次   : 像素流水第 ① 级"地址生成"的最前面（win_compositor / scaler_addr 之前）
//  时钟域 : 像素域 40 MHz（纯组合）
//  依据   : B轨说明书 §6.1（只画最上面那一个）、契约第六节（窗口表字段）
// ------------------------------------------------------------
//  ★★ 为什么必须"只选最上面那一个"，不能逐层叠加：
//     画家算法（从下往上叠）会让每个像素读 N 次源图 —— 4 窗口就是 4 读/像素，
//     带宽 4 倍，直接爆。**"选最上面一个"把多窗口的带宽锁死在 1 读/像素。**
//
//  ★ 输入是【打包的窗口记录】（每条 168 位，位偏移见契约第六节）：
//      win[167:0] = { off_y[31:0], off_x[31:0], scale[31:0],
//                     flags[3:0], mode[3:0], deco[3:0], slot[3:0], z[3:0],
//                     y1[12:0], x1[12:0], y0[12:0], x0[12:0] }
//    这样设计是为了以后再接参数双缓冲（ERAM 窗口表）时**不用改这个模块** ——
//    ERAM 里读出来的就是这种打包记录。
//
//  ★ z 序规则：**z 大的在上**；z 相同则**编号小的在上**（确定性，方便 tb 与复查）
//  ★ 本模块只做"选"，不做"取"：选出来的矩形/缩放/偏移由调用方接到 scaler_addr
// ============================================================
`timescale 1ns / 1ps

module win_zsel #(
    parameter integer WIN_NUM = 4        // 窗口数（契约 WIN_NUM）
)(
    // ---- 打包的窗口记录（WIN_NUM 条，低位在前）----
    input  wire [WIN_NUM*168-1:0] win_tbl,

    // ---- 当前屏幕像素 ----
    input  wire [11:0] pix_x,
    input  wire [11:0] pix_y,

    // ---- 选择结果 ----
    output wire        sel_valid,     // 有窗口命中（★ 不含 pix_de，由调用方与 de 相与）
    output wire [1:0]  sel,           // 命中的最上层窗口编号（sel_valid=0 时无意义）
    output wire [11:0] sel_x0,        // 选中窗口的矩形（屏幕坐标）
    output wire [11:0] sel_y0,
    output wire [11:0] sel_w,         // = x1 - x0
    output wire [11:0] sel_h,         // = y1 - y0
    output wire [3:0]  sel_slot,      // 选中窗口用哪个槽（→ 查描述符）
    output wire [31:0] sel_scale,     // 选中窗口的 scale（Q16.16）
    output wire signed [31:0] sel_off_u,   // 选中窗口的窗口内平移（Q16.16）
    output wire signed [31:0] sel_off_v,

    // ---- 诊断：哪些窗口命中（bit i = 第 i 个窗口命中）----
    output wire [WIN_NUM-1:0] hit_map
);

    // ---- 契约第六节的位偏移（本文件不 include artwork_def，改一处要改两处，
    //      tools\check_defs.py 会盯着）----
    localparam integer WF_X0     = 0;
    localparam integer WF_Y0     = 13;
    localparam integer WF_X1     = 26;
    localparam integer WF_Y1     = 39;
    localparam integer WF_Z      = 52;
    localparam integer WF_SLOT   = 56;
    localparam integer WF_FLAGS  = 68;
    localparam integer WF_SCALE  = 72;
    localparam integer WF_OFF_X  = 104;
    localparam integer WF_OFF_Y  = 136;
    localparam integer WF_TOTAL  = 168;

    // ============================================================
    //  ① 逐窗口命中 + ② 选最上面那个（组合，一拍内完成）
    // ============================================================
    reg [WIN_NUM-1:0] hit_r;
    reg [1:0]         sel_r;
    reg [3:0]         zbest;
    reg               any;
    integer           i;

    always @(*) begin
        any   = 1'b0;
        sel_r = 2'd0;
        zbest = 4'd0;
        for (i = 0; i < WIN_NUM; i = i + 1) begin
            hit_r[i] = win_tbl[i*WF_TOTAL + WF_FLAGS]                  // bit0 = valid
                    && (pix_x >= win_tbl[i*WF_TOTAL + WF_X0 +: 13])
                    && (pix_x <  win_tbl[i*WF_TOTAL + WF_X1 +: 13])
                    && (pix_y >= win_tbl[i*WF_TOTAL + WF_Y0 +: 13])
                    && (pix_y <  win_tbl[i*WF_TOTAL + WF_Y1 +: 13]);

            // 第一个命中的先选上；之后只有 z 更大才顶掉它
            // （所以 z 相同时编号小的赢，行为确定）
            if (hit_r[i] && ((!any) || (win_tbl[i*WF_TOTAL + WF_Z +: 4] > zbest))) begin
                any   = 1'b1;
                zbest = win_tbl[i*WF_TOTAL + WF_Z +: 4];
                sel_r = i[1:0];
            end
        end
    end

    // ============================================================
    //  ③ 把选中那条记录的字段切出来
    // ============================================================
    wire [12:0] x0_s = win_tbl[sel_r*WF_TOTAL + WF_X0 +: 13];
    wire [12:0] y0_s = win_tbl[sel_r*WF_TOTAL + WF_Y0 +: 13];
    wire [12:0] x1_s = win_tbl[sel_r*WF_TOTAL + WF_X1 +: 13];
    wire [12:0] y1_s = win_tbl[sel_r*WF_TOTAL + WF_Y1 +: 13];
    // ★ 先算成中间 wire 再取位：Verilog-2001 不允许对表达式直接做位选
    //   （写成 (x1_s-x0_s)[11:0] 在 ModelSim 也许过，TD 会报错）
    wire [12:0] w_s  = x1_s - x0_s;
    wire [12:0] h_s  = y1_s - y0_s;

    assign sel_valid = any;
    assign sel       = sel_r;
    assign hit_map   = hit_r;

    assign sel_x0    = x0_s[11:0];
    assign sel_y0    = y0_s[11:0];
    assign sel_w     = w_s[11:0];
    assign sel_h     = h_s[11:0];
    assign sel_slot  = win_tbl[sel_r*WF_TOTAL + WF_SLOT  +: 4];
    assign sel_scale = win_tbl[sel_r*WF_TOTAL + WF_SCALE +: 32];
    assign sel_off_u = win_tbl[sel_r*WF_TOTAL + WF_OFF_X +: 32];
    assign sel_off_v = win_tbl[sel_r*WF_TOTAL + WF_OFF_Y +: 32];

endmodule
