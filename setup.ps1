# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

<#
.SYNOPSIS
Takes a stock Windows machine to a running clavity-ls session with morluto/rea registered in an isolated
agent-profile Claude profile. The PowerShell twin of setup.sh; Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProfileName = 'rea',
    [string]$Folder = (Get-Location).ProviderPath,
    [string]$GhidraDir = $env:GHIDRA_INSTALL_DIR,
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$ToolsDir = '',
    [string]$BinDir = '',
    [switch]$InstallHopper,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$NoLaunch,
    [switch]$CheckUpstream,
    [switch]$Quiet,
    [string]$LogDir = ''
)

# The POSIX set -eu counterpart: a non-terminating cmdlet error must not cascade into later steps.
$ErrorActionPreference = 'Stop'

# --- pins begin ---
$script:PIN_SCRIPT_VERSION = '0.1.0'
$script:PIN_GHIDRA_VERSION = '12.1.4'
$script:PIN_GHIDRA_TOPDIR = 'ghidra_12.1.4_PUBLIC'
$script:PIN_GHIDRA_URL = 'https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip'
$script:PIN_GHIDRA_SHA256 = 'ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db'
$script:PIN_GHIDRA_ZIP_BYTES = '569649598'
$script:PIN_GHIDRA_UNPACKED_MB = '882'
$script:PIN_JDK_MAJOR = '21'
$script:PIN_JDK_UNPACKED_MB = '346'
$script:PIN_JDK_FALLBACK_RELEASE = 'jdk-21.0.13+9'
$script:PIN_JDK_FALLBACK_LINUX_X64 = 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz:d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c'
$script:PIN_JDK_FALLBACK_MAC_X64 = 'OpenJDK21U-jdk_x64_mac_hotspot_21.0.13_9.tar.gz:9aa1d1c17ae5467a022679e7e0af5c00797d94ac462ed1a46f4db07a8a34a6dd'
$script:PIN_JDK_FALLBACK_MAC_AARCH64 = 'OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz:bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a'
$script:PIN_JDK_FALLBACK_WINDOWS_X64 = 'OpenJDK21U-jdk_x64_windows_hotspot_21.0.13_9.zip:a4dbaa05fca4bd89d84584e58c459bd732efebb1722af80ab13c6516832004f9'
$script:PIN_JDK_FALLBACK_URL_BASE = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/'
$script:PIN_AGENT_PROFILE_REPO = 'ckir/aiprofiles'
$script:PIN_CLAVITY_REPO = 'ckir/clavity'
$script:PIN_REA_SPEC = 'rea-agents@latest'
$script:PIN_ALLOWED_HOSTS = 'github.com api.github.com release-assets.githubusercontent.com api.adoptium.net registry.npmjs.org raw.githubusercontent.com'
# --- pins end ---

$script:EX_OK = 0
$script:EX_STEP = 1
$script:EX_USAGE = 2
$script:EX_PLATFORM = 3
$script:EX_PREREQ = 4
$script:EX_VERIFY = 5

