# Print the VALUE column area (both cells) of the full-panel dump in menu_render.txt
# at dot resolution, so the two-digit VOLUME row can be eyeballed.
# Usage: powershell -File dump_val.ps1 [-file <txt>] [-rows 4] [-froms 92] [-tos 116]
# NOTE: keep this file ASCII-only.
param(
    [string]$file = "E:\FPGA\ygcom\pre-release-testing\sim\menu_render.txt",
    [int]$rows = 4,
    [int]$froms = 92,
    [int]$tos = 116
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
Write-Output ("file = {0}   rows = {1}" -f (Split-Path $file -Leaf), $panel.Count)

$TXT_TOP = 18; $ROW_H = 50
foreach ($ri in 0..($rows - 1)) {
    Write-Output ("--- row {0} value dots {1}..{2}  ('#'=ink, '.'=panel) ---" -f $ri, $froms, $tos)
    for ($dr = 0; $dr -lt 7; $dr++) {
        $yy = $ri * $ROW_H + $TXT_TOP + 2 * $dr
        $row = $panel[$yy]
        $out = ""
        for ($dc = $froms; $dc -le $tos; $dc++) {
            $x = 2 * $dc
            if ($x + 1 -ge 320) { break }
            $a = $row[$x]; $b = $row[$x + 1]
            if ($a -eq '#' -or $b -eq '#') { $out += '#' } else { $out += '.' }
        }
        Write-Output ("  d{0} {1}" -f $dr, $out)
    }
    Write-Output ""
}
