// ============================================================
//  sfx_player —— 音效音源生成（A 轨）：数据流 → HDMI 音频接口
//
//  把【已经取好的】PCM 流（48 kHz / 16 bit / 单声道）变成
//  HDMI 核要的【并行采样 + valid】，含音量 + 淡入淡出 + 静音兜底。
//
//  ★★ 为什么不是 I2S
//     HDMI 核（hdmi_1_4b_transmitter_core）【不吃 I2S】，它吃的是：
//         I_audio_valid / I_audio_left_data[23:0] / I_audio_right_data[23:0]
//     I2S 是"芯片间"的接口标准，我们的音频本来就在同一颗芯片里，
//     不需要先串行出去再解回来 ⇒ 直接出并行采样，链路更短。
//     （HDMI 协议规定的音频格式是【线上】的数据岛/音频采样包，
//       和芯片内部用什么接口无关。）
//
//  ★★ 三个时钟域
//      clk_aud  12.288 MHz  音频域 —— 数据流、音量、淡入淡出都在这
//      clk_pix  （像素时钟）  ★ HDMI 核和 ACR 都在这个域采样，所以
//                                出给它们的采样/valid 必须跨过来
//      clk_ctl  50 MHz       控制域 —— 只管同步 volume
//
//  ★★ 跨域怎么做
//      48 kHz 采样在 clk_aud 域产生 → 数据摆稳后翻一个 toggle
//      → 像素域两级同步检边沿 → 锁存数据 + 打一拍 o_audio_valid
//      ★ 安全：采样间隔 20.8 µs，像素域 2 拍才 50 ns，相距 400 倍，不可能漏
//
//  ★ 数据从哪来：不归本模块管
//      由 `sdr_rd_arb` 从 SDRAM 读好，经 aud_dout/aud_vld 喂进来
//      （本模块用 aud_next 取走一个字 = 两个采样）
//
//  ★ 静音兜底（必做）：没数据时也【持续】每 48 kHz 推一个 0 采样
//       —— HDMI 音频包要在每个消隐期插入，断流会让核异常
//
//  ★ 淡入淡出：音量斜坡自动跟随 —— 有数据朝满值爬、没数据朝 0 降
//       ★ 所以【不需要 play 命令】：数据来了自然淡入，数据完了自然淡出
//
//  ★ 音量：移位相加，不占乘法器
//
//  ★★ 两个已经踩过的坑（别改回去）
//      ① 半字顺序：wav2sdram 把【偶数序号】采样放在 [31:16]
//         （见 wav2sdram.v:109 `sdr_data <= {smp_lo, smp_data}`）
//         ⇒ 必须先取高半字。顺序反了 = 每两个采样交换 → 轻微高频杂音 ✗
//      ② 静音兜底不能省：没数据时也要照推 0 采样，一帧都不断
//
//  ★★★ 声明全部前置（这个工程踩过五次"先用后声明"了）
// ============================================================
`timescale 1ns / 1ps

module sfx_player #(
    parameter integer FADE_MAX = 8'd255     // 淡入淡出斜坡满值（255 → 约 5.3 ms）
)(
    // ---------------- 音频域 12.288 MHz ----------------
    input  wire        clk_aud,
    input  wire        rst_aud_n,

    // ---------------- 像素域（给 HDMI 核和 ACR）----------------
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    output reg         o_audio_valid,       // 单拍：这一拍有一个采样
    output reg  [23:0] o_audio_left,        // 左声道（16 位采样左对齐到 24 位）
    output reg  [23:0] o_audio_right,       // 右声道（单声道 → 和左一样）

    // ---------------- 控制域 50 MHz（只用来同步 volume）----------------
    input  wire        clk_ctl,
    input  wire        rst_ctl_n,
    input  wire  [7:0] volume,              // 音量（慢变设置；跨域两级同步）

    // ---------------- 数据流（从 sdr_rd_arb 的 FIFO 来）----------------
    input  wire [31:0] aud_dout,            // 一个字 = 两个采样，[31:16] 靠前
    input  wire        aud_vld,             // 1 = aud_dout 有数据
    output wire        aud_next,            // 单拍：取走一个字

    output wire        busy                 // 1 = 还在放
);

    // ============================================================
    //  ★ 所有声明前置
    // ============================================================
    // ---- 音频域 ----
    reg  [7:0]  bcnt;                   // 0..255，数到 0 就是一个采样节拍
    reg  [15:0] samp;                   // 本次要发的 16 位采样（音量前的原值）
    reg         cur_hi;                 // 0 = 该取高半字，1 = 该取低半字
    reg  [31:0] buf0, buf1;             // 从数据流收的两级缓冲
    reg         v0, v1;
    reg  [7:0]  fade;                   // 淡入淡出斜坡 0..FADE_MAX
    reg  [7:0]  vol_s1, vol_s2;         // volume 跨域两级同步
    reg  [23:0] smp24;                  // 本次要发的 24 位采样（左对齐）
    reg         smp_tgl;                // 每出一个采样翻一次（跨域用）

    // ---- 像素域 ----
    reg         t1, t2, t3;             // smp_tgl 三级同步
    reg         new_smp;                // 检到新采样

    // ---- 线 ----
    wire        samp_tick;
    wire        take;
    wire [3:0]  vol4, fad4, gain4;
    wire [7:0]  gmul;
    wire [15:0] out16;
    wire signed [15:0] sv, q1, q2, q3, q4, vout;

    // ============================================================
    //  一、从数据流收字（两级缓冲）
    // ============================================================
    //  ★★★ 2026-10-05 集成修正（B 轨做上板集成时改的，见《A轨待改清单》§音频链）：
    //    原来"收字"（本段）和"取半个字"（下面第五节）写在**两个 always 块**里，
    //    两边都会改 buf0 / buf1 / v0 / v1 —— TD 综合当场报错：
    //        HDL-8007 ERROR: net 'buf0[31]' is constantly driven from multiple places
    //    并把 `sfx_player` 整个降级成黑盒 ⇒ **音频链根本综合不出来**
    //    （ModelSim 不报这个错，所以 A 轨的仿真全是绿的，是"上板才发现"的坑）。
    //    ⇒ 合并成一个 always，并且**先消费、再收字**：
    //       收字用"消费【之后】"的空位判断，两件事撞在同一拍也不会把采样顺序搞反
    //       （原来那版撞拍时会把两个采样交换 → 轻微高频杂音）。
    //      不撞拍时 room0|room1 与原来的 ~v0|~v1 完全等价，行为不变。
    // ============================================================
    wire cons_word = samp_tick & cur_hi;         // 这一拍取完低半字 = 这个字用完
    wire v0_next   = cons_word ? v1 : v0;        // 消费【之后】buf0 还有没有数据
    wire v1_next   = cons_word ? 1'b0 : v1;      // 消费【之后】buf1 还有没有数据
    wire room0     = ~v0_next;                   // 消费之后 buf0 空着
    wire room1     = ~v1_next;                   // 消费之后 buf1 空着
    wire fill_en   = aud_vld & (room0 | room1);  // 有空位就收

    assign take     = fill_en;
    assign aud_next = take;

    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) begin
            buf0 <= 32'd0; buf1 <= 32'd0;
            v0 <= 1'b0;    v1 <= 1'b0;
            cur_hi <= 1'b0;
            samp   <= 16'd0;
        end
        else begin
            // ---------- ① 先取半个字（消费）----------
            if (samp_tick) begin
                if (cur_hi) begin
                    // 取后一个采样（奇数序号，在【低】半字）→ 这个字用完
                    samp   <= buf0[15:0];
                    cur_hi <= 1'b0;
                    if (v1) begin buf0 <= buf1; v1 <= 1'b0; end
                    else         v0   <= 1'b0;
                end
                else if (v0) begin
                    // 先取前一个采样（偶数序号，在【高】半字）
                    samp   <= buf0[31:16];
                    cur_hi <= 1'b1;
                end
                else begin
                    // ★★★ 2026-10-14 晚【治"偶发一声爆破音"—— 在消费端治，不动读通路】
                    //
                    //  症状（上板实测）：偶发一声爆、响完立刻恢复正常；几次播放中一次。
                    //  机理：读口仲裁延迟偶尔超过 FIFO 余量 ⇒ 掉一个字（= 2 个采样）。
                    //        原来这里**硬灌 0** ⇒ 波形上剁出一个台阶 ⇒ 听得见的"爆"。
                    //
                    //  改法：**保持上一个采样**（不赋值），让波形连续。
                    //    · 只晚 41.7 µs（一个字）才继续 ⇒ 人耳完全不可闻；
                    //    · 不会出现直流：下面的 `fade` 在没数据时每拍 −1，5.3 ms 内衰减到 0
                    //      （`gain4` 随之归零），所以"没声音"这件事仍然成立；
                    //    · 仍然是**每个 samp_tick 都推一个采样** ⇒ 没有违反"绝不断流"那条
                    //      （那条要求的是"不停推采样、HDMI 音频包不断"，不是"必须推 0"）。
                    //  ★ cur_hi 仍然归零：保证下一个字进来时还是从**高半字**（偶数序号采样）起，
                    //    半字相位不会被这次断供带偏（否则会变成"每两个采样交换 → 高频杂音"）。
                    //
                    // ★★★ 2026-10-14 深夜【再修一次：开头那声噪点也是它带出来的】
                    //   上板实测：播放开头偶发（约五次一次）一声"啵"；而串口证明
                    //   **每次放完的校验和完全一样**（数据逐次可复现，探针 0、看门狗 False）
                    //   ⇒ 不是数据，是播放瞬态。
                    //   病根：新一轮播放开始时 FIFO 是空的，第一块取数有一段空档；上面那条
                    //   "保持上一个采样"会把**上一轮播放的最后一个采样**拉出来，配上正在爬升的
                    //   fade 增益 ⇒ 就是那声"啵"（空档短听不到、空档长听得到 ⇒ 概率性、与数据无关）。
                    //   ⇒ 只在**正在播**（fade != 0）时才保持；否则回 0（静音）。
                    //     中途短空档照旧保持（那时 fade != 0），播放开头的空档变成静音。
                    if (fade == 8'd0) samp <= 16'd0;
                    cur_hi <= 1'b0;
                end
            end

            // ---------- ② 再收新字（写在后面 ⇒ 它的赋值优先）----------
            if (fill_en) begin
                if (room0) begin buf0 <= aud_dout; v0 <= 1'b1; end
                else       begin buf1 <= aud_dout; v1 <= 1'b1; end
            end
        end
    end

    // ============================================================
    //  二、采样节拍：每 256 个 clk_aud 出一个采样 = 48 kHz
    // ============================================================
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) bcnt <= 8'd0;
        else            bcnt <= bcnt + 8'd1;
    end
    assign samp_tick = (bcnt == 8'd0);

    // ============================================================
    //  三、淡入淡出斜坡：有数据往上爬，没数据往下掉
    // ============================================================
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) fade <= 8'd0;
        else if (samp_tick) begin
            if (v0) begin
                if (fade != FADE_MAX) fade <= fade + 8'd1;
            end
            else if (fade != 8'd0)
                fade <= fade - 8'd1;
        end
    end

    // ============================================================
    //  四、音量（控制域 → 音频域，两级同步）
    // ============================================================
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) begin vol_s1 <= 8'd0; vol_s2 <= 8'd0; end
        else            begin vol_s1 <= volume; vol_s2 <= vol_s1; end
    end

    // ============================================================
    //  五、每个采样节拍取半个字
    //      ★ 先取【高】半字（偶数序号那个采样），见文件头坑①
    //  ★★★ 2026-10-05：这一段已经**合并到上面第一节那个 always 块**里了 ——
    //    两段原来各写各的，同时驱动 buf0/buf1/v0/v1，TD 报多驱动错误。
    //    （逻辑一个字没改，只是搬进去 + 把收字放到后面用"消费之后的空位"。）
    // ============================================================

    // ============================================================
    //  六、音量：gain4 = volume[7:4] × fade[7:4] ÷ 16 → 0..14
    // ============================================================
    assign vol4  = vol_s2[7:4];
    assign fad4  = fade[7:4];
    assign gmul  = vol4 * fad4;                 // 4×4 小乘法
    assign gain4 = gmul[7:4];

    assign sv = $signed(samp);
    assign q1 = sv >>> 1;
    assign q2 = sv >>> 2;
    assign q3 = sv >>> 3;
    assign q4 = sv >>> 4;
    //   sv × gain4 / 16 = sv×(g3/2 + g2/4 + g1/8 + g0/16)
    assign vout = (gain4[3] ? q1 : 16'sd0)
                + (gain4[2] ? q2 : 16'sd0)
                + (gain4[1] ? q3 : 16'sd0)
                + (gain4[0] ? q4 : 16'sd0);

    assign out16 = vout[15:0];

    // ============================================================
    //  七、跨到像素域
    //      clk_aud：数据摆稳 → 翻 toggle
    //      clk_pix：同步后检边沿 → 锁存数据 + 打一拍 valid
    // ============================================================
    always @(posedge clk_aud or negedge rst_aud_n) begin
        if (!rst_aud_n) begin
            smp24   <= 24'd0;
            smp_tgl <= 1'b0;
        end
        else if (samp_tick) begin
            smp24   <= {out16, 8'd0};       // 16 位采样【左对齐】到 24 位
            smp_tgl <= ~smp_tgl;            // ★ 数据先摆稳，再翻 toggle
        end
    end

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin t1 <= 1'b0; t2 <= 1'b0; t3 <= 1'b0; end
        else            begin t1 <= smp_tgl; t2 <= t1; t3 <= t2; end
    end
    always @(*) new_smp = t2 ^ t3;      // toggle 变化 = 有一个新采样

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            o_audio_valid <= 1'b0;
            o_audio_left  <= 24'd0;
            o_audio_right <= 24'd0;
        end
        else begin
            o_audio_valid <= new_smp;       // 单拍
            if (new_smp) begin
                o_audio_left  <= smp24;     // 单声道 → 左右同采样
                o_audio_right <= smp24;
            end
        end
    end

    // ---- 状态 ----
    assign busy = v0 | (fade != 8'd0);

endmodule
