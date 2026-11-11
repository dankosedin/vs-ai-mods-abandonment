<#
.SYNOPSIS
  Re-runs the calculation scripts against a private copy of the extract and checks the key numbers of the post.

.DESCRIPTION
  The raw data is not published (see README.md), so this check needs the extract on your disk:
    data\private\extract-2026-11-02-all\   (or any folder given with -DataDir; a Windows directory junction works:
                                           cmd /c mklink /J data\private <folder that holds the extract>)
  The private data is only READ: the script copies the extract (without saved web pages and logs) and the scripts
  into a temporary work folder, runs the scripts there, reads the regenerated files in <work>\results, and compares
  key numbers with the expected values written below. Output: PASS / FAIL per number, then a summary. Exit code 1
  if any number FAILs. Published files in results\ are not touched.

  What is NOT re-run (needs the network or the cache of raw API responses): Export-*.ps1, Find-*.ps1, Split-AiHits.ps1,
  Sample-Stage5.ps1, Get-CodeContent.ps1, Get-YouTubeMonthly.ps1. Their outputs are part of the extract.
  Merge-AiLabels.ps1 is re-run only when -OverridesFile is given (the manual label overrides are private; without them
  the labels would differ from the published ones). Without it the labels in the extract are used as they are.
  Get-ReleaseDownloadShare.ps1 runs only when -CacheDir (folder with mods\<id>.json) is given.
  The hand-made inputs of stage 4b (stage4b\manual.csv, stage4b\noai-exclude.csv) are part of the private data.

  Runs take a few minutes (the author bootstrap is the longest). The machine is kept from idle sleep meanwhile.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Reproduce.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Reproduce.ps1 -DataDir D:\vs\private -OverridesFile D:\vs\private\label-overrides.csv
