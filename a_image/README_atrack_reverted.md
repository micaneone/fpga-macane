# ★★★ 2026-10-17：A 轨 5 个文件已回退到 HEAD（`3e78402`）

> ## ⚠️ 本文档是【历史记录】，其中两处结论早已过时（2026-10-17 晚核对）
>
> 1. **A 轨现在已合流**（"A 轨解析器合流"那一步做完并上板验证：图/音频/字幕都能装），
>    不再是本文描述的"回退到 HEAD + 备份"状态。当前状态以
>    `../交接文档_2026-10-17.md` 为准。
> 2. 本文第 37~44 行说 `eng_owner_sel` 的问题"本次没有动它" —— **已经修好了**：
>    `a_image/top_a.v` 现在是 `assign eng_owner_sel = eng_start_bmp | eng_start_wav | eng_start_sub;`
>    （= 发起者当家），并用 `assign eng_use = eng_busy_o;`（引擎自己的 busy），
>    见 `top_a.v` 里 "2026-10-17 修正" 那段注释。
>
> 保留本文只为记住"为什么回退过、23:12 那版死在哪"，**不要照着它去恢复文件**。

**这是为了让工程能出可用比特流而做的回退，不是清理 viz 的一部分。**
原工作区改动**没有被丢弃**，全部有备份（见下）。

## 回退了什么

| 文件 | 回退到 | 备份 |
|---|---|---|
| `a_image/top_a.v` | HEAD | `a_image/top_a.v.bak_2312`（23:12 原版，含 bug）<br>`../../.diag_backup_2312fix/top_a.v`（23:12 版 + 多重驱动已修） |
| `a_image/find_bmp.v` | HEAD | `../../.diag_backup_2312fix/find_bmp.v` |
| `a_image/bmp_analyze.v` | HEAD | `../../.diag_backup_2312fix/bmp_analyze.v` |
| `a_image/wav_analyze.v` | HEAD | `../../.diag_backup_2312fix/wav_analyze.v` |
| `a_image/sub_analyze.v` | HEAD | `../../.diag_backup_2312fix/sub_analyze.v` |

## 为什么要回退（受控 A/B 实测，只动这 5 个文件）

| 配置 | LUT | mslice | BRAM | DSP | slices% | phy |
|---|---|---|---|---|---|---|
| A 轨 @ HEAD，`VIZ2_ON=0` | 13465 | 4061 | 46 | 19 | 82.67% | 通过（**逐项复现 22:58 基线**） |
| A 轨 @ HEAD，`VIZ2_ON=1` | 15693 | 4612 | 46 | 19 | 94.01% | 通过 |
| 23:12 `切法C` 重构，`VIZ2_ON=1` | **4324** | **1460** | **14** | **0** | 29.87% | 通过，但**设计是坏的** |

**判定"坏"的依据**：`b_display/scaler_addr.v`（显示缩放/几何，与 A 轨重构无关、两个
构建里源码完全相同）里有 ~8 个真乘法器（`xp10*step12`、`yp_m*step_m`、`v_store0*wpl` …），
而 `a_image/find_bmp.v` 里**一个乘法器都没有**。重构那版整设计 **0 个乘法器 / 0 DSP**
⇒ 不是"A 轨去重省了 9k LUT"，而是**整条显示缩放通路被常数传播折掉了**
（`udiv_q16_up`/`scaler_addr` 仍被 elaborate，但逻辑已折平）。

## 23:12 那版 `切法C` 已知的两个问题（未改，留给 A 轨作者）

1. `top_a.v` 残留两条 `assign eng_lba_o/eng_req_o = <三选一 mux>`，与唯一引擎
   `find_bmp_eng` 的输出端口**同驱一根 net**，且右值三组网线**无驱动**
   ⇒ `HDL-8007 ... driven from multiple places` ⇒ `top_a` 变黑盒 ⇒ `syn_1` 崩。
   （修法：只删那两条 assign + 3 行悬空声明。修好的整份文件在
   `.diag_backup_2312fix/top_a.v`。）
2. `top_a.v`：`assign eng_owner_sel = eng_start_wav | eng_start_sub;`
   ⇒ 只有 `sd_mode==1/2` 时 owner=1；**装图（`sd_mode==0`）时 owner=0**
   ⇒ 引擎内部 `sd_ok/sd_done/sd_busy/sd_err` 全被 `owner_r` 门成 0
   ⇒ 引擎看不见前端应答 ⇒ 装图必然走看门狗失败。
   按三个薄壳的端口注释（`eng_owner` = 本链是否当家）与 HEAD 版的
   `.fe_owner(mode_is_bmp/wav/sub)` 口径，正确写法应让"发起者当家"成立
   （例如直接用三个薄壳的 `eng_owner` 输出，或 `eng_owner_sel = eng_start`）。
   **本次没有动它** —— 它会改变 A 轨行为，需作者确认。

## 一键恢复 23:12 那版（含多重驱动修复）

```powershell
copy ..\..\.diag_backup_2312fix\*.v . -Force
```
（然后重跑 `E:/FPGA/ygcom/td_build3.tcl`；**恢复后工程能综合，但显示缩放通路仍是折掉的，
`eng_owner_sel` 也还没修 —— 直接烧录前请先让 A 轨作者确认。）**
