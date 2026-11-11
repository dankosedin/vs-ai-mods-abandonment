<#
.SYNOPSIS
  Stage 2 input: which release file of each mod to classify as code or content, and the unique files to fetch.

.DESCRIPTION
  Inputs: data\<extract>\mods.csv, releases.csv, cohort-rows.csv (Get-Cohorts.ps1, all rows, no downloads threshold),
  game-releases.csv, and <DataDir>\moddb-cache\mods\<modid>.json for the file of each release (fileid, filename,
  mainfile URL; the extract's releases.csv has no file columns).
  Which release (METHODOLOGY.md, code / content split):
  - cohort row (cohort X): the latest release of the mod created before stable X (the cohort's reference point,
    as in Get-Cohorts.ps1). None: the row is kept with an empty releaseid (reason norelease).
  - new mod of window W (definitions of Get-NewMods.ps1, no downloads threshold, all types): the mod's first release
    (earliest created; ties by releaseid). Window = branch whose stable release is on or before it.
  Output in data\<extract>\stage2\:
  - release-files.csv  rowKind (cohort|newmod), group (cohort or window), modid, releaseid, fileid, filename, url, ext
  - unique-files.csv   one row per fileid in deterministic order: first 8 bytes (big-endian) of SHA-256 of
                       "<seed>-<fileid>", ties by fileid; fetch = True for .zip files (only those are requested).
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Export-ReleaseFiles.ps1 -Extract extract-2026-11-02-all
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [int]$Seed = 42,
    [string]$CacheDir,
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
if (-not $CacheDir) { $CacheDir = Join-Path $DataDir 'moddb-cache' }
$inv = [Globalization.CultureInfo]::InvariantCulture
function D([string]$s) { [datetime]::ParseExact($s.Trim(), [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd'), $inv, 'None') }
$Utf8 = New-Object Text.UTF8Encoding($false)
$ex = Join-Path $DataDir $Extract
$outDir = Join-Path $ex 'stage2'
New-Item -ItemType Directory -Force $outDir | Out-Null

$script:Sha = [Security.Cryptography.SHA256]::Create()
function Get-OrderKey([string]$s) {
    $b = $script:Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
    [uint64]$h = 0
    for ($i = 0; $i -lt 8; $i++) { $h = $h * 256 + $b[$i] }
    return $h
}

$stable = @{}
$wins = @(Import-Csv (Join-Path $Root 'data\derived\game-releases.csv') | ForEach-Object { $stable[$_.branch] = D $_.stable; [pscustomobject]@{ b = $_.branch; s = D $_.stable } } | Sort-Object s)

# releases of the extract, per mod
$rel = @{}
Import-Csv (Join-Path $ex 'releases.csv') -Encoding UTF8 | ForEach-Object {
    if (-not $rel[$_.modid]) { $rel[$_.modid] = New-Object Collections.Generic.List[object] }
    $rel[$_.modid].Add([pscustomobject]@{ Id = [int]$_.releaseid; Created = (D $_.created) })
}

$picks = New-Object Collections.Generic.List[object]
# cohort rows
foreach ($r in (Import-Csv (Join-Path $ex 'cohort-rows.csv') -Encoding UTF8)) {
    $st = $stable[$r.release]
    $p = $null
    if ($rel[$r.modid]) { $p = $rel[$r.modid] | Where-Object { $_.Created -lt $st } | Sort-Object Created, Id | Select-Object -Last 1 }
    $picks.Add([pscustomobject]@{ rowKind = 'cohort'; group = $r.release; modid = $r.modid; releaseid = $(if ($p) { [string]$p.Id } else { '' }) })
}
$nCohort = $picks.Count
# new mods (Get-NewMods.ps1: mods with releases, window by first release)
foreach ($m in (Import-Csv (Join-Path $ex 'mods.csv') -Encoding UTF8)) {
    $r = $rel[$m.modid]; if (-not $r) { continue }
    $first = $r | Sort-Object Created, Id | Select-Object -First 1
    $w = $wins | Where-Object { $_.s -le $first.Created } | Select-Object -Last 1
    if (-not $w) { continue }
    $picks.Add([pscustomobject]@{ rowKind = 'newmod'; group = $w.b; modid = $m.modid; releaseid = [string]$first.Id })
}

# file of each release, from the mod cache
$files = @{}   # releaseid -> @{fileid; filename; url}
$noCache = 0
foreach ($modid in @($picks | Where-Object releaseid | Select-Object -ExpandProperty modid -Unique)) {
    $path = Join-Path $CacheDir "mods\$modid.json"
    if (-not (Test-Path $path)) { $noCache++; continue }
    $j = $Utf8.GetString([IO.File]::ReadAllBytes($path)).TrimStart([char]0xFEFF) | ConvertFrom-Json
    foreach ($x in @($j.mod.releases)) {
        $files[[string]$x.releaseid] = [pscustomobject]@{ fileid = [string]$x.fileid; filename = [string]$x.filename; url = [string]$x.mainfile }
    }
}
function Ext([string]$name, [string]$url) {
    $e = [IO.Path]::GetExtension($name).ToLowerInvariant()
    if (-not $e -and $url) { $e = [IO.Path]::GetExtension(([Uri]$url).AbsolutePath).ToLowerInvariant() }
    if ($e) { $e.TrimStart('.') } else { '' }
}
$out = foreach ($p in $picks) {
    $f = if ($p.releaseid) { $files[$p.releaseid] } else { $null }
    [pscustomobject]@{ rowKind = $p.rowKind; group = $p.group; modid = $p.modid; releaseid = $p.releaseid
        fileid = $(if ($f) { $f.fileid } else { '' }); filename = $(if ($f) { $f.filename } else { '' })
        url = $(if ($f) { $f.url } else { '' }); ext = $(if ($f) { Ext $f.filename $f.url } else { '' }) }
}
$out = @($out)
$out | Export-Csv (Join-Path $outDir 'release-files.csv') -NoTypeInformation -Encoding UTF8

$uniq = @($out | Where-Object fileid | Group-Object fileid | ForEach-Object {
    $f = $_.Group[0]
    [pscustomobject]@{ H = (Get-OrderKey ("$Seed-" + $f.fileid)); Id = [long]$f.fileid
        fileid = $f.fileid; filename = $f.filename; url = $f.url; ext = $f.ext; fetch = ($f.ext -eq 'zip') }
} | Sort-Object H, Id)
$i = 0
$uniq = @($uniq | ForEach-Object { $i++; [pscustomobject]@{ order = $i; fileid = $_.fileid; filename = $_.filename; url = $_.url; ext = $_.ext; fetch = $_.fetch } })
$uniq | Export-Csv (Join-Path $outDir 'unique-files.csv') -NoTypeInformation -Encoding UTF8

Write-Output ("rows: " + $out.Count + " (cohort " + $nCohort + ", newmod " + ($out.Count - $nCohort) + ")")
foreach ($k in 'cohort', 'newmod') {
    $s = @($out | Where-Object rowKind -eq $k)
    Write-Output ("  $k by group: " + (($s | Group-Object group | Sort-Object { [version]$_.Name } | ForEach-Object { $_.Name + '=' + $_.Count }) -join ' '))
    Write-Output ("  $k without release before reference point: " + @($s | Where-Object { -not $_.releaseid }).Count + ", release not in mod cache: " + @($s | Where-Object { $_.releaseid -and -not $_.fileid }).Count)
}
Write-Output ("mods missing from cache: $noCache")
Write-Output ("unique files: " + $uniq.Count + ", to fetch (zip): " + @($uniq | Where-Object fetch).Count)
Write-Output ("unique files by extension: " + (($uniq | Group-Object ext | Sort-Object Count -Descending | ForEach-Object { $(if ($_.Name) { $_.Name } else { '(none)' }) + '=' + $_.Count }) -join ' '))
Write-Output ("Written to $outDir")
