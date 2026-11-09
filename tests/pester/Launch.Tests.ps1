# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the plan phase, the disclosures, the confirmation, the env file, the summary and the launch step of
# setup.ps1; they mirror tests/sh/launch.sh. What a step writes on stdout goes through Write-ReaOutput and what
# the user reads before the question through Write-ReaNotice, both mocked here to record the lines. The launch
# runs through Start-ReaLaunchProcess, mocked for the Windows-shaped cases; one case runs the clavity-ls stub of
# tests/fixtures/bin for real (Linux only). The last Describe is the dry-run end to end: the real plan, steps and
# output over a throwaway machine, with only the Windows-specific steps and the network replaced.

BeforeDiscovery {
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
}

BeforeAll {
    $env:REA_SETUP_NO_MAIN = '1'
    . (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:Fix = Join-Path $script:Root 'tests/fixtures'
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('rea launch work ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:T | Out-Null
    $script:SavedJavaHome = $env:JAVA_HOME
    $script:SavedGhidra = $env:GHIDRA_INSTALL_DIR

    function script:Get-Code {
        param([scriptblock]$Block)
        try { & $Block } catch { return $_.Exception.Data['ReaCode'] }
        return 0
    }
    # Every entry of Dir, one per line, sorted (a literal path, so odd names are safe).
    function script:Get-Listing {
        param([string]$Dir)
        if (-not (Test-Path -LiteralPath $Dir)) { return @() }
        return @(Get-ChildItem -LiteralPath $Dir -Force -Recurse | ForEach-Object { $_.FullName } | Sort-Object)
    }
    function script:Reset-State {
        $script:Plan = $null
        $script:PlanToolsBin = ''
        $script:PlanJdk = ''
        $script:PlanGhidra = ''
        $script:PlanToolsBinText = ''
        $script:PlanJdkText = ''
        $script:PlanGhidraText = ''
        $script:PlanJdkBytes = [int64]0
        $script:PlanGhidraBytes = [int64]0
        $script:ToolsBinPlanned = $null
        $script:JdkPlanned = $null
        $script:JdkReused = $false
        $script:GhidraReused = $false
        $script:EnvFile = ''
        $script:OptYes = $false
        $script:Summary = @{}
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:Opt.NoLaunch = $false
        $script:Opt.Yes = $false
        $script:Opt.ProfileName = 'rea'
        $script:Opt.Folder = (Join-Path $script:T "my folder's here")
        $script:Opt.GhidraDir = ''
        $script:Opt.JavaHome = ''
        $script:Bound = @{}
        $script:ToolsDir = Join-Path $script:T "tools dir"
        $script:BinDir = Join-Path $script:T "bin dir's"
        $script:GhidraDirSelected = Join-Path $script:T "ghidra dir's x"
        $script:JavaHomeSelected = Join-Path $script:T "jdk d'ir"
        $script:LogFile = Join-Path $script:T 'unit.log'
        $script:ConsoleLevel = 'ERROR'
        $env:JAVA_HOME = $null
        $env:GHIDRA_INSTALL_DIR = $null
    }
    script:Reset-State
}

AfterAll {
    $env:JAVA_HOME = $script:SavedJavaHome
    $env:GHIDRA_INSTALL_DIR = $script:SavedGhidra
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'the env file' {
    BeforeEach {
        script:Reset-State
        Remove-Item -LiteralPath $script:ToolsDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:ToolsDir | Out-Null
    }

    It 'ConvertTo-ReaPsQuoted doubles each embedded quote and nothing else' {
        ConvertTo-ReaPsQuoted 'plain' | Should -BeExactly "'plain'"
        ConvertTo-ReaPsQuoted "a'b" | Should -BeExactly "'a''b'"
        ConvertTo-ReaPsQuoted 'a b $x `y` "z"' | Should -BeExactly "'a b `$x ``y`` `"z`"'"
    }

    It 'ConvertTo-ReaPsQuoted doubles every character PowerShell reads as a single quote: <name>' -ForEach @(
        @{ name = 'ASCII apostrophe'; ch = [string][char]0x27 }
        @{ name = 'left single quotation mark'; ch = [string][char]0x2018 }
        @{ name = 'right single quotation mark'; ch = [string][char]0x2019 }
        @{ name = 'single low-9 quotation mark'; ch = [string][char]0x201A }
        @{ name = 'single high-reversed-9 quotation mark'; ch = [string][char]0x201B }
    ) {
        ConvertTo-ReaPsQuoted ('a' + $ch + 'b') | Should -BeExactly ([string][char]0x27 + 'a' + $ch + $ch + 'b' + [string][char]0x27)
    }

    It 'the file round-trips a path with every single-quote look-alike and shell metacharacters (dot-sourced in a child)' {
        $q = ([string][char]0x2019) + ([string][char]0x2018) + ([string][char]0x201A) + ([string][char]0x201B) + "'"
        $script:GhidraDirSelected = Join-Path $script:T ("John O${q}Brien `$x ``y`` `"z`"; a&b (c) %PATH%")
        $script:JavaHomeSelected = Join-Path $script:T "jdk $q end"
        $script:BinDir = Join-Path $script:T "bin $q dir"
        Write-ReaEnvFile -ToolsDir $script:ToolsDir
        $runner = Join-Path $script:T 'source2.ps1'
        [System.IO.File]::WriteAllText($runner, ". `$args[0]`n`$env:GHIDRA_INSTALL_DIR`n`$env:JAVA_HOME`n(`$env:PATH -split [System.IO.Path]::PathSeparator)[0]`n", (New-Object System.Text.UTF8Encoding $true))
        $got = @(& $script:Pwsh -NoProfile -File $runner (Join-Path $script:ToolsDir 'env.ps1'))
        $got.Count | Should -Be 3
        $got[0] | Should -BeExactly $script:GhidraDirSelected
        $got[1] | Should -BeExactly $script:JavaHomeSelected
        $got[2] | Should -BeExactly $script:BinDir
    }

    It 'a dry run writes nothing' {
        $script:Opt.DryRun = $true
        Write-ReaEnvFile -ToolsDir $script:ToolsDir
        @(script:Get-Listing $script:ToolsDir).Count | Should -Be 0
        $script:EnvFile | Should -Be ''
    }

    It '-CheckUpstream writes nothing' {
        $script:Opt.CheckUpstream = $true
        Write-ReaEnvFile -ToolsDir $script:ToolsDir
        @(script:Get-Listing $script:ToolsDir).Count | Should -Be 0
    }

    It 'writes env.ps1 that sets the three values exactly (spaces and quotes), with a BOM and no temporary file' {
        Write-ReaEnvFile -ToolsDir $script:ToolsDir
        $file = Join-Path $script:ToolsDir 'env.ps1'
        $file | Should -Exist
        $script:EnvFile | Should -Be $file
        @(script:Get-Listing $script:ToolsDir).Count | Should -Be 1
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
        $runner = Join-Path $script:T 'source.ps1'
        [System.IO.File]::WriteAllText($runner, ". `$args[0]`n`$env:GHIDRA_INSTALL_DIR`n`$env:JAVA_HOME`n(`$env:PATH -split [System.IO.Path]::PathSeparator)[0]`n(`$env:PATH -split [System.IO.Path]::PathSeparator)[1]`n")
        $got = @(& $script:Pwsh -NoProfile -File $runner $file)
        $got[0] | Should -BeExactly $script:GhidraDirSelected
        $got[1] | Should -BeExactly $script:JavaHomeSelected
        $got[2] | Should -BeExactly $script:BinDir
        $got.Count | Should -BeGreaterThan 3
    }

    It 'overwrites the old file on every run' {
        Write-ReaEnvFile -ToolsDir $script:ToolsDir
        $script:GhidraDirSelected = Join-Path $script:T 'other ghidra'
        Write-ReaEnvFile -ToolsDir $script:ToolsDir
        [System.IO.File]::ReadAllText((Join-Path $script:ToolsDir 'env.ps1')) | Should -Match 'other ghidra'
        @(script:Get-Listing $script:ToolsDir).Count | Should -Be 1
    }

    It 'stops with 1 when no JDK was selected' {
        $script:JavaHomeSelected = ''
        script:Get-Code { Write-ReaEnvFile -ToolsDir $script:ToolsDir } | Should -Be 1
    }
}

Describe 'the plan phase' {
    BeforeEach {
        script:Reset-State
        Remove-Item -LiteralPath $script:ToolsDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:ToolsDir | Out-Null
        Mock Write-ReaNotice { }
        Mock Write-ReaOutput { }
    }

    It 'Get-ReaNeededMb: <ghidra> <jdk> is <want>' -ForEach @(
        @{ ghidra = 'reuse'; jdk = 'reuse'; want = 200 }
        @{ ghidra = 'reuse'; jdk = 'install'; want = 800 }
        @{ ghidra = 'install'; jdk = 'reuse'; want = 1700 }
        @{ ghidra = 'install'; jdk = 'install'; want = 2300 }
        @{ ghidra = 'skip'; jdk = 'skip'; want = 200 }
    ) {
        $script:PlanGhidra = $ghidra
        $script:PlanJdk = $jdk
        Get-ReaNeededMb | Should -Be $want
    }

    It 'Invoke-ReaPlanGhidra reuses a valid -GhidraDir and writes nothing' {
        $script:Opt.GhidraDir = Join-Path $script:Fix 'fake-ghidra'
        $script:Bound = @{ GhidraDir = $script:Opt.GhidraDir }
        Invoke-ReaPlanGhidra
        $script:PlanGhidra | Should -Be 'reuse'
        $script:PlanGhidraBytes | Should -Be 0
        $script:GhidraDirSelected | Should -Be $script:Opt.GhidraDir
        @(script:Get-Listing $script:ToolsDir).Count | Should -Be 0
    }

    It 'Invoke-ReaPlanGhidra plans an install of the pinned size when nothing is valid' {
        Invoke-ReaPlanGhidra
        $script:PlanGhidra | Should -Be 'install'
        $script:PlanGhidraBytes | Should -Be ([int64]$script:PIN_GHIDRA_ZIP_BYTES)
        @(script:Get-Listing $script:ToolsDir).Count | Should -Be 0
    }

    It 'Invoke-ReaPlanGhidra stops with 1 on an invalid -GhidraDir, before any question' {
        $script:Opt.GhidraDir = Join-Path $script:T 'nothing here'
        $script:Bound = @{ GhidraDir = $script:Opt.GhidraDir }
        script:Get-Code { Invoke-ReaPlanGhidra } | Should -Be 1
    }

    It 'Invoke-ReaPlanJdk reuses a valid -JavaHome' {
        Mock Test-ReaJdkValid { [pscustomobject]@{ Valid = $true; Reason = '' } }
        $script:Opt.JavaHome = Join-Path $script:T 'a jdk'
        $script:Bound = @{ JavaHome = $script:Opt.JavaHome }
        Invoke-ReaPlanJdk
        $script:PlanJdk | Should -Be 'reuse'
        $script:PlanJdkBytes | Should -Be 0
        $script:JavaHomeSelected | Should -Be $script:Opt.JavaHome
    }

    It 'Invoke-ReaPlanJdk plans an install with the size of the listing and keeps the resolution' {
        Mock Resolve-ReaJdkRelease { [pscustomobject]@{ Release = 'jdk-21.0.13+9'; Url = 'https://github.com/x'; Sha256 = ('0' * 64); SidecarUrl = ''; Bytes = '12345678' } }
        Invoke-ReaPlanJdk
        $script:PlanJdk | Should -Be 'install'
        $script:PlanJdkBytes | Should -Be 12345678
        $script:JdkPlanned.Release | Should -Be 'jdk-21.0.13+9'
        @(script:Get-Listing $script:ToolsDir).Count | Should -Be 0
    }

    It 'Invoke-ReaPlanJdk uses the estimate when the listing gave no size' {
        Mock Resolve-ReaJdkRelease { [pscustomobject]@{ Release = 'jdk-21.0.13+9'; Url = 'https://github.com/x'; Sha256 = ('0' * 64); SidecarUrl = ''; Bytes = '' } }
        Invoke-ReaPlanJdk
        $script:PlanJdkBytes | Should -Be $script:JdkDownloadEstimateBytes
    }

    It 'Invoke-ReaPlanToolsBin: install when a tool is missing, update when one is behind, else reuse' {
        Mock Resolve-ReaAgentProfile { [pscustomobject]@{ Version = '1.0.0' } }
        Mock Resolve-ReaClavityRelease { [pscustomobject]@{ Version = '2.0.0' } }
        $script:Have = @{ 'agent-profile' = ''; 'clavity-ls' = '2.0.0' }
        Mock Get-ReaInstalledVersion { $script:Have[$Name] }
        Invoke-ReaPlanToolsBin
        $script:PlanToolsBin | Should -Be 'install'
        $script:PlanToolsBinText | Should -Match 'agent-profile 1\.0\.0 \(install\), clavity-ls 2\.0\.0 \(reuse\)'
        $script:Have = @{ 'agent-profile' = '1.0.0'; 'clavity-ls' = '1.9.0' }
        Invoke-ReaPlanToolsBin
        $script:PlanToolsBin | Should -Be 'update'
        $script:Have = @{ 'agent-profile' = '1.0.0'; 'clavity-ls' = '2.0.0' }
        Invoke-ReaPlanToolsBin
        $script:PlanToolsBin | Should -Be 'reuse'
        $script:ToolsBinPlanned.Clavity.Version | Should -Be '2.0.0'
    }

    It 'the plan functions do nothing under -CheckUpstream' {
        $script:Opt.CheckUpstream = $true
        Mock Resolve-ReaAgentProfile { throw 'must not be called' }
        Invoke-ReaPlanToolsBin
        Invoke-ReaPlanJdk
        Invoke-ReaPlanGhidra
        $script:PlanToolsBin | Should -Be ''
        $script:PlanJdk | Should -Be ''
        $script:PlanGhidra | Should -Be ''
    }
}

Describe 'the disclosures and the plan summary' {
    BeforeEach {
        script:Reset-State
        $script:Lines = New-Object System.Collections.Generic.List[string]
        Mock Write-ReaNotice { $script:Lines.Add($Text) }
    }

    It 'Write-ReaDisclosure prints the four items with the computed total' {
        $script:PlanGhidraBytes = [int64]569649598
        $script:PlanJdkBytes = [int64]218103808
        Write-ReaDisclosure
        $text = $script:Lines -join "`n"
        $text | Should -Match 'Download: 751\.3 MB in total \(Ghidra 543\.3 MB, JDK 208\.0 MB\)'
        $text | Should -Match ([regex]::Escape("unpacked under $script:ToolsDir"))
        $text | Should -Match ([regex]::Escape('clavity-ls start always runs agy with --dangerously-skip-permissions, and agy is not isolated by the profile (it shares ~/.gemini/antigravity-cli/)'))
        $text | Should -Match ([regex]::Escape('--install-hopper may ask for administrator rights and installs commercial demo software'))
        $text | Should -Match ([regex]::Escape('npx -y rea-agents@latest downloads and runs the newest published npm package with your rights'))
        @($script:Lines | Where-Object { $_ -match '^  [1-4]\. ' }).Count | Should -Be 4
    }

    It 'Write-ReaDisclosure says so when nothing is pending' {
        Write-ReaDisclosure
        ($script:Lines -join "`n") | Should -Match 'Download: nothing for Ghidra and the JDK'
    }

    It 'Show-ReaPlanSummary prints one line per step' {
        $script:PlanToolsBin = 'update'
        $script:PlanToolsBinText = 'clavity-ls 1.0.0 (update)'
        $script:PlanJdk = 'install'
        $script:PlanJdkText = 'jdk-21.0.13+9 into x'
        $script:PlanJdkBytes = [int64]218103808
        $script:PlanGhidra = 'reuse'
        $script:PlanGhidraText = 'C:\g'
        Show-ReaPlanSummary
        @($script:Lines | Where-Object { $_ -match '^  [a-z-]+: ' }).Count | Should -Be 7
        ($script:Lines -join "`n") | Should -Match 'tools-bin: +would update clavity-ls'
        ($script:Lines -join "`n") | Should -Match 'jdk: +would install jdk-21\.0\.13\+9 into x \(208\.0 MB\)'
        ($script:Lines -join "`n") | Should -Match 'ghidra: +would reuse '
        $script:PlanGhidra = 'skip'
        $script:Lines.Clear()
        Show-ReaPlanSummary
        ($script:Lines -join "`n") | Should -Match 'ghidra: +skip '
        $script:Opt.NoLaunch = $true
        $script:Lines.Clear()
        Show-ReaPlanSummary
        ($script:Lines -join "`n") | Should -Match 'launch: +skip \(-NoLaunch\)'
    }
}

Describe 'Invoke-ReaPlanConfirm' {
    BeforeEach {
        script:Reset-State
        $script:Notices = New-Object System.Collections.Generic.List[string]
        $script:Out = New-Object System.Collections.Generic.List[string]
        Mock Write-ReaNotice { $script:Notices.Add($Text) }
        Mock Write-ReaOutput { $script:Out.Add($Text) }
        Mock Get-ReaFreeMb { 100000 }
        $script:PlanGhidra = 'install'
        $script:PlanJdk = 'install'
        $script:PlanGhidraBytes = [int64]569649598
        $script:PlanJdkBytes = [int64]218103808
    }

    It 'declined: false, nothing changed on stdout, disclosures and plan shown first' {
        Mock Read-ReaConfirm { $false }
        Invoke-ReaPlanConfirm | Should -BeFalse
        ($script:Out -join '|') | Should -Be 'nothing changed'
        ($script:Notices -join "`n") | Should -Match 'Download: '
        ($script:Notices -join "`n") | Should -Match 'Plan:'
        Should -Invoke Read-ReaConfirm -Times 1 -ParameterFilter { $Prompt -eq 'Proceed?' }
    }

    It 'accepted: true and nothing on stdout' {
        Mock Read-ReaConfirm { $true }
        Invoke-ReaPlanConfirm | Should -BeTrue
        $script:Out.Count | Should -Be 0
    }

    It 'no terminal and no -Yes: exit 2, no nothing-changed claim' {
        Mock Test-ReaInteractive { $false }
        script:Get-Code { Invoke-ReaPlanConfirm } | Should -Be 2
        $script:Out.Count | Should -Be 0
    }

    It '-Yes: no question, the disclosures are still printed' {
        $script:OptYes = $true
        Mock Test-ReaInteractive { $false }
        Invoke-ReaPlanConfirm | Should -BeTrue
        ($script:Notices -join "`n") | Should -Match 'Download: '
    }

    It 'a dry run prints the plan and never asks' {
        $script:Opt.DryRun = $true
        Mock Read-ReaConfirm { throw 'must not ask' }
        Invoke-ReaPlanConfirm | Should -BeTrue
        ($script:Notices -join "`n") | Should -Match 'Plan:'
    }

    It '-CheckUpstream: no prompt, no output' {
        $script:Opt.CheckUpstream = $true
        Mock Read-ReaConfirm { throw 'must not ask' }
        Invoke-ReaPlanConfirm | Should -BeTrue
        $script:Notices.Count | Should -Be 0
    }

    It 'low disk: one check for the sum, exit 1 with the shortfall, nothing shown before it' {
        Mock Get-ReaFreeMb { 1000 }
        Mock Read-ReaConfirm { $true }
        script:Get-Code { Invoke-ReaPlanConfirm } | Should -Be 1
        $script:Notices.Count | Should -Be 0
        Should -Invoke Get-ReaFreeMb -Times 1 -Exactly
        $script:Msg = ''
        try { Invoke-ReaPlanConfirm } catch { $script:Msg = $_.Exception.Message }
        $script:Msg | Should -Match 'need 2300 MB, have 1000 MB \(short by 1300 MB\)'
    }

    It 'low disk does not matter when nothing is pending (needs 200)' {
        Mock Get-ReaFreeMb { 1000 }
        Mock Read-ReaConfirm { $true }
        $script:PlanGhidra = 'reuse'
        $script:PlanJdk = 'reuse'
        Invoke-ReaPlanConfirm | Should -BeTrue
    }
}

Describe 'the summary' {
    BeforeEach {
        script:Reset-State
        $script:Out = New-Object System.Collections.Generic.List[string]
        Mock Write-ReaOutput { $script:Out.Add($Text) }
    }

    It 'names what was done, where, and what to do next' {
        $script:Summary['profile'] = 'created rea: C:\p\claude'
        $script:Summary['tools_bin'] = "agent-profile 1.0.0: install`r`nclavity-ls 1.0.0: skip (already latest)"
        $script:Summary['jdk'] = 'jdk-21.0.13+9 installed: C:\j'
        $script:Summary['ghidra'] = '12.1.4 installed: C:\g'
        $script:Summary['rea_setup'] = 'registered rea in C:\p\claude'
        $script:Summary['rea_doctor'] = 'ok: ghidra 12.1.4'
        $script:LogFile = 'C:\some log\file.log'
        $script:EnvFile = Join-Path $script:ToolsDir 'env.ps1'
        Write-ReaSummary
        $text = $script:Out -join "`n"
        $text | Should -Match 'Setup summary'
        $text | Should -Match 'profile: +created rea: C:\\p\\claude'
        $text | Should -Match 'agent-profile 1\.0\.0: install'
        $text | Should -Match 'clavity-ls 1\.0\.0: skip'
        $text | Should -Match 'jdk: +jdk-21\.0\.13\+9 installed'
        $text | Should -Match 'ghidra: +12\.1\.4 installed'
        $text | Should -Match 'rea doctor: +ok: ghidra 12\.1\.4'
        $text | Should -Match ([regex]::Escape('log file:    C:\some log\file.log'))
        $text | Should -Match 'env file: +.*env\.ps1'
        $text | Should -Match ([regex]::Escape("clavity-ls start `"$($script:Opt.Folder)`" --profile rea"))
    }

    It 'says when no env file was written' {
        Write-ReaSummary
        ($script:Out -join "`n") | Should -Match 'env file: +not written'
    }
}

Describe 'Invoke-ReaStepLaunch' {
    BeforeEach {
        script:Reset-State
        $script:Out = New-Object System.Collections.Generic.List[string]
        Mock Write-ReaOutput { $script:Out.Add($Text) }
        Mock Resolve-ReaExecutable { 'C:\bin\clavity-ls.exe' }
        $script:Run = [pscustomobject]@{ ExitCode = 0; Seconds = 1.0 }
        Mock Start-ReaLaunchProcess { $script:Called = @{ File = $FilePath; Args = $ArgumentList; Env = $Environment }; return $script:Run }
        $script:Called = $null
    }

    It '-NoLaunch prints the command, returns 0 and starts nothing' {
        $script:Opt.NoLaunch = $true
        Invoke-ReaStepLaunch | Should -Be 0
        ($script:Out -join '|') | Should -Be ('launch skipped (-NoLaunch); run: clavity-ls start "{0}" --profile rea' -f $script:Opt.Folder)
        Should -Invoke Start-ReaLaunchProcess -Times 0
    }

    It 'runs clavity-ls start <folder> --profile <name> with the three variables, one argument each' {
        Invoke-ReaStepLaunch | Should -Be 0
        $script:Called.File | Should -Be 'C:\bin\clavity-ls.exe'
        ($script:Called.Args -join '|') | Should -Be ('start|{0}|--profile|rea' -f $script:Opt.Folder)
        $script:Called.Env['GHIDRA_INSTALL_DIR'] | Should -Be $script:GhidraDirSelected
        $script:Called.Env['JAVA_HOME'] | Should -Be $script:JavaHomeSelected
        $script:Called.Env['PATH'] | Should -Match ('^' + [regex]::Escape($script:BinDir))
        $script:Called.Env.ContainsKey('CLAUDE_CONFIG_DIR') | Should -BeFalse
        $script:Out.Count | Should -Be 0
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'launch exited 0'
    }

    It 'returns clavity-ls exit code unchanged and logs it' {
        $script:Run = [pscustomobject]@{ ExitCode = 7; Seconds = 1.0 }
        Invoke-ReaStepLaunch | Should -Be 7
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'launch exited 7'
        ($script:Out -join '|') | Should -Not -Match 'Terminal 1'
    }

    It 'a quick exit 1 keeps 1 and prints the two-terminal flow with the soft wording' {
        $script:Run = [pscustomobject]@{ ExitCode = 1; Seconds = 2.5 }
        Invoke-ReaStepLaunch | Should -Be 1
        $text = $script:Out -join "`n"
        $script:Out[0] | Should -Match '^If the message above says clavity-ls could not open a terminal, use two terminals:'
        $text | Should -Match ([regex]::Escape("clavity-ls agy `"$($script:Opt.Folder)`""))
        $text | Should -Match ([regex]::Escape("clavity-ls start `"$($script:Opt.Folder)`" --attach --profile rea"))
        $text | Should -Match 'hint that clavity-ls agy prints omits --profile'
        @($script:Out | Where-Object { $_ -match [regex]::Escape((Join-Path $script:ToolsDir 'env.ps1')) }).Count | Should -Be 2
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'launch exited 1'
    }

    It 'exit 1 after the threshold (a real session that ended with 1) prints no instructions' {
        $script:Run = [pscustomobject]@{ ExitCode = 1; Seconds = 3600 }
        Invoke-ReaStepLaunch | Should -Be 1
        $script:Out.Count | Should -Be 0
        $script:LaunchShortSeconds = 5000
        $script:Run = [pscustomobject]@{ ExitCode = 1; Seconds = 3600 }
        try { Invoke-ReaStepLaunch | Should -Be 1 } finally { $script:LaunchShortSeconds = 10 }
        ($script:Out -join "`n") | Should -Match 'Terminal 1'
    }

    It 'a quick exit 2 or 7 prints no instructions and keeps the code' {
        $script:Run = [pscustomobject]@{ ExitCode = 2; Seconds = 1 }
        Invoke-ReaStepLaunch | Should -Be 2
        $script:Run = [pscustomobject]@{ ExitCode = 7; Seconds = 1 }
        Invoke-ReaStepLaunch | Should -Be 7
        $script:Out.Count | Should -Be 0
    }

    It 'a dry run logs would and starts nothing' {
        $script:Opt.DryRun = $true
        Invoke-ReaStepLaunch | Should -Be 0
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'would run: clavity-ls start'
        Should -Invoke Start-ReaLaunchProcess -Times 0
    }

    It '-CheckUpstream returns 0 without launching' {
        $script:Opt.CheckUpstream = $true
        Invoke-ReaStepLaunch | Should -Be 0
        Should -Invoke Start-ReaLaunchProcess -Times 0
    }

    It 'stops with 1 when clavity-ls is not on PATH' {
        Mock Resolve-ReaExecutable { $null }
        script:Get-Code { Invoke-ReaStepLaunch } | Should -Be 1
    }
}

Describe 'Start-ReaLaunchProcess with the clavity-ls stub' -Skip:$script:OnWindows {
    BeforeEach {
        script:Reset-State
        $script:StubDir = Join-Path $script:T 'stub bin'
        New-Item -ItemType Directory -Path $script:StubDir -Force | Out-Null
        if (-not (Test-Path -LiteralPath (Join-Path $script:StubDir 'clavity-ls'))) {
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:StubDir 'clavity-ls') -Target (Join-Path $script:Fix 'bin/clavity-ls') | Out-Null
        }
        $script:SavedPath = $env:PATH
        $env:PATH = $script:StubDir + [System.IO.Path]::PathSeparator + $script:SavedPath
        $script:Rec = Join-Path $script:T 'stub.rec'
        Remove-Item -LiteralPath $script:Rec -Force -ErrorAction SilentlyContinue
        $env:STUB_CL_LOG = $script:Rec
        Mock Write-ReaOutput { }
    }
    AfterEach {
        $env:PATH = $script:SavedPath
        $env:STUB_CL_LOG = $null
        $env:STUB_CL_EXIT = $null
        $env:STUB_CL_STDERR = $null
        $env:STUB_CL_BG = $null
    }

    It 'runs the stub with the arguments and the environment, the child only' {
        Invoke-ReaStepLaunch | Should -Be 0
        $rec = [System.IO.File]::ReadAllText($script:Rec)
        $rec | Should -Match ([regex]::Escape("arg: start`n"))
        $rec | Should -Match ([regex]::Escape("arg: $($script:Opt.Folder)`n"))
        $rec | Should -Match ([regex]::Escape("arg: --profile`narg: rea`n"))
        $rec | Should -Match ([regex]::Escape("env GHIDRA_INSTALL_DIR=$($script:GhidraDirSelected)`n"))
        $rec | Should -Match ([regex]::Escape("env JAVA_HOME=$($script:JavaHomeSelected)`n"))
        $rec | Should -Match ([regex]::Escape("path-head: $($script:BinDir)`n"))
        $env:GHIDRA_INSTALL_DIR | Should -BeNullOrEmpty
        $env:JAVA_HOME | Should -BeNullOrEmpty
    }

    It 'returns the stub exit code' {
        $env:STUB_CL_EXIT = '7'
        Invoke-ReaStepLaunch | Should -Be 7
    }

    It 'a quick exit 1 prints the instructions and keeps 1' {
        $env:STUB_CL_EXIT = '1'
        Invoke-ReaStepLaunch | Should -Be 1
        Should -Invoke Write-ReaOutput -ParameterFilter { $Text -match 'attach --profile rea' }
    }

    It 'a descendant that keeps the console open does not delay the return' {
        $env:STUB_CL_BG = '4'
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Invoke-ReaStepLaunch | Should -Be 0
            $watch.Stop()
        } finally { $env:STUB_CL_BG = $null }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 2
    }

    It 'the child has this process''s stdin, stdout and stderr (nothing is redirected)' -Skip:(-not (Test-Path '/proc/self/fd/0')) {
        Invoke-ReaStepLaunch | Should -Be 0
        $rec = [System.IO.File]::ReadAllText($script:Rec)
        foreach ($n in 0, 1, 2) {
            $mine = (Get-Item -LiteralPath "/proc/$PID/fd/$n").Target
            $rec | Should -Match ([regex]::Escape("fd${n}: $mine") + '\r?\n')
        }
    }
}

Describe 'the dry run end to end' {
    BeforeAll {
        script:Reset-State
        $script:State = Join-Path $script:T 'e2e state'
        $script:ToolsDir = Join-Path $script:State 'xdg data/rea-tools'
        $script:BinDir = Join-Path $script:State 'home dir/bin'
        $script:Logs = Join-Path $script:T 'e2e logs'
        New-Item -ItemType Directory -Path $script:State | Out-Null
        $script:Opt.DryRun = $true
        $script:Opt.LogDir = $script:Logs
        $script:Opt.Quiet = $true
        $script:Out = New-Object System.Collections.Generic.List[string]
        $script:Notices = New-Object System.Collections.Generic.List[string]
        Mock Write-ReaOutput { $script:Out.Add($Text) }
        Mock Write-ReaNotice { $script:Notices.Add($Text) }
        Mock Invoke-ReaStepPreflight { $script:Summary['preflight'] = 'ok' }
        Mock Invoke-ReaStepPrereq { $script:Summary['prereq'] = 'ok' }
        Mock Invoke-ReaStepProfile { $script:Summary['profile'] = 'would use x (not created: read-only run)' }
        Mock Resolve-ReaExecutable { $null }
        Mock Get-ReaFreeMb { 100000 }
        Mock Resolve-ReaAgentProfile { [pscustomobject]@{ Tag = 'v1.0.0'; Version = '1.0.0'; Asset = 'a.zip'; Url = 'https://github.com/x/a.zip'; SidecarUrl = 'https://github.com/x/a.zip.sha256' } }
        Mock Resolve-ReaClavityRelease { [pscustomobject]@{ Tag = 'v2'; Version = '2.0.0'; Asset = 'c.tar.gz'; Url = 'https://github.com/x/c.tar.gz'; SidecarUrl = 'https://github.com/x/c.tar.gz.sha256' } }
        Mock Resolve-ReaJdkRelease { [pscustomobject]@{ Release = 'jdk-21.0.13+9'; Url = 'https://github.com/adoptium/x.zip'; Sha256 = ('0' * 64); SidecarUrl = ''; Bytes = '218103808' } }
        Mock Get-ReaDownload { throw 'a dry run must not download' }
        Mock Invoke-ReaHttpGet { throw 'a dry run must not download' }
        $script:Before = @(script:Get-Listing $script:State)
        $script:Code = Invoke-Main
    }

    It 'exits 0' {
        $script:Code | Should -Be 0
    }

    It 'writes nothing on the machine but the log' {
        @(script:Get-Listing $script:State) | Should -Be $script:Before
        @(Get-ChildItem -LiteralPath $script:Logs -Filter 'setup-*.log').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:State -Recurse -Force -Filter 'env.*').Count | Should -Be 0
    }

    It 'prints the disclosures and the plan with would install, and the summary on stdout' {
        ($script:Notices -join "`n") | Should -Match 'Download: 751\.3 MB in total'
        ($script:Notices -join "`n") | Should -Match 'jdk: +would install jdk-21\.0\.13\+9'
        ($script:Notices -join "`n") | Should -Match 'ghidra: +would install Ghidra 12\.1\.4'
        ($script:Notices -join "`n") | Should -Match 'tools-bin: +would install agent-profile 1\.0\.0 \(install\), clavity-ls 2\.0\.0 \(install\)'
        ($script:Out -join "`n") | Should -Match 'Dry run: nothing was changed'
        ($script:Out -join "`n") | Should -Match 'env file: +not written'
    }

    It 'logs would for the launch and the env file' {
        $log = [System.IO.File]::ReadAllText((Get-ChildItem -LiteralPath $script:Logs -Filter 'setup-*.log').FullName)
        $log | Should -Match 'would write .*env\.ps1'
        $log | Should -Match 'would run: clavity-ls start'
    }
}