# The SHA-256 of this script file, or n/a when it cannot be read (dot-sourced from a string, no file).
function Get-ReaScriptHash {
    try {
        if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
            return (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } catch {
        return 'n/a'
    }
    return 'n/a'
}

# The bound parameters, captured once so every function reads one object instead of the caller's scope.
$script:Opt = [pscustomobject]@{
    ProfileName   = $ProfileName
    Folder        = $Folder
    GhidraDir     = $GhidraDir
    JavaHome      = $JavaHome
    ToolsDir      = $ToolsDir
    BinDir        = $BinDir
    InstallHopper = $InstallHopper.IsPresent
    Yes           = $Yes.IsPresent
    DryRun        = $DryRun.IsPresent
    NoLaunch      = $NoLaunch.IsPresent
    CheckUpstream = $CheckUpstream.IsPresent
    Quiet         = $Quiet.IsPresent
    LogDir        = $LogDir
}

$script:Bound = $PSBoundParameters

$script:ConsoleLevel = 'INFO'
$script:LogFile = $null
$script:OptYes = $false

# --- logging ---

# Rank of a level: 0..3 for DEBUG INFO WARN ERROR; an unknown level ranks as INFO.
function Get-ReaLevelRank {
    param([string]$Level)
    switch ($Level) {
        'DEBUG' { return 0 }
        'INFO' { return 1 }
        'WARN' { return 2 }
        'ERROR' { return 3 }
        default { return 1 }
    }
}

# True when a line of this level reaches the console at the given threshold.
function Test-ReaLogVisible {
    param(
        [string]$Level,
        [string]$Threshold = $script:ConsoleLevel
    )
    return ((Get-ReaLevelRank $Level) -ge (Get-ReaLevelRank $Threshold))
}

# The one log line: <UTC ISO-8601>Z LEVEL [step] message, LEVEL padded to 5. Timestamp is for tests.
function Format-ReaLogLine {
    param(
        [string]$Level,
        [string]$Step,
        [string]$Message,
        [string]$Timestamp = ''
    )
    if (-not $Timestamp) {
        $Timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ('{0} {1} [{2}] {3}' -f $Timestamp, $Level.PadRight(5), $Step, $Message)
}

# Secret names: TOKEN, KEY, SECRET or PASSWORD in any case, and for the JSON and colon forms AUTHORIZATION too.
$script:ReaRxNameBasic = New-Object System.Text.RegularExpressions.Regex 'TOKEN|KEY|SECRET|PASSWORD', 'IgnoreCase'
$script:ReaRxNameAuth = New-Object System.Text.RegularExpressions.Regex 'TOKEN|KEY|SECRET|PASSWORD|AUTHORIZATION', 'IgnoreCase'

$script:ReaRxNameAuthOnly = New-Object System.Text.RegularExpressions.Regex 'AUTHORIZATION', 'IgnoreCase'
$script:ReaRxAuthEquals = New-Object System.Text.RegularExpressions.Regex '(?<![A-Za-z0-9_-])([A-Za-z0-9_-]+)[ ]*=[ ]*'
$script:ReaRxEquals = New-Object System.Text.RegularExpressions.Regex '(?<![A-Za-z0-9_])([A-Za-z0-9_]+)[ ]*=[ ]*'
$script:ReaRxEqualsValue = New-Object System.Text.RegularExpressions.Regex "\G(`"[^`"\n]*`"[^ \n]*|'[^'\n]*'[^ \n]*|[^ \n]*)"
$script:ReaRxJsonKey = New-Object System.Text.RegularExpressions.Regex '"([A-Za-z0-9_.-]+)"[ ]*:[ ]*'
$script:ReaRxJsonValue = New-Object System.Text.RegularExpressions.Regex '\G("(?:[^"\\\n]|\\.)*"?|[A-Za-z0-9_.+-]+)'
$script:ReaRxColon = New-Object System.Text.RegularExpressions.Regex '(?<![A-Za-z0-9_-])([A-Za-z0-9_-]+)([ ]*:)'
$script:ReaRxColonValue = New-Object System.Text.RegularExpressions.Regex '\G[^\n]*'

# One redaction rule. Find locates candidates (Group 1 is the name); a candidate whose name is secret has the value
# that Take matches right behind it replaced, any other is copied and the scan goes on behind it. The scan visits
# each character once (no pattern here backtracks over a long run), where one pattern with the name inside the
# word took seconds on 200000 characters. Mode: authequals, equals, json or colon.
function Edit-ReaSecretRule {
    param([string]$Text, $Find, $Take, [string]$Mode)
    $out = New-Object System.Text.StringBuilder
    $pos = 0
    $names = $script:ReaRxNameAuth
    if ($Mode -eq 'equals') { $names = $script:ReaRxNameBasic }
    if ($Mode -eq 'authequals') { $names = $script:ReaRxNameAuthOnly }
    while ($pos -le $Text.Length) {
        $m = $Find.Match($Text, $pos)
        if (-not $m.Success) { break }
        $end = $m.Index + $m.Length
        $secret = $names.IsMatch($m.Groups[1].Value)
        $v = $null
        if ($secret) { $v = $Take.Match($Text, $end) }
        if ($secret -and $v.Success) {
            [void]$out.Append($Text, $pos, $m.Index - $pos)
            if ($Mode -eq 'equals' -or $Mode -eq 'authequals') {
                [void]$out.Append($m.Value + '<redacted>')
            } elseif ($Mode -eq 'colon') {
                [void]$out.Append($m.Groups[1].Value + $m.Groups[2].Value + ' <redacted>')
            } elseif ($v.Value.StartsWith('"')) {
                [void]$out.Append($m.Value + '"<redacted>"')
            } else {
                [void]$out.Append($m.Value + '<redacted>')
            }
            $pos = $end + $v.Length
        } else {
            [void]$out.Append($Text, $pos, $end - $pos)
            $pos = $end
        }
    }
    if ($pos -lt $Text.Length) { [void]$out.Append($Text, $pos, $Text.Length - $pos) }
    return $out.ToString()
}

# Hides secrets in a log message, line by line, in the order of setup.sh redact (tests/fixtures/redact-corpus.txt
# pins both): URL userinfo and query; AUTHORIZATION=value to the end of the line; NAME = value (optional spaces
# around the equals sign, quoted values consumed whole); "NAME": value in JSON form
# (strings with escaped quotes, numbers, true, false, null); NAME: value to the end of the line. NAME contains
# TOKEN, KEY, SECRET or PASSWORD, and for the JSON and colon forms also AUTHORIZATION, any case. A JSON value that
# is an object or an array is left alone.
function Hide-ReaSecret {
    param([AllowEmptyString()][string]$Text)
    $r = $Text -replace '(https?://)[^/@ \n]*@', '${1}'
    $r = $r -replace '\?(?<=https?://[^ ?\n]*\?)[^ \n]*', ''
    $r = Edit-ReaSecretRule -Text $r -Find $script:ReaRxAuthEquals -Take $script:ReaRxColonValue -Mode authequals
    $r = Edit-ReaSecretRule -Text $r -Find $script:ReaRxEquals -Take $script:ReaRxEqualsValue -Mode equals
    $r = Edit-ReaSecretRule -Text $r -Find $script:ReaRxJsonKey -Take $script:ReaRxJsonValue -Mode json
    $r = Edit-ReaSecretRule -Text $r -Find $script:ReaRxColon -Take $script:ReaRxColonValue -Mode colon
    return $r
}

# True when Path is Home or lies under it (either separator, case-insensitive on every platform).
function Test-ReaUnderHome {
    param([string]$Path, [string]$HomeDir)
    if ($Path.Equals($HomeDir, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Path.Length -le $HomeDir.Length) { return $false }
    if (-not $Path.StartsWith($HomeDir, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $c = $Path[$HomeDir.Length]
    return ($c -eq '\' -or $c -eq '/')
}

# PATH with the home directory as %USERPROFILE% (nothing when the home directory is empty).
function Get-ReaShortPath {
    param([AllowEmptyString()][string]$Path)
    $homeDir = $env:USERPROFILE
    if (-not $homeDir) { return $Path }
    $homeDir = $homeDir.TrimEnd('\', '/')
    if (-not $homeDir) { return $Path }
    if (Test-ReaUnderHome -Path $Path -HomeDir $homeDir) {
        return ('%USERPROFILE%' + $Path.Substring($homeDir.Length))
    }
    return $Path
}

# Replaces the home directory inside free text with %USERPROFILE% (whole path components only).
function Convert-ReaHomeText {
    param([AllowEmptyString()][string]$Text)
    $homeDir = $env:USERPROFILE
    if (-not $homeDir) { return $Text }
    $homeDir = $homeDir.TrimEnd('\', '/')
    if (-not $homeDir) { return $Text }
    # The path also appears JSON-escaped (doubled backslashes, in rea doctor --json) and with forward slashes.
    $forms = @($homeDir.Replace('\', '\\'), $homeDir.Replace('\', '/'), $homeDir) | Select-Object -Unique
    foreach ($form in $forms) {
        $pattern = '(^|[^A-Za-z0-9._/\\-])' + [regex]::Escape($form) + '(?=$|[\\/]|[^A-Za-z0-9._-])'
        $Text = [regex]::Replace($Text, $pattern, '${1}%USERPROFILE%', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $Text
}

# Prints a warning on stderr; one function so tests can capture it.
function Write-ReaWarning {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

# The file always gets the line; stderr gets it when LEVEL >= the console level.
function Write-ReaLog {
    param(
        [string]$Level,
        [string]$Step,
        [string]$Message
    )
    $line = Format-ReaLogLine -Level $Level -Step $Step -Message (Convert-ReaHomeText (Hide-ReaSecret $Message))
    if ($script:LogFile) {
        try {
            [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false))
        } catch {
            $script:LogFile = $null
            Write-ReaWarning 'warning: cannot write the log file; continuing without one'
        }
    }
    if (Test-ReaLogVisible -Level $Level) {
        [Console]::Error.WriteLine($line)
    }
}

# Logs ERROR with the log path, then throws; Invoke-Main turns the exception into the exit code (a function
# cannot exit the host, so Stop-Rea is the die counterpart).
function Stop-Rea {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
    param(
        [int]$Code,
        [string]$Step,
        [string]$Message
    )
    # The Stop verb makes the analyzer demand ShouldProcess; Stop-Rea changes no system state, so the answer is
    # ignored and it always stops.
    $null = $PSCmdlet.ShouldProcess($Step, 'stop the setup')
    Write-ReaLog -Level ERROR -Step $Step -Message $Message
    if ($script:LogFile) {
        Write-ReaLog -Level ERROR -Step $Step -Message ('details: ' + (Get-ReaShortPath $script:LogFile))
    }
    $ex = New-Object System.InvalidOperationException $Message
    $ex.Data['ReaCode'] = $Code
    throw $ex
}

# Quotes one argument for a Windows command line.
function ConvertTo-ReaQuotedArgument {
    param([AllowEmptyString()][string]$Argument)
    if ($Argument -eq '') { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return ('"' + $escaped + '"')
}

# Runs a program, logging the argument list, exit code and duration. Returns ExitCode, Stdout, Stderr; the
# stderr text goes to the log (bounded to 4000 characters on failure).
function Invoke-ReaCommand {
    param(
        [string]$Step,
        [string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $quoted = @($ArgumentList | ForEach-Object { ConvertTo-ReaQuotedArgument $_ })
    Write-ReaLog -Level DEBUG -Step $Step -Message ('run: ' + $FilePath + ' ' + ($quoted -join ' '))
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $params = @{
            FilePath               = $FilePath
            Wait                   = $true
            PassThru               = $true
            NoNewWindow            = $true
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
        }
        if ($quoted.Count -gt 0) { $params['ArgumentList'] = $quoted }
        $proc = Start-Process @params
        $code = $proc.ExitCode
        $watch.Stop()
        $stdout = [System.IO.File]::ReadAllText($outFile)
        $stderr = [System.IO.File]::ReadAllText($errFile)
        Write-ReaLog -Level DEBUG -Step $Step -Message ('exit {0} after {1}s' -f $code, [int]$watch.Elapsed.TotalSeconds)
        if ($code -ne 0) {
            if ($stderr.Length -gt 4000) { $stderr = $stderr.Substring(0, 4000) }
            Write-ReaLog -Level DEBUG -Step $Step -Message ('stderr: ' + $stderr)
        }
        return [pscustomobject]@{ ExitCode = $code; Stdout = $stdout; Stderr = $stderr }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# Creates the log directory and file, keeps the newest 20, returns the file path ($null without a log).
function Open-ReaLog {
    param([string]$Directory = '')
    if (-not $Directory) {
        $base = Get-ReaLocalAppData
        $Directory = Join-Path (Join-Path $base 'rea-setup') 'logs'
    }
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $file = Join-Path $Directory ('setup-{0}-{1}.log' -f $stamp, $PID)
    try {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        [System.IO.File]::AppendAllText($file, '', (New-Object System.Text.UTF8Encoding $false))
    } catch {
        Write-ReaWarning "warning: cannot create a log file in $(Get-ReaShortPath $Directory); continuing without one"
        $script:LogFile = $null
        return $null
    }
    # Names sort oldest first (UTC timestamp), so drop all but the last 20.
    $logs = @(Get-ChildItem -LiteralPath $Directory -Filter 'setup-*.log' -File | Sort-Object Name)
    if ($logs.Count -gt 20) {
        $logs | Select-Object -First ($logs.Count - 20) | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $script:LogFile = $file
    return $file
}

# --- platform ---

# The OS architecture as RuntimeInformation names it (X64, Arm64, X86, ...). That type needs .NET Framework
# 4.7.1; on an older one this throws and Get-ReaPlatform falls back to the environment.
function Get-ReaRuntimeArchitecture {
    return [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
}

# The OS architecture from PROCESSOR_ARCHITEW6432 (set for a 32-bit process on 64-bit Windows, and then the
# real one) else PROCESSOR_ARCHITECTURE: X64, Arm64, another value lower-cased, or 'unknown' when both are empty.
function Get-ReaEnvArchitecture {
    param(
        [AllowEmptyString()][string]$Wow64 = $env:PROCESSOR_ARCHITEW6432,
        [AllowEmptyString()][string]$Native = $env:PROCESSOR_ARCHITECTURE
    )
    $raw = $Wow64
    if (-not $raw) { $raw = $Native }
    if (-not $raw) { return 'unknown' }
    switch ($raw.ToLowerInvariant()) {
        'amd64' { return 'X64' }
        'arm64' { return 'Arm64' }
        default { return $raw.ToLowerInvariant() }
    }
}

# @{ Os = 'windows'; Arch = 'x64' | 'aarch64' | <anything else, lower-cased: unsupported> }. Architecture is for
# tests.
function Get-ReaPlatform {
    param([string]$Architecture = '')
    if (-not $Architecture) {
        try {
            $Architecture = Get-ReaRuntimeArchitecture
        } catch {
            $Architecture = Get-ReaEnvArchitecture
        }
    }
    switch ($Architecture.ToLowerInvariant()) {
        'x64' { $arch = 'x64' }
        'arm64' { $arch = 'aarch64' }
        default { $arch = $Architecture.ToLowerInvariant() }
    }
    return @{ Os = 'windows'; Arch = $arch }
}

# --- validation ---

# agent-profile's naming rules.
function Test-ReaProfileName {
    param([AllowEmptyString()][string]$Name)
    if (-not $Name) { return $false }
    # \z, not $: a trailing newline must not pass.
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\z') { return $false }
    if ($Name.EndsWith('.')) { return $false }
    $lower = $Name.ToLowerInvariant()
    $reserved = 'agents', 'profiles', 'status', 'list', 'create', 'delete', 'current', 'resolve', 'doctor', 'link', 'unlink', 'repositories', 'completions'
    if ($reserved -contains $lower) { return $false }
    $stem = $lower.Split('.')[0]
    if ($stem -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])$') { return $false }
    return $true
}

# The first X.Y.Z in TEXT, or $null.
function Get-ReaSemver {
    param([AllowEmptyString()][string]$Text)
    $m = [regex]::Match($Text, '[0-9]+\.[0-9]+\.[0-9]+')
    if ($m.Success) { return $m.Value }
    return $null
}

# The Nth (0-2) numeric component's leading digits; a missing or non-numeric one counts as 0.
function Get-ReaSemverPart {
    param([string]$Version, [int]$Index)
    $parts = $Version.Split('.')
    if ($Index -ge $parts.Length) { return [int64]0 }
    $m = [regex]::Match($parts[$Index], '^[0-9]+')
    if ($m.Success) { return [int64]$m.Value }
    return [int64]0
}

# -1, 0 or 1, comparing the leading numeric X.Y.Z only.
function Compare-ReaSemver {
    param([string]$A, [string]$B)
    foreach ($i in 0..2) {
        $x = Get-ReaSemverPart -Version $A -Index $i
        $y = Get-ReaSemverPart -Version $B -Index $i
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

# True for v22.x >= 22.23.4, v24.x >= 24.22.1 or >= 26.12.1.
function Test-ReaNodeVersion {
    param([string]$Version)
    $v = $Version
    if ($v.StartsWith('v')) { $v = $v.Substring(1) }
    $m = [regex]::Match($v, '^[0-9]+')
    if (-not $m.Success) { return $false }
    $major = [int64]$m.Value
    if ($major -eq 22) { $floor = '22.23.4' }
    elseif ($major -eq 24) { $floor = '24.22.1' }
    elseif ($major -gt 26) { return $true }
    elseif ($major -eq 26) { $floor = '26.12.1' }
    else { return $false }
    return ((Compare-ReaSemver $v $floor) -ge 0)
}

# True when a person can answer a prompt.
function Test-ReaInteractive {
    return (-not [Console]::IsInputRedirected)
}

# True under -Yes; refuses (exit 2) without a terminal; else reads one line.
function Read-ReaConfirm {
    param([string]$Prompt)
    if ($script:OptYes) { return $true }
    if (-not (Test-ReaInteractive)) {
        Stop-Rea -Code $script:EX_USAGE -Step confirm -Message "no terminal to ask '$Prompt' on; re-run with -Yes"
    }
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -eq 'y' -or $answer -eq 'Y')
}

# --- network ---

# Test seams: the allow-lists, the pauses between attempts and the stall limits are script-scope values so a
# test can replace them. The waits give the pause before each retry, so they also set the number of attempts.
$script:AllowedSchemes = @('https')
$script:AllowedHosts = @($script:PIN_ALLOWED_HOSTS -split ' ' | Where-Object { $_ })
$script:RetryWaits = @(2, 4, 8, 16)
$script:ReadWriteTimeoutMs = 60000
$script:StallSeconds = 60
$script:StallMinBytes = 1024
$script:TempFiles = New-Object System.Collections.Generic.List[string]

# Makes sure TLS 1.2 is offered (Windows PowerShell 5.1 does not by default).
function Initialize-ReaNetwork {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Pauses between retries; one function so tests can replace it.
function Invoke-ReaSleep {
    param([int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

# Pauses of a fraction of a second between the retries of a move; one function so tests can replace it.
function Invoke-ReaSleepMs {
    param([int]$Milliseconds)
    Start-Sleep -Milliseconds $Milliseconds
}

# Move-Item that tries again when it fails: Windows Defender and the indexer open freshly extracted or
# downloaded files, and renaming a directory that holds an open handle fails with access denied until they let
# go. Ten attempts with a pause that grows from 0.5 s to 2 s; the last failure is thrown.
function Move-ReaItemRetry {
    param([string]$Path, [string]$Destination, [switch]$Force, [int]$Attempts = 10)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Move-Item -LiteralPath $Path -Destination $Destination -Force:$Force -ErrorAction Stop
            return
        } catch {
            if ($i -ge $Attempts) { throw }
            Write-ReaLog DEBUG move ("move failed (attempt $i of ${Attempts}): " + $_.Exception.Message)
            Invoke-ReaSleepMs -Milliseconds ([Math]::Min(2000, 500 + 150 * ($i - 1)))
        }
    }
}

# --- temporary files ---

# Remembers a file or directory for Clear-ReaTempFile. A finally block covers an ordinary failure; this list is
# for Invoke-Main's finally, which is the last chance when a step is interrupted from outside.
function Register-ReaTempFile {
    param([string]$Path)
    $script:TempFiles.Add($Path)
}

# Deletes one file, link or directory tree without ever following a link. A symlink, junction or other reparse
# point is deleted as the link it is (its target is untouched); only real directories are descended into;
# read-only attributes are cleared first. Throws when something cannot be deleted; a missing path is not an error.
function Clear-ReaTreeItem {
    param([string]$Path)
    try {
        $attr = [System.IO.File]::GetAttributes($Path)
    } catch {
        return
    }
    $isDir = (($attr -band [System.IO.FileAttributes]::Directory) -ne 0)
    $isLink = (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    if ($isLink) {
        if ($isDir) {
            try {
                [System.IO.Directory]::Delete($Path, $false)
            } catch {
                [System.IO.File]::Delete($Path)
            }
        } else {
            [System.IO.File]::Delete($Path)
        }
        return
    }
    if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
        [System.IO.File]::SetAttributes($Path, ($attr -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
    }
    if ($isDir) {
        foreach ($child in [System.IO.Directory]::GetFileSystemEntries($Path)) {
            Clear-ReaTreeItem -Path $child
        }
        [System.IO.Directory]::Delete($Path, $false)
    } else {
        [System.IO.File]::Delete($Path)
    }
}

# Removes Path (a file, a link or a tree) as Clear-ReaTreeItem does; the one deletion routine of this script.
function Remove-ReaTree {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'remove')) { return }
    Clear-ReaTreeItem -Path $Path
}

# Removes every registered path, or only -Path; safe to call again and with an empty list. Names are literal
# (no wildcard expansion) and links are never followed.
function Clear-ReaTempFile {
    param([string]$Path = '')
    if ($Path) {
        try { Remove-ReaTree -Path $Path } catch { Write-Verbose "cannot remove $Path" }
        while ($script:TempFiles.Remove($Path)) { continue }
        return
    }
    foreach ($p in @($script:TempFiles)) {
        try { Remove-ReaTree -Path $p } catch { Write-Verbose "cannot remove $p" }
    }
    $script:TempFiles.Clear()
}

# The brief names three of these functions with a plural noun, which PSScriptAnalyzer's PSUseSingularNouns
# rejects (and a suppression is not allowed), so each is defined with a singular noun and the plural name is an
# alias for it. Inside this file the singular names are used; both work for a caller. A test that mocks one of
# them must Mock the singular name: the code calls that, and a mock of the alias would not be seen.
Set-Alias -Name Clear-ReaTempFiles -Value Clear-ReaTempFile
Set-Alias -Name Resolve-ReaRedirects -Value Resolve-ReaRedirect
Set-Alias -Name Get-ReaGitHubReleaseAssets -Value Get-ReaGitHubReleaseAsset

# --- URL rules ---

# The lower-cased host of URL, without userinfo or port ($null without a scheme://).
function Get-ReaUrlHost {
    param([AllowEmptyString()][string]$Url)
    $m = [regex]::Match($Url, '^.*?://([^/?#]*)')
    if (-not $m.Success) { return $null }
    $authority = $m.Groups[1].Value
    $at = $authority.LastIndexOf('@')
    if ($at -ge 0) { $authority = $authority.Substring($at + 1) }
    $colon = $authority.IndexOf(':')
    if ($colon -ge 0) { $authority = $authority.Substring(0, $colon) }
    return $authority.ToLowerInvariant()
}

# True when the scheme is in $script:AllowedSchemes, the host in $script:AllowedHosts and the authority carries
# no userinfo; whitespace and backslashes are refused outright. A trailing-dot host is not in the list.
function Test-ReaUrlAllowed {
    param([AllowEmptyString()][string]$Url)
    if ($Url -match '[\s\\]') { return $false }
    $m = [regex]::Match($Url, '^(.*?)://([^/?#]*)')
    if (-not $m.Success) { return $false }
    if ($script:AllowedSchemes -notcontains $m.Groups[1].Value.ToLowerInvariant()) { return $false }
    if ($m.Groups[2].Value.Contains('@')) { return $false }
    return ($script:AllowedHosts -contains (Get-ReaUrlHost $Url))
}

# False when the URL has a dot-dot path segment (plain or percent-encoded) or a backslash.
function Test-ReaUrlPathSafe {
    param([string]$Url)
    if ($Url -match '/\.\.(/|\?|$)') { return $false }
    if ($Url -match '%2[eE]') { return $false }
    if ($Url.Contains('\')) { return $false }
    return $true
}

# --- transport ---

# A web request with redirects off (every hop is checked by Resolve-ReaRedirect) and the timeouts set.
function New-ReaWebRequest {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
    param([string]$Url, [string]$Method)
    $null = $PSCmdlet.ShouldProcess($Url, 'create a web request')
    Initialize-ReaNetwork
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
    $req.Method = $Method
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'rea-setup/' + $script:PIN_SCRIPT_VERSION
    $req.Timeout = 60000
    $req.ReadWriteTimeout = $script:ReadWriteTimeoutMs
    $req.KeepAlive = $false
    # A corporate proxy may answer 407 and expect the signed-in user's credentials.
    if ($null -ne $req.Proxy) {
        try {
            $req.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        } catch {
            Write-ReaLog DEBUG net ('proxy credentials not set: ' + $_.Exception.Message)
        }
    }
    return $req
}

# The message of the real cause: an AggregateException (from Task.Wait) is replaced by its first inner exception.
function Get-ReaRootMessage {
    param($Exception)
    return (Get-ReaRootException $Exception).Message
}

# The exception behind the wrappers: an AggregateException (Task.Wait) and a MethodInvocationException (any .NET
# method that throws inside an untyped catch) are replaced by their inner exception.
function Get-ReaRootException {
    param($Exception)
    while ($null -ne $Exception -and $null -ne $Exception.InnerException -and
        ($Exception -is [System.AggregateException] -or $Exception -is [System.Management.Automation.MethodInvocationException])) {
        $Exception = $Exception.InnerException
    }
    return $Exception
}

# True for a failure worth another attempt: connection, name-resolution, timeout and broken-transfer errors. A
# certificate failure or anything unrecognised is not.
function Test-ReaTransientError {
    param($Exception)
    $Exception = Get-ReaRootException $Exception
    if ($Exception -is [System.Net.WebException]) {
        $transient = 'ConnectFailure', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'Timeout', 'ConnectionClosed', 'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'KeepAliveFailure'
        return ($transient -contains $Exception.Status.ToString())
    }
    return (($Exception -is [System.IO.IOException]) -or ($Exception -is [System.TimeoutException]))
}

# One HEAD (Method HEAD) or one-byte ranged GET (Method RANGE) without following redirects. Returns Status (0
# when there was no HTTP answer), Location, ContentLength (-1 when unknown), ContentRange and Error. A non-2xx answer arrives as a WebException carrying the
# response, so it is read from there.
function Send-ReaHeadRequest {
    param(
        [string]$Url,
        [ValidateSet('HEAD', 'RANGE')][string]$Method = 'HEAD'
    )
    $result = [pscustomobject]@{ Status = 0; Location = $null; Error = ''; ContentLength = [int64]-1; ContentRange = $null; Retryable = $false }
    $resp = $null
    try {
        if ($Method -eq 'RANGE') {
            $req = New-ReaWebRequest -Url $Url -Method 'GET'
            $req.AddRange(0, 0)
        } else {
            $req = New-ReaWebRequest -Url $Url -Method 'HEAD'
        }
        try {
            $resp = $req.GetResponse()
        } catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if ($null -eq $resp) {
                $result.Error = $_.Exception.Message
                $result.Retryable = Test-ReaTransientError $_.Exception
                return $result
            }
        }
        $result.Status = [int]$resp.StatusCode
        $result.Location = $resp.Headers['Location']
        $result.ContentLength = [int64]$resp.ContentLength
        $result.ContentRange = $resp.Headers['Content-Range']
    } catch {
        $result.Error = $_.Exception.Message
        $result.Retryable = Test-ReaTransientError $_.Exception
    } finally {
        if ($null -ne $resp) { $resp.Close() }
    }
    return $result
}

# Send-ReaHeadRequest with the retries Invoke-ReaHttpGet has: 5xx, 429 and a retryable transport failure are
# tried again after the pauses in $script:RetryWaits (so they also set the number of attempts); any other
# answer is returned at once.
function Invoke-ReaHeadRetry {
    param(
        [string]$Url,
        [ValidateSet('HEAD', 'RANGE')][string]$Method = 'HEAD'
    )
    $waits = @($script:RetryWaits)
    $total = $waits.Count
    $r = $null
    for ($attempt = 1; $attempt -le $total; $attempt++) {
        $r = Send-ReaHeadRequest -Url $Url -Method $Method
        if ($r.Error) { Write-ReaLog DEBUG net ("transport ($Method $Url, attempt $attempt of ${total}): " + $r.Error) }
        $retry = $false
        if ($r.Status -eq 429 -or ($r.Status -ge 500 -and $r.Status -le 599)) {
            $retry = $true
        } elseif ($r.Status -eq 0 -and $null -ne $r.PSObject.Properties['Retryable'] -and $r.Retryable) {
            $retry = $true
        }
        if (-not $retry -or $attempt -ge $total) { break }
        $wait = [int]$waits[$attempt - 1]
        if ($wait -gt 120) { $wait = 120 }
        Write-ReaLog DEBUG net "retrying in ${wait}s"
        Invoke-ReaSleep -Seconds $wait
    }
    return $r
}

# The leading digits of a Retry-After value, or $null when there are none or more than six (so the number can
# never overflow). The HTTP-date form is not honoured.
function Get-ReaRetryAfter {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if (-not $Value) { return $null }
    $m = [regex]::Match($Value, '^\s*([0-9]+)')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Value.Length -gt 6) { return $null }
    return [int]$m.Groups[1].Value
}

# True when a window of the transfer moved fewer than the minimum number of bytes.
function Test-ReaStalled {
    param([int64]$WindowBytes)
    return ($WindowBytes -lt $script:StallMinBytes)
}

# One GET into Destination. Returns Status (the HTTP status once the body is complete; 0 for a transport failure,
# a stall or a short body), RetryAfter (the raw header), Retryable (whether another attempt may help) and Error.
# The body is copied in 64 KiB blocks; fewer than StallMinBytes in any StallSeconds window aborts the transfer.
# The token goes in the Authorization header of this one request and is never put in a message.
function Send-ReaHttpAttempt {
    param(
        [string]$Url,
        [string]$Destination,
        [AllowEmptyString()][string]$AuthToken = ''
    )
    $ProgressPreference = 'SilentlyContinue'
    $result = [pscustomobject]@{ Status = 0; RetryAfter = $null; Retryable = $false; Error = '' }
    $resp = $null
    $stream = $null
    $file = $null
    try {
        $req = New-ReaWebRequest -Url $Url -Method 'GET'
        if ($AuthToken) { $req.Headers.Add('Authorization', ('Bearer ' + $AuthToken)) }
        try {
            $resp = $req.GetResponse()
        } catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if ($null -eq $resp) {
                $result.Error = $_.Exception.Message
                $result.Retryable = Test-ReaTransientError $_.Exception
                return $result
            }
        }
        $status = [int]$resp.StatusCode
        $values = $resp.Headers.GetValues('Retry-After')
        if ($null -ne $values -and @($values).Count -gt 0) { $result.RetryAfter = @($values)[-1] }
        if ($status -lt 200 -or $status -gt 299) {
            $result.Status = $status
            return $result
        }
        $file = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream = $resp.GetResponseStream()
        $buffer = New-Object byte[] 65536
        $total = [int64]0
        $windowBytes = [int64]0
        $window = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            # A read with its own timeout: not every runtime lets the response stream carry one.
            $read = $stream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $read.Wait($script:ReadWriteTimeoutMs)) {
                throw (New-Object System.IO.IOException 'read timed out')
            }
            $n = $read.Result
            if ($n -le 0) { break }
            $file.Write($buffer, 0, $n)
            $total += $n
            $windowBytes += $n
            if ($window.Elapsed.TotalSeconds -ge $script:StallSeconds) {
                if (Test-ReaStalled -WindowBytes $windowBytes) {
                    throw (New-Object System.IO.IOException 'transfer stalled')
                }
                $windowBytes = 0
                $window.Restart()
            }
        }
        if ($resp.ContentLength -ge 0 -and $total -ne $resp.ContentLength) {
            $result.Error = "short body: $total of $($resp.ContentLength) bytes"
            return $result
        }
        $result.Status = $status
    } catch {
        $result.Status = 0
        $result.Error = (Get-ReaRootMessage $_.Exception)
        $result.Retryable = Test-ReaTransientError $_.Exception
    } finally {
        if ($null -ne $file) { $file.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $resp) { $resp.Close() }
    }
    return $result
}

# Resolves a Location header against the URL that answered. An absolute value is returned as sent, so the
# allow-list sees what the server wrote (a re-serialised URL could hide a backslash).
function Resolve-ReaLocation {
    param([string]$Base, [string]$Location)
    if ($Location -match '^[^:/?#]*://' -or $Location -match '[\s\\]') { return $Location }
    try {
        return (New-Object System.Uri((New-Object System.Uri $Base), $Location)).AbsoluteUri
    } catch {
        return $Location
    }
}

# Walks the redirects of URL with HEAD (no body is fetched), at most 5. A hop answering 405 or 403 to HEAD is
# asked again with a one-byte ranged GET. Every hop must pass Test-ReaUrlAllowed. Returns Code and Url: Code 0
# with the final URL, 1 for a disallowed hop, 2 for more than 5 redirects, 3 for any other failure.
function Resolve-ReaRedirect {
    param([string]$Url)
    $current = $Url
    $hops = 0
    while ($true) {
        if (-not (Test-ReaUrlAllowed $current)) {
            Write-ReaLog ERROR net "redirect target not allowed: $current"
            return [pscustomobject]@{ Code = 1; Url = $null }
        }
        $r = Invoke-ReaHeadRetry -Url $current -Method 'HEAD'
        if ($r.Status -eq 405 -or $r.Status -eq 403) {
            $r = Invoke-ReaHeadRetry -Url $current -Method 'RANGE'
        }
        Write-ReaLog DEBUG net "HEAD $current -> $($r.Status)"
        if ($r.Status -ge 200 -and $r.Status -le 299) {
            return [pscustomobject]@{ Code = 0; Url = $current }
        }
        if ($r.Status -ge 300 -and $r.Status -le 399 -and $r.Location) {
            $hops++
            if ($hops -gt 5) {
                Write-ReaLog ERROR net "more than 5 redirects from $Url"
                return [pscustomobject]@{ Code = 2; Url = $null }
            }
            $current = Resolve-ReaLocation -Base $current -Location $r.Location
            continue
        }
        return [pscustomobject]@{ Code = 3; Url = $null }
    }
}

# GET into Destination with retries; $true on 2xx. 5xx, 429 and retryable transport errors are retried
# ($script:RetryWaits gives the pause before each retry, so it also sets the number of attempts; Retry-After
# raises the pause, up to 120 seconds); any other failure returns $false at once. GITHUB_TOKEN goes to
# api.github.com only and is ignored, with a warning, unless it is plain token characters. The destination is
# removed on failure.
function Invoke-ReaHttpGet {
    param(
        [string]$Url,
        [string]$Destination
    )
    $ProgressPreference = 'SilentlyContinue'
    if (-not (Test-ReaUrlAllowed $Url)) {
        Write-ReaLog ERROR net "URL not allowed: $Url"
        return $false
    }
    $token = ''
    $env_token = $env:GITHUB_TOKEN
    if ($env_token -and (Get-ReaUrlHost $Url) -ceq 'api.github.com') {
        if ($env_token -match '^[A-Za-z0-9_.-]+\z') {
            $token = $env_token
        } else {
            Write-ReaLog WARN net 'GITHUB_TOKEN ignored: unexpected characters'
        }
    }
    $waits = @($script:RetryWaits)
    $total = $waits.Count
    $ok = $false
    for ($attempt = 1; $attempt -le $total; $attempt++) {
        $r = Send-ReaHttpAttempt -Url $Url -Destination $Destination -AuthToken $token
        Write-ReaLog DEBUG net "GET $Url -> $($r.Status) (attempt $attempt of $total)"
        if ($r.Error) { Write-ReaLog DEBUG net ('transport: ' + $r.Error) }
        $retry = $false
        if ($r.Status -ge 200 -and $r.Status -le 299) {
            $ok = $true
            break
        } elseif ($r.Status -eq 429 -or ($r.Status -ge 500 -and $r.Status -le 599)) {
            $retry = $true
        } elseif ($r.Status -eq 0 -and $r.Retryable) {
            $retry = $true
        }
        if (-not $retry -or $attempt -ge $total) { break }
        $wait = [int]$waits[$attempt - 1]
        $ra = Get-ReaRetryAfter $r.RetryAfter
        if ($null -ne $ra -and $ra -gt $wait) { $wait = $ra }
        if ($wait -gt 120) { $wait = 120 }
        Write-ReaLog DEBUG net "retrying in ${wait}s"
        Invoke-ReaSleep -Seconds $wait
    }
    if (-not $ok) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        Write-ReaLog ERROR net "GET failed: $Url"
    }
    return $ok
}

# --- checksums ---

# The lower-case SHA-256 of a file.
function Get-ReaFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# The first 64-hex token of a .sha256 sidecar, lower-cased (sha256sum, shasum and PowerShell layouts); $null when
# there is none.
function Get-ReaSidecarSha256 {
    param([string]$Path)
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $m = [regex]::Match($line, '^\s*([0-9A-Fa-f]{64})([^0-9A-Fa-f].*)?$')
        if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    }
    return $null
}

# Resolves the redirects, downloads to Destination.tmp.<pid>, checks the digest (case-insensitive) and only then
# moves the file to Destination. $true on success. A failure, an exception or Ctrl-C leaves nothing behind (the
# finally block removes the temporary); a killed process or a power loss can leave Destination.tmp.<pid>, which
# the orphan cleanup in the later setup steps removes.
function Get-ReaDownload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256
    )
    $resolved = Resolve-ReaRedirect -Url $Url
    if ($resolved.Code -ne 0) {
        Write-ReaLog ERROR net "cannot resolve $Url"
        return $false
    }
    $tmp = $Destination + '.tmp.' + $PID
    Register-ReaTempFile $tmp
    try {
        if (-not (Invoke-ReaHttpGet -Url $resolved.Url -Destination $tmp)) { return $false }
        $got = Get-ReaFileSha256 $tmp
        $want = $Sha256.ToLowerInvariant()
        if ($got -cne $want) {
            Write-ReaLog ERROR net "checksum mismatch for ${Url}: expected $want got $got"
            return $false
        }
        Move-ReaItemRetry -Path $tmp -Destination $Destination -Force
        return $true
    } finally {
        Clear-ReaTempFile -Path $tmp
    }
}

# --- GitHub and Adoptium ---

# The tag of the latest release of Repo, from the redirect of /releases/latest; $null when there is none.
function Get-ReaGitHubLatestTag {
    param([string]$Repo)
    $url = "https://github.com/$Repo/releases/latest"
    if (-not (Test-ReaUrlAllowed $url)) { return $null }
    $r = Invoke-ReaHeadRetry -Url $url -Method 'HEAD'
    Write-ReaLog DEBUG net "latest release of $Repo -> $($r.Location)"
    # The tag is spliced into later URLs: letters, digits and . _ + - only, never a dot segment.
    if ($r.Location -and $r.Location -cmatch '/releases/tag/[A-Za-z0-9_+-][A-Za-z0-9._+-]*\z') {
        return $r.Location.Substring($r.Location.LastIndexOf('/') + 1)
    }
    return $null
}

# The asset names of the latest release of Repo, from the API; nothing at all on failure (a plain return), so @(...).Count is 0; an empty release gives the same.
function Get-ReaGitHubReleaseAsset {
    param([string]$Repo)
    $tmp = [System.IO.Path]::GetTempFileName()
    Register-ReaTempFile $tmp
    try {
        if (-not (Invoke-ReaHttpGet -Url "https://api.github.com/repos/$Repo/releases/latest" -Destination $tmp)) { return }
        $d = [System.IO.File]::ReadAllText($tmp) | ConvertFrom-Json
        $names = @($d.assets | ForEach-Object { [string]$_.name })
        return $names
    } catch {
        Write-ReaLog ERROR net ('cannot read the release: ' + $_.Exception.Message)
        return
    } finally {
        Clear-ReaTempFile -Path $tmp
    }
}

# The asset names of a release, from the HTML of its expanded_assets page; the fallback for when the API is
# rate-limited. Nothing at all on failure (a plain return), so @(...).Count is 0; an empty page gives the same.
function Get-ReaGitHubReleaseAssetsScrape {
    param([string]$Repo, [string]$Tag)
    $tmp = [System.IO.Path]::GetTempFileName()
    Register-ReaTempFile $tmp
    try {
        if (-not (Invoke-ReaHttpGet -Url "https://github.com/$Repo/releases/expanded_assets/$Tag" -Destination $tmp)) { return }
        $html = [System.IO.File]::ReadAllText($tmp)
        $needle = "/$Repo/releases/download/$Tag/"
        $names = @([regex]::Matches($html, '/[^"<> ]+/releases/download/[^"<> ]+') |
                ForEach-Object { $_.Value } |
                Where-Object { $_.Contains($needle) } |
                ForEach-Object { $_.Substring($_.LastIndexOf('/') + 1) } |
                Sort-Object -Unique)
        return $names
    } finally {
        Clear-ReaTempFile -Path $tmp
    }
}

# True when Tag is a Temurin 21 release name such as jdk-21.0.13+9.
function Test-ReaJdkRelease {
    param([AllowEmptyString()][string]$Tag)
    return ($Tag -match '^jdk-21(\.[0-9]+)*\+[0-9]+\z')
}

# Reads the first asset of an Adoptium response: Release, Url, Sha256, SidecarUrl, Bytes. $null unless the release
# name, the download link (host github.com, path /adoptium/temurin21-binaries/, no dot-dot segment), the sidecar
# link and the checksum all pass.
function ConvertFrom-ReaAdoptium {
    param([string]$Path)
    try {
        # Windows PowerShell 5.1 hands a top-level JSON array over as one object, PowerShell 7 unrolls it.
        $parsed = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $first = $parsed
        if ($parsed -is [array]) { $first = $parsed[0] }
        $pkg = $first.binary.package
        $jdk = [pscustomobject]@{
            Release    = [string]$first.release_name
            Url        = [string]$pkg.link
            Sha256     = ([string]$pkg.checksum).ToLowerInvariant()
            SidecarUrl = [string]$pkg.checksum_link
            Bytes      = [string]$pkg.size
        }
    } catch {
        Write-ReaLog ERROR net ('cannot read the Adoptium answer: ' + $_.Exception.Message)
        return $null
    }
    if (-not (Test-ReaJdkRelease $jdk.Release)) {
        Write-ReaLog ERROR net "unexpected JDK release name: $($jdk.Release)"
        return $null
    }
    if (-not (Test-ReaUrlAllowed $jdk.Url)) { return $null }
    if (-not (Test-ReaUrlPathSafe $jdk.Url)) {
        Write-ReaLog ERROR net "unexpected JDK download path: $($jdk.Url)"
        return $null
    }
    if ((Get-ReaUrlHost $jdk.Url) -cne 'github.com') { return $null }
    if ($jdk.Url -notmatch '^[^:]*://[^/]*/adoptium/temurin21-binaries/.') {
        Write-ReaLog ERROR net "unexpected JDK download path: $($jdk.Url)"
        return $null
    }
    if ($jdk.Sha256 -notmatch '^[0-9a-f]{64}\z') { return $null }
    if ($jdk.Bytes -notmatch '^[0-9]+\z') { return $null }
    if ($jdk.SidecarUrl) {
        if (-not (Test-ReaUrlAllowed $jdk.SidecarUrl)) { return $null }
        if (-not (Test-ReaUrlPathSafe $jdk.SidecarUrl)) { return $null }
    }
    return $jdk
}

# Asks the Adoptium API for the latest Temurin 21 JDK and parses it. Returns Code and Jdk: Code 0 with the
# parsed answer, 2 when the API cannot be reached (the caller uses the fallback pin), 1 when the answer fails
# validation.
function Resolve-ReaAdoptium {
    param([string]$Os, [string]$Arch)
    $tmp = [System.IO.Path]::GetTempFileName()
    Register-ReaTempFile $tmp
    try {
        $url = 'https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=' + [uri]::EscapeDataString($Arch) + '&image_type=jdk&os=' + [uri]::EscapeDataString($Os) + '&vendor=eclipse'
        if (-not (Invoke-ReaHttpGet -Url $url -Destination $tmp)) {
            return [pscustomobject]@{ Code = 2; Jdk = $null }
        }
        $jdk = ConvertFrom-ReaAdoptium -Path $tmp
        if ($null -eq $jdk) { return [pscustomobject]@{ Code = 1; Jdk = $null } }
        return [pscustomobject]@{ Code = 0; Jdk = $jdk }
    } finally {
        Clear-ReaTempFile -Path $tmp
    }
}

# --- files, locks, archives and staging ---

# Test seams: how many polls a lock waits (2 s each, so 60 is 120 s), the pause per poll, and the tar program
# ('tar.exe' is the bsdtar that ships with Windows 10; elsewhere plain 'tar').
$script:LockPolls = 60
$script:LockPollSeconds = 2
$script:LockHeld = New-Object System.Collections.Generic.List[string]
$script:TarExe = ''
# The longest extracted path allowed: the classic Windows MAX_PATH of 260 less room for the tool's own files.
$script:MaxPathLength = 240

# The tools directory: -ToolsDir, else %LOCALAPPDATA%\rea-tools.
function Get-ReaLocalAppData {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    return $base
}

function Get-ReaToolsDir {
    if ($script:Opt.ToolsDir) { return $script:Opt.ToolsDir }
    return (Join-Path (Get-ReaLocalAppData) 'rea-tools')
}

# The launcher directory: -BinDir, else %LOCALAPPDATA%\rea-tools\bin.
function Get-ReaBinDir {
    if ($script:Opt.BinDir) { return $script:Opt.BinDir }
    return (Join-Path (Join-Path (Get-ReaLocalAppData) 'rea-tools') 'bin')
}

function Test-ReaWindowsHost {
    return ([System.IO.Path]::DirectorySeparatorChar -eq '\')
}

# The volume that holds Path: DriveType, DriveFormat and AvailableFreeSpace. A UNC path has no drive letter, so
# it is reported as a network volume without a size. One function so a test can stand in for any kind of volume.
function Get-ReaDriveInfo {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($root.StartsWith('\\')) {
        return [pscustomobject]@{ DriveType = 'Network'; DriveFormat = ''; AvailableFreeSpace = [int64]0 }
    }
    return (New-Object System.IO.DriveInfo $root)
}

# Free megabytes on the volume holding Path; a path that does not exist yet uses its nearest existing parent.
function Get-ReaFreeMb {
    param([string]$Path)
    $probe = [System.IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $probe -PathType Container)) {
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }
    $info = Get-ReaDriveInfo -Path $probe
    return [int64][math]::Floor($info.AvailableFreeSpace / 1MB)
}

# True on a fixed NTFS volume; anything else (network, ReFS, FAT, removable, unreadable) stops with exit code 1.
function Test-ReaFixedNtfsVolume {
    param([string]$Path)
    $type = ''
    $format = ''
    try {
        $info = Get-ReaDriveInfo -Path $Path
        $type = [string]$info.DriveType
        $format = [string]$info.DriveFormat
    } catch {
        $type = 'unreadable'
    }
    if ($type -ne 'Fixed' -or $format -ne 'NTFS') {
        Stop-Rea -Code $script:EX_STEP -Step disk -Message "the install location must be on a fixed NTFS volume; $Path is $type $format"
    }
    return $true
}

# True when Path's modification time is more than Minutes minutes ago.
function Test-ReaOlderThan {
    param([string]$Path, [int]$Minutes)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return ($item.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-$Minutes))
}

# True when a process with that id exists.
function Test-ReaProcessAlive {
    param([int64]$ProcessId)
    if ($ProcessId -le 0 -or $ProcessId -gt [int]::MaxValue) { return $false }
    return ($null -ne (Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue))
}

# The pid recorded in LockDir\owner, or $null.
function Get-ReaLockOwner {
    param([string]$LockDir)
    $file = Join-Path $LockDir 'owner'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    try {
        $first = [System.IO.File]::ReadAllLines($file) | Select-Object -First 1
    } catch {
        return $null
    }
    $m = [regex]::Match([string]$first, '^pid=([0-9]+)')
    if ($m.Success) { return [string]$m.Groups[1].Value }
    return $null
}

# Takes Dir\.lock (creating a directory is atomic) and records pid and start time in Dir\.lock\owner. A lock
# whose owner is dead (or that has no owner and is over a minute old) is moved aside to .lock.stale.<pid> and
# dropped, with a WARN, but only while its owner file still names the pid judged dead. A live owner is waited for,
# 2 s per poll, up to $script:LockPolls polls, then the step fails. Taking a lock this process holds is a no-op.
# The lock is registered for Clear-ReaTempFile, so Invoke-Main's finally releases it.
function Lock-ReaDir {
    param([string]$Dir)
    if ($script:LockHeld.Contains($Dir)) { return }
    try {
        [System.IO.Directory]::CreateDirectory($Dir) | Out-Null
    } catch {
        Stop-Rea -Code $script:EX_STEP -Step tools-bin -Message "cannot create directory: $Dir"
    }
    $lock = Join-Path $Dir '.lock'
    $polls = 0
    while ($true) {
        $made = $false
        try {
            # No wildcard escaping: pwsh 7 treats the path of a new item literally and an escaped path would create a
            # directory with backticks in its name. A host that did expand brackets fails the create, and the
            # check below then stops with 'cannot create lock' instead of locking the wrong place.
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            $made = $true
        } catch {
            $made = $false
        }
        if ($made) {
            $started = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
            try {
                [System.IO.File]::WriteAllText((Join-Path $lock 'owner'), "pid=$PID started=$started" + [Environment]::NewLine)
            } catch {
                Write-ReaLog -Level DEBUG -Step tools-bin -Message "cannot write the lock owner file: $lock"
            }
            Register-ReaTempFile $lock
            $script:LockHeld.Add($Dir)
            return
        }
        if (-not (Test-Path -LiteralPath $lock -PathType Container)) {
            Stop-Rea -Code $script:EX_STEP -Step tools-bin -Message "cannot create lock: $lock"
        }
        $owner = Get-ReaLockOwner -LockDir $lock
        $stale = $false
        if ($null -ne $owner) {
            if (-not (Test-ReaProcessAlive -ProcessId ([int64]$owner))) { $stale = $true }
        } elseif (Test-ReaOlderThan -Path $lock -Minutes 1) {
            $stale = $true
        }
        if ($stale) {
            # Move the lock aside (atomic) only while its owner is still the one judged dead; a failed move
            # means another process took it over first, so fall through to normal polling. The live name is
            # never deleted. Directory.Move fails when the target exists, where Move-Item would nest inside it.
            $aside = Join-Path $Dir ".lock.stale.$PID"
            try { Remove-ReaTree -Path $aside } catch { Write-Verbose "cannot remove $aside" }
            $moved = $false
            if ([string](Get-ReaLockOwner -LockDir $lock) -eq [string]$owner) {
                try {
                    [System.IO.Directory]::Move($lock, $aside)
                    $moved = $true
                } catch {
                    $moved = $false
                }
            }
            if ($moved) {
                $tookOver = $true
                $aboutNow = ($null -eq $owner) -and -not (Test-ReaOlderThan -Path $aside -Minutes 1)
                if ($aboutNow) {
                    # An ownerless lock that is fresh once moved aside was created a moment ago by a process that
                    # has not written its owner file yet: put it back and wait like for any live lock.
                    $tookOver = $false
                    if (-not (Test-Path -LiteralPath $lock)) {
                        try {
                            [System.IO.Directory]::Move($aside, $lock)
                        } catch {
                            try { Remove-ReaTree -Path $aside } catch { Write-Verbose "cannot remove $aside" }
                        }
                    } else {
                        try { Remove-ReaTree -Path $aside } catch { Write-Verbose "cannot remove $aside" }
                    }
                } elseif ([string](Get-ReaLockOwner -LockDir $aside) -eq [string]$owner) {
                    $who = 'unknown'
                    if ($null -ne $owner) { $who = $owner }
                    Write-ReaLog -Level WARN -Step tools-bin -Message "stale lock from pid $who taken over: $lock"
                    try { Remove-ReaTree -Path $aside } catch { Write-Verbose "cannot remove $aside" }
                } elseif (-not (Test-Path -LiteralPath $lock)) {
                    # We moved a lock that changed owner between the check and the move: put it back.
                    try {
                        [System.IO.Directory]::Move($aside, $lock)
                    } catch {
                        try { Remove-ReaTree -Path $aside } catch { Write-Verbose "cannot remove $aside" }
                    }
                } else {
                    try { Remove-ReaTree -Path $aside } catch { Write-Verbose "cannot remove $aside" }
                }
                if ($tookOver) { continue }
            }
        }
        $polls++
        if ($polls -ge $script:LockPolls) {
            $who = 'unknown'
            if ($null -ne $owner) { $who = $owner }
            Stop-Rea -Code $script:EX_STEP -Step tools-bin -Message "lock held by pid ${who}: $lock"
        }
        Invoke-ReaSleep -Seconds $script:LockPollSeconds
    }
}

# Removes Dir\.lock when this process holds it; otherwise does nothing.
function Unlock-ReaDir {
    param([string]$Dir)
    if (-not $script:LockHeld.Contains($Dir)) { return }
    Clear-ReaTempFile -Path (Join-Path $Dir '.lock')
    $null = $script:LockHeld.Remove($Dir)
}

# Removes Dir\*.tmp.<pid> and Dir\*.old.<pid> whose process is gone or whose modification time is over 24 hours
# old (also the POSIX script's leftovers); logs each. A suffix that is not a plain number is left alone.
function Remove-ReaOrphan {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    # Only the names this script creates: the bin dir is shared with other tools and a tools dir may hold the
    # user's own files.
    $ours = 'agent-profile*', 'clavity-ls*', 'jdk-[0-9]*', 'ghidra.work', 'ghidra_[0-9]*', 'env.*'
    $items = @(Get-ChildItem -LiteralPath $Dir -Force | Where-Object {
            $name = $_.Name
            ($name -like '*.tmp.*' -or $name -like '*.old.*') -and
            @($ours | Where-Object { $name -like ($_ + '.tmp.*') -or $name -like ($_ + '.old.*') }).Count -gt 0
        })
    foreach ($item in $items) {
        $suffix = $item.Name.Substring($item.Name.LastIndexOf('.') + 1)
        if ($suffix -notmatch '^[0-9]+$') { continue }
        $why = $null
        $procId = [int64]0
        if (-not [int64]::TryParse($suffix, [ref]$procId)) { continue }
        if (-not (Test-ReaProcessAlive -ProcessId $procId)) {
            $why = "pid $suffix is not running"
        } elseif (Test-ReaOlderThan -Path $item.FullName -Minutes 1440) {
            $why = 'older than 24 hours'
        }
        if ($null -eq $why) { continue }
        if ($PSCmdlet.ShouldProcess($item.FullName, 'remove orphan')) {
            Write-ReaLog -Level INFO -Step cleanup -Message "removing orphan ($why): $($item.FullName)"
            try {
                Remove-ReaTree -Path $item.FullName
            } catch {
                Write-ReaLog -Level WARN -Step cleanup -Message "could not remove orphan: $($item.FullName)"
            }
        }
    }
}

# True when Path is Root or below it. Both must already be full paths. The comparison includes a trailing
# separator, so C:\dest-evil is not inside C:\dest; Windows passes -IgnoreCase.
function Test-ReaPathInside {
    param(
        [string]$Path,
        [string]$Root,
        [char]$Separator = [System.IO.Path]::DirectorySeparatorChar,
        [switch]$IgnoreCase
    )
    $cmp = [System.StringComparison]::Ordinal
    if ($IgnoreCase) { $cmp = [System.StringComparison]::OrdinalIgnoreCase }
    $r = $Root.TrimEnd($Separator) + $Separator
    $p = $Path.TrimEnd($Separator) + $Separator
    return $p.StartsWith($r, $cmp)
}

# The tar program for this host.
function Get-ReaTarExe {
    if ($script:TarExe) { return $script:TarExe }
    if (Test-ReaWindowsHost) { return 'tar.exe' }
    return 'tar'
}

# The text after the first Count whitespace-separated fields of Line, leading blanks removed.
function Skip-ReaField {
    param([string]$Line, [int]$Count)
    $rest = $Line
    for ($i = 0; $i -lt $Count; $i++) {
        $rest = [regex]::Replace($rest, '^\s*\S+', '')
    }
    return $rest.TrimStart()
}

# Parses `tar -tv` output (GNU or bsdtar) into entries with Mode, Type (f, d, l, h), Path and Target. Returns
# nothing when any line cannot be parsed or the listing is empty, so a name holding a newline cannot slip through.
function ConvertFrom-ReaTarListing {
    param([AllowEmptyString()][string]$Text)
    $lines = @($Text -split "`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    if ($lines.Count -eq 0) { return }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd("`r")
        $head = [regex]::Match($line, '^([-dlhcbps][-rwxsStTlL.+@]+)\s')
        if (-not $head.Success) { return }
        $mode = $head.Groups[1].Value
        $fields = @($line.Trim() -split '\s+')
        if ($fields.Count -gt 3 -and $fields[3] -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
            $rest = Skip-ReaField -Line $line -Count 5
        } else {
            $rest = Skip-ReaField -Line $line -Count 8
        }
        $type = $mode.Substring(0, 1)
        if ($type -eq '-') { $type = 'f' }
        $target = ''
        if ($type -eq 'h' -or $type -eq 'l') {
            $sep = ' -> '
            if ($type -eq 'h' -and $rest.Contains(' link to ')) { $sep = ' link to ' }
            $parts = @($rest -split [regex]::Escape($sep))
            if ($parts.Count -ne 2) { return }
            $rest = $parts[0]
            $target = $parts[1]
        }
        $entries.Add([pscustomobject]@{ Mode = $mode; Type = $type; Path = $rest; Target = $target })
    }
    return $entries.ToArray()
}

# The entries of a zip. The type comes from the name (a trailing / or \ is a directory) and the Unix mode kept
# in the high half of the external attributes (a symlink's target is the entry's content). Returns nothing when
# the zip cannot be read.
function Get-ReaZipEntry {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($e in $zip.Entries) {
            $name = $e.FullName
            $unix = ([int64]$e.ExternalAttributes -shr 16) -band 0xFFFF
            $target = ''
            if ($name.EndsWith('/') -or $name.EndsWith('\')) {
                $type = 'd'
            } elseif (($unix -band 0xF000) -eq 0xA000) {
                $type = 'l'
                $stream = $e.Open()
                try {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $buffer = New-Object 'char[]' 4096
                    $n = $reader.Read($buffer, 0, 4096)
                    $target = -join $buffer[0..([math]::Max($n, 1) - 1)]
                    if ($n -le 0) { $target = '' }
                } finally {
                    $stream.Dispose()
                }
            } else {
                $type = 'f'
            }
            $entries.Add([pscustomobject]@{ Mode = [Convert]::ToString($unix, 8); Type = $type; Path = $name; Target = $target })
        }
        return $entries.ToArray()
    } catch {
        Write-ReaLog -Level DEBUG -Step archive -Message ('cannot read ' + $Path + ': ' + $_.Exception.Message)
        return
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

# The entries of a .zip (OpenRead) or tar.gz (tar -tvzf): Mode, Type (f, d, l, h), Path, Target. Returns nothing
# when the archive is missing, cannot be listed or a record cannot be parsed. An archive with no entries gives
# nothing as well.
function Get-ReaArchiveEntry {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    if ($Path -match '\.zip$') {
        return (Get-ReaZipEntry -Path $Path)
    }
    $r = Invoke-ReaCommand -Step archive -FilePath (Get-ReaTarExe) -ArgumentList @('-tvzf', $Path)
    if ($r.ExitCode -ne 0) { return }
    return (ConvertFrom-ReaTarListing -Text $r.Stdout)
}

# The path with / separators, every component canonical (no empty or . parts).
function ConvertTo-ReaArchiveCanon {
    param([string]$Path)
    $parts = @(($Path -replace '\\', '/') -split '/' | Where-Object { $_ -ne '' -and $_ -ne '.' })
    return ($parts -join '/')
}

# True when a link target, resolved from the link's directory Dir, leaves the archive root. A .. after a normal
# component is refused outright, since it cannot be resolved without the filesystem.
function Test-ReaLinkEscape {
    param([string]$Dir, [string]$Target)
    $t = $Target -replace '\\', '/'
    if ($t.StartsWith('/') -or $t -match '^[A-Za-z]:') { return $true }
    $depth = @(($Dir -replace '\\', '/') -split '/' | Where-Object { $_ -ne '' -and $_ -ne '.' }).Count
    $seen = $false
    foreach ($c in ($t -split '/')) {
        if ($c -eq '' -or $c -eq '.') { continue }
        if ($c -eq '..') {
            if ($seen) { return $true }
            $depth--
            if ($depth -lt 0) { return $true }
        } else {
            $seen = $true
        }
    }
    return $false
}

# True when no segment of Path ends in a dot or a space (Windows drops them, so `.. ` and `a.` name other things
# than they say) or has a Windows device name as its stem (CON, PRN, AUX, NUL, COM1-9, LPT1-9, with or without
# an extension). A lone . segment is the current directory and fine. Sets Reason on a refusal.
function Test-ReaSegmentsPortable {
    param([string]$Path, [ref]$Reason)
    foreach ($seg in ($Path -split '/')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg.EndsWith('.') -or $seg.EndsWith(' ')) {
            $Reason.Value = 'segment ends with a dot or a space'
            return $false
        }
        $stem = $seg.Split('.')[0].TrimEnd(' ')
        if ($stem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            $Reason.Value = 'Windows device name'
            return $false
        }
    }
    return $true
}

# True when every entry stays inside the archive root: no absolute path (leading / or \, a drive letter, UNC), no
# .. component (a backslash is a separator), no path below a symlink made earlier or later in the same archive,
# no link whose target leaves the root. Fails closed on an empty list. Logs the first offending entry.
function Test-ReaArchiveEntry {
    param([object[]]$Entries)
    $list = @($Entries | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { return $false }
    $sym = @{}
    foreach ($e in $list) {
        if ($e.Type -eq 'l') { $sym[(ConvertTo-ReaArchiveCanon $e.Path)] = $true }
    }
    foreach ($e in $list) {
        $p = ([string]$e.Path) -replace '\\', '/'
        $why = ''
        if ($p -eq '') {
            $why = 'empty path'
        } elseif ($p.StartsWith('/') -or $p -match '^[A-Za-z]:') {
            $why = 'absolute path'
        } elseif (@($p -split '/') -contains '..') {
            $why = 'parent-directory component'
        } elseif ($p.Contains(':')) {
            $why = 'colon in the name (drive letter or alternate data stream)'
        } elseif (-not (Test-ReaSegmentsPortable -Path $p -Reason ([ref]$why))) {
            $null = $why
        } elseif ($e.Type -eq 'l') {
            $dir = ''
            if ($p -match '/[^/]*/?$') { $dir = [regex]::Replace($p, '/[^/]*/?$', '') }
            if (Test-ReaLinkEscape -Dir $dir -Target ([string]$e.Target)) { $why = 'symlink target leaves the archive: ' + $e.Target }
        } elseif ($e.Type -eq 'h') {
            if (Test-ReaLinkEscape -Dir '' -Target ([string]$e.Target)) { $why = 'hardlink target leaves the archive: ' + $e.Target }
        }
        if ($why -eq '') {
            $parts = @((ConvertTo-ReaArchiveCanon $p) -split '/')
            $prefix = ''
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                if ($prefix -eq '') { $prefix = $parts[$i] } else { $prefix = $prefix + '/' + $parts[$i] }
                if ($sym.ContainsKey($prefix)) { $why = "path below a symlink ($prefix)"; break }
            }
        }
        if ($why -ne '') {
            Write-ReaLog -Level ERROR -Step archive -Message ("unsafe archive entry: {0} ({1})" -f $e.Path, $why)
            return $false
        }
    }
    return $true
}

# True when the archive can be listed, holds at least one entry and every entry is safe. Unreadable, empty,
# missing and non-archive files are all unsafe.
function Test-ReaArchiveSafe {
    param([string]$Path)
    $entries = @(Get-ReaArchiveEntry -Path $Path)
    if ($entries.Count -eq 0) {
        Write-ReaLog -Level ERROR -Step archive -Message "cannot list archive: $Path"
        return $false
    }
    return (Test-ReaArchiveEntry -Entries $entries)
}

# True when the longest path the archive would create under Destination is within $script:MaxPathLength; else
# logs the length and the way out (a shorter -ToolsDir) and returns $false. An archive that cannot be listed fails.
function Test-ReaPathLengthOk {
    param([string]$Path, [string]$Destination)
    $entries = @(Get-ReaArchiveEntry -Path $Path)
    if ($entries.Count -eq 0) {
        Write-ReaLog -Level ERROR -Step archive -Message "cannot list archive: $Path"
        return $false
    }
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('/', '\')
    $longest = 0
    $which = ''
    foreach ($e in $entries) {
        $len = $root.Length + 1 + ([string]$e.Path).TrimEnd('/', '\').Length
        if ($len -gt $longest) { $longest = $len; $which = [string]$e.Path }
    }
    if ($longest -gt $script:MaxPathLength) {
        Write-ReaLog -Level ERROR -Step archive -Message "the longest path to extract would be $longest characters (limit $script:MaxPathLength): $root/$which. Pass a shorter -ToolsDir, for example C:\rea"
        return $false
    }
    return $true
}

# PRECONDITION: the caller has run Test-ReaArchiveSafe on this same, already verified file. A zip is extracted
# entry by entry: a directory entry is created, never extracted; for a file the parent directory is created
# first and ExtractToFile is told not to overwrite, after the resolved target is checked to be inside the
# destination again. A tar.gz is extracted with tar -xzf -C. Returns $true on success.
function Expand-ReaArchive {
    param([string]$Path, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    } catch {
        return $false
    }
    if (-not (Test-ReaPathLengthOk -Path $Path -Destination $Destination)) { return $false }
    if ($Path -notmatch '\.zip$') {
        $r = Invoke-ReaCommand -Step archive -FilePath (Get-ReaTarExe) -ArgumentList @('-xzf', $Path, '-C', $Destination, '--no-same-owner')
        return ($r.ExitCode -eq 0)
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $root = [System.IO.Path]::GetFullPath($Destination)
    $ignoreCase = Test-ReaWindowsHost
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        foreach ($e in $zip.Entries) {
            $name = $e.FullName
            $isDir = ($name.EndsWith('/') -or $name.EndsWith('\'))
            $rel = ($name -replace '\\', '/').Replace('/', [string]$sep)
            # Combine, unlike Join-Path, drops the destination for a rooted name, so such an entry resolves
            # outside it and is refused below; a drive letter is refused outright (on Linux it is only a name).
            $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $rel))
            if ($name -match '^[A-Za-z]:' -or -not (Test-ReaPathInside -Path $target -Root $root -Separator $sep -IgnoreCase:$ignoreCase)) {
                Write-ReaLog -Level ERROR -Step archive -Message "archive entry resolves outside the destination: $name"
                return $false
            }
            if ($isDir) {
                [System.IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $false)
        }
        return $true
    } catch {
        Write-ReaLog -Level ERROR -Step archive -Message ('cannot extract ' + $Path + ': ' + $_.Exception.Message)
        return $false
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

# Creates Dir\Name.tmp.<pid> (replacing a leftover of that name), registers it for Clear-ReaTempFile and
# returns its path.
function New-ReaStaging {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Dir, [string]$Name)
    $path = Join-Path $Dir "$Name.tmp.$PID"
    if (-not $PSCmdlet.ShouldProcess($path, 'create staging directory')) { return }
    try { Remove-ReaTree -Path $path } catch { Write-Verbose "cannot remove $path" }
    [System.IO.Directory]::CreateDirectory($path) | Out-Null
    Register-ReaTempFile $path
    return $path
}

# Marks Staging complete (.install-complete, written inside it: UTC timestamp and script version), moves an
# existing Final aside to Final.old.<pid>, renames Staging in and deletes the old one (a failed delete only
# warns). A failure of the second move puts the old install back. Returns $true when Final is the new install.
function Complete-ReaInstall {
    param([string]$Staging, [string]$Final)
    $old = "$Final.old.$PID"
    try {
        $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $text = "$stamp $script:PIN_SCRIPT_VERSION" + [Environment]::NewLine
        [System.IO.File]::WriteAllText((Join-Path $Staging '.install-complete'), $text)
    } catch {
        Write-ReaLog -Level ERROR -Step install -Message "cannot mark the install complete: $Staging"
        return $false
    }
    if (Test-Path -LiteralPath $old) {
        try { Remove-ReaTree -Path $old } catch { Write-ReaLog -Level WARN -Step install -Message "could not remove a leftover: $old" }
    }
    $hadFinal = Test-Path -LiteralPath $Final
    if ($hadFinal) {
        try {
            Move-ReaItemRetry -Path $Final -Destination $old
        } catch {
            Write-ReaLog -Level ERROR -Step install -Message "cannot move the previous install aside: $Final"
            return $false
        }
    }
    try {
        Move-ReaItemRetry -Path $Staging -Destination $Final
    } catch {
        Write-ReaLog -Level ERROR -Step install -Message "cannot move the new install into place: $Final"
        if ($hadFinal) {
            try {
                Move-ReaItemRetry -Path $old -Destination $Final
            } catch {
                Write-ReaLog -Level ERROR -Step install -Message "cannot restore the previous install from: $old"
            }
        }
        return $false
    }
    Clear-ReaTempFile -Path $Staging
    if ($hadFinal) {
        try {
            Remove-ReaTree -Path $old
        } catch {
            Write-ReaLog -Level WARN -Step install -Message "could not remove the previous install: $old"
        }
    }
    return $true
}

# True when Dir\.install-complete and every listed file under Dir exist.
function Test-ReaInstallValid {
    param([string]$Dir, [string[]]$File = @())
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.install-complete') -PathType Leaf)) { return $false }
    foreach ($f in $File) {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $f))) { return $false }
    }
    return $true
}

# The build number after the + in a JDK release name (0 when absent).
function Get-ReaJdkBuild {
    param([string]$Name)
    $m = [regex]::Match($Name, '\+([0-9]+)')
    if ($m.Success) { return [int64]$m.Groups[1].Value }
    return [int64]0
}

# True when directory name A (jdk-21.0.13+9) is a newer release than B: the X.Y.Z first, then the build number.
function Test-ReaJdkNewer {
    param([string]$A, [string]$B)
    $va = ($A -replace '^jdk-', '') -replace '\+.*$', ''
    $vb = ($B -replace '^jdk-', '') -replace '\+.*$', ''
    $c = Compare-ReaSemver $va $vb
    if ($c -ne 0) { return ($c -gt 0) }
    return ((Get-ReaJdkBuild $A) -gt (Get-ReaJdkBuild $B))
}

# Keeps the two newest jdk-<digit>* directories under ToolsDir that hold .install-complete or a release file
# (nothing else is ever touched) and whichever one holds JAVA_HOME or an -InUse path; removes the rest (a failed
# removal only warns). Staging and .old directories are ignored.
function Remove-ReaOldJdk {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$ToolsDir, [string[]]$InUse = @())
    if (-not (Test-Path -LiteralPath $ToolsDir -PathType Container)) { return }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $cmp = [System.StringComparison]::Ordinal
    if (Test-ReaWindowsHost) { $cmp = [System.StringComparison]::OrdinalIgnoreCase }
    $homes = @($InUse) + @($env:JAVA_HOME) | Where-Object { $_ }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($d in @(Get-ChildItem -LiteralPath $ToolsDir -Directory -Force | Where-Object { $_.Name -like 'jdk-[0-9]*' })) {
        if ($d.Name -like '*.tmp.*' -or $d.Name -like '*.old.*') { continue }
        # Only what an install of this script made: the sentinel. A JDK's own release file is no proof, a
        # hand-extracted Temurin has one too.
        $marked = Test-Path -LiteralPath (Join-Path $d.FullName '.install-complete') -PathType Leaf
        if ($marked) { $names.Add($d.Name) }
    }
    foreach ($n in $names) {
        $newer = 0
        foreach ($m in $names) {
            if ($m -ne $n -and (Test-ReaJdkNewer -A $m -B $n)) { $newer++ }
        }
        if ($newer -lt 2) { continue }
        $full = Join-Path $ToolsDir $n
        $keep = $false
        foreach ($h in $homes) {
            $hp = $h.TrimEnd('/', '\') + $sep
            if ($hp.StartsWith($full + $sep, $cmp)) { $keep = $true }
        }
        if ($keep) {
            Write-ReaLog -Level INFO -Step jdk -Message "keeping the JDK in use: $full"
            continue
        }
        if ($PSCmdlet.ShouldProcess($full, 'remove old JDK')) {
            Write-ReaLog -Level INFO -Step jdk -Message "removing old JDK: $full"
            try {
                Remove-ReaTree -Path $full
            } catch {
                Write-ReaLog -Level WARN -Step jdk -Message "could not remove: $full"
            }
        }
    }
}

# The brief names these with a plural noun (or, for Ntfs, a name ending in s), which PSUseSingularNouns rejects; the
# singular function is the real one.
Set-Alias -Name Get-ReaArchiveEntries -Value Get-ReaArchiveEntry
Set-Alias -Name Remove-ReaOrphans -Value Remove-ReaOrphan
Set-Alias -Name Remove-ReaOldJdks -Value Remove-ReaOldJdk
Set-Alias -Name Test-ReaFixedNtfs -Value Test-ReaFixedNtfsVolume

# --- steps ---

$script:CredentialOverrideNames = @(
    'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_OAUTH_REFRESH_TOKEN',
    'ANTHROPIC_PROFILE', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY'
)
$script:HintNode = 'install Node 24: fnm install 24 (https://github.com/Schniz/fnm) or https://nodejs.org'
$script:HintClaudeShim = "agent-profile refuses npm .cmd shims; install Claude Code's native installer"
$script:Summary = @{}
$script:ToolsDir = ''
$script:BinDir = ''
# Set by the plan phase and the steps: whether a choice found something to reuse, whether tools-bin installed
# or updated anything, and the JDK release the plan resolved (Install-ReaJdk consumes it).
$script:JdkReused = $false
$script:GhidraReused = $false
$script:ToolsBinActed = $false
$script:JdkPlanned = $null

# The path of the executable Name resolves to, or $null. -CommandType Application first, so an extensionless
# script of the same name is never preferred (Start-Process on 5.1 may otherwise pick it). One function so a
# test can stand in for any machine.
function Resolve-ReaExecutable {
    param([string]$Name)
    $found = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $found) { return $null }
    return [string]$found.Source
}

# True when Path names a native executable (.exe); an npm .cmd or .ps1 shim is not.
function Test-ReaNativeExecutable {
    param([AllowEmptyString()][string]$Path)
    return $Path.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)
}

# Preflight: platform, profile name, tar.exe, a fixed NTFS tools volume, the two install directories and their
# orphan cleanup. Sets ToolsDir, BinDir and the summary.
function Invoke-ReaStepPreflight {
    $platform = Get-ReaPlatform
    if ($platform.Arch -ne 'x64') {
        Stop-Rea -Code $script:EX_PLATFORM -Step preflight -Message "unsupported platform: $($platform.Os) $($platform.Arch) (no agent-profile, clavity-ls or Ghidra native build)"
    }
    Write-ReaLog INFO preflight "platform: $($platform.Os) $($platform.Arch)"
    if (-not (Test-ReaProfileName $script:Opt.ProfileName)) {
        Stop-Rea -Code $script:EX_USAGE -Step preflight -Message "invalid profile name: $($script:Opt.ProfileName)"
    }
    $tar = Get-ReaTarExe
    if (-not (Resolve-ReaExecutable -Name $tar)) {
        Stop-Rea -Code $script:EX_PREREQ -Step preflight -Message "$tar not found; it ships with Windows 10 build 17063 and later: update Windows, then re-run"
    }
    $script:ToolsDir = Get-ReaToolsDir
    $script:BinDir = Get-ReaBinDir
    Write-ReaLog DEBUG preflight ("tools dir: {0}; bin dir: {1}" -f (Get-ReaShortPath $script:ToolsDir), (Get-ReaShortPath $script:BinDir))
    Test-ReaFixedNtfsVolume -Path $script:ToolsDir | Out-Null
    if ($script:Opt.DryRun -or $script:Opt.CheckUpstream) {
        Write-ReaLog DEBUG preflight 'read-only run: orphan cleanup skipped'
    } else {
        Remove-ReaOrphan -Dir $script:ToolsDir
        Remove-ReaOrphan -Dir $script:BinDir
    }
    $script:Summary['preflight'] = 'ok'
    Write-ReaLog INFO preflight 'ok'
}

# Stops with exit code 4 naming Name when it does not resolve; returns the resolved path.
function Assert-ReaPrereqTool {
    param([string]$Name, [string]$Hint)
    $path = Resolve-ReaExecutable -Name $Name
    if (-not $path) {
        Stop-Rea -Code $script:EX_PREREQ -Step prereq -Message "$Name not found; $Hint"
    }
    return $path
}

# Prerequisites: node (version floor), npx, claude (a native .exe), agy, wt and a PowerShell. -CheckUpstream
# skips claude, agy and wt. Credential-override variables set in the environment are warned about by name.
function Invoke-ReaStepPrereq {
    $nodePath = Assert-ReaPrereqTool -Name node -Hint $script:HintNode
    $run = Invoke-ReaCommand -Step prereq -FilePath $nodePath -ArgumentList @('--version')
    if ($run.ExitCode -ne 0) {
        Stop-Rea -Code $script:EX_PREREQ -Step prereq -Message "node --version failed (exit $($run.ExitCode)); $script:HintNode"
    }
    $nodeVersion = Get-ReaSemver -Text ([string]$run.Stdout)
    if (-not $nodeVersion -or -not (Test-ReaNodeVersion $nodeVersion)) {
        Stop-Rea -Code $script:EX_PREREQ -Step prereq -Message "node $(([string]$run.Stdout).Trim()) is not supported (needs 22.x >= 22.23.4, 24.x >= 24.22.1 or >= 26.12.1); $script:HintNode"
    }
    Write-ReaLog DEBUG prereq "node $nodeVersion"
    Assert-ReaPrereqTool -Name npx -Hint "it ships with Node; $script:HintNode" | Out-Null
    if ($script:Opt.CheckUpstream) {
        Write-ReaLog INFO prereq 'skip claude, agy and wt (-CheckUpstream)'
    } else {
        $claudePath = Assert-ReaPrereqTool -Name claude -Hint 'install Claude Code (https://docs.claude.com/en/docs/claude-code/setup)'
        if (-not (Test-ReaNativeExecutable $claudePath)) {
            Stop-Rea -Code $script:EX_PREREQ -Step prereq -Message "claude resolves to $claudePath; $script:HintClaudeShim"
        }
        Assert-ReaPrereqTool -Name agy -Hint 'install the Antigravity CLI (agy) and put it on PATH' | Out-Null
        Assert-ReaPrereqTool -Name wt -Hint 'install Windows Terminal (https://aka.ms/terminal)' | Out-Null
    }
    if (-not (Resolve-ReaExecutable -Name pwsh) -and -not (Resolve-ReaExecutable -Name powershell)) {
        Stop-Rea -Code $script:EX_PREREQ -Step prereq -Message 'pwsh or powershell not found; install PowerShell (https://aka.ms/powershell)'
    }
    $set = @($script:CredentialOverrideNames | Where-Object { [Environment]::GetEnvironmentVariable($_) })
    if ($set.Count -gt 0) {
        Write-ReaLog WARN prereq ("set in this environment, these override the profile's credential isolation (names only): " + ($set -join ' '))
        $script:Summary['prereq'] = 'warn'
    } else {
        $script:Summary['prereq'] = 'ok'
        Write-ReaLog INFO prereq 'ok'
    }
}

# --- step tools-bin ---

# Runs a managed tool for its version: Path in, an object with ExitCode and Stdout out. A test replaces it to
# run a stub on a host that cannot execute a .exe.
$script:VersionRunner = $null

# The file name of a managed tool in the bin directory.
function Get-ReaBinExeName {
    param([string]$Name)
    return ($Name + '.exe')
}

# Resolves the latest aiprofiles release for Os and Arch ('windows'/'x64', 'linux'/'x64', 'mac'/'x64',
# 'mac'/'aarch64'): an object with Tag, Version, Asset, Url and SidecarUrl. Returns nothing, before any network
# request, for a platform with no build; stops on a release that cannot be resolved.
function Resolve-ReaAgentProfile {
    param([string]$Os, [string]$Arch)
    switch ("$Os $Arch") {
        'linux x64' { $asset = 'agent-profile-x86_64-unknown-linux-gnu.tar.gz' }
        'mac x64' { $asset = 'agent-profile-x86_64-apple-darwin.tar.gz' }
        'mac aarch64' { $asset = 'agent-profile-aarch64-apple-darwin.tar.gz' }
        'windows x64' { $asset = 'agent-profile-x86_64-pc-windows-msvc.zip' }
        default { return }
    }
    $tag = Get-ReaGitHubLatestTag -Repo $script:PIN_AGENT_PROFILE_REPO
    if (-not $tag) {
        Stop-Rea -Code $script:EX_STEP -Step tools-bin -Message "cannot determine the latest release of $script:PIN_AGENT_PROFILE_REPO"
    }
    $version = Get-ReaSemver -Text $tag
    if (-not $version) {
        Stop-Rea -Code $script:EX_VERIFY -Step tools-bin -Message "release tag of $script:PIN_AGENT_PROFILE_REPO has no X.Y.Z version: $tag"
    }
    $url = "https://github.com/$script:PIN_AGENT_PROFILE_REPO/releases/latest/download/$asset"
    Write-ReaLog DEBUG tools-bin "agent-profile latest: tag $tag, asset $asset"
    return [pscustomobject]@{ Tag = $tag; Version = $version; Asset = $asset; Url = $url; SidecarUrl = ($url + '.sha256') }
}

# Resolves the latest clavity release for Os and Arch: an object with Tag, Version, Asset, Url and SidecarUrl.
# The asset is the one tar.gz for the platform among the release's assets (from the API, else from the release
# page); anything but exactly one match stops with exit 5. Returns nothing for a platform with no build.
function Resolve-ReaClavityRelease {
    param([string]$Os, [string]$Arch)
    switch ("$Os $Arch") {
        'linux x64' { $rid = 'linux-x64' }
        'mac aarch64' { $rid = 'osx-arm64' }
        'mac x64' { $rid = 'osx-x64' }
        'windows x64' { $rid = 'win-x64' }
        default { return }
    }
    $tag = Get-ReaGitHubLatestTag -Repo $script:PIN_CLAVITY_REPO
    if (-not $tag) {
        Stop-Rea -Code $script:EX_STEP -Step tools-bin -Message "cannot determine the latest release of $script:PIN_CLAVITY_REPO"
    }
    $names = @(Get-ReaGitHubReleaseAsset -Repo $script:PIN_CLAVITY_REPO)
    if ($names.Count -eq 0) {
        Write-ReaLog WARN tools-bin "the GitHub API did not answer; reading the release page of $tag instead"
        $names = @(Get-ReaGitHubReleaseAssetsScrape -Repo $script:PIN_CLAVITY_REPO -Tag $tag)
    }
    $pattern = '^clavity-ls-' + [regex]::Escape($rid) + '-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz\z'
    $matched = @($names | Where-Object { $_ -cmatch $pattern })
    if ($matched.Count -ne 1) {
        Stop-Rea -Code $script:EX_VERIFY -Step tools-bin -Message "expected exactly one clavity-ls asset for $rid in $tag, found $($matched.Count)"
    }
    $asset = [string]$matched[0]
    $url = "https://github.com/$script:PIN_CLAVITY_REPO/releases/download/$tag/$asset"
    Write-ReaLog DEBUG tools-bin "clavity-ls latest: tag $tag, asset $asset"
    return [pscustomobject]@{ Tag = $tag; Version = (Get-ReaSemver -Text $asset); Asset = $asset; Url = $url; SidecarUrl = ($url + '.sha256') }
}

# True when Ex or one of its inner exceptions says a file is held open or may not be replaced.
function Test-ReaInUseError {
    param([System.Exception]$Ex)
    $e = $Ex
    while ($null -ne $e) {
        if ($e -is [System.IO.IOException] -or $e -is [System.UnauthorizedAccessException]) { return $true }
        $e = $e.InnerException
    }
    return $false
}

# The name Resolve-ReaClavityLs is an alias: the analyzer's singular-noun rule rejects the plural-looking 'Ls'.
Set-Alias -Name Resolve-ReaClavityLs -Value Resolve-ReaClavityRelease

# Puts Source at Destination: File.Replace when Destination exists (it leaves Destination as it was when it
# fails), a move otherwise. One function so a test can make the move fail.
function Move-ReaIntoPlace {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Source, [string]$Destination)
    if (-not $PSCmdlet.ShouldProcess($Destination, 'replace')) { return }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        [System.IO.File]::Replace($Source, $Destination, [NullString]::Value, $true)
    } else {
        [System.IO.File]::Move($Source, $Destination)
    }
}

# Downloads Url, checks it against the SHA-256 in the sidecar, refuses an unsafe archive, extracts it into a
# staging directory beside DestPath, requires the one entry to be the regular file ExpectedFile and puts it at
# DestPath. Returns 'installed', or 'kept' when a running program holds DestPath (the installed copy stays, the
# staged one is removed). Any other failure stops: exit 5 for what the download, the checksum or the archive got
# wrong.
function Install-ReaSingleBinary {
    param([string]$Name, [string]$Url, [string]$SidecarUrl, [string]$ExpectedFile, [string]$DestPath)
    $dir = Split-Path -Parent $DestPath
    try {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    } catch {
        Stop-Rea -Code $script:EX_STEP -Step tools-bin -Message "cannot create directory: $dir"
    }
    $stage = New-ReaStaging -Dir $dir -Name $Name
    try {
        $side = Join-Path $stage 'sidecar'
        $resolved = Resolve-ReaRedirect -Url $SidecarUrl
        if ($resolved.Code -ne 0) {
            Stop-Rea -Code $script:EX_VERIFY -Step tools-bin -Message "cannot resolve the checksum of ${Name}: $SidecarUrl"
        }
        if (-not (Invoke-ReaHttpGet -Url $resolved.Url -Destination $side)) {
            Stop-Rea -Code $script:EX_VERIFY -Step tools-bin -Message "cannot download the checksum of ${Name}: $SidecarUrl"
        }
        $hash = Get-ReaSidecarSha256 -Path $side
        if (-not $hash) {
            Stop-Rea -Code $script:EX_VERIFY -Step tools-bin -Message "the checksum file of $Name holds no SHA-256: $SidecarUrl"
        }
        $archive = Join-Path $stage ($Url.Substring($Url.LastIndexOf('/') + 1))
        Write-ReaLog DEBUG tools-bin "disk_free_mb $(Get-ReaFreeMb -Path $dir) MB at $dir before the download of $Name"
        if (-not (Get-ReaDownload -Url $Url -Destination $archive -Sha256 $hash)) {
            Stop-Rea -Code $script:EX_VERIFY -Step tools-bin -Message "cannot download and verify $Name from $Url"
        }
        if (-not (Test-ReaArchiveSafe -Path $archive)) {
            Stop-Rea -Code $script:EX_VERIFY -Step tools-bin -Message "the archive of $Name is not safe to extract"
        }
        $extract = Join-Path $stage 'x'
        if (-not (Expand-ReaArchive -Path $archive -Destination $extract)) {
            Stop-Rea -Code $script:EX_VERIFY -Step tools-bin -Message "cannot extract the archive of $Name"
        }
        $items = @(Get-ChildItem -LiteralPath $extract -Force)
        $ok = ($items.Count -eq 1)
        if ($ok) {
            $item = $items[0]
            $isLink = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            $ok = ($item.Name -ceq $ExpectedFile) -and (-not $item.PSIsContainer) -and (-not $isLink)
        }
        if (-not $ok) {
            Stop-Rea -Code $script:EX_VERIFY -Step tools-bin -Message "the archive of $Name must hold exactly one file, $ExpectedFile (found $($items.Count) entries)"
        }
        $staged = $items[0].FullName
        try {
            Move-ReaIntoPlace -Source $staged -Destination $DestPath
        } catch {
            if ((Test-ReaInUseError $_.Exception) -and (Test-Path -LiteralPath $DestPath -PathType Leaf)) {
                Write-ReaLog WARN tools-bin "close running sessions to update $Name"
                return 'kept'
            }
            Stop-Rea -Code $script:EX_STEP -Step tools-bin -Message "cannot move $ExpectedFile into place: $DestPath"
        }
        Write-ReaLog DEBUG tools-bin "disk_free_mb $(Get-ReaFreeMb -Path $dir) MB at $dir after installing $Name"
        return 'installed'
    } finally {
        Clear-ReaTempFile -Path $stage
    }
}

# The X.Y.Z that the copy of Name in the bin directory reports for --version, or '' when that file is absent,
# not an application, exits non-zero or prints no X.Y.Z. PATH is not consulted.
function Get-ReaInstalledVersion {
    param([string]$Name)
    $path = Join-Path $script:BinDir (Get-ReaBinExeName $Name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $app = Get-Command -Name ([WildcardPattern]::Escape($path)) -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $app) { return '' }
    try {
        if ($script:VersionRunner) {
            $r = & $script:VersionRunner $path
        } else {
            $r = Invoke-ReaCommand -Step tools-bin -FilePath $path -ArgumentList @('--version')
        }
    } catch {
        return ''
    }
    if ($null -eq $r -or $r.ExitCode -ne 0) { return '' }
    $v = Get-ReaSemver -Text ([string]$r.Stdout)
    if (-not $v) { return '' }
    return [string]$v
}

# Decides install, update or skip for one tool and carries it out (a dry or read-only run only reports); returns
# the summary line.
function Install-ReaTool {
    param([string]$Name, [string]$Latest, [string]$Url, [string]$SidecarUrl)
    $exe = Get-ReaBinExeName $Name
    $dest = Join-Path $script:BinDir $exe
    $have = Get-ReaInstalledVersion -Name $Name
    if (-not $have) {
        $decision = 'install'
        Write-ReaLog DEBUG tools-bin ("no $Name in " + (Get-ReaShortPath $script:BinDir))
    } elseif ((Compare-ReaSemver $have $Latest) -eq -1) {
        $decision = 'update'
    } else {
        $decision = 'skip (already latest)'
    }
    $shown = $have
    if (-not $shown) { $shown = 'none' }
    Write-ReaLog INFO tools-bin "${Name}: $decision (installed: $shown, latest: $Latest)"
    $other = Resolve-ReaExecutable -Name $Name
    if ($other -and -not [string]::Equals($other, $dest, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-ReaLog WARN tools-bin "another $Name at $other precedes the one this script manages"
    }
    $result = $decision
    if ($decision -eq 'install' -or $decision -eq 'update') {
        $script:ToolsBinActed = $true
        if ($script:Opt.DryRun -or $script:Opt.CheckUpstream) {
            Write-ReaLog INFO tools-bin "${Name}: read-only run, nothing installed"
            $result = "$decision (not done: read-only run)"
        } else {
            $done = Install-ReaSingleBinary -Name $Name -Url $Url -SidecarUrl $SidecarUrl -ExpectedFile $exe -DestPath $dest
            if ($done -eq 'kept') {
                $result = "kept $shown (in use)"
            } else {
                Write-ReaLog INFO tools-bin "$Name $Latest installed in $(Get-ReaShortPath $script:BinDir)"
            }
        }
    }
    return "$Name ${Latest}: $result"
}

# agent-profile then clavity-ls, each installed or updated to the latest release in the bin directory. Takes
# the lock on the tools directory (kept until Unlock-ReaToolsDir) and puts the bin directory first on PATH.
function Invoke-ReaStepToolsBin {
    $script:ToolsBinActed = $false
    $readOnly = ($script:Opt.DryRun -or $script:Opt.CheckUpstream)
    if ($readOnly) {
        Write-ReaLog DEBUG tools-bin 'read-only run: no lock taken'
    } else {
        Lock-ReaDir -Dir $script:ToolsDir
        try {
            [System.IO.Directory]::CreateDirectory($script:BinDir) | Out-Null
        } catch {
            Stop-Rea -Code $script:EX_STEP -Step tools-bin -Message "cannot create directory: $script:BinDir"
        }
    }
    $platform = Get-ReaPlatform
    $lines = New-Object System.Collections.Generic.List[string]
    $planned = $script:ToolsBinPlanned
    $script:ToolsBinPlanned = $null
    $ap = $null
    if ($planned) { $ap = $planned.AgentProfile }
    if (-not $ap) { $ap = Resolve-ReaAgentProfile -Os $platform.Os -Arch $platform.Arch }
    if (-not $ap) {
        Stop-Rea -Code $script:EX_PLATFORM -Step tools-bin -Message "no agent-profile build for $($platform.Os) $($platform.Arch)"
    }
    $lines.Add((Install-ReaTool -Name 'agent-profile' -Latest $ap.Version -Url $ap.Url -SidecarUrl $ap.SidecarUrl))
    $cl = $null
    if ($planned) { $cl = $planned.Clavity }
    if (-not $cl) { $cl = Resolve-ReaClavityRelease -Os $platform.Os -Arch $platform.Arch }
    if (-not $cl) {
        Stop-Rea -Code $script:EX_PLATFORM -Step tools-bin -Message "no clavity-ls build for $($platform.Os) $($platform.Arch)"
    }
    $lines.Add((Install-ReaTool -Name 'clavity-ls' -Latest $cl.Version -Url $cl.Url -SidecarUrl $cl.SidecarUrl))
    $env:PATH = $script:BinDir + [System.IO.Path]::PathSeparator + $env:PATH
    $script:Summary['tools_bin'] = ($lines -join [Environment]::NewLine)
    if ($script:ToolsBinActed) {
        Write-ReaLog INFO tools-bin 'ok'
    } else {
        Write-ReaLog INFO tools-bin 'skip (already valid)'
    }
}

# Lets go of the lock Invoke-ReaStepToolsBin took on the tools directory. It belongs after the last step that
# writes to the tools directory, so Invoke-Main calls it where the steps end and the step that follows moves the
# call.
function Unlock-ReaToolsDir {
    Unlock-ReaDir -Dir $script:ToolsDir
}

# --- step jdk ---

# Test seams: a scriptblock standing in for the run of java (param($Path, $Arguments); returns ExitCode, Stdout and
# Stderr like Invoke-ReaCommand), and the JAVA_HOME the step picked.
$script:JavaRunner = $null
$script:JavaHomeSelected = ''

# The file name of a JDK program on this OS (java.exe on Windows).
function Get-ReaJdkExe {
    param([string]$Name)
    if (Test-ReaWindowsHost) { return "$Name.exe" }
    return $Name
}

# Runs java with Arguments through the test seam or Invoke-ReaCommand; $null when it cannot be started.
function Invoke-ReaJava {
    param([string]$Path, [string[]]$Arguments)
    try {
        if ($script:JavaRunner) {
            return (& $script:JavaRunner $Path $Arguments)
        }
        return (Invoke-ReaCommand -Step jdk -FilePath $Path -ArgumentList $Arguments)
    } catch {
        return $null
    }
}

# Valid is $true when Dir is a full 64-bit JDK of at least PIN_JDK_MAJOR for this host's architecture; otherwise
# Reason says why. Dir is the JDK home. The only programs run are Dir's java, with -version and
# -XshowSettings:properties -version. Arch defaults to the host's.
function Test-ReaJdkValid {
    param([string]$Dir, [string]$Arch = '')
    if (-not $Arch) { $Arch = [string](Get-ReaPlatform).Arch }
    $javaName = Get-ReaJdkExe 'java'
    $javacName = Get-ReaJdkExe 'javac'
    $java = Join-Path (Join-Path $Dir 'bin') $javaName
    $javac = Join-Path (Join-Path $Dir 'bin') $javacName
    if (-not (Test-Path -LiteralPath $java -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; Reason = "no bin/$javaName in $Dir" }
    }
    if (-not (Test-Path -LiteralPath $javac -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; Reason = "no bin/$javacName in $Dir (a JRE, not a JDK)" }
    }
    $r = Invoke-ReaJava -Path $java -Arguments @('-version')
    if ($null -eq $r -or $r.ExitCode -ne 0) {
        return [pscustomobject]@{ Valid = $false; Reason = "java -version failed in $Dir" }
    }
    $text = (([string]$r.Stderr) + "`n" + ([string]$r.Stdout)) -replace "`r", ''
    $m = [regex]::Match($text, '(?m)^.*version "([0-9]+)(?:\.([0-9]+))?')
    if (-not $m.Success) {
        $first = ($text -split "`n" | Where-Object { $_ } | Select-Object -First 1)
        return [pscustomobject]@{ Valid = $false; Reason = "cannot read the version from: $first" }
    }
    $major = [int]$m.Groups[1].Value
    if ($major -eq 1 -and $m.Groups[2].Success) { $major = [int]$m.Groups[2].Value }
    $need = [int]$script:PIN_JDK_MAJOR
    if ($major -lt $need) {
        return [pscustomobject]@{ Valid = $false; Reason = "major $major < $need" }
    }
    if ($text -cnotmatch '64-Bit') {
        return [pscustomobject]@{ Valid = $false; Reason = 'not a 64-bit JDK (the banner has no 64-Bit)' }
    }
    $s = Invoke-ReaJava -Path $java -Arguments @('-XshowSettings:properties', '-version')
    if ($null -eq $s -or $s.ExitCode -ne 0) {
        return [pscustomobject]@{ Valid = $false; Reason = "java -XshowSettings:properties failed in $Dir" }
    }
    $settings = (([string]$s.Stderr) + "`n" + ([string]$s.Stdout)) -replace "`r", ''
    $a = [regex]::Match($settings, '(?m)^\s*os\.arch\s*=\s*(\S+)')
    if (-not $a.Success) {
        return [pscustomobject]@{ Valid = $false; Reason = "cannot read os.arch from $Dir" }
    }
    $got = $a.Groups[1].Value
    if ($got -eq 'amd64' -or $got -eq 'x86_64') { $got = 'x64' }
    if ($got -eq 'arm64') { $got = 'aarch64' }
    if ($got -cne $Arch) {
        return [pscustomobject]@{ Valid = $false; Reason = "architecture $got does not match this host ($Arch)" }
    }
    return [pscustomobject]@{ Valid = $true; Reason = '' }
}

# The JAVA_HOME of an install at Dir: Dir\Contents\Home on macOS (Os 'mac') when it exists, else Dir.
function Get-ReaJdkHomeCandidate {
    param([string]$Dir, [string]$Os = 'windows')
    $mac = Join-Path (Join-Path $Dir 'Contents') 'Home'
    if ($Os -eq 'mac' -and (Test-Path -LiteralPath $mac -PathType Container)) { return $mac }
    return $Dir
}

# The embedded pin of a platform as Release, Url, Sha256, SidecarUrl and Bytes (empty); $null when there is none.
function Get-ReaJdkFallback {
    param([string]$Os, [string]$Arch)
    switch ("$Os-$Arch") {
        'linux-x64' { $pin = $script:PIN_JDK_FALLBACK_LINUX_X64 }
        'mac-x64' { $pin = $script:PIN_JDK_FALLBACK_MAC_X64 }
        'mac-aarch64' { $pin = $script:PIN_JDK_FALLBACK_MAC_AARCH64 }
        'windows-x64' { $pin = $script:PIN_JDK_FALLBACK_WINDOWS_X64 }
        default { return $null }
    }
    $at = $pin.IndexOf(':')
    $url = $script:PIN_JDK_FALLBACK_URL_BASE + $pin.Substring(0, $at)
    return [pscustomobject]@{
        Release    = $script:PIN_JDK_FALLBACK_RELEASE
        Url        = $url
        Sha256     = $pin.Substring($at + 1)
        SidecarUrl = $url + '.sha256.txt'
        Bytes      = ''
    }
}

# The JDK to install for Os and Arch: the Adoptium answer, or the embedded pin (with a WARN) when the API cannot
# be reached.
function Resolve-ReaJdkRelease {
    param([string]$Os, [string]$Arch)
    $r = Resolve-ReaAdoptium -Os $Os -Arch $Arch
    if ($r.Code -eq 0) { return $r.Jdk }
    if ($r.Code -ne 2) {
        Stop-Rea -Code $script:EX_VERIFY -Step jdk -Message "the Adoptium answer for $Os $Arch failed validation"
    }
    $fallback = Get-ReaJdkFallback -Os $Os -Arch $Arch
    if ($null -eq $fallback) {
        Stop-Rea -Code $script:EX_PLATFORM -Step jdk -Message "no JDK build for $Os $Arch"
    }
    Write-ReaLog WARN jdk "Adoptium API unreachable; installing the embedded fallback $script:PIN_JDK_FALLBACK_RELEASE, possibly outdated"
    return $fallback
}

# Stops with exit 1 and the shortfall when Path has less than Mb megabytes free.
function Assert-ReaFreeMb {
    param([string]$Path, [int]$Mb)
    $have = Get-ReaFreeMb -Path $Path
    if ($have -lt $Mb) {
        Stop-Rea -Code $script:EX_STEP -Step disk -Message "not enough free space at ${Path}: need $Mb MB, have $have MB (short by $($Mb - $have) MB)"
    }
}

# Installs the latest Temurin JDK (or the embedded fallback) into ToolsDir\jdk-<release> and returns its home; a
# read-only run only logs what it would fetch and returns $null. The work happens in a staging directory beside
# the final one; the archive lives there as .download.<pid> and goes right after the extract.
function Install-ReaJdk {
    $platform = Get-ReaPlatform
    $tools = $script:ToolsDir
    Assert-ReaFreeMb -Path $tools -Mb 600
    $jdk = $script:JdkPlanned
    $script:JdkPlanned = $null
    if (-not $jdk) { $jdk = Resolve-ReaJdkRelease -Os $platform.Os -Arch $platform.Arch }
    $size = 'unknown'
    if ($jdk.Bytes) { $size = $jdk.Bytes }
    Write-ReaLog INFO jdk "resolved $($jdk.Release): $($jdk.Url) ($size bytes)"
    if ($script:Opt.DryRun -or $script:Opt.CheckUpstream) {
        Write-ReaLog INFO jdk 'read-only run, nothing installed'
        $script:Summary['jdk'] = "$($jdk.Release) (not installed: read-only run)"
        return $null
    }
    $release = $jdk.Release
    try {
        [System.IO.Directory]::CreateDirectory($tools) | Out-Null
    } catch {
        Stop-Rea -Code $script:EX_STEP -Step jdk -Message "cannot create directory: $tools"
    }
    $final = Join-Path $tools $release
    $work = New-ReaStaging -Dir $tools -Name "$release.work"
    $stage = $null
    try {
        $ext = '.tar.gz'
        if ($jdk.Url -match '\.zip$') { $ext = '.zip' }
        $archive = Join-Path $work ('.download.' + $PID + $ext)
        if ($jdk.SidecarUrl) {
            $side = Join-Path $work 'sidecar'
            $got = $false
            $resolved = Resolve-ReaRedirect -Url $jdk.SidecarUrl
            if ($resolved.Code -eq 0) { $got = Invoke-ReaHttpGet -Url $resolved.Url -Destination $side }
            if ($got) {
                $hash = Get-ReaSidecarSha256 -Path $side
                if (-not $hash) {
                    Stop-Rea -Code $script:EX_VERIFY -Step jdk -Message "the checksum file of $release holds no SHA-256: $($jdk.SidecarUrl)"
                }
                if ($hash -cne $jdk.Sha256) {
                    Stop-Rea -Code $script:EX_VERIFY -Step jdk -Message "checksum mismatch for ${release}: the API says $($jdk.Sha256), the sidecar says $hash"
                }
            } else {
                Write-ReaLog WARN jdk "the checksum sidecar of $release is unreachable; relying on the SHA-256 from the release listing"
            }
        }
        Write-ReaLog DEBUG jdk "disk_free_mb $(Get-ReaFreeMb -Path $tools) MB at $tools before the download"
        if (-not (Get-ReaDownload -Url $jdk.Url -Destination $archive -Sha256 $jdk.Sha256)) {
            Stop-Rea -Code $script:EX_VERIFY -Step jdk -Message "cannot download and verify $release from $($jdk.Url)"
        }
        if (-not (Test-ReaArchiveSafe -Path $archive)) {
            Stop-Rea -Code $script:EX_VERIFY -Step jdk -Message "the archive of $release is not safe to extract"
        }
        $extract = Join-Path $work 'x'
        if (-not (Expand-ReaArchive -Path $archive -Destination $extract)) {
            Stop-Rea -Code $script:EX_VERIFY -Step jdk -Message "cannot extract the archive of $release"
        }
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        $items = @(Get-ChildItem -LiteralPath $extract -Force)
        $ok = ($items.Count -eq 1)
        if ($ok) {
            $item = $items[0]
            $isLink = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            $ok = ($item.Name -ceq $release) -and $item.PSIsContainer -and (-not $isLink)
        }
        if (-not $ok) {
            Stop-Rea -Code $script:EX_VERIFY -Step jdk -Message "the archive of $release must hold exactly one top directory, $release (found $($items.Count) entries)"
        }
        $stage = New-ReaStaging -Dir $tools -Name $release
        [System.IO.Directory]::Delete($stage)
        try {
            Move-ReaItemRetry -Path $items[0].FullName -Destination $stage
        } catch {
            Stop-Rea -Code $script:EX_STEP -Step jdk -Message "cannot move the extracted JDK into $stage"
        }
        Clear-ReaTempFile -Path $work
        $check = Test-ReaJdkValid -Dir (Get-ReaJdkHomeCandidate -Dir $stage -Os $platform.Os) -Arch $platform.Arch
        if (-not $check.Valid) {
            Stop-Rea -Code $script:EX_VERIFY -Step jdk -Message "the downloaded $release is not a usable JDK: $($check.Reason)"
        }
        if (-not (Complete-ReaInstall -Staging $stage -Final $final)) {
            Stop-Rea -Code $script:EX_STEP -Step jdk -Message "cannot move $release into place: $final"
        }
    } finally {
        Clear-ReaTempFile -Path $work
        if ($stage) { Clear-ReaTempFile -Path $stage }
    }
    $jdkHome = Get-ReaJdkHomeCandidate -Dir $final -Os $platform.Os
    $script:JavaHomeSelected = $jdkHome
    Write-ReaLog DEBUG jdk "disk_free_mb $(Get-ReaFreeMb -Path $tools) MB at $tools after the install"
    Write-ReaLog INFO jdk "installed $release in $(Get-ReaShortPath $final)"
    Remove-ReaOldJdk -ToolsDir $tools -InUse @($jdkHome)
    $script:Summary['jdk'] = "$release installed: $jdkHome"
    return $jdkHome
}

# The value of -JavaHome when it was given on the command line, else ''. The parameter defaults to the JAVA_HOME
# environment variable, so only the bound parameters tell the two apart.
function Get-ReaJavaHomeFlag {
    if ($script:Bound.ContainsKey('JavaHome')) { return [string]$script:Opt.JavaHome }
    return ''
}

# Sets JavaHomeSelected and Summary['jdk']. Precedence: -JavaHome (invalid: exit 1), the JAVA_HOME environment
# variable (invalid: WARN and go on), the newest valid install in the tools directory, a new install. With
# -PlanOnly it stops before the install: JdkReused says whether there is something to reuse; nothing is
# downloaded or written.
function Select-ReaJdk {
    param(
        [string]$FlagHome = (Get-ReaJavaHomeFlag),
        [string]$EnvHome = $env:JAVA_HOME,
        [switch]$PlanOnly
    )
    $script:JavaHomeSelected = ''
    $script:JdkReused = $true
    $os = [string](Get-ReaPlatform).Os
    if ($FlagHome) {
        $candidate = Get-ReaJdkHomeCandidate -Dir $FlagHome -Os $os
        $check = Test-ReaJdkValid -Dir $candidate
        if (-not $check.Valid) {
            Stop-Rea -Code $script:EX_STEP -Step jdk -Message "-JavaHome $FlagHome is not a usable JDK: $($check.Reason)"
        }
        $script:JavaHomeSelected = $candidate
        Write-ReaLog INFO jdk "using -JavaHome: $(Get-ReaShortPath $candidate)"
        $script:Summary['jdk'] = "reused -JavaHome: $candidate"
        return
    }
    if ($EnvHome) {
        $candidate = Get-ReaJdkHomeCandidate -Dir $EnvHome -Os $os
        $check = Test-ReaJdkValid -Dir $candidate
        if ($check.Valid) {
            $script:JavaHomeSelected = $candidate
            Write-ReaLog INFO jdk "using JAVA_HOME: $(Get-ReaShortPath $candidate)"
            $script:Summary['jdk'] = "reused JAVA_HOME: $candidate"
            return
        }
        Write-ReaLog WARN jdk "JAVA_HOME $EnvHome is not a usable JDK ($($check.Reason)); ignoring it"
    }
    $best = ''
    if (Test-Path -LiteralPath $script:ToolsDir -PathType Container) {
        foreach ($d in @(Get-ChildItem -LiteralPath $script:ToolsDir -Directory -Force | Where-Object { $_.Name -like 'jdk-[0-9]*' })) {
            if ($d.Name -like '*.tmp.*' -or $d.Name -like '*.old.*') { continue }
            if (-not (Test-ReaInstallValid -Dir $d.FullName)) {
                Write-ReaLog DEBUG jdk "ignoring $($d.Name): no .install-complete"
                continue
            }
            $check = Test-ReaJdkValid -Dir (Get-ReaJdkHomeCandidate -Dir $d.FullName -Os $os)
            if (-not $check.Valid) {
                Write-ReaLog WARN jdk "ignoring the install $($d.Name): $($check.Reason)"
                continue
            }
            if ((-not $best) -or (Test-ReaJdkNewer -A $d.Name -B $best)) { $best = $d.Name }
        }
    }
    if ($best) {
        $script:JavaHomeSelected = Get-ReaJdkHomeCandidate -Dir (Join-Path $script:ToolsDir $best) -Os $os
        Write-ReaLog INFO jdk "reusing $best in $(Get-ReaShortPath $script:ToolsDir)"
        $script:Summary['jdk'] = "reused ${best}: $($script:JavaHomeSelected)"
        return
    }
    $script:JdkReused = $false
    if ($PlanOnly) { return }
    $installed = Install-ReaJdk
    if ($installed) { $script:JavaHomeSelected = [string]$installed }
}

# Picks or installs the JDK that Ghidra and rea run with. Runs under the lock Invoke-ReaStepToolsBin took. After
# Invoke-ReaPlanJdk it follows the plan (the choice was made there).
function Invoke-ReaStepJdk {
    switch ($script:PlanJdk) {
        'reuse' { }
        'install' {
            # Re-checked under the lock: another run may have installed the JDK since the plan was made
            Select-ReaJdk -PlanOnly
            if (-not $script:JdkReused) {
                $installed = Install-ReaJdk
                if ($installed) { $script:JavaHomeSelected = [string]$installed }
            }
        }
        default { Select-ReaJdk }
    }
    if ($script:JdkReused) {
        Write-ReaLog INFO jdk 'skip (already valid)'
    } else {
        Write-ReaLog INFO jdk 'ok'
    }
}

# --- step ghidra ---

# The Ghidra the step picked, and whether it is the official archive (installed, about to be, or reused from the
# tools directory).
$script:GhidraDirSelected = ''
$script:GhidraOfficial = $false

# The application.version of Dir\Ghidra\application.properties (tolerant of CRLF, blanks and other properties);
# '' when the file or the property is absent.
function Get-ReaGhidraVersion {
    param([string]$Dir)
    $file = Join-Path (Join-Path $Dir 'Ghidra') 'application.properties'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        $m = [regex]::Match($line, '^\s*application\.version\s*=\s*(\S*)\s*$')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

# Valid is $true when Dir holds a Ghidra of the 12.1 line (12.1 or 12.1.N); otherwise Reason says why.
function Test-ReaGhidraValid {
    param([string]$Dir)
    $ver = Get-ReaGhidraVersion -Dir $Dir
    if (-not $ver) {
        return [pscustomobject]@{ Valid = $false; Reason = 'no application.version in Ghidra/application.properties' }
    }
    if ($ver -match '^12\.1(\.[0-9]+)?$') { return [pscustomobject]@{ Valid = $true; Reason = '' } }
    return [pscustomobject]@{ Valid = $false; Reason = "version $ver is not in the 12.1 line" }
}

# Installs the pinned Ghidra into ToolsDir\<top directory> and returns its path; a read-only run only logs what it
# would fetch and returns $null. The work happens in a staging directory beside the final one (a short name, for
# the Windows path limit); the archive lives there as .download.<pid>.zip and goes right after the extract. The
# digest is the one embedded in this script, never one fetched.
function Install-ReaGhidra {
    $tools = $script:ToolsDir
    $topDir = $script:PIN_GHIDRA_TOPDIR
    $version = $script:PIN_GHIDRA_VERSION
    $final = Join-Path $tools $topDir
    Assert-ReaFreeMb -Path $tools -Mb 1500
    Write-ReaLog INFO ghidra "will install Ghidra $version from $script:PIN_GHIDRA_URL ($script:PIN_GHIDRA_ZIP_BYTES bytes) into $(Get-ReaShortPath $final)"
    $script:GhidraOfficial = $true
    if ($script:Opt.DryRun -or $script:Opt.CheckUpstream) {
        Write-ReaLog INFO ghidra 'read-only run, nothing installed'
        $script:Summary['ghidra'] = "$version (not installed: read-only run)"
        return $null
    }
    try {
        [System.IO.Directory]::CreateDirectory($tools) | Out-Null
    } catch {
        Stop-Rea -Code $script:EX_STEP -Step ghidra -Message "cannot create directory: $tools"
    }
    $work = New-ReaStaging -Dir $tools -Name 'ghidra.work'
    $stage = $null
    try {
        $archive = Join-Path $work ('.download.' + $PID + '.zip')
        Write-ReaLog DEBUG ghidra "disk_free_mb $(Get-ReaFreeMb -Path $tools) MB at $tools before the download"
        if (-not (Get-ReaDownload -Url $script:PIN_GHIDRA_URL -Destination $archive -Sha256 $script:PIN_GHIDRA_SHA256)) {
            Stop-Rea -Code $script:EX_VERIFY -Step ghidra -Message "cannot download and verify Ghidra $version from $script:PIN_GHIDRA_URL"
        }
        $size = (Get-Item -LiteralPath $archive -Force).Length
        if ([string]$size -ne [string]$script:PIN_GHIDRA_ZIP_BYTES) {
            Stop-Rea -Code $script:EX_VERIFY -Step ghidra -Message "the Ghidra archive is $size bytes, expected $script:PIN_GHIDRA_ZIP_BYTES"
        }
        if (-not (Test-ReaArchiveSafe -Path $archive)) {
            Stop-Rea -Code $script:EX_VERIFY -Step ghidra -Message 'the Ghidra archive is not safe to extract'
        }
        $extract = Join-Path $work 'x'
        if (-not (Expand-ReaArchive -Path $archive -Destination $extract)) {
            Stop-Rea -Code $script:EX_VERIFY -Step ghidra -Message 'cannot extract the Ghidra archive (the longest path in it is 149 characters beyond the extraction directory: a -ToolsDir of at most 64 characters stays under the 240 limit)'
        }
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        $items = @(Get-ChildItem -LiteralPath $extract -Force)
        $ok = ($items.Count -eq 1)
        if ($ok) {
            $item = $items[0]
            $isLink = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            $ok = ($item.Name -ceq $topDir) -and $item.PSIsContainer -and (-not $isLink)
        }
        if (-not $ok) {
            Stop-Rea -Code $script:EX_VERIFY -Step ghidra -Message "the Ghidra archive must hold exactly one top directory, $topDir (found $($items.Count) entries)"
        }
        $stage = New-ReaStaging -Dir $tools -Name $topDir
        [System.IO.Directory]::Delete($stage)
        try {
            Move-ReaItemRetry -Path $items[0].FullName -Destination $stage
        } catch {
            Stop-Rea -Code $script:EX_STEP -Step ghidra -Message "cannot move the extracted Ghidra into $stage"
        }
        Clear-ReaTempFile -Path $work
        $got = Get-ReaGhidraVersion -Dir $stage
        if ($got -cne $version) {
            Stop-Rea -Code $script:EX_VERIFY -Step ghidra -Message "the downloaded Ghidra reports version '$got', expected $version"
        }
        if (-not (Complete-ReaInstall -Staging $stage -Final $final)) {
            Stop-Rea -Code $script:EX_STEP -Step ghidra -Message "cannot move Ghidra into place: $final"
        }
    } finally {
        Clear-ReaTempFile -Path $work
        if ($stage) { Clear-ReaTempFile -Path $stage }
    }
    $script:GhidraDirSelected = $final
    Write-ReaLog DEBUG ghidra "disk_free_mb $(Get-ReaFreeMb -Path $tools) MB at $tools after the install"
    Write-ReaLog INFO ghidra "installed Ghidra $version in $(Get-ReaShortPath $final)"
    $script:Summary['ghidra'] = "$version installed: $final"
    return $final
}

# The value of -GhidraDir when it was given on the command line, else ''. The parameter defaults to the
# GHIDRA_INSTALL_DIR environment variable, so only the bound parameters tell the two apart.
function Get-ReaGhidraDirFlag {
    if ($script:Bound.ContainsKey('GhidraDir')) { return [string]$script:Opt.GhidraDir }
    return ''
}

# Sets GhidraDirSelected, GhidraOfficial and Summary['ghidra']. Precedence: -GhidraDir (invalid: exit 1), the
# GHIDRA_INSTALL_DIR environment variable (invalid: WARN and go on), the install in the tools directory (valid and
# marked complete; one without the mark is treated as absent and replaced), a new install. With -PlanOnly it
# stops before the install: GhidraReused says whether there is something to reuse; nothing is downloaded or
# written.
function Select-ReaGhidra {
    param(
        [string]$FlagDir = (Get-ReaGhidraDirFlag),
        [string]$EnvDir = $env:GHIDRA_INSTALL_DIR,
        [switch]$PlanOnly
    )
    $script:GhidraDirSelected = ''
    $script:GhidraOfficial = $false
    $script:GhidraReused = $true
    if ($FlagDir) {
        $check = Test-ReaGhidraValid -Dir $FlagDir
        if (-not $check.Valid) {
            Stop-Rea -Code $script:EX_STEP -Step ghidra -Message "-GhidraDir $FlagDir is not a usable Ghidra: $($check.Reason)"
        }
        $script:GhidraDirSelected = $FlagDir
        Write-ReaLog INFO ghidra "using -GhidraDir: $(Get-ReaShortPath $FlagDir)"
        $script:Summary['ghidra'] = "reused -GhidraDir: $FlagDir"
        return
    }
    if ($EnvDir) {
        $check = Test-ReaGhidraValid -Dir $EnvDir
        if ($check.Valid) {
            $script:GhidraDirSelected = $EnvDir
            Write-ReaLog INFO ghidra "using GHIDRA_INSTALL_DIR: $(Get-ReaShortPath $EnvDir)"
            $script:Summary['ghidra'] = "reused GHIDRA_INSTALL_DIR: $EnvDir"
            return
        }
        if ((Get-ReaGhidraVersion -Dir $EnvDir) -match '^12\.2(\.|$)') {
            Write-ReaLog DEBUG ghidra "GHIDRA_INSTALL_DIR $EnvDir is a 12.2 install"
            Write-ReaLog WARN ghidra '12.2 is not accepted by rea 6.8.0; installing 12.1.4 alongside'
        } else {
            Write-ReaLog WARN ghidra "GHIDRA_INSTALL_DIR $EnvDir is not a usable Ghidra ($($check.Reason)); ignoring it"
        }
    }
    $topDir = $script:PIN_GHIDRA_TOPDIR
    $dir = Join-Path $script:ToolsDir $topDir
    if (Test-Path -LiteralPath $dir -PathType Container) {
        if (-not (Test-ReaInstallValid -Dir $dir -File @('Ghidra/application.properties'))) {
            Write-ReaLog DEBUG ghidra "ignoring ${topDir}: no .install-complete or no application.properties"
        } else {
            $check = Test-ReaGhidraValid -Dir $dir
            if ($check.Valid) {
                $script:GhidraDirSelected = $dir
                $script:GhidraOfficial = $true
                Write-ReaLog INFO ghidra "reusing $topDir in $(Get-ReaShortPath $script:ToolsDir)"
                $script:Summary['ghidra'] = "reused ${topDir}: $dir"
                return
            }
            Write-ReaLog WARN ghidra "ignoring the install ${topDir}: $($check.Reason)"
        }
    }
    $script:GhidraReused = $false
    if ($PlanOnly) { return }
    $installed = Install-ReaGhidra
    if ($installed) { $script:GhidraDirSelected = [string]$installed }
}

# Picks or installs the Ghidra that rea runs with. Runs under the lock Invoke-ReaStepToolsBin took; after
# Invoke-ReaPlanGhidra it follows the plan. On macOS the
# official archive has no native decompiler: a WARN and a warn summary, never a failure.
function Invoke-ReaStepGhidra {
    switch ($script:PlanGhidra) {
        'reuse' { }
        'install' {
            # Re-checked under the lock: another run may have installed Ghidra since the plan was made
            Select-ReaGhidra -PlanOnly
            if (-not $script:GhidraReused) {
                $installed = Install-ReaGhidra
                if ($installed) { $script:GhidraDirSelected = [string]$installed }
            }
        }
        default { Select-ReaGhidra }
    }
    Write-ReaLog DEBUG ghidra "selected: $script:GhidraDirSelected"
    if (([string](Get-ReaPlatform).Os) -eq 'mac' -and $script:GhidraOfficial) {
        Write-ReaLog WARN ghidra 'the official 12.1.4 archive has no macOS native decompiler; rea doctor will report native_decompiler missing until it is built (rea docs/installation.md, "Missing macOS native decompiler" / "macOS arm64 native decompiler")'
        $script:Summary['ghidra'] = "warn: $($script:Summary['ghidra']); no macOS native decompiler in the official archive"
    }
    if ($script:GhidraReused) {
        Write-ReaLog INFO ghidra 'skip (already valid)'
    } else {
        Write-ReaLog INFO ghidra 'ok'
    }
}

# --- step profile ---

# The profile directory the step picked.
$script:ClaudeConfigDirSelected = ''

# Path as a full path with the symlinks and junctions of its existing part followed; the rest is kept as given.
function Resolve-ReaLinkedPath {
    param([string]$Path)
    $current = [System.IO.Path]::GetFullPath($Path)
    for ($hop = 0; $hop -lt 16; $hop++) {
        $changed = $false
        $probe = $current
        while ($probe) {
            $item = Get-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            if ($item -and ([string]$item.LinkType -eq 'SymbolicLink' -or [string]$item.LinkType -eq 'Junction') -and $item.Target) {
                $target = [string]@($item.Target)[0]
                if (-not [System.IO.Path]::IsPathRooted($target)) {
                    $target = Join-Path (Split-Path -Parent $probe) $target
                }
                $current = [System.IO.Path]::GetFullPath($target + $current.Substring($probe.Length))
                $changed = $true
                break
            }
            $parent = Split-Path -Parent $probe
            if ($parent -eq $probe) { break }
            $probe = $parent
        }
        if (-not $changed) { break }
    }
    return $current
}

# True when Dir is empty, or is the .claude directory of the home directory or lies inside it (as given, and with
# links followed, case-insensitive); the setup must never write there, whatever agent-profile reports.
function Test-ReaProfileDirShared {
    param([AllowEmptyString()][string]$Dir)
    if (-not $Dir) { return $true }
    $homeDir = $env:USERPROFILE
    if (-not $homeDir) { return $false }
    $shared = Join-Path $homeDir.TrimEnd('\', '/') '.claude'
    $roots = @([System.IO.Path]::GetFullPath($shared), (Resolve-ReaLinkedPath -Path $shared))
    $candidates = @([System.IO.Path]::GetFullPath($Dir), (Resolve-ReaLinkedPath -Path $Dir))
    foreach ($root in $roots) {
        foreach ($candidate in $candidates) {
            if (Test-ReaUnderHome -Path $candidate -HomeDir $root.TrimEnd('\', '/')) { return $true }
        }
    }
    return $false
}

# Runs `agent-profile claude doctor Name --json` and returns the CLAUDE_CONFIG_DIR it reports. Exit 5 means a
# check failed: a WARN naming the failing checks, and create decides. Any other non-zero exit, output that is not
# JSON, or a directory that is not specific to the profile stops with exit 1.
function Get-ReaProfileConfigDir {
    param([string]$Name, [string]$Executable)
    $run = Invoke-ReaCommand -Step profile -FilePath $Executable -ArgumentList @('claude', 'doctor', $Name, '--json')
    if ($run.ExitCode -ne 0 -and $run.ExitCode -ne 5) {
        Stop-Rea -Code $script:EX_STEP -Step profile -Message "agent-profile claude doctor exited $($run.ExitCode)"
    }
    $doc = $null
    try {
        if ($run.Stdout -and $run.Stdout.Trim()) { $doc = ConvertFrom-Json -InputObject $run.Stdout }
    } catch {
        $doc = $null
    }
    if ($null -eq $doc) {
        Stop-Rea -Code $script:EX_STEP -Step profile -Message 'agent-profile claude doctor printed output that is not JSON'
    }
    $checks = @($doc.checks)
    if ($run.ExitCode -eq 5) {
        $failed = @($checks | Where-Object { $null -ne $_ -and $_.status -eq 'fail' } | ForEach-Object { [string]$_.id })
        Write-ReaLog WARN profile ('agent-profile doctor reports failing checks (' + ($failed -join ' ') + '); create decides')
    }
    $value = ''
    $launchCheck = $checks | Where-Object { $null -ne $_ -and $_.id -eq 'launch_environment' } | Select-Object -First 1
    if ($launchCheck -and $launchCheck.data -and $null -ne $launchCheck.data.value) {
        $value = [string]$launchCheck.data.value
    }
    if (Test-ReaProfileDirShared -Dir $value) {
        Stop-Rea -Code $script:EX_STEP -Step profile -Message 'agent-profile did not report a profile-specific CLAUDE_CONFIG_DIR'
    }
    return $value
}

# Runs `agent-profile claude create Name`; returns 'exists' when the profile was already there and 'created'
# otherwise. A failure stops with exit 1 and the end of the output, bounded to 4000 characters (the log hides
# secrets).
function Invoke-ReaProfileCreate {
    param([string]$Name, [string]$Executable)
    $run = Invoke-ReaCommand -Step profile -FilePath $Executable -ArgumentList @('claude', 'create', $Name)
    $text = ([string]$run.Stdout) + ([string]$run.Stderr)
    if ($run.ExitCode -ne 0) {
        if ($text.Length -gt 4000) { $text = $text.Substring($text.Length - 4000) }
        Stop-Rea -Code $script:EX_STEP -Step profile -Message "agent-profile claude create exited $($run.ExitCode): $text"
    }
    if ($text.Contains('already exists')) { return 'exists' }
    return 'created'
}

# Finds the profile's CLAUDE_CONFIG_DIR with agent-profile doctor, creates the profile when it is not there yet and
# requires the directory to exist. Sets ClaudeConfigDirSelected (and the environment variable of that name for the
# later steps) and the summary. A dry run only runs doctor (read-only); -CheckUpstream skips the step. It never
# touches the .claude directory or .claude.json of the home directory.
function Invoke-ReaStepProfile {
    if ($script:Opt.CheckUpstream) {
        Write-ReaLog INFO profile 'skip (-CheckUpstream)'
        $script:Summary['profile'] = 'skipped: -CheckUpstream'
        return
    }
    $name = $script:Opt.ProfileName
    $exe = Resolve-ReaExecutable -Name 'agent-profile'
    if (-not $exe) {
        if ($script:Opt.DryRun) {
            Write-ReaLog INFO profile 'agent-profile is not installed (read-only run); would run doctor and create'
            $script:Summary['profile'] = 'not checked: agent-profile is not installed (read-only run)'
            return
        }
        Stop-Rea -Code $script:EX_STEP -Step profile -Message 'agent-profile not found on PATH after the tools-bin step'
    }
    $dir = Get-ReaProfileConfigDir -Name $name -Executable $exe
    if ($script:Opt.DryRun) {
        $script:ClaudeConfigDirSelected = $dir
        $env:CLAUDE_CONFIG_DIR_SELECTED = $dir
        Write-ReaLog INFO profile ('would use ' + (Get-ReaShortPath $dir) + ' (read-only run, nothing created)')
        $script:Summary['profile'] = "would use $dir (not created: read-only run)"
        return
    }
    $made = Invoke-ReaProfileCreate -Name $name -Executable $exe
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Stop-Rea -Code $script:EX_STEP -Step profile -Message "the profile directory does not exist after create: $dir"
    }
    $script:ClaudeConfigDirSelected = $dir
    $env:CLAUDE_CONFIG_DIR_SELECTED = $dir
    if ($made -eq 'exists') {
        Write-ReaLog INFO profile ('skip (already exists): ' + (Get-ReaShortPath $dir))
        $script:Summary['profile'] = "reused ${name}: $dir"
    } else {
        Write-ReaLog INFO profile ("created ${name}: " + (Get-ReaShortPath $dir))
        $script:Summary['profile'] = "created ${name}: $dir"
    }
    Write-ReaLog INFO profile 'ok'
}

# --- steps rea-setup and rea-doctor ---

$script:HintReaGhidraLine = 'rea 6.8.0 accepts Ghidra 12.1.x; if rea now requires another line, update the pins block (PIN_GHIDRA_*)'
$script:NoteMacDecompiler = 'build it as rea docs/installation.md describes (sections "Missing macOS native decompiler" and "macOS arm64 native decompiler")'
$script:ReaEnvironmentNames = @('CLAUDE_CONFIG_DIR', 'GHIDRA_INSTALL_DIR', 'JAVA_HOME')

# True when Text is a JSON object; Doc receives it.
function Test-ReaJsonObject {
    param([AllowEmptyString()][string]$Json, [ref]$Doc)
    $parsed = $null
    try {
        if ($Json -and $Json.Trim()) { $parsed = ConvertFrom-Json -InputObject $Json }
    } catch {
        $parsed = $null
    }
    if ($parsed -is [System.Management.Automation.PSCustomObject]) {
        if ($null -ne $Doc) { $Doc.Value = $parsed }
        return $true
    }
    return $false
}

# Stops with exit 1 unless the profile directory, the Ghidra directory and the JDK are known and the profile
# directory is not the shared .claude (defence in depth: the setup must never write there).
function Assert-ReaEnvironmentReady {
    param([string]$Step)
    if (-not $script:ClaudeConfigDirSelected) {
        Stop-Rea -Code $script:EX_STEP -Step $Step -Message 'no profile directory was selected (ClaudeConfigDirSelected is empty)'
    }
    if (Test-ReaProfileDirShared -Dir $script:ClaudeConfigDirSelected) {
        Stop-Rea -Code $script:EX_STEP -Step $Step -Message "refusing to run rea with the shared Claude directory: $($script:ClaudeConfigDirSelected)"
    }
    if (-not $script:GhidraDirSelected) {
        Stop-Rea -Code $script:EX_STEP -Step $Step -Message 'no Ghidra directory was selected (GhidraDirSelected is empty)'
    }
    if (-not $script:JavaHomeSelected) {
        Stop-Rea -Code $script:EX_STEP -Step $Step -Message 'no JDK was selected (JavaHomeSelected is empty)'
    }
}

# Runs `npx -y <PIN_REA_SPEC> ArgumentList` with CLAUDE_CONFIG_DIR, GHIDRA_INSTALL_DIR and JAVA_HOME set for that
# child only: the environment variables are set, the child runs, and the previous values (absent included) come
# back in finally. Returns what Invoke-ReaCommand returns.
function Invoke-ReaEnvironmentCommand {
    param([string]$Step, [string[]]$ArgumentList = @())
    $exe = Resolve-ReaExecutable -Name 'npx'
    if (-not $exe) {
        Stop-Rea -Code $script:EX_PREREQ -Step $Step -Message "npx not found; it ships with Node; $script:HintNode"
    }
    $values = @{
        'CLAUDE_CONFIG_DIR'  = $script:ClaudeConfigDirSelected
        'GHIDRA_INSTALL_DIR' = $script:GhidraDirSelected
        'JAVA_HOME'          = $script:JavaHomeSelected
    }
    $saved = @{}
    foreach ($name in $script:ReaEnvironmentNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        foreach ($name in $script:ReaEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, [string]$values[$name], 'Process')
        }
        return (Invoke-ReaCommand -Step $Step -FilePath $exe -ArgumentList (@('-y', $script:PIN_REA_SPEC) + $ArgumentList))
    } finally {
        foreach ($name in $script:ReaEnvironmentNames) {
            if ($null -eq $saved[$name]) {
                Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, [string]$saved[$name], 'Process')
            }
        }
    }
}

# True only for the boolean true: PowerShell compares the string 'true' equal to $true, JSON "true" is not true.
function Test-ReaJsonTrue {
    param($Value)
    return (($Value -is [bool]) -and $Value)
}

# True when the doctor answer has healthy true; false, a missing field and text that is not a JSON object are all false.
function Test-ReaDoctorHealthy {
    param([AllowEmptyString()][string]$Json)
    $doc = $null
    if (-not (Test-ReaJsonObject -Json $Json -Doc ([ref]$doc))) { return $false }
    return (Test-ReaJsonTrue $doc.healthy)
}

# The names of the scope_checks of a doctor answer whose ok is not true.
function Get-ReaDoctorFailing {
    param([AllowEmptyString()][string]$Json)
    $doc = $null
    if (-not (Test-ReaJsonObject -Json $Json -Doc ([ref]$doc))) { return @() }
    return @(@($doc.scope_checks) | Where-Object { $null -ne $_ -and -not (Test-ReaJsonTrue $_.ok) } | ForEach-Object { [string]$_.name })
}

# The ghidra provider of a doctor answer: Available (bool), Version ('-' when there is none) and Failing (the names
# of its checks whose ok is not true). A missing ghidra provider is unavailable with the check name
# ghidra_provider_missing; text that is not a JSON object gives $null.
function Get-ReaGhidraStatus {
    param([AllowEmptyString()][string]$Json)
    $doc = $null
    if (-not (Test-ReaJsonObject -Json $Json -Doc ([ref]$doc))) { return $null }
    $provider = @($doc.providerInspections) | Where-Object { $null -ne $_ -and $_.id -eq 'ghidra' } | Select-Object -First 1
    if ($null -eq $provider) {
        return [pscustomobject]@{ Available = $false; Version = '-'; Failing = @('ghidra_provider_missing') }
    }
    $version = '-'
    if ($provider.providerVersion) { $version = [string]$provider.providerVersion }
    $failing = @(@($provider.checks) | Where-Object { $null -ne $_ -and -not (Test-ReaJsonTrue $_.ok) } | ForEach-Object { [string]$_.name })
    return [pscustomobject]@{ Available = (Test-ReaJsonTrue $provider.available); Version = $version; Failing = $failing }
}

# The end of a stderr text, redacted first (so a cut cannot slice a secret name off its value), trailing whitespace
# dropped, at most 1000 characters: the last 1000 without their partial first line; one long line has no boundary,
# so its last 1000 characters come back marked with a leading '...'.
function Get-ReaStderrTail {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -gt 20000) { $Text = $Text.Substring($Text.Length - 20000) }
    $clean = (Hide-ReaSecret $Text).TrimEnd()
    if ($clean.Length -le 1000) { return $clean.Trim() }
    $window = $clean.Substring($clean.Length - 1000)
    $cut = $window.IndexOf("`n")
    if ($cut -ge 0) {
        $rest = $window.Substring($cut + 1).Trim()
        if ($rest) { return $rest }
    }
    return '...' + $window
}

# The raw doctor answer to the log at DEBUG (the file; the console only at DEBUG), bounded to 200000 characters with
# a marker; Write-ReaLog hides secrets and shortens the home directory.
function Write-ReaJsonLog {
    param([string]$Step, [string]$Label, [AllowEmptyString()][string]$Text)
    $shown = $Text
    if ($null -eq $shown) { $shown = '' }
    if ($shown.Length -gt 200000) {
        $shown = $shown.Substring(0, 200000) + ' [output truncated at 200000 characters]'
    }
    Write-ReaLog -Level DEBUG -Step $Step -Message ("$Label output: " + $shown.Trim())
}

# rea doctor ArgumentList through Invoke-ReaEnvironmentCommand. Exit 0 and 1 are both read (1 is how rea reports an
# unhealthy answer, and its JSON names what failed); any other exit code, and an answer that is not a JSON object,
# stop with exit 5 and the end of stderr. The raw answer goes to the log. Returns ExitCode and Json; the caller
# decides the verdict from both.
function Invoke-ReaDoctorRun {
    param([string]$Step, [string[]]$ArgumentList)
    $run = Invoke-ReaEnvironmentCommand -Step $Step -ArgumentList (@('doctor') + $ArgumentList)
    $tail = Get-ReaStderrTail -Text ([string]$run.Stderr)
    $label = 'rea doctor ' + ($ArgumentList -join ' ')
    Write-ReaJsonLog -Step $Step -Label $label -Text ([string]$run.Stdout)
    if ($run.ExitCode -ne 0 -and $run.ExitCode -ne 1) {
        Stop-Rea -Code $script:EX_VERIFY -Step $Step -Message "$label exited $($run.ExitCode): $tail"
    }
    $unused = $null
    if (-not (Test-ReaJsonObject -Json ([string]$run.Stdout) -Doc ([ref]$unused))) {
        Stop-Rea -Code $script:EX_VERIFY -Step $Step -Message "$label printed output that is not a JSON object (exit $($run.ExitCode)): $tail"
    }
    return [pscustomobject]@{ ExitCode = [int]$run.ExitCode; Json = [string]$run.Stdout }
}

# Registers rea in the profile with `rea setup`. A dry run of rea first (stdout at DEBUG), then the real setup unless
# -DryRun; the profile's .claude.json must then hold mcpServers.rea. It never touches the .claude.json of the home
# directory: CLAUDE_CONFIG_DIR points rea at the profile.
function Invoke-ReaStepReaSetup {
    if ($script:Opt.CheckUpstream) {
        Write-ReaLog INFO rea-setup 'skip (-CheckUpstream)'
        $script:Summary['rea_setup'] = 'skipped: -CheckUpstream'
        return
    }
    if ($script:Opt.DryRun -and (-not $script:ClaudeConfigDirSelected -or -not $script:GhidraDirSelected -or -not $script:JavaHomeSelected)) {
        Write-ReaLog INFO rea-setup 'skip (read-only run: no profile, Ghidra or JDK was selected, so rea has no environment to run in)'
        $script:Summary['rea_setup'] = 'skipped: read-only run'
        return
    }
    Assert-ReaEnvironmentReady -Step rea-setup
    $dry = Invoke-ReaEnvironmentCommand -Step rea-setup -ArgumentList @('setup', '--client', 'claude_code', '--dry-run')
    $out = [string]$dry.Stdout
    if ($out.Length -gt 4000) { $out = $out.Substring(0, 4000) }
    Write-ReaLog DEBUG rea-setup ('rea setup dry-run output: ' + $out.Trim())
    if ($dry.ExitCode -ne 0) {
        Stop-Rea -Code $script:EX_STEP -Step rea-setup -Message "rea setup --dry-run exited $($dry.ExitCode): $(Get-ReaStderrTail -Text ([string]$dry.Stderr))"
    }
    if ($script:Opt.DryRun) {
        Write-ReaLog INFO rea-setup ('skip (read-only run): rea setup would register rea in ' + (Get-ReaShortPath $script:ClaudeConfigDirSelected))
        $script:Summary['rea_setup'] = 'not run: read-only run'
        return
    }
    $setupArgs = @('setup', '--client', 'claude_code', '--yes')
    if ($script:Opt.InstallHopper) { $setupArgs += '--install-hopper' }
    $run = Invoke-ReaEnvironmentCommand -Step rea-setup -ArgumentList $setupArgs
    if ($run.ExitCode -ne 0) {
        Stop-Rea -Code $script:EX_STEP -Step rea-setup -Message "rea setup exited $($run.ExitCode): $(Get-ReaStderrTail -Text ([string]$run.Stderr))"
    }
    $cfg = Join-Path $script:ClaudeConfigDirSelected '.claude.json'
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) {
        Stop-Rea -Code $script:EX_STEP -Step rea-setup -Message "rea setup left no .claude.json in $($script:ClaudeConfigDirSelected)"
    }
    $doc = $null
    $registered = $false
    if (Test-ReaJsonObject -Json ([System.IO.File]::ReadAllText($cfg)) -Doc ([ref]$doc)) {
        $registered = ($null -ne $doc.mcpServers) -and ($doc.mcpServers.rea -is [System.Management.Automation.PSCustomObject])
    }
    if (-not $registered) {
        Stop-Rea -Code $script:EX_STEP -Step rea-setup -Message "$cfg has no mcpServers.rea after rea setup"
    }
    $script:Summary['rea_setup'] = "registered rea in $($script:ClaudeConfigDirSelected)"
    Write-ReaLog INFO rea-setup 'ok'
}

# rea doctor for the client scope (healthy, else exit 5 naming the failing scope_checks), then for the ghidra provider.
# A Ghidra that is not available is exit 5, except on macOS when only native_decompiler fails: that is a WARN with the
# recipe pointer and a warn summary (the official archive has no macOS native decompiler), reported on every run.
# Skipped by -DryRun and -CheckUpstream.
function Invoke-ReaStepReaDoctor {
    if ($script:Opt.CheckUpstream) {
        Write-ReaLog INFO rea-doctor 'skip (-CheckUpstream)'
        $script:Summary['rea_doctor'] = 'skipped: -CheckUpstream'
        return
    }
    if ($script:Opt.DryRun) {
        Write-ReaLog INFO rea-doctor 'skip (-DryRun): nothing was registered to check'
        $script:Summary['rea_doctor'] = 'skipped: -DryRun'
        return
    }
    Assert-ReaEnvironmentReady -Step rea-doctor
    $client = Invoke-ReaDoctorRun -Step rea-doctor -ArgumentList @('--client', 'claude_code', '--skill', '--json')
    if (-not (Test-ReaDoctorHealthy -Json $client.Json)) {
        $names = (Get-ReaDoctorFailing -Json $client.Json) -join ' '
        if (-not $names) { $names = 'none listed (healthy is not true)' }
        Stop-Rea -Code $script:EX_VERIFY -Step rea-doctor -Message "rea doctor reports the Claude Code setup unhealthy (exit $($client.ExitCode)); failing checks: $names"
    }
    if ($client.ExitCode -ne 0) {
        Stop-Rea -Code $script:EX_VERIFY -Step rea-doctor -Message "rea doctor exited $($client.ExitCode) but its JSON says healthy is true: the exit code and the JSON disagree"
    }
    $ghidra = Invoke-ReaDoctorRun -Step rea-doctor -ArgumentList @('--provider', 'ghidra', '--json')
    $status = Get-ReaGhidraStatus -Json $ghidra.Json
    $names = ($status.Failing -join ',')
    Write-ReaLog DEBUG rea-doctor ("ghidra provider: available={0} version={1} failing={2} exit={3}" -f $status.Available, $status.Version, $names, $ghidra.ExitCode)
    if ($status.Available) {
        if ($ghidra.ExitCode -ne 0) {
            Stop-Rea -Code $script:EX_VERIFY -Step rea-doctor -Message "rea doctor exited $($ghidra.ExitCode) but its JSON says the Ghidra provider is available: the exit code and the JSON disagree"
        }
        $script:Summary['rea_doctor'] = "ok: ghidra $($status.Version)"
        Write-ReaLog INFO rea-doctor 'ok'
        return
    }
    if (([string](Get-ReaPlatform).Os) -eq 'mac' -and $names -eq 'native_decompiler') {
        Write-ReaLog WARN rea-doctor "rea reports the native decompiler of $($script:GhidraDirSelected) missing; $script:NoteMacDecompiler. rea cannot decompile until then; continuing"
        $script:Summary['rea_doctor'] = "warn: ghidra installed but not usable by rea until the native decompiler is built ($($script:GhidraDirSelected))"
        return
    }
    if ($status.Failing -contains 'version') {
        Stop-Rea -Code $script:EX_VERIFY -Step rea-doctor -Message "rea reports the Ghidra provider unavailable; failing checks: $names. $script:HintReaGhidraLine"
    }
    if (-not $names) { $names = 'none listed' }
    Stop-Rea -Code $script:EX_VERIFY -Step rea-doctor -Message "rea reports the Ghidra provider unavailable; failing checks: $names"
}

# --- plan phase: resolution and validity checks only, no download and no write ---

# What the plan phase decided for each step ('install', 'update', 'reuse' or 'skip'), a line of text for the
# plan and the disclosures, and the download sizes in bytes. The resolutions the plan made are kept for the
# steps (each step consumes its own and clears it).
$script:PlanToolsBin = ''
$script:PlanJdk = ''
$script:PlanGhidra = ''
$script:PlanToolsBinText = ''
$script:PlanJdkText = ''
$script:PlanGhidraText = ''
$script:PlanJdkBytes = [int64]0
$script:PlanGhidraBytes = [int64]0
$script:ToolsBinPlanned = $null
# The size of the Temurin 21 archive (208 MiB, measured) when the release listing gave none.
$script:JdkDownloadEstimateBytes = [int64]218103808
$script:EnvFile = ''

# Writes one line on stdout (the final summary and the answers a caller may read). One function so a test can
# capture it; a function cannot return it, because its output would join the exit code.
function Write-ReaOutput {
    param([AllowEmptyString()][string]$Text)
    [Console]::Out.WriteLine($Text)
}

# Writes one line on stderr, for what the user reads before the question.
function Write-ReaNotice {
    param([AllowEmptyString()][string]$Text)
    [Console]::Error.WriteLine($Text)
}

# Bytes in megabytes (MiB), one decimal, with a point whatever the culture.
function Format-ReaMegabyte {
    param([int64]$Bytes)
    return ([double]$Bytes / 1MB).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

# install, update or reuse for one managed tool.
function Get-ReaToolDecision {
    param([string]$Name, [string]$Latest)
    $have = Get-ReaInstalledVersion -Name $Name
    if (-not $have) { return 'install' }
    if ((Compare-ReaSemver $have $Latest) -eq -1) { return 'update' }
    return 'reuse'
}

# Resolves the latest agent-profile and clavity-ls (the answers are kept for Invoke-ReaStepToolsBin) and sets
# PlanToolsBin to install (one is missing), update (one is behind) or reuse. Skipped by -CheckUpstream.
function Invoke-ReaPlanToolsBin {
    if ($script:Opt.CheckUpstream) { return }
    $platform = Get-ReaPlatform
    $ap = Resolve-ReaAgentProfile -Os $platform.Os -Arch $platform.Arch
    if (-not $ap) {
        Stop-Rea -Code $script:EX_PLATFORM -Step tools-bin -Message "no agent-profile build for $($platform.Os) $($platform.Arch)"
    }
    $cl = Resolve-ReaClavityRelease -Os $platform.Os -Arch $platform.Arch
    if (-not $cl) {
        Stop-Rea -Code $script:EX_PLATFORM -Step tools-bin -Message "no clavity-ls build for $($platform.Os) $($platform.Arch)"
    }
    $script:ToolsBinPlanned = [pscustomobject]@{ AgentProfile = $ap; Clavity = $cl }
    $apDecision = Get-ReaToolDecision -Name 'agent-profile' -Latest $ap.Version
    $clDecision = Get-ReaToolDecision -Name 'clavity-ls' -Latest $cl.Version
    $script:PlanToolsBin = 'reuse'
    if ($apDecision -eq 'update' -or $clDecision -eq 'update') { $script:PlanToolsBin = 'update' }
    if ($apDecision -eq 'install' -or $clDecision -eq 'install') { $script:PlanToolsBin = 'install' }
    $script:PlanToolsBinText = "agent-profile $($ap.Version) ($apDecision), clavity-ls $($cl.Version) ($clDecision) in $script:BinDir"
    Write-ReaLog INFO plan "tools-bin: $script:PlanToolsBin ($script:PlanToolsBinText)"
}

# Sets PlanJdk to reuse (Select-ReaJdk picked one) or install (the release is resolved; the answer is kept for
# Install-ReaJdk) and PlanJdkBytes to the download size.
function Invoke-ReaPlanJdk {
    if ($script:Opt.CheckUpstream) { return }
    Select-ReaJdk -PlanOnly
    if ($script:JdkReused) {
        $script:PlanJdk = 'reuse'
        $script:PlanJdkBytes = [int64]0
        $script:PlanJdkText = $script:JavaHomeSelected
    } else {
        $platform = Get-ReaPlatform
        $jdk = Resolve-ReaJdkRelease -Os $platform.Os -Arch $platform.Arch
        $script:JdkPlanned = $jdk
        $script:PlanJdk = 'install'
        $script:PlanJdkBytes = $script:JdkDownloadEstimateBytes
        if ($jdk.Bytes) { $script:PlanJdkBytes = [int64]$jdk.Bytes }
        $script:PlanJdkText = "$($jdk.Release) into $script:ToolsDir"
    }
    Write-ReaLog INFO plan "jdk: $script:PlanJdk ($script:PlanJdkText)"
}

# Sets PlanGhidra to reuse (Select-ReaGhidra picked one) or install, and PlanGhidraBytes.
function Invoke-ReaPlanGhidra {
    if ($script:Opt.CheckUpstream) { return }
    Select-ReaGhidra -PlanOnly
    if ($script:GhidraReused) {
        $script:PlanGhidra = 'reuse'
        $script:PlanGhidraBytes = [int64]0
        $script:PlanGhidraText = $script:GhidraDirSelected
    } else {
        $script:PlanGhidra = 'install'
        $script:PlanGhidraBytes = [int64]$script:PIN_GHIDRA_ZIP_BYTES
        $script:PlanGhidraText = "Ghidra $script:PIN_GHIDRA_VERSION into $(Join-Path $script:ToolsDir $script:PIN_GHIDRA_TOPDIR)"
    }
    Write-ReaLog INFO plan "ghidra: $script:PlanGhidra ($script:PlanGhidraText)"
}

# The free space the pending installs need: 1500 MB for Ghidra, 600 for the JDK, 200 for the rest.
function Get-ReaNeededMb {
    $mb = 200
    if ($script:PlanGhidra -eq 'install') { $mb += 1500 }
    if ($script:PlanJdk -eq 'install') { $mb += 600 }
    return $mb
}

# The four things the user is told before anything is downloaded (spec section 10), on stderr.
function Write-ReaDisclosure {
    $bytes = $script:PlanGhidraBytes + $script:PlanJdkBytes
    Write-ReaNotice 'Before anything is changed, please note:'
    if ($bytes -gt 0) {
        Write-ReaNotice ("  1. Download: {0} MB in total (Ghidra {1} MB, JDK {2} MB), unpacked under {3}; agent-profile and clavity-ls go to {4} when they are new or outdated." -f (Format-ReaMegabyte $bytes), (Format-ReaMegabyte $script:PlanGhidraBytes), (Format-ReaMegabyte $script:PlanJdkBytes), $script:ToolsDir, $script:BinDir)
    } else {
        Write-ReaNotice ("  1. Download: nothing for Ghidra and the JDK (both are already there); agent-profile and clavity-ls go to {0} when they are new or outdated." -f $script:BinDir)
    }
    Write-ReaNotice '  2. clavity-ls start always runs agy with --dangerously-skip-permissions, and agy is not isolated by the profile (it shares ~/.gemini/antigravity-cli/).'
    Write-ReaNotice '  3. --install-hopper may ask for administrator rights and installs commercial demo software.'
    Write-ReaNotice '  4. npx -y rea-agents@latest downloads and runs the newest published npm package with your rights.'
}

# would install, would update, would reuse or skip, then Text.
function Format-ReaPlanPhrase {
    param([string]$Plan, [string]$Text)
    if ($Plan -eq 'install' -or $Plan -eq 'update' -or $Plan -eq 'reuse') { return "would $Plan $Text" }
    return "skip $Text"
}

# One line per step, on stderr.
function Show-ReaPlanSummary {
    $jdkText = '{0} ({1} MB)' -f $script:PlanJdkText, (Format-ReaMegabyte $script:PlanJdkBytes)
    $ghidraText = '{0} ({1} MB)' -f $script:PlanGhidraText, (Format-ReaMegabyte $script:PlanGhidraBytes)
    Write-ReaNotice 'Plan:'
    Write-ReaNotice ('  {0,-10} {1}' -f 'tools-bin:', (Format-ReaPlanPhrase $script:PlanToolsBin $script:PlanToolsBinText))
    Write-ReaNotice ('  {0,-10} {1}' -f 'jdk:', (Format-ReaPlanPhrase $script:PlanJdk $jdkText))
    Write-ReaNotice ('  {0,-10} {1}' -f 'ghidra:', (Format-ReaPlanPhrase $script:PlanGhidra $ghidraText))
    Write-ReaNotice ('  {0,-10} would create or reuse the agent-profile profile {1}' -f 'profile:', $script:Opt.ProfileName)
    Write-ReaNotice ('  {0,-10} would register rea in that profile' -f 'rea-setup:')
    Write-ReaNotice ('  {0,-10} would check the registration and Ghidra' -f 'rea-doctor:')
    if ($script:Opt.NoLaunch) {
        Write-ReaNotice ('  {0,-10} skip (-NoLaunch)' -f 'launch:')
    } else {
        Write-ReaNotice ('  {0,-10} would start clavity-ls on {1}' -f 'launch:', $script:Opt.Folder)
    }
}

# The free-space check for every pending install at once, the disclosures, the plan and the question. Returns
# $false when the user declines (after printing `nothing changed` on stdout); the caller then exits 0. Skipped by
# -CheckUpstream; -DryRun prints and never asks.
function Invoke-ReaPlanConfirm {
    if ($script:Opt.CheckUpstream) { return $true }
    $needed = Get-ReaNeededMb
    Write-ReaLog DEBUG plan "free space needed: $needed MB"
    Assert-ReaFreeMb -Path $script:ToolsDir -Mb $needed
    Write-ReaDisclosure
    Show-ReaPlanSummary
    if ($script:Opt.DryRun) {
        Write-ReaLog INFO plan 'dry run: nothing will be changed'
        return $true
    }
    if (-not (Read-ReaConfirm -Prompt 'Proceed?')) {
        Write-ReaLog INFO plan 'declined'
        Write-ReaOutput 'nothing changed'
        return $false
    }
    return $true
}

# --- env file, summary and launch ---

# Text in single quotes, each embedded single quote (the ASCII one and the four typographic ones) doubled (safe for
# any PowerShell).
function ConvertTo-ReaPsQuoted {
    param([AllowEmptyString()][string]$Text)
    # PowerShell reads U+2018, U+2019, U+201A and U+201B as single quotes too (a user name like O'Brien is often
    # typed with U+2019), so each of the five is doubled; the escapes keep this file ASCII.
    return ("'" + [regex]::Replace($Text, '[\u0027\u2018\u2019\u201A\u201B]', '$0$0') + "'")
}

# Writes ToolsDir\env.ps1, which sets GHIDRA_INSTALL_DIR and JAVA_HOME and puts the bin directory first on PATH,
# for a terminal that does not inherit this script's environment. Written to a temporary file and moved over the
# old one on every run, in UTF-8 with a byte-order mark (Windows PowerShell 5.1 reads a script without one as ANSI,
# which would damage a non-ASCII user name in a path). A dry run writes nothing.
function Write-ReaEnvFile {
    param([string]$ToolsDir)
    $script:EnvFile = ''
    if ($script:Opt.CheckUpstream) { return }
    $file = Join-Path $ToolsDir 'env.ps1'
    if ($script:Opt.DryRun) {
        Write-ReaLog INFO env "would write $file"
        return
    }
    if (-not $script:GhidraDirSelected -or -not $script:JavaHomeSelected) {
        Stop-Rea -Code $script:EX_STEP -Step env -Message "cannot write ${file}: no Ghidra or JDK was selected"
    }
    try {
        [System.IO.Directory]::CreateDirectory($ToolsDir) | Out-Null
    } catch {
        Stop-Rea -Code $script:EX_STEP -Step env -Message "cannot create directory: $ToolsDir"
    }
    $lines = @(
        '# Written by setup.ps1 on every run. Dot-source it in a terminal that does not inherit its environment.',
        ('$env:GHIDRA_INSTALL_DIR = ' + (ConvertTo-ReaPsQuoted $script:GhidraDirSelected)),
        ('$env:JAVA_HOME = ' + (ConvertTo-ReaPsQuoted $script:JavaHomeSelected)),
        ('$env:PATH = ' + (ConvertTo-ReaPsQuoted $script:BinDir) + ' + [System.IO.Path]::PathSeparator + $env:PATH')
    )
    $tmp = "$file.tmp.$PID"
    Register-ReaTempFile -Path $tmp
    try {
        [System.IO.File]::WriteAllText($tmp, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding $true))
        Move-ReaIntoPlace -Source $tmp -Destination $file
    } catch {
        Stop-Rea -Code $script:EX_STEP -Step env -Message "cannot write ${file}: $($_.Exception.Message)"
    }
    $script:EnvFile = $file
    Write-ReaLog INFO env ('wrote ' + (Get-ReaShortPath $file))
}

# What was installed, reused or skipped, where, and what to do next; on stdout, before the launch.
function Write-ReaSummary {
    if ($script:Opt.CheckUpstream) { return }
    if ($script:Opt.DryRun) {
        Write-ReaOutput 'Dry run: nothing was changed. Plan result:'
    } else {
        Write-ReaOutput 'Setup summary:'
    }
    Write-ReaOutput ('  profile:     ' + $script:Summary['profile'])
    Write-ReaOutput ('  tools-bin:   in ' + $script:BinDir)
    foreach ($line in @(([string]$script:Summary['tools_bin']) -split "`r?`n")) {
        Write-ReaOutput ('               ' + $line)
    }
    Write-ReaOutput ('  jdk:         ' + $script:Summary['jdk'])
    Write-ReaOutput ('  ghidra:      ' + $script:Summary['ghidra'])
    Write-ReaOutput ('  rea setup:   ' + $script:Summary['rea_setup'])
    Write-ReaOutput ('  rea doctor:  ' + $script:Summary['rea_doctor'])
    Write-ReaOutput ('  log file:    ' + $script:LogFile)
    if ($script:EnvFile) {
        Write-ReaOutput ('  env file:    ' + $script:EnvFile)
    } else {
        Write-ReaOutput '  env file:    not written'
    }
    Write-ReaOutput 'Next:'
    Write-ReaOutput ('  clavity-ls start "{0}" --profile {1}' -f $script:Opt.Folder, $script:Opt.ProfileName)
    Write-ReaOutput '  (to launch again, run this script again: it skips everything that is already in place)'
}

# The two-terminal flow, for a machine where clavity-ls cannot open a terminal itself; -Soft is for a start that
# failed quickly, where the message above may or may not be about a terminal.
function Write-ReaLaunchInstruction {
    param([switch]$Soft)
    $envFile = Join-Path $script:ToolsDir 'env.ps1'
    if ($Soft) {
        Write-ReaOutput 'If the message above says clavity-ls could not open a terminal, use two terminals:'
    } else {
        Write-ReaOutput 'Setup is complete. clavity-ls cannot open a terminal here, so start it from two terminals.'
    }
    Write-ReaOutput 'Terminal 1:'
    Write-ReaOutput ('  . "{0}"' -f $envFile)
    Write-ReaOutput ('  clavity-ls agy "{0}"' -f $script:Opt.Folder)
    Write-ReaOutput 'Terminal 2:'
    Write-ReaOutput ('  . "{0}"' -f $envFile)
    Write-ReaOutput ('  clavity-ls start "{0}" --attach --profile {1}' -f $script:Opt.Folder, $script:Opt.ProfileName)
    Write-ReaOutput 'Use these commands exactly as written: the attach hint that clavity-ls agy prints omits --profile, and must not be used, because it would start Claude on your default profile.'
}

# An exit 1 sooner than this many seconds after the start is how clavity-ls start fails to open a terminal.
$script:LaunchShortSeconds = 10

# Runs FilePath with ArgumentList and the variables in Environment in the child's environment only. Nothing is
# redirected: the child has this process's stdin, stdout and stderr, so a terminal window it opens (which keeps
# them open) cannot hold this function back once the child has exited. Returns ExitCode and the Seconds it ran.
function Start-ReaLaunchProcess {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
    param([string]$FilePath, [string[]]$ArgumentList, [hashtable]$Environment)
    if (-not $PSCmdlet.ShouldProcess($FilePath, 'start')) { return }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-ReaQuotedArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    foreach ($name in $Environment.Keys) { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    $watch.Stop()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Seconds = $watch.Elapsed.TotalSeconds }
}

# The last step; returns clavity-ls start's own exit code. -NoLaunch prints the command; a dry run logs what it
# would do; otherwise clavity-ls start runs directly (Windows has Windows Terminal, which clavity-ls uses) with all
# stdio inherited, and when it exits 1 in under LaunchShortSeconds seconds the two-terminal flow is printed too, as a
# hint (the exit code stays the child's).
function Invoke-ReaStepLaunch {
    if ($script:Opt.CheckUpstream) { return $script:EX_OK }
    $folder = $script:Opt.Folder
    $name = $script:Opt.ProfileName
    if ($script:Opt.DryRun) {
        Write-ReaLog INFO launch "would run: clavity-ls start `"$folder`" --profile $name"
        return $script:EX_OK
    }
    if ($script:Opt.NoLaunch) {
        Write-ReaLog INFO launch 'skip (-NoLaunch)'
        Write-ReaOutput ('launch skipped (-NoLaunch); run: clavity-ls start "{0}" --profile {1}' -f $folder, $name)
        return $script:EX_OK
    }
    $exe = Resolve-ReaExecutable -Name 'clavity-ls'
    if (-not $exe) {
        Stop-Rea -Code $script:EX_STEP -Step launch -Message 'clavity-ls not found on PATH after the tools-bin step'
    }
    $childPath = $script:BinDir + [System.IO.Path]::PathSeparator + $env:PATH
    $childEnv = @{ GHIDRA_INSTALL_DIR = $script:GhidraDirSelected; JAVA_HOME = $script:JavaHomeSelected; PATH = $childPath }
    Write-ReaLog INFO launch "running clavity-ls start `"$folder`" --profile $name"
    $run = Start-ReaLaunchProcess -FilePath $exe -ArgumentList @('start', $folder, '--profile', $name) -Environment $childEnv
    $code = [int]$run.ExitCode
    Write-ReaLog INFO launch "launch exited $code"
    if ($code -eq 1 -and [double]$run.Seconds -lt $script:LaunchShortSeconds) {
        Write-ReaLaunchInstruction -Soft
    }
    return $code
}

# --- step check-upstream ---

# The SHA-256 held by the sidecar file at Url (redirects resolved, the small file fetched into a temporary file
# that is removed); $null when it cannot be fetched or holds no 64-hex token.
function Get-ReaUpstreamSidecar {
    param([string]$Url)
    $resolved = Resolve-ReaRedirect -Url $Url
    if ($resolved.Code -ne 0) { return $null }
    $tmp = [System.IO.Path]::GetTempFileName()
    Register-ReaTempFile $tmp
    try {
        if (-not (Invoke-ReaHttpGet -Url $resolved.Url -Destination $tmp)) { return $null }
        return (Get-ReaSidecarSha256 -Path $tmp)
    } finally {
        Clear-ReaTempFile -Path $tmp
    }
}

# The size in bytes of the file at Url without fetching it: the Content-Length of a HEAD or, when the HEAD is
# refused (403, 405), the total of the Content-Range of a one-byte GET. 5xx and a failed connection are retried
# like Invoke-ReaHttpGet does. $null when no size can be read.
function Get-ReaContentLength {
    param([string]$Url)
    $waits = @($script:RetryWaits)
    for ($attempt = 1; $attempt -le $waits.Count; $attempt++) {
        $r = Send-ReaHeadRequest -Url $Url -Method 'HEAD'
        if ($r.Status -eq 403 -or $r.Status -eq 405) {
            $r = Send-ReaHeadRequest -Url $Url -Method 'RANGE'
        }
        Write-ReaLog DEBUG check-upstream "size of $Url -> $($r.Status)"
        if ($r.Status -eq 200 -and $r.ContentLength -ge 0) { return [int64]$r.ContentLength }
        if ($r.Status -eq 206 -and $r.ContentRange -match '/([0-9]+)\s*$') { return [int64]$Matches[1] }
        $transient = ($r.Status -eq 0 -or ($r.Status -ge 500 -and $r.Status -le 599))
        if (-not $transient -or $attempt -ge $waits.Count) { return $null }
        Invoke-ReaSleep -Seconds ([int]$waits[$attempt - 1])
    }
    return $null
}

# The Ghidra version the latest rea-agents release says it supports, read from SUPPORTED_GHIDRA_VERSION in the
# source of its tag. Stops with exit 5 when that is not PIN_GHIDRA_VERSION, or when the registry answer, the file
# or the constant is missing. Prints the ok line and returns ReaVersion and Ghidra.
function Get-ReaRuntimeSupportedGhidra {
    $npm = 'https://registry.npmjs.org/rea-agents/latest'
    $tmp = [System.IO.Path]::GetTempFileName()
    Register-ReaTempFile $tmp
    try {
        if (-not (Invoke-ReaHttpGet -Url $npm -Destination $tmp)) {
            Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "cannot read the latest rea-agents release from $npm"
        }
        $version = ''
        try {
            $version = [string]([System.IO.File]::ReadAllText($tmp) | ConvertFrom-Json).version
        } catch {
            $version = ''
        }
        if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+\z') {
            Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "no X.Y.Z version in the answer of $npm"
        }
        $src = "https://raw.githubusercontent.com/morluto/rea/rea-agents-$version/src/ghidra/GhidraReleasePolicy.ts"
        if (-not (Invoke-ReaHttpGet -Url $src -Destination $tmp)) {
            Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "cannot read $src"
        }
        $m = [regex]::Match([System.IO.File]::ReadAllText($tmp), '(?<![A-Za-z0-9_])SUPPORTED_GHIDRA_VERSION\s*=\s*"([0-9.]+)"')
        if (-not $m.Success) {
            Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "no SUPPORTED_GHIDRA_VERSION constant in $src"
        }
        $ghidra = $m.Groups[1].Value
        if ($ghidra -cne $script:PIN_GHIDRA_VERSION) {
            Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "rea $version now supports Ghidra $ghidra; update PIN_GHIDRA_*"
        }
        Write-ReaOutput "ok rea_supported_ghidra: rea-agents $version supports Ghidra $ghidra"
        return [pscustomobject]@{ ReaVersion = $version; Ghidra = $ghidra }
    } finally {
        Clear-ReaTempFile -Path $tmp
    }
}

# The latest aiprofiles release has the asset for this host and a 64-hex sidecar.
function Test-ReaUpstreamAgentProfile {
    param($Platform)
    $ap = Resolve-ReaAgentProfile -Os $Platform.Os -Arch $Platform.Arch
    if (-not $ap) {
        Stop-Rea -Code $script:EX_PLATFORM -Step check-upstream -Message "no agent-profile build for $($Platform.Os) $($Platform.Arch)"
    }
    if ((Resolve-ReaRedirect -Url $ap.Url).Code -ne 0) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "the agent-profile asset is missing: $($ap.Url)"
    }
    $hash = Get-ReaUpstreamSidecar -Url $ap.SidecarUrl
    if (-not $hash) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "no SHA-256 in the sidecar $($ap.SidecarUrl)"
    }
    Write-ReaOutput "ok agent-profile: $($ap.Tag) $($ap.Asset) sha256 $hash"
}

# The latest clavity release has exactly one asset for this host and a 64-hex sidecar.
function Test-ReaUpstreamClavity {
    param($Platform)
    $cl = Resolve-ReaClavityRelease -Os $Platform.Os -Arch $Platform.Arch
    if (-not $cl) {
        Stop-Rea -Code $script:EX_PLATFORM -Step check-upstream -Message "no clavity-ls build for $($Platform.Os) $($Platform.Arch)"
    }
    $hash = Get-ReaUpstreamSidecar -Url $cl.SidecarUrl
    if (-not $hash) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "no SHA-256 in the sidecar $($cl.SidecarUrl)"
    }
    Write-ReaOutput "ok clavity-ls: $($cl.Tag) $($cl.Asset) sha256 $hash"
}

# The Adoptium API answers a Temurin 21 release for this host and its .sha256.txt sidecar equals the checksum of
# the API.
function Test-ReaUpstreamAdoptium {
    param($Platform)
    $r = Resolve-ReaAdoptium -Os $Platform.Os -Arch $Platform.Arch
    if ($r.Code -eq 2) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "the Adoptium API did not answer for $($Platform.Os) $($Platform.Arch)"
    }
    if ($r.Code -ne 0) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "the Adoptium answer for $($Platform.Os) $($Platform.Arch) failed validation"
    }
    $jdk = $r.Jdk
    $sidecar = $jdk.SidecarUrl
    if (-not $sidecar) { $sidecar = $jdk.Url + '.sha256.txt' }
    $hash = Get-ReaUpstreamSidecar -Url $sidecar
    if (-not $hash) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "no SHA-256 in the sidecar $sidecar"
    }
    if ($hash -cne $jdk.Sha256) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "the sidecar $sidecar says $hash but the Adoptium API says $($jdk.Sha256)"
    }
    Write-ReaOutput "ok adoptium: $($jdk.Release) sha256 $hash"
}

# PIN_GHIDRA_URL redirects to an allow-listed host and the file there has PIN_GHIDRA_ZIP_BYTES bytes.
function Test-ReaUpstreamGhidra {
    $resolved = Resolve-ReaRedirect -Url $script:PIN_GHIDRA_URL
    if ($resolved.Code -ne 0) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "cannot resolve PIN_GHIDRA_URL $script:PIN_GHIDRA_URL"
    }
    $length = Get-ReaContentLength -Url $resolved.Url
    if ($null -eq $length) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "cannot read the size of $($resolved.Url)"
    }
    if ($length -ne [int64]$script:PIN_GHIDRA_ZIP_BYTES) {
        Stop-Rea -Code $script:EX_VERIFY -Step check-upstream -Message "Ghidra $script:PIN_GHIDRA_VERSION is $length bytes upstream but PIN_GHIDRA_ZIP_BYTES is $script:PIN_GHIDRA_ZIP_BYTES; update PIN_GHIDRA_*"
    }
    Write-ReaOutput "ok ghidra: $length bytes at $(Get-ReaUrlHost $resolved.Url)"
}

# Checks that what the pins assume still holds upstream: one ok or FAIL line per expectation, all of them even
# after a failure. Returns EX_VERIFY when any fails (whatever the cause, spec: exit 5 if any expectation breaks), 0 when all hold. Fetches no archive and
# writes nothing.
function Test-ReaUpstream {
    $platform = Get-ReaPlatform
    $first = 0
    foreach ($name in 'agent-profile', 'clavity-ls', 'adoptium', 'ghidra', 'rea_supported_ghidra') {
        try {
            switch ($name) {
                'agent-profile' { Test-ReaUpstreamAgentProfile -Platform $platform }
                'clavity-ls' { Test-ReaUpstreamClavity -Platform $platform }
                'adoptium' { Test-ReaUpstreamAdoptium -Platform $platform }
                'ghidra' { Test-ReaUpstreamGhidra }
                default { $null = Get-ReaRuntimeSupportedGhidra }
            }
        } catch {
            if ($null -eq $_.Exception.Data['ReaCode']) {
                Write-ReaLog ERROR check-upstream ('unexpected error: ' + $_.Exception.Message)
            }
            Write-ReaOutput "FAIL $name"
            $first = $script:EX_VERIFY
        }
    }
    return $first
}

# Replaces the install steps with -CheckUpstream: stops with exit 5 when any expectation fails.
function Invoke-ReaStepCheckUpstream {
    $code = Test-ReaUpstream
    if ($code -ne 0) {
        Stop-Rea -Code $code -Step check-upstream -Message 'upstream no longer matches the pins in this script'
    }
    $script:Summary['check_upstream'] = 'ok'
    Write-ReaLog INFO check-upstream 'ok'
}

# --- main ---

# Records the pins and effective options at DEBUG, the first lines of every log.
function Write-ReaConfig {
    Write-ReaLog DEBUG preflight "pins: ghidra=$script:PIN_GHIDRA_VERSION topdir=$script:PIN_GHIDRA_TOPDIR bytes=$script:PIN_GHIDRA_ZIP_BYTES unpacked_mb=$script:PIN_GHIDRA_UNPACKED_MB sha256=$script:PIN_GHIDRA_SHA256"
    Write-ReaLog DEBUG preflight "pins: ghidra_url=$script:PIN_GHIDRA_URL"
    Write-ReaLog DEBUG preflight "pins: jdk=$script:PIN_JDK_MAJOR unpacked_mb=$script:PIN_JDK_UNPACKED_MB fallback=$script:PIN_JDK_FALLBACK_RELEASE base=$script:PIN_JDK_FALLBACK_URL_BASE"
    Write-ReaLog DEBUG preflight "pins: jdk_linux_x64=$script:PIN_JDK_FALLBACK_LINUX_X64 jdk_mac_x64=$script:PIN_JDK_FALLBACK_MAC_X64"
    Write-ReaLog DEBUG preflight "pins: jdk_mac_aarch64=$script:PIN_JDK_FALLBACK_MAC_AARCH64 jdk_windows_x64=$script:PIN_JDK_FALLBACK_WINDOWS_X64"
    Write-ReaLog DEBUG preflight "pins: repos=$script:PIN_AGENT_PROFILE_REPO,$script:PIN_CLAVITY_REPO rea=$script:PIN_REA_SPEC hosts=$script:PIN_ALLOWED_HOSTS"
    Write-ReaLog DEBUG preflight "exit codes: $script:EX_OK ok, $script:EX_STEP step, $script:EX_USAGE usage, $script:EX_PLATFORM platform, $script:EX_PREREQ prereq, $script:EX_VERIFY verify"
    Write-ReaLog DEBUG preflight ("options: profile={0} folder={1} ghidra_dir={2} java_home={3}" -f $script:Opt.ProfileName, (Get-ReaShortPath $script:Opt.Folder), $script:Opt.GhidraDir, $script:Opt.JavaHome)
    Write-ReaLog DEBUG preflight ("options: tools_dir={0} bin_dir={1} hopper={2} yes={3} dry_run={4} no_launch={5} check_upstream={6}" -f $script:Opt.ToolsDir, $script:Opt.BinDir, $script:Opt.InstallHopper, $script:Opt.Yes, $script:Opt.DryRun, $script:Opt.NoLaunch, $script:Opt.CheckUpstream)
}

# The bound parameters as '-Name=value' ('-Name' for a switch), sorted by name.
function Format-ReaInvocation {
    param([hashtable]$Parameters)
    if ($Parameters.Count -eq 0) { return '(no parameters)' }
    $parts = foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $value = $Parameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            "-$key"
        } else {
            "-$key=$value"
        }
    }
    return ($parts -join ' ')
}

# The script body; returns the exit code.
# FullPath made absolute against PowerShell's location, not the process directory (the two differ after Set-Location),
# without touching the disk; '' stays ''. A provider-qualified path comes back as the plain provider path.
function Resolve-ReaFullPath {
    param([AllowEmptyString()][string]$Path)
    if (-not $Path) { return $Path }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Invoke-Main {
    Initialize-ReaNetwork
    # The paths are recorded in the profile and env.ps1 and handed to children: make them absolute now
    foreach ($key in 'Folder', 'GhidraDir', 'JavaHome', 'ToolsDir', 'BinDir', 'LogDir') {
        $script:Opt.$key = Resolve-ReaFullPath ([string]$script:Opt.$key)
    }
    $script:OptYes = $script:Opt.Yes
    $script:ConsoleLevel = 'INFO'
    if ($script:Opt.Quiet) { $script:ConsoleLevel = 'WARN' }
    if ($VerbosePreference -eq 'Continue') { $script:ConsoleLevel = 'DEBUG' }
    try {
        Open-ReaLog -Directory $script:Opt.LogDir | Out-Null
        if ($script:LogFile) { Write-ReaLog INFO preflight ('log file: ' + (Get-ReaShortPath $script:LogFile)) }
        Write-ReaLog DEBUG preflight "script version $script:PIN_SCRIPT_VERSION sha256 $(Get-ReaScriptHash)"
        Write-ReaLog DEBUG preflight ('PowerShell ' + $PSVersionTable.PSVersion.ToString())
        Write-ReaLog DEBUG preflight ('invoked: ' + (Format-ReaInvocation $script:Bound))
        Write-ReaConfig
        if ($script:Opt.InstallHopper) {
            Stop-Rea -Code $script:EX_USAGE -Step args -Message '-InstallHopper is not available on Windows'
        }
        Invoke-ReaStepPreflight
        Invoke-ReaStepPrereq
        if ($script:Opt.CheckUpstream) {
            Invoke-ReaStepCheckUpstream
            return $script:EX_OK
        }
        Invoke-ReaPlanToolsBin
        Invoke-ReaPlanJdk
        Invoke-ReaPlanGhidra
        if (-not (Invoke-ReaPlanConfirm)) { return $script:EX_OK }
        Invoke-ReaStepToolsBin
        Invoke-ReaStepJdk
        Invoke-ReaStepGhidra
        Unlock-ReaToolsDir
        Invoke-ReaStepProfile
        Invoke-ReaStepReaSetup
        Invoke-ReaStepReaDoctor
        Write-ReaEnvFile -ToolsDir $script:ToolsDir
        Write-ReaSummary
        return (Invoke-ReaStepLaunch)
    } catch {
        $code = $_.Exception.Data['ReaCode']
        if ($null -ne $code) { return [int]$code }
        Write-ReaLog ERROR main ('unexpected error: ' + $_.Exception.Message)
        return $script:EX_STEP
    } finally {
        Clear-ReaTempFile
    }
}

if ($env:REA_SETUP_NO_MAIN -ne '1') {
    exit (Invoke-Main)
}
