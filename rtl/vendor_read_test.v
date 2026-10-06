// ============================================================
//  模块名 : vendor_read_test（测试件，不进交付仓库）
//  作用   : 用【官方 frame_read_write 的读侧】做一次读口自测，验证：
//             "照官方那套读法（声明式请求 + 它自己的突发状态机 + 读 FIFO），
//              这颗核在这版工程里能不能把数据读准？"
// ------------------------------------------------------------
//  为什么这么做（2026-09-27 下午）：
//    我们自己写的读驱动（连发/举 4 拍/按串发…）全都读出一模一样的坏花样
//    （每个字重复 4 次、整体偏 +3）。既然官方例程在这块板上是好的，
//    那就把官方那套读引擎原样搬进来，只用它的【读侧】：
//      · 写侧（App_wr_*）全部挂起 —— 我们的写口还是用自己的 sdr_arb
//        （因为它写死了 App_wr_dm = 4'b0000，做不了半字写）
//      · 读侧：read_req 举着 → 收到 read_req_ack → 它自己按 BURST_SIZE
//        一串一串读进读 FIFO；读完后我们从 FIFO 里一个一个取出来
//
//  ★ 它读的是"地址图"（地址图里：字的值 = 它的地址），所以期望值 = BASE + 序号。
//  ★ 读的长度 NWORD 故意取 ≤ 读 FIFO 深度(512)，这样"等它读完整帧"再把数据取出来
//    就够了，不用去踩 FIFO 的空满节奏。
// ============================================================
`timescale 1ns / 1ps

module vendor_read_test #(
    parameter integer BASE  = 21'h10400,   // 从哪个字开始读（第 208 行行首）
    parameter integer NWORD = 256          // 读多少个字（<= 512，读 FIFO 装得下）
)(
    input  wire        clk_mem,           // 125 MHz 存储域
    input  wire        clk_pix,           // 40 MHz 像素域（官方的 read_clk）
    input  wire        rst_pix_n,         // 低有效复位（外面对齐的那根）
    input  wire        go,                // 电平：开工（跑完自己记住）

    input  wire        sdr_init_done,
    input  wire        sdr_init_ref_vld,
    input  wire        sdr_busy,

    // ---- 存储侧读口：接到 sdr_arb 的 disp_rd_en / disp_rd_addr 与 rd_vld / rd_data ----
    output wire        App_rd_en,
    output wire [20:0] App_rd_addr,
    input  wire        Sdr_rd_en,
    input  wire [31:0] Sdr_rd_dout,

    // ---- 结果（跑完一直保持）----
    output reg  [15:0] o_got,             // 从读 FIFO 取出来多少个字（期望 NWORD）
    output reg  [15:0] o_bad,             // 其中多少个和期望地址对不上（0 = 逐字全对）
    output reg  [15:0] o_first,           // 第 1 个字的低 16 位
    output reg  [15:0] o_off,             // 第 1 个字偏几个
    output reg  [15:0] o_w0, o_w1, o_w2, o_w3,   // 头 4 个字（看重复花样）
    output reg         o_done,
    output wire        busy
);

    // ============================================================
    //  官方帧缓冲：只用读侧
    // ============================================================
    reg         rd_req;                   // 读请求：举着，直到 ack
    wire        rd_ack, rd_fin;
    wire [31:0] rd_data;
    reg         rd_en;                    // 从读 FIFO 取一个数据

    frame_read_write #(
        .FRAME_WIDTH(640), .FRAME_HEIGHT(480), .WRITE_V_FLIP(1)
    ) u_frw (
        .mem_clk          (clk_mem),
        .rst              (~rst_pix_n),          // ★ 官方模块的 rst 是高有效
        .Sdr_init_done    (sdr_init_done),
        .Sdr_init_ref_vld (sdr_init_ref_vld),
        .Sdr_busy         (sdr_busy),

        // 存储侧读口（直接引到外面接 sdr_arb）
        .App_rd_en        (App_rd_en),
        .App_rd_addr      (App_rd_addr),
        .Sdr_rd_en        (Sdr_rd_en),
        .Sdr_rd_dout      (Sdr_rd_dout),

        // 读侧（像素域）
        .read_clk         (clk_pix),
        .read_req         (rd_req),
        .read_req_ack     (rd_ack),
        .read_finish      (rd_fin),
        .read_addr_0      (BASE[20:0]),
        .read_addr_1      (21'd0),
        .read_addr_2      (21'd0),
        .read_addr_3      (21'd0),
        .read_addr_index  (2'd0),
        .read_len         (NWORD[20:0]),
        .read_en          (rd_en),
        .read_data        (rd_data),

        // ---- 写侧全部挂起：我们不通过它写（写口用我们自己的 sdr_arb）----
        .App_wr_en        (),
        .App_wr_addr      (),
        .App_wr_din       (),
        .App_wr_dm        (),
        .write_clk        (clk_pix),
        .write_req        (1'b0),
        .write_req_ack    (),
        .write_finish     (),
        .write_addr_0     (21'd0),
        .write_addr_1     (21'd0),
        .write_addr_2     (21'd0),
        .write_addr_3     (21'd0),
        .write_addr_index (2'd0),
        .write_len        (21'd0),
        .write_en         (1'b0),
        .write_data       (32'd0)
    );

    // ============================================================
    //  流程：发请求 → 等它读完 → 从 FIFO 把字取出来逐个比对
    // ============================================================
    localparam S_IDLE = 3'd0,   // 等 go
               S_REQ  = 3'd1,   // 举着 read_req
               S_FIN  = 3'd2,   // 等 read_finish（它读进 FIFO 了）
               S_POP  = 3'd3,   // 从 FIFO 取数据并比对
               S_DONE = 3'd4;   // 收工

    reg [2:0]  st;
    reg        rd_en_d;                 // read_en 打一拍：数据在它的下一拍有效
    reg [15:0] got;
    wire [20:0] exp_addr = BASE[20:0] + {5'd0, got};   // 第 got 个字期望的地址

    // ★★ read_finish 是【显存域 125MHz 的单拍脉冲】，40MHz 那边直接等必然错过。
    //    所以在显存域把它锁存成电平，像素域再轮询这个电平。
    reg        fin_sticky;
    always @(posedge clk_mem or negedge rst_pix_n) begin
        if (!rst_pix_n)  fin_sticky <= 1'b0;
        else if (rd_fin) fin_sticky <= 1'b1;
    end

    // 读完之后再等一小会（让最后几个字也进 FIFO），像素域计数
    reg [5:0] settle;

    assign busy = (st != S_IDLE) && (st != S_DONE);

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            st      <= S_IDLE;
            rd_req  <= 1'b0;
            rd_en   <= 1'b0;
            rd_en_d <= 1'b0;
            settle  <= 6'd0;
            got     <= 16'd0;
            o_got   <= 16'd0;
            o_bad   <= 16'd0;
            o_first <= 16'd0;
            o_off   <= 16'd0;
            o_w0    <= 16'd0;
            o_w1    <= 16'd0;
            o_w2    <= 16'd0;
            o_w3    <= 16'd0;
            o_done  <= 1'b0;
        end
        else begin
            rd_en_d <= rd_en;
            case (st)
            S_IDLE: begin
                if (go && !o_done) begin
                    got    <= 16'd0;
                    o_bad  <= 16'd0;
                    rd_req <= 1'b1;
                    st     <= S_REQ;
                end
            end

            S_REQ: begin
                if (rd_ack) begin          // 请求被受理 → 把请求撤下来
                    rd_req <= 1'b0;
                    st     <= S_FIN;
                end
            end

            S_FIN: begin
                // 等"它把这一批读完"的锁存电平；再多等 32 拍让最后几个字进 FIFO
                if (fin_sticky) begin
                    if (settle >= 6'd32) st <= S_POP;
                    else                 settle <= settle + 6'd1;
                end
            end

            S_POP: begin
                rd_en <= (got < NWORD[15:0]);
                if (rd_en_d) begin
                    // ---- 这一个就是第 got 个字 ----
                    if (got == 16'd0) begin
                        o_first <= rd_data[15:0];
                        o_off   <= rd_data[15:0] - BASE[15:0];
                    end
                    if (got == 16'd0) o_w0 <= rd_data[15:0];
                    if (got == 16'd1) o_w1 <= rd_data[15:0];
                    if (got == 16'd2) o_w2 <= rd_data[15:0];
                    if (got == 16'd3) o_w3 <= rd_data[15:0];

                    if (rd_data[15:0] != exp_addr[15:0]) begin
                        if (o_bad != 16'hFFFF) o_bad <= o_bad + 16'd1;
                    end

                    got <= got + 16'd1;
                    if (got == NWORD[15:0] - 16'd1) begin
                        o_got  <= got + 16'd1;
                        o_done <= 1'b1;
                        st     <= S_DONE;
                    end
                end
            end

            S_DONE: begin
                rd_en <= 1'b0;
                st    <= S_DONE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
