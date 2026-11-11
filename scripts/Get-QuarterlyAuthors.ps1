<#
.SYNOPSIS
  Mods per active author by quarter, AI-declaring mods by quarter, the "262 of 3411 authors" figure, and the
  decomposition of yearly mod growth into more authors vs more mods per author.

.DESCRIPTION
  Input (data\<extract>\): mods.csv, ai-mods.csv. No network.

  Definitions (same as Get-ModsVsAuthors.ps1, which this script complements; numbers must agree with it):
    mod            one row of mods.csv, all types (mod, externaltool, other); mods that still exist on the list date.
    author         the ModDB author field of the mod (one per mod). A renamed author splits in two, namesakes merge.
    quarter        calendar quarter of the mod's created date (first publication on ModDB), e.g. 2025Q3.
                   The last quarter (2026Q4) is partial (to the list date) and is not used for ratios.
    active author  in a quarter: a distinct author with at least one mod CREATED in that quarter ("creator").
    mods per active author  mods created in the quarter / active authors of the quarter.
    new author     an author whose first mod (earliest created) falls in the quarter.
    AI-declaring mod  ai-mods.csv column `used` = True (stage 4 label USED from the final labels: at least one fragment
                   of the description, summary or changelog says AI was used for the mod; CURRENT texts, so a
                   declaration added later counts for an old mod). Columns `notUsed` ("says no AI") and `feature` are not
                   used here.
    AI-declaring author  an author with at least one AI-declaring mod, at any date.
    "262 of 3411"  3411 = distinct author values in mods.csv (all 9291 mods); 262 = of them, authors with >= 1
                   AI-declaring mod. The share is 262/3411.
    Decomposition  between two periods A -> B: mods ratio M = mods_B/mods_A, authors ratio U = authors_B/authors_A,
                   mods per author ratio P = M/U. In logarithms ln M = ln U + ln P, so the share due to more authors is
                   ln U / ln M and the share due to productivity is ln P / ln M. Done for the two quarter pairs used in
                   the post (2024Q4 -> 2025Q3 and 2025Q3 -> 2026Q3) and for calendar years (2025 vs 2024).
                   Calendar year = created in the year; 2026 is partial and not used as a ratio.
  Output: results\quarterly-authors-<extract>.md (aggregates only, no author names).
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Get-QuarterlyAuthors.ps1
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$From = '2023Q1',
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
$inv = [Globalization.CultureInfo]::InvariantCulture
function F([double]$x, [string]$f = 'N2') { $x.ToString($f, $inv) }
function Pc($k, $n) { if ($n -eq 0) { '-' } else { (100.0 * $k / $n).ToString('N1', $inv) + '%' } }
function Q([string]$s) { $s.Substring(0, 4) + 'Q' + [math]::Ceiling([int]$s.Substring(5, 2) / 3) }
$ex = Join-Path $DataDir $Extract

$mods = @(Import-Csv (Join-Path $ex 'mods.csv') -Encoding UTF8)
$aiRows = @(Import-Csv (Join-Path $ex 'ai-mods.csv'))
$ai = @{}; $aiRows | Where-Object { $_.used -eq 'True' } | ForEach-Object { $ai[$_.modid] = 1 }
$notUsedOnly = @{}; $aiRows | Where-Object { $_.notUsed -eq 'True' -and $_.used -ne 'True' } | ForEach-Object { $notUsedOnly[$_.modid] = 1 }
foreach ($m in $mods) {
    $m | Add-Member -NotePropertyName Q -NotePropertyValue (Q $m.created) -Force
    $m | Add-Member -NotePropertyName Y -NotePropertyValue $m.created.Substring(0, 4) -Force
    $m | Add-Member -NotePropertyName Ai -NotePropertyValue ([bool]$ai.ContainsKey($m.modid)) -Force
}
$firstQ = @{}; $firstY = @{}
foreach ($g in ($mods | Group-Object author)) {
    $f = $g.Group | Sort-Object created, { [int]$_.modid } | Select-Object -First 1
    $firstQ[$g.Name] = $f.Q; $firstY[$g.Name] = $f.Y
}

$byAuthor = $mods | Group-Object author
$authors = $byAuthor.Count
$aiAuthors = @($byAuthor | Where-Object { @($_.Group | Where-Object Ai).Count -gt 0 })
$noOnlyAuthors = @($byAuthor | Where-Object { @($_.Group | Where-Object Ai).Count -eq 0 -and @($_.Group | Where-Object { $notUsedOnly.ContainsKey($_.modid) }).Count -gt 0 })
$modsOfAiAuthors = @($aiAuthors | ForEach-Object { $_.Group }).Count
$aiMods = @($mods | Where-Object Ai).Count

function Stats($set) {
    $s = @($set); $a = @($s | Group-Object author)
    [pscustomobject]@{ Mods = $s.Count; Authors = $a.Count; PerAuthor = if ($a.Count) { $s.Count / $a.Count } else { 0 } }
}
function Decomp([string]$name, $a, $b) {
    $M = $b.Mods / $a.Mods; $U = $b.Authors / $a.Authors; $P = $M / $U
    "| $name | x$(F $M) ($($a.Mods) -> $($b.Mods)) | x$(F $U) ($($a.Authors) -> $($b.Authors)) | x$(F $P) ($(F $a.PerAuthor) -> $(F $b.PerAuthor)) | $(F ([math]::Log($U) / [math]::Log($M)) 'N2') | $(F ([math]::Log($P) / [math]::Log($M)) 'N2') |"
}

