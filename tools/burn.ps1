# ============================================================
#  burn.ps1 -- flash the current M2 bitstream (SRAM download) and verify
#
#  WHY THIS SCRIPT EXISTS
#    "Did it really download?" has two cheap answers on this board:
#      1) TD must print "PRG-2014 Chip validation success" (else the cable /
#         the chip / the bit is wrong, and the old design keeps running);
#      2) the serial frame must change.  This script checks (1) and can run
#         read_report.ps1 for (2).
#    It also archives the flashed bit so every experiment is reproducible.
#
#  USAGE  (run from anywhere)
#    powershell -ExecutionPolicy Bypass -File .\tools\burn.ps1
#    ...  -Tag D5_vollin            archive name tag          (default M2)
#    ...  -Bit ..\burn\xxx.bit      flash a specific file (e.g. an archive)
#    ...  -Port COM6 -ReadSeconds 8 also read + decode the serial frame
#    ...  -DryRun                   print what would happen, flash nothing
#
#  NOTES
#    - default bit = prj\M2_Runs\phy_1\M2.bit (what tools\build.ps1 just made)
#    - this is an SRAM download: power-cycling the board restores whatever is
#      in FLASH.  Use bw_commands_prompt.exe + flash_program_*.tcl for FLASH.
#    - the serial side needs the CH340 USB-UART (usually COM6, 115200 8N1).
#
#  *** KEEP THIS FILE PURE ASCII ***
# ============================================================

param(
    [string]$Project = '',
    [string]$TdExe   = 'D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe',
    [string]$Bit     = '',
    [string]$Tag     = 'M2',
    [string]$Port    = 'COM6',
    [int]$ReadSeconds = 0,
    [switch]$DryRun,
    [switch]$NoArchive
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Project)) { $Project = Split-Path -Parent $PSScriptRoot }
$Project = (Resolve-Path -LiteralPath $Project).Path
$prj     = Join-Path $Project 'prj'

if ([string]::IsNullOrWhiteSpace($Bit)) { $Bit = Join-Path $prj 'M2_Runs\phy_1\M2.bit' }
$Bit = (Resolve-Path -LiteralPath $Bit).Path
if (-not (Test-Path -LiteralPath $Bit)) { throw ('bitstream not found: ' + $Bit) }

$fi = Get-Item -LiteralPath $Bit
if ($fi.Length -lt 600000) { throw ('bitstream suspiciously small: ' + $fi.Length + ' bytes (' + $Bit + ')') }
Write-Host ('>>> bit     : ' + $Bit + '  ' + $fi.Length + ' bytes  ' + $fi.LastWriteTime) -ForegroundColor DarkGray
$age = (Get-Date) - $fi.LastWriteTime
if ($age.TotalMinutes -gt 60) {
    Write-Host ('>>> WARNING: bit is ' + [int]$age.TotalHours + ' h old; did you rebuild after the last RTL edit?') -ForegroundColor Yellow
}

# ---- archive --------------------------------------------------------------
$archived = ''
if (-not $DryRun -and -not $NoArchive) {
    $burn = Join-Path (Split-Path -Parent $Project) 'burn'
    New-Item -ItemType Directory -Force -Path $burn | Out-Null
    $stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $archived = Join-Path $burn ($Tag + '_' + $stamp + '.bit')
}

# ---- tcl ------------------------------------------------------------------
$bitF = $Bit -replace '\\', '/'
$tclTemplate = @'
set f {__BIT__}
set rc [catch {download -bit $f} r]
puts "download rc=$rc"
puts "result: $r"
puts "=== DONE ==="
exit
'@

if ($DryRun) {
    Write-Host ''
    Write-Host '===== DRY RUN (nothing flashed) =====' -ForegroundColor Cyan
    Write-Host ('  tcl     : download -bit ' + $bitF)
    Write-Host ('  TD shell: ' + $TdExe)
    if ($archived -ne '') { Write-Host ('  archive : ' + $archived) }
    if ($ReadSeconds -gt 0) { Write-Host ('  read    : read_report.ps1 -Seconds ' + $ReadSeconds + ' -Port ' + $Port) }
    exit 0
}

$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$logs    = Join-Path $Project 'logs'
$runDir  = Join-Path $logs ('burn_' + $stamp)
$logPath = Join-Path $logs ('burn_' + $stamp + '.log')
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$tclText = $tclTemplate.Replace('__BIT__', $bitF)
$tclPath = Join-Path $runDir 'download.tcl'
[IO.File]::WriteAllText($tclPath, ($tclText + "`n"), (New-Object System.Text.UTF8Encoding($false)))

# ---- flash ----------------------------------------------------------------
$start = Get-Date
Write-Host '>>> flashing (SRAM download, expect ~7 s)...' -ForegroundColor Cyan
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

if ($rc -ne 0) { throw ('TD returned rc=' + $rc + '; see ' + $logPath) }
if ($text -notmatch 'download rc=0') { throw ('''download rc=0'' not found -- flashing FAILED; see ' + $logPath) }
if ($text -notmatch 'Chip validation success') {
    throw ('no "Chip validation success" in the log -- the bit did not validate; see ' + $logPath)
}

# ---- archive --------------------------------------------------------------
if ($archived -ne '') {
    Copy-Item -LiteralPath $Bit -Destination $archived -Force
}

Write-Host ''
Write-Host ('===== BURN OK ===== ' + [int]((Get-Date) - $start).TotalSeconds + ' s') -ForegroundColor Green
Write-Host ('  bitstream : ' + $Bit)
if ($archived -ne '') { Write-Host ('  archived  : ' + $archived) }
Write-Host ('  log       : ' + $logPath)

# ---- optional: prove the design is alive on the serial side ---------------
if ($ReadSeconds -gt 0) {
    Write-Host ''
    Write-Host ('>>> reading ' + $ReadSeconds + ' s of serial frames on ' + $Port + ' ...') -ForegroundColor Cyan
    $reader = Join-Path $Project 'read_report.ps1'
    if (-not (Test-Path -LiteralPath $reader)) { throw ('read_report.ps1 not found: ' + $reader) }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $reader -Seconds $ReadSeconds -Port $Port
}
exit 0
