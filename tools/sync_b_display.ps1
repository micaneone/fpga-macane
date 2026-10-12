# ============================================================
#  sync_b_display.ps1 -- refresh a project's b_display copy from the delivery repo.
#
#  Default target = this script's own b_display folder (the offline bench).
#  Use -Target to refresh another project's copy, e.g.
#     ... -Target E:\study\fpga\onboard_test\M2_scale\b_display
#
#  WHY A SCRIPT: the bench's copies of line_buf.v / sdr_arb.v / win_compositor.v
#  carry a local `define B_DEBUG_PROBE header (TD has no global macro support).
#  A plain copy would throw that header away and the probe top would then fail
#  with "module win_compositor has no port o_dbg_wbase". This script keeps it.
#
#  Usage:
#     powershell -ExecutionPolicy Bypass -File `...\_probe_m2\sync_b_display.ps1`
#  Then re-run the TD batch flow (see README notes / _probe_m2 history).
#
#  *** ASCII only (PowerShell 5.1 reads BOM-less .ps1 as ANSI).
#      The repo folder holding the RTL has a non-ASCII name, so we do NOT spell
#      it out here -- we discover it: the repo root is E:\study\fpga\WorkForCompetition
#      and the code dir is whichever child has rtl\b_display under it. ***
# ============================================================
param(
    # ★ 交付仓库（克隆下来的那个）的根目录。默认 = 和本工程同级目录里的 WorkForCompetition。
    #   例：-Repo D:\work\26qianrushidasai        （克隆后的目录名可能不叫 WorkForCompetition）
    [string]$Repo   = '',
    # 目标：要刷新的 b_display 目录。默认 = 本工程（tools 的上一级）的 b_display
    [string]$Target = ''
)

$ErrorActionPreference = 'Stop'

if ($Repo -eq '') {
    # 默认猜：本工程同级目录下的 WorkForCompetition（和 AGENTS.md 里的老布局一致）
    $guess = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'WorkForCompetition'
    if (Test-Path $guess) { $Repo = $guess }
    else { throw "没有给 -Repo，也猜不到交付仓库的位置；请显式指定，例如 -Repo D:\work\26qianrushidasai" }
}
$repoRoot = $Repo
$codeDir  = $null
foreach ($d in (Get-ChildItem $repoRoot -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $d.FullName 'rtl\b_display')) { $codeDir = $d.FullName; break }
}
if (-not $codeDir) { throw ("cannot find the RTL code dir under " + $repoRoot) }
$repoDir  = Join-Path $codeDir 'rtl\b_display'
if ($Target -ne '') { $probeDir = $Target } else { $probeDir = Join-Path $PSScriptRoot 'b_display' }
if (-not (Test-Path $probeDir)) { throw ("target dir not found: " + $probeDir) }

# files that need the local probe macro prepended
$needsProbe = @('line_buf.v', 'sdr_arb.v', 'win_compositor.v')

$utf8 = New-Object System.Text.UTF8Encoding($false)

foreach ($f in (Get-ChildItem $repoDir -Filter *.v)) {
    $dst = Join-Path $probeDir $f.Name
    if (-not (Test-Path $dst)) {
        Write-Host ("  + new    " + $f.Name)
    }

    $header = ''
    if (($needsProbe -contains $f.Name) -and (Test-Path $dst)) {
        # Keep the macro header the bench copy already carries.
        # NOTE: in the bench copies that header does NOT sit at line 0 -- it was
        # inserted just above "module xxx (". So locate the `ifndef, then walk
        # back to the "// ====" rule that opens the block.
        $old  = [System.IO.File]::ReadAllText($dst, $utf8)
        $lines = $old -split "`n"
        $ifd = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '`ifndef B_DEBUG_PROBE') { $ifd = $i; break }
        }
        # anchor on the dated first comment line of the block, then take the
        # "// ====" rule immediately above it as the opener.
        $k = -1
        $j = -1
        if ($ifd -ge 0) {
            $lo = [Math]::Max(0, $ifd - 20)
            for ($i = $lo; $i -lt $ifd; $i++) {
                if ($lines[$i] -match '2026-10-02') { $k = $i; break }
            }
            if ($k -gt 0) {
                for ($i = $k - 1; $i -ge $lo; $i--) {
                    if ($lines[$i].Trim() -match '^//\s*=+\s*$') { $j = $i; break }
                }
            }
        }
        if (($ifd -ge 0) -and ($j -ge 0) -and (($ifd + 2) -lt $lines.Count)) {
            $header = (($lines[$j..($ifd + 2)]) -join "`n") + "`n"
        } else {
            Write-Host ("  ! " + $f.Name + " : no probe header found in the bench copy") -ForegroundColor Yellow
        }
    }

    $body = [System.IO.File]::ReadAllText($f.FullName, $utf8)
    [System.IO.File]::WriteAllText($dst, $header + $body, $utf8)

    $tag = if ($header -ne '') { 'probe' } else { 'plain' }
    Write-Host ("  = " + $f.Name + "  (" + $tag + ")")
}
Write-Host "b_display synced to the offline bench."
