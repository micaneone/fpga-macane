# ============================================================
#  build.ps1 -- one-shot M2 build with Anlogic TD (syn -> phy -> bit)
#
#  WHY THIS SCRIPT EXISTS
#    The classic board-day trap: TD's create_run silently "succeeds" when the
#    run directory already exists; launch_runs then replays the OLD run and
#    wait_run returns in ~6 s.  The build looks green but ships the previous
#    netlist.  We lost an hour on exactly this on 2026-10-24.
#    So: delete prj\M2_Runs, run the full flow, then PROVE a fresh bitstream
#    exists (timestamp newer than build start AND size sane) before saying OK.
#
#  USAGE  (run from anywhere; project path is derived from this file's dir)
#    powershell -ExecutionPolicy Bypass -File .\tools\build.ps1
#    ...  -Tag D5_volfix    archive name tag           (default: M2)
#    ...  -KeepRuns         do NOT delete M2_Runs      (debugging only!)
#    ...  -NoArchive        do not copy the bit into ..\burn
#    ...  -TdExe <path>     override the TD command shell
#
#  OUTPUT
#    logs\build_<stamp>.log         full TD console log
#    logs\build_<stamp>\            TD's own td_*.log (working dir for the run)
#    prj\M2_Runs\phy_1\M2.bit       the fresh bitstream
#    ..\burn\<Tag>_<stamp>.bit      archived copy (unless -NoArchive)
#
#  NEXT   tools\burn.ps1   (flashes phy_1\M2.bit and verifies PRG-2014)
#
#  *** KEEP THIS FILE PURE ASCII ***
#      PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so Chinese comments turn
#      into mojibake.  Same rule as check_compile.ps1.
# ============================================================

param(
    [string]$Project = '',
    [string]$TdExe   = 'D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe',
    [string]$Tag     = 'M2',
    [switch]$KeepRuns,
    [switch]$NoArchive
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Project)) { $Project = Split-Path -Parent $PSScriptRoot }
$Project = (Resolve-Path -LiteralPath $Project).Path
$prj     = Join-Path $Project 'prj'
$alPath  = Join-Path $prj 'M2.al'
$bit     = Join-Path $prj 'M2_Runs\phy_1\M2.bit'
$runsDir = Join-Path $prj 'M2_Runs'

foreach ($need in @($alPath, $TdExe)) {
    if (-not (Test-Path -LiteralPath $need)) { throw ('not found: ' + $need) }
}
Write-Host ('>>> project : ' + $Project) -ForegroundColor DarkGray
Write-Host ('>>> TD shell: ' + $TdExe)   -ForegroundColor DarkGray

$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$logs    = Join-Path $Project 'logs'
$runDir  = Join-Path $logs ('build_' + $stamp)
$logPath = Join-Path $logs ('build_' + $stamp + '.log')
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

# ---- 1. force a clean run --------------------------------------------------
if (Test-Path -LiteralPath $runsDir) {
    if ($KeepRuns) {
        Write-Host '>>> WARNING: -KeepRuns -> reusing prj\M2_Runs; the bit may be STALE' -ForegroundColor Yellow
    } else {
        Write-Host '>>> removing prj\M2_Runs (clean build)' -ForegroundColor DarkGray
        Remove-Item -LiteralPath $runsDir -Recurse -Force
        if (Test-Path -LiteralPath $runsDir) { throw ('could not remove ' + $runsDir) }
    }
}

# ---- 2. write the TD tcl (forward slashes! backslashes break TD tcl) ------
$prjF = $prj -replace '\\', '/'
$alF  = $alPath -replace '\\', '/'
$tclTemplate = @'
cd {__PRJ__}
import_device eagle_s20.db -package EG4S20BG256
open_project {__AL__}

proc tryrun {label body} {
  if {[catch {uplevel 1 $body} r]} {
    puts "!! $label FAILED: $r"
    return 1
  } else {
    puts ">> $label OK: $r"
    return 0
  }
}

tryrun "create_run syn_1" {create_run -run_name syn_1}
tryrun "launch_runs syn_1" {launch_runs -run_name syn_1}
tryrun "wait_run syn_1" {wait_run -run_name syn_1}
tryrun "create_run phy_1" {create_run -run_name phy_1}
tryrun "launch_runs phy_1" {launch_runs -run_name phy_1}
tryrun "wait_run phy_1" {wait_run -run_name phy_1}
puts "=== DONE ==="
exit
'@
$tclText = $tclTemplate.Replace('__PRJ__', $prjF).Replace('__AL__', $alF)
$tclPath = Join-Path $runDir 'build.tcl'
[IO.File]::WriteAllText($tclPath, ($tclText + "`n"), (New-Object System.Text.UTF8Encoding($false)))

# ---- 3. run ---------------------------------------------------------------
$start = Get-Date
Write-Host '>>> running TD (expect ~2 min)...' -ForegroundColor Cyan
Push-Location $runDir
try {
    $out = & $TdExe $tclPath *>&1
    $rc  = $LASTEXITCODE
} finally {
    Pop-Location
}
$text = ($out | Out-String)
[IO.File]::WriteAllText($logPath, $text, (New-Object System.Text.UTF8Encoding($false)))
$out | Out-Host
$elapsed = (Get-Date) - $start

# ---- 4. PROVE the bitstream is fresh -------------------------------------
if ($rc -ne 0) { throw ('TD returned rc=' + $rc + '; see ' + $logPath) }
if ($text -notmatch '=== DONE ===') { throw ('flow did not reach === DONE ===; see ' + $logPath) }
if (-not (Test-Path -LiteralPath $bit)) { throw ('no bitstream produced: ' + $bit) }
$fi = Get-Item -LiteralPath $bit
if ($fi.LastWriteTime -lt $start) {
    throw ('bitstream was NOT regenerated (mtime ' + $fi.LastWriteTime + ' is older than build start); see ' + $logPath)
}
if ($fi.Length -lt 600000) { throw ('bitstream suspiciously small: ' + $fi.Length + ' bytes') }
if ($text -match '!! .*FAILED') {
    Write-Host '>>> WARNING: a tryrun step reported FAILED; read the log' -ForegroundColor Yellow
}

# ---- 5. archive -----------------------------------------------------------
$archived = ''
if (-not $NoArchive) {
    $burn = Join-Path (Split-Path -Parent $Project) 'burn'
    New-Item -ItemType Directory -Force -Path $burn | Out-Null
    $archived = Join-Path $burn ($Tag + '_' + $stamp + '.bit')
    Copy-Item -LiteralPath $bit -Destination $archived -Force
}

Write-Host ''
Write-Host ('===== BUILD OK ===== ' + [int]$elapsed.TotalSeconds + ' s') -ForegroundColor Green
Write-Host ('  bitstream : ' + $bit + '  ' + $fi.Length + ' bytes  ' + $fi.LastWriteTime)
if ($archived -ne '') { Write-Host ('  archived  : ' + $archived) }
Write-Host ('  log       : ' + $logPath)
Write-Host ('  next      : powershell -ExecutionPolicy Bypass -File ' + (Join-Path $PSScriptRoot 'burn.ps1'))
exit 0
