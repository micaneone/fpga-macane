# 比特流历史 / 回退清单

> 这个文件夹是**回退用的**：每一版都记着"是什么、上板什么结论"。
> 烧录方法：TD 里 `Tools → Download`，选下面那个 `.bin`（和 `.bit` 是同一种文件）。
>
> **★ 每次上板验证通过的版本都要改名成 `M2_VERIFIED_<日期>_<内容>.bin` 放进这里**，
> 这样"哪天要退回去"永远只需要打开这个文件看第一张表。

---

## ★ 写进配置 FLASH（掉电不丢）—— 2026-10-14 首次做

> `Tools → Download` 只把位流塞进 FPGA 的 SRAM，**掉电就没了**（丢电即失）。
> 要"永久版"必须写**板上那颗外部配置 FLASH**。

| 项 | 值 |
| --- | --- |
| FLASH 型号 | **Winbond W25Q32**（JEDEC ID `EF 40 15` = 4 MB / 32 Mbit）|
| 工具 | **`bin\bw_commands_prompt.exe`**（= BitWizard 的命令行；**不是** `td_commands_prompt.exe`）|
| 完整命令 | `download -bit <绝对路径>.bit -mode program_spi -spd 6 -cable 0` |
| 本次实测耗时 | 擦+写 **116.3 s**（整条 download 119.4 s），`rc=0` |
| 回读校验 | `download -bit <同一份>.bit -mode verify_spi -spd 6 -cable 0` ⇒ **0 条 `PRG-9508`，`rc=0`** |

★ **为什么必须用 `bw_commands_prompt.exe`**：`program_spi` 这个子命令**只注册在 BitWizard 里**。
用 `td_commands_prompt.exe` 跑同一条 `download -mode program_spi` 会在写完之前就报
`invalid command name "program_spi"`（**没有写进 flash，也不会写坏**，见 2026-10-14 的实测）——
不是开关/跳线的问题，别去乱拨开关。

★ 出处：Anlogic **SWUG110《BitWizard 使用指南》§4.2.2 Program Flash**（原文：
"可通过 Program flash 选项将位流文件下载到 Flash，**掉电不丢失**"）；
命令行的用法串在 `bin\bw.exe` 里（`download -d -mode <jtag|program_spi|verify_spi|erase_spi|x_rdbk|refresh> ...`，
以及 GUI 自己拼的那句 `download -%1 "%2" -mode %3 -spd %4 -cable 0`）。


### ★★ FLASH 里现在装的是哪一版（**每次固化都要更新这一小节**）

| 固化时间 | 写入的文件 | SHA256（前 8） | 结果 |
| --- | --- | --- | --- |
| **2026-10-17 23:49** | `M2_VERIFIED_20261017_2334_vizTime_bri.bin`（= `burn\M2_bri_20261017.bit`）| `69CD374C` | `program_spi` **116.7 s**、`verify_spi` **rc=0 / 0 条 PRG-9508**；FLASH ID `ef`（Winbond）|
| 2026-10-14（已被上面覆盖）| `M2_sw3_4clips.bit`（10-14 收工版）| — | 擦+写 116.3 s、回读 0 条 PRG-9508 |

★ **含义变了，注意**：以前"断电重上电"是回到 10-14 那个旧版；**现在断电起来就是 `M2_VERIFIED_20261017_2334_vizTime_bri`**
（菜单第 3 行 = `BRIGHT` 亮度调节 + 字体放大 + 可视化 + 音量进菜单 + 本轮 bug 修复）。
要回到更早的版本**只能重新烧 SRAM**（`td_download.tcl`）或重新 `program_spi` 写 flash。
★ 一份可直接复用的脚本：`E:\FPGA\ygcom\flash_program_bri.tcl`（改第一行 `set f` 即可换目标）。
---

## 一、烧哪个？（按"最近一次确认可用"往下找）

