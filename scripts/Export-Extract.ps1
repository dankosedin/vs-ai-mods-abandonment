<#
.SYNOPSIS
  Copies what this study needs from the shared ModDB cache into a frozen extract (two CSV files).

.DESCRIPTION
  The cache of raw API responses (scripts\cache\Update-ModDbCache.ps1) is mutable, so the study computes only from its own extract.
  The sample is the first -Sample positions of the cache's deterministic order (SHA-256 of "<seed>-<modid>",
  ties by modid) over the mod list of -ListDate. -Sample 0 means the whole list.
  Positions whose mod is not in the cache are counted and reported, not silently dropped.

  Output folder data\private\extract-<ListDate>-<n>\ :
    mods.csv      modid, name, author, type, created, downloads, listAuthorMods, fetchedUtc
    releases.csv  modid, releaseid, created, tags (';'-joined game version tags)
    meta.txt      parameters, counts, cache fetch time range
  listAuthorMods = number of mods by the same author in the whole list of ListDate (current, not at release time).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Export-Extract.ps1 -ListDate 2026-11-02 -Sample 3084
#>
param(
    [Parameter(Mandatory)][string]$ListDate,
    [int]$Sample = 0,
    [int]$Seed = 42,
    [string]$CacheDir,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $DataDir) { $DataDir = Join-Path $here '..\data\private' }
if (-not $CacheDir) { $CacheDir = Join-Path $DataDir 'moddb-cache' }
$inv = [Globalization.CultureInfo]::InvariantCulture

# ---- deterministic order key: first 8 bytes of SHA-256, big-endian (FNV-1a mixed poorly, see README) ----
$script:Sha = [Security.Cryptography.SHA256]::Create()
function Get-OrderKey([string]$s) {
    $b = $script:Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
    [uint64]$h = 0
    for ($i = 0; $i -lt 8; $i++) { $h = $h * 256 + $b[$i] }
    return $h
}
function Read-Json([string]$path) { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
function Csv([object]$v) { '"' + ([string]$v).Replace('"', '""') + '"' }

$listPath = Join-Path $CacheDir "modlist-$ListDate.json"
if (-not (Test-Path $listPath)) { throw "No list $listPath" }
$list = @((Read-Json $listPath).mods)

$authorCount = @{}
foreach ($m in $list) { $a = [string]$m.author; $authorCount[$a] = 1 + [int]$authorCount[$a] }

$order = $list | ForEach-Object {
    [pscustomobject]@{ H = (Get-OrderKey ("$Seed-" + $_.modid)); Id = [int]$_.modid; M = $_ }
} | Sort-Object H, Id
if ($Sample -gt 0) { $order = $order | Select-Object -First $Sample }

$index = @{}
Import-Csv (Join-Path $CacheDir 'index.csv') | ForEach-Object { $index[$_.modid] = $_ }

$label = if ($Sample -gt 0) { $Sample } else { 'all' }
$out = Join-Path $DataDir "extract-$ListDate-$label"
New-Item -ItemType Directory -Force $out | Out-Null

$modLines = New-Object Collections.Generic.List[string]
$relLines = New-Object Collections.Generic.List[string]
$modLines.Add('modid,name,author,type,created,downloads,listAuthorMods,fetchedUtc')
$relLines.Add('modid,releaseid,created,tags')
$missing = 0; $gone = 0; $ok = 0; $fetchedMin = $null; $fetchedMax = $null

foreach ($o in $order) {
    $id = [string]$o.Id
    $row = $index[$id]
    $file = Join-Path $CacheDir "mods\$id.json"
    if ($row -and $row.status -eq 'gone') { $gone++; continue }
    if (-not $row -or -not (Test-Path $file)) { $missing++; continue }
    $m = (Read-Json $file).mod
    $ok++
    if ($row.fetchedUtc) {
        if (-not $fetchedMin -or $row.fetchedUtc -lt $fetchedMin) { $fetchedMin = $row.fetchedUtc }
        if (-not $fetchedMax -or $row.fetchedUtc -gt $fetchedMax) { $fetchedMax = $row.fetchedUtc }
    }
    $modLines.Add((@($m.modid, $m.name, $m.author, $m.type, $m.created, $m.downloads,
        [int]$authorCount[[string]$o.M.author], $row.fetchedUtc) | ForEach-Object { Csv $_ }) -join ',')
    foreach ($r in @($m.releases)) {
        $relLines.Add((@($m.modid, $r.releaseid, $r.created, (@($r.tags) -join ';')) | ForEach-Object { Csv $_ }) -join ',')
    }
}

$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllLines((Join-Path $out 'mods.csv'), $modLines, $utf8)
[IO.File]::WriteAllLines((Join-Path $out 'releases.csv'), $relLines, $utf8)
$meta = @(
    "listDate=$ListDate", "listSize=$($list.Count)", "seed=$Seed", "sample=$label", "positions=$(@($order).Count)",
    "extracted=$ok", "gone=$gone", "notInCache=$missing", "releases=$($relLines.Count - 1)",
    "cacheFetchedUtc=$fetchedMin .. $fetchedMax", "createdUtc=$((Get-Date).ToUniversalTime().ToString('s'))Z"
)
[IO.File]::WriteAllLines((Join-Path $out 'meta.txt'), $meta, $utf8)
$meta | ForEach-Object { Write-Output $_ }
Write-Output "Written to $out"
if ($missing -gt 0) { Write-Warning "$missing sample positions are not in the cache; the extract is not the full sample." }
