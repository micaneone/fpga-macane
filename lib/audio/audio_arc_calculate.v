
// ============================================================
//  audio_arc_calculate —— 算 HDMI 的 ACR（音频时钟重建）参数
//
//  为什么需要它：接收端手上只有 TMDS 时钟，要靠 ACR 包里的 N/CTS 才能重建
//  48kHz 的播放时钟：
//         f_audio = f_TMDS × N / (128 × CTS)
//
//  它怎么算：CTS = 两个 ACR 包之间【数了多少个像素时钟周期】
//         AUDIO_DIV = N/128 = 6144/128 = 48  → 每 48 个样本（= 1ms）发一次包
//         → CTS = 像素时钟频率 / 1000
//             640×480（25MHz）→ 25000
//             800×600（40MHz）→ 40000
//
//  时钟域：★ I_clk 必须接【像素时钟】（例程就是 .I_clk(video_clk)）。
//          接成别的时钟，声音会变调或断续，而且不报错。
//
//  好消息：CTS 是"数出来的"，所以**换分辨率会自动跟着变**，这段代码不用改。
//
//  详见图文：../原理-I2S音频.md 第 4 节
// ============================================================



module audio_arc_calculate #(
    parameter ACR_N = 6144
    )(
    input wire       I_clk,
    input wire       I_rst,

    input wire       I_audio_valid,

    output reg       O_acr_valid,
    output reg[19:0] O_acr_cts,
    output reg[19:0] O_acr_n
);


    localparam AUDIO_DIV = ACR_N >> 7;

    reg[7:0]  S_audio_div_cnt;
    wire      S_audio_valid_div;
    reg[19:0] S_acr_cts_cnt;


    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_audio_div_cnt <= 'd0;
        else
            if(I_audio_valid)
                begin
                    if(S_audio_div_cnt >= AUDIO_DIV-1)
                        S_audio_div_cnt <= 'd0;
                    else
                        S_audio_div_cnt <= S_audio_div_cnt + 'd1;
                end
            else
                S_audio_div_cnt <= S_audio_div_cnt;
    end


    assign S_audio_valid_div = I_audio_valid && (S_audio_div_cnt == AUDIO_DIV-1) ? 1'b1 : 1'b0;

    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_acr_cts_cnt <= 'd0;
        else
            if(S_audio_valid_div)
                S_acr_cts_cnt <= 'd0;
            else
                S_acr_cts_cnt <= S_acr_cts_cnt + 'd1;
    end


    always @(posedge I_clk) begin
        if(S_audio_valid_div)
            begin
                O_acr_valid <= 1'b1;
                O_acr_cts   <= S_acr_cts_cnt + 'd1;
                O_acr_n     <= ACR_N;
            end
        else    
            begin
                O_acr_valid <= 1'b0;
                O_acr_cts   <= 'd0;
                O_acr_n     <= 'd0;
            end
    end

    
endmodule