#>
param(
    [string]$DataDir,
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$OverridesFile,
    [string]$CacheDir,
    [string]$WorkDir,
    [switch]$SkipBootstrap,
    [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
if (-not $DataDir) { $DataDir = Join-Path $root 'data\private' }
$srcExtract = Join-Path $DataDir $Extract
if (-not (Test-Path (Join-Path $srcExtract 'mods.csv'))) {
    Write-Host "Extract not found: $srcExtract"
    Write-Host 'Put the extract there (README.md, "How to obtain the data") or pass -DataDir.'
    exit 2
}

# ---- keep the machine awake ----
Add-Type -Namespace W -Name K -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
$prev = [W.K]::SetThreadExecutionState([uint32]2147483649)  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
Write-Host ("sleep block: " + $(if ($prev -ne 0) { 'ok' } else { 'FAILED' }))

$started = Get-Date
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('ModDBResearch-repro-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$wScripts = Join-Path $WorkDir 'scripts'
$wData = Join-Path $WorkDir 'data\private'
$wResults = Join-Path $WorkDir 'results'
foreach ($p in @($wScripts, $wData, $wResults, (Join-Path $WorkDir 'data\derived'))) { New-Item -ItemType Directory -Force $p | Out-Null }
Copy-Item (Join-Path $here '*.ps1') $wScripts
Copy-Item (Join-Path $root 'data\derived\game-releases.csv') (Join-Path $WorkDir 'data\derived')
Write-Host "work folder: $WorkDir"

# copy of the extract (no saved web pages, no logs), plus audience data when present
& robocopy $srcExtract (Join-Path $wData $Extract) /E /XD pages /XF *.log *.out /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
$ytSrc = Join-Path $DataDir 'audience\youtube'; $twSrc = Join-Path $DataDir 'audience\twitch'
$haveAudience = (Test-Path $ytSrc) -and (Test-Path (Join-Path $twSrc 'sullygnome-monthly.csv'))
if ($haveAudience) {
    & robocopy $ytSrc (Join-Path $wData 'audience\youtube') '20??-??.json' /NFL /NDL /NJH /NJS /NP | Out-Null
    & robocopy $twSrc (Join-Path $wData 'audience\twitch') 'sullygnome-monthly.csv' /NFL /NDL /NJH /NJS /NP | Out-Null
}
$ovrCopy = $null
if ($OverridesFile) { $ovrCopy = Join-Path $WorkDir 'label-overrides.csv'; Copy-Item $OverridesFile $ovrCopy }

# ---- run the scripts ----
$failedScripts = @{}
function Run-Script([string]$name, [string[]]$extra = @()) {
    $s = Join-Path $wScripts $name
    $argStr = ($extra | ForEach-Object { if ($_ -like '-*') { $_ } else { "'" + $_ + "'" } }) -join ' '
    $cmd = "[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture; `$ErrorActionPreference = 'Stop'; & '$s' $argStr; exit 0"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $logPath = Join-Path $WorkDir ("run-" + [IO.Path]::GetFileNameWithoutExtension($name) + '.log')
    $t0 = Get-Date
    & powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc *> $logPath
    $code = $LASTEXITCODE
    $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds)
    if ($code -ne 0) {
        $last = (Get-Content $logPath -Tail 3) -join ' / '
        $failedScripts[$name] = $last
        Write-Host ("  [run] {0,-28} FAILED (exit {1}) {2}" -f $name, $code, $last)
    } else { Write-Host ("  [run] {0,-28} ok ({1} s)" -f $name, $sec) }
}
Write-Host 'Running calculation scripts:'
if ($ovrCopy) { Run-Script 'Merge-AiLabels.ps1' @('-OverridesFile', $ovrCopy) }
Run-Script 'Get-Cohorts.ps1'
Run-Script 'Compare-AiCohorts.ps1' @('-Labels')
Run-Script 'Get-Stage4bCohort.ps1'
Run-Script 'Get-Stage4bCodeContent.ps1'
if (-not $SkipBootstrap) { Run-Script 'Get-AuthorBootstrap.ps1' }
Run-Script 'Get-AuthorWeighted.ps1'
Run-Script 'Get-AuthorRetention.ps1'
Run-Script 'Get-ReturningAuthors.ps1'
Run-Script 'Get-ModsVsAuthors.ps1'
Run-Script 'Get-QuarterlyAuthors.ps1'
Run-Script 'Get-GrowthByRelease.ps1'
Run-Script 'Get-NewMods.ps1'
Run-Script 'Get-NewMods.ps1' @('-CutAtNextStable')
Run-Script 'Get-RepoAiSummary.ps1'
Run-Script 'Get-HiddenAiEstimate.ps1'
if ($haveAudience) { Run-Script 'Get-YouTubeRate.ps1' } else { Write-Host '  [run] Get-YouTubeRate.ps1 skipped (no audience data)' }
if ($CacheDir) { Run-Script 'Get-ReleaseDownloadShare.ps1' @('-Cache', (Join-Path $CacheDir 'mods')) } else { Write-Host '  [run] Get-ReleaseDownloadShare.ps1 skipped (no -CacheDir)' }

# ---- checks ----
$script:pass = 0; $script:fail = 0; $script:skip = 0
function Check([string]$name, [string]$file, [string]$rx, [string]$expected, [string]$needs = '') {
    $path = Join-Path $wResults $file
    if ($needs -and $failedScripts.ContainsKey($needs)) { Write-Host ("FAIL  {0}: script {1} failed" -f $name, $needs); $script:fail++; return }
    if (-not (Test-Path $path)) { Write-Host ("SKIP  {0}: {1} was not produced" -f $name, $file); $script:skip++; return }
    $text = ([IO.File]::ReadAllText($path) -replace "`r`n", "`n")
    $m = [regex]::Match($text, $rx, [Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $m.Success) { Write-Host ("FAIL  {0}: pattern not found in {1}" -f $name, $file); $script:fail++; return }
    $got = (@(1..($m.Groups.Count - 1) | ForEach-Object { $m.Groups[$_].Value }) -join '|')
    if ($got -eq $expected) { Write-Host ("PASS  {0}  [{1}]" -f $name, $got); $script:pass++ }
    else { Write-Host ("FAIL  {0}: got [{1}], expected [{2}]" -f $name, $got, $expected); $script:fail++ }
}
$ex = $Extract
Write-Host ''
Write-Host 'Checks (expected values are the numbers of the post):'
$s4 = "stage4b-cohort-$ex.md"; $bs = "author-bootstrap-$ex.md"; $qa = "quarterly-authors-$ex.md"; $gr = "growth-by-release-$ex.md"
Check 'cohort sizes 1.15..1.22 (mods alive at the release, downloads >= 50)' "cohorts-$ex.md" '^\| n \| ([\d |]+) \|' '176 | 217 | 383 | 421 | 791 | 1113 | 1996 | 3289' 'Get-Cohorts.ps1'
Check 'share updated within 195 days, 1.15..1.22' "cohorts-$ex.md" '^\| 195 d \| ([\d%| ]+) \|' '57% | 69% | 51% | 59% | 48% | 58% | 50% | 52%' 'Get-Cohorts.ps1'
Check 'AI-early: n | updated | share  (56% (25/45))' $s4 '\(AI-early\) \| (\d+) \| (\d+) \| (\d+)%' '45|25|56' 'Get-Stage4bCohort.ps1'
Check 'AI-late: n | updated | share  (96% (43/45))' $s4 '\(AI-late\) \| (\d+) \| (\d+) \| (\d+)%' '45|43|96' 'Get-Stage4bCohort.ps1'
Check 'rest + AI-late: n | updated | share  (52.2% = 1681/3221)' $s4 'rest \+ AI-late\) \| (\d+) \| (\d+) \| (\d+)%' '3221|1681|52' 'Get-Stage4bCohort.ps1'
Check 'all declared AI, undated: n | updated | share  (71.4% (70/98))' $s4 'AI, all \(current labels, undated\) \| (\d+) \| (\d+) \| (\d+)%' '98|70|71' 'Get-Stage4bCohort.ps1'
Check 'no-AI declarations: n | updated | share  (80% (12/15))' $s4 'declared no AI \(noAI\), all \| (\d+) \| (\d+) \| (\d+)%' '15|12|80' 'Get-Stage4bCohort.ps1'
Check 'undetermined AI mods: n | updated  (8 of 98)' $s4 'AI, undetermined \| (\d+) \| (\d+) \|' '8|2' 'Get-Stage4bCohort.ps1'
Check 'AI-early authors / AI-late authors (36 / 18)' $s4 '- AI-early: 45 mods, (\d+) authors;[^\n]*\n- AI-late: 45 mods, (\d+) authors' '36|18' 'Get-Stage4bCohort.ps1'
Check 'broad AI vs rest, labels, 1.22 (71% (70/98) vs 52% (1650/3191))' "ai-cohorts-labels-$ex.md" '^\| broad: AI \|[^|]*\|[^|]*\| (\d+% \(\d+/\d+\)) \|\n\| broad: rest \|[^|]*\|[^|]*\| (\d+% \(\d+/\d+\)) \|' '71% (70/98)|52% (1650/3191)' 'Compare-AiCohorts.ps1'
Check 'author bootstrap, AI-early vs rest + AI-late: difference | CI low | CI high  (+3.4, -11.6..+19.4)' $bs 'b/a: AI-early vs rest \+ AI-late \| A \|[^\n]*\n\| \| B \|[^\n]*\n\| \| A - B \| \| \| ([\-\d.]+) \| \| ([\-\d.]+) to ([\-\d.]+) \|' '3.4|-11.6|19.4' 'Get-AuthorBootstrap.ps1'
Check 'author bootstrap, AI-early share and authors (55.6%, 36 authors)' $bs 'b/a: AI-early vs rest \+ AI-late \| A \| (\d+) \| (\d+) \| ([\d.]+) \|' '45|36|55.6' 'Get-AuthorBootstrap.ps1'
Check 'author bootstrap, rest + AI-late share (52.2%)' $bs 'b/a: AI-early vs rest \+ AI-late \| A \|[^\n]*\n\| \| B \| (\d+) \| \d+ \| ([\d.]+) \|' '3221|52.2' 'Get-AuthorBootstrap.ps1'
Check 'author bootstrap, all declarers minus the rest: difference | CI  (+19.7, +3.6..+32.8)' $bs 'c: all declared AI vs all non-declared \(rest \+ noAI\) \| A \|[^\n]*\n\| \| B \|[^\n]*\n\| \| A - B \| \| \| ([\-\d.]+) \| \| ([\-\d.]+) to ([\-\d.]+) \|' '19.7|3.6|32.8' 'Get-AuthorBootstrap.ps1'
Check 'author bootstrap, code mods: AI-early and other (69.7% of 33; other 61.5% of 1452 here, 892/1451 = 61.5% in the stage 4b report)' $bs 'd1: code mods, AI-early vs rest \+ AI-late \| A \| (\d+) \| \d+ \| ([\d.]+) \|[^\n]*\n\| \| B \| (\d+) \| \d+ \| ([\d.]+) \|' '33|69.7|1452|61.5' 'Get-AuthorBootstrap.ps1'
Check 'author bootstrap, content mods: difference | CI  (-26.3, -46.2..+9.9)' $bs 'd2: content mods, AI-early vs rest \+ AI-late \| A \|[^\n]*\n\| \| B \|[^\n]*\n\| \| A - B \| \| \| ([\-\d.]+) \| \| ([\-\d.]+) to ([\-\d.]+) \|' '-26.3|-46.2|9.9' 'Get-AuthorBootstrap.ps1'
Check 'AI-early code / content updated (70% (23/33), 18% (2/11))' "stage4b-code-content-$ex.md" '^\| AI-early \(declared before the reference point\) \| (\d+% \(\d+/\d+\)) \[[^\]]*\] \| (\d+% \(\d+/\d+\))' '70% (23/33)|18% (2/11)' 'Get-Stage4bCodeContent.ps1'
Check 'other code / content updated (61% (892/1451), 44% (782/1759))' "stage4b-code-content-$ex.md" 'pre-registered view\) \| (\d+% \(\d+/\d+\)) \[[^\]]*\] \| (\d+% \(\d+/\d+\))' '61% (892/1451)|44% (782/1759)' 'Get-Stage4bCodeContent.ps1'
Check 'mods at the 1.19 stable release (1323; 1321 by the strict rule)' $gr '^\| 1\.19 \| 2024-01-17 \| (\d+) \| (\d+) \|' '1323|1321' 'Get-GrowthByRelease.ps1'
Check 'mods in the extract (9291)' $gr '(\d+) mods in the extract' '9291' 'Get-GrowthByRelease.ps1'
Check 'growth since 1.19 (x7.02)' $gr 'Growth 1\.19 -> now: x([\d.]+) \(primary\)' '7.02' 'Get-GrowthByRelease.ps1'
Check 'AI-declaring mods and their share of all mods (549, 5.9%)' $qa 'of which AI-declaring: (\d+) \(([\d.]+)% of all 9291 mods\)' '549|5.9' 'Get-QuarterlyAuthors.ps1'
Check 'authors in total (3411)' $qa 'Authors in total: \*\*(\d+)\*\*' '3411' 'Get-QuarterlyAuthors.ps1'
Check 'authors with an AI-declaring mod (262, 7.7%)' $qa 'at least one AI-declaring mod \(any date\): \*\*(\d+)\*\* = ([\d.]+)%' '262|7.7' 'Get-QuarterlyAuthors.ps1'
Check 'calendar 2025 vs 2024: mods, authors (x3.4, x3.2)' $qa 'calendar 2025 vs 2024 is x([\d.]+) mods and x([\d.]+) active authors' '3.4|3.2' 'Get-QuarterlyAuthors.ps1'
Check 'author-weighted share, 1.22: mods vs authors (52% vs 46%)' "author-weighted-$ex.md" '^\| 1\.22 \| 3289 \| 1424 \| (\d+)% \| (\d+)%' '52|46' 'Get-AuthorWeighted.ps1'
Check 'returning authors, 2026H1, W=90, current labels (41% (22/54) vs 29% (242/832))' "returning-authors-$ex.md" '^\| AI \(current labels\) \| 54 \| (\d+)% \[[^\]]*\] \((\d+/\d+)\)[^\n]*\n\| rest \| 832 \| (\d+)% \[[^\]]*\] \((\d+/\d+)\)' '41|22/54|29|242/832' 'Get-ReturningAuthors.ps1'
Check 'new 1.22 mods, declared AI updated at 30 / 90 days (56%, 63%)' "new-mods-$ex.md" '^\| 1\.22 \| AI \| 433 \| 216 \| (\d+)% \(\d+/\d+\) \| \d+% \(\d+/\d+\) \| (\d+)%' '56|63' 'Get-NewMods.ps1'
Check 'new 1.22 mods, the rest updated at 30 / 90 days (47%, 51%)' "new-mods-$ex.md" '^\| 1\.22 \| rest \| 2854 \| 1260 \| (\d+)% \(\d+/\d+\) \| \d+% \(\d+/\d+\) \| (\d+)%' '47|51' 'Get-NewMods.ps1'
Check 'mods with a public repository (2160)' "repo-ai-$ex.md" 'Mods in these repositories: (\d+)' '2160' 'Get-RepoAiSummary.ps1'
Check 'repositories with an AI trace (10% (200/1906))' "repo-ai-$ex.md" 'Repositories with an AI trace: (\d+% \(\d+/\d+\))' '10% (200/1906)' 'Get-RepoAiSummary.ps1'
Check 'traces among declaring mods (45% (80/178))' "repo-ai-$ex.md" '^\| declared \| 178 \| (\d+% \(\d+/\d+\)) \|' '45% (80/178)' 'Get-RepoAiSummary.ps1'
Check 'mods created in 2026 with a repository: traces (19%, 169 of 871)' "hidden-ai-estimate-$ex.md" 'with a trace \(any date\): \*\*([\d.]+)% \((\d+/\d+)\)\*\*' '19.4|169/871' 'Get-HiddenAiEstimate.ps1'
Check 'hidden AI among non-declared repo mods before the release (2.0% (16/809))' "hidden-ai-estimate-$ex.md" 'before 2026-04-21: \*\*([\d.]+)% \((\d+/\d+)\)\*\*' '2.0|16/809' 'Get-HiddenAiEstimate.ps1'
Check 'tipping point h for AI-early vs rest (a = 0, 0.30: 6.1%, 13.2%)' "hidden-ai-estimate-$ex.md" '^\| AI-early: 55\.6% \(25/45\) \| [^|]*\| ([\d.]+)% \| ([\d.]+)% \|' '6.1|13.2' 'Get-HiddenAiEstimate.ps1'
Check 'tipping point h for all declarers (a = 0, 0.30: 27.8%, 48.0%)' "hidden-ai-estimate-$ex.md" '^\| all declared \(undated\): 71\.4% \(70/98\) \| [^|]*\| ([\d.]+)% \| ([\d.]+)% \|' '27.8|48.0' 'Get-HiddenAiEstimate.ps1'
if ($ovrCopy) {
    Check 'labels re-merged with the overrides: AI-declared mods (549)' "ai-labels-$ex.md" 'AI declared \(any USED hit\): (\d+)' '549' 'Merge-AiLabels.ps1'
} else { Write-Host 'SKIP  labels re-merge (no -OverridesFile); labels were taken from the extract'; $script:skip++ }
if ($haveAudience) {
    Check 'Twitch hours streamed, 2025Q1 (thousand) (18.2)' 'youtube-rate.md' '^\| 2025Q1 \| [\d.]+ \| \d+ \| ([\d.]+) \|' '18.2' 'Get-YouTubeRate.ps1'
    Check 'Twitch hours streamed, 2024Q4 (thousand) (5.4; ratio x3.37)' 'youtube-rate.md' '^\| 2024Q4 \| [\d.]+ \| \d+ \| ([\d.]+) \|' '5.4' 'Get-YouTubeRate.ps1'
} else { Write-Host 'SKIP  Twitch quarters (no audience data)'; $script:skip++ }
if ($CacheDir) {
    Check 'downloads of 34 popular mods, all releases: 1.19 and 1.20 (thousand) (746 -> 1,800, x2.4)' 'release-download-share.md' '^\| 1\.19 \| ([\d,]+) \| \d+ \| \d+ \| \d+ \|\n\| 1\.20 \| ([\d,]+) \|' '746|1,800' 'Get-ReleaseDownloadShare.ps1'
} else { Write-Host 'SKIP  release downloads of 34 mods (no -CacheDir)'; $script:skip++ }

# ---- informational: regenerated vs published files ----
Write-Host ''
Write-Host 'Regenerated results vs published results (information only; some published files carry text edits):'
foreach ($f in (Get-ChildItem $wResults -Filter '*.md' | Sort-Object Name)) {
    $pub = Join-Path $root ('results\' + $f.Name)
    if (-not (Test-Path $pub)) { Write-Host ("  {0,-55} (no published counterpart)" -f $f.Name); continue }
    $a = ([IO.File]::ReadAllText($f.FullName).TrimStart([char]0xFEFF) -replace "`r`n", "`n").TrimEnd()
    $b = ([IO.File]::ReadAllText($pub).TrimStart([char]0xFEFF) -replace "`r`n", "`n").TrimEnd()
    Write-Host ("  {0,-55} {1}" -f $f.Name, $(if ($a -eq $b) { 'identical' } else { 'differs' }))
}

[void][W.K]::SetThreadExecutionState([uint32]2147483648)  # ES_CONTINUOUS: clear the block
Write-Host ''
Write-Host ("Summary: {0} PASS, {1} FAIL, {2} SKIP; {3} script(s) failed; {4} min" -f $script:pass, $script:fail, $script:skip, $failedScripts.Count, [math]::Round(((Get-Date) - $started).TotalMinutes, 1))
if ($failedScripts.Count) { $failedScripts.Keys | ForEach-Object { Write-Host ("  failed: {0}: {1}" -f $_, $failedScripts[$_]) } }
if (-not $KeepWork) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue } else { Write-Host "work folder kept: $WorkDir" }
if ($script:fail -gt 0 -or $failedScripts.Count -gt 0) { exit 1 }
exit 0
