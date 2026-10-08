// ============================================================
//  vendor_rd_path —— 【官方读通路】封装：frame_fifo_read + 读 FIFO
//
//  为什么不直接用 frame_read_write（见《重构_读通路_施工说明.md》§1b）：
//    frame_read_write 把"读控制器 + 读 FIFO"封在一起，**而且把 FIFO 的占用计数
//    `wrusedw` 留在模块内部**。用它的人看不到"FIFO 里现在有几个字"，只能
//    "等 read_finish（整块进 FIFO）再取" ⇒ 一块必须 ≤512 字，而 1536 宽的一行
//    是 771 字 ⇒ 要拆两块、各等一轮 ⇒ 一行 26.4 µs 很可能来不及。
//    ⇒ 自己例化这两件，**把 wrusedw 引出来**，就能"有字就读、没字就等"：
//      取数速度只受 SDRAM 供应速度限制，**不用拆块、也不用等整块**。
//
//  时钟：★ clkw / clkr / mem_clk 都用 clk_mem（125 MHz，同域）——
//        这样 line_buf 的取数逻辑不用搬家，跨域那套坑全绕开。
//        （FIFO 本身支持异域；同域只是"不跨"，行为不变。）
//
//  时序约定（照原厂 / vendor_read_test.v）：
//    · read_req 举着 → read_req_ack 拉高（受理）
//    · 之后用 read_re 一个脉冲取一个字，**数据在下一拍出现在 rd_dout**
//      （FIFO 是非 show-ahead + NOREG；rd_valid 也一并引出来备用）
//    · read_finish 表示"这一块确实都读进 FIFO 了"（收尾/看门狗用）
//
//  ★★ 两个从原厂代码里抄下来、不能改的细节：
//    ① frame_fifo_read 的 `wrusedw` 端口是【10 位】，而 rfifo 输出的是【9 位】
//       ⇒ 必须显式 {1'b0, ...} 补最高位（原厂 frame_read_write 里就是这么补的）。
//    ② 读 FIFO 的 rst 由控制器的 fifo_aclr 驱动（每次受理请求会清一次）
//       ⇒ 块与块之间不会串字，这是"块级独占"安全的前提。
//
//  ★★★ 声明全部前置（这个工程踩过五次"先用后声明"）
// ============================================================
`timescale 1ns / 1ps

module vendor_rd_path #(
    parameter integer ADDR_BITS   = 21,
    parameter integer BURST_BITS  = 9,
    parameter integer FIFO_DEPTH  = 512,
    parameter integer BURST_SIZE  = 128
)(
    input  wire        clk_mem,             // 125 MHz（mem_clk / clkw / clkr 都用它）
    input  wire        rst_mem_n,           // 低有效；内部转成官方模块要的高有效

    input  wire        sdr_init_done,
    input  wire        sdr_init_ref_vld,
    input  wire        sdr_busy,
    // ★★★ 2026-10-08【最小实验：把原厂的读写仲裁接上】（见 规划\B轨待改清单.md §22）
    //   写引擎的忙标志（frame_fifo_write 的 O_wr_busy = 突发中 / 马上要突发）。
    //   官方读控制器本来就有这个输入：`S_CHECK_FIFO` 里
    //   `wrusedw < FIFO_DEPTH-BURST_SIZE && ~App_wr_busy` —— **写侧在突发时，读不发起突发**。
    //   我们以前喂 1'b0（"读写不重叠靠顶层装载期间禁读保证"），等于关掉了原厂仲裁。
    input  wire        wr_busy,

    // ============================================================
    //  一、SDRAM 读口（独占）
    // ============================================================
    output wire        App_rd_en,
    output wire [20:0] App_rd_addr,
    input  wire        Sdr_rd_en,           // 读数据有效
    input  wire [31:0] Sdr_rd_dout,

    // ============================================================
    //  二、块请求（只用 read_addr_0，index 固定 0）
    // ============================================================
    input  wire        rd_req,              // 举着直到 ack
    output wire        rd_ack,
    output wire        rd_fin,              // 一块读完（进 FIFO 了）
    input  wire [20:0] rd_base,
    input  wire [20:0] rd_len,

    // ============================================================
    //  三、取数：有字就读
    // ============================================================
    input  wire        rd_re,               // 一个脉冲取一个字
    output wire [31:0] rd_dout,             // rd_re 的【下一拍】有效
    output wire        rd_valid,            // 官方 FIFO 的 valid（备用）
    output wire [9:0]  rd_used,             // ★ FIFO 里现在有几个字（0 = 空的）
    output wire        rd_used_nz,          // = |rd_used，给"有字就读"用
    output wire        o_rd_busy,           // 官方报"读指令期间"（以后接写侧互锁用）
    // ★★★ 2026-10-06 诊断探针（sticky 计数，饱和在 0xFFFF）：
    //   ① `o_rd_en_cnt` = 官方控制器一共发过多少次 `App_rd_en`
    //      0 = 它一次读都没发（那问题在它的"FIFO 空间够不够"判断上）
    //   ② `o_fifo_seen` = 读 FIFO 曾经非空过吗（1 = 数据确实回来过）
    output reg  [15:0] o_rd_en_cnt,
    output reg         o_fifo_seen
);

    // ---- 内部线 ----
    wire        fifo_aclr;                  // 控制器 → FIFO 的异步清零
    wire [8:0]  fifo_used_w;                // 写侧计数（wrusedw）：喂给控制器看空间
    wire [8:0]  fifo_used_r;                // ★ 读侧计数（rdusedw）：告诉我们"能取几个字"

    // ============================================================
    //  官方读控制器
    // ============================================================
    frame_fifo_read #(
        .MEM_DATA_BITS (32),
        .ADDR_BITS     (ADDR_BITS),
        .BURST_BITS    (BURST_BITS),
        .FIFO_DEPTH    (FIFO_DEPTH),
        .BURST_SIZE    (BURST_SIZE)
    ) u_rd_ctrl (
        .rst              (~rst_mem_n),         // 官方是高有效
        .mem_clk          (clk_mem),
        .Sdr_init_done    (sdr_init_done),
        .Sdr_init_ref_vld (sdr_init_ref_vld),
        .Sdr_busy         (sdr_busy),
        .Sdr_rd_en        (Sdr_rd_en),
        // ★★★ 2026-10-08：原来是 1'b0（= "写侧永远不忙"）。现在接写引擎的 O_wr_busy
        //   ⇒ 恢复原厂的**突发级互锁**：写突发期间，读控制器不发起读突发（在 S_CHECK_FIFO 等）。
        //   两边 FIFO（写 512 / 读 512）负责把对方的突发时间填平。
        .App_wr_busy      (wr_busy),
        .O_rd_busy        (o_rd_busy),
        .App_rd_en        (App_rd_en),
        .App_rd_addr      (App_rd_addr),
        .read_req         (rd_req),
        .read_req_ack     (rd_ack),
        .read_finish      (rd_fin),
        .read_addr_0      (rd_base),
        .read_addr_1      (21'd0),
        .read_addr_2      (21'd0),
        .read_addr_3      (21'd0),
        .read_addr_index  (2'd0),
        .read_len         (rd_len),
        .fifo_aclr        (fifo_aclr),
        .wrusedw          ({1'b0, fifo_used_w}) // ★ 9 位 → 10 位，显式补 0
    );

    // ============================================================
    //  读 FIFO（原厂 IP，定义在 lib\sdram\afifo_32_16_256.v 里）
    //    clkw/clkr 都接 clk_mem（同域）；rst 由控制器的 fifo_aclr 驱动
    // ============================================================
    rfifo_32_32_512 u_rd_fifo (
        .rst         (fifo_aclr),
        .clkw        (clk_mem),
        .clkr        (clk_mem),
        .we          (Sdr_rd_en),
        .di          (Sdr_rd_dout),
        .re          (rd_re),
        .dout        (rd_dout),
        .valid       (rd_valid),
        .full_flag   (),
        .empty_flag  (),
        .afull       (),
        .aempty      (),
        .wrusedw     (fifo_used_w),
        .rdusedw     (fifo_used_r)
    );

    // ★★★ 2026-10-06【必须用读侧计数】：这个 FIFO 的 clkw 和 clkr 虽然都接
    //   clk_mem，但内部指针仍然走格雷码同步器（2~3 拍）。`wrusedw` 是
    //   "写指针 − 同步过来的读指针" —— 写侧**本地**指针，字一写进去它立刻加 1；
    //   而读侧的 `empty_flag` / `rdusedw` 要等写指针同步过来才算数。
    //   ⇒ 用 wrusedw 当"有字了"会让仲裁器**早 3~4 拍**就去 read_en：
    //     那几拍 FIFO 还认为自己空着（rd_en_s = !empty & re 被挡掉），
    //     于是 pop 丢空、dout 还是旧值 —— 交付出去的就是**错位的旧字**。
    //     仿真里这条一眼可见：请求 base=1000/len=8，交付出来是
    //       [0,0,0,0,1000,1001,1002,1003]
    //     （前四个是没更新过的 dout），屏上就是"整条读通路全错"。
    //   ⇒ 一律用读侧口径：rdusedw 和 empty_flag 是同源的，绝不会早。
    assign rd_used    = {1'b0, fifo_used_r};
    assign rd_used_nz = |fifo_used_r;

    // ---- 探针 ①② ----
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            o_rd_en_cnt <= 16'd0;
            o_fifo_seen <= 1'b0;
        end
        else begin
            if (App_rd_en && (o_rd_en_cnt != 16'hFFFF)) o_rd_en_cnt <= o_rd_en_cnt + 16'd1;
            if (rd_used_nz)                             o_fifo_seen <= 1'b1;
        end
    end

endmodule
