// ============================================================================
//  res_ovl.v —— 【菜单打开时，屏幕右上角显示原图分辨率】
//  ────────────────────────────────────────────────────────────────────────────
//  ★ 2026-10-30 新增。
//    需求：菜单一打开，右上角显示当前这张图的原图分辨率，宽、高都要显示
//          （例：1536×1152）。
//    画法：7 段数字 + 手绘乘号，不占 BRAM（不用往 font_cn.dat 里塞新字形）。
//          半透明底（和菜单的压暗一致：>>1 并保留 alpha 位）+ 亮字。
//    位置：右边缘往左 X_RIGHT 像素、顶边下 Y0 像素；
//          每个字形 CW×CH，字形间距 GAP；共 9 个槽：
//          0..3 = 宽的千/百/十/个，4 = ×，5..8 = 高的千/百/十/个
//          （千/百/十为 0 时留空）。
// ============================================================================
module res_ovl #(
    parameter integer SCR_W   = 800,
    parameter integer SCR_H   = 600,
    parameter integer X_RIGHT = 8,
    parameter integer Y0      = 8,
    parameter integer CW      = 16,
    parameter integer CH      = 24,
    parameter integer GAP     = 4,
    parameter [15:0]  CLR_INK = 16'hFFC2      // 和菜单字色一致（亮黄）
)(
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire [11:0] x_in,
    input  wire [11:0] y_in,
    input  wire [15:0] px_in,
    output reg  [15:0] px_out,
    output reg         de_out,
    output reg         vs_out,
    input  wire        menu_on,
    input  wire [11:0] res_w,
    input  wire [11:0] res_h
);

    localparam integer SLOT = CW + GAP;              // 20
    localparam integer TOTW = 9*SLOT - GAP;          // 176
    localparam integer X0   = SCR_W - X_RIGHT - TOTW;// 616
    localparam [11:0] X0_W = X0;
    localparam [11:0] Y0_W = Y0;
    localparam integer Y1   = Y0 + CH;
    localparam [11:0] Y1_W = Y1;               // 32

    // ---------------- 拆数字（宽/高都不超过 4 位） ----------------
    // 2026-10-31 65 MHz pipelining: the decimal-division chain (res_w/1000..10)
    // plus digit/seg/comparator logic was 25 logic levels (WNS -5.441 ns, 1024x768
    // image).  Register the division results and the pixel coordinates so the
    // chain becomes two short stages; total latency is now 2 clocks (was 1).
    reg  [11:0] x_d1, y_d1, rw_d1, rh_d1;
    reg  [15:0] px_d1;
    reg         menu_d1, de_d1, vs_d1;
    reg  [3:0]  slot_d1;
    reg  [11:0] wq3_q, wq2_q, wq1_q, hq3_q, hq2_q, hq1_q;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            x_d1 <= 12'd0; y_d1 <= 12'd0; px_d1 <= 16'd0;
            menu_d1 <= 1'b0; de_d1 <= 1'b0; vs_d1 <= 1'b0;
            slot_d1 <= 4'd0;
            rw_d1 <= 12'd0; rh_d1 <= 12'd0;
            wq3_q <= 12'd0; wq2_q <= 12'd0; wq1_q <= 12'd0;
            hq3_q <= 12'd0; hq2_q <= 12'd0; hq1_q <= 12'd0;
        end
        else begin
            x_d1 <= x_in; y_d1 <= y_in; px_d1 <= px_in;
            menu_d1 <= menu_on; de_d1 <= de_in; vs_d1 <= vs_in;
            slot_d1 <= (x_in - X0_W) / SLOT;
            rw_d1 <= res_w; rh_d1 <= res_h;
            wq3_q <= res_w / 12'd1000;
            wq2_q <= res_w / 12'd100;
            wq1_q <= res_w / 12'd10;
            hq3_q <= res_h / 12'd1000;
            hq2_q <= res_h / 12'd100;
            hq1_q <= res_h / 12'd10;
        end
    end

    wire [3:0] wd3 = wq3_q[3:0];
    wire [3:0] wd2 = (wq2_q - wq3_q*12'd10);
    wire [3:0] wd1 = (wq1_q - wq2_q*12'd10);
    wire [3:0] wd0 = (rw_d1 - wq1_q*12'd10);
    wire [3:0] hd3 = hq3_q[3:0];
    wire [3:0] hd2 = (hq2_q - hq3_q*12'd10);
    wire [3:0] hd1 = (hq1_q - hq2_q*12'd10);
    wire [3:0] hd0 = (rh_d1 - hq1_q*12'd10);

    wire w_show3 = (rw_d1 >= 12'd1000);
    wire w_show2 = (rw_d1 >= 12'd100);
    wire w_show1 = (rw_d1 >= 12'd10);
    wire h_show3 = (rh_d1 >= 12'd1000);
    wire h_show2 = (rh_d1 >= 12'd100);
    wire h_show1 = (rh_d1 >= 12'd10);

    wire box_on = menu_d1 && ((rw_d1 != 12'd0) || (rh_d1 != 12'd0))
               && (x_d1 >= X0_W) && (x_d1 < (X0 + TOTW))
               && (y_d1 >= Y0_W) && (y_d1 < Y1_W);

    wire [11:0] rx   = x_d1 - X0_W;
    wire [11:0] ry   = y_d1 - Y0_W;
    wire [3:0]  slot = slot_d1;
    wire [11:0] gx   = rx - slot*SLOT;
    wire [3:0]  dx   = gx[3:0];
    wire [4:0]  dy   = ry[4:0];

    // ---------------- 取当前槽的字形 ----------------
    wire [3:0] dsel = (slot == 4'd0) ? wd3 :
                      (slot == 4'd1) ? wd2 :
                      (slot == 4'd2) ? wd1 :
                      (slot == 4'd3) ? wd0 :
                      (slot == 4'd5) ? hd3 :
                      (slot == 4'd6) ? hd2 :
                      (slot == 4'd7) ? hd1 : hd0;

    wire dvalid = (slot == 4'd0) ? w_show3 :
                  (slot == 4'd1) ? w_show2 :
                  (slot == 4'd2) ? w_show1 :
                  (slot == 4'd3) ? 1'b1 :
                  (slot == 4'd5) ? h_show3 :
                  (slot == 4'd6) ? h_show2 :
                  (slot == 4'd7) ? h_show1 : 1'b1;

    // 7 段表：bit0=a(上) bit1=b(右上) bit2=c(右下) bit3=d(下) bit4=e(左下) bit5=f(左上) bit6=g(中)
    reg [6:0] seg;
    always @(*) begin
        case (dsel)
            4'd0: seg = 7'b0111111;
            4'd1: seg = 7'b0000110;
            4'd2: seg = 7'b1011011;
            4'd3: seg = 7'b1001111;
            4'd4: seg = 7'b1100110;
            4'd5: seg = 7'b1101101;
            4'd6: seg = 7'b1111101;
            4'd7: seg = 7'b0000111;
            4'd8: seg = 7'b1111111;
            4'd9: seg = 7'b1101111;
            default: seg = 7'b0000000;
        endcase
    end

    wire hit_a = (dy <= 5'd2 )                 && (dx >= 4'd2) && (dx <= 4'd13) && seg[0];
    wire hit_b = (dy >= 5'd1 ) && (dy <= 5'd11) && (dx >= 4'd11)&& (dx <= 4'd14) && seg[1];
    wire hit_c = (dy >= 5'd12) && (dy <= 5'd22) && (dx >= 4'd11)&& (dx <= 4'd14) && seg[2];
    wire hit_d = (dy >= 5'd21)                 && (dx >= 4'd2) && (dx <= 4'd13) && seg[3];
    wire hit_e = (dy >= 5'd12) && (dy <= 5'd22) && (dx >= 4'd1) && (dx <= 4'd3 ) && seg[4];
    wire hit_f = (dy >= 5'd1 ) && (dy <= 5'd11) && (dx >= 4'd1) && (dx <= 4'd3 ) && seg[5];
    wire hit_g = (dy >= 5'd10) && (dy <= 5'd12) && (dx >= 4'd2) && (dx <= 4'd13) && seg[6];
    wire dig_on = hit_a | hit_b | hit_c | hit_d | hit_e | hit_f | hit_g;

    // ---------------- 手绘乘号 × ----------------
    reg [15:0] xmk;
    always @(*) begin
        case (dy)
            5'd0: xmk = 16'h0000;
            5'd1: xmk = 16'h0000;
            5'd2: xmk = 16'h2004;
            5'd3: xmk = 16'h2004;
            5'd4: xmk = 16'h300C;
            5'd5: xmk = 16'h1818;
            5'd6: xmk = 16'h0810;
            5'd7: xmk = 16'h0C30;
            5'd8: xmk = 16'h0660;
            5'd9: xmk = 16'h0240;
            5'd10: xmk = 16'h03C0;
            5'd11: xmk = 16'h0180;
            5'd12: xmk = 16'h0180;
            5'd13: xmk = 16'h03C0;
            5'd14: xmk = 16'h0240;
            5'd15: xmk = 16'h0660;
            5'd16: xmk = 16'h0C30;
            5'd17: xmk = 16'h0810;
            5'd18: xmk = 16'h1818;
            5'd19: xmk = 16'h300C;
            5'd20: xmk = 16'h2004;
            5'd21: xmk = 16'h2004;
            5'd22: xmk = 16'h0000;
            5'd23: xmk = 16'h0000;
            default: xmk = 16'h0000;
        endcase
    end
    wire xok = (gx < 12'd16) ? xmk[gx[3:0]] : 1'b0;

    wire in_cell = (gx < 12'd16);   // [fix] do not wrap gx[3:0] into the GAP columns
    wire on_px = box_on && in_cell && ((slot == 4'd4) ? xok : (dig_on && dvalid));

    wire [15:0] px_dim = {1'b0, px_d1[15:1]} & 16'h7BEF;

    reg        q_box, q_on;
    reg [15:0] q_px, q_pxd;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            px_out <= 16'd0; de_out <= 1'b0; vs_out <= 1'b0;
            q_box <= 1'b0; q_on <= 1'b0; q_px <= 16'd0; q_pxd <= 16'd0;
        end
        else begin
            de_out <= de_d1; vs_out <= vs_d1;
            q_box  <= box_on; q_on <= on_px;
            q_px   <= px_d1;  q_pxd <= px_dim;
            px_out <= q_box ? (q_on ? CLR_INK : q_pxd) : q_px;
        end
    end

endmodule
