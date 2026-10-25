# ============================================================
#  flash_mboot.ps1 -- write the TWO-image MULTI BOOT layout into SPI FLASH
#
#  WHAT THE BOARD EXPECTS (design side, rtl/top_m2.v)
#    The design contains EG_LOGIC_MBOOT (dynamic address).  Runtime jump:
#      0x000000 : 800x600  image (Primary, boots by default)
#      0x0A0000 : 1024x768 image (Second, entered when SW3 is flipped and the
#                 next carousel advance fires)
#    SW3 only *registers* the request; the jump happens at the next image
#    change (user requirement: "this picture stays, switch on the next one").
#
#  HOW TO GET BOTH IMAGES INTO FLASH  (learned the hard way, 2026-10-25)
#    WRONG: two separate `download -bit X.bit -mode program_spi -start_addr Y`
#    runs.  program_spi erases the whole chip and writes the bitmap at address
#    0 -- the -start_addr is ignored on this TD build, so the second run wipes
#    the first image (verified: re-reading region 0 after writing region 0x0A0000
#    failed with PRG-9508 frame/edge mismatches).
#
#    RIGHT: let TD build ONE merged flash image with its own multi-boot helper,
#    then program that single .bin:
#        create_flash_file -target_file A.bit -added_file "B.bit:0x0A0000"
#                          -output mboot_merged.bin -rom_size 16M
#        download -bin mboot_merged.bin -mode program_spi -spd 6 -cable 0
#        download -bin mboot_merged.bin -mode verify_spi  -spd 6 -cable 0
#    -rom_size is in bits and must fit the chip: our W25Q16 is 16 Mbit, so 16M
#    (a 2M value is rejected: "Rom size is not enough ...").
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\tools\flash_mboot.ps1
#    ... -BitA <800x600 bit> -BitB <1024x768 bit> -AddrB 0x0A0000
#    ... -RomSize 16M -Speed 6 -Cable 0
#    ... -NoVerify
#    ... -DryRun            print commands, program nothing (still builds the bin)
#    ... -SkipBuildBin      reuse an existing -Bin (default build800\mboot_merged.bin)
#
#  NOTES
#    - needs bw_commands_prompt.exe; PROGRAM ~3-4 min, do not cut power
#    - after programming: power-cycle once (boots 0x000000 = 800x600),
#      flip SW3, wait for the next carousel change -> 1024x768 image.
#    - verify with the serial console: f28 bit13 hdmi_locked, f2 S=8B/8F.
#
#  *** KEEP THIS FILE PURE ASCII ***
# ============================================================

param(
    [string]$BwExe   = 'D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\bw_commands_prompt.exe',
    [string]$BitA    = 'E:\FPGA\ygcom\build800\prj\M2_Runs\phy_1\M2.bit',
    [string]$BitB    = 'E:\FPGA\ygcom\pre-release-testing\prj\M2_Runs\phy_1\M2.bit',
    [string]$AddrB   = '0x0A0000',
    [string]$RomSize = '16M',
    [string]$Bin     = 'E:\FPGA\ygcom\build800\mboot_merged.bin',
    [string]$LogDir  = 'E:\FPGA\ygcom\pre-release-testing\logs',
    [int]$Speed      = 6,
    [int]$Cable      = 0,
    [switch]$NoVerify,
    [switch]$DryRun,
    [switch]$SkipBuildBin
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $BwExe)) { throw ('bw_commands_prompt.exe not found: ' + $BwExe) }

function Show-Bit([string]$label, [string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw ($label + ' bitstream not found: ' + $path) }
    $p = (Resolve-Path -LiteralPath $path).Path
    $fi = Get-Item -LiteralPath $p
    if ($fi.Length -lt 600000) { throw ($label + ' bitstream suspiciously small: ' + $fi.Length) }
    Write-Host ('>>> ' + $label + ' : ' + $p + '  ' + $fi.Length + ' bytes  ' + $fi.LastWriteTime) -ForegroundColor DarkGray
    $age = (Get-Date) - $fi.LastWriteTime
    if ($age.TotalMinutes -gt 90) {
        Write-Host ('    WARNING: bit is ' + [int]$age.TotalHours + ' h old; rebuild after RTL edits?') -ForegroundColor Yellow
    }
    return $p
}

$pA = Show-Bit 'A (800x600, primary)' $BitA
$pB = Show-Bit 'B (1024x768, second)' $BitB

# flash region check: B must end inside the chip (16 Mbit = 2 MB)
$addrBDec = [Convert]::ToInt64($AddrB, 16)
$regions = @{ '8M' = 1048576; '16M' = 2097152; '32M' = 4194304 }
if (-not $regions.ContainsKey($RomSize)) { throw ('unsupported -RomSize (use 8M/16M/32M): ' + $RomSize) }
$romBytes = $regions[$RomSize]
$bEnd = $addrBDec + (Get-Item -LiteralPath $pB).Length
if ($bEnd -gt $romBytes) { throw ('image B does not fit: ends at 0x{0:X}, rom is 0x{1:X}' -f $bEnd, $romBytes) }
if ((Get-Item -LiteralPath $pA).Length -ge $addrBDec) { throw 'image A overlaps the B start address' }

