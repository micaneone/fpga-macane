// ============================================================
//  eg_phy_bram32k_behav.v —— TD 原语 EG_PHY_BRAM32K 的【仿真替身】
// ------------------------------------------------------------
//  为什么需要它：TD 自带的 sim_release\eg4\eg_phy_bram32k.v 是加密模型，
//  而且**不读 INIT_FILE**（2026-10-25 实测：初始化数据全 0），拿它跑
//  menu 看图台会看到"屏上字全空"，没法判断是我们的错还是模型的错。
//
//  这个替身只实现我们用到的那一部分：
//    - 16 位宽 × 2048 深，两读口、写口忽略（我们是纯 ROM）；
//    - INIT_FILE：每行 16 个 0/1（MSB 在前），用 $readmemb 灌进去；
//    - NOREG 同步读：时钟沿采地址，下一拍 doa/dob 有效。
//
//  ★ 只放进仿真文件表（check_compile.ps1 / sim\run_cn.bat），
//    **绝不能加进 TD 工程 prj\M2.al** —— TD 里用真原语。
// ============================================================
`timescale 1ns / 1ps

module EG_PHY_BRAM32K (
    doa, dia, addra, bytea, bytewea, csa, wea, clka, rsta, ocea,
    dob, dib, addrb, byteb, byteweb, csb, web, clkb, rstb, oceb
);

    parameter MODE          = "DP16K";
    parameter DATA_WIDTH_A  = "16";
    parameter DATA_WIDTH_B  = "16";
    parameter REGMODE_A     = "NOREG";
    parameter REGMODE_B     = "NOREG";
    parameter INIT_FILE     = "";

    output [15:0] doa;
    output [15:0] dob;
    input  [15:0] dia;
    input  [15:0] dib;
    input  [10:0] addra;
    input  [10:0] addrb;
    input         bytea;
    input         bytewea;
    input         byteb;
    input         byteweb;
    input         csa;
    input         wea;
    input         csb;
    input         web;
    input         clka;
    input         rsta;
    input         clkb;
    input         rstb;
    input         ocea;
    input         oceb;

    reg [15:0] mem [0:2047];
    integer    i;

    initial begin
        for (i = 0; i < 2048; i = i + 1) mem[i] = 16'h0000;
        if (INIT_FILE != "" && INIT_FILE != "NONE") begin
            $readmemb(INIT_FILE, mem);
        end
    end

    reg [15:0] doa_r, dob_r;
    always @(posedge clka) begin
        if (rsta)           doa_r <= 16'h0000;
        else if (csa && !wea) doa_r <= mem[addra[10:0]];
    end
    always @(posedge clkb) begin
        if (rstb)           dob_r <= 16'h0000;
        else if (csb && !web) dob_r <= mem[addrb[10:0]];
    end

    assign doa = doa_r;
    assign dob = dob_r;

endmodule
