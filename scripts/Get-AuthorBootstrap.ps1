<#
Cluster bootstrap over AUTHORS for the share of mods updated.

Population: cohort-rows.csv rows with release = -Cohort and downloads >= -MinDownloads (as Get-Stage4bCohort.ps1).
Updated: updatedDay not empty and <= -Horizon (195) days (same as Get-Stage4bCohort.ps1).
Groups: stage4b\cohort-groups.csv (written by Get-Stage4bCohort.ps1): AI-early, AI-late, AI-undetermined, noAI-early/late/
  undetermined, rest. Other composite groups are built from these (see the comparison list in the output).
Code / content: stage2\code-content.csv rows (rowKind cohort, group = cohort), kind code / content, as in
  Get-Stage4bCodeContent.ps1 (kind other / missing are left out of those two comparisons).
Author = the author field of cohort-rows.csv. Names never appear in the output.

Estimator: for each comparison (group A against comparison group B), the population is the mods of A and B. Authors of that
  population are resampled with replacement (as many as there are authors), each resampled author brings ALL their mods of
  the population (an author whose mods sit in both groups brings both, so such authors are counted and reported). In each
  resample the share updated is recomputed for A, for B and for the difference A - B. Reported: point estimate, Wilson 95% on
  mods (ignores clustering), bootstrap 2.5 / 97.5 percentile interval, number of authors in the group, design effect
  (bootstrap variance of the share / binomial variance p(1-p)/n_mods), and for the difference the share of resamples with
  A - B > 0. Resamples where a group is empty are skipped for that group (counted). Fixed seed, -Iterations (default 10000).
  The inner loop is compiled C# (Add-Type) because PowerShell 5.1 is too slow for 10000 x thousands of draws.
Reproduction: before the bootstrap each group is compared with the expected mod counts and shares of the stage 4b reports;
  prints REPRODUCED / NOT REPRODUCED.
Output: results\author-bootstrap-<extract>.md. Local data only.
#>
param(
    [string]$DataDir,
    [string]$Extract = 'extract-2026-11-02-all',
    [string]$Cohort = '1.22',
    [int]$MinDownloads = 50,
    [int]$Horizon = 195,
    [int]$Iterations = 10000,
    [int]$Seed = 20261110
)
$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$root = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $root 'data\private' }
$ex = Join-Path $DataDir $Extract

Add-Type -TypeDefinition @'
using System;
public static class Boot {
    // per author: nA,kA,nB,kB. returns arrays shareA, shareB, diff (NaN when undefined)
    public static double[][] Run(int[] nA, int[] kA, int[] nB, int[] kB, int iters, int seed) {
        int n = nA.Length; Random rnd = new Random(seed);
        double[] sa = new double[iters], sb = new double[iters], sd = new double[iters];
        for (int it = 0; it < iters; it++) {
            long a = 0, ka = 0, b = 0, kb = 0;
            for (int i = 0; i < n; i++) { int j = rnd.Next(n); a += nA[j]; ka += kA[j]; b += nB[j]; kb += kB[j]; }
            sa[it] = a > 0 ? (double)ka / a : double.NaN;
            sb[it] = b > 0 ? (double)kb / b : double.NaN;
            sd[it] = (a > 0 && b > 0) ? sa[it] - sb[it] : double.NaN;
        }
        return new double[][] { sa, sb, sd };
    }
}
'@

function Wil([int]$k, [int]$n) {
    if ($n -eq 0) { return '-' }
    $z = 1.96; $p = $k / $n; $d = 1 + $z * $z / $n
    $c = ($p + $z * $z / (2 * $n)) / $d; $h = $z * [math]::Sqrt($p * (1 - $p) / $n + $z * $z / (4 * $n * $n)) / $d
    '{0:N1}-{1:N1}' -f (100 * ($c - $h)), (100 * ($c + $h))
}
function Stat($v) {
    $x = @($v | Where-Object { -not [double]::IsNaN($_) } | Sort-Object)
    if ($x.Count -eq 0) { return $null }
    $m = ($x | Measure-Object -Average).Average
    $ss = 0.0; foreach ($e in $x) { $ss += ($e - $m) * ($e - $m) }
    $var = if ($x.Count -gt 1) { $ss / ($x.Count - 1) } else { 0 }
    [pscustomobject]@{ N = $x.Count; Lo = $x[[int][math]::Floor(0.025 * ($x.Count - 1))]; Hi = $x[[int][math]::Ceiling(0.975 * ($x.Count - 1))]
        Var = $var; Pos = (@($x | Where-Object { $_ -gt 0 }).Count / $x.Count) }
}
function Pc($x) { '{0:N1}' -f (100 * $x) }

