# Side-by-side dot-resolution dump of two menu rows (for the report).
# Usage: powershell -File pair_dump.ps1 -file <txt> -ra 0 -rb 1
# ASCII-only on purpose (PS 5.1 reads BOM-less files as ANSI).
param(
    [string]$file = "E:\FPGA\ygcom\pre-release-testing\sim\menu_render.txt",
    [int]$ra = 0,
    [int]$rb = 1
)
$lines = Get-Content -LiteralPath $file -Encoding UTF8
$panel = @{}
$started = $false
$got = 0
foreach ($ln in $lines) {
    if (-not $started) { if ($ln -match '320\(W\)') { $started = $true }; continue }
    if ($ln -match '^\s*(\d+)\|(.+)$') {
        $ly = [int]$Matches[1]; $s = $Matches[2]
        if ($s.Length -eq 320) { $panel[$ly] = $s; $got = $got + 1 }
        if ($got -ge 200) { break }
    }
}
$TXT_TOP = 18; $ROW_H = 50
function Crop([int]$ri, [int]$dr) {
    $yy = $ri * $ROW_H + $TXT_TOP + 2 * $dr
    $row = $panel[$yy]
    $out = ""
    for ($dc = 12; $dc -le 53; $dc++) {          # label zone = 6 cells * 7 dots
        $x = 2 * $dc
        $a = $row[$x]; $b = $row[$x + 1]
        if ($a -eq '#' -or $b -eq '#') { $out += '#' }
        elseif ($a -eq '=' -or $b -eq '=') { $out += '=' }
        else { $out += '.' }
    }
    $v = ""
    for ($dc = 96; $dc -le 100; $dc++) {         # value cell = 5 dots
        $x = 2 * $dc
        $a = $row[$x]; $b = $row[$x + 1]
        if ($a -eq '#' -or $b -eq '#') { $v += '#' } else { $v += '.' }
    }
    return $out + " [" + $v + "]"
}
Write-Output ("row{0,-2}                              row{1}" -f $ra, $rb)
for ($dr = 0; $dr -lt 7; $dr++) {
    Write-Output ("d{0}  {1}   d{0}  {2}" -f $dr, (Crop $ra $dr), (Crop $rb $dr))
}
