# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.ps1 core: logging, redaction, platform, validation, versions. They mirror
# tests/sh/core.sh assertion for assertion.

BeforeDiscovery {
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
}

BeforeAll {
    $env:REA_SETUP_NO_MAIN = '1'
    $script:SetupPath = (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    . $script:SetupPath
    $script:Pwsh = (Get-Process -Id $PID).Path
}

Describe 'Write-ReaLog format' {
    It 'formats a UTC ISO-8601 Z timestamp, LEVEL padded to 5, [step], message' {
        Format-ReaLogLine -Level INFO -Step ghidra -Message hello -Timestamp '2026-01-02T03:04:05Z' |
            Should -Be '2026-01-02T03:04:05Z INFO  [ghidra] hello'
    }

    It 'uses a real UTC timestamp by default' {
        Format-ReaLogLine -Level ERROR -Step x -Message m | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ ERROR \[x\] m$'
    }

    It 'shows ERROR on the console at INFO' {
        Test-ReaLogVisible -Level ERROR -Threshold INFO | Should -BeTrue
    }

    It 'hides INFO at WARN (quiet)' {
        Test-ReaLogVisible -Level INFO -Threshold WARN | Should -BeFalse
    }

    It 'ranks an unknown level as INFO' {
        Test-ReaLogVisible -Level BOGUS -Threshold INFO | Should -BeTrue
        Test-ReaLogVisible -Level BOGUS -Threshold WARN | Should -BeFalse
    }

    It 'writes UTF-8 without BOM' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        try {
            $log = Open-ReaLog -Directory $dir
            Write-ReaLog -Level 'DEBUG' -Step 'bom' -Message ('ab' + [char]0xE9)
            $bytes = [System.IO.File]::ReadAllBytes($log)
            $bytes.Length | Should -BeGreaterThan 3
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
            [System.IO.File]::ReadAllText($log) | Should -Match ' DEBUG \[bom\] ab'
        } finally {
            $script:LogFile = $null
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'abbreviates the home directory in the file' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = '/home/u'
            $log = Open-ReaLog -Directory $dir
            Write-ReaLog -Level DEBUG -Step x -Message 'see /home/u/x and /home/ux and /home/u'
            [System.IO.File]::ReadAllText($log) | Should -Match 'see %USERPROFILE%/x and /home/ux and %USERPROFILE%\s*$'
        } finally {
            $env:USERPROFILE = $saved
            $script:LogFile = $null
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'redacts inside the log file' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        try {
            $log = Open-ReaLog -Directory $dir
            Write-ReaLog -Level DEBUG -Step x -Message 'api_key=abc'
            $text = [System.IO.File]::ReadAllText($log)
            $text | Should -Match 'api_key=<redacted>'
            $text | Should -Not -Match 'abc'
        } finally {
            $script:LogFile = $null
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps going with a warning when the log directory cannot be created' {
        $blocker = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $blocker -Value 'file'
        Mock Write-ReaWarning { }
        try {
            $r = Open-ReaLog -Directory (Join-Path $blocker 'sub')
            $r | Should -BeNullOrEmpty
            $script:LogFile | Should -BeNullOrEmpty
            Should -Invoke Write-ReaWarning -Exactly 1 -ParameterFilter { $Message -like 'warning: cannot create a log file in *; continuing without one' }
        } finally {
            Remove-Item -LiteralPath $blocker -Force -ErrorAction SilentlyContinue
        }
    }

    It 'warns once and drops the log when an append fails' {
        Mock Write-ReaWarning { }
        $script:LogFile = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-missing-" + [guid]::NewGuid().ToString('N') + '/x.log')
        Write-ReaLog -Level DEBUG -Step x -Message hi
        $script:LogFile | Should -BeNullOrEmpty
        Should -Invoke Write-ReaWarning -Exactly 1 -ParameterFilter { $Message -eq 'warning: cannot write the log file; continuing without one' }
    }

    It 'keeps only the newest 20 logs' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            1..25 | ForEach-Object { Set-Content -LiteralPath (Join-Path $dir ('setup-2020010{0:D2}T000000Z-1.log' -f $_)) -Value x }
            Open-ReaLog -Directory $dir | Out-Null
            @(Get-ChildItem -LiteralPath $dir -Filter 'setup-*.log').Count | Should -Be 20
            Test-Path -LiteralPath (Join-Path $dir 'setup-202001001T000000Z-1.log') | Should -BeFalse
        } finally {
            $script:LogFile = $null
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Hide-ReaSecret' {
    It 'redacts names containing TOKEN or KEY' {
        Hide-ReaSecret 'GITHUB_TOKEN=abc KEY=def' | Should -Be 'GITHUB_TOKEN=<redacted> KEY=<redacted>'
    }
    It 'strips URL userinfo and query' {
        Hide-ReaSecret 'https://u:p@h/p?x=1' | Should -Be 'https://h/p'
    }
    It 'redacts a lowercase name' {
        Hide-ReaSecret 'api_key=abc x' | Should -Be 'api_key=<redacted> x'
    }
    It 'redacts a lowercase password' {
        Hide-ReaSecret 'password=hunter2' | Should -Be 'password=<redacted>'
    }
    It 'redacts mixed case' {
        Hide-ReaSecret 'Github_Token=x' | Should -Be 'Github_Token=<redacted>'
    }
    It 'redacts a double-quoted value whole' {
        Hide-ReaSecret 'PASSWORD="a b c" next' | Should -Be 'PASSWORD=<redacted> next'
    }
    It 'redacts a single-quoted value whole' {
        Hide-ReaSecret "my_secret='a b c' next" | Should -Be 'my_secret=<redacted> next'
    }
    It 'strips an AUTHORIZATION header' {
        Hide-ReaSecret 'AUTHORIZATION: Bearer abc' | Should -Be 'AUTHORIZATION: <redacted>'
    }
    It 'strips an authorization header' {
        Hide-ReaSecret 'authorization: Bearer abc' | Should -Be 'authorization: <redacted>'
    }
    It 'leaves other text alone' {
        Hide-ReaSecret 'plain=value' | Should -Be 'plain=value'
    }
}

Describe 'Get-ReaShortPath' {
    BeforeEach { $script:SavedHome = $env:USERPROFILE }
    AfterEach { $env:USERPROFILE = $script:SavedHome }

    It 'abbreviates the home directory as %USERPROFILE%' {
        $env:USERPROFILE = '/home/u'
        Get-ReaShortPath '/home/u/x' | Should -Be '%USERPROFILE%/x'
    }
    It 'abbreviates the home directory itself' {
        $env:USERPROFILE = '/home/u'
        Get-ReaShortPath '/home/u' | Should -Be '%USERPROFILE%'
    }
    It 'handles backslashes and case on Windows-style paths' {
        $env:USERPROFILE = 'C:\Users\Bob'
        Get-ReaShortPath 'c:\users\bob\x' | Should -Be '%USERPROFILE%\x'
    }
    It 'does nothing with an empty home' {
        $env:USERPROFILE = ''
        Get-ReaShortPath '/etc/passwd' | Should -Be '/etc/passwd'
    }
    It 'respects the path boundary' {
        $env:USERPROFILE = '/home/u'
        Get-ReaShortPath '/home/ux/y' | Should -Be '/home/ux/y'
    }
}

Describe 'Get-ReaPlatform' {
    It 'reports windows x64' {
        $p = Get-ReaPlatform -Architecture X64
        $p.Os | Should -Be 'windows'
        $p.Arch | Should -Be 'x64'
    }
    It 'reports windows aarch64 for Arm64' {
        (Get-ReaPlatform -Architecture Arm64).Arch | Should -Be 'aarch64'
    }
    It 'passes an unknown architecture through lower-cased' {
        (Get-ReaPlatform -Architecture X86).Arch | Should -Be 'x86'
    }
    It 'reads the runtime architecture by default' {
        (Get-ReaPlatform).Arch | Should -Not -BeNullOrEmpty
    }
    It 'falls back to the environment when RuntimeInformation is unavailable' {
        Mock Get-ReaRuntimeArchitecture { throw 'no RuntimeInformation' }
        Mock Get-ReaEnvArchitecture { 'ARM64' }
        (Get-ReaPlatform).Arch | Should -Be 'aarch64'
    }
}

Describe 'Get-ReaEnvArchitecture' {
    It 'maps AMD64 to X64' {
        Get-ReaEnvArchitecture -Wow64 '' -Native 'AMD64' | Should -Be 'X64'
    }
    It 'maps ARM64 to Arm64' {
        Get-ReaEnvArchitecture -Wow64 '' -Native 'ARM64' | Should -Be 'Arm64'
    }
    It 'lets ARCHITEW6432 win for a 32-bit process on 64-bit Windows' {
        Get-ReaEnvArchitecture -Wow64 'AMD64' -Native 'x86' | Should -Be 'X64'
        Get-ReaEnvArchitecture -Wow64 'ARM64' -Native 'x86' | Should -Be 'Arm64'
    }
    It 'passes native x86 through, so the caller reports it unsupported' {
        (Get-ReaPlatform -Architecture (Get-ReaEnvArchitecture -Wow64 '' -Native 'x86')).Arch | Should -Be 'x86'
    }
    It 'returns an unsupported marker when both variables are empty' {
        $a = Get-ReaEnvArchitecture -Wow64 '' -Native ''
        $a | Should -Be 'unknown'
        (Get-ReaPlatform -Architecture $a).Arch | Should -Be 'unknown'
    }
}

Describe 'Test-ReaProfileName' {
    It 'accepts rea-1.x' {
        Test-ReaProfileName 'rea-1.x' | Should -BeTrue
    }
    It 'rejects <_>' -ForEach @('doctor', 'Doctor', 'CON', 'con', 'con.txt', '-x', '', 'a b', 'ok.', "a`nb", "ok`n") {
        Test-ReaProfileName $_ | Should -BeFalse
    }
}

Describe 'Semver' {
    It 'extracts from clavity-ls output' {
        Get-ReaSemver 'clavity-ls 0.17.0+c356375b' | Should -Be '0.17.0'
    }
    It 'extracts from agent-profile output' {
        Get-ReaSemver 'agent-profile 0.1.1' | Should -Be '0.1.1'
    }
    It 'returns nothing when there is no version' {
        Get-ReaSemver 'no version here' | Should -BeNullOrEmpty
    }
    It 'compares lt' {
        Compare-ReaSemver '0.1.1' '0.1.2' | Should -Be -1
    }
    It 'compares gt numerically' {
        Compare-ReaSemver '0.17.0' '0.9.9' | Should -Be 1
    }
    It 'tolerates a suffix' {
        Compare-ReaSemver '24.22.1-rc' '24.22.1' | Should -Be 0
    }
    It 'tolerates missing parts' {
        Compare-ReaSemver '22' '22.0.1' | Should -Be -1
    }
}

Describe 'Test-ReaNodeVersion' {
    It 'rejects 24.21.0' { Test-ReaNodeVersion 'v24.21.0' | Should -BeFalse }
    It 'accepts 24.22.2' { Test-ReaNodeVersion 'v24.22.2' | Should -BeTrue }
    It 'accepts 26.12.1' { Test-ReaNodeVersion 'v26.12.1' | Should -BeTrue }
    It 'rejects 23' { Test-ReaNodeVersion 'v23.5.0' | Should -BeFalse }
    It 'accepts 24.22.1-rc' { Test-ReaNodeVersion 'v24.22.1-rc' | Should -BeTrue }
    It 'rejects bare v22' { Test-ReaNodeVersion 'v22' | Should -BeFalse }
    It 'accepts 22.23.4' { Test-ReaNodeVersion '22.23.4' | Should -BeTrue }
    It 'rejects 25' { Test-ReaNodeVersion 'v25.0.0' | Should -BeFalse }
    It 'rejects 26.12.0' { Test-ReaNodeVersion 'v26.12.0' | Should -BeFalse }
    It 'accepts 27' { Test-ReaNodeVersion 'v27.0.0' | Should -BeTrue }
    It 'rejects garbage' { Test-ReaNodeVersion 'banana' | Should -BeFalse }
}

Describe 'Stop-Rea and Read-ReaConfirm' {
    It 'throws carrying the exit code' {
        $err = $null
        try { Stop-Rea -Code 4 -Step prereq -Message 'nope' } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Data['ReaCode'] | Should -Be 4
    }
    It 'still throws with -Confirm:$true' {
        $err = $null
        try { Stop-Rea -Code 4 -Step prereq -Message 'nope' -Confirm:$true } catch { $err = $_ }
        $err.Exception.Data['ReaCode'] | Should -Be 4
    }
    It 'still throws with $ConfirmPreference Low' {
        $saved = $ConfirmPreference
        $err = $null
        try {
            $ConfirmPreference = 'Low'
            Stop-Rea -Code 4 -Step prereq -Message 'nope'
        } catch { $err = $_ } finally { $ConfirmPreference = $saved }
        $err.Exception.Data['ReaCode'] | Should -Be 4
    }
    It 'confirms without asking under -Yes' {
        $script:OptYes = $true
        try { Read-ReaConfirm -Prompt 'Proceed?' | Should -BeTrue } finally { $script:OptYes = $false }
    }
    It 'refuses with code 2 when there is no terminal and no -Yes' {
        $script:OptYes = $false
        Mock Test-ReaInteractive { $false }
        $err = $null
        try { Read-ReaConfirm -Prompt 'Proceed?' } catch { $err = $_ }
        $err.Exception.Data['ReaCode'] | Should -Be 2
    }
}

Describe 'Format-ReaInvocation' {
    It 'lists names and values, switches by name only' {
        Format-ReaInvocation @{ ProfileName = 'x'; Yes = [switch]$true } | Should -Be '-ProfileName=x -Yes'
    }
    It 'is empty without parameters' {
        Format-ReaInvocation @{} | Should -Be '(no parameters)'
    }
    It 'is redacted by the log writer' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        try {
            $log = Open-ReaLog -Directory $dir
            Write-ReaLog -Level DEBUG -Step x -Message ('invoked: ' + (Format-ReaInvocation @{ ApiToken = 'abc'; Yes = [switch]$true }))
            $text = [System.IO.File]::ReadAllText($log)
            $text | Should -Match 'invoked: .*-ApiToken=<redacted>'
            $text | Should -Not -Match 'abc'
        } finally {
            $script:LogFile = $null
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-ReaCommand' {
    It 'returns the exit code and captured output' {
        $r = Invoke-ReaCommand -Step t -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', 'Write-Output hi; exit 3')
        $r.ExitCode | Should -Be 3
        $r.Stdout.Trim() | Should -Be 'hi'
    }
}

Describe 'Invoke-Main' {
    BeforeAll {
        function Invoke-Setup {
            param([string[]]$ScriptArgs)
            $saved = $env:REA_SETUP_NO_MAIN
            Remove-Item Env:\REA_SETUP_NO_MAIN
            try {
                $out = & $script:Pwsh -NoProfile -File $script:SetupPath @ScriptArgs 2>&1
                [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out | Out-String) }
            } finally {
                $env:REA_SETUP_NO_MAIN = $saved
            }
        }
    }

    It 'rejects -InstallHopper on Windows' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        try {
            $r = Invoke-Setup -ScriptArgs @('-InstallHopper', '-Yes', '-LogDir', $dir)
            $r.Code | Should -Be 2
            $r.Output | Should -Match 'not available on Windows'
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects an invalid profile name with code 2' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        try {
            $r = Invoke-Setup -ScriptArgs @('-ProfileName', 'doctor', '-Yes', '-LogDir', $dir)
            $r.Code | Should -Be 2
            $r.Output | Should -Match 'invalid profile name: doctor'
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs preflight, prereq, tools-bin and jdk and writes one log file (steps mocked, same on every OS)' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        $savedLogDir = $script:Opt.LogDir
        $savedLog = $script:LogFile
        try {
            $script:Opt.LogDir = $dir
            $script:Calls = New-Object System.Collections.Generic.List[string]
            Mock Invoke-ReaStepPreflight { $script:Calls.Add('preflight') }
            Mock Invoke-ReaStepPrereq { $script:Calls.Add('prereq') }
            Mock Invoke-ReaStepToolsBin { $script:Calls.Add('tools-bin') }
            Mock Invoke-ReaStepJdk { $script:Calls.Add('jdk') }
            Mock Unlock-ReaToolsDir { $script:Calls.Add('unlock') }
            Invoke-Main | Should -Be 0
            ($script:Calls -join ',') | Should -Be 'preflight,prereq,tools-bin,jdk,unlock'
            @(Get-ChildItem -LiteralPath $dir -Filter 'setup-*.log').Count | Should -Be 1
        } finally {
            $script:Opt.LogDir = $savedLogDir
            $script:LogFile = $savedLog
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a real run off Windows fails at the fixed-NTFS check and still logs the invocation' -Skip:$script:OnWindows {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("rea-core-" + [guid]::NewGuid().ToString('N'))
        try {
            $r = Invoke-Setup -ScriptArgs @('-DryRun', '-Yes', '-LogDir', $dir)
            $r.Output | Should -Match 'platform: windows'
            $r.Code | Should -Be 1
            $r.Output | Should -Match 'fixed NTFS'
            $text = [System.IO.File]::ReadAllText((Get-ChildItem -LiteralPath $dir -Filter 'setup-*.log').FullName)
            $text | Should -Match '(?m)invoked: -DryRun -LogDir=.* -Yes\s*$'
            @(Get-ChildItem -LiteralPath $dir -Filter 'setup-*.log').Count | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'pins' {
    It 'carries the pin block the drift gate reads' {
        $script:PIN_GHIDRA_SHA256 | Should -Match '^[0-9a-f]{64}$'
        $script:PIN_SCRIPT_VERSION | Should -Not -BeNullOrEmpty
    }
}
