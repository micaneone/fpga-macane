# tools/ -- board-day helpers

All scripts are **pure ASCII** on purpose: Windows PowerShell 5.1 reads a
BOM-less `.ps1` as ANSI, so Chinese comments in a UTF-8 file turn into
mojibake (and occasionally break parsing).

Run them from anywhere; each script derives the project path from its own
location (`Split-Path -Parent $PSScriptRoot`).

| script | what it does |
|---|---|
| `build.ps1` | Deletes `prj\M2_Runs`, runs TD syn->phy, and **proves** a fresh `M2.bit` exists (mtime newer than start). Archives the bit to `..\burn\<Tag>_<stamp>.bit`. Logs to `logs\`. |
| `burn.ps1` | SRAM-downloads the bit (`download -bit`) and requires `PRG-2014 Chip validation success`. Archives a copy. `-ReadSeconds N -Port COM6` also decodes the serial frame afterwards. |
| `check_filelist.ps1` | Cross-checks `prj\M2.al` against disk: missing files, duplicates, unlisted-but-referenced modules (build breakers), unlisted-and-unused files (dead code). |

## Typical loop

```powershell
# 1. build (2 min, forces a clean run, archives the bit)
powershell -ExecutionPolicy Bypass -File .\tools\build.ps1 -Tag D5_try1

# 2. flash + read 8 s of serial frames
powershell -ExecutionPolicy Bypass -File .\tools\burn.ps1 -Tag D5_try1 -Port COM6 -ReadSeconds 8

# 3. sanity: is the RTL file list still consistent?
powershell -ExecutionPolicy Bypass -File .\tools\check_filelist.ps1
```

## Why `M2_Runs` must be deleted

TD's `create_run` silently "succeeds" when the run directory already exists;
`launch_runs` then replays the OLD run and `wait_run` returns in ~6 s. The
build log looks green but the bitstream is the previous one. `build.ps1`
deletes the directory and additionally checks the bit's timestamp, so a stale
build cannot pass unnoticed. (`-KeepRuns` exists only for debugging TD.)

## Serial frame

33 x 4 hex chars (`dbg_report.v`). `read_report.ps1` in the project root
decodes the common fields; the general layout is documented in
`rtl/top_m2.v` (header) and `rtl/dbg_report.v` (file header).
