# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Integration tests for the setup.ps1 network layer against a fake release server on 127.0.0.1 only. The twin
# of tests/integration/run.sh: it starts the same tests/integration/fake_release_server.py on a free port, runs
# the same scenarios (a-k, plus a stalled transfer) and prints one `ok <scenario>` line each. The server is
# killed in a finally block. Usage: pwsh -NoProfile -File tests/integration/run-win.ps1
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$env:REA_SETUP_NO_MAIN = '1'
. (Join-Path $root 'setup.ps1')

$script:Failures = 0
$script:Sleeps = New-Object System.Collections.ArrayList

# Records the pause instead of taking it.
function Invoke-ReaSleep {
    param([int]$Seconds)
    [void]$script:Sleeps.Add($Seconds)
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Label)
    if ("$Expected" -ceq "$Actual") { return }
    $script:Failures++
    [Console]::Error.WriteLine("FAIL $Label : expected '$Expected' got '$Actual'")
}

function Assert-That {
    param([bool]$Condition, [string]$Label)
    if ($Condition) { return }
    $script:Failures++
    [Console]::Error.WriteLine("FAIL $Label")
}

function Open-Scenario {
    param([string]$Label)
    $script:ScLabel = $Label
    $script:ScFails = $script:Failures
}

function Close-Scenario {
    if ($script:Failures -eq $script:ScFails) { Write-Output "ok $($script:ScLabel)" }
}

# What is in Dir besides Name.
function Get-OtherFile {
    param([string]$Dir, [string]$Name)
    return @(Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $_.Name -cne $Name } | ForEach-Object { $_.Name })
}

# The number of GET requests the server saw for a path.
function Get-Count {
    param([string]$Path)
    $client = New-Object System.Net.WebClient
    try {
        return $client.DownloadString($script:Base + '/__count' + $Path).Trim()
    } finally {
        $client.Dispose()
    }
}

