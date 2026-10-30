# attic/ — 退役但不想丢的代码（2026-10-24 归档）

这里放**没有进 `prj/M2.al`、也没有被任何在册文件实例化**的项目代码。
它们不参与综合/布局布线（TD 根本不编译它们），但会干扰阅读和全局搜索，
所以从 `rtl/ a_image/ b_display/ viz2/ prj/` 移到此处。

**Git 历史完整保留**（都是 `git mv`），需要时 `git mv` 回去即可，例如：

```powershell
git mv attic/rtl/pix_check.v rtl/pix_check.v
```

判定与复查：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\check_filelist.ps1
```

关注输出里的 `UNLISTED & UNUSED`（项目死代码）与 `UNLISTED DUPLICATE COPY`
（在册模块的陈旧副本）两类。`UNUSED LIB / _unused` 属于 `lib\` 公共库池，
是"参考实现库存"，**没有**搬到这里。

## rtl/

| 文件 | 为什么退役 |
|---|---|
| `pix_check.v` | 早期"像素域一致性检查"探针，功能已被 `dbg_report` 串口字段取代 |
| `stub_a_writer.v` | stub 版 A 写口（现由 `vendor_rd_path.v` / `top_a.v` 承担） |
| `vendor_read_test.v` | 厂商 SD 读口试验代码 |
| `disp_top.v.bak_vizfreq` | 手改备份（可视化频率探针版） |

## a_image/

| 文件 | 为什么退役 |
|---|---|
| `sdr_rd_arb.v` | 旧 A 轨读仲裁；现在用 `rtl\vendor_rd_path.v`（M2.al 只登记后者） |
| `top_a.v.bak_2312` | 手改备份（2023-12 版） |

## b_display/

`bilinear.v` / `canvas_xform.v` / `menu_ovl.v`（旧英文菜单，现用 `menu_ovl_cn.v`）/
`status_tx.v` / `udiv_q16_up.v` / `win_sample.v` / `win_zsel.v`
—— 旧显示链路遗留，当前 `disp_top.v` 已不实例化它们。
（`b_display\_font32_unused\font32_rom.v` 仍留在原处：目录名已经标注 unused。）

## viz2/

| 文件 | 说明 |
|---|---|
| `viz_freq.v` | 旧柱状可视化（现用 `viz_render.v`） |
| `viz_top.v` | 旧视觉顶层 |
| `_wtest.txt` | 0 字节杂项文件 |

## sim/

| 文件 | 说明 |
|---|---|
| `menu_render.txt` | `tb_menu_font.v` 导出的菜单全屏 dot 渲染（197 KB），供 `dump_text.ps1` / `dump_val.ps1` / `pair_dump.ps1` 做报告配图 |
| `menu_render_reference.txt` | 同一渲染的参考版（123 KB） |

2026-10-29 从 `sim/` 移入（它们是**参考产物**，不是源码；仿真运行时会重新生成到 sim/ 下，
`.gitignore` 已忽略 `sim/menu_cn*.ppm` 类中间产物）。

## prj/

只保留 1 个 `M2.al.bak_20261017_before_A2`：A2 改动前的手工副本。
其余 7 个历史备份（重登记、去重、亮度、viz 等）已于 2026-10-29 删除——
M2.al 的完整历史在 `git log -p prj/M2.al` 里，手工副本不再需要。
