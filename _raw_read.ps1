# ============================================================
#  _raw_read.ps1 -- dump whatever is on COM11 VERBATIM (no field
#  interpretation), so it can be decoded no matter which build
#  happens to be running on the board.
#
#  usage: powershell -ExecutionPolicy Bypass -File .\_raw_read.ps1 [seconds]
#
#  ★ 2026-10-01: the frame grew from 29 to 33 fields (dbg_report NV=33),
#    so the old "length must be 116, loop 29 times" test is gone. Now any
#    line whose length is a nonzero multiple of 4 is split into 4-char
#    fields, as many as the line has. Old 29-field frames and the new
#    33-field frames both print correctly.
#  *** KEEP THIS FILE PURE ASCII ***
# ============================================================
param([int]$Seconds = 4, [string]$Port = 'COM3')

$sp = New-Object System.IO.Ports.SerialPort
$sp.PortName = $Port; $sp.BaudRate = 115200
$sp.Parity = 'None'; $sp.DataBits = 8; $sp.StopBits = 'One'
$sp.ReadTimeout = 1500
try { $sp.Open() } catch { "OPEN FAIL: " + $_.Exception.Message; exit 1 }
Start-Sleep -Milliseconds 200
$sp.DiscardInBuffer()

$t0 = Get-Date
$end = $t0.AddSeconds($Seconds)
$n = 0
$prev = $null
while ((Get-Date) -lt $end) {
    try { $l = $sp.ReadLine() } catch { continue }
    if (-not $l) { continue }
    $l = $l.Trim()
    if ($l.Length -eq 0) { continue }
    $n = $n + 1
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    if (($l.Length % 4) -eq 0 -and $l.Length -ge 4) {
        $s = $l
        $raw = ''
        $nf = $l.Length / 4
        for ($i = 0; $i -lt $nf; $i++) { $raw += $s.Substring($i * 4, 4) + ' ' }
        "T+{0,6} ms  {1}" -f $ms, $raw
    } else {
        "T+{0,6} ms  len={1}  '{2}'" -f $ms, $l.Length, $l
    }
}
$sp.Close()
""
"lines: $n"