# Probes candidates with --version and needs a real exit code 0, so the Windows Store python.exe stub (which
# prints a hint and exits non-zero) is skipped. Each candidate is a program and its leading arguments.
$python = $null
$pythonLead = @()
foreach ($candidate in @(@('python3'), @('python'), @('py', '-3'))) {
    $cmd = Get-Command $candidate[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { continue }
    $lead = @($candidate | Select-Object -Skip 1)
    try {
        $probe = Invoke-ReaCommand -Step 'python' -FilePath $cmd.Source -ArgumentList ($lead + '--version')
    } catch {
        continue
    }
    if ($probe.ExitCode -eq 0) {
        $python = $cmd.Source
        $pythonLead = $lead
        break
    }
}
if (-not $python) {
    [Console]::Error.WriteLine('run-win.ps1: a working python3 is required')
    exit 1
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rea-net-it-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$server = $null
try {
    # Payload: 4096 bytes of text; its checksum is the oracle for the download scenarios.
    $line = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+/' + "`n"
    [System.IO.File]::WriteAllText((Join-Path $tmp 'payload.bin'), ($line * 64), (New-Object System.Text.UTF8Encoding $false))
    $payloadSha = Get-ReaFileSha256 (Join-Path $tmp 'payload.bin')

    $scenario = [ordered]@{
        '/a'    = @(@{ status = 504 }, @{ status = 504 }, @{ status = 200; body_file = 'payload.bin' })
        '/b'    = @(@{ status = 504 }, @{ status = 504 }, @{ status = 504 }, @{ status = 504 }, @{ status = 200; body_file = 'payload.bin' })
        '/c'    = @(@{ status = 429; headers = @{ 'Retry-After' = '1' } }, @{ status = 200; body_file = 'payload.bin' })
        '/d'    = @(@{ status = 200; body_file = 'payload.bin'; truncate = 1000 })
        '/e'    = @(@{ status = 302; location = 'https://evil.example/' })
        '/g'    = @(@{ status = 404 }, @{ status = 200; body_file = 'payload.bin' })
        '/h'    = @(@{ status = 200; head_status = 405; body_file = 'payload.bin' })
        '/i2'   = @(@{ status = 200; body_file = 'payload.bin' })
        '/k5'   = @(@{ status = 200; body_file = 'payload.bin' })
        '/f6'   = @(@{ status = 200; body_file = 'payload.bin' })
        '/slow' = @(@{ status = 200; body_file = 'payload.bin'; hang_after = 100 }, @{ status = 200; body_file = 'payload.bin'; hang_after = 100 })
        '/j'    = @(@{ status = 200; body_file = 'payload.bin' }, @{ status = 200; body_file = 'payload.bin' })
    }
    foreach ($i in 0..1) { $scenario["/i$i"] = @(@{ status = 302; location = '{base}/i' + ($i + 1) }) }
    foreach ($i in 0..4) { $scenario["/k$i"] = @(@{ status = 302; location = '{base}/k' + ($i + 1) }) }
    foreach ($i in 0..5) { $scenario["/f$i"] = @(@{ status = 302; location = '{base}/f' + ($i + 1) }) }
    [System.IO.File]::WriteAllText((Join-Path $tmp 'scenario.json'), ($scenario | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))

    $serverArgs = $pythonLead + @('-I', (ConvertTo-ReaQuotedArgument (Join-Path $root 'tests/integration/fake_release_server.py')), '0', (ConvertTo-ReaQuotedArgument (Join-Path $tmp 'scenario.json')))
    $server = Start-Process -FilePath $python -ArgumentList $serverArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $tmp 'server.out') -RedirectStandardError (Join-Path $tmp 'server.err')
    $port = $null
    for ($try = 0; $try -lt 100 -and -not $port; $try++) {
        try {
            $m = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $tmp 'server.out')), '(?m)^PORT (\d+)')
            if ($m.Success) { $port = $m.Groups[1].Value }
        } catch {
            Write-Verbose 'the server output is not readable yet'
        }
        if (-not $port) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $port) {
        [Console]::Error.WriteLine('run-win.ps1: the fake server did not start')
        [Console]::Error.WriteLine([System.IO.File]::ReadAllText((Join-Path $tmp 'server.err')))
        exit 1
    }
    $script:Base = "http://127.0.0.1:$port"
    $base = $script:Base

    # The fake server stays on loopback; ignore any proxy configured for this machine.
    [System.Net.WebRequest]::DefaultWebProxy = $null
    $script:AllowedSchemes = @('https', 'http')
    $script:AllowedHosts = @('127.0.0.1')
    $script:RetryWaits = @(0, 0, 0, 0)
    $script:ConsoleLevel = 'ERROR'
    $env:GITHUB_TOKEN = $null

    # (a) 504, 504, 200: the download succeeds on the third request
    Open-Scenario 'a retry then success'
    Assert-That (Invoke-ReaHttpGet -Url "$base/a" -Destination (Join-Path $tmp 'a.out')) 'a: Invoke-ReaHttpGet'
    Assert-Equal 3 (Get-Count '/a') 'a: three requests'
    Assert-Equal $payloadSha (Get-ReaFileSha256 (Join-Path $tmp 'a.out')) 'a: body intact'
    Close-Scenario

    # (b) four 504s: Invoke-ReaHttpGet gives up after four attempts
    Open-Scenario 'b gives up after four attempts'
    Assert-Equal False (Invoke-ReaHttpGet -Url "$base/b" -Destination (Join-Path $tmp 'b.out')) 'b: returns false'
    Assert-Equal 4 (Get-Count '/b') 'b: four requests'
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $tmp 'b.out'))) 'b: no destination left'
    Close-Scenario

    # (c) 429 with Retry-After: 1 then 200: the pause is the server's value (recorded, not slept)
    Open-Scenario 'c Retry-After honoured'
    $script:Sleeps.Clear()
    Assert-That (Invoke-ReaHttpGet -Url "$base/c" -Destination (Join-Path $tmp 'c.out')) 'c: Invoke-ReaHttpGet'
    Assert-Equal '1' ($script:Sleeps -join ' ') 'c: one pause of 1 second'
    Assert-Equal 2 (Get-Count '/c') 'c: two requests'
    Close-Scenario

    # (d) truncated body: Get-ReaDownload fails and leaves nothing behind
    Open-Scenario 'd truncated body leaves nothing'
    $dd = Join-Path $tmp 'dd'
    New-Item -ItemType Directory -Path $dd | Out-Null
    Assert-Equal False (Get-ReaDownload -Url "$base/d" -Destination (Join-Path $dd 'file') -Sha256 $payloadSha) 'd: returns false'
    Assert-Equal 0 (Get-OtherFile $dd '').Count 'd: no DEST and no DEST.tmp.*'
    Close-Scenario

    # (e) redirect to a disallowed host
    Open-Scenario 'e redirect to a disallowed host'
    Assert-Equal 1 (Resolve-ReaRedirects -Url "$base/e").Code 'e: code 1'
    Close-Scenario

    # (f) six chained redirects: too many hops
    Open-Scenario 'f six redirects'
    Assert-Equal 2 (Resolve-ReaRedirects -Url "$base/f0").Code 'f: code 2'
    Close-Scenario

    # (g) 404: one request, no retry
    Open-Scenario 'g 404 is not retried'
    Assert-Equal False (Invoke-ReaHttpGet -Url "$base/g" -Destination (Join-Path $tmp 'g.out')) 'g: returns false'
    Assert-Equal 1 (Get-Count '/g') 'g: exactly one request'
    Close-Scenario

    # (h) HEAD answered 405: retried as a one-byte ranged GET
    Open-Scenario 'h HEAD 405 falls back to a ranged GET'
    $h = Resolve-ReaRedirects -Url "$base/h"
    Assert-Equal 0 $h.Code 'h: code 0'
    Assert-Equal "$base/h" $h.Url 'h: final URL'
    Close-Scenario

    # (i) a chain within the limit resolves to its end, without fetching the body
    Open-Scenario 'i three-hop chain resolves'
    $r = Resolve-ReaRedirects -Url "$base/i0"
    Assert-Equal "$base/i2" $r.Url 'i: final URL'
    Assert-Equal 0 (Get-Count '/i2') 'i: the final body was never fetched'
    Close-Scenario

    # (k) exactly five redirects is allowed (six, in scenario f, is not)
    Open-Scenario 'k five redirects resolve'
    $r = Resolve-ReaRedirects -Url "$base/k0"
    Assert-Equal 0 $r.Code 'k: code 0'
    Assert-Equal "$base/k5" $r.Url 'k: final URL after 5 hops'
    Close-Scenario

    # (j) Get-ReaDownload: right checksum installs the file (upper case accepted), wrong one removes it
    Open-Scenario 'j checksum verification'
    $jj = Join-Path $tmp 'jj'
    New-Item -ItemType Directory -Path $jj | Out-Null
    Assert-That (Get-ReaDownload -Url "$base/j" -Destination (Join-Path $jj 'ok') -Sha256 $payloadSha.ToUpperInvariant()) 'j: matching checksum'
    Assert-That (Test-Path -LiteralPath (Join-Path $jj 'ok') -PathType Leaf) 'j: file installed'
    Assert-Equal $payloadSha (Get-ReaFileSha256 (Join-Path $jj 'ok')) 'j: content'
    Assert-Equal 0 (Get-OtherFile $jj 'ok').Count 'j: no temporary left'
    Assert-Equal False (Get-ReaDownload -Url "$base/j" -Destination (Join-Path $jj 'bad') -Sha256 ('0' * 64)) 'j: wrong checksum'
    Assert-Equal 0 (Get-OtherFile $jj 'ok').Count 'j: wrong checksum leaves nothing'
    Close-Scenario

    # (n) a transfer that stalls after 100 bytes is aborted by the read timeout and leaves nothing
    Open-Scenario 'n stalled transfer is aborted'
    $nn = Join-Path $tmp 'nn'
    New-Item -ItemType Directory -Path $nn | Out-Null
    $savedTimeout = $script:ReadWriteTimeoutMs
    $savedWindow = $script:StallSeconds
    $savedWaits = $script:RetryWaits
    $script:ReadWriteTimeoutMs = 1500
    $script:StallSeconds = 1
    $script:RetryWaits = @(0, 0)
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-Equal False (Get-ReaDownload -Url "$base/slow" -Destination (Join-Path $nn 'file') -Sha256 $payloadSha) 'n: returns false'
        $watch.Stop()
    } finally {
        $script:ReadWriteTimeoutMs = $savedTimeout
        $script:StallSeconds = $savedWindow
        $script:RetryWaits = $savedWaits
    }
    Assert-That ($watch.Elapsed.TotalSeconds -lt 20) 'n: aborted well before the server released the connection'
    Assert-Equal 2 (Get-Count '/slow') 'n: a stall is retried'
    Assert-Equal 0 (Get-OtherFile $nn '').Count 'n: no DEST and no DEST.tmp.*'
    Close-Scenario
} finally {
    if ($null -ne $server) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        $server.WaitForExit(5000) | Out-Null
    }
    Clear-ReaTempFiles
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    [Console]::Error.WriteLine("run-win.ps1: $($script:Failures) assertion(s) failed")
    exit 1
}
