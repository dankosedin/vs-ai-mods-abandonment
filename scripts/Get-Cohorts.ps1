<#
.SYNOPSIS
  Cohort tables: share of mods updated within N days after a stable game release.

.DESCRIPTION
  Reads an extract made by Export-Extract.ps1 and game-releases.csv. Definitions (also in METHODOLOGY.md):
  - Branch of a tag: its first two components ("1.21.3-rc.2" -> "1.21").
  - "Wide" mod: some single release is tagged for 5+ branches. Excluded from all cohorts (noise "compatible with everything").
  - Cohort of release X (branch B, previous branch P): type = mod, downloads >= MinDownloads, created before stable X,
    has a release tagged P, not wide.
  - Updated: the earliest release tagged B. Its day = days from stable X to its created date, floored, and 0 if before
    stable (pre/rc counts as day 0; "ready at start" = day 0).
  - Backfilled: that earliest B release was created before pre.1 of X, i.e. a B tag added to an old file
    (the date of adding a tag is not stored). Variant "no backfill" drops these mods from the cohort.
  - Horizon: the common follow-up, days from the latest analysed stable release to the snapshot (list) date.
    Every mod in every cohort is followed for at least that long, so the Kaplan-Meier estimate at N <= horizon equals
    the plain share; no censoring is needed.
  - Age: of the mod on the day of stable X. Author mods: listAuthorMods (current list, includes later mods; biased up
    for authors who kept going) and atRelease (author's mods in the extract created before stable X; exact only on a
    full extract).
  - Survived (fatigue view): number of earlier branches Y (including the previous one) such that the mod existed before
    stable Y and has a release tagged Y. Survivorship still applies across cohorts; within one cohort the table reads
    "of mods that have already been carried through k releases, how many are carried through this one".
  - Author level: authors with >= 1 cohort mod; "updated" if any of them was updated within the horizon.
  Output: results\cohorts-<extract>.md (aggregates only, publishable) and data\<extract>\cohort-rows.csv (per mod).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Get-Cohorts.ps1 -Extract extract-2026-11-02-3084
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [string[]]$Releases = @('1.15', '1.16', '1.17', '1.18', '1.19', '1.20', '1.21', '1.22'),
    [int]$MinDownloads = 50,
    [int]$WideBranches = 5,
    [int[]]$Days = @(0, 30, 60, 90, 180),
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
$inv = [Globalization.CultureInfo]::InvariantCulture
function Parse-Date([string]$s) { [datetime]::ParseExact($s.Trim(), [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd'), $inv, 'None') }
function Branch([string]$tag) { $p = $tag.TrimStart('v').Split('.'); if ($p.Count -ge 2) { $p[0] + '.' + ($p[1] -replace '\D.*$', '') } else { $null } }

$exDir = Join-Path $DataDir $Extract
$meta = @{}; Get-Content (Join-Path $exDir 'meta.txt') | ForEach-Object { $k, $v = $_ -split '=', 2; $meta[$k] = $v }
$snapshot = Parse-Date $meta['listDate']

$gr = @{}; $branchOrder = @()
Import-Csv (Join-Path $Root 'data\derived\game-releases.csv') | ForEach-Object {
    $gr[$_.branch] = [pscustomobject]@{
        Pre1 = if ($_.pre1) { Parse-Date $_.pre1 } else { $null }; Stable = Parse-Date $_.stable }
    $branchOrder += $_.branch
}
$horizon = [int][Math]::Floor(($snapshot - ($Releases | ForEach-Object { $gr[$_].Stable } | Measure-Object -Maximum).Maximum).TotalDays)
$Days = @($Days | Where-Object { $_ -lt $horizon }) + $horizon

# ---- load extract ----
$mods = @{}
Import-Csv (Join-Path $exDir 'mods.csv') | ForEach-Object {
    $mods[$_.modid] = [pscustomobject]@{ Id = $_.modid; Author = $_.author; Type = $_.type; Created = (Parse-Date $_.created)
        Downloads = [int]$_.downloads; ListAuthorMods = [int]$_.listAuthorMods; Rel = New-Object Collections.Generic.List[object]; Wide = $false }
}
Import-Csv (Join-Path $exDir 'releases.csv') | ForEach-Object {
    $m = $mods[$_.modid]; if (-not $m) { return }
    $br = @($_.tags -split ';' | Where-Object { $_ } | ForEach-Object { Branch $_ } | Where-Object { $_ } | Sort-Object -Unique)
    if ($br.Count -ge $WideBranches) { $m.Wide = $true }
    $m.Rel.Add([pscustomobject]@{ Created = (Parse-Date $_.created); Branches = $br })
}
$byAuthor = @{}
foreach ($m in $mods.Values) { if (-not $byAuthor[$m.Author]) { $byAuthor[$m.Author] = New-Object Collections.Generic.List[datetime] }; $byAuthor[$m.Author].Add($m.Created) }

# ---- cohort rows ----
$rows = New-Object Collections.Generic.List[object]
foreach ($x in $Releases) {
    $i = [array]::IndexOf($branchOrder, $x); if ($i -lt 1) { throw "No previous branch for $x" }
    $p = $branchOrder[$i - 1]; $g = $gr[$x]
    foreach ($m in $mods.Values) {
        if ($m.Type -ne 'mod' -or $m.Wide -or $m.Created -ge $g.Stable) { continue }
        if (-not ($m.Rel | Where-Object { $_.Branches -contains $p })) { continue }
        $first = $m.Rel | Where-Object { $_.Branches -contains $x } | Sort-Object Created | Select-Object -First 1
        $day = $null; $back = $false
        if ($first) {
            $day = [Math]::Max(0, [int][Math]::Floor(($first.Created - $g.Stable).TotalDays))
            $back = ($null -ne $g.Pre1 -and $first.Created -lt $g.Pre1)
        }
        $ageY = ($g.Stable - $m.Created).TotalDays / 365.25
        $authorDates = $byAuthor[$m.Author]
        $atRel = @($authorDates | Where-Object { $_ -lt $g.Stable }).Count
        $tenureY = ($g.Stable - ($authorDates | Measure-Object -Minimum).Minimum).TotalDays / 365.25
        # releases survived: earlier branches Y (incl. P) such that the mod existed before stable Y and has a Y tag
        $surv = 0
        for ($j = 0; $j -lt $i; $j++) {
            $y = $branchOrder[$j]
            if ($m.Created -lt $gr[$y].Stable -and ($m.Rel | Where-Object { $_.Branches -contains $y })) { $surv++ }
        }
        $rows.Add([pscustomobject]@{
            release = $x; modid = $m.Id; author = $m.Author; downloads = $m.Downloads; updatedDay = $day; backfilled = $back
            survived = if ($surv -ge 3) { '3+' } else { [string]$surv }
            age = if ($ageY -lt 1) { '<1' } elseif ($ageY -lt 2) { '1-2' } elseif ($ageY -lt 4) { '2-4' } else { '4+' }
            authorList = if ($m.ListAuthorMods -le 2) { '1-2' } else { '3+' }
            authorAtRelease = if ($atRel -le 2) { '1-2' } else { '3+' }
            authorTenure = if ($tenureY -lt 1) { '<1' } elseif ($tenureY -lt 2) { '1-2' } else { '2+' }
        })
    }
}
$rows | Export-Csv (Join-Path $exDir 'cohort-rows.csv') -NoTypeInformation -Encoding UTF8

# ---- aggregates ----
function Share($set, [int]$n) { $c = @($set | Where-Object { $null -ne $_.updatedDay -and $_.updatedDay -le $n }).Count; $c }
function Pct([int]$k, [int]$n) { if ($n -eq 0) { '-' } else { [string][Math]::Round(100.0 * $k / $n) + '%' } }
function Ci([int]$k, [int]$n) { if ($n -eq 0) { '-' } else { $q = $k / $n; '+-' + [Math]::Round(196 * [Math]::Sqrt($q * (1 - $q) / $n)) } }

$md = New-Object Collections.Generic.List[string]
$md.Add("# Cohorts: $Extract")
$md.Add('')
$md.Add("Snapshot $($meta['listDate']), sample $($meta['sample']) of $($meta['listSize']) (in extract $($meta['extracted']), not in cache $($meta['notInCache'])).")
$md.Add("Filters: type = mod, downloads >= $MinDownloads, mods with a release on $WideBranches+ branches excluded. Horizon $horizon days.")
$md.Add('')

foreach ($variant in @('all', 'no backfill')) {
    $md.Add("## Share updated within N days ($variant)")
    $md.Add('')
    $md.Add('| | ' + ($Releases -join ' | ') + ' |')
    $md.Add('|---|' + (($Releases | ForEach-Object { '---' }) -join '|') + '|')
    $sets = @{}
    foreach ($x in $Releases) {
        $s = @($rows | Where-Object { $_.release -eq $x -and $_.downloads -ge $MinDownloads })
        if ($variant -eq 'no backfill') { $s = @($s | Where-Object { -not $_.backfilled }) }
        $sets[$x] = $s
    }
    $md.Add('| n | ' + (($Releases | ForEach-Object { $sets[$_].Count }) -join ' | ') + ' |')
    if ($variant -eq 'all') { $md.Add('| backfilled | ' + (($Releases | ForEach-Object { @($sets[$_] | Where-Object backfilled).Count }) -join ' | ') + ' |') }
    foreach ($n in $Days) {
        $md.Add("| $n d | " + (($Releases | ForEach-Object { Pct (Share $sets[$_] $n) $sets[$_].Count }) -join ' | ') + ' |')
    }
    $md.Add("| 95% CI at $horizon d, p.p. | " + (($Releases | ForEach-Object { Ci (Share $sets[$_] $horizon) $sets[$_].Count }) -join ' | ') + ' |')
    foreach ($dim in @(@('age', 'mod age, years', @('<1', '1-2', '2-4', '4+')),
                       @('authorList', 'author mods (current list)', @('1-2', '3+')),
                       @('authorAtRelease', 'author mods at release', @('1-2', '3+')),
                       @('authorTenure', 'author tenure at release, years', @('<1', '1-2', '2+')),
                       @('survived', 'game releases already survived', @('0', '1', '2', '3+')))) {
        foreach ($val in $dim[2]) {
            $cells = $Releases | ForEach-Object {
                $g = @($sets[$_] | Where-Object { $_.($dim[0]) -eq $val })
                (Pct (Share $g $horizon) $g.Count) + " ($($g.Count))"
            }
            $md.Add("| $($dim[1]) $val, $horizon d (n) | " + ($cells -join ' | ') + ' |')
        }
    }
    $md.Add('')
}

# author level: mods of one author are not independent; people quit, not mods
$md.Add("## Author level, $horizon d (all): share of authors who updated at least one cohort mod")
$md.Add('')
$md.Add('| | ' + ($Releases -join ' | ') + ' |')
$md.Add('|---|' + (($Releases | ForEach-Object { '---' }) -join '|') + '|')
$aRows = @{}
foreach ($x in $Releases) {
    $aRows[$x] = @($rows | Where-Object { $_.release -eq $x -and $_.downloads -ge $MinDownloads } | Group-Object author | ForEach-Object {
        [pscustomobject]@{
            mods = $_.Count
            tenure = $_.Group[0].authorTenure
            updated = [bool]($_.Group | Where-Object { $null -ne $_.updatedDay -and $_.updatedDay -le $horizon })
        } })
}
foreach ($f in @(@('all', { $true }), @('1 cohort mod', { $_.mods -eq 1 }), @('2+ cohort mods', { $_.mods -ge 2 }),
                 @('tenure <1 y', { $_.tenure -eq '<1' }), @('tenure 1-2 y', { $_.tenure -eq '1-2' }), @('tenure 2+ y', { $_.tenure -eq '2+' }))) {
    $cells = $Releases | ForEach-Object {
        $s = @($aRows[$_] | Where-Object $f[1]); (Pct @($s | Where-Object updated).Count $s.Count) + " ($($s.Count))"
    }
    $md.Add("| authors, $($f[0]) (n) | " + ($cells -join ' | ') + ' |')
}
$md.Add('')

# sensitivity: no download threshold
$md.Add("## Sensitivity: no download threshold, $horizon d (all)")
$md.Add('')
$md.Add('| | ' + ($Releases -join ' | ') + ' |')
$md.Add('|---|' + (($Releases | ForEach-Object { '---' }) -join '|') + '|')
$cells = $Releases | ForEach-Object { $s = @($rows | Where-Object release -eq $_);(Pct (Share $s $horizon) $s.Count) + " ($($s.Count))" }
$md.Add('| share (n) | ' + ($cells -join ' | ') + ' |')
$md.Add('')
$md.Add('Notes: "author mods at release" counts only mods present in the extract, so on a partial sample it undercounts.')

New-Item -ItemType Directory -Force (Join-Path $Root 'results') | Out-Null
$outMd = Join-Path $Root "results\cohorts-$Extract.md"
[IO.File]::WriteAllLines($outMd, $md, (New-Object Text.UTF8Encoding($false)))
$md | ForEach-Object { Write-Output $_ }
Write-Output "Written to $outMd"
