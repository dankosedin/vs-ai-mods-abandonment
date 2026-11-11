<#
.SYNOPSIS
  Caches the entry listing (names and sizes) of mod release zips, read from the tail of each file with HTTP Range.
.DESCRIPTION
  For each file of -FileList (CSV with fileid, url and optionally filename, fetch, order) not yet cached with status
  ok, notzip or gone: GET Range bytes=-65536, find the zip End Of Central Directory record, and if the central
  directory starts before the fetched window, one more Range request for exactly the missing part. Parses the
  central directory (ZIP64 supported). Writes <DataDir>\files\<fileid>.json. Release files are immutable, so a cached
  listing is never refreshed. Rows with fetch=False (not a zip) are skipped without a request.
  Statuses: ok, notzip (binary body without a zip directory; first bytes kept), gone (HTTP 404/410),
  error-<kind> (retried on the next run). An error is never written as an empty listing.
.NOTES
  Exit codes: 0 ok, 2 too many consecutive transient failures, 3 fatal (403 / HTML or text body / range ignored /
  3 notzip in a row / unexpected HTTP), 1 other error. ASCII only on purpose (Windows PowerShell 5.1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FileList,
    [int]$Limit = 1000,
    [int]$Take = 0,
    [int]$DelayMs = 1000,
    [int]$TailBytes = 65536,
    [string]$DataDir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $DataDir) { $DataDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data\private\moddb-cache' }
$UserAgent = 'vs-mod-research/1.0 (personal non-commercial research)'
$Utf8      = New-Object System.Text.UTF8Encoding($false)
$Cp437     = [Text.Encoding]::GetEncoding(437)

$FilesDir = Join-Path $DataDir 'files'
$LogDir   = Join-Path $DataDir 'logs'
foreach ($p in @($DataDir, $FilesDir, $LogDir)) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
$LogPath  = Join-Path $LogDir ('files-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')

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
function Fmt-Utc([datetime]$D) { $D.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
function Hex([byte[]]$B, [int]$N) {
    if (-not $B) { return '' }
    $n = [Math]::Min($N, $B.Length)
    (($B[0..($n - 1)] | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Printable([byte[]]$B, [int]$N) {
    if (-not $B) { return '' }
    $n = [Math]::Min($N, $B.Length)
    $s = $Utf8.GetString($B, 0, $n)
    ($s.ToCharArray() | ForEach-Object { if ([int]$_ -ge 32 -and [int]$_ -lt 127) { $_ } else { '.' } }) -join ''
}

# ---- HTTP ----
# returns @{ Code; Bytes; RetryAfter; Error; ContentRange; ContentType; TooBig }  (Code 0 = network error/timeout)
function Invoke-Range([string]$Url, [long]$From, [long]$To) {
    $res = @{ Code = 0; Bytes = $null; RetryAfter = 0; Error = ''; ContentRange = ''; ContentType = ''; TooBig = $false }
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = $UserAgent
        $req.Timeout = 60000
        $req.ReadWriteTimeout = 60000
        $req.AllowAutoRedirect = $true
        $req.CookieContainer = $null
        if ($To -lt 0) { $req.AddRange([long]$From) } else { $req.AddRange([long]$From, [long]$To) }
        try { $resp = $req.GetResponse() }
        catch [Net.WebException] {
            if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
        }
        try {
            $res.Code = [int]$resp.StatusCode
            $res.ContentRange = [string]$resp.Headers['Content-Range']
            $res.ContentType = [string]$resp.ContentType
            $ra = $resp.Headers['Retry-After']
            if ($ra) { $n = 0; if ([int]::TryParse($ra, [ref]$n)) { $res.RetryAfter = $n } }
            # read at most 4 * TailBytes + 1 MB: a server ignoring Range must not make us download whole mods
            $cap = 4 * $TailBytes + 1048576
            if ($To -ge 0) { $cap = [Math]::Max($cap, ($To - $From + 1) + 1024) }
            $ms = New-Object IO.MemoryStream
            $st = $resp.GetResponseStream()
            $buf = New-Object byte[] 65536
            while ($true) {
                $k = $st.Read($buf, 0, $buf.Length)
                if ($k -le 0) { break }
                $ms.Write($buf, 0, $k)
                if ($ms.Length -gt $cap) { $res.TooBig = $true; break }
            }
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
$script:LastReqTicks = 0
$script:consecFail = 0
$script:Errors = 0
$script:Requests = 0
$Backoff = @(30, 60, 120, 240, 480, 900)

function Fail-Fatal([string]$Why, [byte[]]$Bytes) {
    Write-Log ("FATAL: " + $Why)
    if ($Bytes) {
        Write-Log ("Body first 64 bytes hex: " + (Hex $Bytes 64))
        Write-Log ("Body first 300 chars: " + (Printable $Bytes 300))
    }
    $script:StopReason = $Why
    $script:ExitCode = 3
}
function Is-TextBody($r) {
    if ($r.ContentType -match 'text/|html|json|xml') { return $true }
    if (-not $r.Bytes -or $r.Bytes.Length -eq 0) { return $false }
    $head = (Printable $r.Bytes 200).TrimStart().ToLowerInvariant()
    return ($head.StartsWith('<!doctype') -or $head.StartsWith('<html') -or $head.StartsWith('<?xml'))
}

# Classify: 'ok' | 'gone' | 'retry' | 'fatal'
function Classify($r) {
    if ($r.Code -eq 0 -or $r.Code -eq 429 -or $r.Code -ge 500) { return 'retry' }
    if ($r.Code -eq 403) { Fail-Fatal "HTTP 403" $r.Bytes; return 'fatal' }
    if ($r.Code -eq 404 -or $r.Code -eq 410) { return 'gone' }
    if ($r.Code -ne 200 -and $r.Code -ne 206) { Fail-Fatal ("Unexpected HTTP " + $r.Code) $r.Bytes; return 'fatal' }
    if ($r.TooBig) { Fail-Fatal ("Range ignored? body longer than cap, HTTP " + $r.Code) $null; return 'fatal' }
    if (Is-TextBody $r) { Fail-Fatal ("Text/HTML body (Content-Type '" + $r.ContentType + "')") $r.Bytes; return 'fatal' }
    return 'ok'
}
function Get-Polite([string]$Url, [long]$From, [long]$To) {
    if ($script:LastReqTicks -ne 0) {
        $elapsedMs = ([double]([Diagnostics.Stopwatch]::GetTimestamp() - $script:LastReqTicks)) * 1000.0 / [Diagnostics.Stopwatch]::Frequency
        $wait = $DelayMs - $elapsedMs
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
    }
    $r = Invoke-Range $Url $From $To
    $script:Requests++
    $script:LastReqTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    return $r
}
# Returns @{Kind; R} or $null when we must stop.
# Kind 'badfile': the same URL answered 5xx three times in a row (seen 02.11.2026: one file whose URL is cut in the
# middle of a UTF-8 character gets 502 while every other file is fine). The caller records it and moves on.
function Get-WithRetry([string]$Url, [long]$From, [long]$To) {
    $fileFail = 0
    while ($true) {
        $r = Get-Polite $Url $From $To
        $kind = Classify $r
        if ($kind -eq 'fatal') { Write-Log ("  on " + $Url); return $null }
        if ($kind -ne 'retry') { $script:consecFail = 0; return @{ Kind = $kind; R = $r } }
        $script:consecFail++
        $script:Errors++
        $fileFail++
        $why = if ($r.Code -eq 0) { $r.Error } else { "HTTP " + $r.Code }
        if ($fileFail -ge 3 -and $r.Code -ge 500) {
            Write-Log ("Failure #" + $fileFail + " (" + $why + ") on this file: recording it and moving on")
            $script:consecFail = 0
            return @{ Kind = 'badfile'; R = $r }
        }
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

# Content-Range "bytes a-b/total" -> @(a, total); 200 without it -> @(0, length)
function Parse-Range($r) {
    if ($r.ContentRange -match '^bytes\s+(\d+)-(\d+)/(\d+)$') { return @([long]$Matches[1], [long]$Matches[3]) }
    if ($r.Code -eq 200) { return @([long]0, [long]$r.Bytes.Length) }
    return $null
}

# ---- zip parsing (little endian) ----
function U16([byte[]]$b, [long]$o) { [BitConverter]::ToUInt16($b, [int]$o) }
function U32([byte[]]$b, [long]$o) { [BitConverter]::ToUInt32($b, [int]$o) }
function U64([byte[]]$b, [long]$o) { [BitConverter]::ToUInt64($b, [int]$o) }
function Find-Sig([byte[]]$b, [long]$from, [long]$downTo, [byte]$s2, [byte]$s3) {
    for ($i = $from; $i -ge $downTo; $i--) {
        if ($b[$i] -eq 0x50 -and $b[$i + 1] -eq 0x4b -and $b[$i + 2] -eq $s2 -and $b[$i + 3] -eq $s3) { return $i }
    }
    return -1
}
# Locate the central directory. Returns @{ Ok; Why; CdStart (absolute); CdSize; Entries; Zip64 }
function Read-Eocd([byte[]]$b, [long]$winStart) {
    $res = @{ Ok = $false; Why = ''; CdStart = 0L; CdSize = 0L; Entries = 0L; Zip64 = $false }
    if ($b.Length -lt 22) { $res.Why = 'short'; return $res }
    $low = [Math]::Max(0, $b.Length - 22 - 65535)
    $i = Find-Sig $b ($b.Length - 22) $low 0x05 0x06
    # prefer a record whose comment length reaches exactly to the end of the file
    $j = $i
    while ($j -ge 0) {
        if ($j + 22 + (U16 $b ($j + 20)) -eq $b.Length) { break }
        if ($j - 1 -lt $low) { $j = -1; break }
        $j = Find-Sig $b ($j - 1) $low 0x05 0x06
    }
    if ($j -ge 0) { $i = $j }
    if ($i -lt 0) { $res.Why = 'no-eocd'; return $res }
    $entries = [long](U16 $b ($i + 10)); $cdSize = [long](U32 $b ($i + 12)); $cdOff = [long](U32 $b ($i + 16))
    $endOfCd = $winStart + $i
    if ($entries -eq 0xFFFF -or $cdSize -eq 0xFFFFFFFFL -or $cdOff -eq 0xFFFFFFFFL) {
        $res.Zip64 = $true
        $loc = $i - 20
        if ($loc -lt 0 -or -not ($b[$loc] -eq 0x50 -and $b[$loc + 1] -eq 0x4b -and $b[$loc + 2] -eq 0x06 -and $b[$loc + 3] -eq 0x07)) { $res.Why = 'zip64-no-locator'; return $res }
        $z64Abs = [long](U64 $b ($loc + 8))
        # the zip64 EOCD normally sits right before the locator; find it in the window
        $z = $z64Abs - $winStart
        if ($z -lt 0 -or $z + 56 -gt $b.Length -or -not ($b[$z] -eq 0x50 -and $b[$z + 1] -eq 0x4b -and $b[$z + 2] -eq 0x06 -and $b[$z + 3] -eq 0x06)) {
            $z = Find-Sig $b ($loc - 56) 0 0x06 0x06
            if ($z -lt 0) { $res.Why = 'zip64-no-eocd'; return $res }
        }
        $entries = [long](U64 $b ($z + 32)); $cdSize = [long](U64 $b ($z + 40)); $cdOff = [long](U64 $b ($z + 48))
        $endOfCd = $winStart + $z
    }
    $res.Entries = $entries; $res.CdSize = $cdSize
    # robust to data prepended to the zip: the directory ends where the (zip64) EOCD starts
    $res.CdStart = $endOfCd - $cdSize
    if ($res.CdStart -lt 0) { $res.Why = 'bad-cd-size'; return $res }
    $res.Ok = $true
    return $res
}
# Parse central directory bytes. Returns @{ Ok; Why; Entries = list }
function Read-Cd([byte[]]$b, [long]$count) {
    $list = New-Object Collections.Generic.List[object]
    $o = 0
    for ($n = 0; $n -lt $count; $n++) {
        if ($o + 46 -gt $b.Length) { return @{ Ok = $false; Why = 'cd-truncated'; Entries = $list } }
        if (-not ($b[$o] -eq 0x50 -and $b[$o + 1] -eq 0x4b -and $b[$o + 2] -eq 0x01 -and $b[$o + 3] -eq 0x02)) { return @{ Ok = $false; Why = 'cd-bad-sig'; Entries = $list } }
        $flags = U16 $b ($o + 8)
        $csize = [long](U32 $b ($o + 20)); $usize = [long](U32 $b ($o + 24))
        $nl = U16 $b ($o + 28); $xl = U16 $b ($o + 30); $cl = U16 $b ($o + 32)
        if ($o + 46 + $nl + $xl + $cl -gt $b.Length) { return @{ Ok = $false; Why = 'cd-truncated'; Entries = $list } }
        $enc = if ($flags -band 0x800) { $Utf8 } else { $Cp437 }
        $name = $enc.GetString($b, $o + 46, $nl)
        if ($usize -eq 0xFFFFFFFFL -or $csize -eq 0xFFFFFFFFL) {
            $x = $o + 46 + $nl; $xe = $x + $xl
            while ($x + 4 -le $xe) {
                $id = U16 $b $x; $sz = U16 $b ($x + 2)
                if ($id -eq 1) {
                    $p = $x + 4
                    if ($usize -eq 0xFFFFFFFFL -and $p + 8 -le $x + 4 + $sz) { $usize = [long](U64 $b $p); $p += 8 }
                    if ($csize -eq 0xFFFFFFFFL -and $p + 8 -le $x + 4 + $sz) { $csize = [long](U64 $b $p); $p += 8 }
                    break
                }
                $x += 4 + $sz
            }
        }
        $list.Add([ordered]@{ name = $name; compressedSize = $csize; size = $usize })
        $o += 46 + $nl + $xl + $cl
    }
    return @{ Ok = $true; Why = ''; Entries = $list }
}

function Save-Listing([string]$FileId, [Collections.Specialized.OrderedDictionary]$Obj) {
    $json = $Obj | ConvertTo-Json -Depth 5 -Compress
    Save-Atomic (Join-Path $FilesDir "$FileId.json") ($Utf8.GetBytes($json))
}

# Process one file. Returns the status written, or $null when the run must stop.
function Fetch-One([string]$FileId, [string]$Url) {
    $rec = [ordered]@{ fileid = $FileId; url = $Url; fetchedUtc = ''; status = ''; httpStatus = 0; totalSize = $null
        requests = 0; zip64 = $false; entryCount = 0; entries = @(); note = '' }
    $before = $script:Requests
    $g = Get-WithRetry $Url (-$TailBytes) -1
    if (-not $g) { return $null }
    $r = $g.R
    $rec.httpStatus = $r.Code
    $rec.fetchedUtc = Fmt-Utc (Get-Date)
    if ($g.Kind -eq 'badfile') {
        # not in the skip list ('ok','notzip','gone'), so a later run tries it again
        $rec.status = 'error-http-' + $r.Code; $rec.requests = $script:Requests - $before
        Save-Listing $FileId $rec
        $script:BadFileRun++
        if ($script:BadFileRun -ge 3) {
            Write-Log "3 files in a row failed with 5xx: treating it as an outage"
            $script:StopReason = '3 bad files in a row (5xx)'; $script:ExitCode = 2
            return $null
        }
        return $rec.status
    }
    $script:BadFileRun = 0
    if ($g.Kind -eq 'gone') {
        $rec.status = 'gone'; $rec.requests = $script:Requests - $before
        Save-Listing $FileId $rec; return 'gone'
    }
    $rg = Parse-Range $r
    if (-not $rg) { Fail-Fatal ("HTTP " + $r.Code + " without a parsable Content-Range '" + $r.ContentRange + "'") $r.Bytes; return $null }
    $winStart = $rg[0]; $total = $rg[1]
    $rec.totalSize = $total
    if ($winStart + $r.Bytes.Length -ne $total) { Fail-Fatal ("Window does not reach end of file: start $winStart len " + $r.Bytes.Length + " total $total") $null; return $null }
    $e = Read-Eocd $r.Bytes $winStart
    if (-not $e.Ok) {
        if ($e.Why -eq 'no-eocd' -or $e.Why -eq 'short') {
            $script:NotZipRun++
            $rec.status = 'notzip'; $rec.note = 'no EOCD; first bytes ' + (Hex $r.Bytes 16) + $(if ($winStart -eq 0) { ' (whole file)' } else { ' (tail window)' })
            $rec.requests = $script:Requests - $before
            Write-Log ("  notzip " + $FileId + ": " + $rec.note)
            Save-Listing $FileId $rec
            if ($script:NotZipRun -ge 3) { Fail-Fatal "3 non-zip bodies in a row" $r.Bytes; return $null }
            return 'notzip'
        }
        $rec.status = 'error-' + $e.Why; $rec.zip64 = $e.Zip64; $rec.requests = $script:Requests - $before
        Save-Listing $FileId $rec; return $rec.status
    }
    $script:NotZipRun = 0
    $rec.zip64 = $e.Zip64
    # central directory bytes
    $cdRel = $e.CdStart - $winStart
    if ($cdRel -ge 0) {
        if ($cdRel + $e.CdSize -gt $r.Bytes.Length) { $rec.status = 'error-cd-beyond-eof'; $rec.requests = $script:Requests - $before; Save-Listing $FileId $rec; return $rec.status }
        $cd = New-Object byte[] ([int]$e.CdSize)
        [Array]::Copy($r.Bytes, [int]$cdRel, $cd, 0, [int]$e.CdSize)
    } else {
        $missing = - $cdRel
        if ($missing -gt 64MB) { $rec.status = 'error-cd-too-big'; $rec.note = "missing $missing bytes"; $rec.requests = $script:Requests - $before; Save-Listing $FileId $rec; return $rec.status }
        $g2 = Get-WithRetry $Url $e.CdStart ($winStart - 1)
        if (-not $g2) { return $null }
        if ($g2.Kind -ne 'ok' -or $g2.R.Code -ne 206 -or $g2.R.Bytes.Length -ne $missing) {
            $rec.status = 'error-second-range'; $rec.note = 'HTTP ' + $g2.R.Code + ' len ' + $g2.R.Bytes.Length + ' wanted ' + $missing
            $rec.requests = $script:Requests - $before; Save-Listing $FileId $rec; return $rec.status
        }
        $cd = New-Object byte[] ([int]$e.CdSize)
        [Array]::Copy($g2.R.Bytes, 0, $cd, 0, [int]$missing)
        [Array]::Copy($r.Bytes, 0, $cd, [int]$missing, [int]($e.CdSize - $missing))
        $rec.note = 'second range ' + $missing + ' bytes'
    }
    $p = Read-Cd $cd $e.Entries
    $rec.requests = $script:Requests - $before
    if (-not $p.Ok) { $rec.status = 'error-' + $p.Why; Save-Listing $FileId $rec; return $rec.status }
    $rec.status = 'ok'; $rec.entryCount = $p.Entries.Count; $rec.entries = $p.Entries.ToArray()
    Save-Listing $FileId $rec
    return 'ok'
}

# ================= main =================
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Log ("Start. FileList=$FileList Limit=$Limit Take=$Take DelayMs=$DelayMs DataDir=$DataDir")
try {
    Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    # ES_CONTINUOUS 0x80000000 | ES_SYSTEM_REQUIRED 0x00000001
    if ([Win32.Power]::SetThreadExecutionState([uint32]2147483649) -eq 0) { Write-Log 'Warning: could not block idle sleep' }
    else { Write-Log 'Idle sleep blocked for this run' }
} catch { Write-Log ('Warning: could not block idle sleep: ' + $_.Exception.Message) }

$script:NotZipRun = 0
$script:BadFileRun = 0
$stats = @{}
$skipped = 0; $notFetch = 0; $done = 0
try {
    $list = @(Import-Csv $FileList -Encoding UTF8)
    if ($list.Count -gt 0 -and $list[0].PSObject.Properties['order']) { $list = @($list | Sort-Object { [int]$_.order }) }
    if ($Take -gt 0) { $list = @($list | Select-Object -First $Take) }
    Write-Log ("Files in list (after -Take): " + $list.Count)
    foreach ($f in $list) {
        if ($done -ge $Limit) { $script:StopReason = 'limit reached'; break }
        $fetchCol = $f.PSObject.Properties['fetch']
        $isZip = if ($fetchCol) { $f.fetch -eq 'True' } else { [IO.Path]::GetExtension(([string]$f.filename)).ToLowerInvariant() -eq '.zip' }
        if (-not $isZip) { $notFetch++; continue }
        $path = Join-Path $FilesDir ($f.fileid + '.json')
        if (Test-Path $path) {
            $st = $null
            try { $st = ($Utf8.GetString([IO.File]::ReadAllBytes($path)) | ConvertFrom-Json).status } catch { $st = $null }
            if ($st -eq 'ok' -or $st -eq 'notzip' -or $st -eq 'gone') { $skipped++; continue }
        }
        $s = Fetch-One $f.fileid $f.url
        if (-not $s) { break }
        $stats[$s] = 1 + [int]$stats[$s]
        if ($s -ne 'ok') { Write-Log ("  " + $f.fileid + " -> " + $s) }
        $done++
        if ($done % 50 -eq 0) {
            $el = $sw.Elapsed
            $eta = [TimeSpan]::FromSeconds($el.TotalSeconds / $done * ([Math]::Min($Limit, $list.Count - $skipped - $notFetch) - $done))
            Write-Log ("Progress $done, requests " + $script:Requests + ", elapsed " + $el.ToString('hh\:mm\:ss') + ", ETA " + $eta.ToString('hh\:mm\:ss'))
        }
    }
    if ($script:ExitCode -eq 0 -and $script:StopReason -eq 'completed') { $script:StopReason = 'end of list' }
} catch {
    Write-Log ("ERROR: " + $_.Exception.Message + " at line " + $_.InvocationInfo.ScriptLineNumber)
    $script:StopReason = 'script error'; $script:ExitCode = 1
}

Write-Log "---- Summary ----"
Write-Log ("processed=$done requests=" + $script:Requests + " skipped-cached=$skipped not-zip-by-name=$notFetch transient-errors=" + $script:Errors)
Write-Log ("statuses: " + (($stats.Keys | Sort-Object | ForEach-Object { $_ + '=' + $stats[$_] }) -join ' '))
Write-Log ("stop reason: " + $script:StopReason + ", elapsed=" + $sw.Elapsed.ToString('hh\:mm\:ss'))
try { [void][Win32.Power]::SetThreadExecutionState([uint32]2147483648) } catch { }  # ES_CONTINUOUS only: allow sleep again
Write-Log 'Idle sleep block cleared'
exit $script:ExitCode
