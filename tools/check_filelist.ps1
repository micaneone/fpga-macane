# ============================================================
#  check_filelist.ps1 -- keep prj\M2.al (TD's file list) in sync with disk
#
#  WHY: TD only compiles the .v files listed in prj\M2.al.  A module can sit
#  on disk, look perfectly active, and never be built -- or a file can be
#  listed but deleted.  Both cost board-day hours.  This script reports:
#
#    MISSING                  listed in M2.al but the file is gone      [error]
#    DUPLICATE ENTRIES        same file listed twice in M2.al           [error]
#    UNLISTED-BUT-REFERENCED  on disk, not listed, module is used by a
#                             listed file and defined nowhere in the
#                             list -> elaborate WILL fail              [error]
#    UNLISTED DUPLICATE COPY  on disk, not listed, module is already
#                             defined by a listed file (stale copy)     [info]
#    UNUSED LIB / _unused     lib\ pool or a *_unused folder            [info]
#    UNLISTED & UNUSED        project .v on disk, not listed, module not
#                             referenced anywhere -> dead code          [warn]
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\tools\check_filelist.ps1
#    ...  -Project <dir>      check another checkout
#  Exit code 0 = PASS, 1 = a real build breaker (red items) exists.
#
#  *** KEEP THIS FILE PURE ASCII ***
# ============================================================

param([string]$Project = '')

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Project)) { $Project = Split-Path -Parent $PSScriptRoot }
$Project = (Resolve-Path -LiteralPath $Project).Path
$prj     = Join-Path $Project 'prj'
$alPath  = Join-Path $prj 'M2.al'
if (-not (Test-Path -LiteralPath $alPath)) { throw ('M2.al not found: ' + $alPath) }

function Strip-Comments([string]$t) {
    $t = [regex]::Replace($t, '(?s)/\*.*?\*/', '')
    $t = [regex]::Replace($t, '//[^\r\n]*', '')
    return $t
}

