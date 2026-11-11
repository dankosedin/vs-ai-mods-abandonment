<#
.SYNOPSIS
  Stage 5 input: a stratified sample of stage 4 labels for a blind re-label by a stronger model.

.DESCRIPTION
  Reads data\<extract>\ai-labels.csv. Strata (fixed seed, so the sample is reproducible):
    usedBare     USED on hits from bare keywords only (most likely false positives)
    usedLow      USED with medium or low confidence, any group
    usedHigh     USED with high confidence on tool/phrase hits (should be easy; checks the base rate)
    otherTool    OTHER or UNCLEAR on tool/phrase hits (possible missed declarations)
    notUsed      NOT_USED
    mob          MOB (possible missed declarations among mob AI)
  Writes data\<extract>\stage5\sample.csv WITHOUT the stage 4 label (id, modid, source, releaseid, groups, matches,
  fragment) and stage5\strata.csv (id, stratum) for the comparison. The re-label uses the same prompt
  (scripts\stage4-label-prompt.md) and writes stage5\out.txt.
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [int]$Seed = 5,
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
$ex = Join-Path $DataDir $Extract
$lab = @(Import-Csv (Join-Path $ex 'ai-labels.csv') -Encoding UTF8)
$frag = @{}
Get-ChildItem (Join-Path $ex 'stage4') -Filter 'batch-*.csv' | ForEach-Object { Import-Csv $_.FullName -Encoding UTF8 | ForEach-Object { $frag[$_.id] = $_.fragment } }
$tp = { $_.groups -match 'tool|phrase' }
$strata = [ordered]@{
    usedBare  = @{ n = 12; rows = @($lab | Where-Object { $_.label -eq 'USED' -and $_.groups -notmatch 'tool|phrase' }) }
    usedLow   = @{ n = 8;  rows = @($lab | Where-Object { $_.label -eq 'USED' -and $_.confidence -ne 'high' }) }
    usedHigh  = @{ n = 8;  rows = @($lab | Where-Object { $_.label -eq 'USED' -and $_.confidence -eq 'high' -and $_.groups -match 'tool|phrase' }) }
    otherTool = @{ n = 10; rows = @($lab | Where-Object { $_.label -in 'OTHER', 'UNCLEAR' -and $_.groups -match 'tool|phrase' }) }
    notUsed   = @{ n = 6;  rows = @($lab | Where-Object { $_.label -eq 'NOT_USED' }) }
    mob       = @{ n = 6;  rows = @($lab | Where-Object { $_.label -eq 'MOB' }) }
}
$rng = New-Object Random $Seed
$taken = @{}; $pick = New-Object Collections.Generic.List[object]
foreach ($k in $strata.Keys) {
    $pool = @($strata[$k].rows | Where-Object { -not $taken[$_.id] } | Sort-Object { [int]$_.id })
    $order = @($pool | Sort-Object { $rng.Next() })
    foreach ($r in ($order | Select-Object -First $strata[$k].n)) {
        $taken[$r.id] = 1
        $pick.Add([pscustomobject]@{ id = $r.id; stratum = $k; pool = $pool.Count; r = $r })
    }
}
$out = Join-Path $ex 'stage5'
New-Item -ItemType Directory -Force $out | Out-Null
$pick | Sort-Object { $rng.Next() } | ForEach-Object { $r = $_.r
    [pscustomobject]@{ id = $r.id; modid = $r.modid; source = $r.source; releaseid = $r.releaseid; groups = $r.groups
        matches = $r.matches; fragment = $frag[$r.id] } } | Export-Csv (Join-Path $out 'sample.csv') -NoTypeInformation -Encoding UTF8
$pick | Select-Object id, stratum, pool | Export-Csv (Join-Path $out 'strata.csv') -NoTypeInformation -Encoding UTF8
$pick | Group-Object stratum | ForEach-Object { '{0}: {1} of {2}' -f $_.Name, $_.Count, $_.Group[0].pool }
