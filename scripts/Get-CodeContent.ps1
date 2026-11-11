<#
.SYNOPSIS
  Stage 2: code vs content-only mods, and the share updated for each, per cohort and per new-mod window.

.DESCRIPTION
  Inputs: data\<extract>\stage2\release-files.csv (Export-ReleaseFiles.ps1), <DataDir>\moddb-cache\files\<fileid>.json
  (Update-FileCache.ps1), cohort-rows.csv (Get-Cohorts.ps1), releases.csv, mods.csv, ai-mods.csv (Merge-AiLabels.ps1).
  Kind of a row (its release file):
  - code     the zip has an entry ending in .dll or .cs (case-insensitive), or the file itself is .dll or .cs;
  - content  a zip listing without such entries;
  - other    a file that is neither zip, .dll nor .cs, or a .zip whose tail has no zip directory (cache status notzip);
  - missing  no listing (not fetched yet, error, file gone) or no release before the reference point, or the
             release is no longer in the mod cache. Column reason says which.
  Cohorts: downloads >= MinDownloads (as Compare-AiCohorts.ps1); updated = updatedDay <= Horizon (195, as
  Compare-AiCohorts.ps1). New mods: measure (b) of Get-NewMods.ps1 (a release >= 24 h after the first one and within
  H days of it; only mods first published >= H days before the list date), no downloads threshold.
  -Take N: for a staged fetch, only files at positions 1..N of unique-files.csv count (others: missing, reason
  notsampled), so .dll/.cs files classified without a request do not over-weigh a partial sample.
  Intervals: Wilson 95%. AI groups from ai-mods.csv: AI = used; rest = everything else.
  Output: data\<extract>\stage2\code-content.csv (per row) and results\code-content-<extract>.md (aggregates only).
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Get-CodeContent.ps1 -Extract extract-2026-11-02-all
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [int]$MinDownloads = 50,
    [int]$Horizon = 195,
    [int]$NewModHorizon = 90,
    [int]$Take = 0,
    [string]$ListDate = '2026-11-02',
    [string]$CacheDir,
    [string]$Root,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