# ---- 1. parse the Verilog file list out of the .al XML --------------------
$raw = [IO.File]::ReadAllText($alPath)
$listed = New-Object System.Collections.Generic.List[object]
foreach ($m in [regex]::Matches($raw, 'Path\s*=\s*"([^"]+)"')) {
    $rel = $m.Groups[1].Value
    if ($rel -notmatch '\.(v|sv)$') { continue }
    $full = [IO.Path]::GetFullPath((Join-Path $prj ($rel -replace '/', '\')))
    $dup = $false
    foreach ($e in $listed) { if ($e.Full -eq $full) { $dup = $true } }
    if (-not $dup) {
        $listed.Add([pscustomobject]@{
            Rel    = $rel
            Full   = $full
            Exists = (Test-Path -LiteralPath $full)
        })
    }
}
if ($listed.Count -eq 0) { throw 'no Verilog entries found in M2.al' }

$missing = @($listed | Where-Object { -not $_.Exists })
$dupes   = @($listed | Group-Object Full | Where-Object { $_.Count -gt 1 })

# ---- 2. listed files: concatenated text + set of defined modules ----------
$sb = New-Object System.Text.StringBuilder
foreach ($f in $listed) {
    if (-not $f.Exists) { continue }
    [void]$sb.Append([IO.File]::ReadAllText($f.Full))
    [void]$sb.Append("`n")
}
$listedText = Strip-Comments $sb.ToString()
$defined = New-Object System.Collections.Generic.HashSet[string]
foreach ($m in [regex]::Matches($listedText, '(?m)^\s*module\s+([A-Za-z_][\w$]*)')) {
    [void]$defined.Add($m.Groups[1].Value)
}

# ---- 3. candidate .v files on disk that are NOT in M2.al -----------------
$dirs = @('rtl', 'a_image', 'b_display', 'viz2', 'lib', 'prj\al_ip')
$cands = @()
foreach ($d in $dirs) {
    $dd = Join-Path $Project $d
    if (-not (Test-Path -LiteralPath $dd)) { continue }
    $cands += @(Get-ChildItem -LiteralPath $dd -Recurse -File -Filter *.v |
                Where-Object { $_.Name -notlike '*.bak*' })
}
$listedFull = @($listed | ForEach-Object { $_.Full })
$cands = @($cands | Where-Object { $listedFull -notcontains $_.FullName })

$unlistedUsed = @()   # error: module referenced but defined nowhere in the list
$dupCopies    = @()   # info : stale duplicate of a module that IS built
$libUnused    = @()   # info : library pool / *_unused folder
$orphan       = @()   # warn : project code that is not built and not used
foreach ($c in $cands) {
    $txt = Strip-Comments ([IO.File]::ReadAllText($c.FullName))
    $mods = @([regex]::Matches($txt, '(?m)^\s*module\s+([A-Za-z_][\w$]*)') |
              ForEach-Object { $_.Groups[1].Value })
    $rel = $c.FullName.Substring($Project.Length).TrimStart('\')

    $isLibOrParked = ($rel -match '^lib\\') -or ($rel -match '_unused')
    if ($mods.Count -eq 0) {
        if ($isLibOrParked) { $libUnused += [pscustomobject]@{ Rel = $rel; Why = 'no module (include/defines)' } }
        else                { $orphan    += [pscustomobject]@{ Rel = $rel; Why = 'no module (include/defines)' } }
        continue
    }

    $alreadyBuilt = $false
    foreach ($mod in $mods) { if ($defined.Contains($mod)) { $alreadyBuilt = $true } }
    $used = $false
    foreach ($mod in $mods) {
        if ($listedText -match ('\b' + [regex]::Escape($mod) + '\b')) { $used = $true }
    }

    if ($isLibOrParked) {
        $libUnused += [pscustomobject]@{ Rel = $rel; Why = ('modules: ' + ($mods -join ',')) }
    } elseif ($alreadyBuilt) {
        $dupCopies += [pscustomobject]@{ Rel = $rel; Why = ('duplicate of a built module: ' + ($mods -join ',')) }
    } elseif ($used) {
        $unlistedUsed += [pscustomobject]@{ Rel = $rel; Mods = ($mods -join ',') }
    } else {
        $orphan += [pscustomobject]@{ Rel = $rel; Why = ('never referenced: ' + ($mods -join ',')) }
    }
}

# ---- 4. report -----------------------------------------------------------
Write-Host ''
Write-Host '=== M2.al file list check ===' -ForegroundColor Cyan
Write-Host ('  listed .v files    : ' + $listed.Count + '   (' + $defined.Count + ' modules defined)')
Write-Host ('  unlisted on disk   : ' + $cands.Count)
Write-Host ''

$fail = $false
if ($missing.Count -gt 0) {
    $fail = $true
    Write-Host ('MISSING (' + $missing.Count + ') -- listed in M2.al but not on disk:') -ForegroundColor Red
    foreach ($m in $missing) { Write-Host ('  ' + $m.Rel) }
}
if ($dupes.Count -gt 0) {
    $fail = $true
    Write-Host ('DUPLICATE ENTRIES (' + $dupes.Count + ') in M2.al:') -ForegroundColor Red
    foreach ($g in $dupes) { Write-Host ('  ' + $g.Name + '  x' + $g.Count) }
}
if ($unlistedUsed.Count -gt 0) {
    $fail = $true
    Write-Host ('UNLISTED-BUT-REFERENCED (' + $unlistedUsed.Count + ') -- add to M2.al or elaborate will fail:') -ForegroundColor Red
    foreach ($u in $unlistedUsed) { Write-Host ('  ' + $u.Rel + '   [' + $u.Mods + ']') }
}

if ($dupCopies.Count -gt 0) {
    Write-Host ('UNLISTED DUPLICATE COPY (' + $dupCopies.Count + ') -- stale copy, safe to ignore/attic:') -ForegroundColor DarkGray
    foreach ($d in $dupCopies) { Write-Host ('  ' + $d.Rel + '   (' + $d.Why + ')') }
}
if ($libUnused.Count -gt 0) {
    Write-Host ('UNUSED LIB / _unused (' + $libUnused.Count + ') -- library pool, not project code:') -ForegroundColor DarkGray
    foreach ($l in $libUnused) { Write-Host ('  ' + $l.Rel + '   (' + $l.Why + ')') }
}
if ($orphan.Count -gt 0) {
    Write-Host ('UNLISTED & UNUSED (' + $orphan.Count + ') -- project dead code, candidate for attic/:') -ForegroundColor Yellow
    foreach ($o in $orphan) { Write-Host ('  ' + $o.Rel + '   (' + $o.Why + ')') }
}

Write-Host ''
if ($fail) {
    Write-Host 'RESULT: FAIL (fix the red items above)' -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: PASS' -ForegroundColor Green
exit 0
