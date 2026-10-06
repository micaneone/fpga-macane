// ============================================================
//  模块名 : desc_rx
//  作用   : 源图描述符的【接收侧】—— A 写、B 读的那条片内参数口
//  层次   : 显示链最底层（B 轨）；合成器每帧从这里取"现在能取哪些图"
//  时钟域 : 两个 —— A 侧（写）在【控制域 50 MHz】，B 侧（读）在【像素域 40 MHz】
//  依据   : B轨说明书 §4.3 / §4.4；位段定义见 common\artwork_def.v 第五节
// ------------------------------------------------------------
//  为什么要有它（而不是让 A 把描述符写进 SDRAM）：
//    描述符是一小组"谁装好了、装的是哪张"的状态参数，不是数据。
//    按 §4.4 的分工原则（"SDRAM 是仓库，片内是信箱"），它属于信箱。
//    好处：B 每帧都要用它却不占 SDRAM 带宽；只跨一次时钟域（50 -> 40）；
//          而且复位后片内被清 -> valid=0 -> 屏上是桌面底色，很安全。
//
//  ★ 工作流程（和窗口表同一套机制，§4.4）：
//
//      A 侧 50 MHz                           B 侧 40 MHz
//      ┌────────────────────┐                ┌──────────────────────────┐
//      │ 改【后备】那份的字段  │                │ 每帧只读【前台】那份        │
//      │ 写完翻 a_commit_tgl │──── toggle ───►│ 同步进来、置 pending      │
//      │ 等到 ack 才敢再改    │◄─── toggle ────│ 到 frame_start 那一拍：    │
//      └────────────────────┘                │ 把 a_desc 整份采下来       │
//                                            │ 翻 ack_tgl、清 pending    │
//                                            └──────────────────────────┘
//
//  ★ 给 A 的用法（三步）：
//    1) 把 7 个字段拼成 64 位（位段见 artwork_def.v 第五节）驱动到 a_desc
//    2) 翻一次 a_commit_tgl；★ 从翻之前到收到 ack 之前，a_desc 必须一动不动
//    3) 等 a_ack_tgl 翻转 —— 说明 B 已经把这份表采下发在用了，这时才能改 a_desc
//    ★ 一次提交等一个 ack，不要连翻两次（连翻只会生效最后一份、也只有一个 ack）
//
//  ★ 多久生效：提交后最慢 2 帧（约 33 ms）屏上才用新表；这期间旧表照用，
//    所以 A 装新图的过程对屏上是平滑的（不会闪）。
//
//  ★ 复位后所有槽 valid = 0：屏上显示桌面底色，不会去读没装好的槽。
// ============================================================
`timescale 1ns / 1ps

module desc_rx #(
    parameter integer SLOT_NUM = 2        // 槽位数（= 契约的 SDR_SLOT_NUM，
                                          //  现在 = 2 个大槽：焦点·前台/后台；
                                          //  ★ 小槽定下来之后，契约里加了几个槽，
                                          //    这里的默认值要跟着改，check_defs 会报）
)(
    // ---------------- A 侧：控制域 50 MHz ----------------
    input  wire        clk_ctl,
    input  wire        rst_ctl_n,
    input  wire [SLOT_NUM*64-1:0] a_desc,       // 每槽 64 位，低 57 位有效
    input  wire        a_commit_tgl,            // 翻一次 = 提交一份新表
    output reg         a_ack_tgl,               // 翻一次 = 新表已生效

    // ---------------- B 侧：像素域 40 MHz ----------------
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        frame_start,             // 每帧一次脉冲（B 自己产生）

    // 当前【前台】那一份（合成器直接用，不用再查表）
    output reg  [SLOT_NUM-1:0]    o_valid,
    output reg  [SLOT_NUM*21-1:0] o_base,
    output reg  [SLOT_NUM*12-1:0] o_src_w,
    output reg  [SLOT_NUM*12-1:0] o_src_h,
    output reg  [SLOT_NUM*2-1:0]  o_format,
    output reg  [SLOT_NUM-1:0]    o_transposed,
    output reg  [SLOT_NUM*8-1:0]  o_img_no,

    // 诊断
    output reg  [15:0] o_version,               // 每生效一次 +1
    output wire        o_pending                // 1 = 有提交还没生效
);

    // ------------------------------------------------------------
    //  位偏移（与 common\artwork_def.v 第五节一致）
    //  一个槽的 64 位包装：低 57 位有效，高 7 位补零
    //    [56:49] img_no   [48:37] src_h   [36:25] src_w
    //    [24:4]  base     [3:2]   format  [1] transposed  [0] valid
    //
    //  ★ 本文件不 `include artwork_def.v（不依赖工具的 include 搜索路径）。
    //    两边不一致时 tools\check_defs.py 会报错 —— 改一处务必改另一处。
    // ------------------------------------------------------------
    localparam integer D_VALID  = 0;
    localparam integer D_TRANSP = 1;
    localparam integer D_FORMAT = 2;
    localparam integer D_BASE   = 4;
    localparam integer D_SRC_W  = 25;
    localparam integer D_SRC_H  = 37;
    localparam integer D_IMG_NO = 49;

    // ============================================================
    //  B 侧 40 MHz：收提交、帧边界整表采
    // ============================================================
    reg [2:0] cs;                        // a_commit_tgl 的三级同步
    wire      commit_edge = cs[1] ^ cs[2];
    reg       pending;
    reg       ack_tgl_p;                 // 像素域内部的回执 toggle

    assign o_pending = pending;

    integer i;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            cs           <= 3'd0;
            pending      <= 1'b0;
            ack_tgl_p    <= 1'b0;
            o_valid      <= {SLOT_NUM{1'b0}};    // 复位后：所有槽"没货"
            o_base       <= 0;
            o_src_w      <= 0;
            o_src_h      <= 0;
            o_format     <= 0;
            o_transposed <= 0;
            o_img_no     <= 0;
            o_version    <= 16'd0;
        end
        else begin
            // ---- ① 收 A 的提交 ----
            cs <= {cs[1:0], a_commit_tgl};
            if (commit_edge) pending <= 1'b1;

            // ---- ② 帧边界：有新表就【整份】采下来 ----
            //   一定要等 frame_start：7 个字段是一组，
            //   边写边采会出现"宽度是新的、基址还是旧的"，屏上会跳一下。
            if (frame_start && pending) begin
                for (i = 0; i < SLOT_NUM; i = i + 1) begin
                    o_valid[i]            <= a_desc[i*64 + D_VALID];
                    o_transposed[i]       <= a_desc[i*64 + D_TRANSP];
                    o_format  [i*2  +: 2] <= a_desc[i*64 + D_FORMAT +: 2];
                    o_base    [i*21 +: 21]<= a_desc[i*64 + D_BASE   +: 21];
                    o_src_w   [i*12 +: 12]<= a_desc[i*64 + D_SRC_W  +: 12];
                    o_src_h   [i*12 +: 12]<= a_desc[i*64 + D_SRC_H  +: 12];
                    o_img_no  [i*8  +: 8] <= a_desc[i*64 + D_IMG_NO +: 8];
                end
                o_version <= o_version + 16'd1;
                pending   <= 1'b0;
                ack_tgl_p <= ~ack_tgl_p;     // 回执
            end
        end
    end

    // ============================================================
    //  回执回送到控制域：在 50 MHz 侧生成一根干净的 toggle
    //  （这样 A 和它同域，直接读就行，不必自己打同步器）
    // ============================================================
    reg  ak1, ak2, ak3;
    wire ack_edge = ak2 ^ ak3;

    always @(posedge clk_ctl or negedge rst_ctl_n) begin
        if (!rst_ctl_n) begin
            ak1 <= 1'b0; ak2 <= 1'b0; ak3 <= 1'b0;
            a_ack_tgl <= 1'b0;
        end
        else begin
            ak1 <= ack_tgl_p; ak2 <= ak1; ak3 <= ak2;
            if (ack_edge) a_ack_tgl <= ~a_ack_tgl;
        end
    end

endmodule
