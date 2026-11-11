<#
Returning authors on DATED labels.

Definitions (identical to Get-AuthorRetention.ps1, which produced the post's 41% / 29%):
  Author     = the ModDB "author" field of mods.csv (one per mod).
  First mod  = the author's earliest created mod (ties: lower modid).
  New mod    = the author created another mod 7..W days after the first one (same-week batches do not count).
  Active     = the author published any release (any of their mods) 30..W days after the first mod.
  Eligible   = authors whose first mod is at least W days before -ListDate. Cohort = half-year of the first mod.
  Wilson 95% intervals. The unit of every count is an author (so n = authors, not mods).

Old labels: group = the first mod has a USED label in ai-mods.csv (current texts, late declarations included) vs the rest.
  Must reproduce 41% (22/54) vs 29% (242/832) for 2026H1, W = 90; the script checks this and says so in the output.

New labels: group = the group of the author's FIRST MOD in stage4b\cohort-groups.csv (written by Get-Stage4bCohort.ps1):
  AI-early, AI-late, AI-undetermined, noAI-early/late/undetermined, rest. That file covers only the dated population
  (cohort 1.22, downloads >= 50). First mods outside it have no dated label; they are shown in two extra rows,
  "outside dated set, current AI label" and "outside dated set, other" (the first is NOT a clean AI-early group).
  Also shown: "AI-early" against "everything else" (all other rows pooled) as the pre-registered comparison.

No author names in the output. Local data only.
Output: results\returning-authors-<extract>.md
#>
param(
    [string]$DataDir,
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$ListDate = '2026-11-02'
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
$grp = @{}; Import-Csv (Join-Path $ex 'stage4b\cohort-groups.csv') | ForEach-Object { $grp[$_.modid] = $_.group }
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
    $isAi = $ai.ContainsKey($first.modid)
    $ng = if ($grp.ContainsKey($first.modid)) { $grp[$first.modid] } elseif ($isAi) { 'outside dated set, current AI label' } else { 'outside dated set, other' }
    [pscustomobject]@{ Half = $half; T0 = $t0; Ai = $isAi; Group = $ng; ModDays = $modDays; RelDays = $relDays.ToArray() }
}

function NewMod($x, $W) { @($x | Where-Object { @($_.ModDays | Where-Object { $_ -ge 7 -and $_ -le $W }).Count -gt 0 }).Count }
function Active($x, $W) { @($x | Where-Object { @($_.RelDays | Where-Object { $_ -ge 30 -and $_ -le $W }).Count -gt 0 }).Count }

$views = @(@('2026H1', 90), @('2025H2', 180))
$sb = New-Object System.Text.StringBuilder
function Out($s) { [void]$sb.AppendLine($s) }
Out "# Returning authors on dated labels ($Extract)"
Out ''
Out "Definitions as in Get-AuthorRetention.ps1: author = ModDB author field; first mod = earliest created; new mod = another mod created 7..W days after the first; active = any release 30..W days after the first; only authors whose first mod is at least W days before $ListDate; Wilson 95% intervals. Unit = author (n = authors). The post's 41% / 29% come from results\author-retention-$Extract.md (2026H1, W = 90, row 'new mod'), produced by scripts\Get-AuthorRetention.ps1 (claims-register row 48)."
Out ''
$checkOk = $true
foreach ($v in $views) {
    $h = $v[0]; $W = $v[1]
    $el = @($authors | Where-Object { $_.Half -eq $h -and ($list - $_.T0).TotalDays -ge $W })
    $a = @($el | Where-Object Ai); $r = @($el | Where-Object { -not $_.Ai })
    Out "## $h, W = $W (eligible authors $($el.Count))"
    Out ''
    Out '### Old labels (first mod has a current USED label)'
    Out ''
    Out '| group | authors | new mod | active |'
    Out '|---|---|---|---|'
    Out "| AI (current labels) | $($a.Count) | $(Wil (NewMod $a $W) $a.Count) | $(Wil (Active $a $W) $a.Count) |"
    Out "| rest | $($r.Count) | $(Wil (NewMod $r $W) $r.Count) | $(Wil (Active $r $W) $r.Count) |"
    Out ''
    if ($h -eq '2026H1' -and $W -eq 90) {
        $ok = ((NewMod $a $W) -eq 22 -and $a.Count -eq 54 -and (NewMod $r $W) -eq 242 -and $r.Count -eq 832 -and (Active $a $W) -eq 26 -and (Active $r $W) -eq 282)
        $checkOk = $ok
        Out "Reproduction check against the post / author-retention report (22/54 vs 242/832 new mod; 26/54 vs 282/832 active): $(if ($ok) { 'REPRODUCED' } else { 'NOT REPRODUCED' })."
        Out ''
    }
    Out '### New labels (group of the first mod, stage 4b / 5)'
    Out ''
    Out '| group of the first mod | authors | new mod | active |'
    Out '|---|---|---|---|'
    $names = @('AI-early', 'AI-late', 'AI-undetermined', 'noAI-early', 'noAI-late', 'noAI-undetermined', 'rest', 'outside dated set, current AI label', 'outside dated set, other')
    foreach ($n in $names) {
        $s = @($el | Where-Object { $_.Group -eq $n })
        Out "| $n | $($s.Count) | $(Wil (NewMod $s $W) $s.Count) | $(Wil (Active $s $W) $s.Count) |"
    }
    $e = @($el | Where-Object { $_.Group -eq 'AI-early' }); $o = @($el | Where-Object { $_.Group -ne 'AI-early' })
    $na = @($el | Where-Object { $_.Group -like 'noAI-*' })
    Out "| noAI, all dated | $($na.Count) | $(Wil (NewMod $na $W) $na.Count) | $(Wil (Active $na $W) $na.Count) |"
    Out "| AI-early | $($e.Count) | $(Wil (NewMod $e $W) $e.Count) | $(Wil (Active $e $W) $e.Count) |"
    Out "| everything else (pooled) | $($o.Count) | $(Wil (NewMod $o $W) $o.Count) | $(Wil (Active $o $W) $o.Count) |"
    Out ''
}
if (-not $checkOk) { Out '**The old numbers were NOT reproduced; the new-label rows above should not be used until this is resolved.**'; Out '' }
Out 'Note: the dated groups exist only for first mods in the dated population (cohort 1.22, downloads >= 50); a first mod made in 2026H1 with fewer downloads or no 1.22 release is in an "outside dated set" row. The latter AI row uses current (undated) labels.'
$outPath = Join-Path $root "results\returning-authors-$Extract.md"
[IO.File]::WriteAllText($outPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host "Written to $outPath"
