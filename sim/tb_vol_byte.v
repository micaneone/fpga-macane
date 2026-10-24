// tb_vol_byte.v — 证明 top_m2.v 里 vol_byte 的 8 位乘法截断 bug（2026-10-24）
//   old: wire [7:0] vol_byte = (({4'd0, vol_lv} * 8'd51) >> 1);   // Verilog: `*` 结果宽度 = 操作数最大宽度 = 8 位
//   new: wire [15:0] vol_mult = ({8'd0, vol_lv} * 16'd51); wire [7:0] vol_byte = vol_mult[8:1];
`timescale 1ns/1ps
module tb_vol_byte;
    reg [3:0] lv;

    // 旧写法（8 位截断）
    wire [7:0] vb_old = (({4'd0, lv} * 8'd51) >> 1);

    // 新写法（16 位中间结果）
    wire [15:0] vol_mult = ({8'd0, lv} * 16'd51);
    wire [7:0]  vb_new   = vol_mult[8:1];

    // sfx_player.v 里的 5 位增益（2026-10-24 线性化后），fade=255 满窗 ⇒ fad5=16、gain4=gain5
    function [4:0] gain5; input [7:0] vb; begin gain5 = (vb + 9'd8) >> 4; end endfunction

    integer i;
    initial begin
        $display("lv  vb_old g5_old pct_old |  vb_new g5_new pct_new");
        for (i = 0; i <= 10; i = i + 1) begin
            lv = i[3:0];
            #1;
            $display("%0d   %3d    %2d   %3d%%   |  %3d    %2d   %3d%%",
                    lv, vb_old, gain5(vb_old), (gain5(vb_old) * 100) / 16,
                        vb_new, gain5(vb_new), (gain5(vb_new) * 100) / 16);
        end
        $finish;
    end
endmodule