| 优先级 | 文件 | 上板结论 | 说明 |
| --- | --- | --- | --- |
| ★★★★ **参数菜单·第 1 步（自动验证已过 · ⚠ 菜单未做目视确认）** | **`M2_MENU_20261016_step1_nav.bin`** | 🟡 **串口自动证据已过，但菜单的目视确认待补 ⇒ 暂不烧 flash（flash 里仍是 2026-10-14 的收工版，可用"断电重上电"回退）** | **★ 命名故意不带 `VERIFIED`**（菜单目视待补）。**内容**：① **参数菜单第 1 步** —— **SW2（C7）** 拨动开关 = 菜单开/关（每拨一次 `menu_on` 翻转）；**SW1（C8）** 是两档拨动开关 ⇒ **只能当"方向状态位（电平）"用**（同步后 `menu_dir = sw1`，1 = 上），**菜单打开时 KEY3（B1）每按一次就按 `menu_dir` 移动光标**（4 项、两端回绕），**且此时 KEY3 不换图**（门控 `key3 \| menu_on`：按键低有效 ⇒ `menu_on = 1` 时该门恒为 1，`stub_ctrl` 的消抖器永远看不到"按下"）；**KEY2（B2）** 的"确定"消抖脉冲**已就位但尚未接到任何参数**；菜单画面 = **320×200 面板 + 4 行高亮条，暂无文字**（新模块 `b_display\menu_ovl.v`）。② **音频溢出保护** —— **播放长度（`sdr_len`）与写入长度（采样放行数）两处都夹到 `AUDIO_MAX_WORDS = 120000 字 = 5.0 s @48 kHz 单声道 16 bit`**，超过部分**不写也不播**（护住音效区后面的小槽区 / 字幕区；**不夹长度 ⇒ 超长 WAV 会把写指针推过音效区边界，一旦压到小槽区/字幕区就是卡死 / 画面坏掉**）。③ **音频 FIFO 已搬进 BRAM**（`a_image\aud_blk_rd.v`：`u_aud_blk_rd` **LUT 1133 → 317、+2 BRAM**，全器件 **LUT −1136**，**slice 84.26% → 78.16%**）。**资源实测（综合）**：**LUT 13195/19600 = 67.32%**、**REG 9421**、**BRAM 46/64**、**DSP 19/29**、**slice ~81.0%**；**时序 SWNS −6.692 ns（结构性、历来如此）/ HWNS +0.019 ns**。**自动验证证据（串口）**：字幕指纹 **`98C2`/`08EA`** 与基线**逐位一致**、字段 28 = **`67B3`**、音频字数 **`F300`**。SHA256 `1E37311315B6C217C178B77DFB63CB8D0096431D79754A935FB8D03F981759C9`，与 `E:\FPGA\ygcom\burn\M2_menu_step2.bit`（以及 `prj\M2_Runs\phy_1\M2.bit`）**逐字节相同**（SHA256 已核）。**已知小风险**：**关菜单那一拍若正按住 KEY3，可能误发一次换图**（门控是组合逻辑，`menu_on` 落下的同一拍按键仍可能被消抖器采到） |
| ★★★★ **2026-10-17 23:34 菜单加「亮度」+ 上一条的 bug 修复（已固化 FLASH · 串口自动验证已过）** | **`M2_VERIFIED_20261017_2334_vizTime_bri.bin`** | 🟢 **已烧 SRAM 验证 + 已【固化】进配置 FLASH（2026-10-17 23:49 做完：`program_spi` 116.7 s、`verify_spi` rc=0 无 PRG-9508）** | **内容** = 上一行那版（bug 修复轮）**加上菜单第 3 行 `BRIGHT` 亮度调节**：`bri_lv` 0..15（**默认 15 = 原样**，数学上 `(c×16)>>4 = c` 逐位恒等），手势与 VOLUME 完全一致（光标到 BRIGHT 行 + KEY2 进调节态 + KEY3 按 SW1 方向 ±1，夹住不绕回，软复位保留）。新模块 `b_display\bri_scale.v`（纯组合 0 拍延迟，插在 subtitle 之后 / menu 之前 ⇒ **压暗画面+可视化+字幕，菜单面板不压暗**）；菜单第 3 行由占位 `EXIT` 换成 `BRIGHT`（两位十进制）。**串口字段 21 高 4 位改成 `bri_lv`** ⇒ 默认读 `F000`。**资源实测**：`#lut 13858/19600 = 70.70%`（+23）、`DSP 20 → 22/29`、`mslice 4013 / lslice 4008`、`slices 81.88%`、`Hold WNS +0.003 ns`。**自动验证证据**：`sim\tb_bri_scale.v` 穷举 17 档×65536 色 **bad=0 / 非单调=0**（且 bri=15 逐位透传）；`sim\tb_menu_font.v` 扩到 **6 组黄金对照（setA..setF）全 0 bad**，`menu_on=0` 逐位透传 0/69558、面板漏底 0/64000。**上板（串口）**：status `008B`（fail=0）、px `00075300`=480000、字段 6..9 全 0、字幕指纹 `98C2`/`08EA`、**21 = `F000`（亮度 15）**、26 = `000F`（音量满）、27 = `0000`、28 = `67B3`。SHA256 `69CD374C0C7D2C0962E99C10D50721F0D117C07B9E484374FAAE9E3E281A8AED`（与 `E:\FPGA\ygcom\burn\M2_bri_20261017.bit` 逐字节相同） |
| ★★★★ **2026-10-17 23:07 可视化时间域版 + bug 修复轮（串口自动验证已过 · ⚠ 目视/听感待用户确认）** | **`M2_20261017_2307_vizTime_bugfix.bin`** | 🟡 **串口自动证据已过（下面逐格列出），人眼/听感确认待补 ⇒ 暂不烧 flash** | **内容** = 板上此前那版（`M2_trim2_viz` = 时间域可视化 32 根柱 + 音量进菜单 + 软边转场 + 行/列抽取）**加上本轮 6 处 bug 修复**：① `bmp_analyze` 丢掉 BMP 行填充（`W*3%4!=0` 的图会整图错行）；② `bmp_analyze` 行尾 seek 与 `rd_done` 同拍竞态（`cur_lba` 多跳一个扇区）；③ `sel_aud` 补复位；④ `aud_fail` 死锁（音频装载失败后 SW3 永久失效 → 现在可重试）；⑤ 删死宏 `B_SELFTEST` + 修过期注释；⑥ `M2.al` 删掉重复的 `audio_arc_calculate` 登记（`HDL-7201/7307` 消失）。另清掉"最左列逐行扫描"死探针（串口字段 6~9 从此真为常量 0）。**资源实测**：`#lut 13835/19600 = 70.59%`、`#registers 8529`、`mslice 4017 / lslice 4013`（上限 4900）、`slices 81.98%`、`BRAM 46/64`、`DSP 20/29`；`Setup WNS −6.692 ns`（结构性、历来如此）/ `Hold WNS +0.003 ns`。**自动验证证据（串口，33 字段）**：status `008B`（PLLs+sd_ready+load_done+hdmi，fail=0）、`px=0x00075300=480000`（800×600）、A 推字数低 16 `A980`=43392 ⇒ 240000 字 ✓、字段 6~9 **全 0**、字幕指纹 **`98C2`/`08EA`**（与基线逐位一致）、字段 28 = **`67B3`**（音频 loaded/PLL、字幕 loaded、fail=0）、字段 26（音量）= `000F`、27（sel_aud）= `0000`、12 bit1（块级读掐断）= **0**、21/22 = 0（轮播关/菜单关/zoom 适配档）。SHA256 `29175EBB9BCE2D569519BABE2CD17151328357AFE08A3EBBC53F7C1C96F8ADED`（与 `E:\FPGA\ygcom\burn\M2_bugfix1_20261017.bit` 逐字节相同） |
| ★★★★ **本轮优化版（面积削减 · 自动验证已过 · ⚠ 未做目视确认）** | **`M2_OPT_20261015_lut13442_dsp19.bin`** | 🟡 **自动验证已通过，但用户目视确认待补 ⇒ 暂不烧 flash（flash 里仍是旧的已验证版）** | **★ 命名故意不带 `VERIFIED`**：这一版的**自动验证已过**，但**用户目视确认（画面 / KEY4 / 抢前端 / SW3 / 拔插卡）待补**，按本文件的开头规矩不配 `VERIFIED` 名。**自动验证证据（串口）**：字幕指纹 **`98C2`/`08EA`** 与优化前**逐位一致**、A 链最后一次请求长度 = **`0640` = 1600 字**（字幕遮罩标准字数）、字段 28 = **`67B3`**（音频 + 字幕 **loaded**、**fail = 0**）、字段 12 bit1 = **0**（无看门狗掐断）、演示 BMP 全是 **640×480 = 153,600 字** ≪ **930,830** 上限。**三刀内容**：① **三条链的 SD 前端**（`sd_top` + `sd_init` + `sd_read_cdc` + `sd_read` + `my_spi`）**合并成一份**、由 `sd_mode_r` 选主（**事务中途不换手**：`sd_mode_r` 仍只在 `start && !sd_busy` 锁存）；② `find_bmp` 三处"簇号 × `sec_per_clus`"改成 **log2 译码 + 左移**（FAT32 规定 SecPerClus 必为 2 的幂 ⇒ mod 2³² 逐位等价），非法值补 `fail`；③ `num_fats × fat_size` → **`<<1`** + **`NumFATs != 2 → fail`**（FAT32 规定恒为 2）。**资源实测（综合）**：**LUT 14149 → 13442（68.58%）、DSP 29 → 19（空 10）、REG 9647 → 9239**；**BRAM 44/64 不变**；**时序 SWNS −6.692 ns / HWNS +0.011 ns 不变**；三个 `find_bmp` 的 **DSP 6/6/4 → 0/0/0**；综合 `#MACRO_MULT` **26 → 17**。SHA256 `4C143B5A95CD8FEBC9FF3F30E982DE319004ADF46AF0C99865541ABFB7844268`，与 `E:\FPGA\ygcom\burn\M2_opt_r5.bit`（以及 `prj\M2_Runs\phy_1\M2.bit`）**逐字节相同**（SHA256 已核） |
| ★★★★★ **4 条音频 + 字幕滚动版（最新 · ★ 已写进配置 FLASH = 永久版）** | **`M2_VERIFIED_20261014_sw3audio4_subscroll.bin`** | ✅ **用户 2026-10-14 收工前确认：字幕出来 / KEY3 换图 / SW3(C6) 在 4 条音频间循环 / SW4(C5) 让字幕水平滚；音频"失真 / 连按 / 空置"三个老毛病都不再复现** | **关键内容**：**A 轨 `top_a.v` 新版**（去掉 `bmp_scale` ⇒ 图像**不再缩放**、源图直连 `bmp2sdram`；A 轨只剩 `sys_clk` 一个时钟域 ⇒ **SD 读 12.5 MHz**，装图时间约翻倍）+ **删除 `a_image\bmp_scale.v`** + **SW3(C6) 切 4 条音频**（新模块 `lib\util\sw_edge_debounce.v` 双边沿消抖；KEY3 从此**只管换图**，不再顺带换/播音频）+ **SW4(C5) 字幕水平滚动**（`subtitle_ovl` 每帧帧首 +1 像素、按 800 回绕；拨回去帧首清 0 ⇒ 立刻回静止原位）+ **字幕带洗淡**（`SUB_FADE_SEL=1`：整条横带的**底图**往白混 1/2，黑字本身不动）+ **`find_bmp` 根目录跨簇扫描**（上界从 1 个簇放到 256 扇区、地址式改 `sd_lba+1`，**零新增寄存器**）+ **音频三条修复**（① 播放长度 = **实际字数**，不再用 stride ② 开播**清空 FIFO**，治开头那声"啵" ③ 块长与 FIFO 深度**同时减半到 256**，保住 `ROOM_LIMIT=0` 这条"永不读写重叠"的被验证性质）+ **`SFX_NUM=4`**。SHA256 `3BBB3CA144289AF48C9AF6E47183BF9A595D959680B2B58567289C98D24628C3`；与 `prj\M2_Runs\phy_1\M2.bit` **逐字节相同**（SHA256 已核）。已用 `bw_commands_prompt.exe` 写进配置 FLASH 并**回读校验通过**（见上面那一节）。**已知偏差（调试临时占用，下次收尾要还原）**：串口**字段 26** = 音频 FIFO 饿穿探针（应还原成 `wr_bursts`）、串口**字段 27** = `sel_aud`（应还原成 `clash_cyc`）、`b_display\subtitle_ovl.v` 的**倒字探针** `o_dump_idx`/`o_dump_word`（串口字段 21/22/25）、`a_image\aud_blk_rd.v` 里那条**永远不会成立**的旧饿穿探针 `aud_next && !aud_vld` |
| ★★★★★ **音频修好版** | **`M2_VERIFIED_20261014_audioFixed.bin`** | ✅ **用户确认"失真没了 + 连按正常 + 空置 15 分钟也不杂音"**（2026-10-14）| **音频四条修复版**（源码 = 分支 `refactor-vendor-rd` 提交 `0a3847b`）：① 音频装载选择由单拍脉冲改回 **`aud_want` 电平**（治"一片沙沙"）② `SFX_STRIDE` 120000→**72000**（治"放完又沙沙"）③ 音频块 `BLK_WORDS` 64→**512**（治"每 64 字一条块边界接缝"造成的**失真**）④ 按 KEY3 **重新装载音效**（与图片同构；治"空置久了变坏 / 换图时的杂音"）。SHA256 `81C205DE…`；串口佐证：S=008B、字幕指纹 19=`C003`/20=`0951`、静置 14s 0 次自动重播。完整证据链见交付仓库《规划\B轨待改清单.md》§30.8~§30.21 |
| ★★★★★ **RC3（上一候选发布版）** | **`M2_RC3_20261008_writeFix.bin`** | ✅ **用户确认"测试正常"**（2026-10-08 深夜）| **写通路补丁版**：采纳 A 的修①（`S_ACK` 的 `fifo_aclr` 改定长 8 拍）+ 修⑤ ⇒ **每笔写不再丢头 2 个字**。SHA256 `0DFE017D…`；tag `M2_rc3_20261008`（源码 `4818b72`）。生成 23:15 |
| ★★★★ **RC2（上一版 / 退路）** | **`M2_RC2_20261008_prefetch.bin`** | ✅ **用户确认"成功"**（2026-10-08 晚）| **预装版**：IDLE 期间提前装下一张 ⇒ 按 KEY3 **转场立刻开始**（不再有 0.3~1.8 s 的等待）（**只差写通路补丁**）。SHA256 `5CFE6CAA…`；tag `M2_rc2_20261008`。生成 22:10 |
| ★★★★ **RC1（上一版 / 退路）** | **`M2_RC1_20261008_rwArbitration.bin`** | ✅ **用户确认"完全实现预期功能"**（2026-10-08 晚）| **原厂读写仲裁版**：装载期间**一直显示旧图**（无米白）+ 新图正常 ⇒ **无白屏转场成立**（**只差预装**）。SHA256 `4C8F3F61…`；tag `M2_rc1_20261008` |
| ★★★★ **演示版（demo-ready）** | **`M2_20261008_1835_sdRead25MHz_audioON.bin`** | ✅ **用户确认成功、可以拿来演示**（2026-10-08）| **可演示的候选发布版（Release Candidate）**：图 + 转场 + 音频 + **SD 读 25 MHz**（装载时间减半）。tag `M2_demo_ready_20261008` |
| ★ 实验版（已被 RC1 取代）| `M2_20261008_1930_rwArbExperiment.bin` | 🟡 没单独上过板 | 和 RC1 **同一份源码**（同一个 bit 内容），只是我先归档的那份。**烧 RC1 就行** |
| ★★ 上一版（也是好的）| `M2_VERIFIED_20261008_audioON_blkReadPath.bin` | ✅ 用户确认可用（更早）| 和演示版差**只有 SD 读时钟**（12.5 MHz）。演示版万一哪天出问题，退这一份 |
| 备选 A | `M2_20261006_1753_blkReadPath_displayFix_audioOFF.bin` | ✅ 可用（音频关）| 同一套显示读通路、**音频全关**。音频万一出问题就退这个 |
| 备选 B | `M2_20261006_1256_audioOFF.bin` | ✅ 可用（音频关，旧读通路）| 重构之前的干净基线（`git tag baseline-audiooff-20261006`）|
| ⚠️ 别烧 | `M2_20261006_vendorReadPath_audioOFF.bin` | ❌ **白屏** | 读通路重构中途那版（黑盒/接线错），留着当反面教材 |
| ⚠️ 别烧 | `M2_20261006_1829_audioON_blkReadPath.bin` | 🟡 没上过板 | 和首选那版**同一份源码**，只是 10-06 那次的布线结果；真要退也行，但首选是 10-08 上过板的那一份 |
| 历史 | `M2_20261005_1840_firstAudioBuild.bin` | ❌ 杂音 + 白条 | 第一次把音频并进来那版（证据在 `规划\A轨待改清单.md`）|

