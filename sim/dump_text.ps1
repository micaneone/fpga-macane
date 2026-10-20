# Extract the text band from the "full panel dump" section of a menu_render.txt
# and print it at DOT resolution (one char per font dot-pixel).
# Usage: powershell -File dump_text.ps1 [-file <txt>] [-rows 2]
# NOTE: keep this file ASCII-only (PowerShell 5.1 reads BOM-less files as ANSI,
#       and Chinese comment bytes can swallow the following line).
param(
    [string]$file = "E:\FPGA\ygcom\pre-release-testing\sim\menu_render.txt",
    [int]$rows = 4
)
$lines = Get-Content -LiteralPath $file -Encoding UTF8
$panel = @{}
$started = $false
$got = 0
foreach ($ln in $lines) {
    if (-not $started) {
        if ($ln -match '320\(W\)') { $started = $true }
        continue
    }
    if ($ln -match '^\s*(\d+)\|(.+)$') {
        $ly = [int]$Matches[1]; $s = $Matches[2]
        if ($s.Length -eq 320) { $panel[$ly] = $s; $got = $got + 1 }
        if ($got -ge 200) { break }
    }
}
Write-Output ("file = {0}" -f (Split-Path $file -Leaf))
Write-Output ("full-panel dump rows = {0}" -f $panel.Count)

$TXT_TOP = 18; $ROW_H = 50
foreach ($ri in 0..($rows - 1)) {
    Write-Output ("--- menu row {0}  (label zone dots 12..53, value dots 96..100; '.'=panel '='=hilite '#'=ink) ---" -f $ri)
    for ($dr = 0; $dr -lt 7; $dr++) {
        $yy = $ri * $ROW_H + $TXT_TOP + 2 * $dr
        $row = $panel[$yy]
        $out = ""
        for ($dc = 0; $dc -lt 56; $dc++) {
            $x = 2 * $dc
            $a = $row[$x]; $b = $row[$x + 1]
            if ($a -eq '#' -or $b -eq '#') { $out += '#' }
            elseif ($a -eq '*' -or $b -eq '*') { $out += '*' }
            elseif ($a -eq '=' -or $b -eq '=') { $out += '=' }
            else { $out += '.' }
        }
        $out += "  |"
        for ($dc = 96; $dc -le 100; $dc++) {
            $x = 2 * $dc
            $a = $row[$x]; $b = $row[$x + 1]
            if ($a -eq '#' -or $b -eq '#') { $out += '#' } else { $out += '.' }
        }
        $out += "|"
        Write-Output ("  d{0} {1}" -f $dr, $out)
    }
    Write-Output ""
}