$grp = @{}; Import-Csv (Join-Path $ex 'stage4b\cohort-groups.csv') | ForEach-Object { $grp[$_.modid] = $_.group }
$kind = @{}; Import-Csv (Join-Path $ex 'stage2\code-content.csv') -Encoding UTF8 | Where-Object { $_.rowKind -eq 'cohort' -and $_.group -eq $Cohort } | ForEach-Object { $kind[$_.modid] = $_.kind }
$rows = @(Import-Csv (Join-Path $ex 'cohort-rows.csv') | Where-Object { $_.release -eq $Cohort -and [int]$_.downloads -ge $MinDownloads })
foreach ($r in $rows) {
    $g = $grp[$r.modid]; if (-not $g) { throw "mod $($r.modid) has no group" }
    $r | Add-Member -NotePropertyName G -NotePropertyValue $g -Force
    $r | Add-Member -NotePropertyName Kind -NotePropertyValue $(if ($kind.ContainsKey($r.modid)) { $kind[$r.modid] } else { 'missing' }) -Force
    $r | Add-Member -NotePropertyName Upd -NotePropertyValue ($r.updatedDay -ne '' -and [int]$r.updatedDay -le $Horizon) -Force
}

$isEarly = { $_.G -eq 'AI-early' }
$isOther = { $_.G -eq 'rest' -or $_.G -eq 'AI-late' }
$isAiAll = { $_.G -like 'AI-*' }
$isNonDecl = { $_.G -eq 'rest' -or $_.G -like 'noAI-*' }
$isNoAi = { $_.G -like 'noAI-*' }
$isNoAiEarly = { $_.G -eq 'noAI-early' }
$code = { $_.Kind -eq 'code' }; $content = { $_.Kind -eq 'content' }

# name, A filter, B filter, population extra filter, expected A (k,n), expected B (k,n) ('' = none)
$comps = @(
    @{ N = 'b/a: AI-early vs rest + AI-late'; A = $isEarly; B = $isOther; X = $null; EA = @(25, 45); EB = @(1681, 3221) },
    @{ N = 'c: all declared AI vs all non-declared (rest + noAI)'; A = $isAiAll; B = $isNonDecl; X = $null; EA = @(70, 98); EB = @(1650, 3191) },
    @{ N = 'd1: code mods, AI-early vs rest + AI-late'; A = $isEarly; B = $isOther; X = $code; EA = @(23, 33); EB = @(892, 1451) },
    @{ N = 'd2: content mods, AI-early vs rest + AI-late'; A = $isEarly; B = $isOther; X = $content; EA = @(2, 11); EB = @(782, 1759) },
    @{ N = 'extra: noAI-early vs rest + AI-late'; A = $isNoAiEarly; B = $isOther; X = $null; EA = @(5, 7); EB = @(1681, 3221) },
    @{ N = 'extra: all noAI (15) vs rest + AI-late'; A = $isNoAi; B = $isOther; X = $null; EA = @(12, 15); EB = @(1681, 3221) }
)