$binPath = $Bin
if ([string]::IsNullOrWhiteSpace($binPath)) { $binPath = Join-Path (Split-Path -Parent (Split-Path -Parent $pA)) 'mboot_merged.bin' }
if (-not [IO.Path]::IsPathRooted($binPath)) { $binPath = Join-Path (Get-Location) $binPath }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $binPath) | Out-Null

$tclCreate = 'set rc [catch {create_flash_file -target_file {__BIT_A__} -added_file "__BIT_B__:__ADDR_B__" -output {__BIN__} -rom_size __ROM__} ra]' + "`n" +
             'puts "CREATE rc=$rc"' + "`n" + 'puts "CREATE result: $ra"' + "`n" +
             'if {![file exists {__BIN__}]} { puts "CREATE: output file missing"; exit }' + "`n" +
             'file stat {__BIN__} so' + "`n" + 'puts "BIN size: $so(size)"'
$tclCreate = $tclCreate.Replace('__BIT_A__', ($pA -replace '\\','/')).Replace('__BIT_B__', ($pB -replace '\\','/'))
$tclCreate = $tclCreate.Replace('__ADDR_B__', $AddrB).Replace('__BIN__', ($binPath -replace '\\','/')).Replace('__ROM__', $RomSize)

$tclProg = 'puts "=== PROGRAM MERGED MULTI BOOT IMAGE ==="' + "`n" +
           'set fb {__BIN__}' + "`n" +
           'set rc [catch {download -bin $fb -mode program_spi -spd __SPD__ -cable __CAB__} rp]' + "`n" +
           'puts "PROGRAM rc=$rc"' + "`n" + 'puts "PROGRAM result: $rp"' + "`n" +
           'set rv [catch {download -bin $fb -mode verify_spi -spd __SPD__ -cable __CAB__} rq]' + "`n" +
           'puts "VERIFY rc=$rv"' + "`n" + 'puts "VERIFY result: $rq"' + "`n" + 'puts "=== DONE ==="'
$tclProg = $tclProg.Replace('__BIN__', ($binPath -replace '\\','/')).Replace('__SPD__', [string]$Speed).Replace('__CAB__', [string]$Cable)

function Invoke-Td([string]$tclText, [string]$label) {
    $tmp = Join-Path $env:TEMP ('mboot_' + [IO.Path]::GetRandomFileName() + '.tcl')
    [IO.File]::WriteAllText($tmp, $tclText, (New-Object System.Text.UTF8Encoding($false)))
    $out = & $BwExe (($tmp -replace '\\','/')) *>&1
    Remove-Item $tmp -ErrorAction SilentlyContinue
    return ($out | Out-String)
}

if (-not $SkipBuildBin) {
    Write-Host '>>> building merged flash image (create_flash_file)...' -ForegroundColor Cyan
    $t = Invoke-Td $tclCreate 'create'
    if ($t -notmatch 'CREATE rc=0') { Write-Host $t; throw 'create_flash_file FAILED (see output above)' }
    $m = [regex]::Match($t, 'BIN size: (\d+)')
    if ($m.Success) { Write-Host ('    merged bin: ' + $binPath + '  ' + $m.Groups[1].Value + ' bytes') }
    if (-not (Test-Path -LiteralPath $binPath)) { throw ('merged bin not created: ' + $binPath) }
    # sanity: a proper two-image merge is ~ (0x0A0000 + bit_size) > 1 MB; a single-image
    # fallback (added file silently ignored) is only ~640 KB and would brick slot B.
    $mergedLen = (Get-Item -LiteralPath $binPath).Length
    if ($mergedLen -lt 1000000) { throw ('merged bin only ' + $mergedLen + ' bytes -- the added image was IGNORED (expected ~1296081); refusing to program') }
}

if ($DryRun) {
    Write-Host ''
    Write-Host '===== DRY RUN (FLASH untouched) =====' -ForegroundColor Cyan
    Write-Host ('  merged bin : ' + $binPath + '  ' + (Get-Item -LiteralPath $binPath).Length + ' bytes')
    Write-Host ('  program    : download -bin <bin> -mode program_spi -spd ' + $Speed + ' -cable ' + $Cable)
    if (-not $NoVerify) { Write-Host '  verify     : download -bin <bin> -mode verify_spi' }
    exit 0
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $LogDir ('flashmb_' + $stamp + '.log')
$start = Get-Date
Write-Host '>>> programming 2 images + verify (expect ~4 min; DO NOT cut power)...' -ForegroundColor Cyan
$t = Invoke-Td $tclProg 'prog'
[IO.File]::WriteAllText($logPath, $t, (New-Object System.Text.UTF8Encoding($false)))
$t | Out-Host
if ($t -notmatch 'PROGRAM rc=0') { throw ('"PROGRAM rc=0" not found -- FLASH write FAILED; see ' + $logPath) }
if (-not $NoVerify -and ($t -notmatch 'VERIFY rc=0')) { throw ('"VERIFY rc=0" not found -- FLASH read-back mismatch; see ' + $logPath) }

Write-Host ''
Write-Host ('===== FLASH MULTI BOOT OK ===== ' + [int]((Get-Date) - $start).TotalSeconds + ' s') -ForegroundColor Green
Write-Host ('  merged bin : ' + $binPath)
Write-Host ('  A 800x600  : @ 0x000000')
Write-Host ('  B 1024x768 : @ ' + $AddrB)
Write-Host ('  log        : ' + $logPath)
Write-Host '  next       : power-cycle the board once, then flip SW3 (switch happens on the next image)'
exit 0
