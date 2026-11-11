<#
.SYNOPSIS
  New mods by creation window, measure (b): share of new mods with an update within H days after first publication.

.DESCRIPTION
  Inputs: data\<extract>\mods.csv, releases.csv, ai-mods.csv (Merge-AiLabels.ps1), game-releases.csv.
  Definitions:
  - First publication: the mod's earliest release (file); mods without releases are skipped.
  - Window W: first publication on or after stable W and before stable W+1 (the branch current when the mod was made).
    The last window is open (up to the list date).
  - Updated within H: a later release created at least 24 h after the first one (same-day re-uploads do not count)
    and at most H days after it.
  - Follow-up: only mods first published at least H days before the list date count for horizon H (complete
    follow-up, no censoring model).
  - Groups (from stage 4 labels): AI = any USED; noAI = NOT_USED and no USED; rest = the others.
  - Author's first mod: no mod of the same listed author in the extract was published earlier.
  - No downloads threshold by default (downloads grow with age, a threshold biases against young mods);
    -MinDownloads for a sensitivity run.
  - -CutAtNextStable: follow-up ends at the next stable game release after the first publication (or the list
    date), so updates prompted by a new game version do not count; for horizon H only mods with H days of follow-up
    before that release count (no bias against mods made late in a window).
  Measure (b) is activity, not "kept alive": early updates are often bug fixes.
  Output: results\new-mods-<extract>[-dlN][-cut].md (aggregates only).
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [int[]]$Horizons = @(30, 60, 90, 120, 180),
    [int]$MinDownloads = 0,
    [string]$ListDate = '2026-11-02',
    [switch]$CutAtNextStable,
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
$inv = [Globalization.CultureInfo]::InvariantCulture
function D([string]$s) { [datetime]::ParseExact($s.Trim(), [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd'), $inv, 'None') }
$ex = Join-Path $DataDir $Extract
$asOf = D $ListDate

$wins = @(Import-Csv (Join-Path $Root 'data\derived\game-releases.csv') | ForEach-Object { [pscustomobject]@{ b = $_.branch; s = D $_.stable } } | Sort-Object s)
$rel = @{}
Import-Csv (Join-Path $ex 'releases.csv') -Encoding UTF8 | ForEach-Object {
    if (-not $rel[$_.modid]) { $rel[$_.modid] = New-Object Collections.Generic.List[datetime] }
    $rel[$_.modid].Add((D $_.created))
}
$ai = @{}
Import-Csv (Join-Path $ex 'ai-mods.csv') | ForEach-Object {
    $ai[$_.modid] = if ($_.used -eq 'True') { 'AI' } elseif ($_.notUsed -eq 'True') { 'noAI' } else { $null } }

$mods = foreach ($m in (Import-Csv (Join-Path $ex 'mods.csv') -Encoding UTF8)) {
    $r = $rel[$m.modid]
    if (-not $r -or [int]$m.downloads -lt $MinDownloads) { continue }
    $d = @($r | Sort-Object)
    $first = $d[0]
    $w = $wins | Where-Object { $_.s -le $first } | Select-Object -Last 1
    if (-not $w) { continue }
    $next = $d | Where-Object { ($_ - $first).TotalHours -ge 24 } | Select-Object -First 1
    $end = $asOf
    if ($CutAtNextStable) { $ns = $wins | Where-Object { $_.s -gt $first } | Select-Object -First 1; if ($ns -and $ns.s -lt $end) { $end = $ns.s } }
    [pscustomobject]@{ modid = $m.modid; author = $m.author; first = $first; win = $w.b
        updDays = if ($next) { ($next - $first).TotalDays } else { $null }
        age = ($end - $first).TotalDays
        grp = if ($ai[$m.modid]) { $ai[$m.modid] } else { 'rest' } }
}
$mods = @($mods)
# Author's first mod
foreach ($g in ($mods | Group-Object author)) {
    $early = ($g.Group | Sort-Object first | Select-Object -First 1).modid
    foreach ($x in $g.Group) { $x | Add-Member firstOfAuthor ($x.modid -eq $early) }
}

function Cell($set, [int]$h) {
    $s = @($set | Where-Object { $_.age -ge $h })
    if ($s.Count -eq 0) { return '- (0)' }
    $k = @($s | Where-Object { $null -ne $_.updDays -and $_.updDays -le $h }).Count
    '{0}% ({1}/{2})' -f [Math]::Round(100.0 * $k / $s.Count), $k, $s.Count
}
$md = New-Object Collections.Generic.List[string]
$suffix = $(if ($MinDownloads -gt 0) { "-dl$MinDownloads" } else { '' }) + $(if ($CutAtNextStable) { '-cut' } else { '' })
$md.Add("# New mods by creation window: $Extract$suffix")
$md.Add('')
$md.Add("Measure (b): share of new mods with a release >= 24 h after the first one and within H days of it (updated / n). " +
    "Only mods published at least H days before $ListDate" + $(if ($CutAtNextStable) { ' and before the next stable game release (updates after it are not counted)' } else { '' }) + ". Window = branch whose stable release preceded the first publication. " +
    "Downloads >= $MinDownloads. Groups from stage 4 labels (AI = declared use, noAI = declared no use).")
$md.Add('')
$md.Add('## All new mods')
$md.Add('')
$md.Add('| window | new mods | ' + (($Horizons | ForEach-Object { "$_ d" }) -join ' | ') + ' |')
$md.Add('|---|---|' + (($Horizons | ForEach-Object { '---' }) -join '|') + '|')
$winNames = @($wins.b | Where-Object { $mods.win -contains $_ })
foreach ($w in $winNames) {
    $s = @($mods | Where-Object win -eq $w)
    $md.Add("| $w | $($s.Count) | " + (($Horizons | ForEach-Object { Cell $s $_ }) -join ' | ') + ' |')
}
foreach ($split in 'all', 'firstOfAuthor', 'experienced') {
    $md.Add('')
    $title = switch ($split) { 'all' { 'By declaration' } 'firstOfAuthor' { "By declaration, author's first mod" } 'experienced' { 'By declaration, author has earlier mods' } }
    $md.Add("## $title")
    $md.Add('')
    $md.Add('| window | group | new mods | authors | ' + (($Horizons | ForEach-Object { "$_ d" }) -join ' | ') + ' |')
    $md.Add('|---|---|---|---|' + (($Horizons | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($w in $winNames) {
        foreach ($g in 'AI', 'noAI', 'rest') {
            $s = @($mods | Where-Object { $_.win -eq $w -and $_.grp -eq $g -and (
                $split -eq 'all' -or ($split -eq 'firstOfAuthor' -and $_.firstOfAuthor) -or ($split -eq 'experienced' -and -not $_.firstOfAuthor)) })
            if ($s.Count -eq 0) { continue }
            $a = @($s | Select-Object -ExpandProperty author -Unique).Count
            $md.Add("| $w | $g | $($s.Count) | $a | " + (($Horizons | ForEach-Object { Cell $s $_ }) -join ' | ') + ' |')
        }
    }
}
$out = Join-Path $Root "results\new-mods-$Extract$suffix.md"
[IO.File]::WriteAllLines($out, $md, (New-Object Text.UTF8Encoding($false)))
$md | ForEach-Object { Write-Output $_ }
