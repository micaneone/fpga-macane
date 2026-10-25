# ============================================================
#  check_compile.ps1 -- compile + elaborate the M2 project with ModelSim
#
#  WHY: the two encrypted cores (SDRAM controller, HDMI core) cannot be
#  simulated, but EVERYTHING ELSE can. Compiling + elaborating top_m2
#  catches the classic board-day killers cheaply:
#      - a port name typed wrong in the top
#      - a module that is not in the file list
#      - a width mismatch
#  It does NOT simulate the real SD card (no card in a simulator).
#
#  Usage:  powershell -ExecutionPolicy Bypass -File .\check_compile.ps1
#          powershell -ExecutionPolicy Bypass -File .\check_compile.ps1 -NoProbe
#            -NoProbe = compile WITHOUT +define+B_DEBUG_PROBE.
#            Use it to emulate what TD does, because a TD project has no
#            global Verilog macro (every .al on this machine has an empty
#            <Project_Settings>, and there is nowhere else to put one).
#            Since 2026-10-02 the three b_display files that carry probe
#            ports define B_DEBUG_PROBE locally, so both variants must pass.
#
#  *** KEEP THIS FILE PURE ASCII ***  (see run_sim.ps1 for the reason)
# ============================================================

param([switch]$NoProbe)

$ErrorActionPreference = 'Continue'

# +define+SIM_SDRAM: sdr_arb instantiates the fake SDRAM instead of the encrypted one
# +define+B_DEBUG_PROBE: board-probe ports of the b_display modules.
#   NOTE: both macros live in ONE "+define+" argument on purpose (two separate
#   "+define+" arguments silently produced no library units in one environment).
$defs = if ($NoProbe) { '+define+SIM_SDRAM' } else { '+define+SIM_SDRAM+B_DEBUG_PROBE' }
Write-Host (">>> macros: " + $defs) -ForegroundColor DarkGray

# ★ 2026-10-13 [local machine paths -- teammates must edit these three lines]
$ms   = 'D:\altera\14.1\modelsim_ase\win32aloem'
$here = $PSScriptRoot
$vend = 'D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\sim_release\eg4'
# ★ The M0_bwtest\sim harness (fake_sdram.v + hdmi_core_model.v + tbs) is NOT
#   present on this machine yet -> this script stops at "MISSING:" below.
#   Point $m0 at the harness once a teammate hands it over.
$m0   = 'E:\FPGA\ygcom\pre-release-testing\sim'

if (-not (Test-Path "$ms\vlog.exe")) {
    Write-Host "ModelSim not found: $ms" -ForegroundColor Red
    exit 1
}

# fresh scratch dir every run (no deleting of anything)
$scratch = Join-Path $env:TEMP ('m1_check_' + (Get-Date -Format 'HHmmss'))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

