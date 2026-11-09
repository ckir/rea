# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.ps1 steps preflight and prereq. Executable resolution (Resolve-ReaExecutable) and the
# node version probe (Invoke-ReaCommand) are mocked, so the cases run on Linux pwsh 7 as well; the .exe
# versus .cmd rule is tested with the files in tests/fixtures/bin-win. Windows PowerShell 5.1 specifics
# (Start-Process on an extensionless script) are covered by the Windows integration run.

BeforeDiscovery {
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
}

BeforeAll {
    # BeforeDiscovery variables are empty in the run phase, so the run-phase reads need their own copy
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
    $env:REA_SETUP_NO_MAIN = '1'
    . (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:BinWin = Join-Path $script:Root 'tests/fixtures/bin-win'
    $script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('rea prereq work ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:T | Out-Null
    $script:AllNames = @('node', 'npx', 'claude', 'agy', 'wt', 'pwsh', 'tar.exe', 'tar')
    function script:Get-Code {
        param([scriptblock]$Block)
        try { & $Block } catch { return $_.Exception.Data['ReaCode'] }
        return 0
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ReaNativeExecutable' {
    It 'accepts a native exe, in any case' {
        Test-ReaNativeExecutable (Join-Path $script:BinWin 'claude.exe') | Should -BeTrue
        Test-ReaNativeExecutable 'C:\Users\John Smith\bin\CLAUDE.EXE' | Should -BeTrue
    }
    It 'refuses an npm cmd shim and a script' {
        Test-ReaNativeExecutable (Join-Path $script:BinWin 'node.cmd') | Should -BeFalse
        Test-ReaNativeExecutable 'C:\x\claude.cmd' | Should -BeFalse
        Test-ReaNativeExecutable 'C:\x\claude.ps1' | Should -BeFalse
        Test-ReaNativeExecutable 'C:\x\claude' | Should -BeFalse
    }
}

Describe 'Resolve-ReaExecutable (unmocked)' {
    BeforeAll {
        $script:SavedPath = $env:PATH
        $script:PathSep = [System.IO.Path]::PathSeparator
        # mkdirs a scratch PATH directory holding the named files (executable on Unix)
        function script:New-PathDir {
            param([string]$Label, [string[]]$Files)
            $d = Join-Path $script:T ($Label + ' ' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $d | Out-Null
            foreach ($f in $Files) {
                $fp = Join-Path $d $f
                Set-Content -LiteralPath $fp -Value '#!/bin/sh'
                if (-not $script:OnWindows) { & chmod 755 $fp }
            }
            return $d
        }
    }
    AfterEach { $env:PATH = $script:SavedPath }

    It 'returns $null when the command is absent' {
        $d = New-PathDir -Label 'empty' -Files @()
        $env:PATH = $d
        Resolve-ReaExecutable -Name 'rea-no-such-tool-xyz' | Should -BeNullOrEmpty
    }
    It 'returns the path as a string when the command exists' -Skip:$script:OnWindows {
        $d = New-PathDir -Label 'hit' -Files @('rea-fake-tool')
        $env:PATH = $d + $script:PathSep + $script:SavedPath
        $r = Resolve-ReaExecutable -Name 'rea-fake-tool'
        $r | Should -BeOfType [string]
        $r | Should -Be (Join-Path $d 'rea-fake-tool')
    }
    It 'on a non-Windows host an extensionless claude is not a native exe, so the step refuses it with exit 4' -Skip:$script:OnWindows {
        $d = New-PathDir -Label 'noext' -Files @('claude')
        $env:PATH = $d
        $r = Resolve-ReaExecutable -Name 'claude'
        $r | Should -Be (Join-Path $d 'claude')
        Test-ReaNativeExecutable $r | Should -BeFalse
    }
    It 'Windows only: claude.exe wins over claude.cmd in the same directory' -Skip:(-not $script:OnWindows) {
        $d = New-PathDir -Label 'both' -Files @('claude.cmd', 'claude.exe')
        $env:PATH = $d
        Resolve-ReaExecutable -Name 'claude' | Should -Be (Join-Path $d 'claude.exe')
    }
    It 'Windows only: a lone claude.cmd resolves to the cmd, which the step refuses' -Skip:(-not $script:OnWindows) {
        $d = New-PathDir -Label 'cmdonly' -Files @('claude.cmd')
        $env:PATH = $d
        $r = Resolve-ReaExecutable -Name 'claude'
        $r | Should -Be (Join-Path $d 'claude.cmd')
        Test-ReaNativeExecutable $r | Should -BeFalse
    }
    It 'Windows only: a claude.cmd earlier on PATH than claude.exe is rejected by the step with exit 4' -Skip:(-not $script:OnWindows) {
        $first = New-PathDir -Label 'first' -Files @('claude.cmd')
        $second = New-PathDir -Label 'second' -Files @('claude.exe')
        $env:PATH = $first + $script:PathSep + $second + $script:PathSep + $script:SavedPath
        $script:LogFile = Join-Path $script:T 'order.log'
        $script:ConsoleLevel = 'ERROR'
        $script:Opt.CheckUpstream = $false
        $script:NodeVersion = 'v24.22.2'
        $script:NodeExit = 0
        Mock Invoke-ReaCommand { return [pscustomobject]@{ ExitCode = 0; Stdout = 'v24.22.2'; Stderr = '' } }
        $real = ${function:Resolve-ReaExecutable}
        Mock Resolve-ReaExecutable { if ($Name -eq 'claude') { return (& $real -Name $Name) } return (Join-Path $script:BinWin 'node.cmd') }
        try {
            Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match ([regex]::Escape("agent-profile refuses npm .cmd shims"))
        } finally { $script:LogFile = $null }
    }
}

Describe 'Invoke-ReaStepPrereq' {
    BeforeEach {
        $script:LogFile = Join-Path $script:T ('prereq-' + [guid]::NewGuid().ToString('N') + '.log')
        $script:ConsoleLevel = 'ERROR'
        $script:Opt.CheckUpstream = $false
        $script:Summary = @{}
        $script:Found = @{}
        foreach ($n in $script:AllNames) { $script:Found[$n] = (Join-Path $script:BinWin ($n + '.cmd')) }
        $script:Found['claude'] = Join-Path $script:BinWin 'claude.exe'
        $script:NodeVersion = 'v24.22.2'
        $script:NodeExit = 0
        Mock Resolve-ReaExecutable { return $script:Found[$Name] }
        Mock Invoke-ReaCommand { return [pscustomobject]@{ ExitCode = $script:NodeExit; Stdout = $script:NodeVersion; Stderr = '' } }
        foreach ($v in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_OAUTH_REFRESH_TOKEN', 'ANTHROPIC_PROFILE', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY')) {
            Remove-Item -LiteralPath "Env:$v" -ErrorAction SilentlyContinue
        }
    }
    AfterEach {
        $script:LogFile = $null
        Remove-Item -LiteralPath 'Env:ANTHROPIC_API_KEY' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:CLAUDE_CODE_USE_FOUNDRY' -ErrorAction SilentlyContinue
    }

    It 'passes with every prerequisite and node 24.22.2' {
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 0
        $script:Summary['prereq'] | Should -Be 'ok'
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'prereq\] ok'
    }
    It 'exits 4 with the fnm hint for node 24.21.0' {
        $script:NodeVersion = 'v24.21.0'
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
        $log = Get-Content -LiteralPath $script:LogFile -Raw
        $log | Should -Match ([regex]::Escape('install Node 24: fnm install 24 (https://github.com/Schniz/fnm) or https://nodejs.org'))
        $log | Should -Match 'v24\.21\.0'
    }
    It 'fails closed on an unparsable or failing node' {
        $script:NodeVersion = 'garbage'
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
        $script:NodeVersion = 'v24.22.2'
        $script:NodeExit = 1
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
    }
    It 'exits 4 naming node when it is missing' {
        $script:Found['node'] = $null
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'node not found'
    }
    It 'exits 4 naming <name> when it is missing' -ForEach @(
        @{ Name = 'agy' }, @{ Name = 'npx' }, @{ Name = 'claude' }, @{ Name = 'wt' }
    ) {
        $script:Found[$Name] = $null
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match "$Name not found"
    }
    It 'accepts powershell when pwsh is absent and refuses neither' {
        $script:Found['pwsh'] = $null
        $script:Found['powershell'] = Join-Path $script:BinWin 'node.cmd'
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 0
        $script:Found['powershell'] = $null
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'pwsh or powershell not found'
    }
    It 'refuses a claude that resolves to a .cmd before any .exe' {
        $cmd = Join-Path $script:T 'claude.cmd'
        Copy-Item -LiteralPath (Join-Path $script:BinWin 'node.cmd') -Destination $cmd
        $script:Found['claude'] = $cmd
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match ([regex]::Escape("agent-profile refuses npm .cmd shims; install Claude Code's native installer"))
    }
    It 'accepts the native claude.exe next to a claude.cmd sibling when the exe resolves' {
        Copy-Item -LiteralPath (Join-Path $script:BinWin 'node.cmd') -Destination (Join-Path $script:T 'claude.cmd')
        $script:Found['claude'] = Join-Path $script:BinWin 'claude.exe'
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 0
    }
    It '-CheckUpstream skips claude, agy and wt' {
        $script:Opt.CheckUpstream = $true
        $script:Found['claude'] = $null
        $script:Found['agy'] = $null
        $script:Found['wt'] = $null
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 0
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'CheckUpstream'
        $script:Found['node'] = $null
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
    }
    It 'warns by name, never by value, for credential overrides' {
        $env:ANTHROPIC_API_KEY = 'sk-secret-value-123'
        $env:CLAUDE_CODE_USE_FOUNDRY = '1'
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 0
        $log = Get-Content -LiteralPath $script:LogFile -Raw
        $log | Should -Match 'WARN .*ANTHROPIC_API_KEY'
        $log | Should -Match 'CLAUDE_CODE_USE_FOUNDRY'
        $log | Should -Not -Match 'sk-secret-value-123'
        $script:Summary['prereq'] | Should -Be 'warn'
    }
    It 'does not warn when no override is set' {
        Get-Code { Invoke-ReaStepPrereq } | Should -Be 0
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Not -Match 'WARN'
    }
}

Describe 'Invoke-ReaStepPrereq with a real node stub' {
    It 'reads the version a program prints' -Skip:$script:OnWindows {
        $script:LogFile = Join-Path $script:T 'real.log'
        $script:ConsoleLevel = 'ERROR'
        $script:Opt.CheckUpstream = $true
        $script:Found = @{ node = (Join-Path $script:Root 'tests/fixtures/bin/node'); npx = 'x'; pwsh = 'x' }
        Mock Resolve-ReaExecutable { return $script:Found[$Name] }
        $env:STUB_node_VERSION = 'v24.21.0'
        try {
            Get-Code { Invoke-ReaStepPrereq } | Should -Be 4
            $env:STUB_node_VERSION = 'v26.12.1'
            Get-Code { Invoke-ReaStepPrereq } | Should -Be 0
        } finally {
            Remove-Item -LiteralPath Env:STUB_node_VERSION -ErrorAction SilentlyContinue
            $script:Opt.CheckUpstream = $false
            $script:LogFile = $null
        }
    }
}

Describe 'Invoke-ReaStepPreflight' {
    BeforeEach {
        $script:LogFile = Join-Path $script:T ('preflight-' + [guid]::NewGuid().ToString('N') + '.log')
        $script:ConsoleLevel = 'ERROR'
        $script:Summary = @{}
        $script:Opt.ProfileName = 'rea'
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:Opt.ToolsDir = Join-Path $script:T 'tools dir'
        $script:Opt.BinDir = Join-Path $script:T 'bin dir'
        Mock Resolve-ReaExecutable { return 'tar.exe' }
        Mock Test-ReaFixedNtfsVolume { return $true }
        Mock Remove-ReaOrphan { }
    }
    AfterEach {
        $script:LogFile = $null
        $script:Opt.ProfileName = 'rea'
        $script:Opt.ToolsDir = ''
        $script:Opt.BinDir = ''
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
    }

    It 'passes on windows x64 and records the directories' {
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
        Get-Code { Invoke-ReaStepPreflight } | Should -Be 0
        $script:ToolsDir | Should -Be (Join-Path $script:T 'tools dir')
        $script:BinDir | Should -Be (Join-Path $script:T 'bin dir')
        $script:Summary['preflight'] | Should -Be 'ok'
        Should -Invoke Test-ReaFixedNtfsVolume -Times 1 -Exactly
        Should -Invoke Remove-ReaOrphan -Times 2 -Exactly
    }
    Context 'a folder that is the home directory' {
        BeforeEach {
            Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
            $script:SavedHome = $env:USERPROFILE
            $script:SavedFolder = $script:Opt.Folder
            $env:USERPROFILE = Join-Path $script:T 'home dir'
        }
        AfterEach {
            $env:USERPROFILE = $script:SavedHome
            $script:Opt.Folder = $script:SavedFolder
        }
        It 'warns that agy runs with permissions skipped over the home directory, and continues' {
            $script:Opt.Folder = $env:USERPROFILE
            Get-Code { Invoke-ReaStepPreflight } | Should -Be 0
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'WARN +\[preflight\].*home directory.*permissions skipped'
        }
        It 'warns for a trailing separator and a different case' {
            $script:Opt.Folder = $env:USERPROFILE.ToUpperInvariant() + [System.IO.Path]::DirectorySeparatorChar
            if ([System.IO.Path]::DirectorySeparatorChar -eq '/') { Set-ItResult -Skipped -Because 'paths are case-sensitive here'; return }
            Get-Code { Invoke-ReaStepPreflight } | Should -Be 0
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'home directory'
        }
        It 'does not warn for a folder below the home directory' {
            $script:Opt.Folder = Join-Path $env:USERPROFILE 'project'
            Get-Code { Invoke-ReaStepPreflight } | Should -Be 0
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Not -Match 'home directory'
        }
    }
    It 'exits 3 on windows aarch64 with the platform hint' {
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'aarch64' } }
        Get-Code { Invoke-ReaStepPreflight } | Should -Be 3
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match ([regex]::Escape('unsupported platform: windows aarch64 (no agent-profile, clavity-ls or Ghidra native build)'))
    }
    It 'reports windows aarch64 from Get-ReaPlatform itself' {
        Mock Get-ReaRuntimeArchitecture { return 'Arm64' }
        Get-Code { Invoke-ReaStepPreflight } | Should -Be 3
    }
    It 'exits 2 for the profile doctor' {
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
        $script:Opt.ProfileName = 'doctor'
        Get-Code { Invoke-ReaStepPreflight } | Should -Be 2
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'invalid profile name: doctor'
    }
    It 'exits 4 when tar.exe is missing' {
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
        Mock Resolve-ReaExecutable { return $null }
        Get-Code { Invoke-ReaStepPreflight } | Should -Be 4
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'build 17063'
    }
    It 'stops (exit 1) when the tools volume is not fixed NTFS' {
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
        Mock Test-ReaFixedNtfsVolume { Stop-Rea -Code 1 -Step disk -Message 'the install location must be on a fixed NTFS volume' }
        Get-Code { Invoke-ReaStepPreflight } | Should -Be 1
    }
    It 'leaves orphans alone on -DryRun and -CheckUpstream' {
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
        $script:Opt.DryRun = $true
        Get-Code { Invoke-ReaStepPreflight } | Should -Be 0
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $true
        Get-Code { Invoke-ReaStepPreflight } | Should -Be 0
        Should -Invoke Remove-ReaOrphan -Times 0 -Exactly
    }
}
