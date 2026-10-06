# `top_a` 使用说明（给集成方 / B 轨）

> **这份文件说明**：`rtl\top_a.v` 是 A 轨对外交付的**唯一入口模块**。
> 这份说明讲清楚：它是什么、怎么例化、怎么调用、有什么不能踩的坑、哪些还没验证过。
>
> **写于** 2026-10-01。使用前如果 `top_a.v` 又改过，以文件本身为准。

---

## 〇、先搞清楚它是什么

```
        ┌─────────────────────────── top_a ───────────────────────────┐
SD 卡 ──┤ ┌── 图像链：bmp_analyze → bmp_scale → bmp2sdram ──┐        │
        │ │                                                  │        │
        │ └── 音频链：wav_analyze ────────→ wav2sdram ──────┤        │
        │                                                   │        │
        │      desc_tx（组描述符）───────────────────────────┘        │
        └───────┬──────────────────────┬──────────────────────┬───────┘
                │                      │                      │
        SD 卡引脚（已二选一）    SDRAM 写口（已二选一）    描述符口
              → SD 座            → sdr_arb（★ 在外面）    → desc_rx
```

**三条最重要的性质：**

1. **`top_a` 里没有 SDRAM 控制器。** 全项目只能例化一个 `sdr_arb`，它归集成顶层。
   `top_a` 只提供一组写口信号，由顶层接到 `sdr_arb` 上。
2. **`top_a` 里没有状态机、没有队列。** 它只做"执行一条命令"：
   给一个 `start` 脉冲 → 装一张图 **或** 一条音频 → 拉一下 `load_done` / `wav_done`。
   **先装什么后装什么、装几条，全由外面的调用逻辑决定。**
3. **图片链和音频链共用同一根 SD 卡引脚**，所以物理上**只能串行**，一次一条。

---

## 一、例化模板（可直接抄）

```verilog
top_a #(
    .SLOT_NUM (2)                  // ★ 必须和 desc_rx 的 SLOT_NUM 一致
) u_top_a (
    .sys_clk     (clk_ctl),        // 50 MHz 控制域
    .sys_rst_n   (rst_ctl_n),

    // ---- SD 卡引脚：内部二选一后接出去，外面直接接 SD 座 ----
    .spi_miso    (sd_miso),
    .spi_mosi    (sd_mosi),
    .spi_clk     (sd_clk),
    .spi_cs      (sd_cs),

    // ---- 命令 ----
    .start       (a_start),        // 单拍脉冲
    .sd_to_wav   (a_to_wav),       // 0 = 这次装图，1 = 这次装音频
    .skip        (a_skip),         // 第几个图 / 第几条音频

    .use_slot    (a_slot),         // 装到哪个槽（0 / 1）
    .slot_base   (a_slot_base),    // 槽基址，字地址
    .img_no      (a_img_no),       // 图号，进描述符

    .sfx_base    (a_sfx_base),     // 音效区基址 + 条号 × STRIDE

    // ---- 状态回报 ----
    .busy        (a_busy),
    .load_done   (a_load_done),    // 单拍：整帧图写进 SDRAM
    .desc_done   (a_desc_done),    // 单拍：描述符生效
    .ready_n     (a_ready_n),      // 和 desc_done 同拍：第几张就绪
    .wav_done    (a_wav_done),     // 单拍：这条音频写进 SDRAM
    .fail        (a_fail),
    .sd_ready    (a_sd_ready),
    .led_init    (a_led_init),     // 调试用

    // ---- SDRAM 写口 → 接 sdr_arb ----
    .a_wr_req    (wr_req),
    .a_wr_base   (wr_base),
    .a_wr_len    (wr_len),
    .a_wr_ack    (wr_ack),
    .a_wr_data   (wr_data),
    .a_wr_we     (wr_we),
    .a_wr_full   (wr_full),
    .a_wr_done   (wr_done),
    .sdr_ready   (sdr_ready),

    // ---- 描述符口 → 接 desc_rx ----
    .a_desc      (a_desc),
    .a_commit_tgl(a_commit_tgl),
    .a_ack_tgl   (a_ack_tgl),

    // ---- 诊断：上板接 ILA，综合时可以接到不用的信号上 ----
    .dbg_px_cnt    (),  .dbg_first_px  (),  .dbg_wr_cnt  (),  .dbg_first_addr(),
    .dbg_wav_cnt   (),  .dbg_overrun   (),  .dbg_warn_odd(),
    .dbg_scaled    (),  .dbg_wav_odd   ()
);
```

