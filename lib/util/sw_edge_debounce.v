// ============================================================
//  sw_edge_debounce —— 拨码 / 乒乓开关消抖（稳定后【任意方向】变化给一个单拍脉冲）
//
//  ★★★ 2026-10-14 深夜【开关3 切音频】
//    用途：板上"开关3"（丝印 SW3 = FPGA 引脚 C6）。需求原话：
//    "用开关3做音频切换，每改一次方向，就换下一个音频。"
//    拨上 / 拨下**都算**"改一次方向" ⇒ 两个方向都要出脉冲。
//
//  ★ 为什么**不能**用 lib\util\key_press_debounce.v（那个只认单方向）：
//    ① 判据写死了单方向：它的输出条件就是
//         `if (button_stable && !button_sync1) press_pulse <= 1'b1;`
//       —— 只有"稳态=1、新采样=0"（= 按键按下，板上按键低有效）才出脉冲；
//       "0 → 1"（松手 / 拨到另一侧）那一半**永远不出脉冲**。
//       拨码开关没有"按 / 松"，两个方向都是用户的有效操作 ⇒ 用它就只能
//       识别一个方向，往另一个方向拨**完全没反应**。
//    ② 复位初值是 `sync0/sync1/stable = 1'b1`（按键"不按=1"这个前提）。
//       这个前提对拨码开关不成立：上电时开关可能停在 0 也可能停在 1，
//       初值一旦和实际电平不同，复位释放后就等于"看见了一次变化" ⇒
//       白多出一个脉冲（本工程里就是 `sel_aud` 上电莫名 +1）。
//    ③ 语义也不一样：那个是"按键事件"，这个是"电平变了"。
//    ★ 所以单独写这一个小模块（全部逻辑 20 行），而**不要**去改
//      `key_press_debounce` —— 它还在给 KEY3（换图）用，改它会顺手把换图那条路带坏。
//
//  ★ 电平来源（三处，互为印证 —— 引脚 C6）：
//    · 《HX4S20 开发板手册》p.18 图 2-19：SW1=C8 / SW2=C7 / **SW3=C6** / SW4=C5；
//    · 原理图网名 `NLSWKEY03` = **C6**；
//    · 官方 DEMO 约束里 `key[2]`（`SW[2]`）= **C6**，且都写 `PULLTYPE = PULLUP`。
//  ★ 极性：拨上=1 / 拨下=0，但**两份官方文档互相矛盾** ⇒ 本模块**不做任何方向假设**，
//    两个边沿都出脉冲：极性万一反了，也只是"拨上 / 拨下对调"，
//    功能照样对（"换下一条音频"这件事本来就不关心方向）。
//
//  ★ 上电不误发脉冲（本模块存在的另一个关键理由）：
//    · 复位期间 `change_pulse` 恒 0；
//    · 复位释放后头 3 拍（`warmup` 0→1→2→3）**只把当前同步后的电平直接当稳态**
//      （`sw_stable <= sync1`）并把计时器清零，这 3 拍里"初值 ≠ 实际电平"不会被
//      当成一次变化 ⇒ **上电第一帧绝不出脉冲** ⇒ 顶层 `sel_aud` 不会被莫名 +1。
//      3 拍 = 两级同步器 2 拍（等 `sync1` 采到真正的电平）+ 1 拍余量。
//
//  接口与用法（★ 和 key_press_debounce 一样，`rst` 是**高有效**）：
//      .CLK_FREQ_HZ (50_000_000)   ★ 必须填对！默认 50 MHz，填错了消抖时间跟着错
//      .DEBOUNCE_MS (20)
//      .rst         (~sys_rst_n)   高有效
//      .sw_in       (sw3)          开关电平（板上 PULLUP；拨到"1"那一侧是开路的）
//      .change_pulse(sw3_change)   稳定后**任意方向**变化 ⇒ 一个单拍脉冲
// ============================================================
`timescale 1ns / 1ps

module sw_edge_debounce #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,            // ★ 高有效（和 key_press_debounce 保持一致）
    input  wire sw_in,          // 开关电平：两个方向都有效
    output reg  change_pulse    // 稳定后任意方向变化 ⇒ 单拍
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
localparam integer CNT_W = $clog2(DEBOUNCE_CYCLES);          // 20 ms @50 MHz ⇒ 20 位
localparam [CNT_W-1:0] DEBOUNCE_MAX = DEBOUNCE_CYCLES - 1;   // 按计数位宽比较，省比较器
localparam [1:0]       WARMUP_DONE = 2'd3;                   // 初始化拍数走完（见下面用法）

reg             sync0, sync1;       // 两级同步（开关是异步输入）
reg             sw_stable;          // 已经认下来的稳态电平
reg [CNT_W-1:0] cnt;
reg [1:0]       warmup;             // 复位释放后 0→1→2→3；< 3 时只"认账"，不发脉冲

always @(posedge clk or posedge rst) begin
    if (rst) begin
        // ★ 复位期间不发脉冲；初值统一给 0（不给 1 —— 拨码开关没有"不按=1"这个前提）
        sync0        <= 1'b0;
        sync1        <= 1'b0;
        sw_stable    <= 1'b0;
        cnt          <= {CNT_W{1'b0}};
        warmup       <= 2'd0;
        change_pulse <= 1'b0;
    end else begin
        sync0        <= sw_in;
        sync1        <= sync0;
        change_pulse <= 1'b0;

        if (warmup != WARMUP_DONE) begin
            // ★ 上电初始化这 3 拍：不发脉冲，把"当前电平"直接当稳态
            //   （这样"复位初值 ≠ 实际电平"不会被当成一次变化）
            warmup    <= warmup + 2'd1;
            sw_stable <= sync1;
            cnt       <= {CNT_W{1'b0}};
        end else if (sync1 == sw_stable) begin
            cnt <= {CNT_W{1'b0}};            // 没变（或抖动又回到原样）⇒ 计时清零
        end else if (cnt >= DEBOUNCE_MAX) begin
            // ★ 新电平稳住满 DEBOUNCE_MS ⇒ 认账；**不分方向**，一律给一拍脉冲
            sw_stable    <= sync1;
            change_pulse <= 1'b1;
            cnt          <= {CNT_W{1'b0}};
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
end

endmodule