$sb = New-Object System.Text.StringBuilder
function Out($s) { [void]$sb.AppendLine($s) }
Out "# Cluster bootstrap over authors, share updated ($Extract)"
Out ''
Out "Cohort $Cohort, downloads >= $MinDownloads, n = $($rows.Count) mods, $(@($rows | Group-Object author).Count) authors. Updated = release for the next game version within $Horizon days. $Iterations resamples, seed $Seed. Generated by scripts\Get-AuthorBootstrap.ps1 (definitions in its header). Authors are resampled with all their mods in the comparison's population; shares in percent. Wilson = interval on mods, ignoring clustering; boot = 2.5/97.5 percentile; deff = bootstrap variance / binomial variance of the share."
Out ''
$repro = New-Object System.Text.StringBuilder
$tab = New-Object System.Text.StringBuilder
$odd = New-Object System.Text.StringBuilder
foreach ($c in $comps) {
    $sel = @($rows | Where-Object $c.A) + @($rows | Where-Object $c.B)
    $selA = @($rows | Where-Object $c.A); $selB = @($rows | Where-Object $c.B)
    if ($c.X) { $selA = @($selA | Where-Object $c.X); $selB = @($selB | Where-Object $c.X) }
    $cntA = @($selA | Where-Object Upd).Count; $cntB = @($selB | Where-Object Upd).Count
    $okA = ($cntA -eq $c.EA[0] -and $selA.Count -eq $c.EA[1]); $okB = ($cntB -eq $c.EB[0] -and $selB.Count -eq $c.EB[1])
    [void]$repro.AppendLine("| $($c.N) | A: $cntA/$($selA.Count) (expected $($c.EA[0])/$($c.EA[1])) | B: $cntB/$($selB.Count) (expected $($c.EB[0])/$($c.EB[1])) | $(if ($okA -and $okB) { 'REPRODUCED' } else { 'NOT REPRODUCED' }) |")
    # per-author counts
    $pop = @($selA + $selB)
    $names = @($pop | Group-Object author)
    $aSet = @{}; foreach ($m in $selA) { $aSet[$m.author] = 1 }; $bSet = @{}; foreach ($m in $selB) { $bSet[$m.author] = 1 }
    $both = @($aSet.Keys | Where-Object { $bSet.ContainsKey($_) }).Count
    [void]$odd.AppendLine("- $($c.N): authors in A $($aSet.Count), in B $($bSet.Count), in both $both.")
    $idA = @{}; foreach ($m in $selA) { $idA[$m.modid + '|' + $m.author] = 1 }
    $nAv = New-Object 'int[]' $names.Count; $kAv = New-Object 'int[]' $names.Count; $nBv = New-Object 'int[]' $names.Count; $kBv = New-Object 'int[]' $names.Count
    for ($i = 0; $i -lt $names.Count; $i++) {
        foreach ($m in $names[$i].Group) {
            if ($idA.ContainsKey($m.modid + '|' + $m.author)) { $nAv[$i]++; if ($m.Upd) { $kAv[$i]++ } }
            else { $nBv[$i]++; if ($m.Upd) { $kBv[$i]++ } }
        }
    }
    $res = [Boot]::Run($nAv, $kAv, $nBv, $kBv, $Iterations, $Seed)
    $stA = Stat $res[0]; $stB = Stat $res[1]; $stD = Stat $res[2]
    $pA = $cntA / $selA.Count; $pB = $cntB / $selB.Count
    function Deff($s, $p, $n) { if ($p -le 0 -or $p -ge 1) { return 'n/a' }; '{0:N2}' -f ($s.Var / ($p * (1 - $p) / $n)) }
    [void]$tab.AppendLine("| $($c.N) | A | $($selA.Count) | $($aSet.Count) | $(Pc $pA) | $(Wil $cntA $selA.Count) | $(Pc $stA.Lo)-$(Pc $stA.Hi) | $(Deff $stA $pA $selA.Count) | | |")
    [void]$tab.AppendLine("| | B | $($selB.Count) | $($bSet.Count) | $(Pc $pB) | $(Wil $cntB $selB.Count) | $(Pc $stB.Lo)-$(Pc $stB.Hi) | $(Deff $stB $pB $selB.Count) | | |")
    [void]$tab.AppendLine("| | A - B | | | $(Pc ($pA - $pB)) | | $(Pc $stD.Lo) to $(Pc $stD.Hi) | | $(Pc $stD.Pos) | $($Iterations - $stD.N) |")
}
Out '## Reproduction of group counts and shares (expected values from the stage 4b reports)'
Out ''
Out '| comparison | group A | group B | check |'
Out '|---|---|---|---|'
Out $repro.ToString().TrimEnd()
Out ''
Out '## Bootstrap results (A = first group, B = comparison group)'
Out ''
Out '| comparison | group | mods | authors | share % | Wilson 95% | boot 95% | deff | P(A-B > 0) % | skipped resamples |'
Out '|---|---|---|---|---|---|---|---|---|---|'
Out $tab.ToString().TrimEnd()
Out ''
Out '## Authors present in both groups of a comparison'
Out ''
Out $odd.ToString().TrimEnd()
$outPath = Join-Path $root "results\author-bootstrap-$Extract.md"
[IO.File]::WriteAllText($outPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host "Written to $outPath"
