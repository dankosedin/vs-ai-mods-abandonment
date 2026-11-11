<#
.SYNOPSIS
  Stage 4, second pass, input: splits data\<extract>\ai-hits.csv into numbered batches for a model to label.

.DESCRIPTION
  Every hit row gets a stable id (its 1-based row number in ai-hits.csv). Rows are kept in file order and cut into
  batches of -BatchSize rows. All groups are included (tool, phrase and bare, with and without mobHint): labelling is
  cheap, and bare hits also hold negations ("no AI was used") and hits the mob heuristic misses.
  Output: data\<extract>\stage4\batch-NN.csv (id, modid, source, releaseid, groups, matches, fragment).
  The model writes data\<extract>\stage4\out-NN.txt per scripts\stage4-label-prompt.md; Merge-AiLabels.ps1 joins them.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Split-AiHits.ps1 -Extract extract-2026-11-02-all
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [int]$BatchSize = 161,
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Join-Path $here '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
$dir = Join-Path $DataDir $Extract
$rows = @(Import-Csv (Join-Path $dir 'ai-hits.csv') -Encoding UTF8)
$out = Join-Path $dir 'stage4'
New-Item -ItemType Directory -Force $out | Out-Null

$i = 0
$items = foreach ($r in $rows) {
    $i++
    [pscustomobject]@{ id = $i; modid = $r.modid; source = $r.source; releaseid = $r.releaseid
        groups = $r.groups; matches = $r.matches; fragment = $r.fragment }
}
$n = 0
for ($s = 0; $s -lt $items.Count; $s += $BatchSize) {
    $n++
    $e = [Math]::Min($s + $BatchSize, $items.Count) - 1
    $path = Join-Path $out ('batch-{0:D2}.csv' -f $n)
    $items[$s..$e] | Export-Csv $path -NoTypeInformation -Encoding UTF8
}
"rows $($items.Count), batches $n, in $out"
