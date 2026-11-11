<#
.SYNOPSIS
  Stage 4b: the AI group of a cohort split by when the declaration appeared (before / after the reference point).

.DESCRIPTION
  Inputs (data\<extract>\): cohort-rows.csv, ai-mods.csv, ai-labels.csv, releases.csv, stage4b\wayback-*.csv
  (Find-WaybackDeclarations.ps1, one file per run) and stage4b\manual.csv (hand-checked verdicts). No network.
  Population: cohort rows of -Cohort with downloads >= -MinDownloads. Updated = updatedDay not empty and <= -Horizon
  (as in Compare-AiCohorts.ps1).
  Dating of a mod that declares AI (ai-mods.csv used = True):
    changelog source  early if the earliest release with a USED changelog label was created before -RefDate, else late;
    description       (USED label from text or summary) manual.csv final if present, else the status of the mod's row
                      in the newest wayback-*.csv (by file time); early -> early; early-tag -> late (the ModDB "AI" tag
                      is not a declaration, by rule); late -> late; early-kw without a manual verdict ->
                      needs review; undetermined / nosnapshot / nodesc -> undetermined; no row or no status -> pending.
    both              early if either source is early; otherwise the description verdict when it is not late, else late.
  Groups: AI-early, AI-late, AI-undetermined, AI-needs-review, AI-pending, noAI (NOT_USED and no USED; not dated),
  rest (no declaration); plus the pre-registered view "no declaration at the reference point" = rest + AI-late.
  Per group: n, updated, share with a 95% Wilson interval, author-weighted share (each author weight 1, mean of
  per-author shares, as in Get-AuthorWeighted.ps1), authors.
  Output: results\stage4b-cohort-<extract>.md (aggregates only); author names in data\<extract>\stage4b\cohort-authors.md
  and data\<extract>\stage4b\cohort-dating.csv (per mod).
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$Cohort = '1.22',
    [string]$RefDate = '2026-04-21',
    [int]$MinDownloads = 50,
    [int]$Horizon = 195,
    [int]$TopAuthors = 5,
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
$inv = [Globalization.CultureInfo]::InvariantCulture
function D([string]$s) { [datetime]::ParseExact($s.Trim(), [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd'), $inv, 'None') }
$ref = D $RefDate
$ex = Join-Path $DataDir $Extract
$s4b = Join-Path $ex 'stage4b'

# A wayback run may be writing its csv right now: read with shared access.
function ReadShared([string]$path) {
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd() } finally { $fs.Dispose() }
    if ($t.Trim()) { @($t | ConvertFrom-Csv) } else { @() }
}

$relDate = @{}; Import-Csv (Join-Path $ex 'releases.csv') -Encoding UTF8 | ForEach-Object { $relDate[$_.releaseid] = D $_.created }
$aiMods = @{}; Import-Csv (Join-Path $ex 'ai-mods.csv') | ForEach-Object { $aiMods[$_.modid] = $_ }
$clFirst = @{}; $usedAny = @{}; $notUsed = @{}
Import-Csv (Join-Path $ex 'ai-labels.csv') -Encoding UTF8 | ForEach-Object {
    if ($_.label -eq 'USED') {
        $usedAny[$_.modid] = 1
        if ($_.source -eq 'changelog') {
            $d = $relDate[$_.releaseid]
            if ($null -eq $d) { Write-Warning "release $($_.releaseid) of mod $($_.modid) not in releases.csv" }
            elseif (-not $clFirst.ContainsKey($_.modid) -or $d -lt $clFirst[$_.modid]) { $clFirst[$_.modid] = $d }
        }
    } elseif ($_.label -eq 'NOT_USED') { $notUsed[$_.modid] = 1 }
}

$manual = @{}; $mf = Join-Path $s4b 'manual.csv'
if (Test-Path $mf) { Import-Csv $mf | ForEach-Object { $manual[$_.modid] = $_.final } }
$noaiExclude = @{}; $xf = Join-Path $s4b 'noai-exclude.csv'
if (Test-Path $xf) { Import-Csv $xf | ForEach-Object { $noaiExclude[$_.modid] = $_.reason } }
$wb = @{}; $wbFiles = @(Get-ChildItem $s4b -Filter 'wayback-*.csv' | Sort-Object LastWriteTime)
foreach ($f in $wbFiles) {
    $tag = $f.BaseName.Substring(8)
    foreach ($r in (ReadShared $f.FullName)) {
        $st = if ($r.PSObject.Properties['status']) { $r.status } else { '' }
        $wb[$r.modid] = [pscustomobject]@{ Status = $st; Tag = $tag }
    }
}

function DescVerdict([string]$modid) {
    if ($manual.ContainsKey($modid)) { return @($manual[$modid], 'manual') }
    $w = $wb[$modid]
    if (-not $w) { return @('pending', '') }
    $v = switch ($w.Status) {
        'early' { 'early' } 'early-tag' { 'late' } 'late' { 'late' } 'early-kw' { 'needs-review' }
        'undetermined' { 'undetermined' } 'nosnapshot' { 'undetermined' } 'nodesc' { 'undetermined' }
        default { 'pending' }
    }
    @($v, "wayback-$($w.Tag)")
}

$rows = @(Import-Csv (Join-Path $ex 'cohort-rows.csv') | Where-Object { $_.release -eq $Cohort -and [int]$_.downloads -ge $MinDownloads })
function Upd($r) { $r.updatedDay -ne '' -and [int]$r.updatedDay -le $Horizon }

$dating = New-Object Collections.Generic.List[object]
$noaiFrom = @{}
foreach ($r in $rows) {
    $m = $aiMods[$r.modid]
    $isAi = $m -and $m.used -eq 'True'
    if (-not $isAi) {
        $g = if ($notUsed[$r.modid] -and -not $usedAny[$r.modid] -and -not $noaiExclude.ContainsKey($r.modid)) { 'noAI' } else { 'rest' }
        if ($g -eq 'noAI') { $x = DescVerdict $r.modid; $g = 'noAI-' + $x[0]; $noaiFrom[$r.modid] = $x[1] }
        $r | Add-Member -NotePropertyName Group -NotePropertyValue $g -Force
        continue
    }
    $hasCl = $m.usedSources -match 'changelog'; $hasDesc = $m.usedSources -match 'text|summary'
    $cl = ''; $clDate = ''
    if ($hasCl) {
        if ($clFirst.ContainsKey($r.modid)) { $clDate = $clFirst[$r.modid].ToString('yyyy-MM-dd'); $cl = if ($clFirst[$r.modid] -lt $ref) { 'early' } else { 'late' } }
        else { $cl = 'pending'; Write-Warning "mod $($r.modid): changelog source but no dated USED changelog label" }
    }
    $dv = ''; $dFrom = ''
    if ($hasDesc) { $x = DescVerdict $r.modid; $dv = $x[0]; $dFrom = $x[1] }
    $source = if ($hasCl -and $hasDesc) { 'both' } elseif ($hasCl) { 'changelog' } else { 'description' }
    $verdict = if ($cl -eq 'early' -or $dv -eq 'early') { 'early' }
        elseif ($source -eq 'changelog') { $cl }
        elseif ($source -eq 'description') { $dv }
        elseif ($dv -ne 'late') { $dv } else { $cl }
    $r | Add-Member -NotePropertyName Group -NotePropertyValue "AI-$verdict" -Force
    $dating.Add([pscustomobject]@{ modid = $r.modid; author = $r.author; source = $source; verdict = $verdict
        updated = [bool](Upd $r); changelogVerdict = $cl; changelogFirstUsed = $clDate; descVerdict = $dv; descFrom = $dFrom })
}

# Wilson 95% interval
function Wilson([int]$k, [int]$n) {
    if ($n -eq 0) { return '-' }
    $z = 1.96; $p = $k / $n; $den = 1 + $z * $z / $n
    $c = ($p + $z * $z / (2 * $n)) / $den; $h = $z * [Math]::Sqrt($p * (1 - $p) / $n + $z * $z / (4 * $n * $n)) / $den
    '{0}-{1}%' -f [Math]::Round(100 * ($c - $h)), [Math]::Round(100 * ($c + $h))
}
function P($x) { if ($null -eq $x) { '-' } else { '{0}%' -f [Math]::Round(100.0 * $x) } }
function Line([string]$name, $set) {
    $s = @($set | Where-Object { $null -ne $_ }); $n = $s.Count
    if ($n -eq 0) { return "| $name | 0 | - | - | - | - | 0 |" }
    $k = @($s | Where-Object { Upd $_ }).Count
    $by = @($s | Group-Object author)
    $w = (@($by | ForEach-Object { $g = @($_.Group); @($g | Where-Object { Upd $_ }).Count / $g.Count }) | Measure-Object -Average).Average
    "| $name | $n | $k | $(P ($k / $n)) | $(Wilson $k $n) | $(P $w) | $($by.Count) |"
}
function G([string]$g) { @($rows | Where-Object Group -eq $g) }

$ai = $dating.ToArray()
$noaiAll = @($rows | Where-Object { $_.Group -like 'noAI-*' })
$cnt = @{}; foreach ($v in 'early', 'late', 'undetermined', 'needs-review', 'pending') { $cnt[$v] = @($ai | Where-Object verdict -eq $v).Count }
$dated = $cnt['early'] + $cnt['late'] + $cnt['undetermined']

$md = New-Object Collections.Generic.List[string]
$md.Add("# Stage 4b: AI declarations dated against the reference point, cohort $Cohort ($Extract)")
$md.Add('')
$md.Add("Cohort $Cohort, downloads >= $MinDownloads, n = $($rows.Count). Updated = a release for the next game version within $Horizon days. Reference point $RefDate (stable $Cohort).")
$md.Add('')
$md.Add("**Coverage:** $($ai.Count) mods declare AI (stage 4 labels). Dated $dated (early $($cnt['early']), late $($cnt['late']), undetermined $($cnt['undetermined'])); needs review $($cnt['needs-review']); pending (no stage 4b result yet) $($cnt['pending']). " +
    $(if ($cnt['pending'] -or $cnt['needs-review']) { '**Partial: the AI-early and AI-late rows will change.**' } else { 'All AI mods are dated.' }))
$md.Add('')
$md.Add('Dating: a changelog declaration is dated by the creation of the first release that carries it. A description declaration is early if it was on the last Wayback Machine snapshot before the cut (cut = max(reference point, mod creation + 14 days)), late if absent there, undetermined if the only snapshots before the cut fall in the first 14 days or none exist; verdicts of the search script are checked by hand. A mod declared in both is early if either is early. The ModDB "AI" tag is not counted as a declaration.')
$md.Add('')
$md.Add('| group | n | updated | share | 95% CI (Wilson) | author-weighted | authors |')
$md.Add('|---|---|---|---|---|---|---|')
$md.Add((Line 'AI, declared before the reference point (AI-early)' (G 'AI-early')))
$md.Add((Line 'AI, declared after (AI-late)' (G 'AI-late')))
$md.Add((Line 'AI, undetermined' (G 'AI-undetermined')))
$md.Add((Line 'AI, needs review' (G 'AI-needs-review')))
$md.Add((Line 'AI, pending' (G 'AI-pending')))
$md.Add((Line 'AI, all (current labels, undated)' @($rows | Where-Object { $_.Group -like 'AI-*' })))
$md.Add((Line 'declared no AI (noAI), all' $noaiAll))
$md.Add((Line '  noAI, declared before the reference point (noAI-early)' (G 'noAI-early')))
$md.Add((Line '  noAI, declared after (noAI-late)' (G 'noAI-late')))
$md.Add((Line '  noAI, undetermined' (G 'noAI-undetermined')))
$md.Add((Line '  noAI, needs review / pending' @((G 'noAI-needs-review') + (G 'noAI-pending'))))
$md.Add((Line 'no declaration (rest)' (G 'rest')))
$md.Add((Line 'all' $rows))
$md.Add('')
$md.Add('Pre-registered view (only declarations dated before the reference point count; late declarers fall into "no declaration"):')
$md.Add('')
$md.Add('| group | n | updated | share | 95% CI (Wilson) | author-weighted | authors |')
$md.Add('|---|---|---|---|---|---|---|')
$md.Add((Line 'declared AI at the reference point (AI-early)' (G 'AI-early')))
$md.Add((Line 'declared no AI at the reference point (noAI-early)' (G 'noAI-early')))
$md.Add((Line 'no declaration at the reference point (rest + AI-late)' @($rows | Where-Object { $_.Group -eq 'rest' -or $_.Group -eq 'AI-late' })))
$md.Add('')
$md.Add('noAI is dated like AI descriptions (Wayback, manual verdicts; stage 5). noAI-late and noAI-undetermined mods are shown in the table above but are not added to the last row, which keeps its AI-stage-4b definition (rest + AI-late); undetermined, needs-review and pending mods are left out of the pre-registered view. Mods listed in stage4b\noai-exclude.csv (labelled NOT_USED but not a no-AI statement) count as rest.')
$md.Add('')
$md.Add('By source of the declaration (mods, updated):')
$md.Add('')
$md.Add('| source | early | late | undetermined | needs review | pending |')
$md.Add('|---|---|---|---|---|---|')
foreach ($src in 'description', 'changelog', 'both') {
    $cells = foreach ($v in 'early', 'late', 'undetermined', 'needs-review', 'pending') {
        $s = @($ai | Where-Object { $_.source -eq $src -and $_.verdict -eq $v }); "$($s.Count) ($(@($s | Where-Object updated).Count))"
    }
    $md.Add("| $src | " + ($cells -join ' | ') + ' |')
}
$md.Add('')
$md.Add('Clustering: mods per author inside the group (largest authors, counts only).')
$md.Add('')
foreach ($v in 'early', 'late') {
    $by = @($ai | Where-Object verdict -eq $v | Group-Object author | Sort-Object Count -Descending)
    $md.Add("- AI-${v}: $(@($ai | Where-Object verdict -eq $v).Count) mods, $($by.Count) authors; largest: " + ((@($by | Select-Object -First $TopAuthors) | ForEach-Object { $_.Count }) -join ', '))
}
$md.Add('')
$md.Add("Wayback files read: " + (($wbFiles | ForEach-Object { $_.Name }) -join ', ') + "; manual verdicts: $($manual.Count).")

# Author names stay in data\ (not for publication), not in results\.
$internal = New-Object System.Collections.Generic.List[string]
$internal.Add("# Stage 4b, cohort ${Cohort}: authors (internal review only, not for publication)")
$internal.Add('')
foreach ($v in 'early', 'late') {
    $by = @($ai | Where-Object verdict -eq $v | Group-Object author | Sort-Object Count -Descending | Select-Object -First $TopAuthors)
    $internal.Add("- AI-${v}, top authors: " + (($by | ForEach-Object { $u = @($_.Group | Where-Object updated).Count; "$($_.Name) $($_.Count) ($u updated)" }) -join '; '))
}

$outMd = Join-Path $Root "results\stage4b-cohort-$Extract.md"
[IO.File]::WriteAllLines($outMd, $md, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllLines((Join-Path $s4b 'cohort-authors.md'), $internal, (New-Object Text.UTF8Encoding($false)))
$rows | ForEach-Object { [pscustomobject]@{ modid = $_.modid; group = $_.Group } } | Sort-Object { [int]$_.modid } | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $s4b 'cohort-groups.csv')
$outCsv = Join-Path $s4b 'cohort-dating.csv'
$dating | Sort-Object { [int]$_.modid } | Export-Csv -NoTypeInformation -Encoding UTF8 $outCsv
$md | ForEach-Object { Write-Output $_ }
