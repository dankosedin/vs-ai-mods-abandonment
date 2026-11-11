<#
Author retention: does an author come back after the first mod, AI-declaring first mods vs the rest.

Author = the ModDB "author" field (one per mod). First mod = the author's earliest created mod (any type).
Group = the first mod's stage 4 label (AI = USED on the first mod; current texts, so late declarations included).
For each window W (days), only authors whose first mod is at least W days before -ListDate:
  new mod   = the author created another mod 7..W days after the first one (same-week batches do not count)
  active    = the author published any release (any of their mods) 30..W days after the first mod
Cohorts by half-year of the first mod. Wilson 95% intervals. Local data only.
Output: results\author-retention-<extract>.md
#>
param(
    [string]$DataDir,
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$ListDate = '2026-11-02',
    [int[]]$Windows = @(90, 180, 365)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $root 'data\private' }
$ex = Join-Path $DataDir $Extract
$list = [datetime]::ParseExact($ListDate, 'yyyy-MM-dd', $null)
function D($s) { [datetime]::ParseExact($s.Substring(0, 10), 'yyyy-MM-dd', $null) }
function Wil($k, $n) {
    if ($n -eq 0) { return '-' }
    $z = 1.96; $p = $k / $n; $d = 1 + $z * $z / $n
    $c = ($p + $z * $z / (2 * $n)) / $d; $h = $z * [math]::Sqrt($p * (1 - $p) / $n + $z * $z / (4 * $n * $n)) / $d
    '{0:N0}% [{1:N0}-{2:N0}] ({3}/{4})' -f (100 * $p), (100 * ($c - $h)), (100 * ($c + $h)), $k, $n
}

$mods = @(Import-Csv (Join-Path $ex 'mods.csv'))
$ai = @{}; Import-Csv (Join-Path $ex 'ai-mods.csv') | Where-Object { $_.used -eq 'True' } | ForEach-Object { $ai[$_.modid] = 1 }
$relByMod = @{}
Import-Csv (Join-Path $ex 'releases.csv') | ForEach-Object {
    if (-not $relByMod.ContainsKey($_.modid)) { $relByMod[$_.modid] = New-Object System.Collections.ArrayList }
    [void]$relByMod[$_.modid].Add((D $_.created))
}

$authors = foreach ($g in ($mods | Group-Object author)) {
    $ms = @($g.Group | Sort-Object created, { [int]$_.modid })
    $first = $ms[0]; $t0 = D $first.created
    $modDays = @($ms | Select-Object -Skip 1 | ForEach-Object { ((D $_.created) - $t0).TotalDays })
    $relDays = New-Object System.Collections.ArrayList
    foreach ($m in $ms) { if ($relByMod.ContainsKey($m.modid)) { foreach ($r in $relByMod[$m.modid]) { [void]$relDays.Add(($r - $t0).TotalDays) } } }
    $half = '{0}H{1}' -f $t0.Year, $(if ($t0.Month -le 6) { 1 } else { 2 })
    [pscustomobject]@{ Name = $g.Name; T0 = $t0; Half = $half; Ai = $ai.ContainsKey($first.modid); Mods = $ms.Count
        ModDays = $modDays; RelDays = $relDays.ToArray() }
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Author retention: $Extract")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Author = ModDB author field. First mod = earliest created. AI = the first mod declares AI use (stage 4 USED label, current texts: late declarations included, so AI is biased upwards). New mod = another mod created 7..W days after the first; active = any release 30..W days after the first. Only authors whose first mod is at least W days before $ListDate. Wilson 95% intervals.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Authors: $(@($authors).Count); first mod AI-declared: $(@($authors | Where-Object Ai).Count).")
foreach ($W in $Windows) {
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("## W = $W days")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| first mod | authors | AI | new mod: AI | new mod: rest | active: AI | active: rest |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|')
    $elig = @($authors | Where-Object { ($list - $_.T0).TotalDays -ge $W })
    foreach ($h in ($elig | Group-Object Half | Sort-Object Name)) {
        $a = @($h.Group | Where-Object Ai); $r = @($h.Group | Where-Object { -not $_.Ai })
        $nm = { param($x) @($x | Where-Object { @($_.ModDays | Where-Object { $_ -ge 7 -and $_ -le $W }).Count -gt 0 }).Count }
        $ac = { param($x) @($x | Where-Object { @($_.RelDays | Where-Object { $_ -ge 30 -and $_ -le $W }).Count -gt 0 }).Count }
        [void]$sb.AppendLine("| $($h.Name) | $($h.Count) | $($a.Count) | $(Wil (& $nm $a) $a.Count) | $(Wil (& $nm $r) $r.Count) | $(Wil (& $ac $a) $a.Count) | $(Wil (& $ac $r) $r.Count) |")
    }
}
$outPath = Join-Path $root "results\author-retention-$Extract.md"
[IO.File]::WriteAllText($outPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host "Written to $outPath"
