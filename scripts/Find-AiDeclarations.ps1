<#
.SYNOPSIS
  Stage 4, first pass: keyword hits that may be AI-use declarations, in mod summaries, descriptions and changelogs.

.DESCRIPTION
  Local only: reads the mods of an extract (data\<extract>\mods.csv) from the cache of API responses and the list summary from the
  list of the extract's date. A hit is a hint, not a verdict: "AI" in mods mostly means mob behaviour. A model judges the
  fragments later (stage 4, second pass).
  Pattern groups:
    tool    names of AI tools and vendors (ChatGPT, Claude, Copilot, LLM, vibe coding, ...)
    phrase  "AI-generated", "made with AI", "with the help of AI", "artificial intelligence" in several languages
    bare    a bare AI / A.I. / KI / IA / Cyrillic and Chinese equivalents (case-sensitive)
  Each fragment also gets mobHint = it mentions entity behaviour words (task, pathfinding, mob, ...), to rank, not to drop.
  Output: data\<extract>\ai-hits.csv (modid, source, releaseid, groups, matches, mobHint, fragment), one row per merged
  fragment; results\ai-hits-<extract>.md with aggregates only.
  Non-ASCII patterns are written as \uXXXX so the script stays ASCII (PowerShell 5.1 reads BOM-less files as ANSI).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Find-AiDeclarations.ps1 -Extract extract-2026-11-02-4190
#>
param(
    [string]$Extract = 'extract-2026-11-02-all',
    [int]$Context = 150,
    [string]$Root,
    [string]$DataDir,
    [string]$CacheDir
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Join-Path $here '..' }
if (-not $DataDir) { $DataDir = Join-Path $Root 'data\private' }
if (-not $CacheDir) { $CacheDir = Join-Path $DataDir 'moddb-cache' }
$inv = [Globalization.CultureInfo]::InvariantCulture

$ci = [Text.RegularExpressions.RegexOptions]::IgnoreCase
$groups = [ordered]@{
    tool   = New-Object regex ('chat-?gpt|openai|\bclaude\b|anthropic|copilot|\bgemini\b|\bcodex\b|deepseek|\bgrok\b|mistral ?ai|' +
        'perplexity|windsurf|\bcline\b|\baider\b|midjourney|stable ?diffusion|dall-?e|\bsuno\b|elevenlabs|cursor (?:ide|ai|agent)|' +
        '\bgpt-?[345o]|\bLLMs?\b|large language model|vibe.?cod|\bqwen\b|kimi k|github spark|lovable'), $ci
    phrase = New-Object regex ('\bA\.?I\.?[- ](?:generated|assisted|made|written|coded|created|tools?|art|images?|textures?|models?|helped|help)|' +
        '(?:generated|made|written|created|coded|assisted|helped|done|built|translated)\s+(?:with|by|using|through|via)\s+(?:the\s+)?(?:help\s+of\s+)?(?:an?\s+)?(?:A\.?I\b|LLM|chat-?gpt|claude|copilot|gemini|codex|cursor)|' +
        'with (?:the )?help of (?:an? )?(?:A\.?I\b|LLM|chat-?gpt|claude|copilot|gemini)|artificial intelligence|machine learning|generative|' +
        'k\u00fcnstliche[nr]? intelligenz|intelig[e\u00ea]ncia artificial|inteligencia artificial|intelligence artificielle|' +
        'intelligenza artificiale|sztuczn\w* inteligencj\w*|\u0438\u0441\u043a\u0443\u0441\u0441\u0442\u0432\u0435\u043d\w* \u0438\u043d\u0442\u0435\u043b\u043b\u0435\u043a\u0442\w*|' +
        '\u0448\u0442\u0443\u0447\u043d\w* \u0456\u043d\u0442\u0435\u043b\u0435\u043a\u0442\w*|\u4eba\u5de5\u667a\u80fd|\u751f\u6210\u5f0f'), $ci
    bare   = New-Object regex '\bA\.?I\b|\bKI\b|\bIA\b|\u0418\u0418|\u0428\u0406|\bAIs\b'
}
$mob = New-Object regex ('task|behaviou?r|pathfind|entity|entities|\bmobs?\b|creature|\bnpcs?\b|hostile|wander|flee|aggro|' +
    'animal|drifter|wolf|wolves|bear|villager|trader|combat|attack|target|spawn'), $ci

function Plain([string]$html) {
    if (-not $html) { return '' }
    $t = $html -replace '(?i)<br\s*/?>|</p>|</li>|</div>|</h\d>', "`n" -replace '<[^>]+>', ' '
    $t = [Net.WebUtility]::HtmlDecode($t)
    ($t -replace '[ \t\u00a0]+', ' ' -replace '\s*\n\s*', "`n").Trim()
}
function Csv([object]$v) { '"' + ([string]$v).Replace('"', '""').Replace("`r", ' ').Replace("`n", ' / ') + '"' }

$exDir = Join-Path $DataDir $Extract
$meta = @{}; Get-Content (Join-Path $exDir 'meta.txt') | ForEach-Object { $k, $v = $_ -split '=', 2; $meta[$k] = $v }
$summary = @{}
foreach ($m in @(([IO.File]::ReadAllText((Join-Path $CacheDir "modlist-$($meta['listDate']).json"), [Text.Encoding]::UTF8) | ConvertFrom-Json).mods)) {
    $summary[[string]$m.modid] = [string]$m.summary
}

