<#
.SYNOPSIS
  Builds/extends a shared, resumable on-disk cache of the Vintage Story mod DB API.
.NOTES
  Exit codes: 0 ok, 2 too many consecutive transient failures, 3 fatal (403 / non-JSON / bad statuscode), 1 other error.
  ASCII only on purpose (Windows PowerShell 5.1).
#>
[CmdletBinding()]
param(
    [int]$Limit = 1000,
    [int]$Seed = 42,
    [int]$MaxAgeDays = 30,
    [int]$DelayMs = 1000,
    [string]$SeedFrom = '',
    [string]$DataDir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $DataDir) { $DataDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data\private\moddb-cache' }
$BaseUrl   = 'https://mods.vintagestory.at'
$UserAgent = 'vs-mod-research/1.0 (personal non-commercial research)'
$Utf8      = New-Object System.Text.UTF8Encoding($false)

$ModsDir = Join-Path $DataDir 'mods'
$LogDir  = Join-Path $DataDir 'logs'
foreach ($p in @($DataDir, $ModsDir, $LogDir)) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
$IndexPath = Join-Path $DataDir 'index.csv'
$LogPath   = Join-Path $LogDir ('run-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')

function Write-Log([string]$Msg) {
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Msg
    Write-Host $line
    [IO.File]::AppendAllText($LogPath, $line + "`r`n", $Utf8)
}

function Save-Atomic([string]$Path, [byte[]]$Bytes) {
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    if (Test-Path $Path) { [IO.File]::Delete($Path) }
    [IO.File]::Move($tmp, $Path)
}

# ---- index (hashtable modid -> PSCustomObject) ----
$Index = @{}
function Load-Index {
    if (Test-Path $IndexPath) {
        foreach ($r in (Import-Csv -Path $IndexPath -Encoding UTF8)) { $Index[[string]$r.modid] = $r }
    }
}
function Save-Index {
    $rows = $Index.Values | Sort-Object { [int]$_.modid } |
        Select-Object modid, status, fetchedUtc, lastreleased, comments
    $csv = ($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
    Save-Atomic $IndexPath ($Utf8.GetBytes($csv + "`r`n"))
}
function Set-IndexRow([string]$ModId, [string]$Status, [string]$Fetched, [string]$Last, [string]$Comments) {
    $Index[$ModId] = [pscustomobject]@{ modid = $ModId; status = $Status; fetchedUtc = $Fetched; lastreleased = $Last; comments = $Comments }
}
function Fmt-Utc([datetime]$D) { $D.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

# ---- deterministic order key: first 8 bytes of SHA-256, big-endian (FNV-1a mixed poorly, see README) ----
$script:Sha = [Security.Cryptography.SHA256]::Create()
function Get-OrderKey([string]$s) {
    $b = $script:Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
    [uint64]$h = 0
    for ($i = 0; $i -lt 8; $i++) { $h = $h * 256 + $b[$i] }
    return $h
}

# ---- HTTP ----
# returns @{ Code; Bytes; RetryAfter; Error }  (Code 0 = network error/timeout)
function Invoke-Http([string]$Url) {
    $res = @{ Code = 0; Bytes = $null; RetryAfter = 0; Error = '' }
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = $UserAgent
        $req.Timeout = 60000
        $req.ReadWriteTimeout = 60000
        $req.AllowAutoRedirect = $true
        $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        $req.Accept = 'application/json'
        try { $resp = $req.GetResponse() }
        catch [Net.WebException] {
            if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
        }
        try {
            $res.Code = [int]$resp.StatusCode
            $ra = $resp.Headers['Retry-After']
            if ($ra) { $n = 0; if ([int]::TryParse($ra, [ref]$n)) { $res.RetryAfter = $n } }
            $ms = New-Object IO.MemoryStream
            $st = $resp.GetResponseStream()
            $st.CopyTo($ms)
            $res.Bytes = $ms.ToArray()
        } finally { $resp.Close() }
    } catch {
        $res.Code = 0
        $res.Error = $_.Exception.Message
    }
    return $res
}

$script:StopReason = 'completed'
$script:ExitCode = 0
$script:Json = $null
$script:LastReqTicks = 0
$script:consecFail = 0
$script:Errors = 0
$Backoff = @(30, 60, 120, 240, 480, 900)

function Fail-Fatal([string]$Why, [byte[]]$Bytes) {
    Write-Log ("FATAL: " + $Why)
    if ($Bytes) {
        $t = $Utf8.GetString($Bytes)
        if ($t.Length -gt 500) { $t = $t.Substring(0, 500) }
        Write-Log ("Body (first 500 chars): " + $t)
    }
    $script:StopReason = $Why
    $script:ExitCode = 3
}

# Classify a response: 'ok' | 'gone' | 'retry' | 'fatal'
function Classify($r) {
    if ($r.Code -eq 0 -or $r.Code -eq 429 -or $r.Code -ge 500) { return 'retry' }
    if ($r.Code -eq 403) { Fail-Fatal "HTTP 403" $r.Bytes; return 'fatal' }
    if ($r.Code -ne 200 -and $r.Code -ne 404) { Fail-Fatal ("Unexpected HTTP " + $r.Code) $r.Bytes; return 'fatal' }
    $j = $null
    try { $j = $Utf8.GetString($r.Bytes) | ConvertFrom-Json } catch { $j = $null }
    if (-not $j -or $null -eq $j.statuscode) { Fail-Fatal "Non-JSON body or no statuscode" $r.Bytes; return 'fatal' }
    $sc = [string]$j.statuscode
    if ($sc -eq '404') { return 'gone' }
    if ($sc -ne '200' -or $r.Code -ne 200) { Fail-Fatal ("JSON statuscode " + $sc + " / HTTP " + $r.Code) $r.Bytes; return 'fatal' }
    return 'ok'
}

function Get-Polite([string]$Url) {
    # strictly sequential, one request per DelayMs
    if ($script:LastReqTicks -ne 0) {
        $elapsedMs = ([double]([Diagnostics.Stopwatch]::GetTimestamp() - $script:LastReqTicks)) * 1000.0 / [Diagnostics.Stopwatch]::Frequency
        $wait = $DelayMs - $elapsedMs
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
    }
    $r = Invoke-Http $Url
    $script:LastReqTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    return $r
}

# Fetch with retry/backoff. Returns @{Kind; Bytes} or $null when we must stop.
function Get-WithRetry([string]$Url) {
    while ($true) {
        $r = Get-Polite $Url
        $kind = Classify $r
        if ($kind -eq 'fatal') { return $null }
        if ($kind -ne 'retry') { $script:consecFail = 0; return @{ Kind = $kind; Bytes = $r.Bytes } }
        $script:consecFail++
        $script:Errors++
        $why = if ($r.Code -eq 0) { $r.Error } else { "HTTP " + $r.Code }
        if ($script:consecFail -ge 5) {
            Write-Log ("Failure #" + $script:consecFail + " (" + $why + "): giving up")
            $script:StopReason = "5 consecutive failures (" + $why + ")"
            $script:ExitCode = 2
            return $null
        }
        $sec = $Backoff[[Math]::Min($script:consecFail - 1, $Backoff.Count - 1)]
        if ($r.RetryAfter -gt $sec) { $sec = $r.RetryAfter }
        Write-Log ("Failure #" + $script:consecFail + " (" + $why + ") on " + $Url + "; backing off " + $sec + " s")
        Start-Sleep -Seconds $sec
    }
}

# ================= main =================
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Log ("Start. Limit=$Limit Seed=$Seed MaxAgeDays=$MaxAgeDays DelayMs=$DelayMs DataDir=$DataDir")

# Keep the system from idle sleep while running (display may still turn off). Windows drops the request when the
# process exits, so a crash cannot leave it set; we also clear it explicitly at the end. Lid close still sleeps.
try {
    Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    # ES_CONTINUOUS 0x80000000 | ES_SYSTEM_REQUIRED 0x00000001
    if ([Win32.Power]::SetThreadExecutionState([uint32]2147483649) -eq 0) { Write-Log 'Warning: could not block idle sleep' }
    else { Write-Log 'Idle sleep blocked for this run' }
} catch { Write-Log ('Warning: could not block idle sleep: ' + $_.Exception.Message) }
Load-Index

# ---- seed import ----
$seeded = 0; $seedSkipped = 0
if ($SeedFrom) {
    if (-not (Test-Path $SeedFrom)) { Write-Log "SeedFrom not found: $SeedFrom" }
    else {
        foreach ($f in (Get-ChildItem -Path $SeedFrom -Filter '*.json' -File)) {
            if ($f.BaseName -notmatch '^\d+$') { $seedSkipped++; continue }
            $dest = Join-Path $ModsDir ($f.BaseName + '.json')
            if ((Test-Path $dest) -and $Index.ContainsKey($f.BaseName)) { continue }
            try {
                $bytes = [IO.File]::ReadAllBytes($f.FullName)
                $j = $Utf8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
                if ([string]$j.statuscode -ne '200' -or -not $j.mod) { $seedSkipped++; continue }
            } catch { $seedSkipped++; continue }
            Save-Atomic $dest $bytes
            $lr = ''; if ($null -ne $j.mod.lastreleased) { $lr = [string]$j.mod.lastreleased }
            $cm = ''; if ($null -ne $j.mod.comments) { $cm = [string]$j.mod.comments }
            Set-IndexRow $f.BaseName 'ok' (Fmt-Utc $f.LastWriteTimeUtc) $lr $cm
            $seeded++
        }
        if ($seeded -gt 0) { Save-Index }
        Write-Log ("Seed import: $seeded imported, $seedSkipped skipped")
    }
}

# ---- list ----
$today = (Get-Date).ToString('yyyy-MM-dd')
$listPath = Join-Path $DataDir ("modlist-$today.json")
$listBytes = $null
if (Test-Path $listPath) {
    $listBytes = [IO.File]::ReadAllBytes($listPath)
    Write-Log "Reusing today's list: $listPath"
} else {
    Write-Log "Fetching mod list"
    $g = Get-WithRetry ($BaseUrl + '/api/mods')
    if ($g -and $g.Kind -eq 'ok') { $listBytes = $g.Bytes; Save-Atomic $listPath $listBytes }
}
$mods = @()
if ($listBytes) {
    $lj = $Utf8.GetString($listBytes) | ConvertFrom-Json
    if ([string]$lj.statuscode -ne '200') { Fail-Fatal ("List statuscode " + $lj.statuscode) $listBytes }
    else { $mods = @($lj.mods) }
} elseif ($script:ExitCode -eq 0) { $script:ExitCode = 1; $script:StopReason = 'could not get list' }
$totalInList = $mods.Count

$fetched = 0; $gone = 0; $fresh = 0; $done = 0
if ($script:ExitCode -eq 0) {
    # deterministic order: SHA-256 of "<seed>-<modid>", ties by modid
    $order = $mods | ForEach-Object {
        [pscustomobject]@{ H = (Get-OrderKey ("$Seed-" + $_.modid)); Id = [int]$_.modid; M = $_ }
    } | Sort-Object H, Id

    $now = (Get-Date).ToUniversalTime()
    foreach ($o in $order) {
        if ($done -ge $Limit) { $script:StopReason = 'limit reached'; break }
        $id = [string]$o.Id
        $lr = ''; if ($null -ne $o.M.lastreleased) { $lr = [string]$o.M.lastreleased }
        $cm = ''; if ($null -ne $o.M.comments) { $cm = [string]$o.M.comments }
        $row = $Index[$id]
        $need = $false
        if (-not $row) { $need = $true }
        elseif ($row.lastreleased -ne $lr -or $row.comments -ne $cm) { $need = $true }
        else {
            $ft = [datetime]::MinValue
            $okParse = [datetime]::TryParse($row.fetchedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$ft)
            if (-not $okParse -or ($now - $ft).TotalDays -gt $MaxAgeDays) { $need = $true }
            elseif ($row.status -eq 'ok' -and -not (Test-Path (Join-Path $ModsDir "$id.json"))) { $need = $true }
        }
        if (-not $need) { $fresh++; continue }

        $g = Get-WithRetry ($BaseUrl + '/api/mod/' + $id)
        if (-not $g) { break }
        if ($g.Kind -eq 'ok') {
            Save-Atomic (Join-Path $ModsDir "$id.json") $g.Bytes
            Set-IndexRow $id 'ok' (Fmt-Utc (Get-Date)) $lr $cm
            $fetched++
        } else {
            Set-IndexRow $id 'gone' (Fmt-Utc (Get-Date)) $lr $cm
            $gone++
        }
        Save-Index
        $done++
        if ($done % 25 -eq 0) {
            $el = $sw.Elapsed
            $eta = [TimeSpan]::FromSeconds($el.TotalSeconds / $done * ($Limit - $done))
            Write-Log ("Progress $done/$Limit, elapsed " + $el.ToString('hh\:mm\:ss') + ", ETA " + $eta.ToString('hh\:mm\:ss'))
        }
    }
    if ($script:ExitCode -eq 0 -and $done -lt $Limit) { $script:StopReason = 'no more mods needing fetch' }
}

$cached = @(Get-ChildItem -Path $ModsDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
Write-Log "---- Summary ----"
Write-Log ("fetched=$fetched gone=$gone skipped-fresh=$fresh errors=" + $script:Errors + " seeded=$seeded")
Write-Log ("stop reason: " + $script:StopReason)
Write-Log ("total mods in list=$totalInList, total cached=$cached, elapsed=" + $sw.Elapsed.ToString('hh\:mm\:ss'))
try { [void][Win32.Power]::SetThreadExecutionState([uint32]2147483648) } catch { }  # ES_CONTINUOUS only: allow sleep again
exit $script:ExitCode
