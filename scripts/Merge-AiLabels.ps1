<#
.SYNOPSIS
  Stage 4, second pass, output: joins the model's labels (stage4\out-NN.txt) with the hits (stage4\batch-NN.csv).

.DESCRIPTION
  Checks that every hit id has exactly one valid label. Writes:
    data\<extract>\ai-labels.csv  one row per hit: id, modid, source, releaseid, groups, matches, mobHint-free hit
                                  columns plus label, scope, confidence, evidence
    data\<extract>\ai-mods.csv    one row per mod with any hit: modid, used, notUsed, feature, scopes, usedSources,
                                  usedConfidence (best), labels
    results\ai-labels-<extract>.md  aggregates only
  A mod is AI-declared (used = True) when any of its hits is labelled USED. Labels are the model's (stage 4); the
  manual check is stage 5.

  Manual overrides: an optional CSV (-OverridesFile, default <DataDir>\label-overrides.csv) with the columns
  pattern,label,scope,reason. A hit whose fragment matches a pattern (regex) gets that label; the model's label stays in
  modelLabel. The author's file is NOT published (its reasons mention specific mods and authors). Without the file the
  model labels are used as they are, and the counts differ slightly from the published ones (the results file says how
  many hits were overridden). Policy: an override is made only after a sample check shows the model mislabelled a
  recurring boilerplate sentence; the pattern is a fixed phrase, never a mod or author name.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Merge-AiLabels.ps1 -Extract extract-2026-11-02-all
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$Root,
    [string]$DataDir,
    [string]$OverridesFile
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
$ex = Join-Path $DataDir $Extract
$st = Join-Path $ex 'stage4'
$valid = 'USED', 'NOT_USED', 'OTHER_MOD', 'FEATURE', 'MOB', 'OTHER', 'UNCLEAR'

$hits = @{}
Get-ChildItem $st -Filter 'batch-*.csv' | ForEach-Object { Import-Csv $_.FullName -Encoding UTF8 | ForEach-Object { $hits[$_.id] = $_ } }
$lab = @{}
Get-ChildItem $st -Filter 'out-*.txt' | ForEach-Object {
    $f = $_.Name
    Get-Content $_.FullName -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
        $p = $_ -split '\|', 5
        if ($p.Count -ne 5 -or $valid -notcontains $p[1]) { throw "bad line in ${f}: $_" }
        if ($lab.ContainsKey($p[0])) { throw "duplicate id $($p[0]) in $f" }
        $lab[$p[0]] = $p
    }
}
$missing = @($hits.Keys | Where-Object { -not $lab.ContainsKey($_) })
if ($missing.Count) { throw "unlabelled ids: $($missing[0..9] -join ', ')" }

# Manual overrides (optional, not published): a hit whose fragment matches a pattern gets that label; the model's
# label is kept in modelLabel. Decisions and reasons live in the overrides file.
if (-not $OverridesFile) { $OverridesFile = Join-Path $DataDir 'label-overrides.csv' }
$ovr = @()
if (Test-Path $OverridesFile) { $ovr = @(Import-Csv $OverridesFile) } else { Write-Warning "No overrides file ($OverridesFile): model labels are used unchanged." }
$nOvr = 0
$rows = foreach ($id in ($hits.Keys | Sort-Object { [int]$_ })) {
    $h = $hits[$id]; $p = $lab[$id]
    $label = $p[1]; $scope = $p[2]; $conf = $p[3]; $ev = $p[4].Trim()
    $o = $ovr | Where-Object { $h.fragment -match $_.pattern } | Select-Object -First 1
    if ($o) { $nOvr++; $label = $o.label; $scope = $o.scope; $conf = 'high'; $ev = "override: $($o.pattern)" }
    [pscustomobject]@{ id = [int]$id; modid = $h.modid; source = $h.source; releaseid = $h.releaseid; groups = $h.groups
        matches = $h.matches; label = $label; scope = $scope; confidence = $conf; evidence = $ev; modelLabel = $p[1] }
}
$rows | Export-Csv (Join-Path $ex 'ai-labels.csv') -NoTypeInformation -Encoding UTF8