---

## 二、端口表

### 2.1 时钟 / 复位 / SD 卡

| 端口 | 方向 | 位宽 | 说明 |
| --- | --- | --- | --- |
| `sys_clk` | in | 1 | 50 MHz 控制域 |
| `sys_rst_n` | in | 1 | 低有效，**异步复位** |
| `spi_miso` | in | 1 | 直接接 SD 座 |
| `spi_mosi` / `spi_clk` / `spi_cs` | out | 1 | 直接接 SD 座；内部已按 `sd_to_wav_r` 二选一 |

### 2.2 命令

| 端口 | 方向 | 位宽 | 说明 |
| --- | --- | --- | --- |
| `start` | in | 1 | **单拍脉冲**，发起一条命令 |
| `sd_to_wav` | in | 1 | 0 = 装图，1 = 装音频。**必须在 `start` 那一拍就摆好** |
| `skip` | in | 4 | 装第几个（图 / 音频共用，看 `sd_to_wav`） |
| `use_slot` | in | 3 | 装到第几个槽（0 ~ `SLOT_NUM`-1） |
| `slot_base` | in | 21 | 槽帧缓冲基址，**字地址** |
| `img_no` | in | 8 | 图号，会写进描述符 |
| `sfx_base` | in | 21 | 音效区基址 + 条号 × `SDR_SFX_STRIDE` |

### 2.3 状态回报

| 端口 | 方向 | 位宽 | 说明 |
| --- | --- | --- | --- |
| `busy` | out | 1 | **整条命令**期间为 1（见 §3.2） |
| `load_done` | out | 1 | **单拍**：整帧图写完并进 SDRAM |
| `desc_done` | out | 1 | **单拍**：描述符已被 `desc_rx` ack |
| `ready_n` | out | 8 | 和 `desc_done` 同拍：第几张图就绪 |
| `wav_done` | out | 1 | **单拍**：这条音频写完并进 SDRAM |
| `fail` | out | 1 | 电平：出错（找不到 / 格式不对 / 丢数据） |
| `sd_ready` | out | 1 | 电平：SD 卡初始化完成，**发命令前必须先等它变 1** |
| `led_init` | out | 1 | 电平：引脚已交接（调试用） |

> ⚠️ `load_done` / `desc_done` / `wav_done` **都是单拍脉冲**。
> 如果隔几十拍再去判断，必然读到 0 —— 要先拿寄存器锁存。（这个坑仿真时踩过一次）

### 2.4 SDRAM 写口（→ `sdr_arb`）

| 端口 | 方向 | 位宽 | 说明 |
| --- | --- | --- | --- |
| `a_wr_req` | out | 1 | 举着，直到 `a_wr_ack` 来了才放 |
| `a_wr_base` | out | 21 | 这一段从哪个字地址开始 |
| `a_wr_len` | out | 21 | 这一段多少个字 |
| `a_wr_ack` | in | 1 | **一拍**：受理了 |
| `a_wr_data` | out | 32 | 一个 32 位字 = 两个像素 / 两个采样 |
| `a_wr_we` | out | 1 | 写使能 |
| `a_wr_full` | in | 1 | 背压：为 1 就先别推 |
| `a_wr_done` | in | 1 | **一拍**：这一段写进 SDRAM 了 |
| `sdr_ready` | in | 1 | SDRAM 初始化完成 |

> ★ 这套协议 = 原厂 `frame_fifo_write` 那套。
> **没有 `sdr_dm`（半字写）** —— 所以奇数个采样时最后一个采样会被丢掉（见 §5.2）。
>
> `a_wr_ack` / `a_wr_full` / `a_wr_done` 是**广播**给内部两条链的 ——
> 没被启动的那条在 IDLE 待着，不会误动。

