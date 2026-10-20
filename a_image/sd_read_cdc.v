// ============================================================
//  sd_read_cdc —— 【把整个 sd_read 搬到 100 MHz】的跨时钟外壳
//  ★ 集成临时改动（见 规划\A轨待改清单.md 第十一条）2026-10-08
//
//  ── 为什么是"搬 sd_read 整体"，而不是只搬 my_spi ──
//  第一版做的是"只把移位器（my_spi）搬到 100 MHz、FSM 留在 50 MHz"。
//  **仿真当场否掉了它**（`tb_spi_cdc_bridge` 抓到 MOSI 头两位是旧字节）：
//    25 MHz 下一个字节 8 位 = 320 ns，而"这一字节的最后一位"到"下一字节的第一位"
//    只隔 **1 个位时间 = 40 ns**；跨时钟往返（fast→50MHz→fast）实测 **80 ns**
//    ⇒ 下一个字节的 `data_in` 根本来不及换上去（头两位还是上一个字节的值）。
//  ⇒ 结论：**字节源（read_tx_data / send_cnt）必须和移位器在同一个域**，
//    所以把整个 `sd_read`（含 my_spi）搬到 100 MHz：它内部一行都不用改，
//    "上一次 send_done → 换下一个字节" 仍然是 1 拍（10 ns ≪ 40 ns）✓。
//
//  ── 这个模块干什么 ──
//  对外（50 MHz 侧）**端口和 sd_read 逐位相同** ⇒ `sd_top` 里只换模块名；
//  对内：真 sd_read 跑在 clk_fast（100 MHz）上，两边按项目契约那条铁律握手
//        （**数据先稳定 + 翻 toggle**，见 `artwork_def.v` 第三节）：
//
//        50 MHz 侧（find_bmp）            100 MHz 侧（真 sd_read）
//          read_req（电平）──────2FF──────► read_req
//          read_addr[31:0]（整段稳定）──2FF──► read_addr
//          init_done （电平）──────2FF──────► init_done
//          read_busy ◄─────────2FF─────────  read_busy（电平）
//          read_ok   ◄─检边─ 2FF ◄─toggle──  read_ok（**每字节一拍**）+ data_out
//          read_done ◄─检边─ 2FF ◄─toggle──  read_done（整块一拍）
//          read_err  ◄─检边─ 2FF ◄─toggle──  read_err （整块一拍）
//
//  ★ 为什么"每字节的 data_out"可以直接过两拍同步器：
//    它在 fast 域里一个字上要稳 **320 ns**（= 8 位 × 40 ns），
//    而目的域只有在"检到 toggle 边沿"那一拍才去锁存它，
//    那时数据至少已经稳了 2~3 拍 50 MHz（40~60 ns）⇒ 安全。
//
//  ★ 附带好处：`sd_read` 里那些计数（块间空闲 IDLE_MAX=255）在 100 MHz 下
//    变成一半时间（5.1 µs → 2.55 µs），每块之间的空档也小了。
//    （`TIME_OUT` 也一起减半：40 ms → 20 ms。它只在"边读边写"那一档才用得上，
//     而那一档默认关着；20 ms 仍大于一帧 16.6 ms。）
//
//  ★ 声明全部前置（这个工程踩过五次"先用后声明"）
// ============================================================
`timescale 1ns / 1ps

module sd_read_cdc #(
    parameter [21:0] TIME_OUT = 22'd2_000_000,   // 透传给真 sd_read（100 MHz 拍）
    parameter [15:0] IDLE_MAX = 16'd255,
    parameter        sck_div  = 0                // 4 相拍：SCLK = clk_fast/4
)(
    // ---------------- 50 MHz 侧：**端口与 sd_read 逐位相同** ----------------
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input  wire        init_done,
    input  wire        read_req,
    input  wire [31:0] read_addr,
    output reg         read_busy,
    output reg         read_ok,
    output reg         read_done,
    output reg         read_err,
    output reg  [7:0]  data_out,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_clk,
    output wire        spi_cs,

    // ★★★ 2026-10-17【CMD18 多块读】1 = 允许连续读多块（透传到真 sd_read）
    //   ★ 这是**慢变电平**（一条链"正在读像素数据"期间恒 1）⇒ 两拍同步就够。
    input  wire        stream_en,

    // ---------------- ★ 快速域时钟（100 MHz ⇒ SCLK = 25 MHz）----------------
    input  wire        clk_fast
);

    // ============================================================
    //  ★ 声明全部前置
    // ============================================================
    reg  [1:0]  rstf;                       // 快速域复位（异步置位、同步释放）
    wire        rst_fast_n;

    // ---- 50 → fast ----
    reg         rq_f1, rq_f2;               // read_req 电平
    reg         id_f1, id_f2;               // init_done 电平
    reg  [31:0] ad_f1, ad_f2;               // read_addr（整段稳定）
    reg         st_f1, st_f2;               // ★ stream_en（慢变电平）

    // ---- fast → 50 ----
    reg         byte_tgl;                   // 每收到一个字节翻一次
    reg         done_tgl, err_tgl;          // 整块结束 / 出错 各翻一次
    reg         bs_f1, bs_f2;               // read_busy 电平
    reg         bt1, bt2, dt1, dt2, et1, et2;
    wire        byte_edge, done_edge, err_edge;

    // ---- 真 sd_read 的输出（快速域）----
    wire        f_busy, f_ok, f_done, f_err;
    wire [7:0]  f_data;

    assign rst_fast_n = rstf[1];
    assign byte_edge  = bt1 ^ bt2;
    assign done_edge  = dt1 ^ dt2;
    assign err_edge   = et1 ^ et2;

    // ============================================================
    //  一、快速域复位：异步置位、同步释放
    // ============================================================
    always @(posedge clk_fast or negedge sys_rst_n) begin
        if (!sys_rst_n) rstf <= 2'b00;
        else            rstf <= {rstf[0], 1'b1};
    end

    // ============================================================
    //  二、50 MHz → 100 MHz（都是电平 / 稳定数据，两拍同步即可）
    // ============================================================
    always @(posedge clk_fast or negedge rst_fast_n) begin
        if (!rst_fast_n) begin
            rq_f1 <= 1'b0; rq_f2 <= 1'b0;
            id_f1 <= 1'b0; id_f2 <= 1'b0;
            st_f1 <= 1'b0; st_f2 <= 1'b0;      // ★ 默认**不**流式：和原版逐位相同
        end
        else begin
            rq_f1 <= read_req;  rq_f2 <= rq_f1;
            id_f1 <= init_done; id_f2 <= id_f1;
            st_f1 <= stream_en; st_f2 <= st_f1;
        end
    end
    always @(posedge clk_fast or negedge rst_fast_n) begin
        if (!rst_fast_n) begin ad_f1 <= 32'd0; ad_f2 <= 32'd0; end
        else             begin ad_f1 <= read_addr; ad_f2 <= ad_f1; end
    end

    // ============================================================
    //  三、本体：真 sd_read（**一个字没改**），时钟换成 100 MHz
    // ============================================================
    sd_read #(
        .TIME_OUT (TIME_OUT),
        .IDLE_MAX (IDLE_MAX),
        .sck_div  (sck_div)
    ) u_sd_read (
        .sys_clk   (clk_fast),
        .sys_rst_n (rst_fast_n),
        .init_done (id_f2),
        .read_req  (rq_f2),
        .read_addr (ad_f2),
        .read_busy (f_busy),
        .read_ok   (f_ok),
        .read_done (f_done),
        .read_err  (f_err),
        .data_out  (f_data),
        .spi_mosi  (spi_mosi),
        .spi_miso  (spi_miso),
        .spi_clk   (spi_clk),
        .spi_cs    (spi_cs),
        .stream_en (st_f2)                 // ★ 流式开关（同步后）
    );

    // ============================================================
    //  四、100 MHz → 50 MHz
    //     每字节的 read_ok / 整块的 done / err 在 fast 域只有 1 拍（10 ns），
    //     50 MHz 侧抓不到 ⇒ 一律翻 toggle 过去、在 50 MHz 侧检边还原成单拍脉冲。
    // ============================================================
    always @(posedge clk_fast or negedge rst_fast_n) begin
        if (!rst_fast_n) begin
            byte_tgl <= 1'b0; done_tgl <= 1'b0; err_tgl <= 1'b0;
        end
        else begin
            if (f_ok)   byte_tgl <= ~byte_tgl;      // 每字节一次（含命令/响应/数据）
            if (f_done) done_tgl <= ~done_tgl;
            if (f_err)  err_tgl  <= ~err_tgl;
        end
    end

    // read_busy 是电平：两拍同步
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin bs_f1 <= 1'b0; bs_f2 <= 1'b0; end
        else            begin bs_f1 <= f_busy; bs_f2 <= bs_f1; end
    end

    // 三个 toggle：两拍同步 + 检边
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            bt1 <= 1'b0; bt2 <= 1'b0;
            dt1 <= 1'b0; dt2 <= 1'b0;
            et1 <= 1'b0; et2 <= 1'b0;
        end
        else begin
            bt1 <= byte_tgl; bt2 <= bt1;
            dt1 <= done_tgl; dt2 <= dt1;
            et1 <= err_tgl;  et2 <= et1;
        end
    end

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            read_busy <= 1'b0;
            read_ok   <= 1'b0;
            read_done <= 1'b0;
            read_err  <= 1'b0;
            data_out  <= 8'h00;
        end
        else begin
            read_busy <= bs_f2;
            read_ok   <= byte_edge;                 // 语义和 sd_read 一样：每字节单拍
            read_done <= done_edge;
            read_err  <= err_edge;
            // ★ 检到"收到一个字节"那一拍锁存：fast 域里这个字节已稳 ≥2 拍 50MHz
            if (byte_edge) data_out <= f_data;
        end
    end

endmodule
