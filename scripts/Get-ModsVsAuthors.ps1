<#
Did mods grow faster than authors? Quarterly counts of new mods and of authors who created them, with and without
AI-declared mods (stage 4 USED labels, current texts); hidden AI among mods with a repository (stage 3 traces);
code share of authors' first mods vs their later mods (stage 2 kinds of new mods). Local data only.
Output: results\mods-vs-authors-<extract>.md
#>
param(
    [string]$DataDir,
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$From = '2021Q2'
)
$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$root = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $root 'data\private' }
$ex = Join-Path $DataDir $Extract
function Q([string]$s) { $s.Substring(0, 4) + 'Q' + [math]::Ceiling([int]$s.Substring(5, 2) / 3) }
function Pct($k, $n) { if ($n -eq 0) { '-' } else { '{0:N0}%' -f (100 * $k / $n) } }

$mods = @(Import-Csv (Join-Path $ex 'mods.csv'))
$ai = @{}; Import-Csv (Join-Path $ex 'ai-mods.csv') | Where-Object { $_.used -eq 'True' } | ForEach-Object { $ai[$_.modid] = 1 }
$repo = @{}; Import-Csv (Join-Path $ex 'stage3\mod-repo-ai.csv') | Where-Object { $_.status -eq 'ok' } | ForEach-Object { $repo[$_.modid] = $_.aiTrace }
$kind = @{}; Import-Csv (Join-Path $ex 'stage2\code-content.csv') | Where-Object { $_.rowKind -eq 'newmod' -and ($_.kind -eq 'code' -or $_.kind -eq 'content') } | ForEach-Object { $kind[$_.modid] = $_.kind }

# author's first quarter and order of each mod
$firstQ = @{}; $rank = @{}
foreach ($g in ($mods | Group-Object author)) {
    $i = 0
    foreach ($m in ($g.Group | Sort-Object created, { [int]$_.modid })) { if ($i -eq 0) { $firstQ[$g.Name] = Q $m.created }; $rank[$m.modid] = $i; $i++ }
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Mods vs authors: $Extract")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Quarter of the mod's creation. Creators = distinct authors who created a mod in the quarter; new = their first mod. AI = stage 4 USED label (current texts). The last quarter is partial. ModDB data start 2021-02-14.")
[void]$sb.AppendLine()
[void]$sb.AppendLine('| quarter | mods | creators | mods per creator | new authors | mods by new authors | AI-declared mods | mods w/o AI | creators w/o AI mod | mods per creator w/o AI |')
[void]$sb.AppendLine('|---|---|---|---|---|---|---|---|---|---|')
$byQ = $mods | Group-Object { Q $_.created } | Where-Object { $_.Name -ge $From } | Sort-Object Name
foreach ($q in $byQ) {
    $m = @($q.Group); $cr = @($m | Group-Object author)
    $aiM = @($m | Where-Object { $ai.ContainsKey($_.modid) })
    $noAi = @($m | Where-Object { -not $ai.ContainsKey($_.modid) }); $crNo = @($noAi | Group-Object author)
    $newA = @($cr | Where-Object { $firstQ[$_.Name] -eq $q.Name })
    $byNew = @($m | Where-Object { $firstQ[$_.author] -eq $q.Name })
    [void]$sb.AppendLine(('| {0} | {1} | {2} | {3:N2} | {4} | {5} | {6} ({7}) | {8} | {9} | {10:N2} |' -f $q.Name, $m.Count, $cr.Count, ($m.Count / $cr.Count), $newA.Count, $byNew.Count, $aiM.Count, (Pct $aiM.Count $m.Count), $noAi.Count, $crNo.Count, ($noAi.Count / [math]::Max(1, $crNo.Count))))
}

[void]$sb.AppendLine()
[void]$sb.AppendLine('## Hidden AI: mods with a linked repository (stage 3), AI traces at any date')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| quarter | mods with repo | traces | of them not declared | first mods of new authors with repo | traces |')
[void]$sb.AppendLine('|---|---|---|---|---|---|')
foreach ($q in $byQ) {
    $r = @($q.Group | Where-Object { $repo.ContainsKey($_.modid) }); $t = @($r | Where-Object { $repo[$_.modid] -eq 'yes' })
    $hid = @($t | Where-Object { -not $ai.ContainsKey($_.modid) })
    $f = @($r | Where-Object { $rank[$_.modid] -eq 0 }); $ft = @($f | Where-Object { $repo[$_.modid] -eq 'yes' })
    [void]$sb.AppendLine("| $($q.Name) | $($r.Count) | $($t.Count) ($(Pct $t.Count $r.Count)) | $($hid.Count) | $($f.Count) | $($ft.Count) ($(Pct $ft.Count $f.Count)) |")
}

[void]$sb.AppendLine()
[void]$sb.AppendLine("## Steps: code share of an author's first mod vs later mods (stage 2 kind of the mod's first release)")
[void]$sb.AppendLine()
[void]$sb.AppendLine('| quarter | first mods: code | 2nd-3rd mods: code | 4th+ mods: code |')
[void]$sb.AppendLine('|---|---|---|---|')
foreach ($q in $byQ) {
    $k = @($q.Group | Where-Object { $kind.ContainsKey($_.modid) })
    $cells = foreach ($sel in @({ $rank[$_.modid] -eq 0 }, { $rank[$_.modid] -ge 1 -and $rank[$_.modid] -le 2 }, { $rank[$_.modid] -ge 3 })) {
        $s = @($k | Where-Object $sel); $c = @($s | Where-Object { $kind[$_.modid] -eq 'code' }).Count
        "$(Pct $c $s.Count) ($c/$($s.Count))"
    }
    [void]$sb.AppendLine("| $($q.Name) | $($cells -join ' | ') |")
}
$all = @($mods | Where-Object { $kind.ContainsKey($_.modid) })
$pairs = foreach ($g in ($all | Group-Object author)) {
    $ms = @($g.Group | Sort-Object { $rank[$_.modid] })
    if ($ms.Count -ge 2 -and $rank[$ms[0].modid] -eq 0) { [pscustomobject]@{ First = $kind[$ms[0].modid]; Later = @($ms | Select-Object -Skip 1 | ForEach-Object { $kind[$_.modid] }) } }
}
[void]$sb.AppendLine()
foreach ($fk in 'content', 'code') {
    $p = @($pairs | Where-Object { $_.First -eq $fk }); $later = @($p | ForEach-Object { $_.Later }); $c = @($later | Where-Object { $_ -eq 'code' }).Count
    [void]$sb.AppendLine("- Authors whose first mod is $fk (and who have later mods with a known kind): $($p.Count); their later mods are code in $(Pct $c $later.Count) ($c/$($later.Count)).")
}
$outPath = Join-Path $root "results\mods-vs-authors-$Extract.md"
[IO.File]::WriteAllText($outPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host "Written to $outPath"
