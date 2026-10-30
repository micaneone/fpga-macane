# ygcom / D5 商显广告机 —— 安路 EG4S20 上板工程

> 一句话：SD 卡里放 **BMP 图 + WAV 音乐 + SUB 字幕**，片上 SDRAM 缓冲，HDMI 输出
> **800×600**（可切 **1024×768**）的商显广告机；带菜单、无白屏转场、字幕滚动、
> 报警链路、卡热插拔恢复、音频可视化。

> 刚接手？先看 [`docs/交接文档_2026-10-23.md`](docs/交接文档_2026-10-23.md)。
> 文档总目录：[`docs/README.md`](docs/README.md)。
> 历史位流：[`bitstream_history/README.md`](bitstream_history/README.md)。

---

## 0. 现在到哪一步（2026-10-29）

| 能力 | 状态 |
|---|---|
| 显示 | 800×600@60 主用；1024×768@60 全屏（菜单「清晰」切换） |
| 启动 | 上电自动轮播 16 条广告，每 6 s 一条，转场 0.18 s、无白屏 |
| 交互 | 6 行菜单：缩放 / 可视 / 音量 / 亮度 / 清晰 / 字幕；按键导航 |
| 字幕 | 800×64 滚动字幕条，一图一字幕（SUB1..16） |
| 音频 | 一图一音（mus1..16），BGM 只播一次；报警音/报警字幕链路（EMG.*） |
| 可靠性 | 拔卡自动恢复、兜底页、S1 插播态、开卡缓存空闲自动重扫 |
| 大图素材 | 固件按 BMP 实际尺寸自动决定是否 ½ 抽稀后存 SDRAM（≥901 行抽稀） |
| 片内自测 | 菜单打开时右上角显示**当前原图分辨率**（宽×高，7 段码）——2026-10-29 新增 |
| 资源（800 版） | LUT ≈71.5%、BRAM ≈71.9%、DSP ≈79.3%、slices 4110/4108（压线，改动注意） |

**当前工作区**：`E:\FPGA\ygcom\`，多个 worktree：
`pre-release-testing`（1024 版 = 本仓库 `exp/scale-rollback`）、`build800`（800 版 = `exp/scale-rollback-800`）。

---

## 1. 五分钟上手

工具链：安路 **TD 6.2.1**（`D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116`）、板子 EG4S20BG256、
串口 115200 8N1（调试 UART 常为 COM6/COM5）。

```powershell
# 1) 编译检查（不综合，ModelSim，约 30 秒）—— 抓端口/位宽/少文件
.\check_compile.ps1

# 2) 综合 + 布局布线（约 2–3 分钟）
tools\build.ps1 -Tag MyBuild
#    产物：prj\M2_Runs\phy_1\M2.bit

# 3) 下到 SRAM 看效果（掉电即失，约 10 秒）
tools\burn.ps1 -Tag MyBuild -Port COM6 -ReadSeconds 8

# 4) 读串口遥测（33 字段 × 4 hex，0.2 s 一帧）
.\read_report.ps1 -Port COM6 -Seconds 8

# 5) FLASH 固化（掉电保存，单镜像）
tools\flash.ps1 -Bit prj\M2_Runs\phy_1\M2.bit

# 6) FLASH 双镜像（A=800×600，B=1024×768，SW3 切换）
tools\flash_mboot.ps1 -BitA 800版.bit -BitB 1024版.bit
```

> 烧录/固化都需要 Anlogic USB 下载线；没有下载线时 `burn.ps1`/`flash*.ps1` 会报
> `USB device open error`，串口也读不到数据。

---

## 2. 目录结构

| 目录 | 内容 |
|---|---|
| `rtl\` | 顶层与系统级：`top_m2.v`（7200+ 行，交付版）、`disp_top.v`（显示子顶层）、`blk_rd_arb.v`、`vendor_rd_path.v`、`dbg_report.v`、`stub_ctrl.v`、`stub_win_table.v` |
| `a_image\` | A 轨（装载）：BMP/WAV/SUB 解析、抽稀、写 SDRAM、片内自测写入器 |
| `b_display\` | B 轨（显示）：合成器、行缓冲、缩放、转场、字幕、菜单、报警、亮度、兜底页、可视化 |
| `viz2\` | 音频可视化（时域柱，`viz_time.v` / `viz_render.v`） |
| `lib\` | 公共库：SDRAM 控制器、HDMI 核、音频、SD 卡、常用工具 |
| `prj\` | TD 工程：`M2.al`（文件表）、`m2.sdc`（时序）、`m2_pin.adc`（引脚）、`al_ip\`（PLL） |
| `sim\` | ModelSim 仿真：13 个测试台 + 卡片/SDRAM/HDMI 行为模型 + 运行脚本 |
| `tools\` | 构建/烧录/固化/校验脚本，字模生成，`mboot_800.patch` |
| `docs\` | 文档（交接/结构审查/优化报告/说明书/视频脚本） |
| `bitstream_history\` | 已验证位流存档（`*_VERIFIED*` 为已上板验证） |
| `attic\` | 退役代码与历史备份（不参与综合，见 `attic/README.md`） |

---

## 3. 两个参数集：800×600 / 1024×768

两版**代码相同**，只差几组参数文件：

| 文件 | 800 版 | 1024 版 |
|---|---|---|
| `rtl\disp_top.v` | `video_timing #(.pic_wide(800), .pic_high(600))`、viz `N=24/VIS_Y=480` | `1024/768`、`N=31/VIS_Y=648` |
| `b_display\zoom_sel.v` | `K_DEN800=20972 / K_DEN600=27962` | `K_DEN800=16384 / K_DEN600=21845` |
| `lib\hdmi\my_hdmitop.v`、`lib\video\video_timing.v`、`prj\al_ip\PLL_0.v` | 800×600 时序/PLL | 1024×768 时序/PLL |
| `rtl\top_m2.v` | 少量常量（viz/坐标） | 少量常量 |

