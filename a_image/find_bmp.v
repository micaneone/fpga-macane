//==========================================================================
//  find_bmp.v —— ★★★ 2026-10-16【切法C·find_bmp 合流】
//
//  本文件里现在有【两个】模块：
//
//    ① find_bmp        —— 薄壳（每链一份，例化在 bmp_analyze / wav_analyze /
//                          sub_analyze 里）。只做三件事：
//                           · sd_top 直通读的让位仲裁（busy ? 引擎地址 : rd_lba）
//                           · 把前端的应答按 fe_owner 屏蔽后回给父模块（一字未改）
//                           · 把"查文件"的请求/结果引到模块口上（eng_*）
//                         它【不再含】任何 FAT/目录状态机。
//
//    ② find_bmp_eng    —— FAT/目录索引状态机本体（★ 全局只有一份，
//                          例化在 top_a 里 = `u_find_eng`）。原来三份逐字相同的
//                          FSM（只是 TARGET_EXT 和 skip 不同）现在合成一份，
//                          扩展名/skip 走请求接口，由请求方在 start 那拍带过来。
//
//  【为什么可以只用一份】三条链查文件天然互斥：
//    · 上电顺序 图 → 音频 → 字幕 是串行的；
//    · top_a 用**组合的** sd_mode 分 start（一次只有一条链拿到 start），
//      而且一次 SD 事务期间 top_a 只把当家那条链的请求送到前端；
//    · 引擎内部对非当家链把 fe_* 全部门控成 0 ⇒ 就算两条链同时被误启动，
//      非当家那条也只会自己走看门狗 ⇒ fail（看得见的错），
//      绝不会把主链正在收的字节当成自己的（看不见的错）。
//
//  【两条修复自动对三条链生效】
//    ① 根目录跨簇扫描（上界 256 扇区 + sd_lba+1）
//    ② 簇地址 = log2 译码 + 左移（含 spc_ok / num_fats!=2 ⇒ fail 守卫）
//==========================================================================
//==========================================================================
//  ① find_bmp —— 薄壳：sd_top 直通读让位 + 共享引擎的请求/结果口
//==========================================================================
  module find_bmp #(
      parameter [23:0] TARGET_EXT = {"B","M","P"},  // ★ 只用来给引擎挑扩展名
      // ★★★ 2026-10-20【找图逻辑·按名字分类（A 轨 10-20 交付，移植到共享引擎）】：
      //   NAME_EN = 0 ⇒ 只比后缀（老行为，逐位不变；名字比较整段被综合删掉）
      //   NAME_EN = 1 ⇒ 后缀 + 文件名前缀都要对（第 0~7 字节）
      parameter        NAME_EN    = 1'b0
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
      input             name_sel,       // ★ 0 = 找 NAME0（"AD"），1 = 找 NAME1（"MAP"）
      input             name_inv,       // ★ 2026-10-21：1 = 反选（要求不以 NAME1 开头）
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
      output            bus_owner,
      //======================================================================
      //  ★★★ 2026-10-16【切法C·find_bmp 合流】：跟共享引擎（u_find_eng）的请求/结果口
      //    —— 父模块要把这 8 根原样引到顶层，由 top_a 接到唯一那份 find_bmp_eng 上。
      //======================================================================
      output [23:0]     eng_ext,        // → 引擎：本链要找的扩展名（常数量，无逻辑）
      output [3:0]      eng_skip,       // → 引擎：本链的 skip（引擎在 start 那拍锁存）
      output            eng_name_en,    // ★ → 引擎：本链要不要比文件名（= NAME_EN，常数）
      output            eng_name_sel,   // ★ → 引擎：0 = AD 类，1 = MAP 类（NAME_EN=0 时为 0）
      output            eng_name_inv,   // ★ 2026-10-21 → 引擎：1 = 反选
      output            eng_start,      // → 引擎：本链要查文件（= 原 f_start 的语义）
      output            eng_owner,      // → 引擎：1 = 本链当家（= fe_owner）
      input      [31:0] eng_lba_i,      // ← 引擎：引擎自己算的扇区地址
      input             eng_req_i,      // ← 引擎：引擎自己的读请求
      input             eng_done,       // ← 引擎：查到了（已打拍）
      input             eng_fail,       // ← 引擎：查不到 / 卡 / 坏卡（已按 owner 门控）
      input      [31:0] eng_sector,     // ← 引擎：file_sector（已打拍、已按 owner 门控）
      input      [31:0] eng_size,       // ← 引擎：file_size  （已打拍、已按 owner 门控）
      input      [31:0] eng_cluster,    // ← 引擎：file_cluster（已打拍、已按 owner 门控）
      input             eng_busy        // ← 引擎：引擎自己的 busy（直通读让位用）
  );
      //======================================================================
      //  引擎请求口：全是直连，零逻辑
      //======================================================================
      assign eng_ext   = TARGET_EXT;    // 参数是常量 ⇒ 综合成 tie-off，不占 LUT
      assign eng_skip  = skip;
      // ★ NAME_EN=0 ⇒ 恒 0，引擎里名字比较整段被综合掉（音频/字幕两条链 0 LUT）
      assign eng_name_en  = NAME_EN ? 1'b1 : 1'b0;
      assign eng_name_sel = NAME_EN ? name_sel : 1'b0;
    assign eng_name_inv = NAME_EN ? name_inv : 1'b0;
      assign eng_start = start;
      assign eng_owner = fe_owner;

      //======================================================================
      //  sd_top 读接口仲裁（★ 与原版逐位含义相同）
      //    eng_use=1 → 引擎正在查文件（用引擎自己算的 MBR/BPB/目录/FAT 扇区）
      //    eng_use=0 → 让给下一层用（读图片 / 音频 / 字幕数据）
      //  ★ 原版是 `busy ? sd_lba : rd_lba`，busy 就是引擎 FSM 的 busy。
      //  ★★★ 2026-10-17【修正 · 假面积的真正根因】这里原来写的是
      //     `eng_use = eng_busy | eng_owner`，而 `eng_owner` 被赋成 `fe_owner`
      //     （= 本链被选中的电平）⇒ 展开后
      //        rd_ok = ¬eng_use ∧ fe_ok ∧ fe_owner
      //              = ¬(eng_busy | fe_owner) ∧ fe_ok ∧ fe_owner  **≡ 0**
      //     （rd_done / rd_err 同理，是**可证明的恒 0**，不是仿真才看得出的错）
      //     ⇒ 三条链"直通读图片/音频/字幕数据"这条路永远完不成 ⇒ 分析器 FSM 被
      //       综合器证明死掉 ⇒ 整条 A 轨连同下游显示/音频一起被折平。
      //       那一轮实测的 "LUT 4820 / DSP 0 / BRAM 14 / 29.87%" 就是它
      //       （`README_atrack_reverted.md` 把这现象归因于"显示缩放通路被常数传播"，
      //        只是表象；真正被折的是 A 轨的直通读握手）。
      //  ★ 正确口径 = 原版：只用**引擎自己的 busy**。start 那一拍 busy 还是 0，
      //    但父模块此时在 B_FIND、rd_lba 恒 0 ⇒ 与 `busy|start` 选出的地址逐位相同。
      //  ★ 本链选完以后仍然要 top_a 按 sd_mode_r 三选一才进前端
      //    （和 fe_data 广播那套完全对称，红线：一次事务只有一条链上送）。
      //======================================================================
      wire eng_use = eng_busy;

      assign fe_lba = eng_use ? eng_lba_i : rd_lba;
      assign fe_req = eng_use ? eng_req_i : rd_req;

      // 透传回去，用 eng_use 门控，别让下一层看见引擎自己的流量
      //   ★ fe_ok/fe_done/fe_err 的 `& fe_owner` 屏蔽与原版一字未改
      assign rd_data = fe_data;
      assign rd_ok   = eng_use ? 1'b0 : (fe_ok   & fe_owner);
      assign rd_done = eng_use ? 1'b0 : (fe_done & fe_owner);
      assign rd_busy = fe_busy & fe_owner;
      assign rd_err  = eng_use ? 1'b0 : (fe_err  & fe_owner);

      //======================================================================
      //  状态 / 结果打拍
      //    ★ 为什么必须寄存：引擎的 res_* 是**组合**出来的，而 done 是寄存的。
      //      原版里父模块在 `f_done` 那一拍取 f_sector/f_size，取到的就是引擎
      //      寄存器输出（同一拍有效）；现在引擎的结果是组合量 ⇒ 必须先在
      //      top_a 打一拍、再由 top_a 把 done 一起发出来，
      //      这样父模块看到的 (f_done, f_sector, f_size) 相对关系与原版一致。
      //    ★ busy 用 eng_busy（电平）而不用 eng_busy|done：原版 busy 在
      //      S_DONE 那一拍就掉了，done 与 busy 同拍，所以这里也不同拍。
      //======================================================================
      always @(posedge sys_clk or negedge sys_rst_n) begin
          if (!sys_rst_n) begin
              busy          <= 1'b0;
              done          <= 1'b0;
              fail          <= 1'b0;
              file_sector   <= 32'd0;
              file_size     <= 32'd0;
              file_cluster  <= 32'd0;
              next_cluster  <= 32'd0;
              next_sector   <= 32'd0;
              chain_end     <= 1'b0;
          end
          else begin
              done  <= 1'b0;
              fail  <= 1'b0;
              busy  <= eng_busy;                    // 电平：引擎正在查文件
              if (eng_done) begin
                  file_sector  <= eng_sector;
                  file_size    <= eng_size;
                  file_cluster <= eng_cluster;
                  done         <= 1'b1;
              end
              if (eng_fail) fail <= 1'b1;
              // ★ cmd=1（跟簇链）三条链都恒为 0 ⇒ next_cluster/next_sector/chain_end
              //   永远是复位值，只为端口兼容（合成器会把这些死寄存器摘掉）
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


