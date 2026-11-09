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
    while ($Exception -is [System.AggregateException] -and $null -ne $Exception.InnerException) {
        $Exception = $Exception.InnerException
    }
    return $Exception.Message
}

# True for a failure worth another attempt: connection, name-resolution, timeout and broken-transfer errors. A
# certificate failure or anything unrecognised is not.
function Test-ReaTransientError {
    param($Exception)
    if ($Exception -is [System.AggregateException] -and $null -ne $Exception.InnerException) {
        $Exception = $Exception.InnerException
    }
    if ($Exception -is [System.Net.WebException]) {
        $transient = 'ConnectFailure', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'Timeout', 'ConnectionClosed', 'ReceiveFailure', 'SendFailure', 'PipelineFailure', 'KeepAliveFailure'
        return ($transient -contains $Exception.Status.ToString())
    }
    return (($Exception -is [System.IO.IOException]) -or ($Exception -is [System.TimeoutException]))
}

# One HEAD (Method HEAD) or one-byte ranged GET (Method RANGE) without following redirects. Returns Status (0
# when there was no HTTP answer), Location and Error. A non-2xx answer arrives as a WebException carrying the
# response, so it is read from there.
function Send-ReaHeadRequest {
    param(
        [string]$Url,
        [ValidateSet('HEAD', 'RANGE')][string]$Method = 'HEAD'
    )
    $result = [pscustomobject]@{ Status = 0; Location = $null; Error = '' }
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
                return $result
            }
        }
        $result.Status = [int]$resp.StatusCode
        $result.Location = $resp.Headers['Location']
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($null -ne $resp) { $resp.Close() }
    }
    return $result
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
        $r = Send-ReaHeadRequest -Url $current -Method 'HEAD'
        if ($r.Status -eq 405 -or $r.Status -eq 403) {
            $r = Send-ReaHeadRequest -Url $current -Method 'RANGE'
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
        Move-Item -LiteralPath $tmp -Destination $Destination -Force
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
    $r = Send-ReaHeadRequest -Url $url -Method 'HEAD'
    Write-ReaLog DEBUG net "latest release of $Repo -> $($r.Location)"
    if ($r.Location -and $r.Location -match '/releases/tag/[^/]+$') {
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
            $started = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
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
    $items = @(Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $_.Name -like '*.tmp.*' -or $_.Name -like '*.old.*' })
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
        $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
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
            Move-Item -LiteralPath $Final -Destination $old -ErrorAction Stop
        } catch {
            Write-ReaLog -Level ERROR -Step install -Message "cannot move the previous install aside: $Final"
            return $false
        }
    }
    try {
        Move-Item -LiteralPath $Staging -Destination $Final -ErrorAction Stop
    } catch {
        Write-ReaLog -Level ERROR -Step install -Message "cannot move the new install into place: $Final"
        if ($hadFinal) {
            try {
                Move-Item -LiteralPath $old -Destination $Final -ErrorAction Stop
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
        $marked = (Test-Path -LiteralPath (Join-Path $d.FullName '.install-complete') -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $d.FullName 'release') -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $d.FullName 'Contents') 'Home') 'release') -PathType Leaf)
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
function Invoke-Main {
    Initialize-ReaNetwork
    $script:OptYes = $script:Opt.Yes
    $script:ConsoleLevel = 'INFO'
    if ($script:Opt.Quiet) { $script:ConsoleLevel = 'WARN' }
    if ($VerbosePreference -eq 'Continue') { $script:ConsoleLevel = 'DEBUG' }
    try {
        Open-ReaLog -Directory $script:Opt.LogDir | Out-Null
        Write-ReaLog DEBUG preflight "script version $script:PIN_SCRIPT_VERSION sha256 n/a"
        Write-ReaLog DEBUG preflight ('PowerShell ' + $PSVersionTable.PSVersion.ToString())
        Write-ReaLog DEBUG preflight ('invoked: ' + (Format-ReaInvocation $script:Bound))
        Write-ReaConfig
        if ($script:Opt.InstallHopper) {
            Stop-Rea -Code $script:EX_USAGE -Step args -Message '-InstallHopper is not available on Windows'
        }
        Invoke-ReaStepPreflight
        Invoke-ReaStepPrereq
        return $script:EX_OK
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