$rank = @{ high = 3; medium = 2; low = 1 }
$mods = foreach ($g in ($rows | Group-Object modid)) {
    $u = @($g.Group | Where-Object { $_.label -eq 'USED' })
    $scopes = @($u | ForEach-Object { $_.scope -split '\+' } | Where-Object { $_ -and $_ -ne '-' } | Sort-Object -Unique)
    $best = ($u | Sort-Object { $rank[$_.confidence] } -Descending | Select-Object -First 1).confidence
    [pscustomobject]@{ modid = $g.Name; used = [bool]$u.Count
        notUsed = [bool]@($g.Group | Where-Object { $_.label -eq 'NOT_USED' }).Count
        feature = [bool]@($g.Group | Where-Object { $_.label -eq 'FEATURE' }).Count
        scopes = $scopes -join '+'; usedSources = (@($u.source | Sort-Object -Unique) -join '+'); usedConfidence = $best
        labels = (@($g.Group.label | Sort-Object -Unique) -join '+') }
}
$mods | Export-Csv (Join-Path $ex 'ai-mods.csv') -NoTypeInformation -Encoding UTF8

# Aggregates
function Grp($r) { if ($r.groups -match 'tool|phrase') { 'tool/phrase' } else { 'bare only' } }
$md = New-Object Collections.Generic.List[string]
$md.Add("# Stage 4, second pass: model labels ($Extract)")
$md.Add('')
$md.Add("Hits: $($rows.Count) from $($mods.Count) mods. Labelled by Claude Haiku with scripts\stage4-label-prompt.md; checked on a blind sample of 50 by Claude Sonnet (stage 5, 45/50 agree). Manual overrides (private optional file): $nOvr hits.")
$md.Add('')
$md.Add('## Hits by label and keyword group')
$md.Add('')
$md.Add('| label | tool/phrase | bare only | all |')
$md.Add('|---|---|---|---|')
foreach ($l in $valid) {
    $s = @($rows | Where-Object { $_.label -eq $l })
    $a = @($s | Where-Object { (Grp $_) -eq 'tool/phrase' }).Count
    $md.Add("| $l | $a | $($s.Count - $a) | $($s.Count) |")
}
$md.Add('')
$md.Add('## Mods')
$md.Add('')
$used = @($mods | Where-Object { $_.used })
$md.Add("- AI declared (any USED hit): $($used.Count); of them high confidence: $(@($used | Where-Object { $_.usedConfidence -eq 'high' }).Count).")
$md.Add("- Also a NOT_USED hit in the same mod (partial use or contradiction): $(@($used | Where-Object { $_.notUsed }).Count).")
$md.Add("- No AI declared (NOT_USED only, no USED): $(@($mods | Where-Object { $_.notUsed -and -not $_.used }).Count).")
$md.Add("- AI as a feature, not declared as used: $(@($mods | Where-Object { $_.feature -and -not $_.used }).Count).")
$tp = @{}; $rows | Where-Object { (Grp $_) -eq 'tool/phrase' } | ForEach-Object { $tp[$_.modid] = 1 }
$md.Add("- Mods with a tool/phrase hint (first pass): $($tp.Count); of them AI declared: $(@($used | Where-Object { $tp[$_.modid] }).Count); AI declared from bare hits only: $(@($used | Where-Object { -not $tp[$_.modid] }).Count).")
$md.Add('')
$md.Add('## What AI was used for (AI-declared mods; a mod can have several)')
$md.Add('')
$md.Add('| scope | mods |')
$md.Add('|---|---|')
$used | ForEach-Object { $_.scopes -split '\+' } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending |
    ForEach-Object { $md.Add("| $($_.Name) | $($_.Count) |") }
$md.Add('')
$md.Add('## Where the declaration was found (AI-declared mods)')
$md.Add('')
$md.Add('| sources | mods |')
$md.Add('|---|---|')
$used | Group-Object usedSources | Sort-Object Count -Descending | ForEach-Object { $md.Add("| $($_.Name) | $($_.Count) |") }
$out = Join-Path $Root "results\ai-labels-$Extract.md"
$md | Set-Content $out -Encoding UTF8
"hits $($rows.Count), mods $($mods.Count), AI declared $($used.Count); wrote ai-labels.csv, ai-mods.csv, $out"
