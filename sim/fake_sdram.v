// ============================================================
//  fake_sdram -- 仿真用的"假 SDRAM"（B轨说明书 §8.2）
//
//  为什么要它：真正的 SDRAM 控制器是加密的 sdr_wrrd.enc.v，
//  在 ModelSim 10.3c 里编不过，SDRAM 这一层【不能仿真】。
//  对策就是把这个"不能仿真的部分"换成一片行为模型，
//  让上层（合成器 / 缩放 / 叠加 / 这里的 bw_measure）先验完。
//  真 SDRAM 只用"写死图案 -> 上屏"这一种方式验。
//
//  接口与 工程代码\rtl\b_display\sdram\sdram.v 的 App_* / Sdr_* 一侧【完全一致】，
//  所以可以原位替换。
//
//  ★ 仿真里测不出真机的带宽差异：真 SDRAM 的瓶颈来自"行激活"，
//    访问跨行时要重新激活一整行（这个延时不在本模型里）。所以本模型里
//    行方向、列方向、交错读三组的拍数【几乎一样】,这是对的，不要以为
//    "仿真里三组数字一样 = 真机也一样"。真机上的差异只能上板量。
//    本模型负责验的是：地址序列对不对、拍数怎么数、校验能不能抓到错。
//
//  参数：
//    DEPTH       存储器深度（字）
//    INIT_CYCLES Sdr_init_done 在多少拍之后拉高
//    RD_LATENCY  读延迟（拍）
//    BUSY_PERIOD 0 = 不产生 Sdr_busy；N = 每 N 拍拉 3 拍 busy（测 GATE_BUSY 用）
//    INJECT_ADDR >= 0 时，读这个地址返回被异或过的数据（验证校验器能抓到错）
// ============================================================
`timescale 1ns / 1ps

module fake_sdram #(
    parameter integer DEPTH       = 1 << 18,
    parameter integer INIT_CYCLES = 20,
    parameter integer RD_LATENCY  = 10,
    parameter integer BUSY_PERIOD = 0,
    parameter integer INJECT_ADDR = -1,
    parameter [31:0]  INJECT_XOR  = 32'h0000_0100
)(
    input  wire        Clk,
    input  wire        Clk_sft,
    input  wire        Rst,

    output wire        Sdr_init_done,
    output wire        Sdr_init_ref_vld,
    output wire        Sdr_busy,

    input  wire        App_wr_en,
    input  wire [20:0] App_wr_addr,
    input  wire [3:0]  App_wr_dm,
    input  wire [31:0] App_wr_din,

    input  wire        App_rd_en,
    input  wire [20:0] App_rd_addr,
    output reg         Sdr_rd_en,
    output reg  [31:0] Sdr_rd_dout
);

    reg [31:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = 32'h0000_0000;
        Sdr_rd_en   = 1'b0;
        Sdr_rd_dout = 32'h0;
    end

    // ---------- 初始化 ----------
    reg [15:0] init_cnt;
    always @(posedge Clk or posedge Rst) begin
        if (Rst) init_cnt <= 16'd0;
        else if (init_cnt != 16'hFFFF) init_cnt <= init_cnt + 16'd1;
    end
    assign Sdr_init_done    = (init_cnt >= INIT_CYCLES);
    assign Sdr_init_ref_vld = 1'b0;

    // ---------- 刷新忙（可选）----------
    reg [15:0] busy_cnt;
    always @(posedge Clk or posedge Rst) begin
        if (Rst) busy_cnt <= 16'd0;
        else if (BUSY_PERIOD > 0) busy_cnt <= busy_cnt + 16'd1;
    end
    assign Sdr_busy = (BUSY_PERIOD > 0) && ((busy_cnt % BUSY_PERIOD) < 3);

    // ---------- 写 ----------
    always @(posedge Clk) begin
        if (App_wr_en) begin
            if (!App_wr_dm[3]) mem[App_wr_addr][31:24] <= App_wr_din[31:24];
            if (!App_wr_dm[2]) mem[App_wr_addr][23:16] <= App_wr_din[23:16];
            if (!App_wr_dm[1]) mem[App_wr_addr][15:8]  <= App_wr_din[15:8];
            if (!App_wr_dm[0]) mem[App_wr_addr][7:0]   <= App_wr_din[7:0];
        end
    end

    // ---------- 读：固定 RD_LATENCY 拍流水 ----------
    reg [20:0] adr_sr [0:RD_LATENCY-1];
    reg [RD_LATENCY-1:0] vld_sr;

    always @(posedge Clk or posedge Rst) begin
        if (Rst) begin
            vld_sr <= {RD_LATENCY{1'b0}};
            for (i = 0; i < RD_LATENCY; i = i + 1) adr_sr[i] <= 21'd0;
            Sdr_rd_en   <= 1'b0;
            Sdr_rd_dout <= 32'h0;
        end
        else begin
            vld_sr <= {vld_sr[RD_LATENCY-2:0], App_rd_en};
            adr_sr[0] <= App_rd_addr;
            for (i = 1; i < RD_LATENCY; i = i + 1) adr_sr[i] <= adr_sr[i-1];

            Sdr_rd_en <= vld_sr[RD_LATENCY-1];
            if ((INJECT_ADDR >= 0) && (adr_sr[RD_LATENCY-1] == INJECT_ADDR))
                Sdr_rd_dout <= mem[adr_sr[RD_LATENCY-1]] ^ INJECT_XOR;
            else
                Sdr_rd_dout <= mem[adr_sr[RD_LATENCY-1]];
        end
    end

endmodule
