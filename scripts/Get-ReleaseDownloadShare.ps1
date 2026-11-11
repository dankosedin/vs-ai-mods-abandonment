<#
Server-pinning check for the downloads-as-audience proxy. A client downloads the version the server runs, not the newest,
so downloads of non-newest releases of a game branch measure pinned servers and updates. Per (mod, branch) where
branch = highest game tag major.minor of a release:
  all = sum of downloads of all releases of the branch, max = downloads of the most downloaded release,
  newest = downloads of the newest release by date.
Reports per branch: total all / max / newest, share of non-newest downloads, and the audience curve both ways for
mods that have releases in every branch 1.16..1.22. Source: <DataDir>\moddb-cache\mods (the cache of raw API responses, read only).
Output: results\release-download-share.md
#>
param([int]$MinTotal = 500, [string]$DataDir, [string]$Cache)
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$root = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $root 'data\private' }
if (-not $Cache) { $Cache = Join-Path $DataDir 'moddb-cache\mods' }
$branches = '1.16','1.17','1.18','1.19','1.20','1.21','1.22'
function Branch($tags) {
    $best = $null
    foreach ($t in $tags) { if ($t -match '^(\d+)\.(\d+)') { $v = [int]$Matches[1]*1000+[int]$Matches[2]; if ($null -eq $best -or $v -gt $best) { $best = $v } } }
    if ($null -eq $best) { return $null }
    '{0}.{1}' -f [math]::Floor($best/1000), ($best % 1000)
}
$mb = @()   # one row per (mod, branch)
$n = 0
foreach ($f in Get-ChildItem $Cache -Filter *.json) {
    $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $j.mod -or -not $j.mod.releases) { continue }
    if ([int]$j.mod.downloads -lt $MinTotal) { continue }
    $n++
    $groups = $j.mod.releases | Group-Object { Branch $_.tags } | Where-Object { $_.Name }
    foreach ($g in $groups) {
        $r = @($g.Group)
        $all = ($r | Measure-Object downloads -Sum).Sum
        $max = ($r | Measure-Object downloads -Maximum).Maximum
        $newest = ($r | Sort-Object created -Descending | Select-Object -First 1).downloads
        $mb += [pscustomobject]@{ mod=$j.mod.modid; branch=$g.Name; releases=$r.Count; all=[long]$all; max=[long]$max; newest=[long]$newest }
    }
}
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("Mods with >= $MinTotal downloads: $n; (mod, branch) pairs: $($mb.Count).`n")
[void]$sb.AppendLine('**All mods with >= 2 releases in the branch** (thousand downloads):'); [void]$sb.AppendLine('')
[void]$sb.AppendLine('| branch | pairs | all releases | most downloaded | newest | share of non-newest | max / all |')
[void]$sb.AppendLine('|---|---|---|---|---|---|---|')
foreach ($b in $branches) {
    $x = $mb | Where-Object { $_.branch -eq $b -and $_.releases -ge 2 }
    if (-not $x) { continue }
    $a = ($x | Measure-Object all -Sum).Sum; $m = ($x | Measure-Object max -Sum).Sum; $nw = ($x | Measure-Object newest -Sum).Sum
    [void]$sb.AppendLine(('| {0} | {1} | {2:N0} | {3:N0} | {4:N0} | {5:P0} | {6:P0} |' -f $b,$x.Count,($a/1000),($m/1000),($nw/1000),(1-$nw/$a),($m/$a)))
}
$full = $mb | Group-Object mod | Where-Object { $s = $_.Group.branch; ($branches | Where-Object { $s -notcontains $_ }).Count -eq 0 }
$ids = @($full.Name)
[void]$sb.AppendLine("`n**Mods with releases in every branch 1.16..1.22** ($($ids.Count) mods, thousand downloads; index: 1.20 = 100):`n")
[void]$sb.AppendLine('| branch | all releases | most downloaded | index all | index max |')
[void]$sb.AppendLine('|---|---|---|---|---|')
$tot = @{}
foreach ($b in $branches) {
    $x = $mb | Where-Object { $_.branch -eq $b -and $ids -contains $_.mod }
    $tot[$b] = @{ all = ($x | Measure-Object all -Sum).Sum; max = ($x | Measure-Object max -Sum).Sum }
}
foreach ($b in $branches) {
    [void]$sb.AppendLine(('| {0} | {1:N0} | {2:N0} | {3:N0} | {4:N0} |' -f $b,($tot[$b].all/1000),($tot[$b].max/1000),(100*$tot[$b].all/$tot['1.20'].all),(100*$tot[$b].max/$tot['1.20'].max)))
}
$out = Join-Path $root 'results\release-download-share.md'
$sb.ToString() | Set-Content $out -Encoding UTF8
$sb.ToString()
