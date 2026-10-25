# ============================================================
#  decode_frame.ps1 -- human-readable decode of ONE serial frame
#
#  The board prints 33 x 4-hex fields (132 chars) + CRLF, see
#  rtl/dbg_report.v.  read_report.ps1 reads the port live; this script
#  decodes a frame you already have (copied from a log / CSV / terminal),
#  which is handy when the board is on someone else's desk.
#
#  USAGE
#    .\tools\decode_frame.ps1 -Frame "00C8 0000 008F 0001 0000 ..."      # 132 chars
#    .\tools\decode_frame.ps1 -Frame "00C80000008F..."                   # or no spaces
#
#  *** KEEP THIS FILE PURE ASCII ***  (PowerShell 5.1 reads BOM-less
#      .ps1 as ANSI; non-ASCII comments become mojibake)
# ============================================================

param(
    [Parameter(Mandatory = $true)][string]$Frame
)

$ErrorActionPreference = 'Stop'

$hex = ($Frame -replace '[^0-9A-Fa-f]', '').ToUpper()
if ($hex.Length -ne 132) {
    throw ('frame must be 33 fields x 4 hex = 132 hex chars, got ' + $hex.Length)
}
$f = New-Object int[] 33
for ($i = 0; $i -lt 33; $i++) {
    $f[$i] = [Convert]::ToInt32($hex.Substring($i * 4, 4), 16)
}

function B($v, $bit) { if ((($v -shr $bit) -band 1) -eq 1) { '1' } else { '0' } }

Write-Host ('frame hex : ' + $hex)
Write-Host ''

# ---------- f2: main status byte ------------------------------------------
$s = $f[2]
Write-Host ('f02 status        : 0x{0:X4}  hdmi_lock={1} warn_odd={2} overrun={3} fail_latch={4} load_done={5} a_busy={6} sd_ready={7} aud_pll_lock={8}' -f $s, (B $s 7), (B $s 6), (B $s 5), (B $s 4), (B $s 3), (B $s 2), (B $s 1), (B $s 0))

# ---------- f21: debug/carousel/menu word ---------------------------------
$c = $f[21]
$bri  = ($c -shr 12) -band 0xF
$viz  = ($c -shr 9)  -band 1
$aca  = ($c -shr 8)  -band 1
$zoom = ($c -shr 5)  -band 7
$mon  = ($c -shr 4)  -band 1
$msel = ($c -shr 1)  -band 7
$med  = $c -band 1
Write-Host ('f21 caro/menu   : 0x{0:X4}  bri={1} viz_on={2} auto_caro={3} zoom={4} menu_on={5} menu_sel={6} menu_edit={7}' -f $c, $bri, $viz, $aca, $zoom, $mon, $msel, $med)

# ---------- f22/23/24: carousel + A-track load size -----------------------
Write-Host ('f22 caro_cnt      : {0}  ({1} frame requests counted)' -f $f[22], $f[22])
$wrlen = (($f[24] -band 0x1F) -shl 16) -bor $f[23]
Write-Host ('f23/24 a_wr_len   : {0} words  (~{1:N0} px@16b)' -f $wrlen, ($wrlen * 2))

# ---------- f25: failsafe state / f26: volume / f27: audio sel ------------
Write-Host ('f25 fs_state      : {0}' -f $f[25])
Write-Host ('f26 vol_lv        : {0} / 10  ({1}%)' -f $f[26], ($f[26] * 10))
Write-Host ('f27 sel_aud       : {0}' -f $f[27])

# ---------- f28: audio FSM + subtitle FSM ---------------------------------
$a = $f[28]
Write-Host ('f28 audio/sub     : 0x{0:X4}' -f $a)
Write-Host ('    aud_fail={0} aud_loaded={1} pll_lock={2} aud_busy={3} dbg_vld={4} play_tgl={5} aud_st={6}' -f (B $a 15), (B $a 14), (B $a 13), (B $a 12), (B $a 11), (B $a 10), (($a -shr 8) -band 3))
Write-Host ('    sub_loaded={0} sub_fail={1} sub_pulse={2} sub_done={3} sub_overrun={4} sub_short={5} sub_st={6}' -f (B $a 7), (B $a 6), (B $a 5), (B $a 4), (B $a 3), (B $a 2), ($a -band 3))

# ---------- f29: fail source ----------------------------------------------
$src = $f[29]
Write-Host ('f29 fail_src      : 0x{0:X4}  [bmp={1} overrun={2} size_bad={3} wav_an={4} sub_an={5} sub_overrun={6} sub_short={7}]' -f $src, (B $src 0), (B $src 1), (B $src 2), (B $src 3), (B $src 4), (B $src 5), (B $src 6))

# ---------- f30: temporary probe = audio digital amplitude (P0 debug) -----
$amp = $f[30]
$pct = [math]::Round(($amp / 32768.0) * 100.0, 1)
Write-Host ('f30 aud_amp       : {0}  (~{1}% FS, 8192-sample mean |L|)' -f $amp, $pct)

# ---------- f31: temporary probe = audio-FSM gate bitmap ------------------
$g = $f[31]
Write-Host ('f31 gate_bits     : 0x{0:X4}' -f $g)
Write-Host ('    img_hold={0} tr_active={1} a_busy={2} req_pend={3} a_start_use={4} aud_busy={5} sub_load_pulse={6} sub_st={7}' -f (B $g 0), (B $g 1), (B $g 2), (B $g 3), (B $g 4), (B $g 5), (B $g 6), (($g -shr 7) -band 3))

# ---------- rest -----------------------------------------------------------
Write-Host ''
Write-Host ('f00/01 val        : 0x{0:X4}' -f ((($f[1] -band 0xFF) -shl 16) -bor $f[0]))
Write-Host ('f03 frm           : {0}' -f $f[3])
Write-Host ('f04/05 bad        : {0} / {1}' -f $f[4], $f[5])
Write-Host ('f06..09 rows      : {0} {1} {2} {3}' -f $f[6], $f[7], $f[8], $f[9])
Write-Host ('f10 drop_cnt      : {0}' -f $f[10])
Write-Host ('f11 abort_cnt     : {0}' -f $f[11])
Write-Host ('f12 tag_bad/reppar: {0}' -f $f[12])
Write-Host ('f13..16 lb        : {0} {1} {2} {3}' -f $f[13], $f[14], $f[15], $f[16])
Write-Host ('f17 cmp_sel       : {0}' -f $f[17])
Write-Host ('f18 key_cnt       : {0}' -f $f[18])
Write-Host ('f19/20 lb_off/alignbad: {0} / {1}' -f $f[19], $f[20])
Write-Host ('f32 rv_col        : 0x{0:X4}' -f $f[32])
