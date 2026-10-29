  module bmp_analyze #(
      // ★ 2026-10-20：1 = 按文件名找（AD* / MAP*），0 = 只按后缀（老行为）
      parameter NAME_EN = 1'b0
  )(
      input         sys_clk,
      input         sys_rst_n,

      // ---- ★★★ 第②步：共享 SD 前端（sd_top 在 top_a，三条链共用那一份）----
      input         fe_init_done,   // ← 原来 find_bmp 的 bus_owner（sd_ready）
      input         fe_led,         // ← 原来 find_bmp 的 led1（led_init）
      input         fe_owner,       // ★ 1 = 现在是"装图"这一条当家
      output [31:0] fe_lba,         // → 共享前端 read_addr
      output        fe_req,         // → 共享前端 read_req
      input  [7:0]  fe_data,        // ← 读回的数据（每字节单拍 fe_ok）
      input         fe_ok,
      input         fe_done,
      input         fe_busy,
      input         fe_err,

      // ---- ★★★ 2026-10-16【切法C·find_bmp 合流】：查文件请求/结果口 ----
      //   本链不再自带 FAT/目录状态机，这 8 根原样引到 top_a，
      //   由 top_a 接到【全局唯一一份】`find_bmp_eng`（u_find_eng）上。
      //   谁选主 / 怎么保证同时只有一条链在查 —— 见 top_a 的 sd_mode_r 那一段。
      output [23:0] eng_ext,        // → 引擎：本链扩展名（常量 "BMP"）
      output [3:0]  eng_skip,       // → 引擎：本链 skip（引擎在 start 那拍锁存）
      output        eng_name_en,    // ★ 2026-10-20：本链要比文件名 ⇒ 恒 1
      output        eng_name_sel,   // ★ 2026-10-20：0 = AD 类，1 = MAP 类
      output        eng_start,      // → 引擎：本链要查文件
      output        eng_owner,      // → 引擎：1 = 装图这条当家 → 直接接 u_find_eng.owner
      input  [31:0] eng_lba_i,      // ← 引擎：引擎自己算的扇区地址
      input         eng_req_i,      // ← 引擎：引擎自己的读请求
      input         eng_busy,       // ← 引擎：引擎自己的 busy
      input         eng_done,       // ← 引擎：查到了
      input         eng_fail,       // ← 引擎：查不到 / 卡 / 坏卡
      input  [31:0] eng_sector,     // ← 引擎：file_sector（已打拍）
      input  [31:0] eng_size,       // ← 引擎：file_size  （已打拍）
      input  [31:0] eng_cluster,    // ← 引擎：file_cluster（已打拍）

      // ---- 命令 ----
      input         start,          // 拉高一拍开始
      input  [3:0]  skip,           // 第几张 BMP
      input         name_sel,       // ★ 2026-10-20：0 = 找 AD 类，1 = 找 MAP 类

      // ---- 状态 ----
      output reg    busy,
      output reg    done,           // 单拍：全部像素输出完毕
      output reg    fail,           // 单拍：失败

      // ---- 图像信息 ----
      output reg [15:0] img_width,
      output reg [15:0] img_height,
      output reg        img_valid,  // 1 = 宽高有效

      // ---- 像素输出 ----
      output reg [15:0] px_data,    // RGB565 = {R[7:3], G[7:2], B[7:3]}
      output reg        px_we,      // 单拍写使能
      output     [31:0] px_addr,    // 像素序号 = y*W + x

      // ---- 调试 ----
      output            led_init,
      output            sd_ready,
      // ★★★ 2026-10-17【CMD18 多块连续读】：1 = 现在正在"读像素数据"这一段
      //   ⇒ 顶层拿它接 `sd_top.stream_en`（多块连续读的开关）。含义见 `sd_read.v` 文件头。
      //   ★ 为什么只在这一段开：文件头/目录阶段读的是**零散**扇区（不连续），
      //     开流式每块反而要多一次收流动作；而像素数据是**连续上千个扇区**，
      //     省掉的正是每块一次的卡访问延迟（实测约 120 µs/块）。
      output            seq_rd,
      output     [31:0] dbg_px_cnt,      // 已输出像素数，正常 == W*H
      output     [31:0] dbg_data_off,    // 从文件头读出的数据起点
      output     [15:0] dbg_first_px,    // 第一个像素的【完整 RGB888】（调试用）
      output     [31:0] dbg_first_addr,  // 第一个像素的地址（期望 (H-1)*W）
      // ★★★ 2026-10-21【D3 · C3】位深单独引出：32 位 BMP 以前只会静默失败，
      //   兜底页要靠它写出 "NEED 24BIT BMP"，否则现场只会看到 "BAD IMAGE" 再猜。
      output reg [15:0] bmp_bpp,          // 位深（第 28~29 字节；24 = 唯一支持的格式）
      // [2026-10-30] menu top-right: raw BMP header width/height (BEFORE decimation)
      output     [15:0] o_bmp_w,
      output     [15:0] o_bmp_h
  );

      //======================================================================
      //  和 find_bmp 的连线
      //======================================================================
      reg         f_start;                          // → find_bmp.start
      wire        f_done, f_fail;
      wire [31:0] f_sector, f_size, f_cluster;

      reg  [31:0] rd_lba;                           // → find_bmp.rd_lba
      reg         rd_req;                           // → find_bmp.rd_req
      wire [7:0]  rd_data;                          // ← find_bmp.rd_data
      wire        rd_ok, rd_done, rd_busy, rd_err;  // ←

      //======================================================================
      //  状态机
      //======================================================================
      localparam B_IDLE = 4'd0,
                 B_FIND = 4'd1,
                 B_WAIT = 4'd2,
                 B_REQ  = 4'd3,
                 B_RECV = 4'd4,
                 B_NEXT = 4'd5,
                 B_DONE = 4'd6,
                 B_FAIL = 4'd7;

      // ★★★ 2026-10-17【方案B · 装载时按行抽稀（降采样）】
      //   用户："像素高的图换的时间太长了"。这张卡在 SPI 模式下没法用 25 MHz、也没法
      //   用 CMD18 收流（两者都上板试过，见交接文档）⇒ 剩下的办法就是**少读**：
      //   显示窗口只有 800×600，源图却有 1152 行 ⇒ 原来把 1152 行全读进来，再由显示端
      //   按最近邻取 600 行，**白读了将近一半**。
      //   现在在装载端就按 Bresenham 等间隔只取 H_TGT 行（其余字节读出即丢），
      //   并把 `img_height` 报成实际保留的行数 —— 这四样东西会自动跟着变小/变对：
      //     `frame_words`（写长度）、`size_bad`（槽容量检查）、`desc_tx`（显示用它映射）。
      //   ★ 视觉上几乎无差别：显示端本来就是"1152 行里取 600 行"，这里取的还是那批行。
      //   ★ 不引入任何 seek：跳行只是"把字节读出来丢掉"（`g_cnt < skip_to`），
      //     扇区照常 cur_lba+1 顺次前进 ⇒ 没有额外开销，还顺手把行尾 padding 一并丢掉。
      //   ★ 源图高 ≤ H_TGT 时 h_keep = 源图高 ⇒ **行为与改动前逐位相同**（小图完全不受影响）。
      //
      //   ★★★ 2026-10-17【v2：整数抽取 + 真 seek】—— v1 的两条教训（都已上板验证）
      //     ① 只"读了不用"**一点时间都省不下来**：瓶颈是 SD 读，字节还是全读了；
      //     ② 只把高报小会改掉**长宽比**：显示端 fit 是 `min(800/W, 600/H)`
      //        ⇒ 1536×600 被显示成 800×312 中间一条（用户看到"图像不对"）。
      //   v2 的做法：
      //     · 行、列按**同一个** lg 抽（H>1800 ⇒ ÷4，H>900 ⇒ ÷2，否则不抽）
      //       ⇒ 报给显示的 (W>>lg, H>>lg) 长宽比与原图一致 ⇒ fit 出来的画面不变；
      //     · 真正省时间靠 **seek**：行边界上若下一行不要，直接把 `cur_lba` 跳到
      //       下一个所需行所在扇区（放弃当前扇区剩余字节是安全的 —— 每个扇区的读
      //       本来就是一笔独立事务，前端自己会收尾）。
      //   ★ 只用整数抽取（保留 0,2,4… 行），不需要除法器、也不需要行缓冲。
      //   ★ `DECIM_ON = 0` 时 lg 恒 0 ⇒ **行为与改动前逐位相同**（回退开关）。
      localparam integer DECIM_ON = 1;

      reg [3:0]  state;

      // ---- 从 find_bmp 拿到 ----
      reg [31:0] bmp_sector;      // 文件起始扇区
      reg [31:0] cur_lba;         // 当前要读的扇区
      reg [31:0] max_sec;         // 文件总共占几个扇区

      // ---- 从 BMP 头解出来的 ----
      reg [31:0] bmp_data_off;    // 像素数据起点（第 10~13 字节）
      reg [31:0] bmp_width;       // 宽（第 18~21 字节）
      reg [31:0] bmp_height;      // 高（第 22~25 字节）
      // bmp_bpp 已改成输出端口（见模块头，D3 · C3）
      reg        bm_ok;           // 开头是不是 "BM"
      reg        hdr_ready;       // 头解完了
      reg        hdr_bad;         // 头里有问题

      reg [31:0] row_bytes;       // 每行占几个字节 = ((W*3+3)/4)*4
      reg [31:0] total_px;        // 总像素数 = W*H

      // ---- ★ 2026-10-17【方案B v2】整数抽取 + seek 用 ----
      reg  [1:0]  lg;             // 抽取的对数：0 = 不抽，1 = ÷2，2 = ÷4
      reg  [15:0] wd;             // 报给显示的宽 = W >> lg
      reg  [15:0] hd;             // 报给显示的高 = H >> lg
      reg  [15:0] ridx;           // 当前处理到源图第几行
      reg  [15:0] ocol;           // 输出行内列号（0..wd-1）
      reg  [31:0] row_off;        // 当前这一行在文件里的绝对字节偏移
      reg  [9:0]  skip_cnt;       // seek 之后：新扇区开头要丢掉几个字节

      // ---- 收字节 ----
      reg [31:0] g_cnt;           // 全局字节计数（从文件第 0 字节算起）
      reg [31:0] sec_cnt;         // 已读扇区数（防死循环）

      // ---- 像素转换 ----
      reg [1:0]  pad_cnt;         // ★★★ 2026-10-17【修 bug】本行还剩几个【填充字节】要丢
      reg [1:0]  sub_cnt;         // 像素内第几字节 0=蓝 1=绿 2=红
      reg [7:0]  b_byte, g_byte;  // 暂存蓝、绿（完整 8 位，供调试用）
      reg [15:0] col;             // 当前列 0..W-1
      reg [31:0] row_base;        // 当前显示行在帧缓冲里的起始地址
      reg [31:0] px_cnt;          // 已输出像素数
      reg [31:0] px_addr_r;       // ★ 像素序号（寄存，和 px_we 同拍更新）
      reg [15:0] first_px_r;      // 第一个像素的完整 RGB888（调试用）
      reg [31:0] first_addr_r;    // 第一个像素的地址（调试用）

      // ★ px_addr 改成寄存输出，保证和 px_we / px_data 严格对齐
      assign px_addr = px_addr_r;

      // "BM" 两个字节都对
      wire bm_all_ok = bm_ok;

      // 尺寸上限（col 只有 16 位，超过 65535 的宽度算不了）
      wire size_ok = (bmp_width  >= 32'd1) && (bmp_width  <= 32'd4096) &&
                     (bmp_height >= 32'd1) && (bmp_height <= 32'd4096);

      // ★ 像素处理的总条件：头部就绪 + 过了头部 + 像素还没收够
      wire pix_phase = hdr_ready && (g_cnt >= bmp_data_off) && (px_cnt < total_px);

      // ★ 2026-10-17【方案B】：多块连续读的开关 = 就是"正在读像素数据"这一段（见端口说明）
      assign seq_rd = pix_phase;

      // ★★★ 2026-10-17【方案B v2】抽取档 / 行列判定 / seek 目标（**必须放模块层**：
      //   Verilog 不允许在 always 块里声明 wire）。
      //   `lg_w` 由源图高决定：H>2400 ⇒ ÷4，H>1200 ⇒ ÷2，否则不抽（小图完全不受影响）。
      //   行列用**同一个** lg ⇒ 长宽比不变 ⇒ 显示端 fit 出来的画面和原来一样。
      wire [1:0]  lg_w    = DECIM_ON ? ((bmp_height > 32'd1800) ? 2'd2 :
                                        (bmp_height > 32'd900)  ? 2'd1 : 2'd0)
                                     : 2'd0;
      wire [15:0] wd_w    = bmp_width[15:0]  >> lg_w;
      wire [15:0] hd_w    = bmp_height[15:0] >> lg_w;
      wire [15:0] lg_mask = (16'd1 << lg) - 16'd1;               // 0 / 1 / 3
      wire        keep_row = ((ridx & lg_mask) == 16'd0);         // 这一行要不要吐
      wire        keep_col = ((col  & lg_mask) == 16'd0);         // 这一列要不要吐
      wire        keep_rn  = (((ridx + 16'd1) & lg_mask) == 16'd0); // 下一行要不要
      //  seek 目标 = 当前行起点 + 2^lg 行（用移位，不做乘法）
      wire [31:0] step_off = row_off + (row_bytes << lg);

      // ============================================================
      //  ★★★ 2026-10-17【修 bug ①】BMP 行填充（padding）没被丢掉
      // ------------------------------------------------------------
      //  24 位 BMP 每行字节数按 4 对齐：row_bytes = ((W*3+3)/4)*4
      //  ⇒ W*3 % 4 != 0 的图（例如 W=1001 ⇒ 3003 字节 ⇒ 行尾补 1 个字节）
      //    每个行尾都夹着 1..3 个【不属于任何像素】的填充字节。
      //
      //  原实现只用"吐满 W 个源像素"判行尾，然后 `col` 清零继续 —— 那 1..3 个
      //  填充字节就被当成下一行的前 1..3 个颜色字节吃掉 ⇒ **整图错行**
      //  （和 byte_in_row 时代那个"每 4 行错一次"是同类病，只是触发条件不同）。
      //
      //  卡上现在四种宽度 640/800/1080/1536 的 W*3 都能被 4 整除 ⇒ 从没暴露；
      //  这属于"换一张图就翻车"的真 bug，一起修掉。
      //  修法：行尾把 `pad_cnt` 装成填充字节数，接下来的 pad_cnt 个字节只丢不用。
      //     pad_n = (4 − (W*3 mod 4)) mod 4
      //     W*3 mod 4 用 2 位加法自然取模（W[1:0]+W[1:0]+W[1:0]），不做乘除法。
      //  ★ 只有 `keep_rn`（原地继续、字节流不断）那一支才需要丢；
      //    seek 那一支直接把读指针跳到下一行行首，填充字节根本不会被读到。
      // ============================================================
      wire [1:0]  w3_lo = bmp_width[1:0] + bmp_width[1:0] + bmp_width[1:0];  // (3W) mod 4
      wire [2:0]  pad_t = 3'd4 - {1'b0, w3_lo};                            // 0..4
      wire [1:0]  pad_n = pad_t[1:0];                     // 0/1/2/3（w3_lo=0 ⇒ 4⇒0）
      // ★ 行尾判据（也是"要不要 seek"的判据）提到模块层，两处共用同一份定义
      wire        row_end    = (col == bmp_width[15:0] - 16'd1) && (sub_cnt == 2'd2);
      wire        row_seek   = pix_phase && keep_row && (pad_cnt == 2'd0) && row_end && !keep_rn;

      assign dbg_px_cnt     = px_cnt;
      assign dbg_data_off   = bmp_data_off;
      assign dbg_first_px   = first_px_r;
      assign dbg_first_addr = first_addr_r;
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n) begin
              state        <= B_IDLE;
              f_start      <= 1'b0;
              rd_lba       <= 32'd0;
              rd_req       <= 1'b0;
              cur_lba      <= 32'd0;
              max_sec      <= 32'd0;
              bmp_sector   <= 32'd0;
              bmp_data_off <= 32'd0;
              bmp_width    <= 32'd0;
              bmp_height   <= 32'd0;
              bmp_bpp      <= 16'd0;
              bm_ok        <= 1'b0;
              hdr_ready    <= 1'b0;
              hdr_bad      <= 1'b0;
              row_bytes    <= 32'd0;
              total_px     <= 32'd0;
              lg           <= 2'd0;
              wd           <= 16'd0;
              hd           <= 16'd0;
              ridx         <= 16'd0;
              ocol         <= 16'd0;
              row_off      <= 32'd0;
              skip_cnt     <= 10'd0;
              g_cnt        <= 32'd0;
              sec_cnt      <= 32'd0;
              sub_cnt      <= 2'd0;
              pad_cnt      <= 2'd0;
              b_byte       <= 8'd0;
              g_byte       <= 8'd0;
              col          <= 16'd0;
              row_base     <= 32'd0;
              px_cnt       <= 32'd0;
              px_addr_r    <= 32'd0;
              first_px_r   <= 'd0;
              first_addr_r <= 32'd0;
              busy         <= 1'b0;
              done         <= 1'b0;
              fail         <= 1'b0;
              img_width    <= 16'd0;
              img_height   <= 16'd0;
              img_valid    <= 1'b0;
              px_data      <= 16'd0;        // ★ 16 位
              px_we        <= 1'b0;
          end
          else begin
              done  <= 1'b0;
              fail  <= 1'b0;
              px_we <= 1'b0;        // 单拍脉冲，默认清零

              case (state)
              //--------------------------------------------------------------
              B_IDLE: begin
                  busy <= 1'b0;
                  if (start && sd_ready) begin
                      f_start     <= 1'b1;      // 一拍
                      hdr_ready   <= 1'b0;
                      hdr_bad     <= 1'b0;
                      bm_ok       <= 1'b0;
                      img_valid   <= 1'b0;
                      g_cnt       <= 32'd0;
                      lg          <= 2'd0;
                      wd          <= 16'd0;
                      hd          <= 16'd0;
                      ridx        <= 16'd0;
                      ocol        <= 16'd0;
                      row_off     <= 32'd0;
                      skip_cnt    <= 10'd0;
                      sec_cnt     <= 32'd0;
                      sub_cnt     <= 2'd0;
                      pad_cnt     <= 2'd0;
                      col         <= 16'd0;
                      px_cnt      <= 32'd0;
                      px_addr_r   <= 32'd0;     // 顺手清掉，方便调试
                      first_px_r  <= 16'd0;
                      first_addr_r<= 32'd0;
                      busy        <= 1'b1;
                      state       <= B_FIND;
                  end
              end
              //--------------------------------------------------------------
              B_FIND: begin
                  f_start <= 1'b0;
                  if (f_done) begin
                      bmp_sector <= f_sector;
                      cur_lba    <= f_sector;
                      // 文件占几个扇区，向上取整
                      max_sec    <= (f_size + 32'd511) >> 9;
                      sec_cnt    <= 32'd0;
                      state      <= B_WAIT;
                  end
                  else if (f_fail)
                      state <= B_FAIL;
              end
              //--------------------------------------------------------------
              // 等上一笔事务彻底结束
              B_WAIT: begin
                  if (!rd_busy) begin
                      rd_lba <= cur_lba;
                      rd_req <= 1'b1;
                      state  <= B_REQ;
                  end
              end
              //--------------------------------------------------------------
              // 请求举着，等被受理
              B_REQ: begin
                  if (rd_busy) begin
                      rd_req <= 1'b0;
                      state  <= B_RECV;
                  end
              end
              //--------------------------------------------------------------
              B_RECV: begin
                  // ★ 2026-10-17【方案B v2】seek 之后，新扇区开头这 `skip_cnt` 个字节要丢掉
                  //   （`g_cnt` 在 seek 时已设成扇区基址，丢一个加一个，丢完就正好落在行首）。
                  if (rd_ok && (skip_cnt != 10'd0)) begin
                      skip_cnt <= skip_cnt - 10'd1;
                      g_cnt    <= g_cnt + 32'd1;
                  end
                  else if (rd_ok) begin
                      //==========================================================
                      //  1. BMP 头字段（只在前 30 个字节）
                      //==========================================================
                      if (g_cnt == 32'd0) bm_ok <= (rd_data == 8'h42);          // 'B'
                      if (g_cnt == 32'd1) bm_ok <= bm_ok && (rd_data == 8'h4D); // 'M'

                      // 第 10~13 字节：像素数据起点（小端）
                      if (g_cnt == 32'd10) bmp_data_off[7:0]   <= rd_data;
                      if (g_cnt == 32'd11) bmp_data_off[15:8]  <= rd_data;
                      if (g_cnt == 32'd12) bmp_data_off[23:16] <= rd_data;
                      if (g_cnt == 32'd13) bmp_data_off[31:24] <= rd_data;

                      // 第 18~21 字节：宽
                      if (g_cnt == 32'd18) bmp_width[7:0]   <= rd_data;
                      if (g_cnt == 32'd19) bmp_width[15:8]  <= rd_data;
                      if (g_cnt == 32'd20) bmp_width[23:16] <= rd_data;
                      if (g_cnt == 32'd21) bmp_width[31:24] <= rd_data;

                      // 第 22~25 字节：高
                      if (g_cnt == 32'd22) bmp_height[7:0]   <= rd_data;
                      if (g_cnt == 32'd23) bmp_height[15:8]  <= rd_data;
                      if (g_cnt == 32'd24) bmp_height[23:16] <= rd_data;
                      if (g_cnt == 32'd25) bmp_height[31:24] <= rd_data;

                      // 第 28~29 字节：位深
                      if (g_cnt == 32'd28) bmp_bpp[7:0]  <= rd_data;
                      if (g_cnt == 32'd29) bmp_bpp[15:8] <= rd_data;

                      //----------------------------------------------------------
                      // 第 30 个字节：所有头字段都齐了，做校验 + 算派生量
                      //----------------------------------------------------------
                      if (g_cnt == 32'd30) begin
                          if (!bm_all_ok || (bmp_bpp != 16'd24) || !size_ok) begin
                              hdr_bad <= 1'b1;      // 不是 24 位 BMP / 宽高异常
                          end
                          else begin
                              hdr_ready <= 1'b1;
                              // 每行字节数 = ((W*3 + 3) / 4) * 4
                              row_bytes <= ((bmp_width * 32'd3 + 32'd3) >> 2) << 2;
                              // ★ 2026-10-17【方案B v2】：行列按同一个 lg 抽取
                              lg         <= lg_w;
                              wd         <= wd_w;
                              hd         <= hd_w;
                              total_px   <= wd_w * hd_w;
                              // bottom-up：文件第 0 行写到帧缓冲最后一行
                              row_base   <= ({16'd0, hd_w} - 32'd1) * {16'd0, wd_w};
                              // ★ 报给显示的是**抽取后**的宽高（frame_words / size_bad /
                              //   desc_tx 都由它派生 ⇒ 自动变小、自动对；长宽比不变）
                              img_width  <= wd_w;
                              img_height <= hd_w;
                              img_valid  <= 1'b1;
                              // ★ 行/列/seek 的初值：从像素数据起点、第 0 行开始
                              ridx       <= 16'd0;
                              ocol       <= 16'd0;
                              row_off    <= bmp_data_off;
                              skip_cnt   <= 10'd0;
                              pad_cnt    <= 2'd0;      // ★ 每一行行尾由 row_end 重新装
                          end
                      end

                      //==========================================================
                      //  ★★★ 2026-10-17【方案B v2】列抽取 + 行尾 seek（详见文件头）
                      //  ★ 3 个字节凑一个**源像素**，凑满后按 `keep_col` 决定吐不吐；
                      //    `col` 是**源列号**，每个源像素都要 +1（不能只在吐的时候加）。
                      //  ★ 行尾用源像素数判（和字节流解耦，见下面那段历史注释）；
                      //    行尾时按 `keep_rn` 决定"原地继续"还是"seek 到下一条要读的行"。
                      //==========================================================
                      if (pix_phase && keep_row) begin

                        // ★★★ 2026-10-17【修 bug ①】行尾那 1..3 个填充字节：
                        //   只丢不用（判据/推导见模块层 `pad_n` 那一段）。
                        if (pad_cnt != 2'd0) begin
                            pad_cnt <= pad_cnt - 2'd1;
                        end
                        else begin

                          // ---- 2a. BGR → RGB565 ----
                          if ({16'd0, col} < bmp_width[15:0]) begin
                              if (sub_cnt == 2'd0) begin                // 蓝
                                  b_byte  <= rd_data;
                                  sub_cnt <= 2'd1;
                              end
                              else if (sub_cnt == 2'd1) begin           // 绿
                                  g_byte  <= rd_data;
                                  sub_cnt <= 2'd2;
                              end
                              else begin                                // 红 = 一个源像素完成
                                  sub_cnt <= 2'd0;
                                  col     <= col + 1'b1;                // ★ 源列号：每个源像素都加
                                  // ★ 列抽取：只有"抽中的列"且输出列号还没到 wd 才吐
                                  if (keep_col && ({16'd0, ocol} < wd)) begin
                                      px_data   <= {rd_data[7:3],       // R[7:3]
                                                    g_byte[7:2],        // G[7:2]
                                                    b_byte[7:3]};       // B[7:3]
                                      // ★ 用【自增前】的 row_base / ocol（同原来的口径）
                                      px_addr_r <= row_base + {16'd0, ocol};
                                      if (px_cnt == 32'd0) begin
                                          first_px_r   <= {rd_data[7:3], g_byte[7:2], b_byte[7:3]};
                                          first_addr_r <= row_base + {16'd0, ocol};
                                      end
                                      px_we   <= 1'b1;
                                      ocol    <= ocol + 1'b1;
                                      px_cnt  <= px_cnt + 1'b1;
                                  end
                              end
                          end

                          // ---- 2b. 行尾 ----
                          // ★ 必须放在 2a 后面：行尾那一拍 col 要清零，
                          //   不能被 2a 的 col+1 覆盖掉
                          //
                          // ★★ 集成临时改动（见 规划\A轨待改清单.md 第 5 条）
                          //   原来这里用【外部字节计数器 byte_in_row】判行尾：
                          //       if (byte_in_row == row_bytes - 1) ...
                          //   问题：640x480 24 位每行 1920 字节 = 3.75 个 512 字节扇区，
                          //   行首每 4 行才落在扇区边界上；只要字节流在扇区切换处
                          //   多算/漏算一个字节，行边界就会错 → 每 4 行错一次
                          //   → 屏上正是"一条一条、每 4 行跳一次的错位横带"。
                          //   现在改成用【本行已吐出的像素数】判行尾，和字节流完全解耦：
                          //   吐满 bmp_width 个像素（且正好在第 3 个字节=红）就是这一行结束。
                          //   byte_in_row 降级成纯参考量，不再参与行边界判断。
                          if (row_end) begin
                              col         <= 16'd0;
                                      ridx        <= ridx + 16'd1;
                              row_base    <= row_base - {16'd0, wd};  // 输出行往上走一格
                              ocol        <= 16'd0;
                              if (keep_rn) begin
                                  // 下一行也要 ⇒ 原地继续（不 seek，字节流不断）
                                  row_off <= row_off + row_bytes;
                                  // ★★★ 2026-10-17【修 bug ①】原地继续时，
                                  //   这一行的填充字节会紧跟着到来 ⇒ 装进 pad_cnt 丢掉。
                                  pad_cnt <= pad_n;
                              end
                              else begin
                                  // ★ 下一行不要 ⇒ **seek**：跳到"下一条要读的行"所在扇区。
                                  //   进 B_WAIT 等当前这笔读收尾；当前扇区剩下的字节会被前端
                                  //   自然丢弃（每扇区一笔独立事务 ⇒ 不会错位）。
                                  //   ★★ `step_off` 是**文件内**偏移，`cur_lba` 是**盘上绝对**扇区
                                  //      ⇒ 必须加上文件起始扇区 `bmp_sector`！
                                  //      （仿真台抓到过：漏了它就去读盘上第 1 个扇区，画面变全白。）
                                  cur_lba  <= bmp_sector + {19'd0, step_off[31:9]};
                                  skip_cnt <= step_off[8:0];
                                  g_cnt    <= {step_off[31:9], 9'd0};
                                  row_off  <= step_off;
                                  ridx     <= ridx + {14'd0, lg_mask} + 16'd1;  // 行号一起跳
                                  state    <= B_WAIT;
                              end
                          end
                        end
                      end

                      g_cnt <= g_cnt + 32'd1;
                  end

                  // ★★★ 2026-10-17【修 bug ②】行尾 seek 与扇区结束【同拍】的竞态
                  // ------------------------------------------------------------
                  //  `read_ok` 和 `read_done` 在第 512 个字节那一拍是**同时**为高的
                  //  （sd_read.v: `if (data_cnt == 511) read_done <= 1`；
                  //    sd_read_cdc.v: 两者各翻一个 toggle、在同一拍被检边还原）。
                  //  如果某一行的最后一个像素的第三个字节正好是扇区最后一字节，
                  //  那么同一拍里既会执行行尾 seek（`state <= B_WAIT`），
                  //  又会执行下面这句 `state <= B_NEXT` —— 后赋值优先 ⇒ 变成 B_NEXT：
                  //     · `cur_lba` 已经是 seek 目标，B_NEXT 又 +1 ⇒ 多跳一个扇区；
                  //     · `skip_cnt` / `g_cnt` 还是 seek 的值 ⇒ 整行偏 512 字节。
                  //  ⇒ 用 `row_seek`（= 本拍正在做"跳到下一行"这件事）把它挡掉。
                  //  实测卡上 640/800/1080/1536 四种宽度都不落在这个同拍窗口里
                  //  （按 (data_off + W*3*k + W*3-1) mod 512 逐个算过），所以是潜在 bug；
                  //  但 `W*3 ≡ 0 (mod 512)` 的图（W=512/1024/1536/2048 且 data_off 合适）
                  //  会撞上，属于"换张图就错行"的雷。
                  if (rd_done && !row_seek) state <= hdr_bad ? B_FAIL : B_NEXT;
                  if (rd_err)  state <= B_FAIL;
              end
              //--------------------------------------------------------------
              B_NEXT: begin
                  if (px_cnt >= total_px)
                      state <= B_DONE;          // 所有像素都吐完了
                  else if (sec_cnt >= max_sec)
                      state <= B_FAIL;          // 文件读完了但像素没凑齐
                  else begin
                      cur_lba <= cur_lba + 32'd1;
                      sec_cnt <= sec_cnt + 32'd1;
                      state   <= B_WAIT;
                  end
              end
              //--------------------------------------------------------------
              B_DONE: begin
                  done  <= 1'b1;
                  busy  <= 1'b0;
                  state <= B_IDLE;
              end
              B_FAIL: begin
                  fail  <= 1'b1;
                  busy  <= 1'b0;
                  state <= B_IDLE;
              end
              default: state <= B_IDLE;
              endcase
          end
      end

      find_bmp #(
          .TARGET_EXT ({"B","M","P"}),
          .NAME_EN    (NAME_EN)           // ★ 2026-10-20：由顶层开关（默认 0 = 老行为）
      ) u_find_bmp (
          .sys_clk    (sys_clk),
          .sys_rst_n  (sys_rst_n),

          // ---- ★★★ 第②步：共享 SD 前端（真正的 sd_top 在 top_a，全局一份）----
          .fe_init_done (fe_init_done),
          .fe_led       (fe_led),
          .fe_owner     (fe_owner),
          .fe_lba       (fe_lba),
          .fe_req       (fe_req),
          .fe_data      (fe_data),
          .fe_ok        (fe_ok),
          .fe_done      (fe_done),
          .fe_busy      (fe_busy),
          .fe_err       (fe_err),

          .start      (f_start),
          .cmd        (1'b0),           // 0 = 找文件
          .skip       (skip),
          .name_sel   (name_sel),
        .name_inv   (1'b0),           // ★ 2026-10-21：名字过滤统一在 top_a 的共享引擎上做       // ★ 2026-10-20：0 = AD 类，1 = MAP 类
          .in_cluster (32'd0),          // cmd=0 用不到

          .busy       (),               // 不用
          .done       (f_done),
          .fail       (f_fail),

          .file_sector (f_sector),
          .file_size   (f_size),
          .file_cluster(f_cluster),

          .next_cluster(), .next_sector(), .chain_end(),

          .rd_lba  (rd_lba),
          .rd_req  (rd_req),
          .rd_data (rd_data),
          .rd_ok   (rd_ok),
          .rd_done (rd_done),
          .rd_busy (rd_busy),
          .rd_err  (rd_err),

          .led1      (led_init),
          .bus_owner (sd_ready),

          // ---- ★★★ 2026-10-16【切法C·find_bmp 合流】----
          .eng_ext     (eng_ext),
          .eng_skip    (eng_skip),
          .eng_name_en (eng_name_en),   // ★ 2026-10-20：恒 1（本链要比名字）
          .eng_name_sel(eng_name_sel),  // ★ 2026-10-20：0 = AD 类，1 = MAP 类
          .eng_start   (eng_start),
          .eng_owner   (eng_owner),
          .eng_lba_i   (eng_lba_i),
          .eng_req_i   (eng_req_i),
          .eng_busy    (eng_busy),
          .eng_done    (eng_done),
          .eng_fail    (eng_fail),
          .eng_sector  (eng_sector),
          .eng_size    (eng_size),
          .eng_cluster (eng_cluster)
      );

  // [2026-10-30] raw BMP size straight out to the menu resolution overlay
  assign o_bmp_w = bmp_width[15:0];
  assign o_bmp_h = bmp_height[15:0];
  endmodule