# ---- the exact file list that should go into the TD project ----
$files = @()
$files += (Join-Path $here 'lib\sdram\global_def.v')
# 官方帧缓冲那一套（frame_read_write 要它）—— 现在读口自测用它
foreach ($f in 'frame_read_write.v','frame_fifo_read.v','frame_fifo_write.v',
               'afifo_16_32_256.v','afifo_32_16_256.v') {
    $files += (Join-Path $here ('lib\sdram\' + $f))
}
$files += (Get-ChildItem (Join-Path $here 'lib\util') -Filter *.v).FullName
$files += (Join-Path $here 'lib\video\video_timing.v')
# ★ 2026-10-05: the audio PLL (PLL_HDMI_AUDIO) is instantiated by the top now
#   (A-track audio chain needs 12.288 MHz).  It lives in lib\audio, which is
#   NOT globbed below -- without this line the elaborate fails with
#   "Instantiation of 'PLL_HDMI_AUDIO' failed. The design unit was not found."
$files += (Join-Path $here 'lib\audio\PLL_HDMI_AUDIO.v')
foreach ($f in 'hdmi_phy_wrapper_x4.v','lane_lvds_10_4.v','my_hdmitop.v','startup_pulse.v','video_rgb_to_axis.v') {
    $files += (Join-Path $here ('lib\hdmi\' + $f))
}
$files += (Get-ChildItem (Join-Path $here 'b_display') -Filter *.v).FullName
$files += (Get-ChildItem (Join-Path $here 'a_image')   -Filter *.v).FullName
$files += (Get-ChildItem (Join-Path $here 'rtl')       -Filter *.v).FullName
$files += (Get-ChildItem (Join-Path $here 'prj\al_ip') -Filter *.v).FullName
# 2026-10-20: viz2\ was missing from this list -> elaborate died with
# "Instantiation of 'viz_time' failed". TD's project (prj\M2.al) has always
# had these four files; keep the two lists in sync.
$files += (Get-ChildItem (Join-Path $here 'viz2')      -Filter *.v).FullName

# ---- stand-ins for the two encrypted cores + vendor primitive models ----
$extra = @(
    (Join-Path $m0 'fake_sdram.v'),          # module sdram is NOT used: sdr_arb takes fake_sdram
    (Join-Path $m0 'hdmi_core_model.v'),     # replaces hdmi_1_4b_transmitter_core_wrapper
    (Join-Path $vend 'eg_phy_pll.v'),
    (Join-Path $vend 'eg_logic_clk.v'),
    (Join-Path $vend 'eg_logic_io.v'),
    (Join-Path $vend 'eg_phy_glbl.v'),
    # 2026-10-02: bmp_scale now instantiates the TD BRAM primitive EG_LOGIC_BRAM
    # (the inferred array was 3072x64 = 196k flops; TD could not map it to BRAM).
    (Join-Path $vend 'eg_logic_bram.v'),
    # 2026-10-25: font_cn now instantiates EG_PHY_BRAM32K (24x24 glyph ROM,
    # INIT_FILE=font_cn.dat).  The TD model in sim_release is encrypted AND
    # ignores INIT_FILE (verified 2026-10-25: reads all zeros), so use our own
    # behavioural stand-in that does $readmemb from the .dat file.
    (Join-Path $m0 'eg_phy_bram32k_behav.v'),
    # 2026-10-25: top_m2 now instantiates EG_LOGIC_MBOOT (MULTI BOOT reconfig,
    # SW3 = switch display resolution).  TD has no sim model for it at all, so a
    # plain behavioural stub keeps check_compile/sim working.
    (Join-Path $m0 'eg_logic_mboot_behav.v')
)

# flat mirror: global_def.v is `include`d by path-less name
foreach ($f in ($files + $extra)) {
    if (Test-Path $f) { Copy-Item $f (Join-Path $scratch (Split-Path $f -Leaf)) -Force }
    else { Write-Host "MISSING: $f" -ForegroundColor Red; exit 1 }
}
# font_cn.v instantiates EG_PHY_BRAM32K with INIT_FILE="font_cn.dat" (relative
# to the run dir), so the stand-in model needs it next to the compiled units.
Copy-Item (Join-Path $here 'b_display\font_cn.dat') $scratch -Force

Push-Location $scratch
& "$ms\vlib.exe" work | Out-Null

Write-Host ">>> compiling" -ForegroundColor Cyan
$n = 0
foreach ($f in (Get-ChildItem -Filter *.v)) {
$out = & "$ms\vlog.exe" -work work $defs $f.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  COMPILE FAILED: " + $f.Name) -ForegroundColor Red
        $out | Select-String -Pattern 'Error|\*\*' | Select-Object -First 6 | ForEach-Object { Write-Host ("    " + $_.Line) }
        Pop-Location; exit 1
    }
    $n = $n + 1
}
Write-Host ("  " + $n + " files compiled OK")

Write-Host ">>> elaborating top_m2" -ForegroundColor Cyan
$top = @('work.glbl')
$out = & "$ms\vsim.exe" -c -do "quit -f" work.top_m2 $top 2>&1
if ($out | Select-String -Pattern '\*\* Error|Error loading design') {
    Write-Host "  ELABORATE FAILED" -ForegroundColor Red
    $out | Select-String -Pattern 'Error' | Select-Object -First 10 | ForEach-Object { Write-Host ("    " + $_.Line) }
    Pop-Location; exit 1
}

Pop-Location
Write-Host ""
Write-Host "OK: the whole M2 project compiles and top_m2 elaborates." -ForegroundColor Green
Write-Host "    (the SD card itself can only be verified on the board)" -ForegroundColor DarkGray

# ============================================================
#  smoke test (optional): does the display half actually run?
#    - compiles sim\*.v and runs tb_top_m1_smoke if it exists
#    - checks: PLL lock, frame_id advancing, read requests issued, no X
# ============================================================
$smoke = Join-Path $here 'sim\tb_top_m1_smoke.v'
if (-not (Test-Path $smoke)) { exit 0 }

$scratch2 = Join-Path $env:TEMP ('m1_smoke_' + (Get-Date -Format 'HHmmss'))
New-Item -ItemType Directory -Force -Path $scratch2 | Out-Null
foreach ($f in ($files + $extra)) {
    if (Test-Path $f) { Copy-Item $f (Join-Path $scratch2 (Split-Path $f -Leaf)) -Force }
}
Copy-Item $smoke $scratch2 -Force

Push-Location $scratch2
& "$ms\vlib.exe" work | Out-Null
foreach ($f in (Get-ChildItem -Filter *.v)) {
    $out = & "$ms\vlog.exe" -work work $defs $f.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  SMOKE COMPILE FAILED: " + $f.Name) -ForegroundColor Red
        Pop-Location; exit 1
    }
}

Write-Host ""
Write-Host ">>> smoke test (tb_top_m1_smoke)" -ForegroundColor Cyan
$log = '.\smoke.log'
& "$ms\vsim.exe" -l $log -c -do "run -all; quit -f" work.tb_top_m1_smoke work.glbl | Out-Null
Start-Sleep -Milliseconds 800
if (Test-Path $log) {
    Get-Content $log | Select-String -Pattern '^#\s+(===|  |ERROR|RESULT)' | ForEach-Object { Write-Host ("  " + $_.Line.TrimStart('#',' ')) }
    $raw = [System.IO.File]::ReadAllText((Resolve-Path $log))
    $ok = ($raw -match 'RESULT: PASS') -and -not ($raw -match 'RESULT: FAIL')
    Pop-Location
    if ($ok) { Write-Host "smoke: PASS" -ForegroundColor Green; exit 0 }
    else     { Write-Host "smoke: FAIL" -ForegroundColor Red; exit 1 }
}
Pop-Location
