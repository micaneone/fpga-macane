# 比特流历史 / 回退清单

> 这个文件夹是**回退用的**：每一版都记着"是什么、上板什么结论"。
> 烧录方法：TD 里 `Tools → Download`，选下面那个 `.bin`（和 `.bit` 是同一种文件）。
>
> **★ 每次上板验证通过的版本都要改名成 `M2_VERIFIED_<日期>_<内容>.bin` 放进这里**，
> 这样"哪天要退回去"永远只需要打开这个文件看第一张表。

---

## 一、烧哪个？（按"最近一次确认可用"往下找）

| 优先级 | 文件 | 上板结论 | 说明 |
| --- | --- | --- | --- |
| ★★★ **首选** | **`M2_VERIFIED_20261008_audioON_blkReadPath.bin`** | ✅ **用户确认可用**（2026-10-08）| 当前正式版本：**图 + 转场 + 音频**全都在（`AUDIO_OFF = 0`）|
| ★ 新出的（等上板）| `M2_20261008_1835_sdRead25MHz_audioON.bin` | 🟡 **没上过板** | 在首选那一版基础上**把 SD 读从 12.5 MHz 提到 25 MHz**（米白时长应减半）。判读：`规划\B轨待改清单.md` §21 |
| 备选 A | `M2_20261006_1753_blkReadPath_displayFix_audioOFF.bin` | ✅ 可用（音频关）| 同一套显示读通路、**音频全关**。音频万一出问题就退这个 |
| 备选 B | `M2_20261006_1256_audioOFF.bin` | ✅ 可用（音频关，旧读通路）| 重构之前的干净基线（`git tag baseline-audiooff-20261006`）|
| ⚠️ 别烧 | `M2_20261006_vendorReadPath_audioOFF.bin` | ❌ **白屏** | 读通路重构中途那版（黑盒/接线错），留着当反面教材 |
| ⚠️ 别烧 | `M2_20261006_1829_audioON_blkReadPath.bin` | 🟡 没上过板 | 和首选那版**同一份源码**，只是 10-06 那次的布线结果；真要退也行，但首选是 10-08 上过板的那一份 |
| 历史 | `M2_20261005_1840_firstAudioBuild.bin` | ❌ 杂音 + 白条 | 第一次把音频并进来那版（证据在 `规划\A轨待改清单.md`）|

---

## 二、首选那一版的完整信息

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
