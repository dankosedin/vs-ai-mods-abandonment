<#
YouTube audience proxy, depth-corrected. The search returns the newest N videos of a month (order=date) and stops at a
depth that does not depend on the month, so the raw count is a cap artifact. Here: per month take the videos with the
game name in the title, the covered span (newest publishedAt .. oldest publishedAt, min 1 day) and the rate = videos per
day over that span; channels per day likewise. Quarterly: mean of monthly rates, joined with Twitch hours streamed.
Output: results\youtube-rate.md (+ csv).
Twitch input: audience\twitch\sullygnome-monthly.csv (columns month, hours_streamed, avg_channels), read by hand from one public Twitch
statistics page (the site asks not to scrape); the monthly values are not published, only the quarterly means in the output.
#>
param([string]$DataDir)
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$root = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $root 'data\private' }
$yt = Join-Path $DataDir 'audience\youtube'
$rows = foreach ($f in Get-ChildItem $yt -Filter '20??-??.json' | Sort-Object Name) {
    $tag = $f.BaseName
    $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $items = @($j.pages | ForEach-Object { $_.items }) | Where-Object { $_.snippet.title -match 'vintage\s*story' }
    $dates = @($items | ForEach-Object { [datetime]::Parse($_.snippet.publishedAt).ToUniversalTime() })
    $monthStart = [datetime]::ParseExact($tag,'yyyy-MM',$null)
    $monthEnd = $monthStart.AddMonths(1)
    if ($dates.Count -eq 0) { continue }
    $newest = ($dates | Measure-Object -Maximum).Maximum; $oldest = ($dates | Measure-Object -Minimum).Minimum
    # complete month = oldest within first 2 days of the month; else the search was cut off
    $complete = ($oldest - $monthStart).TotalDays -lt 2
    $span = [math]::Max(1, ($newest - $oldest).TotalDays)
    if ($complete) { $span = ($monthEnd - $monthStart).TotalDays }
    $ch = @($items | ForEach-Object { $_.snippet.channelId } | Select-Object -Unique).Count
    [pscustomobject]@{ month=$tag; videos=$dates.Count; channels=$ch; spanDays=[math]::Round($span,1); complete=$complete
        perDay=[math]::Round($dates.Count/$span,2); chPerDay=[math]::Round($ch/$span,2) }
}
$rows | Export-Csv (Join-Path $root 'results\youtube-rate.csv') -NoTypeInformation -Encoding UTF8
$tw = Import-Csv (Join-Path $DataDir 'audience\twitch\sullygnome-monthly.csv')
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('| quarter | YouTube videos/day | complete months of 3 | Twitch hours streamed (thousand) | Twitch channels |')
[void]$sb.AppendLine('|---|---|---|---|---|')
$rows | Group-Object { $y=$_.month.Substring(0,4); $q=[math]::Ceiling([int]$_.month.Substring(5,2)/3); "$y`Q$q" } | ForEach-Object {
    $q = $_.Name; $m = $_.Group.month
    $t = $tw | Where-Object { $m -contains $_.month }
    $pd = ($_.Group | Measure-Object perDay -Average).Average
    $hs = ($t | Measure-Object hours_streamed -Average).Average/1000
    $ac = ($t | Measure-Object avg_channels -Average).Average
    [void]$sb.AppendLine(('| {0} | {1:N2} | {2} | {3:N1} | {4:N1} |' -f $q,$pd,@($_.Group|Where-Object complete).Count,$hs,$ac))
}
$out = Join-Path $root 'results\youtube-rate.md'
$sb.ToString() | Set-Content $out -Encoding UTF8
$sb.ToString()
"complete months: " + @($rows|Where-Object complete).Count + " of " + $rows.Count
