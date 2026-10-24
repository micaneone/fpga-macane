// tb_vol33.v — 验证【33 级音量】映射（2026-10-24）
//   top_m2.v：vol_lv 0..33（共 34 档）⇒ vol_byte = (vol_lv*1980 + 128) >> 8 ≈ vol_lv*255/33（33 档 = 255）
//   sfx_player.v：gain7 = (vol_byte+2)>>2 → 0..64；fad6 = (fade+4)>>3 → 0..32（满窗 = 32）
//                 gmul = gain7*fad6；gain4 = gmul>>5 = gain7；输出 = sv*gain4/64
//   检查：vol_byte 单调、两端 0/255、gain4 逐档严格递增（0..33 共 34 档全部可分辨）。
`timescale 1ns/1ps
module tb_vol33;
    reg  [5:0] lv;

    wire [15:0] vol_mult = ({2'd0, lv} * 16'd1980);   // 0..65340，16 位不溢出
    wire [7:0]  vb       = (vol_mult + 16'd128) >> 8; // ≈ lv*255/33

    // 满窗（fade=255 ⇒ fad6=32）时的实际数字增益
    wire [6:0]  gain7 = ({1'b0, vb} + 9'd2) >> 2;     // 0..64
    wire [11:0] gmul  = gain7 * 6'd32;                // fad6 = 32 ⇒ gmul = gain7×32
    wire [6:0]  gain4 = gmul[11:5];                   // 0..64

    integer i;
    integer bad;
    integer prev_g;
    integer pct;
    initial begin
        bad = 0;
        prev_g = -1;
        $display("lv vol_byte gain4 pct");
        for (i = 0; i <= 33; i = i + 1) begin
            lv = i[5:0];
            #1;
            pct = (gain4 * 100) / 64;
            $display("%2d      %3d   %2d   %3d%%", lv, vb, gain4, pct);
            if ((i > 0) && (gain4 <= prev_g)) begin
                $display("  !! 档位不可分辨 at lv=%0d (gain4=%0d, prev=%0d)", lv, gain4, prev_g);
                bad = bad + 1;
            end
            prev_g = gain4;
        end
        lv = 6'd0;  #1; if (vb !== 8'd0)   begin $display("!! lv0  vol_byte=%0d (expect 0)",   vb); bad = bad + 1; end
        lv = 6'd33; #1; if (vb !== 8'd255) begin $display("!! lv33 vol_byte=%0d (expect 255)", vb); bad = bad + 1; end
        if (bad == 0) $display("RESULT: OK (34 档全部可分辨，0..255 满量程)");
        else          $display("RESULT: FAIL (%0d problems)", bad);
        $finish;
    end
endmodule