### 2.5 描述符口（→ `desc_rx`）

| 端口 | 方向 | 位宽 | 说明 |
| --- | --- | --- | --- |
| `a_desc` | out | `SLOT_NUM*64` | 描述符表 |
| `a_commit_tgl` | out | 1 | toggle 握手：翻转 = 提交 |
| `a_ack_tgl` | in | 1 | toggle 握手：对端翻转 = 收到了 |

### 2.6 诊断

| 端口 | 位宽 | 正常值 |
| --- | --- | --- |
| `dbg_px_cnt` | 32 | == 源图 `W × H` |
| `dbg_first_px` | 16 | 第一个像素的 RGB565 |
| `dbg_wr_cnt` | 32 | == `st_w × st_h / 2` |
| `dbg_first_addr` | 32 | == `(H-1) × W` |
| `dbg_wav_cnt` | 32 | == `采样数 / 2`（向下取整） |
| `dbg_overrun` | 1 | **应该恒为 0**（两级暂存没兜住才会亮） |
| `dbg_warn_odd` | 1 | 图像：奇数像素。**应该恒为 0** |
| `dbg_scaled` | 1 | 1 = 这一帧真的缩过 |
| `dbg_wav_odd` | 1 | 音频采样数是奇数（最后一个落单被丢）。**正常现象** |

---

## 三、怎么调用

### 3.1 单条命令的生命周期

```verilog
// ① 等 SD 卡就绪（只在复位后等一次）
wait (sd_ready);

// ② 摆好命令
sd_to_wav = 1'b0;              // 装图
skip      = 4'd0;              // 第 0 张
use_slot  = 3'd0;
slot_base = SLOT0_BASE;
img_no    = 8'd1;

// ③ 给一个单拍脉冲
start = 1'b1;  @(posedge clk);  start = 1'b0;

// ④ 等整条命令干完
@(negedge busy);

// ⑤ 确认成功（可选，但建议）
if (fail)  ...  // 出错处理
```

装音频就是把 ② 换成：

```verilog
sd_to_wav = 1'b1;              // 装音频
skip      = 4'd2;              // 第 2 条
sfx_base  = SDR_AUDIO_BASE + 2*SDR_SFX_STRIDE;
```

### 3.2 为什么等 `busy` 就够了

```verilog
assign busy = bmp_busy | sc_busy | bmp2sdram_busy | desc_busy
            | wav_busy | wav2sdram_busy;
```

从"开始找文件"一直到"整帧写进 SDRAM + 描述符被 ack 完"，`busy` 一直是 1。
所以**等 `busy` 落下去 = 这一条彻底完事了**，可以安全地发下一条。

### 3.3 典型的整体流程

```
上电
 ├─ wait(sd_ready)
 ├─ 把要用的音效逐条灌进音效区      （8 条 → 8 次 start，sd_to_wav=1）
 ├─ 把第一屏要的图装进槽 0 / 槽 1    （每张 1 次 start，sd_to_wav=0）
 └─ 通知 B 轨可以开始渲染

之后按需换图：
    B 轨说"槽 1 可以覆盖了" → C 轨发一条 start 重装槽 1
    （★ "哪个槽现在能覆盖"只有 B 知道，B 要状态回推给 A/C）
```

---

## 四、三条铁律（踩了会很隐蔽，都不会报错）

### ① `sd_to_wav` 必须在 `start` 那一拍就摆好，整条命令期间不许变

`top_a` 内部在 `start` 那一拍把它**锁存**成 `sd_to_wav_r`，然后：
- SD 卡引脚（`spi_clk/mosi/cs`）按它二选一
- SDRAM 写口（`a_wr_req/base/len/data/we`）按它二选一

**中途改变 = 引脚和写口同时易主**，两条链都会读到垃圾数据，**而且两条都不会报错**。

