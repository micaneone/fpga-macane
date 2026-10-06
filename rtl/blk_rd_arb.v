// ============================================================
//  blk_rd_arb —— 【块级】读口仲裁（显示 / 音频 / 以后字幕都走这里）
//
//  为什么要有它（2026-10-06 的结论）：
//    原厂 frame_read_write 的仲裁是"读 vs 写、按块"，它**不管两个读家**。
//    我们以前是"逐拍"把显示和音频绞在一个读口上 —— 这颗 SDRAM 核受不了这种
//    交织：偶发读不到/读错 ⇒ 显示丢字（白条闪）+ 音频收到图像数据（电流声）。
//    ⇒ 所以"显示 vs 音频（+ 字幕）"这一层必须自己写，而且必须是**块级**：
//      **谁拿到读口，谁整块读完；块与块之间不交叠。**
//      好处：数据只可能属于"当前这一块" ⇒ **不需要 tag 队列** ⇒ 那一类脱钩 bug 消失。
//
//  和官方模块怎么接：
//    · 本模块驱动官方读侧的 read_req / read_addr_0 / read_len，
//      收它的 read_req_ack / read_finish，并用 read_en / read_data 逐字取走；
//    · ★ 官方模块的 read_clk 接到 clk_mem（不是像素域）—— 这样两边同域，
//      line_buf 的取数逻辑不用搬家，跨域那套坑全绕开；
//    · ★ 官方模块在每次 read_req 受理时会异步清读 FIFO（read_fifo_aclr），
//      所以"一块取完再换下一块"是安全的 —— 不会有上一块的残字串到下一块。
//
//  申请方（显示 / 音频）的接口约定（两边一样）：
//    1) 拉高 x_req，并保持 x_base / x_len 不变（一次一个块）；
//    2) 等 x_gnt 拉高（表示这个块已经在读了，可以从 FIFO 取字）；
//    3) 每要一个字就给 x_next 一个脉冲；**数据在下一拍出现在 x_data**（和官方时序一致）；
//    4) 取满 x_len 个字后把 x_req 拉低（或者由仲裁器数够 x_len 自动收尾）。
//    ★ 仲裁器会数数，绝不会让一个申请方多取（多取就会吃到下一块的字）。
//
//  优先级：**显示优先**。音频只在显示没有块请求时（行间空档 / 垂直消隐）才拿到读口。
//         音频一次要短（48~64 字，≤0.5 µs），插在空档里绰绰有余。
//
//  ★★★ 声明全部前置（这个工程踩过五次"先用后声明"）
// ============================================================
`timescale 1ns / 1ps

module blk_rd_arb #(
    parameter integer RD_LEAD = 21'd1      // 提前几拍把 read_req 举起来（留给跨域/状态机）
)(
    input  wire        clk_mem,
    input  wire        rst_mem_n,

    // ============================================================
    //  一、官方 frame_read_write 的读侧
    // ============================================================
    output reg         rd_req,             // 举着直到 ack
    input  wire        rd_ack,
    input  wire        rd_fin,             // 一块读完了（同域，直接可用）
    output reg  [20:0] rd_base,            // → read_addr_0
    output reg  [20:0] rd_len,             // → read_len
    output reg         rd_en,              // 从读 FIFO 取一个字
    input  wire [31:0] rd_data,            // rd_en 的【下一拍】有效
    // ★★★ 2026-10-06：来自 vendor_rd_path 的"FIFO 里现在有几个字"。
    //   有它才敢"边填边取"：**没字就不发 read_en**（否则取到空 FIFO 是脏数据）。
    //   也因此不用"等整块读完"，1536 宽的一行 771 字一块就够。
    input  wire        rd_used_nz,         // FIFO 非空

    // ============================================================
    //  二、显示申请人（一行一个块）
    // ============================================================
    input  wire        d_req,
    input  wire [20:0] d_base,
    input  wire [20:0] d_len,
    output reg         d_gnt,
    input  wire        d_next,             // 电平：显示"还要字"
    output wire [31:0] d_data,
    // ★★ 交付脉冲【合并成一个 2 位端口】：bit0 = 显示交付、bit1 = 音频交付。
    //    为什么不用两根 1 位线：TD 对"同一个 net 被两个分支驱动"很敏感
    //    （连 `assign x = sel ? a : b;` 这种都报过多驱动），合并成一根就从根上没有二选一。
    output wire [1:0]  o_dv,
    output reg         d_done,             // 单拍：这个块取完了

    // ============================================================
    //  三、音频申请人（消隐期一次短块）
    // ============================================================
    input  wire        a_req,
    input  wire [20:0] a_base,
    input  wire [20:0] a_len,
    output reg         a_gnt,
    input  wire        a_next,
    output wire [31:0] a_data,
    output reg         a_done,             // 单拍

    // ---- 诊断 ----
    output reg  [15:0] o_blk_cnt,          // 服务过多少块（累计）
    output reg  [15:0] o_aud_blk_cnt       // 其中多少块是音频
);

    // ============================================================
    //  ★ 声明全部前置
    // ============================================================
    localparam [2:0] S_IDLE  = 3'd0,       // 等申请
                     S_REQ   = 3'd1,       // 举 read_req 等 ack
                     S_SERV  = 3'd2,       // 授权中：申请方逐字取
                     S_TAIL  = 3'd3;       // 取够了，等 read_fin 收尾（保底）

    reg  [2:0]  st;
    reg         owner;                     // 0 = 显示，1 = 音频
    reg  [20:0] blk_base, blk_len;
    reg  [20:0] take_cnt;                  // 这个块已经被取走多少个字
    // ★ 交付脉冲的"源"：只在主状态机里赋值一次，端口再用连续赋值分给两家
    //   （TD 对"同一个 reg 在两个分支/两个 always 里赋值"很敏感，这样写最保险）
    reg         take_dv_r;
    // ★★★ 2026-10-06【关键修正·第二版】：官方读 FIFO 是
    //     "read_en 之后【下一拍】dout 才有效"（非 show-ahead + NOREG）。
    //   而我们这边的 read_en 本身也是寄存器（`rd_en <= take_ok`），所以：
    //        take_ok (T)  →  rd_en (T+1)  →  rd_data/dout 有效 (T+2)
    //   ⇒ **交付脉冲必须打两拍**才和 dout 对齐（第一版只打一拍，
    //     交付的是"上一次 pop 的旧 dout"，实测交付出来是
    //     [旧值 x4, 1000, 1001, 1002, 1003]，请求是 1000..1007 ⇒ 整条读通路全错）。
    //   数据本身【组合】引出去（`d_data = rd_data`），
    //   由 `o_dv` 的脉冲（= take_ok 打两拍）告诉申请方"这一拍有效"。
    reg         take_d1, take_d2;
    reg         owner_d1, owner_d2;        // 跟着打两拍的所有者（dv 要和对齐）

    wire        cur_req  = owner ? a_req  : d_req;
    wire        cur_next = owner ? a_next : d_next;
    // ★ 取数条件：① 在服务中 ② 申请方这一拍要字 ③ 还没取够 ④ **FIFO 里确实有字**
    wire        take_ok  = (st == S_SERV) && cur_next && (take_cnt < blk_len) && rd_used_nz;
    wire        take_last = take_ok && (take_cnt + 21'd1 >= blk_len);

    // ============================================================
    //  一、主状态机
    //    ★ 优先级：显示优先 —— 只有在没有显示块请求时才接音频。
    // ============================================================
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            st        <= S_IDLE;
            owner     <= 1'b0;
            rd_req    <= 1'b0;
            rd_base   <= 21'd0;
            rd_len    <= 21'd0;
            blk_base  <= 21'd0;
            blk_len   <= 21'd0;
            take_cnt  <= 21'd0;
            d_gnt     <= 1'b0;
            a_gnt     <= 1'b0;
            d_done    <= 1'b0;
            a_done    <= 1'b0;
            take_dv_r <= 1'b0;
            o_blk_cnt     <= 16'd0;
            o_aud_blk_cnt <= 16'd0;
        end
        else begin
            d_done <= 1'b0;
            a_done <= 1'b0;
            take_dv_r <= take_ok;          // ★ 唯一赋值处

            case (st)
            // ---- 等申请：显示优先 ----
            S_IDLE: begin
                d_gnt <= 1'b0;
                a_gnt <= 1'b0;
                rd_en <= 1'b0;
                if (d_req) begin
                    owner    <= 1'b0;
                    blk_base <= d_base;
                    blk_len  <= d_len;
                    rd_base  <= d_base;
                    rd_len   <= d_len;
                    rd_req   <= 1'b1;
                    take_cnt <= 21'd0;
                    st       <= S_REQ;
                end
                else if (a_req) begin
                    owner    <= 1'b1;
                    blk_base <= a_base;
                    blk_len  <= a_len;
                    rd_base  <= a_base;
                    rd_len   <= a_len;
                    rd_req   <= 1'b1;
                    take_cnt <= 21'd0;
                    st       <= S_REQ;
                end
            end

            // ---- 等官方模块受理 ----
            S_REQ: begin
                if (rd_ack) begin
                    rd_req <= 1'b0;
                    if (owner) a_gnt <= 1'b1;
                    else       d_gnt <= 1'b1;
                    st     <= S_SERV;
                    if (o_blk_cnt != 16'hFFFF)      o_blk_cnt     <= o_blk_cnt + 16'd1;
                    if (owner && o_aud_blk_cnt != 16'hFFFF) o_aud_blk_cnt <= o_aud_blk_cnt + 16'd1;
                end
            end

            // ---- 授权中：申请方逐字取；取满 blk_len 就收尾 ----
            S_SERV: begin
                rd_en <= take_ok;                       // 取一个字（数据下一拍回来）
                if (take_ok) take_cnt <= take_cnt + 21'd1;
                if (take_last) begin
                    st <= S_TAIL;
                end
            end

            // ---- 收尾：等 read_fin（官方那块确实读完了），再交回 IDLE ----
            S_TAIL: begin
                rd_en <= 1'b0;
                if (rd_fin) begin
                    if (owner) begin a_gnt <= 1'b0; a_done <= 1'b1; end
                    else       begin d_gnt <= 1'b0; d_done <= 1'b1; end
                    st <= S_IDLE;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

    // ============================================================
    //  二、数据分流
    //    ★ 官方 FIFO 只有一路出口（read_en / read_data）。
    //      因为"一次只有一个块在服务"，所以**谁在服务，数据就归谁** ——
    //      这里不需要任何 tag 队列，这是本设计的关键好处。
    // ============================================================
    // 打两拍的"取数完成"：rd_en 是寄存器，dout 又是 rd_en 的下一拍 ⇒ 共两拍
    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            take_d1  <= 1'b0;
            take_d2  <= 1'b0;
            owner_d1 <= 1'b0;
            owner_d2 <= 1'b0;
        end
        else begin
            take_d1  <= take_ok;             // 第 1 拍：rd_en 发出
            take_d2  <= take_d1;             // 第 2 拍：rd_data 到位
            owner_d1 <= owner;
            owner_d2 <= owner_d1;
        end
    end

    // 数据总线【组合】引出去：申请方看到自己的 dv 脉冲时，这一拍的数据就是它的
    // （和官方 `read_data` 的用法完全一致 —— 不需要再寄存一次）
    assign d_data = rd_data;
    assign a_data = rd_data;

    // ★★★ 交付脉冲：一根 2 位线，bit0 = 显示、bit1 = 音频。
    //   用【打两拍】的 take_d2（= dout 真的有效那一拍），和组合引出的数据天然对齐。
    assign o_dv = take_d2 ? (owner_d2 ? 2'b10 : 2'b01) : 2'b00;

endmodule
