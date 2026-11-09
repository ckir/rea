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