> ★ 历史坑（2026-10-01 修的）：`bmp_start` / `wav_start` 一开始写成跟**寄存过的**
> `sd_to_wav_r` 相与，而 `sd_to_wav_r` 要到 `start` 的**下一拍**才变 1
> → `wav_start` 永远没脉冲 → **音频链根本不会启动**。
> 现在改成了跟组合的 `sd_to_wav` 相与。

### ② `busy = 1` 期间不许再给 `start`

### ③ 全项目只能例化一个 SDRAM 控制器

`top_a` 里**没有** `sdr_arb`。如果例化两个，两个都会去驱动同一根 SDRAM 总线。

---

## 五、素材要求

### 5.1 图片（BMP）

| 项 | 要求 |
| --- | --- |
| 格式 | **24 位**未压缩 BMP（`bmp_bpp` 必须 == 24） |
| 宽 / 高 | 1 ~ 4096 |
| 朝向 | 正高度（bottom-up，即最常见的普通 BMP） |
| 尺寸 | 装得进槽就**原样直通**；装不进就**自动缩到 1536×1152** 并按 4:3 居中裁剪 |

> ⚠️ **已知问题**：`bmp_analyze` 判行尾用的是"本行吐够 W 个像素"，
> 当 **`W % 4 != 0`** 时，行尾 padding 字节会被当成像素。
> 现在板子上用的 640×480（行字节 1920，是 4 的倍数）不受影响。
> 换图时**尽量挑 `W % 4 == 0` 的**。

### 5.2 音频（WAV）

| 项 | 要求 |
| --- | --- |
| 格式 | **PCM**（`a_fmt == 1`） |
| 采样率 | **必须 48 kHz**（`RATE_REQ` 写死，对不上直接 `fail`） |
| 声道 | **必须单声道**（`CH_REQ = 1`） |
| 位深 | **必须 16 bit**（`BITS_REQ = 16`） |
| chunk 顺序 | `fmt` 必须在 `data` **之前** |

> ★★ **文件必须连续存放！** `wav_analyze` 是按**连续扇区**读的，**不走 FAT 簇链**。
> 所以：**格卡 → 一次性把所有素材拷进去 → 之后别删别补**。
> 碎片的文件会读到垃圾，而且不报错（只会响出噪声）。

---

## 六、故障排查

| 现象 | 可能原因 |
| --- | --- |
| `fail` 亮 | 文件没找到 / WAV 采样率或声道不对 / BMP 不是 24 位 / 文件被读完了像素还没凑齐 |
| `busy` 一直不落 | 文件太大读不完；或 `sdr_arb` 没给 `a_wr_done` |
| `load_done` 永远不亮 | `sdr_arb` 没给 `a_wr_ack` / `a_wr_done`；或 SDRAM 没 ready |
| `dbg_overrun` 亮 | 写口被 `a_wr_full` 堵太久，两级暂存没兜住 → 丢数据 |
| `dbg_warn_odd`（图像）亮 | 源图 `W × H` 是奇数 → **不该发生**，检查图 |
| `dbg_wav_odd` 亮 | 采样数是奇数，最后一个被丢。**正常**，不用管 |
| `sd_ready` 一直是 0 | SD 卡没插好 / 不是 FAT32 / 上电时序问题 |
| 图是"一条一条、每 4 行跳一次的横带" | `bmp_analyze` 行边界问题（已修，2026-10-01） |

---

## 七、已验证 / 没验证（★ 交接前看清楚）

