  //==========================================================================
  //  bmp_scale —— A 轨【装载时降采样】（任意比盒式平均）
  //
  //  位置：  bmp_analyze ──► 【本模块】 ──► bmp2sdram
  //
  //  干什么：
  //    · 图装得下槽  → 原样直通（一个像素都不动，连地址都不改）
  //    · 图装不下    → 等比缩到「槽能装下的最大 4:3」= TGT_W x TGT_H
  //                    源图超过 4:3 的部分【居中裁剪】掉
  //
  //  目标尺寸 TGT_W x TGT_H = 1152 x 864
  //    ★★ 2026-10-04 由 1536x1152 改小（B 按用户要求直接改 A，见《A轨待改清单》）：
  //      显示窗口只有 800x600，而 1536x1152 要写 884,736 字 —— 白写了 3.7 倍，
  //      装载时间（= 转场里"米白"那一段的长度）几乎全花在这里。
  //      1152x864 一样是精确 4:3，字数降到 864 x 576 = 497,664（少了 1.78 倍），
  //      而显示端在窗口里最高 1.44 倍看清细节（1x/1.5x 档还有真细节）。
  //    · 1152 = 2^7*3^2、864 = 2^5*27 —— 除 2 得 576 字/行，移位就行
  //
  //  ★ 只缩不放：装得下就直通。这样小图仍然保留契约里
  //    "放大上限 Z = sqrt(槽像素/窗口面积)" 的余量，不白扔。
  //
  //  ------------------------------------------------------------------
  //  算法：任意比盒式平均（area average）
  //
  //    每个输出像素 = 它覆盖的那块源像素的算术平均：
  //        out(ou,ok) = mean{ src(u,k) : u 在 ou 的列范围, k 在 ok 的行范围 }
  //
  //    列、行各用一个 DDA 累加器推边界 —— 只有加法器 + 比较器，
  //    没有乘法器、没有除法器：
  //        acc += TGT_W;  if (acc >= win_len) { acc -= win_len; idx++; }
  //
  //  数据流：
  //    源像素 (u,k) ──► DDA 算它落在哪个输出列 ou
  //                 ──► acc_ram[bank][ou] += {R,G,B}，cnt++
  //    源行跨过输出行边界 ──► 切 bank，后台发射那一行：
  //                          out_px = sum / cnt，边发边清零
  //
  //  ★ 乒乓双 bank：正在累加的 bank 和正在发射的 bank 互不干扰，
  //    发射在后台慢慢跑，不堵住输入。
  //
  //  ★ 发射通道不用快：源像素 1.92us 一个（契约第二节），
  //    50 MHz 下每两个源像素之间隔 96 个时钟，
  //    发射一行最多 TGT_W x 12 拍 = 18432 拍 << 一行源数据的 100 万拍。
  //
  //  ★ 除法：商最大 63（G 分量），8 拍"移位-试减"，R/G/B 三路并行。
  //    不需要 DSP、不需要迭代除法器。
  //
  //  ------------------------------------------------------------------
  //  ★ 什么时候真的会缩：触发条件是 src_h*ceil(src_w/2) > SLOT_WORDS，
  //    即源图 > 186 万像素。此时裁剪窗口面积必然 > 1,861,660 > 目标
  //    1,769,472，所以【一定是降采样】，不会走"要放大"的分支。
  //==========================================================================
  module bmp_scale #(
      // ★★ 2026-10-04：1536x1152 → 1152x864（见文件头说明；装载时间少 1.78 倍）
      parameter integer TGT_W      = 1152,      // 目标宽（4:3）
      parameter integer TGT_H      = 864,       // 目标高
      // ★ 2026-10-03 契约 v8：大槽 0 补到 930,832 字 → 两个大槽里小的那个是 930,828
      parameter integer SLOT_WORDS = 930828     // 大槽字数（判"装不装得下"）
  )(
      input             clk,                    // 控制域 50 MHz
      input             rst_n,

      // ---- 帧起点（接 top_a 的 start）----
      input             start,

      // ---- 从 bmp_analyze 来 ----
      input      [15:0] src_w,                  // 源图宽（像素）
      input      [15:0] src_h,                  // 源图高（像素）
      input             src_we,                 // 源像素写使能（单拍）
      input      [31:0] src_addr,               // 源像素序号 = y*src_w + x
      input      [15:0] src_px,                 // 源像素 RGB565
      input             src_done,               // 源图吐完了（单拍）

      // ---- 去 bmp2sdram ----
      output reg        out_we,
      output reg [31:0] out_addr,               // 缩放后栅格序号 = y*out_w + x
      output reg [15:0] out_px,
      output reg        out_done,

      // ---- 给 desc_tx 的尺寸（★ 存储尺寸，不是原图尺寸）----
      output wire [15:0] out_w,
      output wire [15:0] out_h,

      // ---- 诊断 ----
      output wire        scaled,                // 1 = 这一帧真的缩了
      output reg         err_overrun,           // 发射没跟上（不能亮）
      output wire        busy
  );

      //==================================================================
      //  一、判"装不装得下" + 算裁剪窗口（组合，每帧一组常量）
      //==================================================================
      wire [31:0] row_words  = ({16'd0, src_w} + 32'd1) >> 1;
      wire [31:0] need_words = {16'd0, src_h} * row_words;
      // ★★ 2026-10-04：触发条件加一条"**比目标大就缩**"。
      //   原来只判"装不进大槽"（>930,828 字 = 186 万像素），于是 1536x1152
      //   这种"装得下但远大于显示需要"的图**一点都不缩**，照样整张写 884,736 字
      //   —— 装载时间（= 转场里米白那段）全花在这儿。
      //   现在：源图任一边超过目标，或者整张装不进大槽，都缩到 TGT_W x TGT_H。
      //   ★ 代价（用户已知情并选择）：这张图存成 1152x864 之后，
      //     窗口里"有真细节"的倍率上限 = 1152/800 ≈ 1.44 倍（1x/1.5x 仍真细节）。
      // ★★ 2026-10-04【收回】：触发条件回到"只有装不进大槽才缩"。
      //    为什么收回：把 1536x1152（884,736 字，本来直通得好好的）也逼上了
      //    `bmp_scale` 的缩放路径，而上板结果正是台账里早就记着的那个已知问题
      //    ——"超大图压缩"这条路会白屏（所以当初的决定是：演示素材在 PC 端先缩好，
      //    A 不做缩放）。用户实测：640x480→600x800 正常，→1152 白条扫完就全白。
      //    ⇒ 要缩短装载，改在 PC 端把素材缩到 ~1152x864 就行，别动这条路径。
      //    （TGT_W/TGT_H 仍是 1152x864：只影响"装不进大槽"的那种图。）
      wire        do_scale   = (need_words > SLOT_WORDS);

      //  裁剪：取源图中间一块 4:3，尽可能大
      wire [31:0] w_x3 = {16'd0, src_w} * 32'd3;
      wire [31:0] h_x4 = {16'd0, src_h} * 32'd4;
      wire        wide = (w_x3 > h_x4);                          // 源图比 4:3 更宽

      wire [31:0] sw_calc = ({16'd0, src_h} * 32'd4) / 32'd3;
      wire [31:0] sh_calc = ({16'd0, src_w} * 32'd3) / 32'd4;

      wire [15:0] win_sw = wide ? sw_calc[15:0] : src_w;
      wire [15:0] win_sh = wide ? src_h         : sh_calc[15:0];
      wire [15:0] win_su = ({16'd0, src_w} - {16'd0, win_sw}) >> 1;   // 左边裁掉
      wire [15:0] win_kl = ({16'd0, src_h} - {16'd0, win_sh}) >> 1;   // 下边裁掉

      assign out_w  = do_scale ? TGT_W[15:0] : src_w;
      assign out_h  = do_scale ? TGT_H[15:0] : src_h;
      assign scaled = do_scale;

      //==================================================================
      //  二、配置锁存 + 源像素坐标
      //==================================================================
      reg        cfg_vld;
      reg [15:0] c_sw, c_sh, c_su, c_kl;
      reg        c_scale;

      reg [15:0] u_cnt, k_cnt;      // 当前源像素的列 / 行（发射顺序）
      reg [31:0] px_cnt;
      reg [31:0] px_total;
      reg        frame_run;
      reg        e_done;
      reg        src_all;           // 源像素收完了

      assign busy = frame_run;

      //==================================================================
      //  三、列 / 行 DDA
      //==================================================================
      reg [31:0] acc_u;
      reg [15:0] ou;
      reg [31:0] acc_v;
      reg [15:0] ok_cur;
      reg [15:0] row_hi;            // = c_kl + c_sh，省一次加法

      //==================================================================
      //  四、累加器 RAM（乒乓双 bank，真双口）
      //     [15:0] R 和   [31:16] G 和   [47:32] B 和   [63:48] 计数
      //==================================================================
      // ★★ 2026-10-02 集成临时改动（见 规划\A轨待改清单.md 第 9 条）：
      //   原来是 `reg [63:0] acc_ram [0:2*TGT_W-1]`（3072 字 × 64 位 = 196,608 比特）。
      //   TD 的 RAM 推断认不出这个形状 —— 日志里有 "extracting RAM for identifier
      //   'acc_ram'"，但到 "Infer Logic BRAM" 那一步就没了（它只认出 512×32 那种
      //   单块形状），于是这 196,608 个比特每人一个触发器：bmp_scale 一个模块
      //   17.5 万个 DFF、24 万个 LUT（整颗芯片只有 19,600 个）→ 综合永远跑不完。
      //   改成直接例化 TD 自己的 BRAM 原语 EG_LOGIC_BRAM（TD 的 IP 生成器就是这么出的），
      //   宽度/深度由工具自己拼块。读写时序与原数组等价。
      //   ★ 仿真要补模型 TD_engineer\sim_release\eg4\eg_logic_bram.v
      localparam integer ACC_DEPTH = 2*TGT_W;    // 3072
      localparam integer ACC_AW    = 12;         // 4096 ≥ 3072

      // ---- 端口 A：累加（写口）----
      // ★ 这几条声明必须放在下面的例化【之前】：Verilog 里没声明就用，
      //   会被当成隐式 wire，回头再写 reg 声明 ModelSim 就报"已声明"。
      reg  [12:0] a_idx;
      reg         a_we;
      reg  [63:0] a_din;

      // ---- 端口 B：发射（写口，只写 0 = 边发边清零）----
      reg  [12:0] b_idx;
      reg         b_we;

      wire [63:0] acc_dout_a, acc_dout_b;

      EG_LOGIC_BRAM #(
          .DATA_WIDTH_A (64), .DATA_WIDTH_B (64),
          .ADDR_WIDTH_A (ACC_AW), .ADDR_WIDTH_B (ACC_AW),
          .DATA_DEPTH_A (ACC_DEPTH), .DATA_DEPTH_B (ACC_DEPTH),
          .BYTE_ENABLE  (0), .BYTE_A (1), .BYTE_B (1),
          .MODE         ("DP"),
          .REGMODE_A    ("NOREG"), .REGMODE_B ("NOREG"),
          .WRITEMODE_A  ("READBEFOREWRITE"), .WRITEMODE_B ("READBEFOREWRITE"),
          .RESETMODE    ("SYNC"),
          .DEBUGGABLE   ("NO"), .PACKABLE ("NO"), .FORCE_KEEP ("OFF"),
          .INIT_FILE    ("NONE"), .FILL_ALL ("NONE"),
          .IMPLEMENT    ("9K")
      ) u_acc_ram (
          .doa   (acc_dout_a), .dia (a_din), .addra (a_idx),
          .cea   (1'b1), .ocea (1'b1), .clka (clk), .wea (a_we), .rsta (1'b0), .bea (1'b1),
          .dob   (acc_dout_b), .dib (64'd0), .addrb (b_idx),
          .ceb   (1'b1), .oceb (1'b1), .clkb (clk), .web (b_we), .rstb (1'b0), .beb (1'b1)
      );
      wire [63:0] a_dout = acc_dout_a;
      wire [63:0] b_dout = acc_dout_b;

      reg        bank_cur;          // 正在累加的 bank
      reg        bank_emt;          // 正在发射的 bank

      // bank 索引：bank*TGT_W
      function [12:0] bank_off;
          input b;
          begin
              bank_off = b ? TGT_W[12:0] : 13'd0;
          end
      endfunction

      //==================================================================
      //  五、累加小状态机（读-改-写，3 拍）
      //==================================================================
      localparam A_IDLE = 2'd0, A_RD = 2'd1, A_WR = 2'd2;

      reg  [1:0]  st_a;
      reg         acc_pend;
      reg  [15:0] pend_ou;
      reg  [15:0] pend_px;

      wire [15:0] p_r = {11'd0, pend_px[15:11]};
      wire [15:0] p_g = {10'd0, pend_px[10:5]};
      wire [15:0] p_b = {11'd0, pend_px[4:0]};

      //==================================================================
      //  六、发射状态机（后台跑）
      //==================================================================
      localparam E_IDLE = 3'd0, E_RD = 3'd1, E_RD2 = 3'd2,
                 E_INI  = 3'd3, E_DIV= 3'd4, E_OUT = 3'd5;

      reg  [2:0]  st_e;
      reg  [3:0]  emit_pend;
      reg  [15:0] emt_idx;
      reg  [31:0] emt_base;
      reg         emt_first;

      reg  [15:0] dv_r, dv_g, dv_b;
      reg  [15:0] dv_t;
      reg  [15:0] dq_r, dq_g, dq_b;
      reg  [3:0]  dstep;

      // ---- 发射输出寄存（和直通一起在最后的输出块里选择）----
      reg         e_we;
      reg  [31:0] e_addr;
      reg  [15:0] e_px;

      // ---- 本拍是不是"源行在窗口里"的最后一行 ----
      wire row_end   = src_we && c_scale &&
                       (u_cnt == src_w - 16'd1) &&
                       (k_cnt >= c_kl) && (k_cnt < row_hi);
      // ---- 行 DDA 本拍触发（切 bank + 请求发射一个输出行）----
      wire dda_fire  = row_end && (acc_v + TGT_H >= c_sh);
      // ★ 开工前必须等累加单元空下来：最后一个源像素的"读-改-写"要 3 拍，
      //   如果发射抢在它写回之前去读 RAM，那一格就是旧值（少算了最后一行）
      wire emit_go   = (st_e == E_IDLE) && (emit_pend != 4'd0) &&
                       (st_a == A_IDLE) && !acc_pend;
      // 发射通道排空（没在发、也没排队、而且这一拍没在开工）
      // ★ 必须带上 !emit_go：emit_pend 归 0 和 st_e 离开 E_IDLE 是同一拍生效的，
      //   不加这一条，那一拍 emit_idle 会误报为 1，out_done 会提前拉高。
      wire emit_idle = (st_e == E_IDLE) && (emit_pend == 4'd0) && !emit_go;

      //==================================================================
      //  主时序
      //==================================================================
      always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
              cfg_vld     <= 1'b0;
              c_sw        <= 16'd0;
              c_sh        <= 16'd0;
              c_su        <= 16'd0;
              c_kl        <= 16'd0;
              row_hi      <= 16'd0;
              c_scale     <= 1'b0;

              u_cnt       <= 16'd0;
              k_cnt       <= 16'd0;
              px_cnt      <= 32'd0;
              px_total    <= 32'd0;
              frame_run   <= 1'b0;
              e_done      <= 1'b0;
              src_all     <= 1'b0;

              acc_u       <= 32'd0;
              ou          <= 16'd0;
              acc_v       <= 32'd0;
              ok_cur      <= 16'd0;

              bank_cur    <= 1'b0;
              bank_emt    <= 1'b1;

              st_a        <= A_IDLE;
              acc_pend    <= 1'b0;
              pend_ou     <= 16'd0;
              pend_px     <= 16'd0;
              a_idx       <= 13'd0;
              a_we        <= 1'b0;
              a_din       <= 64'd0;

              st_e        <= E_IDLE;
              emit_pend   <= 4'd0;
              emt_idx     <= 16'd0;
              emt_base    <= 32'd0;
              emt_first   <= 1'b1;
              b_idx       <= 13'd0;
              b_we        <= 1'b0;

              dv_r        <= 16'd0;
              dv_g        <= 16'd0;
              dv_b        <= 16'd0;
              dv_t        <= 16'd0;
              dq_r        <= 16'd0;
              dq_g        <= 16'd0;
              dq_b        <= 16'd0;
              dstep       <= 4'd0;

              e_we        <= 1'b0;
              e_addr      <= 32'd0;
              e_px        <= 16'd0;
              err_overrun <= 1'b0;
          end
          else begin
              // ---- 默认 ----
              a_we    <= 1'b0;
              b_we    <= 1'b0;
              e_we    <= 1'b0;
              px_total <= {16'd0, src_w} * {16'd0, src_h};

              //----------------------------------------------------------
              //  帧起点
              //----------------------------------------------------------
              if (start) begin
                  cfg_vld     <= 1'b0;
                  u_cnt       <= 16'd0;
                  k_cnt       <= 16'd0;
                  px_cnt      <= 32'd0;
                  acc_u       <= 32'd0;
                  ou          <= 16'd0;
                  acc_v       <= 32'd0;
                  ok_cur      <= 16'd0;
                  bank_cur    <= 1'b0;
                  bank_emt    <= 1'b1;
                  emit_pend   <= 4'd0;
                  st_e        <= E_IDLE;
                  st_a        <= A_IDLE;
                  acc_pend    <= 1'b0;
                  emt_first   <= 1'b1;
                  frame_run   <= 1'b0;
                  e_done      <= 1'b0;
                  src_all     <= 1'b0;
                  err_overrun <= 1'b0;
              end

              //----------------------------------------------------------
              //  收源像素
              //----------------------------------------------------------
              // 配置：第一个源像素到达【之前】一直跟着 win_* 装载。
              // 这样第一个像素那一拍 c_* 已经是本帧的值，不会漏掉它。
              if (!cfg_vld && !start) begin
                  c_sw    <= win_sw;
                  c_sh    <= win_sh;
                  c_su    <= win_su;
                  c_kl    <= win_kl;
                  row_hi  <= win_kl + win_sh;
                  c_scale <= do_scale;
              end

              if (src_we) begin
                  if (!cfg_vld) begin
                      cfg_vld   <= 1'b1;
                      frame_run <= c_scale;      // 用上一拍已装好的值
                  end

                  if (c_scale) begin
                      //----------------------------------------------
                      //  在窗口内 → 累加
                      //----------------------------------------------
                      if ((u_cnt >= c_su) && (u_cnt < c_su + c_sw) &&
                          (k_cnt >= c_kl) && (k_cnt < row_hi)) begin
                          if (st_a == A_IDLE) begin
                              pend_ou <= ou;
                              pend_px <= src_px;
                              a_idx   <= bank_off(bank_cur) + {1'b0, ou};
                              a_we    <= 1'b0;
                              st_a    <= A_RD;
                          end
                          else begin
                              // 上一个还没写完（正常不会：96 拍够 3 拍用）。
                              // 排一个队，数据也要一起存下来
                              acc_pend <= 1'b1;
                              pend_ou  <= ou;
                              pend_px  <= src_px;
                          end

                          // 列 DDA
                          if (acc_u + TGT_W >= c_sw) begin
                              acc_u <= acc_u + TGT_W - c_sw;
                              ou    <= ou + 16'd1;
                          end
                          else begin
                              acc_u <= acc_u + TGT_W;
                          end
                      end

                      //----------------------------------------------
                      //  行尾
                      //----------------------------------------------
                      if (u_cnt == src_w - 16'd1) begin
                          u_cnt <= 16'd0;
                          acc_u <= 32'd0;
                          ou    <= 16'd0;

                          // 行 DDA（只对窗口内的行推进）
                          if ((k_cnt >= c_kl) && (k_cnt < row_hi)) begin
                              if (acc_v + TGT_H >= c_sh) begin
                                  acc_v    <= acc_v + TGT_H - c_sh;
                                  bank_cur <= ~bank_cur;
                                  bank_emt <= bank_cur;      // 老 bank 是刚攒满的
                              end
                              else begin
                                  acc_v <= acc_v + TGT_H;
                              end

                          end

                          // 下一行才是第一窗口行 → 在它【开始之前】把行 DDA 归零。
                          // ★ 必须是 k_cnt+1，不能是 k_cnt：这一拍是在处理完
                          //   第 k_cnt 行之后，归零要留给下一行用。
                          if (k_cnt + 16'd1 == c_kl) begin
                              acc_v  <= 32'd0;
                              ok_cur <= 16'd0;
                          end

                          k_cnt <= k_cnt + 16'd1;
                      end
                      else begin
                          u_cnt <= u_cnt + 16'd1;
                      end
                  end

                  px_cnt <= px_cnt + 32'd1;
                  if (px_cnt + 32'd1 == px_total) src_all <= 1'b1;
              end
              else if (src_done) begin
                  src_all <= 1'b1;
              end

              // ★ out_done 要等【像素收完】并且【发射通道排空】——
              //   最后一行还在发的时候不能算完，否则后面接的模块会少收一行
              // ★ 必须带 !start：start 那一拍 src_all 还是上一帧的残留值，
              //   不加这一条会把上面刚清掉的 e_done 又设回 1（同一块里后写的赢），
              //   于是第一帧之后 e_done 永远清不掉。
              if (!start && src_all && emit_idle) e_done <= 1'b1;

              //----------------------------------------------------------
              //  发射请求队列
              //----------------------------------------------------------
              // ★ 只有【行 DDA 触发】才请求发射一个输出行，不是每个源行都发
              if (dda_fire && emit_pend == 4'd0 && st_e == E_IDLE)
                  emit_pend <= 4'd1;              // 空着，下一拍直接开工
              else begin
                  emit_pend <= emit_pend + (dda_fire ? 4'd1 : 4'd0) - (emit_go ? 4'd1 : 4'd0);
                  if (dda_fire && emit_pend != 4'd0) err_overrun <= 1'b1;
              end

              //----------------------------------------------------------
              //  累加：读-改-写（3 拍）
              //----------------------------------------------------------
              case (st_a)
              A_IDLE: begin
                  if (acc_pend) begin
                      acc_pend <= 1'b0;
                      a_idx    <= bank_off(bank_cur) + {1'b0, pend_ou};
                      a_we     <= 1'b0;
                      st_a     <= A_RD;
                  end
              end
              A_RD: st_a <= A_WR;
              A_WR: begin
                  a_din <= { a_dout[63:48] + 16'd1,
                             a_dout[47:32] + p_b,
                             a_dout[31:16] + p_g,
                             a_dout[15:0]  + p_r };
                  a_we  <= 1'b1;
                  st_a  <= A_IDLE;
              end
              default: st_a <= A_IDLE;
              endcase

              //----------------------------------------------------------
              //  发射（后台）
              //----------------------------------------------------------
              case (st_e)
              E_IDLE: begin
                  if (emit_go) begin
                      emt_idx  <= 16'd0;
                      if (emt_first) begin
                          emt_base  <= (TGT_H - 1) * TGT_W;
                          emt_first <= 1'b0;
                      end
                      else begin
                          emt_base  <= emt_base - TGT_W;
                      end
                      st_e <= E_RD;
                  end
              end

              E_RD: begin
                  b_idx <= bank_off(bank_emt) + {1'b0, emt_idx};
                  b_we  <= 1'b0;
                  st_e  <= E_RD2;
              end

              E_RD2: st_e <= E_INI;

              E_INI: begin
                  dv_r  <= b_dout[15:0];
                  dv_g  <= b_dout[31:16];
                  dv_b  <= b_dout[47:32];
                  dv_t  <= b_dout[63:48] << 7;
                  dq_r  <= 16'd0;
                  dq_g  <= 16'd0;
                  dq_b  <= 16'd0;
                  dstep <= 4'd7;
                  st_e  <= E_DIV;
              end

              E_DIV: begin
                  if (dv_r >= dv_t) begin dv_r <= dv_r - dv_t; dq_r <= dq_r | (16'd1 << dstep); end
                  if (dv_g >= dv_t) begin dv_g <= dv_g - dv_t; dq_g <= dq_g | (16'd1 << dstep); end
                  if (dv_b >= dv_t) begin dv_b <= dv_b - dv_t; dq_b <= dq_b | (16'd1 << dstep); end
                  dv_t <= dv_t >> 1;
                  if (dstep == 4'd0) st_e <= E_OUT;
                  else               dstep <= dstep - 4'd1;
              end

              E_OUT: begin
                  e_we   <= 1'b1;
                  e_px   <= {dq_r[4:0], dq_g[5:0], dq_b[4:0]};
                  e_addr <= emt_base + {16'd0, emt_idx};
                  b_we   <= 1'b1;                 // 顺手把这一格清零

                  if (emt_idx == TGT_W[15:0] - 16'd1)
                      st_e <= E_IDLE;
                  else begin
                      emt_idx <= emt_idx + 16'd1;
                      st_e    <= E_RD;
                  end
              end

              default: st_e <= E_IDLE;
              endcase

          end
      end

      //==================================================================
      //  输出选择（★ 单独一个块，out_* 只在这里驱动）
      //==================================================================
      always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
              out_we   <= 1'b0;
              out_px   <= 16'd0;
              out_addr <= 32'd0;
              out_done <= 1'b0;
          end
          else if (do_scale) begin
              out_we   <= e_we;
              out_px   <= e_px;
              out_addr <= e_addr;
              out_done <= e_done;
          end
          else begin
              out_we   <= src_we;
              out_px   <= src_px;
              out_addr <= src_addr;
              out_done <= src_done;
          end
      end

  endmodule