if (-not $CacheDir) { $CacheDir = Join-Path $DataDir 'moddb-cache' }
$inv = [Globalization.CultureInfo]::InvariantCulture
function D([string]$s) { [datetime]::ParseExact($s.Trim(), [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd'), $inv, 'None') }
$Utf8 = New-Object Text.UTF8Encoding($false)
$ex = Join-Path $DataDir $Extract
$asOf = D $ListDate

# ---- listings ----
$listing = @{}   # fileid -> @{ status; hasDll; hasCs; zip64; second }
$rf = @(Import-Csv (Join-Path $ex 'stage2\release-files.csv') -Encoding UTF8)
$pos = @{}; Import-Csv (Join-Path $ex 'stage2\unique-files.csv') -Encoding UTF8 | ForEach-Object { $pos[$_.fileid] = [int]$_.order }
foreach ($fid in @($rf | Where-Object { $_.fileid -and $_.ext -eq 'zip' } | Select-Object -ExpandProperty fileid -Unique)) {
    $path = Join-Path $CacheDir "files\$fid.json"
    if (-not (Test-Path $path)) { continue }
    $j = $Utf8.GetString([IO.File]::ReadAllBytes($path)) | ConvertFrom-Json
    $names = @($j.entries | ForEach-Object { [string]$_.name })
    $listing[$fid] = [pscustomobject]@{ status = [string]$j.status
        hasDll = [bool](@($names | Where-Object { $_ -match '(?i)\.dll$' }).Count)
        hasCs = [bool](@($names | Where-Object { $_ -match '(?i)\.cs$' }).Count)
        zip64 = [bool]$j.zip64; second = ([string]$j.note -like 'second range*'); entries = $names.Count; size = $j.totalSize }
}

$rows = foreach ($r in $rf) {
    $kind = 'missing'; $reason = ''; $dll = $false; $cs = $false
    if (-not $r.releaseid) { $reason = 'norelease' }
    elseif (-not $r.fileid) { $reason = 'nofile' }
    elseif ($Take -gt 0 -and $pos[$r.fileid] -gt $Take) { $reason = 'notsampled' }
    elseif ($r.ext -eq 'dll' -or $r.ext -eq 'cs') { $kind = 'code'; $reason = 'byext'; $dll = ($r.ext -eq 'dll'); $cs = ($r.ext -eq 'cs') }
    elseif ($r.ext -ne 'zip') { $kind = 'other'; $reason = 'ext-' + $r.ext }
    else {
        $l = $listing[$r.fileid]
        if (-not $l) { $reason = 'notfetched' }
        elseif ($l.status -eq 'ok') { $dll = $l.hasDll; $cs = $l.hasCs; $kind = $(if ($dll -or $cs) { 'code' } else { 'content' }); $reason = 'listing' }
        elseif ($l.status -eq 'notzip') { $kind = 'other'; $reason = 'notzip' }
        else { $reason = $l.status }
    }
    [pscustomobject]@{ rowKind = $r.rowKind; group = $r.group; modid = $r.modid; fileid = $r.fileid; kind = $kind; reason = $reason; hasDll = $dll; hasCs = $cs }
}
$rows = @($rows)
$rows | Export-Csv (Join-Path $ex 'stage2\code-content.csv') -NoTypeInformation -Encoding UTF8

# ---- joins ----
$cr = @{}; Import-Csv (Join-Path $ex 'cohort-rows.csv') | ForEach-Object { $cr[$_.release + '|' + $_.modid] = $_ }
$ai = @{}; Import-Csv (Join-Path $ex 'ai-mods.csv') | ForEach-Object { if ($_.used -eq 'True') { $ai[$_.modid] = $true } }
$rel = @{}
Import-Csv (Join-Path $ex 'releases.csv') -Encoding UTF8 | ForEach-Object {
    if (-not $rel[$_.modid]) { $rel[$_.modid] = New-Object Collections.Generic.List[datetime] }
    $rel[$_.modid].Add((D $_.created))
}

function Wilson([int]$k, [int]$n) {
    if ($n -eq 0) { return '- (0)' }
    $z = 1.96; $p = $k / $n; $den = 1 + $z * $z / $n
    $c = ($p + $z * $z / (2 * $n)) / $den
    $h = $z * [Math]::Sqrt($p * (1 - $p) / $n + $z * $z / (4 * $n * $n)) / $den
    '{0}% [{1}-{2}] ({3}/{4})' -f [Math]::Round(100 * $p), [Math]::Round(100 * ($c - $h)), [Math]::Round(100 * ($c + $h)), $k, $n
}
function Cnt($set, $pred) { @($set | Where-Object $pred).Count }

$coh = @($rows | Where-Object rowKind -eq 'cohort' | ForEach-Object {
    $c = $cr[$_.group + '|' + $_.modid]
    $_ | Add-Member downloads ([int]$c.downloads) -PassThru | Add-Member upd ($c.updatedDay -ne '' -and [int]$c.updatedDay -le $Horizon) -PassThru |
        Add-Member ai ([bool]$ai[$_.modid]) -PassThru })
$cohorts = @($coh | Select-Object -ExpandProperty group -Unique | Sort-Object { [version]$_ })

$md = New-Object Collections.Generic.List[string]
$md.Add("# Code vs content: $Extract" + $(if ($Take -gt 0) { " (first $Take unique files of the fetch order)" } else { '' }))
$md.Add('')
$md.Add("Code = the release zip has a .dll or .cs entry (or the file is .dll/.cs). Cohort X: the mod's latest release before stable X. " +
    "Downloads >= $MinDownloads; updated = a release tagged X within $Horizon days of stable X. Wilson 95% intervals, [low-high] (k/n). " +
    "Listings from the tail of each zip (HTTP Range); a partial fetch is a uniform random sample of the files.")
$md.Add('')
$md.Add('## Cohorts')
$md.Add('')
$md.Add('| cohort | n | listed (coverage) | other | code share | updated: code | updated: content |')
$md.Add('|---|---|---|---|---|---|---|')
foreach ($x in $cohorts) {
    $s = @($coh | Where-Object { $_.group -eq $x -and $_.downloads -ge $MinDownloads })
    $k = @($s | Where-Object { $_.kind -eq 'code' -or $_.kind -eq 'content' })
    $code = @($k | Where-Object kind -eq 'code'); $cont = @($k | Where-Object kind -eq 'content')
    $md.Add("| $x | $($s.Count) | $($k.Count) ($([Math]::Round(100.0 * $k.Count / [Math]::Max(1, $s.Count)))%) | $(Cnt $s { $_.kind -eq 'other' }) | " +
        "$(Wilson $code.Count $k.Count) | $(Wilson (Cnt $code { $_.upd }) $code.Count) | $(Wilson (Cnt $cont { $_.upd }) $cont.Count) |")
}
$md.Add('')
$md.Add("## Cohorts: code share and updated share by AI declaration (stage 4 labels, AI = used)")
$md.Add('')
$md.Add('| cohort | code share: AI | code share: rest | AI code updated | AI content updated | rest code updated | rest content updated |')
$md.Add('|---|---|---|---|---|---|---|')
foreach ($x in $cohorts) {
    $k = @($coh | Where-Object { $_.group -eq $x -and $_.downloads -ge $MinDownloads -and ($_.kind -eq 'code' -or $_.kind -eq 'content') })
    $a = @($k | Where-Object ai); $b = @($k | Where-Object { -not $_.ai })
    $cells = foreach ($g in @($a, $b)) {
        foreach ($kd in 'code', 'content') { $t = @($g | Where-Object kind -eq $kd); Wilson (Cnt $t { $_.upd }) $t.Count } }
    $md.Add("| $x | $(Wilson (Cnt $a { $_.kind -eq 'code' }) $a.Count) | $(Wilson (Cnt $b { $_.kind -eq 'code' }) $b.Count) | " + ($cells -join ' | ') + ' |')
}
$md.Add('')
$md.Add('## Cohorts without a downloads threshold: code share')
$md.Add('')
$md.Add('| cohort | n | listed | code share |')
$md.Add('|---|---|---|---|')
foreach ($x in $cohorts) {
    $s = @($coh | Where-Object group -eq $x); $k = @($s | Where-Object { $_.kind -eq 'code' -or $_.kind -eq 'content' })
    $md.Add("| $x | $($s.Count) | $($k.Count) | $(Wilson (Cnt $k { $_.kind -eq 'code' }) $k.Count) |")
}

# ---- new mods ----
$nm = @($rows | Where-Object rowKind -eq 'newmod' | ForEach-Object {
    $d = @($rel[$_.modid] | Sort-Object); $first = $d[0]
    $next = $d | Where-Object { ($_ - $first).TotalHours -ge 24 } | Select-Object -First 1
    $_ | Add-Member age (($asOf - $first).TotalDays) -PassThru |
        Add-Member upd ($null -ne $next -and ($next - $first).TotalDays -le $NewModHorizon) -PassThru |
        Add-Member ai ([bool]$ai[$_.modid]) -PassThru })
$md.Add('')
$md.Add("## New mods by window (first release; measure (b) of Get-NewMods.ps1, $NewModHorizon d, no downloads threshold)")
$md.Add('')
$md.Add("| window | n | listed (coverage) | other | code share | code share: AI | updated $NewModHorizon d: code | updated: content |")
$md.Add('|---|---|---|---|---|---|---|---|')
foreach ($w in @($nm | Select-Object -ExpandProperty group -Unique | Sort-Object { [version]$_ })) {
    $s = @($nm | Where-Object group -eq $w)
    $k = @($s | Where-Object { $_.kind -eq 'code' -or $_.kind -eq 'content' })
    $f = @($k | Where-Object { $_.age -ge $NewModHorizon })
    $code = @($f | Where-Object kind -eq 'code'); $cont = @($f | Where-Object kind -eq 'content')
    $a = @($k | Where-Object ai)
    $md.Add("| $w | $($s.Count) | $($k.Count) ($([Math]::Round(100.0 * $k.Count / [Math]::Max(1, $s.Count)))%) | $(Cnt $s { $_.kind -eq 'other' }) | " +
        "$(Wilson (Cnt $k { $_.kind -eq 'code' }) $k.Count) | $(Wilson (Cnt $a { $_.kind -eq 'code' }) $a.Count) | " +
        "$(Wilson (Cnt $code { $_.upd }) $code.Count) | $(Wilson (Cnt $cont { $_.upd }) $cont.Count) |")
}

# ---- diagnostics ----
$ls = @($listing.Values)
$ok = @($ls | Where-Object status -eq 'ok')
$md.Add('')
$md.Add('## Listings (unique files referenced by the rows)')
$md.Add('')
$md.Add("- zip files referenced: $(@($rf | Where-Object { $_.fileid -and $_.ext -eq 'zip' } | Select-Object -ExpandProperty fileid -Unique).Count); listed: $($ls.Count)")
$md.Add('- statuses: ' + (($ls | Group-Object status | Sort-Object Name | ForEach-Object { $_.Name + ' ' + $_.Count }) -join ', '))
$md.Add("- of ok: dll only $(Cnt $ok { $_.hasDll -and -not $_.hasCs }), cs only (source, compiled by the game) $(Cnt $ok { $_.hasCs -and -not $_.hasDll }), " +
    "both $(Cnt $ok { $_.hasDll -and $_.hasCs }), neither $(Cnt $ok { -not $_.hasDll -and -not $_.hasCs })")
$md.Add("- zip64: $(Cnt $ls { $_.zip64 }); needed a second range request: $(Cnt $ls { $_.second }); empty zips: $(Cnt $ok { $_.entries -eq 0 })")
$md.Add('- release files that are not zips (by extension): ' + (($rf | Where-Object { $_.fileid -and $_.ext -ne 'zip' } | Group-Object fileid | ForEach-Object { $_.Group[0].ext } | Group-Object | ForEach-Object { $_.Name + ' ' + $_.Count }) -join ', '))
$md.Add('- rows by reason: ' + (($rows | Group-Object rowKind, reason | Sort-Object Name | ForEach-Object { $_.Name + ' ' + $_.Count }) -join '; '))

New-Item -ItemType Directory -Force (Join-Path $Root 'results') | Out-Null
$out = Join-Path $Root ("results\code-content-$Extract" + $(if ($Take -gt 0) { "-take$Take" } else { '' }) + '.md')
[IO.File]::WriteAllLines($out, $md, $Utf8)
$md | ForEach-Object { Write-Output $_ }
Write-Output "Written to $out"
