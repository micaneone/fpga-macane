# rtl/b_display/lib —— 已经验证过、只需要被调用的模块

> **这里面的东西不要改。**
> 它们要么是已经在板子上跑通过的（HDMI 链路 / SDRAM 控制器），
> 要么是官方例程里验证过的。B 轨的工作是**在上面加新级**，不是重写它们。
>
> 真需要改，请复制一份到上一层目录再改，在这个目录里保持"可对照的原样"。

## 四个子目录

| 目录 | 里面是什么 | 来源 |
| --- | --- | --- |
| `video/` | 行场时序（`video_timing.v`）、彩条、BRAM 小图、原工程顶层参考 | `MY_project\video\src\` |
| `hdmi/` | **HDMI 1.4b 发射核 + 自研硬 4:1 串化 PHY** —— 全项目最值钱的资产 | 同上 |
| `sdram/` | 片内 SDRAM 控制器 11 个文件（3 个 `.enc.v` 是加密的，当黑盒用）| 同上 |
| `audio/` | HDMI 音频打包三件套 + 音频 PLL（M3 做转场音效时才用）| 同上 |
| `util/` | `seg_decoder.v` / `seg_scan.v`（官方例程的数码管）、`key_press_debounce.v`（官方例程的按键消抖，从 `sd_card_bmp.v` 末尾原样抠出来）、`UART_sendchar.v`（我们自己写的）| 模块库 |

## 用的时候要知道的几件事

1. **`sdram/` 在 ModelSim 里编不过**：`sdr_wrrd.enc.v` 是 TD 专用加密核。
   所以 `sim\run_sim.ps1` 把这个目录整个跳过了，仿真时用 `sim\fake_sdram.v` 顶替。
2. **`hdmi/hdmi1.4b_transmitter_core/*.enc.v` elaborate 不了**
   （`Error occurred in protected context`），所以仿真时用 `sim\hdmi_core_model.v` 顶替；
   但**综合必须用真的**，`prj\bwtest.al` 里已经配好。
3. **`sdram.v` 用 `include "global_def.v"` 的短名**，所以这两个文件必须待在同一个目录里
   （现在在 `lib\sdram\` 下一起 ✓）。挪动的时候别把它们拆开。
4. `hdmi/my_hdmitop.v` 的 **`I_rst` 是高有效**（和大多数模块相反），别接错。
5. `video/ref_top_video.v` 是原显示工程的顶层，**只作参考**；
   我们的作品顶层和测试顶层都在别处，不要拿它当模板直接改。
6. `sdram/` 里片内 SDRAM 是 **SIP 封装，没有引脚、不需要约束**。
7. `util/key_press_debounce.v` 的 `CLK_FREQ_HZ` **默认是 100 MHz，我们是 50 MHz，用的时候必须显式传**；
   填错了消抖时间会跟着错一倍（不报错，只是手感不对）。它的 `rst` 是**高有效**。

## 和 `模块库\` 的区别

`模块库\00_自有_已验证\` 是"全项目共用的资产库"，A / B / C 都可能从那里取件；
这里的 `lib\` 是 **B 轨已经搬进工程、正在用的那一份**。
两边内容有重叠是正常的 —— 以本目录的这份为准（工程用的是它）。