---

## 二、首选那一版的完整信息

> ### ✅✅ 2026-10-08 晚：**演示版（demo-ready）已确认**
> 用户烧了 18:35 那版（SD 读 25 MHz）后回报"**成功，目前这个版本可以用来演示**"。
> ⇒ **`M2_20261008_1835_sdRead25MHz_audioON.bin` 就是演示版首选**，
> 源码 tag = **`M2_demo_ready_20261008`**。
> 术语：这一档在软件工程里叫 **Release Candidate（RC，候选发布版）** ——
> 功能齐、已通过"能不能演示"这一道验证；再往上一档（正式交付/送审）叫 **Release / GA**。

| 项 | 值 |
| --- | --- |
| 文件 | `bitstream_history\M2_VERIFIED_20261008_audioON_blkReadPath.bin` |
| SHA256 | `357330F696CE1044EA084CBC7DB18931F7D0CA7F09E01AB66A8F571932F74534` |
| 生成时间 | 2026-10-08 16:54（TD 6.2.1，`prj\M2_Runs\phy_1\M2.bit` 同一份）|
| **源码版本** | 本仓库 `refactor-vendor-rd` 分支 **`3f9dc7e`**（tag **`M2_verified_20261008`**）|
| 顶层 | `rtl\top_m2.v`，`AUDIO_OFF = 1'b0`（音频开）|
| 资源 | LUT 14,345 / 19,600（73.2%）· REG 8,746 · BRAM 57/64 · DSP 29/29 |
| 时序 | setup −6.692 ns / 141 端点（老底子：像素域 h_cnt→scaler、SDRAM dq）；**hold 每域 0 条违例** |
| 上板现象 | 图正常、转场正常、**有声音**；用户 2026-10-08 确认"当前版本可用" |
| 配套 SD 卡 | 根目录只放 `onboard_test\sd_card_sfx\SFX0.WAV`（3.000 s / 48 kHz / 单声道 / 16 bit）|

