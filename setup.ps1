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
[CmdletBinding()]
param(
    [string]$ProfileName = 'rea',
    [string]$Folder = (Get-Location).Path,
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

# Hides secrets in a log message. Names are matched case-insensitively (-replace is); quoted values are
# consumed whole.
function Hide-ReaSecret {
    param([AllowEmptyString()][string]$Text)
    $names = 'TOKEN|KEY|SECRET|PASSWORD'
    $r = $Text -replace "([A-Za-z0-9_]*($names)[A-Za-z0-9_]*)=(`"[^`"]*`"|'[^']*'|[^ ]*)", '${1}=<redacted>'
    $r = $r -replace '(authorization:)[^"]*', '${1} <redacted>'
    $r = $r -replace '(https?://)[^/@ ]*@', '${1}'
    $r = $r -replace '(https?://[^ ?]*)\?[^ ]*', '${1}'
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
    $pattern = '(^|[^A-Za-z0-9._/\\-])' + [regex]::Escape($homeDir) + '(?=$|[\\/]|[^A-Za-z0-9._-])'
    return [regex]::Replace($Text, $pattern, '${1}%USERPROFILE%', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
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
            [Console]::Error.WriteLine('warning: cannot write the log file; continuing without one')
        }
    }
    if (Test-ReaLogVisible -Level $Level) {
        [Console]::Error.WriteLine($line)
    }
}

# Logs ERROR with the log path, then throws; Invoke-Main turns the exception into the exit code (a function
# cannot exit the host, so Stop-Rea is the die counterpart).
function Stop-Rea {
    [CmdletBinding(SupportsShouldProcess = $true)]
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
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = Join-Path $HOME '.local/state' }
        $Directory = Join-Path (Join-Path $base 'rea-setup') 'logs'
    }
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $file = Join-Path $Directory ('setup-{0}-{1}.log' -f $stamp, $PID)
    try {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        [System.IO.File]::AppendAllText($file, '', (New-Object System.Text.UTF8Encoding $false))
    } catch {
        [Console]::Error.WriteLine("warning: cannot create a log file in $(Get-ReaShortPath $Directory); continuing without one")
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

# @{ Os = 'windows'; Arch = 'x64' | 'aarch64' | <other, lower-cased> }. Architecture is for tests.
function Get-ReaPlatform {
    param([string]$Architecture = '')
    if (-not $Architecture) {
        $Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
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

# The script body; returns the exit code.
function Invoke-Main {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $script:OptYes = $script:Opt.Yes
    $script:ConsoleLevel = 'INFO'
    if ($script:Opt.Quiet) { $script:ConsoleLevel = 'WARN' }
    if ($VerbosePreference -eq 'Continue') { $script:ConsoleLevel = 'DEBUG' }
    try {
        Open-ReaLog -Directory $script:Opt.LogDir | Out-Null
        Write-ReaLog DEBUG preflight "script version $script:PIN_SCRIPT_VERSION sha256 n/a"
        Write-ReaLog DEBUG preflight ('PowerShell ' + $PSVersionTable.PSVersion.ToString())
        Write-ReaLog DEBUG preflight ('invoked: ' + $MyInvocation.Line)
        Write-ReaConfig
        if ($script:Opt.InstallHopper) {
            Stop-Rea -Code $script:EX_USAGE -Step args -Message '-InstallHopper is not available on Windows'
        }
        if (-not (Test-ReaProfileName $script:Opt.ProfileName)) {
            Stop-Rea -Code $script:EX_USAGE -Step preflight -Message "invalid profile name: $($script:Opt.ProfileName)"
        }
        $platform = Get-ReaPlatform
        if ($platform.Arch -ne 'x64') {
            Stop-Rea -Code $script:EX_PLATFORM -Step preflight -Message "unsupported platform: $($platform.Os) $($platform.Arch)"
        }
        Write-ReaLog INFO preflight "platform: $($platform.Os) $($platform.Arch)"
        return $script:EX_OK
    } catch {
        $code = $_.Exception.Data['ReaCode']
        if ($null -ne $code) { return [int]$code }
        Write-ReaLog ERROR main ('unexpected error: ' + $_.Exception.Message)
        return $script:EX_STEP
    }
}

if ($env:REA_SETUP_NO_MAIN -ne '1') {
    exit (Invoke-Main)
}