//==========================================================================
//  ② find_bmp_eng —— FAT/目录索引状态机本体（★ 全局唯一一份）
//
//  这是原来三份 find_bmp 里那份逐字相同的 FSM，一字未改，只做了两处接口搬家：
//    · TARGET_EXT 从 parameter 变成运行时端口 `target_ext`
//      （每链要什么不一样，合并后必须由请求方带过来，引擎在 start 那拍锁存）
//    · fe_lba/fe_req 不再由本模块直接驱动：引擎把「引擎自己算的地址」
//      （eng_lba/eng_req）交回薄壳，由薄壳与直通读地址仲裁后再上送。
//  另外把 `rd_*` 直通搬回薄壳，所以引擎这里只保留"引擎自己忙"这一根 `eng_busy`。
//==========================================================================
  module find_bmp_eng #(
      // ★★★ 2026-10-20【按名字分类】：0x00 字节 = 通配（前缀匹配），所以 "AD" 匹配
      //   AD.BMP / AD2.BMP / ADIMG.BMP；小写参数自动转大写在下面 nm_u 里做。
      parameter [63:0] NAME0 = 64'h4144_0000_0000_0000,   // "A","D"
      parameter [63:0] NAME1 = 64'h4D41_5000_0000_0000    // "M","A","P"
  )(
      input             sys_clk,
      input             sys_rst_n,
      // ---- 共享前端应答（广播）----
      input             fe_init_done,   // ← 共享 sd_top.bus_owner
      input      [7:0]  fe_data,        // ← 共享 sd_top.data_out
      input             fe_ok,          // ← 每字节单拍
      input             fe_done,        // ← 整块单拍
      input             fe_busy,        // ← 电平
      input             fe_err,         // ← 整块单拍
      // ---- 请求：谁在查、查什么 ----
      input             start,          // 单拍：开始查（top_a 已按 sd_mode 选中）
      input             owner,          // ★ 1 = 发起者就是当家链（top_a 用 sd_mode_r 算）
      input      [23:0] target_ext,     // ★ 要找的扩展名（合并后由请求方带）
      input             name_en,        // ★ 1 = 还要比文件名（只有图像链会拉高）
      input             name_sel,       // ★ 0 = NAME0（"AD"），1 = NAME1（"MAP"）
      input             name_inv,       // ★ 2026-10-21：1 = 反选（要求【不以】NAME1 开头）
      input             cmd,
      input      [3:0]  skip,
      input      [31:0] in_cluster,
      // ---- 状态 ----
      output reg        busy,           // 引擎正在查文件（电平 → eng_busy）
      output reg        done,           // 单拍：查到了
      output reg        fail,           // 单拍：没查到 / 卡 / 坏卡
      // ---- 引擎自己的读请求（薄壳拿去做让位仲裁）----
      output     [31:0] eng_lba,
      output            eng_req,
      output            eng_busy,       // 引擎正在查文件（电平）
      // ---- 结果（组合，由 top_a 打拍后广播）----
      output     [31:0] eng_res_sector,
      output     [31:0] eng_res_size,
      output     [31:0] eng_res_cluster,
      output            eng_res_done,
      output            eng_res_fail
  );
      reg  [31:0] sd_lba;                    // find_bmp_eng 的 FSM 驱动
      reg         sd_req;                    // 同上
      // ★★★ 切法C：前端在 top_a，这里只做「主 / 非主」屏蔽 ——
      //   owner=1 时下面这几根与改动前逐位等价（就是前端原来的信号）；
      //   owner=0 时引擎看见的是「前端不存在」：busy 恒 0、没有任何 ok/done/err
      //   ⇒ 非主链即使被误启动，也只会自己走看门狗 → fail（看得见的错），
      //     绝不会把前端正在传给主链的字节当成自己的（看不见的错）。
      //   ★ 切法C：owner 由 top_a 用组合 sd_mode 算出来（同一次查文件期间恒定），
      //     start 那拍锁存进 owner_r；下面四根用它门控 ⇒ 物理形式仍然是
      //     「fe_ok & <常量>」，与原版逐位等价。
      //   ★ 声明前置（这个工程踩过"先用后声明"）：sd_* 与 owner_r 都放最前面
      reg         owner_r;        // ★ 切法C：start 那拍锁存"本链当家"
      wire [7:0]  sd_data  = fe_data;
      wire        sd_ok    = fe_ok   & owner_r;
      wire        sd_done  = fe_done & owner_r;
      wire        sd_busy  = fe_busy & owner_r;
      wire        sd_err   = fe_err  & owner_r;
      wire        init_done = fe_init_done;  // 别名，FSM 里的 init_done 不用改
      localparam S_IDLE = 3'd0, S_WAIT = 3'd1, S_REQ  = 3'd2, S_RECV = 3'd3,
                 S_CALC = 3'd4, S_DONE = 3'd5, S_FAIL = 3'd6;
      localparam P_MBR = 2'd0, P_BPB = 2'd1, P_DIR = 2'd2, P_FAT = 2'd3;
      reg [2:0]  state;
      reg [1:0]  phase;
      reg        cmd_r;
      reg [3:0]  skip_r;
      reg [31:0] in_clus_r;
      reg [23:0] ext_r;          // ★ 切法C：start 那拍锁存请求方的扩展名
      reg        name_en_r;      // ★ 2026-10-20：start 那拍锁存"要不要比名字"
      reg        name_sel_r;     // ★ 2026-10-20：start 那拍锁存"AD 类 / MAP 类"
    reg        name_inv_r;     // ★ 2026-10-21：start 那拍锁存"要不要反选"
      reg        name_ok;        // ★ 2026-10-20：目录项第 0~7 字节的名字前缀比较结果

      reg [9:0]  byte_cnt;       // 扇区内字节计数 0~511
      reg [7:0]  dir_sec;        // 根目录已扫到第几个扇区
      reg [3:0]  hit_cnt;        // 已命中几个同扩展名文件
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

      // 扩展名是不是目标（卡上永远存大写）—— ★ 切法C：改用锁存后的 ext_r
      wire ext_ok = (ext0 == ext_r[23:16]) &&
                    (ext1 == ext_r[15:8])  &&
                    (ext2 == ext_r[7:0]);

      //==========================================================================
      //  ★★★ 2026-10-20【找图逻辑·按名字分类】：目录项第 0~7 字节（8.3 的主名）
      //    · NAME0/NAME1 里没写满的字节是 0x00 = 通配 ⇒ "AD" 能匹配 AD.BMP / AD2.BMP
      //    · 卡上永远大写；参数写小写在这里自动转（只影响第 5~7 位，几颗 LUT）
      //    · name_en_r=0（音频/字幕链）⇒ name_ok 不参与判断，整段被综合删掉
      //==========================================================================
      wire [7:0] nb0  = NAME0[63 - byte_cnt[2:0]*8 -: 8];
      wire [7:0] nb1  = NAME1[63 - byte_cnt[2:0]*8 -: 8];
      wire [7:0] nm_b = name_sel_r ? nb1 : nb0;
      wire [7:0] nm_u = (nm_b >= 8'h61 && nm_b <= 8'h7A) ? (nm_b - 8'd32) : nm_b;
      wire       nm_eq = (nm_b == 8'h00) ? 1'b1 : (sd_data == nm_u);

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
      //  状态 / 结果输出
      //    ★ eng_busy = FSM 的 busy（电平）。薄壳用它做直通读让位仲裁，
      //      top_a 用它 + sd_mode_r 算 owner。
      //    ★ 结果只在 S_DONE 那一拍有意义（和原版 file_sector 同一拍）。
      //======================================================================
      assign eng_lba         = sd_lba;
      assign eng_req         = sd_req;
      assign eng_busy        = busy;
      // ★★★ 2026-10-17【修正 · 查到了却读不到数据】
      //   原来这里直接输出组合量 `clu_lba`，而 `clu_lba` 只有 `state==S_DONE` 那一拍有效
      //   （`sel_dir = (state == S_DONE)`）。但 `done` 是**寄存器**、下一拍才高，而 S_DONE
      //   同一拍就把 state 打回 S_IDLE ⇒ top_a 在看到 `eng_res_done` 时采到的
      //   `clu_lba` 已经退回 `root_dir_c`（根目录簇的扇区）⇒ **文件首扇区地址是错的**，
      //   分析器照着错地址读一整帧垃圾、最后走看门狗 → fail。
      //   HEAD 版是在 S_DONE 那一拍用 `file_sector <= clu_lba` 锁存的，所以没有这个问题。
      //   修法：在 S_DONE 把三个结果一起锁存，输出改用寄存器（与 done 同拍有效）。
      reg  [31:0] res_sector_r, res_size_r, res_cluster_r;

      assign eng_res_sector  = res_sector_r;
      assign eng_res_size    = res_size_r;
      assign eng_res_cluster = res_cluster_r;
      assign eng_res_done    = done;
      assign eng_res_fail    = fail;

      //======================================================================
      //  主状态机（★ 与原 find_bmp 逐字相同，只多了 ext_r / owner_r 锁存）
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
              ext0 <= 8'd0; ext1 <= 8'd0; ext2 <= 8'd0;
              ext_r <= 24'd0;
              owner_r <= 1'b0;
              entry_live <= 1'b0; entry_hit <= 1'b0;
              clus_hi <= 16'd0;   clus_lo  <= 16'd0;
              fsize   <= 32'd0;
              res_sector_r  <= 32'd0;
              res_size_r    <= 32'd0;
              res_cluster_r <= 32'd0;
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
                      ext_r     <= target_ext;   // ★ 切法C：本拍锁存请求方的扩展名
                      name_en_r <= name_en;      // ★ 2026-10-20：锁存"本链要不要比名字"
                      name_sel_r<= name_sel;     // ★ 2026-10-20：锁存"AD 类 / MAP 类"
        name_inv_r<= name_inv;     // ★ 2026-10-21
                      owner_r   <= owner;        // ★ 切法C：本拍锁存"发起者当家"
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

                          // ★ 2026-10-20：名字前缀（第 0~7 字节）累加比较
                          if (byte_cnt[4:0] == 5'd0)      name_ok <= nm_eq;
                          else if (byte_cnt[4:0] <= 5'd7) name_ok <= name_ok && nm_eq;

                          if (byte_cnt[4:0] == 5'd8)  ext0 <= sd_data;
                          if (byte_cnt[4:0] == 5'd9)  ext1 <= sd_data;
                          if (byte_cnt[4:0] == 5'd10) ext2 <= sd_data;

                          if (byte_cnt[4:0] == 5'd11)          // 属性字节
                              entry_hit <= entry_live && ext_ok &&
                                           (!name_en_r || (name_inv_r ? !name_ok : name_ok)) &&
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
                      state <= S_DONE;        // ★ cmd=1 三链恒不用：只保留状态迁移
                  end
                  default: state <= S_FAIL;
                  endcase
              end
              //==============================================================
              S_DONE: begin
                  // ★ 结果必须在这里锁存（原因见上面 res_sector_r 那段注释）
                  res_sector_r  <= clu_lba;
                  res_size_r    <= fsize;
                  res_cluster_r <= {clus_hi, clus_lo};
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

  endmodule