$out = New-Object Collections.Generic.List[string]
$out.Add('modid,source,releaseid,groups,matches,mobHint,fragment')
$modsWith = @{}; foreach ($g in $groups.Keys) { $modsWith[$g] = @{} }
$modsMobOnly = @{}
$created = @{}
$nMods = 0; $nFrag = 0

foreach ($row in (Import-Csv (Join-Path $exDir 'mods.csv'))) {
    $id = $row.modid; $nMods++
    $created[$id] = $row.created
    $m = ([IO.File]::ReadAllText((Join-Path $CacheDir "mods\$id.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json).mod
    $sources = New-Object Collections.Generic.List[object]
    $sources.Add(@('summary', '', $summary[$id]))
    $sources.Add(@('text', '', (Plain $m.text)))
    foreach ($r in @($m.releases)) { $sources.Add(@('changelog', [string]$r.releaseid, (Plain $r.changelog))) }

    foreach ($s in $sources) {
        $text = [string]$s[2]; if (-not $text) { continue }
        $hits = New-Object Collections.Generic.List[object]
        foreach ($g in $groups.Keys) {
            foreach ($mt in $groups[$g].Matches($text)) { $hits.Add([pscustomobject]@{ G = $g; I = $mt.Index; L = $mt.Length; V = $mt.Value }) }
        }
        if ($hits.Count -eq 0) { continue }
        # merge overlapping context windows into fragments
        $frags = New-Object Collections.Generic.List[object]
        foreach ($h in ($hits | Sort-Object I)) {
            $a = [Math]::Max(0, $h.I - $Context); $b = [Math]::Min($text.Length, $h.I + $h.L + $Context)
            $last = if ($frags.Count) { $frags[$frags.Count - 1] } else { $null }
            if ($last -and $a -le $last.B) { $last.B = [Math]::Max($last.B, $b); $last.H.Add($h) }
            else { $l = New-Object Collections.Generic.List[object]; $l.Add($h); $frags.Add([pscustomobject]@{ A = $a; B = $b; H = $l }) }
        }
        foreach ($f in $frags) {
            $frag = $text.Substring($f.A, $f.B - $f.A)
            $gs = @($f.H | ForEach-Object G | Sort-Object -Unique)
            $mobHint = $mob.IsMatch($frag)
            foreach ($g in $gs) { $modsWith[$g][$id] = $true }
            $out.Add((@($id, $s[0], $s[1], ($gs -join ';'), (@($f.H | ForEach-Object V | Sort-Object -Unique) -join ';'),
                $mobHint, $frag) | ForEach-Object { Csv $_ }) -join ',')
            $nFrag++
        }
    }
}

$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllLines((Join-Path $exDir 'ai-hits.csv'), $out, $utf8)

# ---- aggregates ----
$strong = @{}; foreach ($k in $modsWith['tool'].Keys + $modsWith['phrase'].Keys) { $strong[$k] = $true }
$any = @{}; foreach ($g in $groups.Keys) { foreach ($k in $modsWith[$g].Keys) { $any[$k] = $true } }
function Pct([int]$k, [int]$n) { if ($n -eq 0) { '-' } else { [string]::Format($inv, '{0:0.0}%', 100.0 * $k / $n) } }

$md = New-Object Collections.Generic.List[string]
$md.Add("# AI keyword hits: $Extract")
$md.Add('')
$md.Add("Hints only, before model review. Mods $nMods, fragments $nFrag. Sources: list summary, description, all changelogs.")
$md.Add('')
$md.Add('| group | mods | share |')
$md.Add('|---|---|---|')
foreach ($g in $groups.Keys) { $md.Add("| $g | $($modsWith[$g].Count) | $(Pct $modsWith[$g].Count $nMods) |") }
$md.Add("| tool or phrase | $($strong.Count) | $(Pct $strong.Count $nMods) |")
$md.Add("| any | $($any.Count) | $(Pct $any.Count $nMods) |")
$md.Add('')
$md.Add('## Mods with a tool or phrase hit, by creation quarter')
$md.Add('')
$md.Add('| quarter | mods | with hit | share |')
$md.Add('|---|---|---|---|')
$created.GetEnumerator() | Group-Object { $d = [datetime]::ParseExact($_.Value, 'yyyy-MM-dd HH:mm:ss', $inv); "$($d.Year)-Q$([Math]::Ceiling($d.Month / 3))" } |
    Sort-Object Name | ForEach-Object {
        $k = @($_.Group | Where-Object { $strong[$_.Key] }).Count
        $md.Add("| $($_.Name) | $($_.Count) | $k | $(Pct $k $_.Count) |")
    }
$outMd = Join-Path $Root "results\ai-hits-$Extract.md"
[IO.File]::WriteAllLines($outMd, $md, $utf8)
$md | ForEach-Object { Write-Output $_ }
Write-Output "Fragments: $(Join-Path $exDir 'ai-hits.csv')"
