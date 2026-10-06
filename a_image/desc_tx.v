 //  desc_tx —— 组装源图描述符，提交给 desc_rx
  //==========================================================================
  //
  //  位置：   bmp2sdram ──frame_done──► desc_tx ──a_desc/a_commit_tgl──► desc_rx
  //  时钟域： 50 MHz（和 desc_rx 的 A 侧同域）
  //
  //  ★ 给 desc_rx 的用法（三步，desc_rx 文件头里定的）：
  //     1) 拼好 a_desc
  //     2) 翻 a_commit_tgl；从翻之前到收到 ack 之前，a_desc 必须一动不动
  //     3) 等 a_ack_tgl 翻转 → 这份表生效了，才能改下一份
  //     ★ 一次提交等一个 ack，不要连翻两次
  //
  //  ★ 只改【目标槽】，其他槽原样保留
  //     这是双缓冲的关键：装槽 0 的时候，槽 1 里正在显示的那张不能被你弄没了
  //
  //  ★ 位段（与 desc_rx 一致，定义在 common\artwork_def.v 第五节）：
  //     [63:57] 补零   [56:49] img_no   [48:37] src_h   [36:25] src_w
  //     [24:4]  base   [3:2]   format   [1] transposed [0] valid
  //==========================================================================
  module desc_tx #(
      parameter integer SLOT_NUM = 2
  )(
      input             clk_ctl,
      input             rst_ctl_n,

      // ---- 从 bmp2sdram 来 ----
      input             frame_done,       // 单拍：整帧写进 SDRAM 了

      // ---- 图片信息 ----
      input      [15:0] img_width,
      input      [15:0] img_height,
      input      [7:0]  img_no,           // 第几张
      input       [2:0]     use_slot,         // 0 = 写槽 0，1 = 写槽 1
      input      [20:0] slot_base,        // 这个槽的帧缓冲基址（字地址）

      // ---- 去 desc_rx ----
      output reg [SLOT_NUM*64-1:0] a_desc,
      output reg        a_commit_tgl,
      input             a_ack_tgl,

      // ---- 状态回报 ----
      output reg        busy,             // 1 = 正在提交 / 等 ack
      output reg        ready_pulse,      // 单拍：这份表生效了（给 C 轨的 ready_n）
      output reg [7:0]  ready_n           // 和 ready_pulse 同拍：第几张就绪
  );

      localparam T_IDLE   = 2'd0,
                 T_COMMIT = 2'd1,
                 T_WAIT   = 2'd2;

      reg [1:0] st;
      reg       ack_d;
      wire      ack_edge = a_ack_tgl ^ ack_d;

      reg [7:0] img_no_r;                 // 提交那一刻的图号，等 ack 后用

      // ---- 目标槽这一份的 64 位 ----
      wire [63:0] new_slot = {
          7'd0,                       // [63:57] 补零
          img_no,                     // [56:49] 第几张
          img_height[11:0],           // [48:37] 高（12 位，上限 4095）
          img_width[11:0],            // [36:25] 宽（12 位，上限 4095）
          slot_base,                  // [24:4]  这个槽的基址
          2'b00,                      // [3:2]   format = 00 = RGB565
          1'b0,                       // [1]     transposed = 0（横屏）
          1'b1                        // [0]     valid = 1  ★ 交付完成
      };
      // ---- 只改目标槽，其他槽原样保留 ----
      reg [SLOT_NUM*64-1:0] desc_next;
      integer i;
      always @(*) begin
          desc_next = a_desc;
          for (i = 0; i < SLOT_NUM; i = i + 1)
              if (i == use_slot)
                  desc_next[i*64 +: 64] = new_slot;
      end

      always @(posedge clk_ctl or negedge rst_ctl_n) begin
          if (!rst_ctl_n) begin
              st           <= T_IDLE;
              a_desc       <= {SLOT_NUM*64{1'b0}};   // 复位：所有槽 valid = 0
              a_commit_tgl <= 1'b0;
              ack_d        <= 1'b0;
              img_no_r     <= 8'd0;
              busy         <= 1'b0;
              ready_pulse  <= 1'b0;
              ready_n      <= 8'd0;
          end
          else begin
              ack_d       <= a_ack_tgl;
              ready_pulse <= 1'b0;
              case (st)
              //-------- 等整帧写进 SDRAM --------
              T_IDLE: begin
                  busy <= 1'b0;
                  if (frame_done) begin
                      a_desc   <= desc_next;   // 只改目标槽
                      img_no_r <= img_no;      // 顺手记下是第几张
                      busy     <= 1'b1;
                      st       <= T_COMMIT;
                  end
              end

              T_COMMIT: begin
                  a_commit_tgl <= ~a_commit_tgl;
                  st           <= T_WAIT;
              end

              //-------- 等 B 侧采完回执 --------
              T_WAIT: begin
                  if (ack_edge) begin
                      ready_pulse <= 1'b1;
                      ready_n     <= img_no_r;
                      busy        <= 1'b0;
                      st          <= T_IDLE;
                  end
              end

              default: st <= T_IDLE;
              endcase
          end
      end

  endmodule