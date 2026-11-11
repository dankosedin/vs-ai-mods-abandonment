<#
.SYNOPSIS
  Share updated within the horizon: mods with an AI hint vs the rest, under two labelling rules.

.DESCRIPTION
  Inputs: data\<extract>\cohort-rows.csv (Get-Cohorts.ps1), ai-hits.csv (Find-AiDeclarations.ps1), releases.csv.
  Only tool/phrase hits count (bare "AI" is mostly mob AI). Labelling rules for cohort X:
    broad   any hit in the current summary, description or any changelog;
    strict  a hit in a changelog of a release created before stable X (text that existed before the outcome).
  The broad label can depend on the outcome: only updated mods write new changelogs, and only maintained mods get
  descriptions edited. Where a broad-labelled mod's hits come from is also tabulated.
  -Labels: use the stage 4 model labels (ai-labels.csv, Merge-AiLabels.ps1) instead of the regex hints: a hit counts
  when labelled USED, from any keyword group; adds a row for mods that declare no AI (NOT_USED and no USED).
  Without -Labels the hints are unreviewed. Output: results\ai-cohorts[-labels]-<extract>.md (aggregates only).
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [string[]]$Releases = @('1.20', '1.21', '1.22'),
    [int]$MinDownloads = 50,
    [int]$Horizon = 195,
    [switch]$Labels,
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
$inv = [Globalization.CultureInfo]::InvariantCulture
function D([string]$s) { [datetime]::ParseExact($s.Trim(), [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd'), $inv, 'None') }
$ex = Join-Path $DataDir $Extract

$stable = @{}; Import-Csv (Join-Path $Root 'data\derived\game-releases.csv') | ForEach-Object { $stable[$_.branch] = D $_.stable }
$relDate = @{}; Import-Csv (Join-Path $ex 'releases.csv') -Encoding UTF8 | ForEach-Object { $relDate[$_.releaseid] = D $_.created }
$hits = @{}; $noAi = @{}
if ($Labels) {
    $lr = @(Import-Csv (Join-Path $ex 'ai-labels.csv') -Encoding UTF8)
    $src = @($lr | Where-Object label -eq 'USED')
    $usedMods = @{}; $src | ForEach-Object { $usedMods[$_.modid] = 1 }
    $lr | Where-Object { $_.label -eq 'NOT_USED' -and -not $usedMods[$_.modid] } | ForEach-Object { $noAi[$_.modid] = 1 }
} else {
    $src = @(Import-Csv (Join-Path $ex 'ai-hits.csv') -Encoding UTF8 | Where-Object { $_.groups -match 'tool|phrase' })
}
$src | ForEach-Object {
    if (-not $hits[$_.modid]) { $hits[$_.modid] = New-Object Collections.Generic.List[object] }
    $d = if ($_.source -eq 'changelog') { $relDate[$_.releaseid] } else { $null }
    $hits[$_.modid].Add([pscustomobject]@{ Source = $_.source; Date = $d })
}
$rows = @(Import-Csv (Join-Path $ex 'cohort-rows.csv') | Where-Object { [int]$_.downloads -ge $MinDownloads })
function Upd($r) { $r.updatedDay -ne '' -and [int]$r.updatedDay -le $Horizon }
function Cell($set) { $s = @($set); $k = @($s | Where-Object { Upd $_ }).Count
    if ($s.Count -eq 0) { '- (0)' } else { '{0}% ({1}/{2})' -f [Math]::Round(100.0 * $k / $s.Count), $k, $s.Count } }

$md = New-Object Collections.Generic.List[string]
$md.Add("# AI hint vs rest: $Extract")
$md.Add('')
$md.Add("Share updated within $Horizon days (updated / n). Downloads >= $MinDownloads. " + $(if ($Labels) { 'Stage 4 model labels (USED; stage 5 check 45/50; optional manual overrides, see Merge-AiLabels.ps1).' } else { 'Unreviewed tool/phrase hints.' }))
$md.Add('')
$md.Add('| | ' + ($Releases -join ' | ') + ' |')
$md.Add('|---|' + (($Releases | ForEach-Object { '---' }) -join '|') + '|')
$lines = [ordered]@{ 'broad: AI' = @(); 'broad: rest' = @(); 'strict: AI' = @(); 'strict: rest' = @()
    'broad AI, hit only in summary/description' = @(); 'broad AI, hit only in changelogs after stable X' = @(); 'declared no AI (labels only)' = @() }
$cells = @{}; foreach ($k in $lines.Keys) { $cells[$k] = @() }
foreach ($x in $Releases) {
    $c = @($rows | Where-Object release -eq $x); $st = $stable[$x]
    $broad = @(); $broadRest = @(); $strict = @(); $strictRest = @(); $descOnly = @(); $lateOnly = @()
    foreach ($r in $c) {
        $h = $hits[$r.modid]
        if (-not $h) { $broadRest += $r; $strictRest += $r; continue }
        $broad += $r
        $early = @($h | Where-Object { $_.Source -eq 'changelog' -and $_.Date -lt $st })
        if ($early.Count) { $strict += $r } else { $strictRest += $r }
        if (-not @($h | Where-Object Source -eq 'changelog').Count) { $descOnly += $r }
        elseif (-not $early.Count -and -not @($h | Where-Object { $_.Source -ne 'changelog' }).Count) { $lateOnly += $r }
    }
    $cells['broad: AI'] += Cell $broad; $cells['broad: rest'] += Cell $broadRest
    $cells['strict: AI'] += Cell $strict; $cells['strict: rest'] += Cell $strictRest
    $cells['broad AI, hit only in summary/description'] += Cell $descOnly
    $cells['broad AI, hit only in changelogs after stable X'] += Cell $lateOnly
    $cells['declared no AI (labels only)'] += Cell @($c | Where-Object { $noAi[$_.modid] })
}
foreach ($k in $lines.Keys) { $md.Add("| $k | " + ($cells[$k] -join ' | ') + ' |') }
$outMd = Join-Path $Root ("results\ai-cohorts" + $(if ($Labels) { '-labels' } else { '' }) + "-$Extract.md")
[IO.File]::WriteAllLines($outMd, $md, (New-Object Text.UTF8Encoding($false)))
$md | ForEach-Object { Write-Output $_ }