仿真环境：`wav_chk\`（假 SD 卡 `find_bmp_sd.v` + 假写引擎 `wr_engine_mock.v` + `tb_top_a.v`）
重跑：`sh wav_chk/run_top_a.sh`

### ✅ 已验证（ModelSim 2026-10-01，用 `rtl/top_a.v` 原件）

| 项 | 结果 |
| --- | --- |
| 图像链 8×4 BMP → 16 个字 | 逐个比对全对 |
| `dbg_px_cnt` / `dbg_wr_cnt` | 32 / 16 ✅ |
| `dbg_first_px` / `dbg_first_addr` | `0x2210` / 24 ✅ |
| 描述符 w/h/base/valid | 8 / 4 / 1000 / 1 ✅ |
| 音频链 9 采样（奇数） → 4 个字 | 逐个比对全对 |
| `dbg_wav_odd` | 1 ✅（正确） |
| 两处 mux | 装图时只推图的数据，装音频时只推音频的数据 ✅ |

### ❌ 还没验证

| 项 | 说明 |
| --- | --- |
| **缩放路径** | 测试图小，`dbg_scaled=0`，`bmp_scale` 真的缩一次**没覆盖** |
| 真 SD 卡 / 真 SPI 时序 | 仿真用的是假 SD 卡 |
| `a_wr_full` 背压（集成后） | `wav2sdram` 单独验过，集成后没验 |
| framebuffer 朝向 | 见 §8.2 |

---

## 八、两个悬而未决的事

### 8.1 ★ 音效区容量不够（**必须先和契约持有者定**）

契约里写的：

```verilog
`define SDR_AUDIO_WORDS  21'd44100
`define SDR_SFX_NUM      8
`define SDR_SFX_STRIDE   21'd5513     // 注释按 22.05 kHz 算：0.5s ≈ 11025 采样 ≈ 5513 字
```

但 `wav_analyze` **只认 48 kHz**。换算：

| | 字 / 条 | 8 条合计 |
| --- | --- | --- |
| 契约给的 | 5,513 | **44,100** |
| 48 kHz × 0.5 s 实际要 | 12,000 | **96,000** ✗ 差 51,900 |
| 实测素材 `mus1.wav`（3.6 s） | **86,543** | **一条就把整个音效区撑爆** ✗ |

**现在的音效区总时长只有 1.84 秒**，8 条平分每条 **0.23 秒**。

几个方向（**需要团队定，不是 A 轨单方面能改的**）：

- **A. 缩素材**：每条裁到 0.23 秒以内。基本不现实。
- **B. 从两个大槽腾地方**（推荐）：大槽给的是 930,830 字，但焦点窗口 1536×1152 装满
  也只要 `1536×1152/2 = 884,736` 字，**每个富余 46,094 字**，两个共 **92,188 字**。
  音效区变成 `44,100 + 92,188 = 136,288` 字 → **5.68 秒总时长，8 条各 0.71 秒** ✓
- **C. 把 `RATE_REQ` 放开到 22050**：但 `CLK_AUD_HZ = 12.288 MHz` 是给 48 kHz 配的
  （12.288 M ÷ 256 = 48 k），播放端要跟着改，串得多。

> ⚠️ **如果走 B，有个耦合点别忘（忘了就是静默写坏）**：
> `bmp_scale` 的 `SLOT_WORDS` **默认写死 930,830**，它靠这个数决定"缩不缩"。
> 改了 `SLOT0_WORDS/SLOT1_WORDS` 之后，`top_a.v` 里 `bmp_scale` 那个例化的
> `SLOT_WORDS` **必须跟着改成 884736**。
> 否则：槽只有 884,736 字，但 `bmp_scale` 还按 930,830 判断"装得下"→ 不缩
> → **写到隔壁槽去了**，而且不报错。

### 8.2 framebuffer 的朝向要确认一次

`bmp2sdram` 现在**不拿 `px_addr` 当地址用**，只取 `px_addr[0]` 判奇偶；
整帧是**按到达顺序**从 `frame_base` 一个字一个字推的。
而 `bmp_analyze` 的到达顺序是"BMP 文件第 0 行先出" = **图最下面一行先出**
（`dbg_first_addr = (H-1)*W = 24`，不是 0）。

结果：framebuffer 里是"**底行在低地址**"。
如果 B 轨按自上而下光栅读，图会**上下翻转**；用对称的格子图/棋盘图**看不出来**。

**建议**：拿一张上下明显不对称的图（比如带文字）上板看一眼，确认方向。

---

## 九、一句话总结

> **`top_a` 只回答"这一条命令怎么装"；"什么时候装、装到哪、装几条"都是集成层的活。**
>
> 集成层只要记住这个循环就行：
> **摆好参数 → 给一个 `start` 脉冲 → 等 `busy` 落 → 再摆下一条**
