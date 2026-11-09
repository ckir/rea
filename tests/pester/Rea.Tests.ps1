# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.ps1 steps rea-setup and rea-doctor; they mirror tests/sh/rea.sh. The run of npx is replaced by
# a mock of Invoke-ReaCommand (the npx.cmd stub of tests/fixtures/bin-win is not used: a mock behaves the same on
# every OS) which records the argument list and the three environment variables at call time, writes a profile
# .claude.json when told to, and answers from a table keyed by the call number. The doctor fixtures are real
# `rea doctor --json` answers (paths sanitised). Every run uses a scratch USERPROFILE that must end empty: the
# steps never write the .claude directory or .claude.json of the home directory.

BeforeAll {
    $env:REA_SETUP_NO_MAIN = '1'
    . (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:Fix = Join-Path $script:Root 'tests/fixtures'
    $script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('rea rea work ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:T | Out-Null
    $script:SavedProfile = $env:USERPROFILE

    function script:Read-Fix {
        param([string]$Name)
        return [System.IO.File]::ReadAllText((Join-Path $script:Fix $Name))
    }
    function script:Get-Code {
        param([scriptblock]$Block)
        try { & $Block } catch { return $_.Exception.Data['ReaCode'] }
        return 0
    }
    function script:Get-LogText {
        return [System.IO.File]::ReadAllText($script:LogFile)
    }
    $script:CO = script:Read-Fix 'rea-doctor-client-ok.json'
    $script:CE = script:Read-Fix 'rea-doctor-client-empty.json'
    $script:GO = script:Read-Fix 'rea-doctor-ghidra-ok.json'
    $script:GB = script:Read-Fix 'rea-doctor-ghidra-bad.json'
    $script:GM = script:Read-Fix 'rea-doctor-ghidra-mac-nodecomp.json'
    $script:CfgOk = '{"mcpServers":{"rea":{"command":"npx","args":["-y","rea-agents@6.8.0","mcp"]}}}'
}

AfterAll {
    $env:USERPROFILE = $script:SavedProfile
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'doctor answer helpers' {
    It 'Test-ReaDoctorHealthy: <name>' -ForEach @(
        @{ name = 'client-ok'; file = 'CO'; want = $true }
        @{ name = 'client-empty'; file = 'CE'; want = $false }
        @{ name = 'ghidra-ok'; file = 'GO'; want = $true }
        @{ name = 'ghidra-bad'; file = 'GB'; want = $false }
    ) {
        Test-ReaDoctorHealthy -Json (Get-Variable -Scope Script -Name $file).Value | Should -Be $want
    }
    It 'Test-ReaDoctorHealthy is false for text that is not a JSON object' -ForEach @(
        @{ text = 'this is not json' }
        @{ text = '' }
        @{ text = '[1,2]' }
        @{ text = 'null' }
        @{ text = '{}' }
        @{ text = '{"healthy":"true"}' }
    ) {
        Test-ReaDoctorHealthy -Json $text | Should -BeFalse
    }
    It 'Get-ReaDoctorFailing names both scope checks of the empty profile' {
        (Get-ReaDoctorFailing -Json $script:CE) -join ' ' | Should -Be 'registration:claude_code skill:identity'
        @(Get-ReaDoctorFailing -Json $script:CO).Count | Should -Be 0
    }
    It 'Get-ReaGhidraStatus on ok: available, 12.1.4, nothing failing' {
        $s = Get-ReaGhidraStatus -Json $script:GO
        $s.Available | Should -BeTrue
        $s.Version | Should -Be '12.1.4'
        @($s.Failing).Count | Should -Be 0
        (Get-ReaGhidraStatus -Json $script:CO).Available | Should -BeTrue
    }
    It 'Get-ReaGhidraStatus on bad: unavailable, installation and java named' {
        $s = Get-ReaGhidraStatus -Json $script:GB
        $s.Available | Should -BeFalse
        $s.Version | Should -Be '-'
        $s.Failing -join ',' | Should -Be 'installation,java'
    }
    It 'Get-ReaGhidraStatus on mac-nodecomp: native_decompiler only' {
        $s = Get-ReaGhidraStatus -Json $script:GM
        $s.Available | Should -BeFalse
        $s.Failing -join ',' | Should -Be 'native_decompiler'
    }
    It 'Get-ReaGhidraStatus tolerates missing and null parts' {
        (Get-ReaGhidraStatus -Json '{}').Failing -join ',' | Should -Be 'ghidra_provider_missing'
        $s = Get-ReaGhidraStatus -Json '{"providerInspections":[null,{"id":"ghidra","available":true,"providerVersion":null,"checks":[null,{"name":"x"}]}]}'
        $s.Available | Should -BeTrue
        $s.Version | Should -Be '-'
        $s.Failing -join ',' | Should -Be 'x'
        Get-ReaGhidraStatus -Json 'nope' | Should -BeNullOrEmpty
    }
    It 'the fixtures carry no session or personal string: <what>' -ForEach @(
        @{ what = 'home'; bad = '/home/' + 'user' }
        @{ what = 'tmp session'; bad = '/tmp/' + 'claude' }
        @{ what = 'uid'; bad = 'claude-' + '1001' }
        @{ what = 'surname'; bad = 'Kirgous' + 'sios' }
        @{ what = 'forename'; bad = 'Cos' + 'tas' }
    ) {
        foreach ($n in 'client-ok', 'client-empty', 'ghidra-ok', 'ghidra-bad', 'ghidra-mac-nodecomp') {
            (script:Read-Fix "rea-doctor-$n.json").Contains($bad) | Should -BeFalse
        }
    }
    It 'the failing mac scope check is not classified healthy and fails in both lists' {
        $d = ConvertFrom-Json -InputObject $script:GM
        foreach ($list in @($d.scope_checks, $d.checks)) {
            $c = @($list) | Where-Object { $_.name -eq 'ghidra-native_decompiler' } | Select-Object -First 1
            $c.ok | Should -BeFalse
            $c.classification | Should -Be 'config_drift'
        }
    }
    It 'Hide-ReaSecret hides the value of a JSON-form secret' {
        Hide-ReaSecret '{"GITHUB_TOKEN": "abc123", "x": 1}' | Should -Be '{"GITHUB_TOKEN": "<redacted>", "x": 1}'
    }
}

Describe 'rea steps' {
    BeforeEach {
        $script:Case = Join-Path $script:T ('case ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case | Out-Null
        $script:HomeDir = Join-Path $script:Case 'home dir'
        New-Item -ItemType Directory -Path $script:HomeDir | Out-Null
        $script:Cfg = Join-Path $script:Case 'prof dir/claude'
        New-Item -ItemType Directory -Path $script:Cfg -Force | Out-Null
        $script:Gh = Join-Path $script:Case 'ghidra dir'
        $script:Jh = Join-Path $script:Case 'jdk dir'
        $env:USERPROFILE = $script:HomeDir
        $script:LogFile = Join-Path $script:Case 'run.log'
        $script:ConsoleLevel = 'ERROR'
        $script:Summary = @{}
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:Opt.InstallHopper = $false
        $script:ClaudeConfigDirSelected = $script:Cfg
        $script:GhidraDirSelected = $script:Gh
        $script:JavaHomeSelected = $script:Jh
        $script:Answers = @{}
        $script:Calls = New-Object System.Collections.Generic.List[string]
        $script:EnvSeen = New-Object System.Collections.Generic.List[string]
        $script:ParentConfig = 'parent-config-dir'
        $env:CLAUDE_CONFIG_DIR = $script:ParentConfig
        Mock Resolve-ReaExecutable { return 'npx-stub' }
        Mock Get-ReaPlatform { return @{ Os = 'linux'; Arch = 'x64' } }
        Mock Invoke-ReaCommand {
            $n = $script:Calls.Count + 1
            $script:Calls.Add(($ArgumentList -join ' '))
            $script:EnvSeen.Add(("{0}: {1}|{2}|{3}" -f $n, $env:CLAUDE_CONFIG_DIR, $env:GHIDRA_INSTALL_DIR, $env:JAVA_HOME))
            $a = $script:Answers[$n]
            if ($null -eq $a) { $a = @{} }
            if ($a.ContainsKey('Config')) {
                [System.IO.File]::WriteAllText((Join-Path $script:Cfg '.claude.json'), $a['Config'])
            }
            $code = 0
            if ($a.ContainsKey('Exit')) { $code = $a['Exit'] }
            $out = ''
            if ($a.ContainsKey('Out')) { $out = $a['Out'] }
            $err = ''
            if ($a.ContainsKey('Err')) { $err = $a['Err'] }
            return [pscustomobject]@{ ExitCode = $code; Stdout = $out; Stderr = $err }
        }
    }
    AfterEach {
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:Opt.InstallHopper = $false
        $script:ClaudeConfigDirSelected = ''
        $script:GhidraDirSelected = ''
        $script:JavaHomeSelected = ''
        $script:LogFile = $null
        Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\GHIDRA_INSTALL_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\JAVA_HOME -ErrorAction SilentlyContinue
    }

    Context 'Invoke-ReaEnvironmentCommand' {
        It 'runs npx -y with the pinned spec and the arguments' {
            Invoke-ReaEnvironmentCommand -Step t -ArgumentList @('doctor', '--json') | Out-Null
            $script:Calls[0] | Should -Be '-y rea-agents@latest doctor --json'
        }
        It 'sets the three variables for the child and restores the parent value' {
            Invoke-ReaEnvironmentCommand -Step t -ArgumentList @('x') | Out-Null
            $script:EnvSeen[0] | Should -Be ("1: {0}|{1}|{2}" -f $script:Cfg, $script:Gh, $script:Jh)
            $env:CLAUDE_CONFIG_DIR | Should -Be $script:ParentConfig
            $env:GHIDRA_INSTALL_DIR | Should -BeNullOrEmpty
            $env:JAVA_HOME | Should -BeNullOrEmpty
        }
        It 'removes the variables again when they were unset before' {
            Remove-Item Env:\CLAUDE_CONFIG_DIR
            Invoke-ReaEnvironmentCommand -Step t -ArgumentList @('x') | Out-Null
            [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'Process') | Should -BeNullOrEmpty
            Test-Path Env:\CLAUDE_CONFIG_DIR | Should -BeFalse
            Test-Path Env:\GHIDRA_INSTALL_DIR | Should -BeFalse
            Test-Path Env:\JAVA_HOME | Should -BeFalse
        }
        It 'restores the previous values when the command throws' {
            $env:JAVA_HOME = 'parent-java'
            Mock Invoke-ReaCommand { throw 'boom' }
            { Invoke-ReaEnvironmentCommand -Step t -ArgumentList @('x') } | Should -Throw
            $env:JAVA_HOME | Should -Be 'parent-java'
            $env:CLAUDE_CONFIG_DIR | Should -Be $script:ParentConfig
            Test-Path Env:\GHIDRA_INSTALL_DIR | Should -BeFalse
        }
        It 'stops with 4 when npx is not found' {
            Mock Resolve-ReaExecutable { return $null }
            script:Get-Code { Invoke-ReaEnvironmentCommand -Step t -ArgumentList @('x') } | Should -Be 4
        }
    }

    Context 'Invoke-ReaStepReaSetup' {
        It 'dry-runs, then sets up, finds mcpServers.rea and writes nothing under the home' {
            $script:Answers[2] = @{ Config = $script:CfgOk }
            Invoke-ReaStepReaSetup
            $script:Calls.Count | Should -Be 2
            $script:Calls[0] | Should -Be '-y rea-agents@latest setup --client claude_code --dry-run'
            $script:Calls[1] | Should -Be '-y rea-agents@latest setup --client claude_code --yes'
            $script:EnvSeen[1] | Should -Be ("2: {0}|{1}|{2}" -f $script:Cfg, $script:Gh, $script:Jh)
            $script:Summary['rea_setup'] | Should -Match '^registered rea in '
            Get-LogText | Should -Match 'INFO +\[rea-setup\] ok'
            @(Get-ChildItem -LiteralPath $script:HomeDir -Force).Count | Should -Be 0
            $env:CLAUDE_CONFIG_DIR | Should -Be $script:ParentConfig
        }
        It 'logs the dry-run stdout at DEBUG' {
            $script:Answers[1] = @{ Out = 'would write the registration' }
            $script:Answers[2] = @{ Config = $script:CfgOk }
            Invoke-ReaStepReaSetup
            Get-LogText | Should -Match 'DEBUG +\[rea-setup\] rea setup dry-run output: would write the registration'
        }
        It 'appends --install-hopper to the real call only when asked' {
            $script:Opt.InstallHopper = $true
            $script:Answers[2] = @{ Config = $script:CfgOk }
            Invoke-ReaStepReaSetup
            $script:Calls[0] | Should -Be '-y rea-agents@latest setup --client claude_code --dry-run'
            $script:Calls[1] | Should -Be '-y rea-agents@latest setup --client claude_code --yes --install-hopper'
        }
        It 'dies with 1 when the real setup fails, naming the exit code and stderr' {
            $script:Answers[2] = @{ Exit = 3; Err = 'boom from rea' }
            script:Get-Code { Invoke-ReaStepReaSetup } | Should -Be 1
            Get-LogText | Should -Match 'ERROR +\[rea-setup\] rea setup exited 3: boom from rea'
            $script:Calls.Count | Should -Be 2
        }
        It 'dies with 1 when the dry-run fails, before the real call' {
            $script:Answers[1] = @{ Exit = 7 }
            script:Get-Code { Invoke-ReaStepReaSetup } | Should -Be 1
            $script:Calls.Count | Should -Be 1
        }
        It 'dies with 1 when .claude.json is missing after setup' {
            script:Get-Code { Invoke-ReaStepReaSetup } | Should -Be 1
            Get-LogText | Should -Match 'ERROR +\[rea-setup\] rea setup left no \.claude\.json'
        }
        It 'dies with 1 when .claude.json has <name>' -ForEach @(
            @{ name = 'no rea'; cfg = '{"mcpServers":{}}' }
            @{ name = 'null mcpServers'; cfg = '{"mcpServers":null}' }
            @{ name = 'a string rea'; cfg = '{"mcpServers":{"rea":"x"}}' }
            @{ name = 'no mcpServers'; cfg = '{}' }
            @{ name = 'a body that is not JSON'; cfg = 'not json' }
        ) {
            $script:Answers[2] = @{ Config = $cfg }
            script:Get-Code { Invoke-ReaStepReaSetup } | Should -Be 1
            Get-LogText | Should -Match 'ERROR +\[rea-setup\] .*no mcpServers\.rea'
        }
        It 'refuses <name> with 1 and runs nothing' -ForEach @(
            @{ name = 'the shared .claude'; dir = 'HOME/.claude' }
            @{ name = 'a subpath of the shared .claude'; dir = 'HOME/.claude/profiles/x' }
            @{ name = 'an empty selection'; dir = '' }
        ) {
            $script:ClaudeConfigDirSelected = ($dir -replace '^HOME', $script:HomeDir)
            script:Get-Code { Invoke-ReaStepReaSetup } | Should -Be 1
            $script:Calls.Count | Should -Be 0
        }
        It 'dies with 1 without a Ghidra directory or a JDK' {
            $script:GhidraDirSelected = ''
            script:Get-Code { Invoke-ReaStepReaSetup } | Should -Be 1
            $script:GhidraDirSelected = $script:Gh
            $script:JavaHomeSelected = ''
            script:Get-Code { Invoke-ReaStepReaSetup } | Should -Be 1
            $script:Calls.Count | Should -Be 0
        }
        It '-DryRun makes the dry-run call only' {
            $script:Opt.DryRun = $true
            Invoke-ReaStepReaSetup
            $script:Calls.Count | Should -Be 1
            $script:Calls[0] | Should -Match 'setup --client claude_code --dry-run$'
            Get-LogText | Should -Match 'read-only run'
        }
        It '-DryRun with nothing selected runs no npx' {
            $script:Opt.DryRun = $true
            $script:ClaudeConfigDirSelected = ''
            Invoke-ReaStepReaSetup
            $script:Calls.Count | Should -Be 0
        }
        It '-CheckUpstream skips the step' {
            $script:Opt.CheckUpstream = $true
            Invoke-ReaStepReaSetup
            $script:Calls.Count | Should -Be 0
            Get-LogText | Should -Match 'INFO +\[rea-setup\] skip \(-CheckUpstream\)'
        }
    }

    Context 'Invoke-ReaStepReaDoctor' {
        It 'passes on a healthy client and an available Ghidra' {
            $script:Answers[1] = @{ Out = $script:CO }
            $script:Answers[2] = @{ Out = $script:GO }
            Invoke-ReaStepReaDoctor
            $script:Calls[0] | Should -Be '-y rea-agents@latest doctor --client claude_code --skill --json'
            $script:Calls[1] | Should -Be '-y rea-agents@latest doctor --provider ghidra --json'
            $script:Summary['rea_doctor'] | Should -Be 'ok: ghidra 12.1.4'
            $script:EnvSeen[1] | Should -Be ("2: {0}|{1}|{2}" -f $script:Cfg, $script:Gh, $script:Jh)
            Get-LogText | Should -Match 'INFO +\[rea-doctor\] ok'
        }
        It 'reads an unhealthy answer given with exit 1 and dies with 5 naming registration:claude_code' {
            $script:Answers[1] = @{ Out = $script:CE; Exit = 1 }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'ERROR +\[rea-doctor\] .*registration:claude_code skill:identity'
            $script:Calls.Count | Should -Be 1
        }
        It 'dies with 5 naming installation and java for a bad Ghidra' {
            $script:Answers[1] = @{ Out = $script:CO }
            $script:Answers[2] = @{ Out = $script:GB; Exit = 1 }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'ERROR +\[rea-doctor\] .*installation,java'
            Get-LogText | Should -Not -Match 'accepts Ghidra'
        }
        It 'adds the pins hint when the version check fails' {
            $bad = $script:GB.Replace('"name":"installation","ok":false', '"name":"installation","ok":true').Replace('"name":"java","ok":false', '"name":"version","ok":false')
            $script:Answers[1] = @{ Out = $script:CO }
            $script:Answers[2] = @{ Out = $bad; Exit = 1 }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'rea 6\.8\.0 accepts Ghidra 12\.1\.x; if rea now requires another line, update the pins block \(PIN_GHIDRA_\*\)'
        }
        It 'on mac a lone native_decompiler failure is a WARN and a warn summary' {
            Mock Get-ReaPlatform { return @{ Os = 'mac'; Arch = 'x64' } }
            $script:Answers[1] = @{ Out = $script:CO }
            $script:Answers[2] = @{ Out = $script:GM; Exit = 1 }
            Invoke-ReaStepReaDoctor
            $text = Get-LogText
            $text | Should -Match 'WARN +\[rea-doctor\] .*Missing macOS native decompiler.*macOS arm64 native decompiler'
            $text | Should -Match ('WARN +\[rea-doctor\] .*' + [regex]::Escape($script:Gh))
            $script:Summary['rea_doctor'] | Should -Match '^warn: '
        }
        It 'on linux the same answer dies with 5' {
            $script:Answers[1] = @{ Out = $script:CO }
            $script:Answers[2] = @{ Out = $script:GM; Exit = 1 }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'ERROR +\[rea-doctor\] .*native_decompiler'
        }
        It 'on mac another failure besides native_decompiler dies with 5' {
            Mock Get-ReaPlatform { return @{ Os = 'mac'; Arch = 'x64' } }
            $two = $script:GM.Replace('"name":"java","ok":true', '"name":"java","ok":false')
            $script:Answers[1] = @{ Out = $script:CO }
            $script:Answers[2] = @{ Out = $two; Exit = 1 }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
        }
        It 'dies with 5 and a stderr tail on <name>' -ForEach @(
            @{ name = 'output that is not JSON'; out = 'this is not json' }
            @{ name = 'empty output'; out = '' }
            @{ name = 'a JSON array'; out = '[1,2]' }
        ) {
            $script:Answers[1] = @{ Out = $out; Err = 'npm ERR! network' }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'ERROR +\[rea-doctor\] .*not a JSON object.*npm ERR! network'
        }
        It 'dies with 5 on an exit code other than 0 and 1 even with parsable output' {
            $script:Answers[1] = @{ Out = $script:CO; Exit = 127; Err = 'npx: not found' }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'exited 127: npx: not found'
        }
        It 'dies with 5 on exit 1 with healthy:true and says the exit code and the JSON disagree' {
            $script:Answers[1] = @{ Out = $script:CO; Exit = 1 }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'ERROR +\[rea-doctor\] .*exit code and the JSON disagree'
            $script:Calls.Count | Should -Be 1
        }
        It 'dies with 5 on exit 0 with healthy:false, naming the failing scope checks' {
            $script:Answers[1] = @{ Out = $script:CE; Exit = 0 }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'ERROR +\[rea-doctor\] .*registration:claude_code skill:identity'
        }
        It 'dies with 5 on exit 1 with available:true (also on mac)' -ForEach @(@{ os = 'linux' }, @{ os = 'mac' }) {
            Mock Get-ReaPlatform { return @{ Os = $os; Arch = 'x64' } }
            $script:Answers[1] = @{ Out = $script:CO }
            $script:Answers[2] = @{ Out = $script:GO; Exit = 1 }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'ERROR +\[rea-doctor\] .*exit code and the JSON disagree'
        }
        It 'dies with 5 on a ghidra doctor exit 2 with the stderr tail' {
            $script:Answers[1] = @{ Out = $script:CO }
            $script:Answers[2] = @{ Out = $script:GO; Exit = 2; Err = 'usage error' }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'exited 2: usage error'
        }
        It 'logs the raw JSON of both calls at DEBUG, redacted, and not visible at INFO' {
            $script:ConsoleLevel = 'INFO'
            $d = ConvertFrom-Json -InputObject $script:CO
            $d.identity.cli_package_version = '6.8.0-uniq-4711'
            $d | Add-Member -NotePropertyName GITHUB_TOKEN -NotePropertyValue 'abc123'
            $script:Answers[1] = @{ Out = (ConvertTo-Json -InputObject $d -Depth 20 -Compress) }
            $script:Answers[2] = @{ Out = $script:GO }
            Invoke-ReaStepReaDoctor
            $text = Get-LogText
            $text | Should -Match 'DEBUG +\[rea-doctor\] rea doctor --client claude_code --skill --json output: .*6\.8\.0-uniq-4711'
            $text | Should -Match 'DEBUG +\[rea-doctor\] rea doctor --provider ghidra --json output: .*providerVersion'
            $text | Should -Not -Match 'abc123'
            $text | Should -Match '<redacted>'
            Test-ReaLogVisible -Level DEBUG | Should -BeFalse
        }
        It 'logs the raw JSON of an unhealthy answer too' {
            $script:Answers[1] = @{ Out = $script:CE; Exit = 1 }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Match 'output: \{"healthy":false'
        }
        It 'bounds the logged JSON to 200000 characters with a marker and still parses it whole' {
            $script:Answers[1] = @{ Out = ('{"healthy":true,"pad":"' + ('x' * 250000) + '"}') }
            $script:Answers[2] = @{ Out = $script:GO }
            Invoke-ReaStepReaDoctor
            $text = Get-LogText
            $text | Should -Match '\[output truncated at 200000 characters\]'
            (($text -split "`n") | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessThan 201000
        }
        It 'cuts the stderr tail at a line boundary so a sliced secret name leaks nothing' {
            $script:Answers[2] = @{ Exit = 3; Err = ("first line`nANTHROPIC_API_KEY=sk-secret-123`n" + ('y' * 983)) }
            script:Get-Code { Invoke-ReaStepReaSetup } | Should -Be 1
            $text = Get-LogText
            $text | Should -Match 'ERROR +\[rea-setup\] rea setup exited 3: '
            $text | Should -Not -Match 'sk-secret-123'
            $text | Should -Match 'yyyyyyyy'
        }
        It '-DryRun skips it' {
            $script:Opt.DryRun = $true
            Invoke-ReaStepReaDoctor
            $script:Calls.Count | Should -Be 0
            Get-LogText | Should -Match 'skip \(-DryRun\)'
        }
        It '-CheckUpstream skips it' {
            $script:Opt.CheckUpstream = $true
            Invoke-ReaStepReaDoctor
            $script:Calls.Count | Should -Be 0
        }
        It 'refuses the shared profile directory with 1' {
            $script:ClaudeConfigDirSelected = Join-Path $script:HomeDir '.claude'
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 1
            $script:Calls.Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $script:HomeDir -Force).Count | Should -Be 0
        }
        It 'does not log a secret from rea output' {
            $script:Answers[1] = @{ Out = 'token=abcd ANTHROPIC_API_KEY=sk-secret-123' }
            script:Get-Code { Invoke-ReaStepReaDoctor } | Should -Be 5
            Get-LogText | Should -Not -Match 'sk-secret-123'
        }
    }
}

Describe 'pin' {
    It 'PIN_REA_SPEC is rea-agents@latest' {
        $script:PIN_REA_SPEC | Should -Be 'rea-agents@latest'
    }
}

Describe 'temporary files' {
    It 'Invoke-ReaCommand leaves no file in a private TMPDIR after a failing command' -Skip:($IsWindows -eq $true -or $PSVersionTable.PSVersion.Major -lt 6) {
        $priv = Join-Path $script:T 'priv tmp'
        New-Item -ItemType Directory -Path $priv | Out-Null
        $saved = $env:TMPDIR
        $script:LogFile = $null
        try {
            $env:TMPDIR = $priv
            $r = Invoke-ReaCommand -Step t -FilePath 'sh' -ArgumentList @('-c', 'echo out; echo err >&2; exit 3')
            $r.ExitCode | Should -Be 3
            @(Get-ChildItem -LiteralPath $priv -Force).Count | Should -Be 0
        } finally {
            $env:TMPDIR = $saved
        }
    }
}
