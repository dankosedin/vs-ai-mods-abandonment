<#
Audience proxy: YouTube videos about Vintage Story per month (YouTube Data API v3, search.list).

One search per month (100 quota units; the free daily quota is 10000, i.e. ~100 months a day):
q = "vintage story" (exact phrase), type=video, publishedAfter/Before = the month, order=date, maxResults=50.
Recorded per month: pageInfo.totalResults (YouTube's own rough estimate), items on the first page, how many of them
have "vintage story" in the title (precision of the query), distinct channels among those, and an estimate
totalResults * precision. The raw response is cached per month, so reruns cost nothing and the run is resumable
across days: on quotaExceeded it stops cleanly (exit 4) and continues from the next month on the next run.

The API key is read from -KeyFile (default %USERPROFILE%\.secrets\youtube-api-key.txt) and is never written to logs or outputs.
Output: <DataDir>\audience\youtube\<yyyy-MM>.json (raw), youtube-monthly.csv, log.
#>
param(
    [string]$DataDir,
    [string]$From = '2019-01',
    [string]$To = '2026-10',
    [int]$Limit = 200,
    [int]$DelayMs = 1000,
    [string]$Query = '"vintage story"',
    [int]$MaxPages = 10,
    [string]$KeyFile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $root 'data\private' }
$out = Join-Path $DataDir 'audience\youtube'
New-Item -ItemType Directory -Force $out | Out-Null
$logPath = Join-Path $out ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
function Log($m) { $l = (Get-Date -Format 'HH:mm:ss') + ' ' + $m; Add-Content -Path $logPath -Value $l -Encoding UTF8; Write-Host $l }

$keyFile = if ($KeyFile) { $KeyFile } else { Join-Path $env:USERPROFILE '.secrets\youtube-api-key.txt' }
$key = (Get-Content $keyFile -Raw).Trim()

$months = @()
$d = [datetime]::ParseExact($From, 'yyyy-MM', $null); $end = [datetime]::ParseExact($To, 'yyyy-MM', $null)
while ($d -le $end) { $months += $d; $d = $d.AddMonths(1) }

$fetched = 0; $exit = 0
foreach ($m in $months) {
    $tag = $m.ToString('yyyy-MM'); $file = Join-Path $out "$tag.json"
    if (Test-Path $file) { continue }
    if ($fetched -ge $Limit) { Log "limit $Limit reached"; break }
    $after = $m.ToString('yyyy-MM-ddT00:00:00Z'); $before = $m.AddMonths(1).ToString('yyyy-MM-ddT00:00:00Z')
    $base = 'https://www.googleapis.com/youtube/v3/search?part=snippet&type=video&order=date&maxResults=50' +
        '&q=' + [uri]::EscapeDataString($Query) + "&publishedAfter=$after&publishedBefore=$before&key=$key"
    try {
        # Page through until no nextPageToken (search caps around 500 results). All pages of a month are saved
        # together, so a month is either complete in the cache or absent.
        $pages = New-Object System.Collections.ArrayList; $token = $null
        do {
            Start-Sleep -Milliseconds $DelayMs
            $url = $base; if ($token) { $url += "&pageToken=$token" }
            $j = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json
            [void]$pages.Add($j); $token = $j.nextPageToken
        } while ($token -and $pages.Count -lt $MaxPages)
        $json = '{"pages":[' + (($pages | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }) -join ',') + ']}'
        [IO.File]::WriteAllText("$file.tmp", $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -Force "$file.tmp" $file
        $fetched++
        Log "$tag ok, pages $($pages.Count)$(if ($token) { ' (MaxPages hit)' })"
    } catch {
        $body = ''
        if ($_.Exception.Response) { try { $body = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {} }
        if ($body -match 'quotaExceeded|dailyLimitExceeded') { Log "$tag quota exceeded, stopping (rerun tomorrow)"; $exit = 4; break }
        $msg = $_.Exception.Message
        if ($body) { $msg += ' | ' + ($body.Substring(0, [math]::Min(300, $body.Length)) -replace [regex]::Escape($key), '<key>') }
        Log "$tag error: $msg"; $exit = 3; break
    }
}

# Summary over all cached months
$rows = foreach ($m in $months) {
    $tag = $m.ToString('yyyy-MM'); $file = Join-Path $out "$tag.json"
    if (-not (Test-Path $file)) { continue }
    $j = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $j.pages) { continue }   # old single-page format from the first test: refetch
    $items = @($j.pages | ForEach-Object { $_.items } | Where-Object { $_ } | Sort-Object { $_.id.videoId } -Unique)
    $match = @($items | Where-Object { $_.snippet.title -match '(?i)vintage\s*story' })
    [pscustomobject]@{
        month = $tag; pages = @($j.pages).Count; videos = $items.Count; titleMatch = $match.Count
        channels = @($match | ForEach-Object { $_.snippet.channelId } | Sort-Object -Unique).Count
        totalResultsEstimate = $j.pages[0].pageInfo.totalResults
    }
}
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $out 'youtube-monthly.csv')
Log "fetched $fetched this run; months cached $(@($rows).Count) of $($months.Count)"
exit $exit
