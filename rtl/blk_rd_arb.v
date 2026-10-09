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
    parameter integer RD_LEAD = 21'd1,     // 提前几拍把 read_req 举起来（留给跨域/状态机）
    // ★★★ 2026-10-06【服务态看门狗】：一块授权出去之后，只要申请方一直
    //   不取字（`x_next` 不给）或者 SDRAM 一直不回数据，状态机会**永远停在
    //   S_SERV** —— 那样读口就被这一块攥死，**显示也读不了 ⇒ 白屏**。
    //   所以：连续这么多拍没有任何一个字被取走，就放弃这一块、把读口放回去。
    //   8192 拍 @125MHz ≈ 65 µs，和 line_buf 自己的看门狗同量级。
    parameter integer SERV_MAX = 8192
    ,
    // ★★★ 2026-10-09【收尾兜底】：S_TAIL 的看门狗上限。
    //   原来是共用 SERV_MAX(8192 拍 = 65 µs)，可短块漏掉 read_finish 时会**真的等满**，
    //   把显示/音频的读口整整卡 65 µs（> 一行 26.4 µs）⇒ 掉行 + 音频饿死。
    //   现在收尾这条路的兜底 = 256 拍 ≈ **2 µs**（远小于一行，掉不了行）。
    parameter integer TAIL_MAX = 256
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
    // ★★★ 2026-10-09【短块收尾修正】：官方读控制器"读指令进行中"（= vendor_rd_path 的 o_rd_busy）
    //   为什么要它：S_TAIL 原来只等 `rd_fin`，而官方那条 `read_finish` **只亮一拍**。
    //   长块（显示一行 300~800 字）没问题，可**短块**（字幕 25 字 / 音频 64 字）
    //   很可能在申请方把字取完之前官方就已经报完 finish ⇒ 我们**漏掉那个脉冲** ⇒
    //   在 S_TAIL 里**死等到看门狗**（SERV_MAX = 8192 拍 = 65 µs）才把读口还回去。
    //   ★ 上板实测（2026-10-09）：显示读请求最大推迟 = 8192 拍，屏幕底部那块
    //     因为行缓冲被看门狗放弃而变成米白 + 黑横线，音频也被饿成一片沙沙声。
    //   ⇒ 现在就认"官方已经不忙了"就收尾（块的字早就取完了）。
    input  wire        rd_busy,

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
    output wire [2:0]  o_dv,               // ★ 2026-10-08：位宽 2 → 3（bit2 = 字幕）
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

    // ============================================================
    //  四、★ 2026-10-08【字幕申请人】—— 一次一行的 25 字短块
    //     · 一条字幕 1600 字 = 25 字/行 × 64 行（800×64 遮罩，1bpp）
    //     · 字幕**不是**每拍都在取：它是"下一条扫描线要用哪一行"，提前一条线取
    //       ⇒ 一帧 64 个短块 ≈ 64×(25+握手) ≈ 2200 拍，占一帧的 0.1%
    //     · 优先级排在**显示之后、音频之后**（谁都没有它也不急）
    // ============================================================
    input  wire        s_req,
    input  wire [20:0] s_base,
    input  wire [20:0] s_len,
    output reg         s_gnt,
    input  wire        s_next,
    output wire [31:0] s_data,
    output reg         s_done,             // 单拍

    // ---- 诊断 ----
    output reg  [15:0] o_blk_cnt,          // 服务过多少块（累计）
    output reg  [15:0] o_aud_blk_cnt,      // 其中多少块是音频
    output reg  [15:0] o_sub_blk_cnt,      // 其中多少块是字幕
    output reg         o_timeout           // 1 = 看门狗掐断过（sticky）
);

    // ============================================================
    //  ★ 声明全部前置
    // ============================================================
    localparam [2:0] S_IDLE  = 3'd0,       // 等申请
                     S_REQ   = 3'd1,       // 举 read_req 等 ack
                     S_SERV  = 3'd2,       // 授权中：申请方逐字取
                     S_TAIL  = 3'd3;       // 取够了，等 read_fin 收尾（保底）

    reg  [2:0]  st;
    // ★ 2026-10-08：owner 由 1 位扩成 2 位（第三个客户是字幕）
    localparam [1:0] OW_DISP = 2'd0,       // 显示（最高优先级）
                     OW_AUD  = 2'd1,       // 音频
                     OW_SUB  = 2'd2;       // 字幕
    reg  [1:0]  owner;
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
    reg  [1:0]  owner_d1, owner_d2;        // 跟着打两拍的所有者（dv 要和对齐）
    reg  [13:0] serv_cnt;                  // ★ 服务态看门狗计数（有字取走就清零）

    // ★ 当前主人的请求 / 是否还要字（三选一；用 case 写，避免 TD 的多驱动误报）
    reg         cur_req, cur_next;
    always @(*) begin
        case (owner)
        OW_AUD:  begin cur_req = a_req;  cur_next = a_next;  end
        OW_SUB:  begin cur_req = s_req;  cur_next = s_next;  end
        default: begin cur_req = d_req;  cur_next = d_next;  end
        endcase
    end
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
            owner     <= OW_DISP;
            rd_req    <= 1'b0;
            rd_base   <= 21'd0;
            rd_len    <= 21'd0;
            blk_base  <= 21'd0;
            blk_len   <= 21'd0;
            take_cnt  <= 21'd0;
            d_gnt     <= 1'b0;
            a_gnt     <= 1'b0;
            s_gnt     <= 1'b0;
            d_done    <= 1'b0;
            a_done    <= 1'b0;
            s_done    <= 1'b0;
            take_dv_r <= 1'b0;
            o_blk_cnt     <= 16'd0;
            o_aud_blk_cnt <= 16'd0;
            o_sub_blk_cnt <= 16'd0;
            o_timeout     <= 1'b0;
            serv_cnt      <= 14'd0;
        end
        else begin
            d_done <= 1'b0;
            a_done <= 1'b0;
            s_done <= 1'b0;
            take_dv_r <= take_ok;          // ★ 唯一赋值处
            // ---- 看门狗计数：这一拍取走一个字就清零，否则累加 ----
            if (take_ok)                       serv_cnt <= 14'd0;
            else if (serv_cnt != 14'h3FFF)     serv_cnt <= serv_cnt + 14'd1;

            case (st)
            // ---- 等申请：显示优先 ----
            S_IDLE: begin
                d_gnt <= 1'b0;
                a_gnt <= 1'b0;
                s_gnt <= 1'b0;
                rd_en <= 1'b0;
                if (d_req) begin
                    owner    <= OW_DISP;
                    blk_base <= d_base;
                    blk_len  <= d_len;
                    rd_base  <= d_base;
                    rd_len   <= d_len;
                    rd_req   <= 1'b1;
                    take_cnt <= 21'd0;
                    st       <= S_REQ;
                end
                // ★★★ 2026-10-09【优先级改序】：显示 > **字幕** > 音频。
                //   原来是 显示 > 音频 > 字幕，上板实测字幕被饿到"每帧只取到几行"
                //   （行缓冲老是旧的 ⇒ 屏幕底部变米白 + 几条黑横线）。
                //   字幕一次只借 25 个字、而且要"下一条扫描线之前"拿到，比音频（64 字、
                //   1.3 ms 才要一次）更急 ⇒ 让字幕排在音频前面。音频有 128 字缓冲(2.7 ms)
                //   扛得住偶尔往后排一次。
                else if (s_req) begin
                    owner    <= OW_SUB;
                    blk_base <= s_base;
                    blk_len  <= s_len;
                    rd_base  <= s_base;
                    rd_len   <= s_len;
                    rd_req   <= 1'b1;
                    take_cnt <= 21'd0;
                    st       <= S_REQ;
                end
                else if (a_req) begin
                    owner    <= OW_AUD;
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
                    if (owner == OW_AUD)      a_gnt <= 1'b1;
                    else if (owner == OW_SUB) s_gnt <= 1'b1;
                    else                      d_gnt <= 1'b1;
                    // ★★★ 看门狗计数**必须在这里清零**：它是"这一块已经被拿走多少拍
                    //   还没进一个字"的计数。空闲期间（行间 26 µs）它一直加到饱和，
                    //   不在这里清的话，一块刚授权就立刻超时 ⇒ 一个字都取不到
                    //   （仿真里：arb 在 S_REQ→S_SERV→S_IDLE 之间空转，dv 永远是 0）。
                    serv_cnt <= 14'd0;
                    st     <= S_SERV;
                    if (o_blk_cnt != 16'hFFFF)      o_blk_cnt     <= o_blk_cnt + 16'd1;
                    if ((owner == OW_AUD) && (o_aud_blk_cnt != 16'hFFFF))
                        o_aud_blk_cnt <= o_aud_blk_cnt + 16'd1;
                    if ((owner == OW_SUB) && (o_sub_blk_cnt != 16'hFFFF))
                        o_sub_blk_cnt <= o_sub_blk_cnt + 16'd1;
                end
            end

            // ---- 授权中：申请方逐字取；取满 blk_len 就收尾 ----
            S_SERV: begin
                rd_en <= take_ok;                       // 取一个字（数据下一拍回来）
                if (take_ok) take_cnt <= take_cnt + 21'd1;
                if (take_last) begin
                    // ★★★ 2026-10-06【必须在这里就撤授权】：
                    //   这一块的字**已经全部交付完了**，但官方的 read_finish 还要
                    //   等整串突发跑完（blk_len 通常不是 128 的整数倍），这中间
                    //   状态机停在 S_TAIL —— 如果 `a_gnt` 还举着，申请方**下一个**
                    //   块请求会看到这个【上一块的旧授权】，误以为自己的新请求
                    //   已经被受理（然后 FSM 去收集、申请方把 req 撤掉），
                    //   等 S_TAIL 结束撤掉授权时那个请求就**再也回不来**了。
                    //   仿真里这条一眼可见：第 1 块 64 字正确，第 2 块起
                    //   "受理 100 次、一个字都收不到"，两头看门狗轮流掐断。
                    if (owner == OW_AUD)      a_gnt <= 1'b0;
                    else if (owner == OW_SUB) s_gnt <= 1'b0;
                    else                      d_gnt <= 1'b0;
                    st <= S_TAIL;
                end
                // ★★★ 2026-10-06 看门狗：一直没人取字（申请方卡住 /
                //   SDRAM 一直不回）就把这一块放掉、读口还回去 ——
                //   **绝不让显示被音频（或任何申请方）堵死**。
                else if (serv_cnt >= SERV_MAX[13:0]) begin
                    o_timeout <= 1'b1;
                    if (owner == OW_AUD)      a_gnt <= 1'b0;
                    else if (owner == OW_SUB) s_gnt <= 1'b0;
                    else                      d_gnt <= 1'b0;
                    rd_req  <= 1'b0;
                    rd_en   <= 1'b0;
                    st      <= S_IDLE;
                end
            end

            // ---- 收尾：等 read_fin（官方那块确实读完了），再交回 IDLE ----
            //   ★★★ 2026-10-09：三条出口 —— ① `rd_fin` 来了（正常）
            //     ② **官方已经不忙了**（`!rd_busy`：短块最容易走这条 —— 字早就取完了，
            //        只是那个一拍宽的 finish 在我们进 S_TAIL 之前就过去了）
            //     ③ `TAIL_MAX` 兜底（远小于 SERV_MAX，绝不长期占着读口）
            //   ★ 早放口是**安全**的：官方模块在每次 read_req 被受理时会异步清读 FIFO，
            //     所以下一块开始时不会有上一块的残字串进来（见文件头那段）。
            S_TAIL: begin
                rd_en <= 1'b0;
                if (rd_fin || !rd_busy) begin
                    if (owner == OW_AUD)      begin a_gnt <= 1'b0; a_done <= 1'b1; end
                    else if (owner == OW_SUB) begin s_gnt <= 1'b0; s_done <= 1'b1; end
                    else                      begin d_gnt <= 1'b0; d_done <= 1'b1; end
                    st <= S_IDLE;
                end
                // ★ 收尾也兜一个底：官方的 read_finish 只亮一拍，万一它在我们
                //   进 S_TAIL 之前就过去了（FIFO 够深时是可能的），这里不能死等。
                //   ★ 2026-10-09：兜底值改成 TAIL_MAX（256 拍 = 2 µs），不再用 SERV_MAX(65 µs)
                else if (serv_cnt >= TAIL_MAX[13:0]) begin
                    o_timeout <= 1'b1;
                    if (owner == OW_AUD)      a_gnt <= 1'b0;
                    else if (owner == OW_SUB) s_gnt <= 1'b0;
                    else                      d_gnt <= 1'b0;
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
            owner_d1 <= OW_DISP;
            owner_d2 <= OW_DISP;
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
    assign s_data = rd_data;               // ★ 2026-10-08：字幕也是同一条出口

    // ★★★ 交付脉冲：一根 3 位线，bit0 = 显示、bit1 = 音频、bit2 = 字幕。
    //   用【打两拍】的 take_d2（= dout 真的有效那一拍），和组合引出的数据天然对齐。
    assign o_dv = take_d2 ? (3'b001 << owner_d2) : 3'b000;

endmodule
