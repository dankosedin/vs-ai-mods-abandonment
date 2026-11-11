<#
Stage 4b: was the AI declaration in the mod description already there before the reference point?

For each AI-labelled mod of a cohort (USED label from the description text), asks the Wayback Machine CDX API for
snapshots of the mod page (/show/mod/<assetid> and /<urlalias>), takes the latest snapshot before -RefDate, fetches
the raw archived page and checks whether the declaration (the labelled evidence quote, or its matched keywords) is
in it. Also notes the earliest snapshot after -RefDate as a fallback reference.

Politeness: strictly sequential, -DelayMs between requests, back-off on 429/5xx, stop on repeated failures.
Blocks idle sleep while running (system only).

Output: <extract>\stage4b\wayback-<tag>.csv and a log.
#>
param(
    [string]$DataDir,
    [string]$CacheDir,
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$Cohort = '1.22',
    [string]$RefDate = '2026-04-21',
    [int]$MinDownloads = 50,
    [int]$Sample = 10,
    [int]$Skip = 0,
    [int]$DelayMs = 4000,
    [string]$Seed = '42',
    [string]$Tag = '',
    # A declaration written within GraceDays of the mod's creation counts as early (filling in the description,
    # not a reaction to the update). The snapshot cut is max(RefDate, created + GraceDays).
    [int]$GraceDays = 14,
    # 'ai' (default, stage 4b): AI mods with a USED label from text. 'noai' (stage 5): mods with a NOT_USED label
    # from text/summary and no USED label (the 'evidence'/'keywords' are then the no-AI statement).
    [ValidateSet('ai','noai')][string]$Population = 'ai'
)
# status: early   = declaration found on the last snapshot before the cut
#         late    = not found there, and that snapshot is at least GraceDays after creation
#         undetermined = not found, but the only snapshots before the cut are within GraceDays of creation
#         nosnapshot   = no snapshot before the cut
# For non-early mods the latest snapshot overall is also checked (laterTs/laterFound): the declaration must be
# visible in archived pages at all, otherwise "late" may be a page-format problem.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $root 'data\private' }
$ex = Join-Path $DataDir $Extract
if (-not $CacheDir) { $CacheDir = Join-Path $DataDir 'moddb-cache' }
$cache = Join-Path $CacheDir 'mods'
$out = Join-Path $ex 'stage4b'
New-Item -ItemType Directory -Force $out | Out-Null
if (-not $Tag) { $Tag = "s$Skip-n$Sample" }
$csvPath = Join-Path $out "wayback-$Tag.csv"
$logPath = Join-Path $out ("wayback-$Tag-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
function Log($m) { $l = (Get-Date -Format 'HH:mm:ss') + ' ' + $m; Add-Content -Path $logPath -Value $l -Encoding UTF8; Write-Host $l }

# --- keep the machine awake ---
Add-Type -Namespace W -Name K -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
$prev = [W.K]::SetThreadExecutionState([uint32]2147483649)  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
Log ("sleep block: " + $(if ($prev -ne 0) { 'ok' } else { 'FAILED' }))

try {
    # --- population: AI mods of the cohort whose USED label comes from the description text ---
    $ai = @{}; Import-Csv (Join-Path $ex 'ai-mods.csv') | Where-Object { $_.used -eq 'True' -and $_.usedSources -match 'text' } | ForEach-Object { $ai[$_.modid] = $_ }
    $wantLabel = 'USED'
    if ($Population -eq 'noai') {
        $wantLabel = 'NOT_USED'; $ai = @{}; $usedAny = @{}
        Import-Csv (Join-Path $ex 'ai-labels.csv') -Encoding UTF8 | Where-Object { $_.label -eq 'USED' } | ForEach-Object { $usedAny[$_.modid] = 1 }
        Import-Csv (Join-Path $ex 'ai-labels.csv') -Encoding UTF8 | Where-Object { $_.label -eq 'NOT_USED' -and $_.source -match 'text|summary' -and -not $usedAny.ContainsKey($_.modid) } | ForEach-Object { $ai[$_.modid] = $_ }
    }
    $labels = @{}
    Import-Csv (Join-Path $ex 'ai-labels.csv') | Where-Object { $_.label -eq $wantLabel -and $_.source -match 'text|summary' } | ForEach-Object {
        if (-not $labels.ContainsKey($_.modid)) { $labels[$_.modid] = New-Object System.Collections.ArrayList }
        [void]$labels[$_.modid].Add($_)
    }
    $mods = @(Import-Csv (Join-Path $ex 'cohort-rows.csv') | Where-Object { $_.release -eq $Cohort -and [int]$_.downloads -ge $MinDownloads -and $ai.ContainsKey($_.modid) })
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $ordered = $mods | Sort-Object @{ e = { $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Seed-$($_.modid)")); [BitConverter]::ToString($b, 0, 8) } }, @{ e = { [int]$_.modid } }
    $todo = @($ordered | Select-Object -Skip $Skip -First $Sample)
    Log "population $($mods.Count), this run $($todo.Count) (skip $Skip)"

    $ua = 'vs-mod-research/1.0 (personal non-commercial research)'
    $fails = 0
    function Get-Url($url, [int]$Tries = 5) {
        for ($try = 0; $try -lt $Tries; $try++) {
            Start-Sleep -Milliseconds $script:DelayMs
            try {
                $r = Invoke-WebRequest -Uri $url -UserAgent $ua -UseBasicParsing -TimeoutSec 60
                $script:fails = 0
                return $r.Content
            } catch {
                $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                if ($code -eq 404) { return $null }
                $script:fails++
                $wait = 30 * [math]::Pow(2, $try)
                Log "  error $code on $url : $($_.Exception.Message); wait $wait s"
                if ($script:fails -ge 5) { throw "too many consecutive failures" }
                Start-Sleep -Seconds $wait
            }
        }
        throw "giving up on $url"
    }
    # Only the description tab counts: comments (other people) and the tags line ("AI" tag, id 660, seen on
    # snapshots of 2026, gone from the API by 2026-11-02) would give false keyword hits.
    function Desc($html) {
        $a = $html.IndexOf('class="tab-content description"'); if ($a -lt 0) { return $null }
        $b = $html.IndexOf('class="tab-content files"', $a); if ($b -lt 0) { $b = $html.IndexOf('class="comments"', $a) }
        if ($b -lt 0) { $b = $html.Length }
        return [regex]::Replace($html.Substring($a, $b - $a), '(?s)<dd class="tags">.*?</dd>', ' ')
    }
    function TagAi($html) { return [regex]::IsMatch($html, 'tagids\[\]=\d+"[^>]*>\s*AI\s*</a>') }
    $pages = Join-Path $out 'pages'; New-Item -ItemType Directory -Force $pages | Out-Null
    function Save($modid, $ts, $html) { [IO.File]::WriteAllText((Join-Path $pages "$modid-$ts.html"), $html, [Text.Encoding]::UTF8) }
    function Norm($s) {
        $s = [regex]::Replace($s, '<script[\s\S]*?</script>|<style[\s\S]*?</style>', ' ', 'IgnoreCase')
        $s = [regex]::Replace($s, '<[^>]+>', ' ')
        $s = [System.Net.WebUtility]::HtmlDecode($s)
        return ([regex]::Replace($s, '\s+', ' ')).ToLowerInvariant()
    }

    $ref = [datetime]::ParseExact($RefDate, 'yyyy-MM-dd', $null)
    $refTs = $ref.ToString('yyyyMMdd')
    $results = New-Object System.Collections.ArrayList
    $modErrRun = 0
    foreach ($m in $todo) {
      try {
        $j = (Get-Content -Raw -Encoding UTF8 (Join-Path $cache "$($m.modid).json") | ConvertFrom-Json).mod
        Log "mod $($m.modid) asset $($j.assetid) alias '$($j.urlalias)' created $($j.created)"
        $keys = @("mods.vintagestory.at/show/mod/$($j.assetid)")
        if ($j.urlalias) { $keys += "mods.vintagestory.at/$($j.urlalias)" }
        $snaps = New-Object System.Collections.ArrayList
        $cdxMode = 'prefix'
        foreach ($k in $keys) {
            # 02.11.2026: for some assets the prefix query answers 503 every time while the exact query answers 200.
            # Try prefix twice, then fall back to the exact URL (loses only variants with a query string or subpath).
            $cdxBase = "https://web.archive.org/cdx/search/cdx?url=$([uri]::EscapeDataString($k))&output=json&fl=timestamp,original,statuscode&filter=statuscode:200&collapse=digest"
            $body = $null
            try { $body = Get-Url ($cdxBase + '&matchType=prefix') 2 }
            catch {
                Log "  prefix CDX failed for $k ($($_.Exception.Message)); trying exact"
                $script:fails = 0
                $cdxMode = 'exact'
                $body = Get-Url $cdxBase
            }
            if (-not $body) { continue }
            $arr = $body | ConvertFrom-Json
            $pat = '^https?://(www\.)?' + [regex]::Escape($k) + '($|[/?#])'
            foreach ($row in ($arr | Select-Object -Skip 1)) {
                if ($row[1] -match $pat) { [void]$snaps.Add([pscustomobject]@{ ts = $row[0]; url = $row[1] }) }
            }
        }
        $created = [datetime]::ParseExact($j.created.Substring(0, 10), 'yyyy-MM-dd', $null)
        $graceEnd = $created.AddDays($GraceDays)
        $cut = if ($graceEnd -gt $ref) { $graceEnd } else { $ref }
        $cutTs = $cut.ToString('yyyyMMdd')
        $before = @($snaps | Where-Object { $_.ts.Substring(0, 8) -lt $cutTs } | Sort-Object ts)
        $after = @($snaps | Where-Object { $_.ts.Substring(0, 8) -ge $cutTs } | Sort-Object ts)
        $rec = [ordered]@{
            modid = $m.modid; assetid = $j.assetid; created = $j.created; updatedDay = $m.updatedDay; cut = $cutTs
            snapshots = $snaps.Count; before = $before.Count; after = $after.Count
            lastBefore = ''; firstAfter = ''; fetched = ''; evidenceFound = ''; keywordsFound = ''; keywords = ''
            status = ''; tagAi = ''; laterTs = ''; laterFound = ''; laterTagAi = ''; cdx = $cdxMode
        }
        if ($after.Count) { $rec.firstAfter = $after[0].ts }
        $ev = @(); $kw = @()
        if ($labels.ContainsKey($m.modid)) {
            foreach ($l in $labels[$m.modid]) { if ($l.evidence) { $ev += ($l.evidence -replace '^override:\s*', '').ToLowerInvariant() }; $kw += ($l.matches -split ';' | Where-Object { $_ }) }
        }
        $kw = @($kw | Sort-Object -Unique); $rec.keywords = ($kw -join ';')
        if ($before.Count) {
            $snap = $before[-1]; $rec.lastBefore = $snap.ts
            $page = Get-Url ("https://web.archive.org/web/$($snap.ts)id_/$($snap.url)")
            if ($page) {
                Save $m.modid $snap.ts $page
                $d = Desc $page
                $rec.fetched = if ($d) { 'ok' } else { 'nodesc' }
                $rec.tagAi = TagAi $page
                $t = if ($d) { Norm $d } else { '' }
                $hitEv = @($ev | Where-Object { $t.Contains(([regex]::Replace($_, '\s+', ' '))) })
                $rec.evidenceFound = "$($hitEv.Count)/$($ev.Count)"
                $hitKw = @($kw | Where-Object { $t -match ('\b' + [regex]::Escape($_.ToLowerInvariant()) + '\b') })
                $rec.keywordsFound = ($hitKw -join ';')
            } else { $rec.fetched = 'missing' }
        }
        # early-kw: only keywords matched (the quote was reworded later, or a bare "AI" elsewhere on the page,
        # e.g. in comments): review by hand.
        $evHit = $rec.evidenceFound -and -not $rec.evidenceFound.StartsWith('0/')
        if (-not $before.Count -or $rec.fetched -eq 'missing') { $rec.status = 'nosnapshot' }
        elseif ($rec.fetched -eq 'nodesc') { $rec.status = 'nodesc' }
        elseif ($evHit) { $rec.status = 'early' }
        elseif ($rec.keywordsFound) { $rec.status = 'early-kw' }
        elseif ($rec.tagAi -eq $true) { $rec.status = 'early-tag' }
        elseif ($rec.lastBefore.Substring(0, 8) -ge $graceEnd.ToString('yyyyMMdd')) { $rec.status = 'late' }
        else { $rec.status = 'undetermined' }
        if ($rec.status -ne 'early' -and $after.Count) {
            $last = $after[-1]; $rec.laterTs = $last.ts
            $page = Get-Url ("https://web.archive.org/web/$($last.ts)id_/$($last.url)")
            if ($page) {
                Save $m.modid $last.ts $page
                $rec.laterTagAi = TagAi $page
                $d = Desc $page
                $t = if ($d) { Norm $d } else { '' }
                $hitEv = @($ev | Where-Object { $t.Contains(([regex]::Replace($_, '\s+', ' '))) })
                $hitKw = @($kw | Where-Object { $t -match ('\b' + [regex]::Escape($_.ToLowerInvariant()) + '\b') })
                $rec.laterFound = "ev $($hitEv.Count)/$($ev.Count); kw " + ($hitKw -join ';')
            } else { $rec.laterFound = 'missing' }
        }
        Log ("  $($rec.status): snaps $($rec.snapshots) (before cut $($rec.before), after $($rec.after)); lastBefore $($rec.lastBefore); evidence $($rec.evidenceFound); kw [$($rec.keywordsFound)] of [$($rec.keywords)]; later $($rec.laterTs) [$($rec.laterFound)]")
        [void]$results.Add([pscustomobject]$rec)
        $modErrRun = 0
      } catch {
        # record the mod as error (a later run can retry it) and go on; two such mods in a row = outage, stop
        $modErrRun++
        Log "  error on mod $($m.modid): $($_.Exception.Message)"
        [void]$results.Add([pscustomobject][ordered]@{
            modid = $m.modid; assetid = ''; created = ''; updatedDay = $m.updatedDay; cut = ''
            snapshots = ''; before = ''; after = ''; lastBefore = ''; firstAfter = ''; fetched = ''; evidenceFound = ''
            keywordsFound = ''; keywords = ''; status = 'error'; tagAi = ''; laterTs = ''; laterFound = ''; laterTagAi = ''; cdx = ''
        })
        $script:fails = 0
      }
        $results | Export-Csv -NoTypeInformation -Encoding UTF8 $csvPath
        if ($modErrRun -ge 2) { Log 'two mods in a row failed: stopping'; break }
    }
    Log "done: $csvPath"
} finally {
    [void][W.K]::SetThreadExecutionState([uint32]2147483648)
    Log 'sleep block cleared'
}
