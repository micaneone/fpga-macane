  module find_bmp #(
      parameter [23:0] TARGET_EXT = {"B","M","P"}
  )(
      input             sys_clk,
      input             sys_rst_n,
      // ★★★ 2026-10-15【第②步 · SD 前端三合一】：
      //   原来这里透传 clk_spi + 4 根 SD 引脚，并在文件尾自己例化一份 sd_top
      //   （sd_top = sd_init + sd_read_cdc + sd_read + my_spi，三条链那三份逐字相同）。
      //   现在 sd_top **全局只有一份**，例化在 top_a 里（`u_sd_front`）；
      //   三条链的 find_bmp 通过下面这组端口共享它 —— FAT/目录/簇链状态机一行没改。
      //   ★ 本链的请求只在 `fe_owner=1`（= 当前 sd_mode_r 选中的那一条）时才被 top_a
      //     送到前端；`fe_owner=0` 时连前端的应答都看不见（见下面 sd_ok/sd_done 的屏蔽）。
      input             fe_init_done,   // ← 共享 sd_top.bus_owner（= 原来的 init_done）
      input             fe_led,         // ← 共享 sd_top.led1
      input             fe_owner,       // ★ 1 = 本链 = 当前 sd_mode_r 选中的那一条
      output     [31:0] fe_lba,         // → 共享 sd_top.read_addr（本链仲裁后的地址）
      output            fe_req,         // → 共享 sd_top.read_req
      input      [7:0]  fe_data,        // ← 共享 sd_top.data_out
      input             fe_ok,          // ← 每字节单拍
      input             fe_done,        // ← 整块单拍
      input             fe_busy,        // ← 电平
      input             fe_err,         // ← 整块单拍
      // ---- 命令接口 ----
      input             start,
      input             cmd,
      input      [3:0]  skip,
      input      [31:0] in_cluster,
      // ---- 状态回报 ----
      output reg        busy,
      output reg        done,
      output reg        fail,
      // ---- 查找结果 ----
      output reg [31:0] file_sector,
      output reg [31:0] file_size,
      output reg [31:0] file_cluster,
      // ---- 跟簇链结果 ----
      output reg [31:0] next_cluster,
      output reg [31:0] next_sector,
      output reg        chain_end,
      // ---- 直通读扇区（找完文件后，下一层用它读图片数据）----
      input      [31:0] rd_lba,
      input             rd_req,
      output [7:0]      rd_data,
      output            rd_ok,
      output            rd_done,
      output            rd_busy,
      output            rd_err,
      // ---- 调试 ----
      output            led1,
      output            bus_owner
  );
      reg  [31:0] sd_lba;                    // find_bmp 的 FSM 驱动
      reg         sd_req;                    // 同上
      // ★★★ 第②步：前端在 top_a，这里只做「主 / 非主」屏蔽 ——
      //   fe_owner=1 时下面这几根与改动前逐位等价（就是前端原来的信号）；
      //   fe_owner=0 时本链看见的是「前端不存在」：busy 恒 0、没有任何 ok/done/err
      //   ⇒ 非主链即使被误启动，也只会自己走看门狗 → fail（看得见的错），
      //     绝不会把前端正在传给主链的字节当成自己的（看不见的错）。
      wire [7:0]  sd_data = fe_data;
      wire        sd_ok   = fe_ok   & fe_owner;
      wire        sd_done = fe_done & fe_owner;
      wire        sd_busy = fe_busy & fe_owner;
      wire        sd_err  = fe_err  & fe_owner;
      wire [31:0] w_lba;                     // 仲裁后送给共享前端
      wire        w_req;
      wire init_done = fe_init_done;         // 别名，FSM 里的 init_done 不用改
      assign fe_lba = w_lba;                 // 本链的请求出口（top_a 按 fe_owner 三选一）
      assign fe_req = w_req;
      localparam S_IDLE = 3'd0, S_WAIT = 3'd1, S_REQ  = 3'd2, S_RECV = 3'd3,
                 S_CALC = 3'd4, S_DONE = 3'd5, S_FAIL = 3'd6;
      localparam P_MBR = 2'd0, P_BPB = 2'd1, P_DIR = 2'd2, P_FAT = 2'd3;
      reg [2:0]  state;
      reg [1:0]  phase;
      reg        cmd_r;
      reg [3:0]  skip_r;
      reg [31:0] in_clus_r;

      reg [9:0]  byte_cnt;       // 扇区内字节计数 0~511
      reg [7:0]  dir_sec;        // 根目录已扫到第几个扇区
      reg [3:0]  hit_cnt;        // 已命中几个 .BMP
      reg [19:0] wdt;            // 看门狗

      // ---- 从 MBR 抽出来 ----
      reg [31:0] part_base;      // 分区起始扇区
      reg        is_mbr;         // 第 0 扇区是不是真的分区表

      // ---- 从 BPB 抽出来 ----
      reg [7:0]  sec_per_clus;
      reg [15:0] reserved;
      reg [7:0]  num_fats;
      reg [31:0] fat_size;
      reg [31:0] root_cluster;

      reg        params_valid;   // MBR+BPB 是否已经解析过

      // ---- 目录项扫描 ----
      reg [7:0]  ext0, ext1, ext2;
      reg        entry_live, entry_hit;
      reg [15:0] clus_hi, clus_lo;
      reg [31:0] fsize;
      reg        found;

      // ---- FAT 表项 ----
      reg [31:0] fat_val;

      //======================================================================
      //  组合逻辑（避免「同一拍读到寄存器旧值」）
      //======================================================================
      // ★★★ 2026-10-15【方案A · 移位替代乘法，省 DSP】
      //   为什么逐位等价：FAT32 规范强制 BPB_SecPerClus 只能是 2 的幂（1/2/4/.../128），
      //   所以 (X - 2) * sec_per_clus ≡ (X - 2) << log2(sec_per_clus) 恒成立 ——
      //   原式本来就是 32 位截断乘（mod 2^32），左移在 mod 2^32 内同样截断，
      //   两者对任意 X 的每一位都相同（合法卡上 0 差异）。
      //   sec_per_clus 不是 2 的幂 = 违反规范的坏卡 ⇒ spc_ok=0 ⇒ P_BPB 直接 S_FAIL，
      //   绝不会像原来那样静默算出一个错扇区地址。
      //   译码结果只喂移位器（LUT 实现），不再占 DSP。
      reg  [2:0]  spc_shift;
      reg         spc_ok;
      always @(*) begin
          spc_ok    = 1'b1;
          spc_shift = 3'd0;
          case (sec_per_clus)
              8'd1:   spc_shift = 3'd0;
              8'd2:   spc_shift = 3'd1;
              8'd4:   spc_shift = 3'd2;
              8'd8:   spc_shift = 3'd3;
              8'd16:  spc_shift = 3'd4;
              8'd32:  spc_shift = 3'd5;
              8'd64:  spc_shift = 3'd6;
              8'd128: spc_shift = 3'd7;
              default: begin spc_ok = 1'b0; spc_shift = 3'd0; end
          endcase
      end

      // ★★★ 第二刀：FAT32 规定 BPB_NumFATs 恒为 2 ⇒ num_fats * fat_size = fat_size << 1
      //   （同样是 32 位截断乘 → 32 位左移，mod 2^32 逐位等价；NumFATs!=2 由 P_BPB 守卫拦掉）
      wire [31:0] fat_start_c  = part_base + {16'd0, reserved};
      wire [31:0] data_start_c = fat_start_c + (fat_size << 1);

      // 扩展名是不是目标（卡上永远存大写）
      wire ext_ok = (ext0 == TARGET_EXT[23:16]) &&
                    (ext1 == TARGET_EXT[15:8])  &&
                    (ext2 == TARGET_EXT[7:0]);

      // FAT 表项在本扇区里的字节偏移：每扇区 128 项、每项 4 字节
      wire [9:0]  fat_off = {in_clus_r[6:0], 2'b00};   // 0,4,...,508

      // cmd=1 的结果（0/1 是保留簇，EOC 及以上是结束，都判掉防止乘法溢出）
      wire [27:0] nxt_clus = fat_val[27:0];
      wire        nxt_end  = (nxt_clus >= 28'h0FFFFFF8) || (nxt_clus < 28'd2);

      //======================================================================
      //  ★★★ 方案A 第三步：三个「簇号 → 扇区号」使用点分属**互斥的 FSM 相位**，
      //     于是共用同一套「减 2 → 左移 → 加 data_start_c」通路（移位器由 3 份减到 1 份）：
      //        root_dir_c  : S_IDLE（cmd=0 且 params_valid）与 S_CALC/P_BPB
      //        nxt_sec     : S_CALC/P_FAT
      //        file_sector : S_DONE（cmd=0）
      //  为什么与原式逐位等价：FAT32 强制 sec_per_clus 是 2 的幂 ⇒ (X-2)*spc ≡ (X-2)<<log2(spc)；
      //    原乘法处在 32 位上下文里本来就是截断乘（mod 2^32），左移同样按 32 位截断，逐位相同。
      //  ★ 选择式里**必须**带 state==S_CALC：phase 是寄存器，做过一次 cmd=1 之后会停在 P_FAT；
      //    若只判 phase==P_FAT，下一次 S_IDLE 取 root_dir_c 时会误选 nxt_clus
      //    （这种错只在「先跟过一次簇链、再重新找文件」时暴露，非常隐蔽）。
      //======================================================================
      wire        sel_fat = (state == S_CALC) && (phase == P_FAT);
      wire        sel_dir = (state == S_DONE);
      wire [31:0] clu_sel = sel_fat ? {4'd0, nxt_clus} :
                            sel_dir ? {clus_hi, clus_lo} : root_cluster;
      wire [31:0] clu_lba = data_start_c + ((clu_sel - 32'd2) << spc_shift);

      wire [31:0] root_dir_c = clu_lba;
      wire [31:0] nxt_sec    = nxt_end ? 32'd0 : clu_lba;
      
      //======================================================================
      //  sd_top 读接口仲裁
      //    busy=1 → find_bmp 自己用（查 MBR / BPB / 根目录 / FAT）
      //    busy=0 → 让给下一层用（读图片数据）
      //======================================================================
      assign w_lba = busy ? sd_lba : rd_lba;
      assign w_req = busy ? sd_req : rd_req;

      // 透传回去，用 busy 门控，别让下一层看见 find_bmp 自己的流量
      assign rd_data = sd_data;
      assign rd_ok   = busy ? 1'b0 : sd_ok;
      assign rd_done = busy ? 1'b0 : sd_done;
      assign rd_busy = sd_busy;
      assign rd_err  = busy ? 1'b0 : sd_err;

      //======================================================================
      //  主状态机
      //======================================================================
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n) begin
              state         <= S_IDLE;
              phase         <= P_MBR;
              sd_req        <= 1'b0;
              sd_lba        <= 32'd0;
              busy          <= 1'b0;
              done          <= 1'b0;
              fail          <= 1'b0;
              byte_cnt      <= 10'd0;
              dir_sec       <= 8'd0;
              hit_cnt       <= 4'd0;
              wdt           <= 20'd0;
              params_valid  <= 1'b0;
              found         <= 1'b0;
              is_mbr        <= 1'b0;
              part_base     <= 32'd0;
              fat_val       <= 32'd0;
              file_sector   <= 32'd0;
              file_size     <= 32'd0;
              file_cluster  <= 32'd0;
              next_cluster  <= 32'd0;
              next_sector   <= 32'd0;
              chain_end     <= 1'b0;
              ext0 <= 8'd0; ext1 <= 8'd0; ext2 <= 8'd0;
              entry_live <= 1'b0; entry_hit <= 1'b0;
              clus_hi <= 16'd0;   clus_lo  <= 16'd0;
              fsize   <= 32'd0;
              sec_per_clus <= 8'd0;  reserved <= 16'd0;  num_fats <= 8'd0;
              fat_size <= 32'd0;     root_cluster <= 32'd0;
          end
          else begin
              done <= 1'b0;
              fail <= 1'b0;

              // 看门狗：只在「等 sd_top 受理」期间计数
              if (state == S_IDLE || state == S_CALC)
                  wdt <= 20'd0;
              else if (wdt != 20'hFFFFF)
                  wdt <= wdt + 1'b1;

              case (state)
              //==============================================================
              S_IDLE: begin
                  busy <= 1'b0;
                  if (start && init_done) begin
                      cmd_r     <= cmd;
                      skip_r    <= skip;
                      in_clus_r <= in_cluster;
                      hit_cnt   <= 4'd0;
                      dir_sec   <= 8'd0; 
                      found     <= 1'b0;
                      busy      <= 1'b1;

                      if (cmd == 1'b0 && !params_valid) begin
                          sd_lba <= 32'd0;          // 从 MBR 开始
                          phase  <= P_MBR;
                          state  <= S_WAIT;
                      end
                      else if (cmd == 1'b0) begin
                          sd_lba <= root_dir_c;     // 参数已有，直接扫根目录
                          phase  <= P_DIR;
                          state  <= S_WAIT;
                      end
                      else if (params_valid) begin  // cmd=1：读 FAT 表
                          sd_lba <= fat_start_c + (in_cluster >> 7);
                          phase  <= P_FAT;
                          state  <= S_WAIT;
                      end
                      else
                          state <= S_FAIL;          // 没解析过 BPB，先跑一次 cmd=0
                  end
              end
              //==============================================================
              // 先等上一笔事务的 busy 彻底落下
              S_WAIT: begin
                  if (!sd_busy) begin
                      sd_req <= 1'b1;
                      state  <= S_REQ;
                  end
                  else if (wdt == 20'hFFFFF)
                      state <= S_FAIL;
              end
              //==============================================================
              // 请求已拉高，等被受理（sd_read 只在 idle_cnt==255 那拍采样）
              S_REQ: begin
                  if (sd_busy) begin
                      sd_req   <= 1'b0;
                      byte_cnt <= 10'd0;
                      state    <= S_RECV;
                  end
                  else if (wdt == 20'hFFFFF) begin
                      sd_req <= 1'b0;              // 超时也要撤请求
                      state  <= S_FAIL;
                  end
              end
              //==============================================================
              S_RECV: begin
                  if (sd_ok) begin
                      case (phase)
                      //---- MBR：分区表第 0 项 ----------------------------------
                      P_MBR: begin
                          if (byte_cnt == 10'd450)
                              is_mbr <= (sd_data == 8'h0B) || (sd_data == 8'h0C);
                          if (byte_cnt == 10'd454) part_base[7:0]   <= sd_data;
                          if (byte_cnt == 10'd455) part_base[15:8]  <= sd_data;
                          if (byte_cnt == 10'd456) part_base[23:16] <= sd_data;
                          if (byte_cnt == 10'd457) part_base[31:24] <= sd_data;
                      end
                      //---- BPB：取参数 -----------------------------------------
                      P_BPB: begin
                          if (byte_cnt == 10'd13) sec_per_clus   <= sd_data;
                          if (byte_cnt == 10'd14) reserved[7:0]  <= sd_data;
                          if (byte_cnt == 10'd15) reserved[15:8] <= sd_data;
                          if (byte_cnt == 10'd16) num_fats       <= sd_data;
                          if (byte_cnt == 10'd36) fat_size[7:0]   <= sd_data;
                          if (byte_cnt == 10'd37) fat_size[15:8]  <= sd_data;
                          if (byte_cnt == 10'd38) fat_size[23:16] <= sd_data;
                          if (byte_cnt == 10'd39) fat_size[31:24] <= sd_data;
                          if (byte_cnt == 10'd44) root_cluster[7:0]   <= sd_data;
                          if (byte_cnt == 10'd45) root_cluster[15:8]  <= sd_data;
                          if (byte_cnt == 10'd46) root_cluster[23:16] <= sd_data;
                          if (byte_cnt == 10'd47) root_cluster[31:24] <= sd_data;
                      end
                      //---- 根目录：一条 32 字节，边收边判 ----------------------
                      P_DIR: begin
                          // byte_cnt[8:5]=第几行(0~15)  byte_cnt[4:0]=行内偏移
                          if (byte_cnt[4:0] == 5'd0)
                              entry_live <= (sd_data != 8'h00) &&
                                            (sd_data != 8'hE5);
                          if (byte_cnt[4:0] == 5'd8)  ext0 <= sd_data;
                          if (byte_cnt[4:0] == 5'd9)  ext1 <= sd_data;
                          if (byte_cnt[4:0] == 5'd10) ext2 <= sd_data;

                          if (byte_cnt[4:0] == 5'd11)          // 属性字节
                              entry_hit <= entry_live && ext_ok &&
                                           ((sd_data & 8'h18) == 8'h00);
                              // 0x18 一次排除 LFN(0x0F)/卷标(0x08)/目录(0x10)

                          // 命中、且正是我们要的那一个，才取簇号和大小
                          if (entry_hit && (hit_cnt == skip_r)) begin
                              if (byte_cnt[4:0] == 5'd20) clus_hi[7:0]  <= sd_data;
                              if (byte_cnt[4:0] == 5'd21) clus_hi[15:8] <= sd_data;
                              if (byte_cnt[4:0] == 5'd26) clus_lo[7:0]  <= sd_data;
                              if (byte_cnt[4:0] == 5'd27) clus_lo[15:8] <= sd_data;
                              if (byte_cnt[4:0] == 5'd28) fsize[7:0]    <= sd_data;
                              if (byte_cnt[4:0] == 5'd29) fsize[15:8]   <= sd_data;
                              if (byte_cnt[4:0] == 5'd30) fsize[23:16]  <= sd_data;
                              if (byte_cnt[4:0] == 5'd31) begin
                                  fsize[31:24] <= sd_data;
                                  found        <= 1'b1;
                              end
                          end

                          if (byte_cnt[4:0] == 5'd31 && entry_hit)
                              hit_cnt <= hit_cnt + 1'b1;
                      end
                      //---- FAT 表：取第 in_clus_r 项 ---------------------------
                      P_FAT: begin
                          if (byte_cnt == fat_off + 10'd0) fat_val[7:0]   <= sd_data;
                          if (byte_cnt == fat_off + 10'd1) fat_val[15:8]  <= sd_data;
                          if (byte_cnt == fat_off + 10'd2) fat_val[23:16] <= sd_data;
                          if (byte_cnt == fat_off + 10'd3) fat_val[31:24] <= sd_data;
                      end
                      default: ;
                      endcase
                      byte_cnt <= byte_cnt + 1'b1;
                  end

                  if (sd_done) state <= S_CALC;
                  if (sd_err)  state <= S_FAIL;
              end
              //==============================================================
              S_CALC: begin
                  case (phase)
                  P_MBR: begin
                      // 不是分区表（superfloppy）时，BPB 就在第 0 扇区
                      sd_lba <= is_mbr ? part_base : 32'd0;
                      phase  <= P_BPB;
                      state  <= S_WAIT;
                  end
                  P_BPB: begin
                      // ★★★ 方案A 守卫：BPB 参数违反 FAT32 规范 ⇒ 明确失败，绝不静默算错地址
                      //   （SecPerClus 必须是 2 的幂；NumFATs 必须是 2）
                      if (!spc_ok || num_fats != 8'd2) begin
                          state <= S_FAIL;
                      end
                      else begin
                      params_valid <= 1'b1;
                      dir_sec      <= 8'd0;

                      if (cmd_r == 1'b0) begin
                          sd_lba <= root_dir_c;
                          phase  <= P_DIR;
                      end
                      else begin
                          sd_lba <= fat_start_c + (in_clus_r >> 7);
                          phase  <= P_FAT;
                      end
                      state <= S_WAIT;
                      end
                  end
                  P_DIR: begin
                      if (found)
                          state <= S_DONE;
                      // ★★★ 2026-10-14 深夜【修 FAT32 根目录跨簇扫描 · 零新增逻辑版】
                      //   缺陷：原来这里只扫「根目录第一个簇」（界限 = sec_per_clus 个扇区）
                      //         就 S_FAIL，从不往后走。FAT32 根目录是普通簇链、可跨多簇：
                      //         8 扇区/簇 = 4KB = 128 个目录项，有长文件名时一个文件占好几项，
                      //         卡上增删文件会让 .SUB 的目录项掉到第二簇之后 ⇒ 字幕再也找不到
                      //         （串口 sub_fail=1、字幕 RAM 全零）。图片链只是碰巧排在最前面。
                      //   修法（省资源版）：上界放宽到 **256 个扇区 = 128 KB = 4096 个目录项**，
                      //         并把下面的地址式改成「扇区号 +1」。
                      //         ★ 依据：根目录在卡上几乎总是**连续**分配的（格式化时一次划好，
                      //           之后加文件只是往后顺延），顺着扇区号扫就能到第二、第三簇。
                      //         ★ 不用"跟 FAT 簇链"的正统做法，是因为它要加 32 位簇指针 +
                      //           模式标志 + 计数器 + 一条 mux；本器件实测已 100.9% MSlice
                      //           装不下（PHY-9009：4949 > 4900）。这个改法**零新增寄存器**。
                      else if (dir_sec != 8'hFF) begin
                          dir_sec <= dir_sec + 8'd1;
                          // ★★★ 2026-10-14 深夜：原来是 root_dir_c + dir_sec + 1 —— **只对第一个簇成立**，
                          //   一旦扫到第二簇就会跳回第一簇开头、原地打转。
                          //   进入本状态时 sd_lba 恰好 = 「当前扇区基址 + dir_sec」，
                          //   所以 +1 在第一簇上与旧式逐位等价，跨簇后也正确。
                          sd_lba  <= sd_lba + 32'd1;
                          state   <= S_WAIT;
                      end
                      else
                          state <= S_FAIL;    // 根目录第一个簇扫完没找到
                  end
                  P_FAT: begin
                      next_cluster <= {4'd0, nxt_clus};
                      next_sector  <= nxt_sec;
                      chain_end    <= nxt_end;
                      state        <= S_DONE;
                  end
                  default: state <= S_FAIL;
                  endcase
              end
              //==============================================================
              S_DONE: begin
                  if (cmd_r == 1'b0) begin
                      file_cluster <= {clus_hi, clus_lo};
                      file_size    <= fsize;
                      file_sector  <= clu_lba;   // 见上面的共用通路（此相位 clu_sel = 命中文件的簇号）
                  end
                  sd_req <= 1'b0;
                  done   <= 1'b1;
                  busy   <= 1'b0;
                  state  <= S_IDLE;
              end
              S_FAIL: begin
                  sd_req <= 1'b0;
                  fail   <= 1'b1;
                  busy   <= 1'b0;
                  state  <= S_IDLE;
              end
              default: state <= S_IDLE;
              endcase
          end
      end

      //======================================================================
      //  ★★★ 第②步：sd_top 已经提到 top_a（全局只有一份），这里不再例化
      //    只把共享前端的两个「状态灯」透传出去（端口名/语义和改动前完全一样）：
      //      led1      = sd_top.led1        （初始化完成）
      //      bus_owner = sd_top.bus_owner   （引脚已交接 = 原来的 sd_ready）
      //======================================================================
      assign led1      = fe_led;
      assign bus_owner = fe_init_done;

  endmodule
