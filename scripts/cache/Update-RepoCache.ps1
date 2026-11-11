<#
.SYNOPSIS
  Builds/extends a shared, resumable cache of mod source repositories: commit metadata, file paths, refs. No file contents.

.DESCRIPTION
  For each repository: GitHub metadata through the authenticated gh CLI (archived, fork, dates; GitHub only), then
  "git clone --bare --filter=blob:none" into a fresh temp folder (commits and trees, no file contents), read with git log /
  ls-tree / for-each-ref, written to the cache, temp clone deleted. Nothing from the clone is ever executed; no checkout.

  Input: a CSV with columns repoKey, cloneUrl (e.g. a study's repo-urls.csv; rows with status other than ok are skipped,
  duplicates collapsed). Order: -KeysFile (one repoKey per line, processed in that order) or else a deterministic shuffle
  (first 8 bytes of SHA-256 of "<seed>-<repoKey>").

  Output <DataDir>\repos\<repoKey>\ (repoKey = host/owner/repo, lower case):
    meta.json    repoKey, cloneUrl, fetchedUtc, status (ok|gone|empty|error), error, github{...}, head, counts, seconds
    commits.tsv  sha, authorDate, commitDate, authorName, authorEmail, committerName, committerEmail, parents,
                 subject, trailers (all, ' | '-joined), markers (body lines that mention generation or AI tools, max 5)
    paths.tsv    path, firstCommitDate, firstSha, inHead (1/0): every path ever added on any branch, earliest commit date
    refs.tsv     refname, sha, date
  Tabs and newlines inside fields are replaced by spaces. Dates are ISO 8601 as git prints them (with offset).

  Refresh: a repo is fetched when it has no meta.json, its status is error, or meta.json is older than -MaxAgeDays.

  Politeness: strictly sequential, -DelayMs between repositories. A clone failing on network/5xx/rate limit counts as
  transient; 5 in a row stop the run (exit 2). The machine is kept from idle sleep while running.
  Exit codes: 0 ok, 1 other error, 2 repeated transient failures.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\cache\Update-RepoCache.ps1 -UrlCsv data\private\extract-2026-11-02-all\repo-urls.csv -Limit 50
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UrlCsv,
    [string]$KeysFile = '',
    [int]$Limit = 200,
    [int]$Seed = 42,
    [int]$MaxAgeDays = 30,
    [int]$DelayMs = 2000,
    [int]$CloneTimeoutSec = 600,
    [string]$DataDir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $DataDir) { $DataDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data\private\moddb-cache' }
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$ReposDir = Join-Path $DataDir 'repos'
$LogDir = Join-Path $DataDir 'logs'
foreach ($p in @($ReposDir, $LogDir)) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
$LogPath = Join-Path $LogDir ('repos-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')
$TmpRoot = Join-Path ([IO.Path]::GetTempPath()) 'vs-repo-scan'

function Write-Log([string]$Msg) {
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Msg
    Write-Host $line
    [IO.File]::AppendAllText($LogPath, $line + "`r`n", $Utf8)
}
function Fmt-Utc([datetime]$D) { $D.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
function Clean([string]$s) { if ($null -eq $s) { return '' }; return ($s -replace "[`t`r`n]+", ' ').Trim() }
function Save-Text([string]$Path, [string]$Text) {
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $Text, $Utf8)
    if (Test-Path $Path) { [IO.File]::Delete($Path) }
    [IO.File]::Move($tmp, $Path)
}

$script:Sha = [Security.Cryptography.SHA256]::Create()
function Get-OrderKey([string]$s) {
    $b = $script:Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
    [uint64]$h = 0
    for ($i = 0; $i -lt 8; $i++) { $h = $h * 256 + $b[$i] }
    return $h
}

# ---- process runner: UTF-8 output, timeout, no prompts ----
function Quote-Arg([string]$a) { if ($a -match '[\s"]') { return '"' + $a.Replace('"', '\"') + '"' }; return $a }
function Run([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec = 120) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $psi.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    $psi.EnvironmentVariables['GIT_ASKPASS'] = ''
    $psi.EnvironmentVariables['SSH_ASKPASS'] = ''
    $psi.EnvironmentVariables['GH_PROMPT_DISABLED'] = '1'
    $psi.EnvironmentVariables['GH_NO_UPDATE_NOTIFIER'] = '1'
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return @{ Code = -1; Out = ''; Err = "timeout after $TimeoutSec s" }
    }
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}
$GitBase = @('-c', 'credential.helper=', '-c', 'core.askPass=', '-c', 'core.quotePath=false', '-c', 'protocol.file.allow=never')
function Git([string]$Dir, [string[]]$ArgList, [int]$TimeoutSec = 300) {
    $a = $GitBase + @('--git-dir', $Dir) + $ArgList
    return Run 'git' $a $TimeoutSec
}

