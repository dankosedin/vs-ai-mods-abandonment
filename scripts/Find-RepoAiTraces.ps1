<#
.SYNOPSIS
  Stage 3, step 3: AI traces in the mods' source repositories, with the date each trace first appeared.

.DESCRIPTION
  Reads data\<extract>\repo-urls.csv and the repository cache (<DataDir>\moddb-cache\repos, filled by
  Update-RepoCache.ps1). File contents are never read: only paths, commit metadata, trailers and refs.

  Signals (a repository has an AI trace if any of them is present; date = earliest commit date of that signal):
    file     a path, on any branch and at any time, that belongs to an AI coding tool:
             files CLAUDE.md, CLAUDE.local.md, AGENTS.md, AGENT.md, GEMINI.md, .cursorrules, .windsurfrules, .clinerules,
             copilot-instructions.md, .mcp.json, .aider*, .cursorignore, .codeiumignore, .github/instructions/*.instructions.md,
             .github/prompts/*.prompt.md; or a path inside a folder .claude, .cursor, .windsurf, .gemini, .codex, .roo,
             .kiro, .junie, .clinerules, .specstory, .continue, .serena, .aider*, .github/agents
    trailer  a Co-authored-by trailer naming an AI tool (anthropic.com, Claude, Copilot, Cursor, OpenAI, Codex, Gemini,
             Jules, Devin, Aider, Windsurf, Codeium, ChatGPT)
    message  a commit body line like "Generated with [Claude Code]" or "Generated with/by Copilot|Cursor|ChatGPT|Codex|AI"
    author   the commit author or committer is an AI agent account (by e-mail: noreply@anthropic.com, Copilot's GitHub
             account, cursoragent@cursor.com, Jules, Devin, OpenHands, Codex)
    branch   a branch named claude/..., copilot/..., codex/..., cursor/..., jules/..., devin/...
  A branch has no commit date of its own; its date is the date of its tip commit's creation (creatordate).

  Output:
    data\<extract>\stage3\repo-ai.csv   per repository: repoKey, status, archived, fork, ghCreated, ghPushed, commits,
                                        firstCommit, lastCommit, aiTrace, signals, firstAiDate, firstAiSignal, evidence
    data\<extract>\stage3\mod-repo-ai.csv  per mod with a repository link: modid, repoKey, subpath, sharedBy (mods using
                                        the same repository), plus the repository columns
  Only repositories present in the cache are reported; the rest are counted as "not scanned".

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Find-RepoAiTraces.ps1 -Extract extract-2026-11-02-all
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [int]$Sample = 0,   # >0: only the first N repositories of stage3\order.txt (the scan order), a uniform sample

    [string]$CacheDir,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $DataDir) { $DataDir = Join-Path $here '..\data\private' }
if (-not $CacheDir) { $CacheDir = Join-Path $DataDir 'moddb-cache' }
$dir = Join-Path $DataDir $Extract
$outDir = Join-Path $dir 'stage3'
New-Item -ItemType Directory -Force $outDir | Out-Null
$Utf8 = New-Object Text.UTF8Encoding $false
function Csv([object]$v) { '"' + ([string]$v).Replace('"', '""') + '"' }
function Read-Tsv([string]$path) {
    if (-not (Test-Path $path)) { return @() }
    $lines = [IO.File]::ReadAllLines($path, $Utf8)
    if ($lines.Count -lt 2) { return @() }
    $h = $lines[0].Split("`t")
    $rows = New-Object Collections.Generic.List[object]
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i]) { continue }
        $f = $lines[$i].Split("`t"); $o = @{}
        for ($j = 0; $j -lt $h.Count; $j++) { $o[$h[$j]] = if ($j -lt $f.Count) { $f[$j] } else { '' } }
        $rows.Add($o)
    }
    return $rows
}

$FileRx = '(?i)(^|/)(claude\.md|claude\.local\.md|agents\.md|agent\.md|gemini\.md|\.cursorrules|\.windsurfrules|\.clinerules|copilot-instructions\.md|\.mcp\.json|\.aider[^/]*|\.cursorignore|\.codeiumignore)$' +
          '|(?i)(^|/)\.github/(instructions/[^/]+\.instructions\.md|prompts/[^/]+\.prompt\.md|agents/)' +
          '|(?i)(^|/)(\.claude|\.cursor|\.windsurf|\.gemini|\.codex|\.roo|\.kiro|\.junie|\.clinerules|\.specstory|\.continue|\.serena|\.aider[^/]*)/'
$TrailerRx = '(?i)co-authored-by:[^|]*(anthropic\.com|\bclaude\b|copilot|cursor|openai|codex|gemini|jules|devin|aider|windsurf|codeium|chatgpt)'
$MessageRx = '(?i)generated (with|by|using) \[?(claude|copilot|cursor|chatgpt|codex|gemini|ai\b)|claude\.com/claude-code|claude\.ai/code'
$AuthorRx = '(?i)noreply@anthropic\.com|\+copilot@users\.noreply\.github\.com|copilot-swe-agent|cursoragent@cursor\.com|google-labs-jules|devin-ai-integration|openhands|codex@openai|chatgpt-codex-connector'
$BranchRx = '^refs/heads/(claude|copilot|codex|cursor|jules|devin)/'

function Utc([string]$d) { if (-not $d) { return $null }; return [DateTimeOffset]::Parse($d).UtcDateTime }

$urls = Import-Csv (Join-Path $dir 'repo-urls.csv') | Where-Object status -eq 'ok'
if ($Sample -gt 0) {
    $keep = @{}; Get-Content (Join-Path $outDir 'order.txt') | Select-Object -First $Sample | ForEach-Object { $keep[$_] = 1 }
    $urls = @($urls | Where-Object { $keep.ContainsKey($_.repoKey) })
}
$byKey = @{}
foreach ($u in $urls) { if (-not $byKey[$u.repoKey]) { $byKey[$u.repoKey] = New-Object Collections.Generic.List[object] }; $byKey[$u.repoKey].Add($u) }

$repoRows = @{}
$notScanned = 0
foreach ($key in $byKey.Keys) {
    $rd = Join-Path $CacheDir ('repos\' + ($key -replace '/', '\'))
    $mp = Join-Path $rd 'meta.json'
    if (-not (Test-Path $mp)) { $notScanned++; continue }
    $meta = [IO.File]::ReadAllText($mp, $Utf8) | ConvertFrom-Json
    $r = [ordered]@{ repoKey = $key; status = $meta.status; archived = ''; fork = ''; ghCreated = ''; ghPushed = ''; commits = $meta.commits
        firstCommit = ''; lastCommit = ''; aiTrace = ''; signals = ''; firstAiDate = ''; firstAiSignal = ''; evidence = '' }
    if ($meta.github) { $r.archived = $meta.github.archived; $r.fork = $meta.github.fork; $r.ghCreated = $meta.github.created_at; $r.ghPushed = $meta.github.pushed_at }
    if ($meta.status -eq 'ok') {
        $hits = New-Object Collections.Generic.List[object]   # @{ type; date; ev }
        $commits = Read-Tsv (Join-Path $rd 'commits.tsv')
        $dates = @($commits | ForEach-Object { Utc $_.commitDate } | Sort-Object)
        if ($dates.Count) { $r.firstCommit = $dates[0].ToString('yyyy-MM-dd'); $r.lastCommit = $dates[-1].ToString('yyyy-MM-dd') }
        foreach ($c in $commits) {
            $d = Utc $c.commitDate
            if ($c.trailers -match $TrailerRx) { $hits.Add(@{ type = 'trailer'; date = $d; ev = $Matches[0] }) }
            if ($c.markers -match $MessageRx) { $hits.Add(@{ type = 'message'; date = $d; ev = $Matches[0] }) }
            $who = "$($c.authorEmail) $($c.committerEmail)"
            if ($who -match $AuthorRx) { $hits.Add(@{ type = 'author'; date = $d; ev = $Matches[0] }) }
        }
        foreach ($p in (Read-Tsv (Join-Path $rd 'paths.tsv'))) {
            if ($p.path -match $FileRx) { $hits.Add(@{ type = 'file'; date = (Utc $p.firstCommitDate); ev = $p.path }) }
        }
        foreach ($b in (Read-Tsv (Join-Path $rd 'refs.tsv'))) {
            if ($b.refname -match $BranchRx) { $hits.Add(@{ type = 'branch'; date = (Utc $b.date); ev = $b.refname }) }
        }
        if ($hits.Count) {
            $r.aiTrace = 'yes'
            $r.signals = (@($hits | ForEach-Object { $_.type } | Sort-Object -Unique) -join ';')
            $first = $hits | Sort-Object { $_.date } | Select-Object -First 1
            $r.firstAiDate = $first.date.ToString('yyyy-MM-dd'); $r.firstAiSignal = $first.type
            $r.evidence = (@($hits | Group-Object { $_.type } | ForEach-Object {
                $ev = @($_.Group | ForEach-Object { $_.ev } | Sort-Object -Unique | Select-Object -First 3) -join ', '
                "$($_.Name): $ev" }) -join ' / ')
            if ($r.evidence.Length -gt 300) { $r.evidence = $r.evidence.Substring(0, 300) }
        } else { $r.aiTrace = 'no' }
    }
    $repoRows[$key] = $r
}

$cols = 'repoKey', 'status', 'archived', 'fork', 'ghCreated', 'ghPushed', 'commits', 'firstCommit', 'lastCommit', 'aiTrace', 'signals', 'firstAiDate', 'firstAiSignal', 'evidence'
$lines = New-Object Collections.Generic.List[string]
$lines.Add($cols -join ',')
foreach ($k in ($repoRows.Keys | Sort-Object)) { $r = $repoRows[$k]; $lines.Add((@($cols | ForEach-Object { Csv $r[$_] }) -join ',')) }
[IO.File]::WriteAllLines((Join-Path $outDir 'repo-ai.csv'), $lines, $Utf8)

$mcols = @('modid', 'subpath', 'sharedBy') + $cols
$ml = New-Object Collections.Generic.List[string]
$ml.Add($mcols -join ',')
foreach ($u in $urls) {
    $r = $repoRows[$u.repoKey]
    if (-not $r) { continue }
    $vals = @($u.modid, $u.subpath, $byKey[$u.repoKey].Count) + @($cols | ForEach-Object { $r[$_] })
    $ml.Add((@($vals | ForEach-Object { Csv $_ }) -join ','))
}
[IO.File]::WriteAllLines((Join-Path $outDir 'mod-repo-ai.csv'), $ml, $Utf8)

$st = $repoRows.Values | Group-Object { $_.status }
"repositories: $($byKey.Count); scanned: $($repoRows.Count); not scanned: $notScanned"
"status: " + (($st | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
"AI trace: $(@($repoRows.Values | Where-Object { $_.aiTrace -eq 'yes' }).Count) of $(@($repoRows.Values | Where-Object { $_.status -eq 'ok' }).Count) ok"
