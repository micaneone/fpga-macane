# ============================================================
#  read_report.ps1 (M2 build) -- read COM11 and decode the top_m2 frame
#
#  Frame = 33 x 16-bit fields, 4 hex chars each, one frame per 0.2 s,
#  115200 8N1.  Field map must match rtl\top_m2.v + rtl\dbg_report.v.
#
#    0,1    W  = sdr_wr_cnt : words actually written into SDRAM (accumulates)
#    2      S  = status byte (see below)
#    3      F  = frame id low 8 bits (keeps moving => display chain alive)
#    4,5    A's output pixel count (a_dbg_px_cnt[23:0]); for a 640x480 load
#           it should end at 307200 = 0x04B000, for 1920x1200 at 0x300000
#    6..9   ★ 2026-10-03 转场探针（原来这里是 M1 时代的整行扫描 px0..px3）：
#           6 = {KEY3 消抖脉冲次数, 转场请求次数}
#           7 = {a_start 次数, a_wr_ack 次数}       A 有没有被放行去写
#           8 = {描述符版本变化次数, a_wr_done 次数} 装载有没有真的完成
#           9 = {swap 次数, 状态位}：bit5=may_load bit4=active bit3=front_sel
#                 bit2:1=fx_sel bit0=req_pend
#           ★ 判读：按一下 KEY3 之后再看这四组数各有没有往上走 ——
#             6 不动 = 键没被看到；6 动而 7 不动 = A 没被放行；
#             7 动而 8 不动 = 装载没完成；8 动而 9 不动 = 转场没走完。
#    10     flags (see below)
#    11     A's own pushed-word count, low 16 bits
#    12     ★★ 2026-10-05: bit0 = reppar (which row-probe group 6..9 shows),
#           bit1 = 音频仲裁 tag 队列【脱钩过】(sticky). 1 = "杂音/白线是仲裁的锅"。
#    13     lb_wbase   requested row-start word address (low 16)
#    14     lb_rd0     first word actually received (low 16)
#    15     lb_rd1     second word actually received (low 16)
#    16     lb_words   words read in that transfer
#    17   * current ZOOM LEVEL 0..5  (0=fit 1=1x 2=1.5x 3=2x 4=3x 5=4x)
#           -- NEW in M2; field 17 used to be the cmp_off knob
#    18     KEY1 press count
#    19     lb_off      first kept word minus requested row start
#    20     lb_alignbad words whose value is not their own address
#    21..24 scan group index / pass index / A's a_wr_len (low, high)
#    25..28 ★ 2026-10-04 写侧镜像（原来是 M1 时代的扫描字 px4..px7）：
#           25 = 引擎"写字"拍数低 16 位（= 引擎写进 SDRAM 的字数，累计）
#           26 = 引擎开过多少次写突发       27 = 读写同拍的拍数（累计）
#           28 = ★★ 2026-10-05 改成【音频链状态位图】（原来是保留 0）。
#                位号是【字段自身的】：bit15 aud_fail / bit14 aud_loaded /
#                bit13 音频PLL锁 / bit12 aud_busy / bit11 有音频数据流 /
#                bit10 play_tgl 在翻 / bit9:8 小状态机（0等图 1等待 2装载音效 3做完）
#                期望顺序：20xx（PLL 锁）-> 60xx（音效装完）-> 68xx（有数据流）
#                -> 播放中 bit10 在 4/C 之间跳；播完 loaded 一直留着（一直 6xxx）
#           ★ A 的段长度在【字段 23/24】里（a_wr_len 的低 16 + 高 5），别在这里找。
#           ★ 用法：25 的低 16 位应当等于 字段 11（A 自己推的字数）；
#             27 只要不是 0，就说明读写真的同拍过。
#    29     SDRAM sticky bitmap (see _check_busy.py)
#    30..32 ★★ 2026-10-05: AUDIO DATA SELF-CHECK (was the 10-01 SDRAM-busy experiment):
#           30 = words this playback has pulled out of SDRAM (expect 72000 = 0x11940)
#           31 = low 16 of the 32-bit running SUM of those words
#           32 = high 16 of that sum
#           Compare (30, 31, 32) with the same numbers computed from SFX0.WAV on the PC:
#           identical => the audio data read back from SDRAM is word-for-word correct
#           (=> any remaining hiss is NOT data corruption). Different => gives the error rate.
#
#  S    : bit0 both PLLs locked / bit1 SD ready / bit2 A busy / bit3 loaded once
#         / bit4 fail (latched) / bit5 overrun (latched) / bit6 odd-width warn
#         / bit7 HDMI locked
#  flags: bit0 a_sd_ready / bit1 sdr_ready / bit2 a_busy / bit3 stwr_busy
#         ★ bit15 = **读写同拍过吗**（sticky，一旦撞上就一直是 1，直到复位）——
#           只要它是 1，就一定能解释"写进去的数据坏"；一直 0 就别赖读写。
#         / bit4 disp wants to read (disp_rd_en)
#         / bit5 * read actually allowed (disp_rd_en_g)   <-- gate output
#         / bit6 descriptor valid / bit7 hdmi locked / bit8 a_load_done
#         / bit9  front slot (0 = slot0, 1 = slot1)          <-- 2026-10-03 transition
#         / bit10 * may_load: screen is all white, A may write SDRAM
#         / bit11 transition active (fade out / hold / fade in)
#         / bit12 st_busy (read self-test) / bit13 A got a start pulse
#
#  Why bit4/bit5 of flags matter: they are the two sides of the read gate.
#  While A is loading they must differ (wants=1, allowed=0).  If they are
#  ever both 1 while S bit2 (A busy) is 1, the read/write overlap bug is back.
#
#  Usage:  powershell -ExecutionPolicy Bypass -File .\read_report.ps1 [seconds]
#  *** KEEP THIS FILE PURE ASCII ***
# ============================================================
param([int]$Seconds = 8, [string]$Port = 'COM11')

