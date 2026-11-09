# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.ps1 step profile; they mirror tests/sh/profile.sh. The run of agent-profile is replaced by a
# mock of Invoke-ReaCommand (the cmd stub of tests/fixtures/bin-win is not used: a mock behaves the same on every
# OS), which answers doctor with a fixture and create with a directory under the scratch profile root. The step
# must never write in the .claude directory or .claude.json of the home directory: every test runs with a scratch
# USERPROFILE and ends by listing it. The last tests run the REAL agent-profile, when there is one. Every
# directory has a space in its name.

BeforeDiscovery {
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
    $script:HasRealAp = [bool](Get-Command -Name 'agent-profile' -CommandType Application -ErrorAction SilentlyContinue)
    if (-not $script:HasRealAp) { [Console]::Out.WriteLine('skip: the real agent-profile is not on PATH') }
}

BeforeAll {
    $env:REA_SETUP_NO_MAIN = '1'
    . (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:Fix = Join-Path $script:Root 'tests/fixtures'
    $script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('rea profile work ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:T | Out-Null
    $script:SavedProfile = $env:USERPROFILE
    $script:BadMessage = 'agent-profile did not report a profile-specific CLAUDE_CONFIG_DIR'

    function script:Get-Code {
        param([scriptblock]$Block)
        try { & $Block } catch { return $_.Exception.Data['ReaCode'] }
        return 0
    }
    function script:New-Doctor {
        param([string]$Value)
        $doc = @{ checks = @(@{ id = 'launch_environment'; data = @{ value = $Value } }) }
        return (ConvertTo-Json -InputObject $doc -Depth 5 -Compress)
    }
    function script:Get-Entry {
        param([string]$Dir)
        if (-not (Test-Path -LiteralPath $Dir)) { return @() }
        return @(Get-ChildItem -LiteralPath $Dir -Force | ForEach-Object { $_.Name })
    }
    function script:Get-LogText {
        return [System.IO.File]::ReadAllText($script:LogFile)
    }
}

AfterAll {
    $env:USERPROFILE = $script:SavedProfile
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'profile' {
    BeforeEach {
        $script:Case = Join-Path $script:T ('case ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case | Out-Null
        $script:HomeDir = Join-Path $script:Case 'home dir'
        New-Item -ItemType Directory -Path $script:HomeDir | Out-Null
        $script:Aph = Join-Path $script:Case 'aph dir'
        $env:USERPROFILE = $script:HomeDir
        $script:LogFile = Join-Path $script:Case 'run.log'
        $script:ConsoleLevel = 'ERROR'
        $script:Summary = @{}
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:SavedName = $script:Opt.ProfileName
        $script:Opt.ProfileName = 't1'
        $script:ClaudeConfigDirSelected = ''
        Remove-Item Env:\CLAUDE_CONFIG_DIR_SELECTED -ErrorAction SilentlyContinue
        $script:DoctorOut = New-Doctor -Value (Join-Path $script:Aph 'profiles/t1/claude')
        $script:DoctorExit = 0
        $script:CreateExit = 0
        $script:CreateErr = ''
        $script:Calls = New-Object System.Collections.Generic.List[string]
        Mock Resolve-ReaExecutable { return 'agent-profile-stub' }
        Mock Invoke-ReaCommand {
            $script:Calls.Add(($ArgumentList -join ' '))
            if ($ArgumentList[1] -eq 'doctor') {
                return [pscustomobject]@{ ExitCode = $script:DoctorExit; Stdout = $script:DoctorOut; Stderr = '' }
            }
            if ($script:CreateExit -ne 0) {
                return [pscustomobject]@{ ExitCode = $script:CreateExit; Stdout = ''; Stderr = $script:CreateErr }
            }
            $d = Join-Path $script:Aph ('profiles/' + $ArgumentList[2] + '/claude')
            if (Test-Path -LiteralPath $d) {
                return [pscustomobject]@{ ExitCode = 0; Stdout = "profile '$($ArgumentList[2])' for claude already exists: $d"; Stderr = '' }
            }
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            return [pscustomobject]@{ ExitCode = 0; Stdout = "created profile '$($ArgumentList[2])' for claude: $d"; Stderr = '' }
        }
    }
    AfterEach {
        $script:Opt.ProfileName = $script:SavedName
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:LogFile = $null
        Remove-Item Env:\CLAUDE_CONFIG_DIR_SELECTED -ErrorAction SilentlyContinue
    }

    Context 'Get-ReaProfileConfigDir' {
        It 'gives the launch_environment value of the "after create" fixture' {
            $script:DoctorOut = [System.IO.File]::ReadAllText((Join-Path $script:Fix 'sample-doctor-agent-profile.json'))
            Get-ReaProfileConfigDir -Name t1 -Executable x | Should -Be '/home/u/.local/share/agent-profile/profiles/t1/claude'
        }
        It 'accepts exit 5 with the fail fixture as a WARN naming profile_path' {
            $script:DoctorOut = [System.IO.File]::ReadAllText((Join-Path $script:Fix 'sample-doctor-agent-profile-fail.json'))
            $script:DoctorExit = 5
            Get-ReaProfileConfigDir -Name t1 -Executable x | Should -Be '/home/u/.local/share/agent-profile/profiles/t1/claude'
            Get-LogText | Should -Match 'WARN +\[profile\] .*failing checks \(profile_path\).*create decides'
        }
        It 'dies with 1 when doctor exits 4' {
            $script:DoctorExit = 4
            script:Get-Code { Get-ReaProfileConfigDir -Name t1 -Executable x } | Should -Be 1
            Get-LogText | Should -Match 'ERROR +\[profile\] agent-profile claude doctor exited 4'
        }
        It 'refuses <name> with the exact message' -ForEach @(
            @{ name = 'the home .claude'; json = 'HOME/.claude' }
            @{ name = 'the home .claude with a trailing separator'; json = 'HOME/.claude/' }
            @{ name = 'a subpath of the home .claude'; json = 'HOME/.claude/profiles/rea' }
            @{ name = 'a subpath through ..'; json = 'HOME/.claude/../.claude/x' }
            @{ name = 'the home .claude in other case'; json = 'HOME/.CLAUDE/x' }
            @{ name = 'an empty value'; json = '' }
        ) {
            $script:DoctorOut = New-Doctor -Value ($json -replace '^HOME', $script:HomeDir)
            script:Get-Code { Get-ReaProfileConfigDir -Name t1 -Executable x } | Should -Be 1
            Get-LogText | Should -Match ('ERROR +\[profile\] ' + [regex]::Escape($script:BadMessage) + '\s')
        }
        It 'refuses <name> without a NullReference' -ForEach @(
            @{ name = 'no launch_environment check'; json = '{"checks":[]}' }
            @{ name = 'no checks at all'; json = '{}' }
            @{ name = 'a null data'; json = '{"checks":[{"id":"launch_environment","data":null}]}' }
            @{ name = 'no data'; json = '{"checks":[{"id":"launch_environment"}]}' }
        ) {
            $script:DoctorOut = $json
            script:Get-Code { Get-ReaProfileConfigDir -Name t1 -Executable x } | Should -Be 1
            Get-LogText | Should -Match ('ERROR +\[profile\] ' + [regex]::Escape($script:BadMessage) + '\s')
        }
        It 'dies with 1 on output that is not JSON' {
            $script:DoctorOut = 'this is not json'
            script:Get-Code { Get-ReaProfileConfigDir -Name t1 -Executable x } | Should -Be 1
            Get-LogText | Should -Match 'ERROR +\[profile\] .*not JSON'
        }
        It 'dies with 1 on empty output' {
            $script:DoctorOut = ''
            script:Get-Code { Get-ReaProfileConfigDir -Name t1 -Executable x } | Should -Be 1
        }
        It 'accepts a sibling that only starts with .claude' {
            $d = Join-Path $script:HomeDir '.claude-other/p1/claude'
            $script:DoctorOut = New-Doctor -Value $d
            Get-ReaProfileConfigDir -Name t1 -Executable x | Should -Be $d
        }
        It 'refuses a path through a symlink into the home .claude' -Skip:$script:OnWindows {
            New-Item -ItemType Directory -Path (Join-Path $script:HomeDir '.claude') | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:Case 'link to claude') -Target (Join-Path $script:HomeDir '.claude') | Out-Null
            $script:DoctorOut = New-Doctor -Value (Join-Path $script:Case 'link to claude/p1/claude')
            script:Get-Code { Get-ReaProfileConfigDir -Name t1 -Executable x } | Should -Be 1
        }
        It 'refuses the real target of a .claude that is a symlink' -Skip:$script:OnWindows {
            $elsewhere = Join-Path $script:Case 'elsewhere'
            New-Item -ItemType Directory -Path $elsewhere | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:HomeDir '.claude') -Target $elsewhere | Out-Null
            $script:DoctorOut = New-Doctor -Value (Join-Path $elsewhere 'p1')
            script:Get-Code { Get-ReaProfileConfigDir -Name t1 -Executable x } | Should -Be 1
        }
    }

    Context 'Invoke-ReaStepProfile' {
        It 'creates the profile, sets the directory, exports it and writes nothing under the home' {
            Invoke-ReaStepProfile
            $want = Join-Path $script:Aph 'profiles/t1/claude'
            $script:ClaudeConfigDirSelected | Should -Be $want
            $env:CLAUDE_CONFIG_DIR_SELECTED | Should -Be $want
            Test-Path -LiteralPath $want -PathType Container | Should -BeTrue
            $script:Summary['profile'] | Should -Be "created t1: $want"
            Get-LogText | Should -Match 'INFO +\[profile\] created t1'
            Get-LogText | Should -Match 'INFO +\[profile\] ok'
            @(script:Get-Entry $script:HomeDir).Count | Should -Be 0
        }
        It 'a second run is a skip (already exists)' {
            Invoke-ReaStepProfile
            $script:Summary = @{}
            Invoke-ReaStepProfile
            $script:Summary['profile'] | Should -Be ('reused t1: ' + (Join-Path $script:Aph 'profiles/t1/claude'))
            Get-LogText | Should -Match 'INFO +\[profile\] skip \(already exists\)'
        }
        It 'still attempts create after doctor exit 5' {
            $script:DoctorExit = 5
            Invoke-ReaStepProfile
            Test-Path -LiteralPath (Join-Path $script:Aph 'profiles/t1/claude') | Should -BeTrue
            Get-LogText | Should -Match 'WARN +\[profile\] .*create decides'
        }
        It 'stops before create when doctor exits 4' {
            $script:DoctorExit = 4
            script:Get-Code { Invoke-ReaStepProfile } | Should -Be 1
            Test-Path -LiteralPath $script:Aph | Should -BeFalse
            ($script:Calls -join '|') | Should -Not -Match 'create'
        }
        It 'refuses a doctor directory inside the home .claude and creates nothing' {
            $script:DoctorOut = New-Doctor -Value (Join-Path $script:HomeDir '.claude/profiles/rea')
            script:Get-Code { Invoke-ReaStepProfile } | Should -Be 1
            ($script:Calls -join '|') | Should -Not -Match 'create'
            @(script:Get-Entry $script:HomeDir).Count | Should -Be 0
        }
        It 'dies with 1 when create fails, with a bounded and redacted stderr tail' {
            $script:CreateExit = 4
            $script:CreateErr = 'HEADMARK' + ('0123456789' * 700) + ' ANTHROPIC_API_KEY=sk-secret-123 TAILMARK'
            script:Get-Code { Invoke-ReaStepProfile } | Should -Be 1
            $text = Get-LogText
            $text | Should -Match 'ERROR +\[profile\] agent-profile claude create exited 4: '
            $text | Should -Match 'TAILMARK'
            $text | Should -Not -Match 'HEADMARK'
            $text | Should -Not -Match 'sk-secret-123'
        }
        It 'dies with 1 when the directory is missing after create' {
            $script:DoctorOut = New-Doctor -Value (Join-Path $script:Case 'never created/claude')
            script:Get-Code { Invoke-ReaStepProfile } | Should -Be 1
            Get-LogText | Should -Match 'ERROR +\[profile\] the profile directory does not exist after create'
        }
        It 'a dry run runs doctor only' {
            $script:Opt.DryRun = $true
            Invoke-ReaStepProfile
            Test-Path -LiteralPath $script:Aph | Should -BeFalse
            ($script:Calls -join '|') | Should -Not -Match 'create'
            Get-LogText | Should -Match 'INFO +\[profile\] would use .*profiles.t1.claude'
            $script:Summary['profile'] | Should -Match 'not created: read-only run'
        }
        It 'a dry run refuses a home .claude directory too' {
            $script:Opt.DryRun = $true
            $script:DoctorOut = New-Doctor -Value (Join-Path $script:HomeDir '.claude')
            script:Get-Code { Invoke-ReaStepProfile } | Should -Be 1
        }
        It 'a dry run without agent-profile is a note' {
            $script:Opt.DryRun = $true
            Mock Resolve-ReaExecutable { return $null }
            Invoke-ReaStepProfile
            Get-LogText | Should -Match 'agent-profile is not installed'
        }
        It 'a real run without agent-profile dies with 1' {
            Mock Resolve-ReaExecutable { return $null }
            script:Get-Code { Invoke-ReaStepProfile } | Should -Be 1
        }
        It '-CheckUpstream skips the step and runs nothing' {
            $script:Opt.CheckUpstream = $true
            Invoke-ReaStepProfile
            $script:Calls.Count | Should -Be 0
            Get-LogText | Should -Match 'INFO +\[profile\] skip \(-CheckUpstream\)'
        }
    }
}

Describe 'profile with the real agent-profile' {
    BeforeEach {
        $script:Case = Join-Path $script:T ('real ' + [guid]::NewGuid().ToString('N'))
        $script:HomeDir = Join-Path $script:Case 'home dir'
        New-Item -ItemType Directory -Path $script:HomeDir -Force | Out-Null
        $script:Aph = Join-Path $script:Case 'aph dir'
        $script:SavedAph = $env:AGENT_PROFILE_HOME
        $script:SavedHomeVar = $env:HOME
        $env:USERPROFILE = $script:HomeDir
        $env:HOME = $script:HomeDir
        $env:AGENT_PROFILE_HOME = $script:Aph
        $script:LogFile = Join-Path $script:Case 'run.log'
        $script:ConsoleLevel = 'ERROR'
        $script:Summary = @{}
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:SavedName = $script:Opt.ProfileName
        $script:Opt.ProfileName = 't1'
    }
    AfterEach {
        $script:Opt.ProfileName = $script:SavedName
        $script:Opt.DryRun = $false
        $env:USERPROFILE = $script:SavedProfile
        $env:HOME = $script:SavedHomeVar
        if ($script:SavedAph) { $env:AGENT_PROFILE_HOME = $script:SavedAph } else { Remove-Item Env:\AGENT_PROFILE_HOME -ErrorAction SilentlyContinue }
        Remove-Item Env:\CLAUDE_CONFIG_DIR_SELECTED -ErrorAction SilentlyContinue
        $script:LogFile = $null
    }

    It 'a dry run creates no profile, a real run creates the directory, a second run skips, the home stays empty' -Skip:(-not $script:HasRealAp) {
        $script:Opt.DryRun = $true
        Invoke-ReaStepProfile
        Test-Path -LiteralPath (Join-Path $script:Aph 'profiles/t1') | Should -BeFalse
        $script:Opt.DryRun = $false
        Invoke-ReaStepProfile
        $want = Join-Path $script:Aph 'profiles/t1/claude'
        Test-Path -LiteralPath $want -PathType Container | Should -BeTrue
        $env:CLAUDE_CONFIG_DIR_SELECTED | Should -Be $want
        @(script:Get-Entry $script:HomeDir).Count | Should -Be 0
        Invoke-ReaStepProfile
        Get-LogText | Should -Match 'skip \(already exists\)'
        @(script:Get-Entry $script:HomeDir).Count | Should -Be 0
    }
}
