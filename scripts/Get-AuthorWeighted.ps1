<#
.SYNOPSIS
  Mod-level vs author-level shares of mods updated within the horizon, per cohort and for AI-declared vs rest.

.DESCRIPTION
  Mods of one author are not independent (one author decides for all their mods), and prolific authors dominate
  mod-level shares. Three views per cohort (data\<extract>\cohort-rows.csv, downloads >= -MinDownloads):
    mods      share of mods updated within -Horizon days (the usual metric)
    weighted  every author has weight 1, split evenly over their mods in the cohort (mean of per-author shares)
    any       share of authors who updated at least one of their mods
  Also: share of the cohort held by the top 1% of authors, and the same three views for AI-declared mods
  (data\<extract>\ai-mods.csv, used = True) vs the rest. Author = the mod's listed author in mods.csv.
  Output: results\author-weighted-<extract>.md (aggregates only).
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [string[]]$Releases = @('1.15', '1.16', '1.17', '1.18', '1.19', '1.20', '1.21', '1.22'),
    [int]$MinDownloads = 50,
    [int]$Horizon = 195,
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
$ex = Join-Path $DataDir $Extract
$rows = @(Import-Csv (Join-Path $ex 'cohort-rows.csv') | Where-Object { [int]$_.downloads -ge $MinDownloads })
$ai = @{}
$aiFile = Join-Path $ex 'ai-mods.csv'
if (Test-Path $aiFile) { Import-Csv $aiFile | Where-Object { $_.used -eq 'True' } | ForEach-Object { $ai[$_.modid] = 1 } }
function Upd($r) { $r.updatedDay -ne '' -and [int]$r.updatedDay -le $Horizon }
function P($x) { if ($null -eq $x) { '-' } else { '{0}%' -f [Math]::Round(100.0 * $x) } }
function Views($set) {
    $s = @($set)
    if ($s.Count -eq 0) { return [pscustomobject]@{ n = 0; a = 0; mods = $null; weighted = $null; any = $null; top = $null } }
    $by = @($s | Group-Object author)
    $per = @($by | ForEach-Object { $g = @($_.Group); @($g | Where-Object { Upd $_ }).Count / $g.Count })
    $sizes = @($by | ForEach-Object { $_.Count } | Sort-Object -Descending)
    $k = [Math]::Max(1, [int][Math]::Ceiling($by.Count / 100))
    [pscustomobject]@{ n = $s.Count; a = $by.Count
        mods = @($s | Where-Object { Upd $_ }).Count / $s.Count
        weighted = ($per | Measure-Object -Average).Average
        any = @($per | Where-Object { $_ -gt 0 }).Count / $by.Count
        top = ($sizes[0..($k - 1)] | Measure-Object -Sum).Sum / $s.Count }
}
$md = New-Object Collections.Generic.List[string]
$md.Add("# Mods vs authors: $Extract")
$md.Add('')
$md.Add("Updated within $Horizon days after the stable release. Downloads >= $MinDownloads. weighted = each author counts once (mean of per-author shares); any = authors who updated at least one mod; top 1% = share of the cohort's mods held by the top 1% of authors.")
$md.Add('')
$md.Add('## All mods')
$md.Add('')
$md.Add('| cohort | mods | authors | mods updated | author-weighted | authors, any updated | top 1% of authors hold |')
$md.Add('|---|---|---|---|---|---|---|')
foreach ($x in $Releases) {
    $v = Views ($rows | Where-Object release -eq $x)
    $md.Add("| $x | $($v.n) | $($v.a) | $(P $v.mods) | $(P $v.weighted) | $(P $v.any) | $(P $v.top) |")
}
if ($ai.Count) {
    $md.Add('')
    $md.Add('## AI-declared (stage 4 labels, used = True) vs rest')
    $md.Add('')
    $md.Add('| cohort | group | mods | authors | mods updated | author-weighted | authors, any updated |')
    $md.Add('|---|---|---|---|---|---|---|')
    foreach ($x in ($Releases | Where-Object { $_ -in '1.20', '1.21', '1.22' })) {
        $c = @($rows | Where-Object release -eq $x)
        foreach ($grp in 'AI', 'rest') {
            $set = if ($grp -eq 'AI') { $c | Where-Object { $ai[$_.modid] } } else { $c | Where-Object { -not $ai[$_.modid] } }
            $v = Views $set
            $md.Add("| $x | $grp | $($v.n) | $($v.a) | $(P $v.mods) | $(P $v.weighted) | $(P $v.any) |")
        }
    }
}
$out = Join-Path $Root "results\author-weighted-$Extract.md"
[IO.File]::WriteAllLines($out, $md, (New-Object Text.UTF8Encoding($false)))
$md | ForEach-Object { Write-Output $_ }
