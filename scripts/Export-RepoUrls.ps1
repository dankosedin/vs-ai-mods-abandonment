<#
.SYNOPSIS
  Stage 3, step 1: source repository links of the mods in an extract (repo-urls.csv in the extract folder).

.DESCRIPTION
  Reads sourcecodeurl, and homepageurl when sourcecodeurl gives no repository, from the shared ModDB cache for every mod
  of the extract. The extract has no URL columns, so this freezes them next to it.

  Supported hosts (a repository is <owner>/<repo>, the first two path segments):
    github.com, codeberg.org, git.gay, any host whose name starts with "git." or "gitea." or "forgejo." (Gitea/Forgejo),
    gitlab.com (nested groups: the path up to "/-/" or to the end), git.sr.ht (~user/repo).
  Anything else is written with status "unsupported" and no clone URL.

  Output data\<extract>\repo-urls.csv:
    modid, field (sourcecodeurl|homepageurl), url, status (ok|unsupported|norepo), host, repoKey, cloneUrl, subpath
  repoKey = <host>/<owner>/<repo>, lower case; several mods may share one repository (monorepos).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Export-RepoUrls.ps1 -Extract extract-2026-11-02-all
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$CacheDir,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $DataDir) { $DataDir = Join-Path $here '..\data\private' }
if (-not $CacheDir) { $CacheDir = Join-Path $DataDir 'moddb-cache' }
$dir = Join-Path $DataDir $Extract
function Csv([object]$v) { '"' + ([string]$v).Replace('"', '""') + '"' }

function Parse-RepoUrl([string]$u) {
    $u = $u.Trim()
    if ($u -match '^git@([^:]+):(.+)$') { $u = "https://$($Matches[1])/$($Matches[2])" }
    $u = $u -replace '^ssh://(git@)?', 'https://'
    $m = [regex]::Match($u, '^(?i)https?://(?:www\.)?([^/:?#]+)(?::\d+)?(/[^?#]*)?')
    if (-not $m.Success) { return $null }
    $hostName = $m.Groups[1].Value.ToLowerInvariant()
    $path = $m.Groups[2].Value.Trim('/')
    $segs = @($path.Split('/') | Where-Object { $_ -ne '' })
    $repoSegs = $null; $rest = @()
    if ($hostName -eq 'gitlab.com') {
        $cut = [Array]::IndexOf($segs, '-')
        if ($cut -lt 0) { $repoSegs = $segs } else { $repoSegs = $segs[0..($cut - 1)]; $rest = $segs[($cut + 1)..($segs.Count - 1)] }
        if ($repoSegs.Count -lt 2) { return @{ status = 'norepo'; host = $hostName } }
    } elseif ($hostName -eq 'github.com' -or $hostName -eq 'codeberg.org' -or $hostName -eq 'git.gay' -or
              $hostName -match '^(git|gitea|forgejo)\.' ) {
        if ($segs.Count -lt 2) { return @{ status = 'norepo'; host = $hostName } }
        $repoSegs = $segs[0..1]
        if ($segs.Count -gt 2) { $rest = $segs[2..($segs.Count - 1)] }
        if ($hostName -eq 'github.com' -and $repoSegs[0] -match '^(orgs|users|sponsors|settings|topics|search|marketplace)$') {
            return @{ status = 'norepo'; host = $hostName }
        }
    } else {
        return @{ status = 'unsupported'; host = $hostName }
    }
    $repoSegs = @($repoSegs)
    $repoSegs[$repoSegs.Count - 1] = $repoSegs[$repoSegs.Count - 1] -replace '\.git$', ''
    $repoPath = ($repoSegs -join '/')
    # subpath: what follows tree/<branch>/ or blob/<branch>/ (branch names with '/' are not resolved)
    $sub = ''
    if ($rest.Count -ge 3 -and $rest[0] -match '^(tree|blob|src)$') { $sub = ($rest[2..($rest.Count - 1)] -join '/') }
    return @{
        status = 'ok'; host = $hostName; repoKey = ("$hostName/$repoPath").ToLowerInvariant()
        cloneUrl = "https://$hostName/$repoPath.git"; subpath = $sub
    }
}

$mods = Import-Csv (Join-Path $dir 'mods.csv')
$lines = New-Object Collections.Generic.List[string]
$lines.Add('modid,field,url,status,host,repoKey,cloneUrl,subpath')
$n = @{ ok = 0; unsupported = 0; norepo = 0; none = 0 }
foreach ($mod in $mods) {
    $file = Join-Path $CacheDir "mods\$($mod.modid).json"
    $m = ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json).mod
    $chosen = $null
    foreach ($field in 'sourcecodeurl', 'homepageurl') {
        $u = [string]$m.$field
        if (-not $u) { continue }
        $p = Parse-RepoUrl $u
        if (-not $p) { continue }
        if ($field -eq 'homepageurl' -and $p.status -ne 'ok') { continue }   # homepage only counts when it is a repository
        if (-not $chosen -or ($chosen.p.status -ne 'ok' -and $p.status -eq 'ok')) { $chosen = @{ field = $field; url = $u; p = $p } }
        if ($chosen.p.status -eq 'ok') { break }
    }
    if (-not $chosen) { $n.none++; continue }
    $p = $chosen.p; $n[$p.status]++
    $lines.Add((@($mod.modid, $chosen.field, $chosen.url, $p.status, $p.host, $p.repoKey, $p.cloneUrl, $p.subpath) | ForEach-Object { Csv $_ }) -join ',')
}
[IO.File]::WriteAllLines((Join-Path $dir 'repo-urls.csv'), $lines, (New-Object Text.UTF8Encoding $false))
$keys = @(Import-Csv (Join-Path $dir 'repo-urls.csv') | Where-Object status -eq 'ok' | Select-Object -ExpandProperty repoKey -Unique)
"mods: $($mods.Count); with repo link: $($n.ok); unsupported host: $($n.unsupported); host but no repo path: $($n.norepo); no link: $($n.none)"
"unique repositories: $($keys.Count)"