$md = New-Object Collections.Generic.List[string]
$md.Add("# Quarterly mods and authors ($Extract)")
$md.Add('')
$md.Add('Generated by `scripts\Get-QuarterlyAuthors.ps1`. Aggregates only. Definitions in the script header: mod = row of mods.csv (all types); author = ModDB author field; quarter and year = created date; active author = distinct author with a mod created in the period; AI-declaring mod = ai-mods.csv column `used` = True (current texts, late declarations included). 2026Q4 is partial (to the list date).')
$md.Add('')
$md.Add('## Authors who declare AI')
$md.Add('')
$md.Add("- Authors in total: **$authors** (distinct author values over $($mods.Count) mods).")
$md.Add("- Authors with at least one AI-declaring mod (any date): **$($aiAuthors.Count)** = $(Pc $aiAuthors.Count $authors) of all authors. Claimed in the post: 262 of 3411 (7.7%).")
$md.Add("- Their mods in total: $modsOfAiAuthors, of which AI-declaring: $aiMods ($(Pc $aiMods $mods.Count) of all $($mods.Count) mods).")
$md.Add("- Authors whose only label is `"no AI`" (notUsed, no used): $($noOnlyAuthors.Count) (the post does not use this number).")
$md.Add('')
$md.Add('## By quarter (mods created in the quarter)')
$md.Add('')
$md.Add('| quarter | mods | active authors | mods per active author | new authors | AI-declaring mods | share of mods | active authors with an AI-declaring mod | mods w/o AI | active authors w/o AI mod | mods per author w/o AI |')
$md.Add('|---|---|---|---|---|---|---|---|---|---|---|')
$qs = @{}
foreach ($q in ($mods | Group-Object Q | Where-Object { $_.Name -ge $From } | Sort-Object Name)) {
    $s = Stats $q.Group; $qs[$q.Name] = $s
    $aiM = @($q.Group | Where-Object Ai); $aiA = @($aiM | Group-Object author).Count
    $no = Stats @($q.Group | Where-Object { -not $_.Ai })
    $newA = @($q.Group | Group-Object author | Where-Object { $firstQ[$_.Name] -eq $q.Name }).Count
    $md.Add("| $($q.Name) | $($s.Mods) | $($s.Authors) | $(F $s.PerAuthor) | $newA | $($aiM.Count) | $(Pc $aiM.Count $s.Mods) | $aiA | $($no.Mods) | $($no.Authors) | $(F $no.PerAuthor) |")
}
$md.Add('')
$md.Add('## By calendar year')
$md.Add('')
$md.Add('| year | mods | active authors | active authors with an AI-declaring mod (that year) | mods per active author | new authors | new authors with an AI-declaring mod (that year) | AI-declaring mods | share of mods |')
$md.Add('|---|---|---|---|---|---|---|---|---|')
$ys = @{}
foreach ($y in ($mods | Group-Object Y | Sort-Object Name)) {
    $s = Stats $y.Group; $ys[$y.Name] = $s
    $aiM = @($y.Group | Where-Object Ai)
    $newA = @($y.Group | Group-Object author | Where-Object { $firstY[$_.Name] -eq $y.Name })
    $newAi = @($newA | Where-Object { @($_.Group | Where-Object Ai).Count -gt 0 }).Count
    $md.Add("| $($y.Name)$(if ($y.Name -eq '2026') { ' (partial)' }) | $($s.Mods) | $($s.Authors) | $(@($aiM | Group-Object author).Count) | $(F $s.PerAuthor) | $($newA.Count) | $newAi | $($aiM.Count) | $(Pc $aiM.Count $s.Mods) |")
}
$md.Add('')
$md.Add('## Decomposition of mod growth: more authors vs more mods per author')
$md.Add('')
$md.Add('| period | mods | active authors | mods per author | share of ln(mods ratio) from authors | share from productivity |')
$md.Add('|---|---|---|---|---|---|')
$md.Add((Decomp '2024Q4 -> 2025Q3 (quarters)' $qs['2024Q4'] $qs['2025Q3']))
$md.Add((Decomp '2025Q3 -> 2026Q3 (quarters, one year)' $qs['2025Q3'] $qs['2026Q3']))
$md.Add((Decomp 'calendar 2024 -> 2025' $ys['2024'] $ys['2025']))
$md.Add('')
$m1 = $qs['2026Q3'].Mods / $qs['2025Q3'].Mods; $p1 = ($qs['2026Q3'].PerAuthor / $qs['2025Q3'].PerAuthor)
$md.Add("- Check of the post's claim for 2025Q3 -> 2026Q3: ln(P)/ln(M) = ln($(F $p1 'N3')) / ln($(F $m1 'N3')) = $(F ([math]::Log($p1) / [math]::Log($m1)) 'N3') (claimed 0.24 for productivity, so about 3/4 authors).")
$m2 = $ys['2025'].Mods / $ys['2024'].Mods; $u2 = $ys['2025'].Authors / $ys['2024'].Authors
$q2m = $qs['2025Q3'].Mods / $qs['2024Q4'].Mods; $q2u = $qs['2025Q3'].Authors / $qs['2024Q4'].Authors
$md.Add("- Wording check: calendar 2025 vs 2024 is x$(F $m2 'N1') mods and x$(F $u2 'N1') active authors (claimed x3.4 and x3.2); 2024Q4 -> 2025Q3 is x$(F $q2m 'N1') mods and x$(F $q2u 'N1') authors (claimed x2.8 and x2.8). The post should name which of the two definitions it cites.")
$md.Add('- Quarter-to-quarter ratios compare single quarters (seasonality and the 1.20 release in 2025Q1 are inside them); the calendar-year ratio is the less noisy of the two.')

$out = Join-Path $Root "results\quarterly-authors-$Extract.md"
[IO.File]::WriteAllLines($out, $md, (New-Object Text.UTF8Encoding($false)))
$md | ForEach-Object { Write-Output $_ }