### 怎么回到这个版本

```powershell
# ① 只要比特流（最快）：TD → Tools → Download → 选
#    bitstream_history\M2_VERIFIED_20261008_audioON_blkReadPath.bin

# ② 要源码也回到这一版：
cd E:\study\fpga\onboard_test\M2_scale
git checkout M2_verified_20261008      # 或者 git checkout 3f9dc7e

# ③ 要重新出比特流：
cd prj\M2_Runs\syn_1 ; & 'E:\study\fpga\anlu\TD_engineer\bin\td_commands_prompt.exe' `
    'E:/study/fpga/anlu/TD_engineer/doc/scripts/DefaultFlow.tcl'
cd ..\phy_1          ; & 'E:\study\fpga\anlu\TD_engineer\bin\td_commands_prompt.exe' `
    'E:/study/fpga/anlu/TD_engineer/doc/scripts/DefaultFlow.tcl'
```

★ 注意：**重新布线的比特流和上面那个不是逐字节相同的**（TD 的布局布线不确定），
但功能和时序结论一致（面积/时序数字一模一样）。要"原样"就烧这个 `.bin`。

---

## 三、这批比特流对应的时间线（为什么要改）

| 日期 | 改了什么 | 上板结论 |
| --- | --- | --- |
| 10-05 | 第一次把音频并进 M2（显示和音频**逐拍抢读口**，靠 tag 队列分流）| 图 + 音都出，但**白条 + 沙沙声**，且噪声随图变大 |
| 10-05 晚 | 修时序（hold 24 条违例 → 0）、改 tag 队列重同步 | 白条少了、杂音照旧 ⇒ **病根不是时序** |
| 10-06 | **读通路重构**：改成块级仲裁（`blk_rd_arb` + `vendor_rd_path`），tag 队列整套删掉 | 中途出过白屏（6 个 bug 全在仿真里逮到并修掉，见 `规划\B轨待改清单.md` §19）|
| 10-06 晚 | 音频也改走**块级口**（`aud_blk_rd.v`），`AUDIO_OFF = 0` | 等上板 |
| **10-08** | （源码未变，重新出流）| ✅ **上板确认可用** ← 就是首选那一版 |
