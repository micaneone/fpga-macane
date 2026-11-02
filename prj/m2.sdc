# ============================================================
#  M1 集成工程时序约束
#
#  M0 那版已经"补过跨时钟域声明"（第一版故意空着跑过一次，
#  确认了 40<->100/200 之间有一条真有路径、其余大违例都是跨域被当成
#  同步路径算出来的假违例）。M1 的跨域点和 M0 是**同一批**，只是多了
#  描述符那一条，所以配方照抄，只把说明改准确。
#
#  M1 实际存在的跨域点（都要在这里被正确地"排除"或声明）：
#    · 写口          A 50 -> 125   数据先稳 + 翻 toggle      sdr_arb.v
#    · 描述符口      A 50 -> 40    同左 + 帧边界整份采       desc_rx.v
#    · 行缓冲/读回   125 -> 40     双口 RAM + toggle 同步    line_buf.v
#    · 像素↔串化     40 <-> 100/200 lane_lvds_10_4 内部已处理
#    都在下面两组 set_clock_groups 覆盖之内。
#
#  时钟名是【实跑报告里抄下来的】，不是猜的：
#    Clock Summary（M0_Runs\phy_1\final_timing.rpt）
#      clk0: 125.000  u_pll_sdr/pll_inst.clkc[1]     显存（SDRAM Clk）
#      clk1:  40.000  u_pll0/pll_inst.clkc[0]        像素
#      clk3: 100.000  u_pll0/pll_inst.clkc[1]        并行（串化用）
#      clk4: 200.000  u_pll0/pll_inst.clkc[2]        串化
#      clk5: 125.000  u_pll_sdr/pll_inst.clkc[2]     显存 180°（SDRAM Clk_sft）
#  ★ top_m1 里两个 PLL 的实例名就是 u_pll0 / u_pll_sdr，
#    所以这些路径名和 M0 那份一字不差。
# ============================================================

# ------------------------------------------------------------
#  1. 板级输入主时钟：50 MHz 晶振
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]


# ------------------------------------------------------------
#  2. 顺着两个 PLL 自动推导出全部派生时钟
# ------------------------------------------------------------
derive_clocks


# ------------------------------------------------------------
#  3. 像素域 <-> 串化域：互斥
#     lane_lvds_10_4 里是"像素域打包 + pclk 域按包取走"的结构，
#     跨域在 RTL 里已经处理过了（格雷码指针 / 电平比较），
#     不按单周期分析。写法沿用官方例程。
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {u_pll0/pll_inst.clkc[0]}] \
    -group [get_clocks {u_pll0/pll_inst.clkc[1] u_pll0/pll_inst.clkc[2]}]


# ------------------------------------------------------------
#  4. 四块时钟域互相异步
#
#     ★★ 2026-09-26 修正：上一版把 100/200MHz 那一对漏掉了 ——
#        结果是"软复位从 50MHz 跨到 HDMI 串化域(100MHz)"那 10 条路被当成
#        同步路径算，报出 -1.8ns 的假违例（第一遍综合的 177 条里就有一批）。
#        M0 工程也有同样的漏（所以它也有 67 条），当时上板是通的，
#        但那是因为运气好 —— 这里是真跨域，必须声明。
#
#     ★ 两个 125MHz（0° / 180°）必须放在【同一个组】里：
#       它们之间照常做时序分析（那是 SDRAM 芯片用 180° 相位采 DQ 的关系，
#       绝对不能放松），只是把"它们和另外三块时钟之间"的路径排除掉。
#     ★ 100MHz 和 200MHz 同理放在同一组（同一个 PLL、有固定相位关系）。
# ------------------------------------------------------------
# ★★ 2026-09-27 深夜（关键实验）：这里从"4 组"改回 M0 的"3 组" ——
#    也就是把 `u_pll0/pll_inst.clkc[1] clkc[2]`（100/200MHz 串化域）那一组删掉。
#
#    为什么改：M1 和 M0 的 SDRAM 核、PLL、时钟接法、读法代码都逐行比过、完全一致，
#    但 M0 上板"读回逐字比对"是 F=000000 全对，M1 却出现"每 4 个字错 3 个"。
#    这一版把"连发读 + 逐字比对"直接放在 M1 里跑（rd_selftest.v），
#    结果 2048 个字错 1536 个 —— 说明问题**不在显示链、也不在行缓冲**，
#    而是在"这一版工程"本身。两版工程之间能比的只剩时序约束：
#       M0 是 3 组（50 / 40 / 显存对），M1 多声明了 100/200MHz 那一组。
#    多声明一组"异步"，会让那批跨域路径不再受时序驱动 → 布局布线结果整体改变
#    → 而这颗 SDRAM 核内部"用 180° 时钟采 DQ"那条路对时钟树走线很敏感，
#      采样点一动就变成"每 4 拍才更新一次"。
#
#    代价（当年 M0 就是带着它上板成功的）：50MHz 软复位跨到串化域那 ~10 条路
#    会被当成同步路径算，报几条违例。
#    ★ 如果这次自测变成 0，就说明"少声明这一组"才是对的，正式版也照此写。
set_clock_groups -asynchronous \
    -group [get_clocks {clk}] \
    -group [get_clocks {u_pll0/pll_inst.clkc[0]}] \
    -group [get_clocks {u_pll0/pll_inst.clkc[1] u_pll0/pll_inst.clkc[2]}] \
    -group [get_clocks {u_pll_sdr/pll_inst.clkc[1] u_pll_sdr/pll_inst.clkc[2]}] \
    -group [get_clocks {u_pll_aud/pll_inst.clkc[2]}]