$sp = New-Object System.IO.Ports.SerialPort
$sp.PortName = $Port; $sp.BaudRate = 115200
$sp.Parity = 'None'; $sp.DataBits = 8; $sp.StopBits = 'One'
$sp.ReadTimeout = 1500
try { $sp.Open() } catch { "OPEN FAIL: " + $_.Exception.Message; exit 1 }
Start-Sleep -Milliseconds 300
$sp.DiscardInBuffer()

$lines = @()
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    try {
        $l = $sp.ReadLine()
        if ($l -and $l.Trim().Length -gt 0) { $lines += $l.Trim() }
    } catch { }
}
$sp.Close()

if ($lines.Count -eq 0) { "no data on $Port"; exit 1 }

function BitN($f, $n) { ($f -shr $n) -band 1 }

$shown = 0
$firstW = $null; $lastW = $null
$firstA = $null; $lastA = $null
$sawBusy = 0; $sawOverlap = 0

foreach ($l in $lines) {
    if ($l.Length -lt 132) { continue }        # 33 fields = 132 chars
    $v = New-Object 'int[]' 33
    $badhex = $false
    for ($i = 0; $i -lt 33; $i++) {
        try { $v[$i] = [Convert]::ToInt32($l.Substring($i * 4, 4), 16) }
        catch { $badhex = $true; break }
    }
    if ($badhex) { continue }

    $shown  = $shown + 1
    $W      = ($v[1] -shl 16) -bor $v[0]
    $Apx    = ($v[5] -shl 16) -bor $v[4]
    $st     = $v[2]
    $fl     = $v[10]

    if ($firstW -eq $null) { $firstW = $W; $firstA = $Apx }
    $lastW = $W; $lastA = $Apx

    $pll = BitN $st 0; $sd = BitN $st 1; $ab = BitN $st 2; $ld = BitN $st 3
    $fa  = BitN $st 4; $ov = BitN $st 5; $hd = BitN $st 7
    $want = BitN $fl 4; $allow = BitN $fl 5
    if ($ab -eq 1) { $sawBusy = 1; if ($allow -eq 1) { $sawOverlap = 1 } }

    "f{0,4} F={1,3} S={2:X2}(pll{3} sd{4} busy{5} done{6} FAIL{7} OVR{8} hdmi{9}) W={10:X6} Apx={11:X6} zoom={12} key1={13} | gate want={14} allow={15} | lb asked={16:X4} got1={17:X4} got2={18:X4} words={19:X3} off={20,3} bad={21,3}" -f `
        $shown, $v[3], $st, $pll, $sd, $ab, $ld, $fa, $ov, $hd, $W, $Apx, $v[17], $v[18],
        $want, $allow, $v[13], $v[14], $v[15], $v[16], $v[19], $v[20]
}

"";"============================================================"
"frames decoded : $shown (of " + $lines.Count + " lines)"
if ($shown -eq 0) { "frame too short - is the board sending 33 fields?"; exit 1 }
"W   (engine words)  first={0:X6}  last={1:X6}  delta={2} (0x{2:X})" -f $firstW, $lastW, (($lastW - $firstW) -band 0xFFFFFF)
"Apx (A's pixels)    first={0:X6}  last={1:X6}  delta={2}" -f $firstA, $lastA, ($lastA - $firstA)
""
"--- what to check -------------------------------------------------"
"* F keeps moving            => display chain alive"
"* S bit0/bit1/bit7 all 1    => PLLs + SD + HDMI ok"
"* while S bit2 (busy) is 1, gate must show want=1 allow=0"
"  (want=1 AND allow=1 while busy => read/write overlap bug is back)"
"* after loading one image, W delta should equal W*H/2 of the STORED size:"
"    640x480 -> 153600 (0x25800)   800x600 -> 240000 (0x3A980)"
"    1536x1152 -> 884736 (0xD8000)"
"  a SHORT delta  => the write did not cover the whole frame"
"  S bit5 OVR set  => A dropped pixel pairs (overrun)"
"* lb_off / lb_alignbad are only meaningful with the ADDRESS PATTERN"
"  loaded (each word's value = its own address); lb_alignbad should be 0."
"  They are meaningless with a real photo."
""
if ($sawBusy -eq 1) {
    if ($sawOverlap -eq 1) { "!! saw want=1 AND allow=1 while A was busy -> OVERLAP" }
    else                   { "ok: the read gate stayed closed while A was busy" }
} else { "(A was never busy during this capture - load an image and re-run)" }