# ---- GitHub metadata ----
function Get-GitHubMeta([string]$Owner, [string]$Repo) {
    $r = Run 'gh' @('api', "repos/$Owner/$Repo", '--jq',
        '{archived:.archived, fork:.fork, created_at:.created_at, pushed_at:.pushed_at, default_branch:.default_branch, size_kb:.size, full_name:.full_name}') 60
    if ($r.Code -eq 0) { return @{ ok = $true; data = ($r.Out | ConvertFrom-Json) } }
    if ($r.Err -match 'HTTP 404|HTTP 451') { return @{ ok = $false; gone = $true; err = (Clean $r.Err) } }
    return @{ ok = $false; gone = $false; err = (Clean $r.Err) }
}

# ---- one repository ----
$MarkerRx = '(?i)(generated|created|written|made|authored|assisted)\s+(with|by|using)|claude|copilot|codex|cursor|chatgpt|openai|anthropic|gemini|\bgpt|\bllm\b|\bai\b|\uD83E\uDD16'
function Scan-Repo($Row) {
    $key = $Row.repoKey
    $outDir = Join-Path $ReposDir ($key -replace '/', '\')
    $meta = [ordered]@{ repoKey = $key; cloneUrl = $Row.cloneUrl; fetchedUtc = (Fmt-Utc (Get-Date)); status = ''; error = ''
        github = $null; head = ''; commits = 0; paths = 0; refs = 0; seconds = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $transient = $false
    $segs = $key.Split('/')
    if ($segs[0] -eq 'github.com') {
        $gm = Get-GitHubMeta $segs[1] $segs[2]
        if ($gm.ok) { $meta.github = $gm.data }
        elseif ($gm.gone) { $meta.status = 'gone'; $meta.error = $gm.err }
        else { $meta.status = 'error'; $meta.error = 'gh: ' + $gm.err; $transient = $true }
    }
    if (-not $meta.status) {
        $tmp = Join-Path $TmpRoot ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $tmp | Out-Null
        $gitDir = Join-Path $tmp 'repo.git'
        try {
            $c = Run 'git' ($GitBase + @('clone', '--bare', '--filter=blob:none', '--quiet', '--no-tags', $Row.cloneUrl, $gitDir)) $CloneTimeoutSec
            if ($c.Code -ne 0) {
                $e = Clean $c.Err
                if ($e -match '(?i)not found|does not exist|could not read Username|Authentication failed|HTTP 40[134]|access denied') { $meta.status = 'gone' }
                else { $meta.status = 'error'; $transient = $true }
                $meta.error = 'clone: ' + $e
            } else {
                $env:GIT_NO_LAZY_FETCH = '1'
                $fmt = '%H%x1f%aI%x1f%cI%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%P%x1f%s%x1f%(trailers:unfold,separator=%x1d)%x1f%b%x1e'
                $lg = Git $gitDir @('log', '--all', '--no-renames', "--format=$fmt")
                if ($lg.Code -ne 0) {
                    if ($lg.Err -match 'does not have any commits|bad default revision|unknown revision') { $meta.status = 'empty' }
                    else { throw "git log: $(Clean $lg.Err)" }
                }
                $cl = New-Object Collections.Generic.List[string]
                $cl.Add("sha`tauthorDate`tcommitDate`tauthorName`tauthorEmail`tcommitterName`tcommitterEmail`tparents`tsubject`ttrailers`tmarkers")
                foreach ($rec in $lg.Out.Split([char]0x1e)) {
                    $rec = $rec.TrimStart("`r", "`n")
                    if (-not $rec) { continue }
                    $f = $rec.Split([char]0x1f)
                    if ($f.Count -lt 11) { continue }
                    $parents = @($f[7].Split(' ') | Where-Object { $_ }).Count
                    $tr = (@($f[9].Split([char]0x1d) | ForEach-Object { Clean $_ } | Where-Object { $_ }) -join ' | ')
                    $mk = (@($f[10].Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match $MarkerRx } |
                        Select-Object -First 5 | ForEach-Object { $s = Clean $_; if ($s.Length -gt 200) { $s.Substring(0, 200) } else { $s } }) -join ' | ')
                    $cl.Add((@($f[0], $f[1], $f[2], (Clean $f[3]), (Clean $f[4]), (Clean $f[5]), (Clean $f[6]), $parents, (Clean $f[8]), $tr, $mk)) -join "`t")
                }
                $meta.commits = $cl.Count - 1
                $first = @{}
                $pl = Git $gitDir @('log', '--all', '--no-renames', '--diff-filter=A', '--name-only', '--format=%x1e%H%x1f%cI')
                if ($pl.Code -ne 0 -and $meta.status -ne 'empty') { throw "git log paths: $(Clean $pl.Err)" }
                foreach ($blk in $pl.Out.Split([char]0x1e)) {
                    $lines = @($blk.Split("`n") | ForEach-Object { $_.TrimEnd("`r") })
                    if (-not $lines[0]) { continue }
                    $h = $lines[0].Split([char]0x1f)
                    $dt = [DateTimeOffset]::Parse($h[1])
                    for ($i = 1; $i -lt $lines.Count; $i++) {
                        $path = $lines[$i]
                        if (-not $path) { continue }
                        $old = $first[$path]
                        if (-not $old -or $dt -lt $old.dt) { $first[$path] = @{ dt = $dt; date = $h[1]; sha = $h[0] } }
                    }
                }
                $inHead = @{}
                if ($meta.status -ne 'empty') {
                    $lt = Git $gitDir @('ls-tree', '-r', '--name-only', 'HEAD')
                    if ($lt.Code -eq 0) { foreach ($l in $lt.Out.Split("`n")) { $l = $l.TrimEnd("`r"); if ($l) { $inHead[$l] = 1 } } }
                    $hd = Git $gitDir @('rev-parse', 'HEAD')
                    if ($hd.Code -eq 0) { $meta.head = $hd.Out.Trim() }
                }
                $ptl = New-Object Collections.Generic.List[string]
                $ptl.Add("path`tfirstCommitDate`tfirstSha`tinHead")
                foreach ($k in ($first.Keys | Sort-Object)) {
                    $v = $first[$k]; $ih = if ($inHead.ContainsKey($k)) { 1 } else { 0 }
                    $ptl.Add("$(Clean $k)`t$($v.date)`t$($v.sha)`t$ih")
                }
                $meta.paths = $ptl.Count - 1
                $rf = Git $gitDir @('for-each-ref', '--format=%(refname)%09%(objectname)%09%(creatordate:iso-strict)')
                $rl = New-Object Collections.Generic.List[string]
                $rl.Add("refname`tsha`tdate")
                foreach ($l in $rf.Out.Split("`n")) { $l = $l.TrimEnd("`r"); if ($l) { $rl.Add($l) } }
                $meta.refs = $rl.Count - 1
                if (-not $meta.status) { $meta.status = 'ok' }
                New-Item -ItemType Directory -Force $outDir | Out-Null
                Save-Text (Join-Path $outDir 'commits.tsv') (($cl -join "`n") + "`n")
                Save-Text (Join-Path $outDir 'paths.tsv') (($ptl -join "`n") + "`n")
                Save-Text (Join-Path $outDir 'refs.tsv') (($rl -join "`n") + "`n")
            }
        } catch {
            $meta.status = 'error'; $meta.error = Clean $_.Exception.Message
        } finally {
            Remove-Item Env:\GIT_NO_LAZY_FETCH -ErrorAction SilentlyContinue
            try { Remove-Item -Recurse -Force $tmp -ErrorAction Stop } catch { Write-Log "  warning: could not delete $tmp" }
        }
    }
    $meta.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    New-Item -ItemType Directory -Force $outDir | Out-Null
    Save-Text (Join-Path $outDir 'meta.json') ((New-Object PSObject -Property $meta) | ConvertTo-Json -Depth 4)
    return @{ meta = $meta; transient = $transient }
}

# ---- main ----
try {
    Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    if ([Win32.Power]::SetThreadExecutionState([uint32]2147483649) -eq 0) { Write-Log 'Warning: could not block idle sleep' }
    else { Write-Log 'Idle sleep blocked for this run' }
} catch { Write-Log ('Warning: could not block idle sleep: ' + $_.Exception.Message) }

$exit = 0
try {
    $rows = @{}
    foreach ($r in (Import-Csv $UrlCsv)) {
        if ($r.PSObject.Properties['status'] -and $r.status -ne 'ok') { continue }
        if ($r.repoKey -and -not $rows.ContainsKey($r.repoKey)) { $rows[$r.repoKey] = $r }
    }
    if ($KeysFile) {
        $order = @(Get-Content $KeysFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $rows.ContainsKey($_) })
    } else {
        $order = @($rows.Keys | ForEach-Object { [pscustomobject]@{ H = (Get-OrderKey "$Seed-$_"); K = $_ } } | Sort-Object H, K | ForEach-Object { $_.K })
    }
    Write-Log "repositories in input: $($rows.Count); in order: $($order.Count); limit $Limit"
    $done = 0; $fresh = 0; $consec = 0; $stats = @{}
    $total = [Diagnostics.Stopwatch]::StartNew()
    foreach ($key in $order) {
        if ($done -ge $Limit) { break }
        $mp = Join-Path (Join-Path $ReposDir ($key -replace '/', '\')) 'meta.json'
        if (Test-Path $mp) {
            $old = [IO.File]::ReadAllText($mp, $Utf8) | ConvertFrom-Json
            if ($old.status -ne 'error' -and ((Get-Date).ToUniversalTime() - [datetime]::Parse($old.fetchedUtc).ToUniversalTime()).TotalDays -lt $MaxAgeDays) { $fresh++; continue }
        }
        if ($done -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        $res = Scan-Repo $rows[$key]
        $done++
        $m = $res.meta
        $stats[$m.status] = 1 + [int]$stats[$m.status]
        $arch = if ($m.github -and $m.github.archived) { ' archived' } else { '' }
        Write-Log ("[$done] $key $($m.status)$arch commits=$($m.commits) paths=$($m.paths) $($m.seconds)s " + $(if ($m.error) { "| $($m.error)" } else { '' }))
        if ($res.transient) { $consec++ } else { $consec = 0 }
        if ($consec -ge 5) { Write-Log 'Stopping: 5 transient failures in a row'; $exit = 2; break }
    }
    Write-Log ("---- Summary: scanned=$done skipped-fresh=$fresh " + (($stats.Keys | Sort-Object | ForEach-Object { "$_=$($stats[$_])" }) -join ' ') +
        " elapsed=" + $total.Elapsed.ToString('hh\:mm\:ss'))
} catch {
    Write-Log ('Fatal: ' + $_.Exception.Message); $exit = 1
} finally {
    try { [void][Win32.Power]::SetThreadExecutionState([uint32]2147483648) } catch { }
}
exit $exit