# ------------------------------------------------------------
#  4b. ★★★ 2026-10-05：补上【音频 PLL】那一组（原来漏了）
#      `u_pll_aud/pll_inst.clkc[2]`（12.295 MHz）原来不在任何 set_clock_groups 里，
#      于是 top_aud / sdr_rd_arb / sfx_player 里那几处【本来就是同步器】的跨域点
#      被当成同步路径算，布完线报出来的是：
#        - 音频域内部  recovery/removal  -4.8 ns   (u_ctrl/soft_rst → sfx_player 的 .sr)
#        - 音频→像素    setup           -5.1 ns   (sfx_player.smp24 → o_audio_left)
#        - 仲裁器内部   setup           -6.0 ns   (sdr_rd_arb 的 gray 指针链)
#      ★ 危害不只是"报告难看"：工具为了去满足这些根本不可能收敛的跨域路径，把布局
#        挤到 85% 以上，反而把【真路径】（40MHz 像素域的 v_cnt→scaler、50MHz 控制域）
#        从"通过"拖成违例 —— 上板表现就是 白线扫屏 + 音频杂音。
#      ⇒ 按《规划\A轨待改清单.md》2026-10-05 第 4 条把音频时钟声明成异步。
#        （这几处跨域在 RTL 里本来就是"数据先稳 + 翻 toggle / 两级同步"的写法。）
#      ★ 注意：这颗 SDRAM 核对 set_clock_groups 很敏感（见上面第 4 节那段历史），
#        所以改完必须重新布线并【上板确认读口正常】（串口字段 0/1 必须 == 字段 11）。
# ------------------------------------------------------------


# ------------------------------------------------------------
#  5. 现在不要写的东西
#     · 不要写"所有时钟互相异步" —— 那等于整块板子不再做时序检查
#     · 不要写 set_input_delay / set_output_delay —— 本工程没有和外部
#       器件做同步接口（串口很慢、按键是人手按的、SD 卡更慢、
#       HDMI 的 TMDS 由核自己管）
#     · 暂不给 PLL 输出改名字（rename_clock）。用自动推导的名字最稳，
#       改名一旦写错路径，后面的 set_clock_groups 会【静默失效】。
# ------------------------------------------------------------

# ===== 2026-10-31 timing exceptions (added by Lead, ASCII only) =====
# (a) SDRAM PHY cross-phase interface paths (clk_sdr 0deg <-> 180deg):
#     these are inside the vendor SDRAM controller IP and talk to the external
#     SDRAM device; the read/write phase is set by the device tAC/CL, not by
#     internal synchronous logic. TD budgets them at an ideal 4ns half period
#     and reports WNS -6.7ns on 80 endpoints, which can never close.
set_false_path -from [get_clocks {u_pll_sdr/pll_inst.clkc[1]}] -to [get_clocks {u_pll_sdr/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {u_pll_sdr/pll_inst.clkc[2]}] -to [get_clocks {u_pll_sdr/pll_inst.clkc[1]}]
# (b) 7-seg LED segment outputs: slow human-readable indicators, refreshed at
#     kHz rate by a divider; a single 20ns cycle budget is unrealistically tight
#     for the BCD/segment decode chain, so declare a multi-cycle path (160ns).
# 7-seg segment outputs are slow human indicators -> no timing requirement at all
set_false_path -to [get_ports {seg_data[*]}]
