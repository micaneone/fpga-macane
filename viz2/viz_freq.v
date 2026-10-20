//==========================================================================
//  viz_freq —— 频域：24 段【一阶低通梯级滤波组】频谱
//              ★★ v3（2026-10-18）：改成【时分复用】省资源
//==========================================================================
//
//  ── 它是什么 ──
//  N 级一阶低通串成"梯级"，相邻两级之差就是那一段的频带能量：
//
//        x ──►LP(α1)──►LP(α2)──►LP(α3)── … ──►LP(αN)
//              y1        y2        y3              yN
//        band_k = |y[k-1] − y[k]|
//
//  一阶低通 y += α·(x−y)，转折频率 f_c ≈ fs·α/(2π)，fs=48kHz ⇒ f_c ≈ 7640·α Hz
//  α = 2^-a + 2^-b + 2^-c   ⇒  纯移位，零乘法零除法零 DSP
//
//  ── ★★★ v3 为什么要时分复用 ──
//  v2 是【24 级并行】：24 套 20 位 减法+3 次移位加+加法+绝对值+比较 同时存在。
//  Vivado 综合实测 **3068 LUT / 1537 FF**，换算成安路约 1050 MSlice ——
//  而这块板子当时已经 100.9% MSlice，频谱直接没资源装，**上板出不来**。
//
//  v3 改成【一个共享运算单元，每个采样扫 N 拍】：
//    · 采样率 48 kHz，clk_aud 12.288 MHz ⇒ **每个采样有 256 拍**，扫 24 拍绰绰有余
//    · 每拍只做一级： d = prev_y - y[k] → y[k] += α_k·d → 更新 pk[k-1]
//    · `prev_y` 把"上一级的【新】值"带过来 ⇒ 只需要 1 个变址读 mux（不是 2 个）
//    · 顺带：这就是"直接型级联"，比 v2 的延迟一拍的写法更贴近理论
//  ⇒ 预测 ~400 LUT / ~1050 FF（省 ~2600 LUT）
//
//  ── 对数刻度（沿用 v2）──
//  本滤波组从 400Hz 到 4kHz 输出涨约 36dB，线性刻度装不下（低频顶死高频全 0）。
//  用【找最高位 + 取下面 3 位小数】近似 log2，约 1.9 dB 一级，
//  **整个模块只用一个转换器**（在 dump 的那 N 拍里逐段算）。
//
//  ── 握手（2026-10-16 修正：aud_vld 是【电平】不是单拍脉冲）──
//      aud_vld   电平 —— 手里有字就一直是 1
//      aud_dout  当前那个字，只在 aud_next 之后一拍才换
//      aud_next  单拍 —— 消费端取走那一拍（12.288MHz÷512 = 24kHz 字率）
//  ⇒ 真正"来了一个新字" = aud_vld & aud_next。全部【只读】，绝不驱动。
//
//  ── 参数 ──
//    N        频段数（= 梯级数），默认 24
//    SMP_WIN  每帧统计多少个采样（48k 下 2048 = 42.7ms ≈ 23fps）
//    LOG_BIAS 整体抬高的"级数"（1 级 ≈ 1.9dB）。柱子整体太矮就调大
//
//  ★ 输出接口和 viz_time 完全一样，直接接另一个 viz_render
//  ★★★ 声明全部前置
//==========================================================================
module viz_freq #(
    parameter integer N        = 24,
    parameter integer SMP_WIN  = 2048,
    parameter integer LOG_BIAS = 16
)(
    input  wire        clk_aud,
    input  wire        rst_aud_n,

    // ---- 音频采样流（从 aud_blk_rd 来，★ 只读）----
    input  wire        aud_vld,       // ★ 电平：手里有字就一直是 1
    input  wire [31:0] aud_dout,
    input  wire        aud_next,      // ★ 单拍：消费端取走那一拍

    // ---- 输出给 viz_render 的 wr_* ----
    output reg         wr_en,
    output reg  [4:0]  wr_addr,
    output reg  [5:0]  wr_val,

    // ---- 诊断 ----
    output wire [15:0] dbg_win,       // 本帧已统计的采样数
    output wire        dbg_dump,      // 1 = 正在逐段输出
    output wire [5:0]  dbg_hi         // 第 1 段（最高频）的本帧峰值
);

    //======================================================================
    //  ★ 声明全部前置
    //======================================================================
    localparam [4:0]  N_1    = N - 1;
    localparam [4:0]  N_V    = N;
    localparam [15:0] WIN_M1 = SMP_WIN - 1;

    // ---- 梯级状态 / 本帧各段峰值 ----
    //   ★ y[0] 不用（扫描第一级时 prev_y 直接吃输入采样），但**必须留着这个槽**：
    //     空闲时 sk=0，组合逻辑仍会去读 y[sk]，不给 y[0] 就是越界读
    reg signed [19:0] y  [0:N];
    reg        [19:0] pk [0:N-1];

    // ---- 采样入队（一个"字"= 2 个采样）----
    reg  [1:0]  pend;
    reg  [15:0] pd0, pd1;
    reg  [15:0] xs;                // 本次扫描要处理的采样
    reg         sweep_go;          // 起扫请求（把 xs 打进 prev_y）

    // ---- 扫描体 ----
    reg         sact;              // 正在扫
    reg  [4:0]  sk;                // 当前扫到第几级 1..N
    reg  signed [19:0] prev_y;     // 上一级的【新】值（第一级时 = 输入）

    // ---- 帧计数 ----
    reg  [15:0] win_cnt;
    reg         win_pend;

    // ---- 逐段输出 ----
    reg         dump_req, dump_act;
    reg  [4:0]  dump_k;

    // ---- 运算（组合）----
    wire signed [19:0] y_cur;
    reg  [3:0]  s1, s2, s3;
    reg  signed [19:0] dlt;
    wire signed [19:0] inc;
    wire signed [19:0] y_new;
    wire [19:0] mag;

    // ---- 对数转换（只有一个，dump 时逐段复用）----
    reg  [19:0] lg_x;
    reg  [22:0] lg_s;
    reg  [4:0]  lg_m;
    reg  [2:0]  lg_f;
    reg  signed [7:0] lg_h;
    integer     lg_i;

    integer i;

    wire wr_stb = aud_vld & aud_next;   // ★ 真正的"来一个新字"事件
    wire idle   = ~sact & ~sweep_go;    // 扫描间空档

    assign dbg_win  = win_cnt;
    assign dbg_dump = dump_act;
    assign dbg_hi   = pk[0];

    //======================================================================
    //  ★ 移位表：α = 2^-s1 + 2^-s2 + 2^-s3
    //     注释放的是 f_c = 7640×α，即"这一段的上边界"
    //======================================================================
    always @(*) begin
        case (sk)
            1 : begin s1 = 4'd1;  s2 = 4'd2;  s3 = 4'd3;  end // α=0.8750  ~6685 Hz
            2 : begin s1 = 4'd1;  s2 = 4'd3;  s3 = 4'd4;  end // α=0.6875  ~5252 Hz
            3 : begin s1 = 4'd1;  s2 = 4'd6;  s3 = 4'd7;  end // α=0.5234  ~3999 Hz
            4 : begin s1 = 4'd2;  s2 = 4'd3;  s3 = 4'd5;  end // α=0.4063  ~3104 Hz
            5 : begin s1 = 4'd2;  s2 = 4'd5;  s3 = 4'd5;  end // α=0.3125  ~2388 Hz
            6 : begin s1 = 4'd3;  s2 = 4'd4;  s3 = 4'd4;  end // α=0.2500  ~1910 Hz
            7 : begin s1 = 4'd3;  s2 = 4'd5;  s3 = 4'd5;  end // α=0.1875  ~1433 Hz
            8 : begin s1 = 4'd3;  s2 = 4'd7;  s3 = 4'd7;  end // α=0.1406  ~1074 Hz
            9 : begin s1 = 4'd4;  s2 = 4'd5;  s3 = 4'd6;  end // α=0.1094   ~836 Hz
            10: begin s1 = 4'd4;  s2 = 4'd6;  s3 = 4'd7;  end // α=0.0859   ~656 Hz
            11: begin s1 = 4'd5;  s2 = 4'd6;  s3 = 4'd6;  end // α=0.0625   ~478 Hz
            12: begin s1 = 4'd5;  s2 = 4'd6;  s3 = 4'd8;  end // α=0.0508   ~388 Hz
            13: begin s1 = 4'd5;  s2 = 4'd8;  s3 = 4'd8;  end // α=0.0391   ~298 Hz
            14: begin s1 = 4'd6;  s2 = 4'd7;  s3 = 4'd8;  end // α=0.0273   ~209 Hz
            15: begin s1 = 4'd6;  s2 = 4'd8;  s3 = 4'd8;  end // α=0.0234   ~179 Hz
            16: begin s1 = 4'd6;  s2 = 4'd10; s3 = 4'd10; end // α=0.0176   ~134 Hz
            17: begin s1 = 4'd7;  s2 = 4'd8;  s3 = 4'd9;  end // α=0.0137   ~104 Hz
            18: begin s1 = 4'd7;  s2 = 4'd9;  s3 = 4'd11; end // α=0.0103    ~78 Hz
            19: begin s1 = 4'd8;  s2 = 4'd9;  s3 = 4'd9;  end // α=0.0078    ~60 Hz
            20: begin s1 = 4'd8;  s2 = 4'd9;  s3 = 4'd12; end // α=0.0061    ~47 Hz
            21: begin s1 = 4'd8;  s2 = 4'd11; s3 = 4'd12; end // α=0.0046    ~35 Hz
            22: begin s1 = 4'd9;  s2 = 4'd10; s3 = 4'd11; end // α=0.0034    ~26 Hz
            23: begin s1 = 4'd9;  s2 = 4'd11; s3 = 4'd12; end // α=0.0027    ~21 Hz
            default: begin s1 = 4'd10; s2 = 4'd11; s3 = 4'd12; end // 第 24 级 α=0.0017 ~13 Hz
        endcase
    end

    //======================================================================
    //  运算：每拍做一级
    //======================================================================
    assign y_cur = y[sk];
    always @(*) dlt = prev_y - y_cur;                       // 这一段的原始差
    assign inc   = (dlt >>> s1) + (dlt >>> s2) + (dlt >>> s3);
    assign y_new = y_cur + inc;
    assign mag   = dlt[19] ? (~dlt + 20'd1) : dlt[19:0];    // |dlt|

    //======================================================================
    //  ① 梯级状态 y[]：每拍更新一级（★ 本数组只在这个 always 里被写）
    //======================================================================
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) begin
            for (i = 0; i <= N; i = i + 1) y[i] <= 20'sd0;
        end
        else if (sact)
            y[sk] <= y_new;
    end

    //======================================================================
    //  ② 峰值 pk[]：扫描时更新、dump 时逐段清掉（★ 只在这个 always 里被写）
    //======================================================================
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) begin
            for (i = 0; i < N; i = i + 1) pk[i] <= 20'd0;
        end
        else if (dump_act)
            pk[dump_k] <= 20'd0;                 // dump 读完就清（优先级最高）
        else if (sact && (sk != 5'd0) && (mag > pk[sk-1]))
            pk[sk-1] <= mag;
    end

    //======================================================================
    //  ③ 扫描控制 + 采样入队 + 帧计数 + 逐段输出
    //======================================================================
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) begin
            pend     <= 2'd0;
            pd0      <= 16'd0;
            pd1      <= 16'd0;
            xs       <= 16'd0;
            sweep_go <= 1'b0;
            sact     <= 1'b0;
            sk       <= 5'd0;
            prev_y   <= 20'sd0;
            win_cnt  <= 16'd0;
            win_pend <= 1'b0;
            dump_req <= 1'b0;
            dump_act <= 1'b0;
            dump_k   <= 5'd0;
            wr_en    <= 1'b0;
            wr_addr  <= 5'd0;
            wr_val   <= 6'd0;
        end
        else begin
            wr_en    <= 1'b0;
            sweep_go <= 1'b0;

            // ---------- ① 采样入队（每来一个"新字"收 2 个采样）----------
            //   ★ 这里【只入队、不递减】。递减只在下面 ③ 真正消费掉一个采样时做。
            //     （第一版在这里也无条件递减，结果第二个采样还没轮到就已被减到 0
            //       ⇒ 每个字只处理 1 个采样，写次数正好是正确值的一半）
            if ((pend == 2'd0) && wr_stb) begin
                pd0  <= aud_dout[15:0];
                pd1  <= aud_dout[31:16];
                pend <= 2'b11;
            end

            // ---------- ② 扫描体 ----------
            if (sweep_go) begin
                // 起扫：把输入打进 prev_y，sk 从 1 开始
                sact   <= 1'b1;
                sk     <= 5'd1;
                prev_y <= {{4{xs[15]}}, xs};
            end
            else if (sact) begin
                prev_y <= y_new;                     // 下一级的输入
                if (sk == N_V) sact <= 1'b0;
                else           sk   <= sk + 5'd1;
            end

            // ---------- ③ 有采样待处理就起扫（dump 期间先压住）----------
            if ((pend != 2'd0) && idle && !dump_act && !dump_req) begin
                xs       <= pend[1] ? pd1 : pd0;
                sweep_go <= 1'b1;
                pend     <= {1'b0, pend[1]};
            end

            // ---------- ④ 帧计数（每个采样一次）----------
            if (sweep_go) begin
                if (win_cnt >= WIN_M1) begin
                    win_cnt  <= 16'd0;
                    win_pend <= 1'b1;
                end
                else
                    win_cnt <= win_cnt + 16'd1;
            end

            // ---------- ⑤ 帧末：等扫描空下来 → 起 dump ----------
            if (win_pend && idle) begin
                win_pend <= 1'b0;
                dump_req <= 1'b1;
            end

            // ---------- ⑥ 逐段输出（低频在左）----------
            if (dump_act) begin
                wr_en   <= 1'b1;
                wr_addr <= N_1 - dump_k;   // 第 1 段(最高频) → 最右
                wr_val  <= lg_h[5:0];      // ★ 送出去的是对数级
                dump_k  <= dump_k + 5'd1;
                if (dump_k == N_1)
                    dump_act <= 1'b0;
            end
            else if (dump_req) begin
                dump_req <= 1'b0;
                dump_act <= 1'b1;
                dump_k   <= 5'd0;
            end
        end
    end

    //======================================================================
    //  ★ 对数转换：20 位幅度 → 6 位"级"（约 1.9 dB 一级）
    //     级 = 3×最高位序号 + 最高位下面第 2..0 位   （0 表示静音）
    //======================================================================
    always @(*) begin
        lg_x = pk[dump_k];
        lg_s = lg_x << 3;                      // 先左移 3 位，下面按 m+1 取就能
                                               // 正好落在这 3 个小数位上
        lg_m = 5'd0;
        for (lg_i = 0; lg_i < 20; lg_i = lg_i + 1)
            if (lg_x[lg_i]) lg_m = lg_i[4:0];  // 最后一个为真的 = 最高位

        lg_f = lg_s[lg_m + 5'd1 +: 3];         // 最高位下面那 3 位，∈ 4..7

        lg_h = lg_m * 3 + lg_f - 7'd4 + LOG_BIAS;
        if (lg_x == 20'd0) lg_h = 8'sd0;       // 静音 → 0
        else if (lg_h < 8'sd0) lg_h = 8'sd0;
        else if (lg_h > 8'sd63) lg_h = 8'sd63;
    end

endmodule