- **本分支 = 800 版（800x600 窗口）**；1024 版（1024x768 窗口）在 `exp/scale-rollback`（= `main`）分支。
- 板上 FLASH 布局（16 Mbit W25Q16）：**0x000000 放 800 镜像**、**0x0A0000 放 1024 镜像**，
  用 SW3 + 白闪遮黑屏切 MULTI BOOT。

---

## 4. 串口遥测（115200 8N1）

每 0.2 s 一帧：**33 个字段 × 4 hex = 132 字符 + CRLF**。字段表见
[`docs/交接文档_2026-10-23.md`](docs/交接文档_2026-10-23.md) §9。最常用的几个：

| 字段 | 含义 |
|---|---|
| 0/1 | `W`：已写进 SDRAM 的字数（装载进度） |
| 2 | `S`：状态位（bit0 PLL / bit1 SD 就绪 / bit2 装载中 / bit3 装完过 / bit4 A 错误 / bit7 HDMI 锁） |
| 3 | `F`：帧号（在跳 = 显示链在跑） |
| 10 | 搬运请求被丢的次数（该行显示底色） |
| 11 | 看门狗 abort 次数 |
| 23/24 | `a_wr_len`：当前装载请求的总字数 |
| 29 | 当前缩放档（0=适配） |

抓包/解码脚本：`read_report.ps1`、`tools\decode_frame.ps1`。

---

## 5. SD 卡要求（**重点**）

- 图片：24 bpp、未压缩 BMP（`AD1..AD16.bmp`；宽度/高度 ≤ 4095，超出会溢出描述符）
- 音乐：48 kHz / 单声道 / 16 bit PCM WAV（`mus1..mus16.wav`，一图一音；`EMG.wav` 报警）
- 字幕：800×64、24 bpp BMP（`SUB1..SUB16.sub`；`EMG.SUB` 报警）
- 报警图：`EMG1.bmp`；卡根目录扫描，**文件名 8.3 大写**、`EMG*` 保留给报警
- ★ **每个文件必须在卡上连续存放**：固件按「连续扇区」直读 BMP，不跟 FAT 链。
  碎片化会在屏幕上产生**横条花带**（2026-10-28 实锤踩坑）。换卡/拷图后建议整盘重写，
  并用 `FSCTL_GET_RETRIEVAL_POINTERS` 确认每个 BMP 只有 1 个 extent。
- 固件侧限制：大槽 930830 字；≥901 行的图自动 ½ 抽稀，≥1801 行 ¼ 抽稀。

---

## 6. 文档与验收材料

| 文档 | 内容 |
|---|---|
| [`docs/README.md`](docs/README.md) | 文档索引 |
| [`docs/交接文档_2026-10-23.md`](docs/交接文档_2026-10-23.md) | 工程交接（内存地图/时钟域/模块地图/串口/上手命令） |
| [`docs/工程结构审查_2026-10-24.md`](docs/工程结构审查_2026-10-24.md) | 结构/资源/时序审查、死文件清单 |
| [`docs/优化冲刺报告_2026-10-25.md`](docs/优化冲刺报告_2026-10-25.md) | P0 五项优化结果与证据 |
| [`docs/优化施工日志_2026-10-25.md`](docs/优化施工日志_2026-10-25.md) | 逐步骤施工记录 |
| [`docs/工程优化建议_2026-10-25.md`](docs/工程优化建议_2026-10-25.md) | P0/P1/P2 审计 |
| [`docs/调研_安路FPGA视频工程可优化方向_2026-10-25.md`](docs/调研_安路FPGA视频工程可优化方向_2026-10-25.md) | 外部调研 |
| [`docs/作品说明书_草稿_v0.2_2026-10-28.docx`](docs/作品说明书_草稿_v0.2_2026-10-28.docx) | 竞赛作品说明书 v0.2 |
| [`docs/演示视频脚本_2026-10-28.md`](docs/演示视频脚本_2026-10-28.md) | 演示视频脚本 |

---

## 7. 红线 / 易踩

1. **`lib\video\ref_top_video.v` 不能加进工程**——里面有个模块叫 `top`，会抢顶层。
2. **`PLL_HDMI_AUDIO` 别被标 `AutoExcluded`**，否则报 `instantiate unknown module`。
3. **`prj\m2.sdc` 四个时钟域必须写全**（50 / 40 / 100+200 / 125×2），少一对=上百条假违例。
4. **`prj\M2_Runs\` 全是中间产物**（已 gitignore），别提交；`logs\`、`_serial_logs\` 同理。
5. 别在交付仓库里跑 `tools\sync_b_display.ps1`（会把 A 侧同步过头，改 RTL 直接改本仓库）。
6. 资源已压线（LUT≈71%、BRAM≈72%、DSP≈79%、slices 4110/4108 压线通过）——
   加 BRAM 大模块前先看 `prj\M2_Runs\syn_1\gate.qor`。
7. SDRAM 0°/180° 等负 slack 是已知假违例（`set_clock_groups` 已覆盖），
   不要为了"清零"去改约束。
