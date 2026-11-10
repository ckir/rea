# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.ps1 step jdk; they mirror tests/sh/jdk.sh. java is replaced by $script:JavaRunner, which
# answers from the files next to bin\ exactly as the stub of tests/fixtures/fake-jdk does (banner, arch, stream,
# fail), so the cases run on Linux pwsh too. The network is replaced at the seams of the tools-bin tests (the
# Adoptium resolve, the redirect walk and the HTTP GET, which copies a prepared file), so Get-ReaDownload, the
# checksum, the archive checks, the extraction and the commit all run for real, on real zip and tar.gz archives.
# Every directory has a space in its name.

BeforeDiscovery {
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
}

BeforeAll {
    # BeforeDiscovery variables are empty in the run phase, so the run-phase reads need their own copy
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
    $env:REA_SETUP_NO_MAIN = '1'
    . (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('rea jdk work ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:T | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:Rel = 'jdk-21.0.13+9'
    $script:Ban21 = "openjdk version `"21.0.13`" 2026-10-21 LTS`nOpenJDK Runtime Environment (build 21.0.13+9-LTS)`nOpenJDK 64-Bit Server VM (build 21.0.13+9-LTS, mixed mode)`n"
    $script:Ban17 = "openjdk version `"17.0.2`" 2022-01-18`nOpenJDK 64-Bit Server VM (build 17.0.2+8, mixed mode)`n"

    function script:Get-Code {
        param([scriptblock]$Block)
        try { & $Block } catch { return $_.Exception.Data['ReaCode'] }
        return 0
    }
    # A fake JDK at Dir: empty java and javac; Banner (default: a 21.0.13 64-bit banner) and Arch go in files the
    # runner reads. -NoJavac makes it a JRE.
    function script:New-FakeJdk {
        param([string]$Dir, [string]$Banner = '', [string]$Arch = '', [switch]$NoJavac, [switch]$Stdout, [switch]$Fail)
        $bin = Join-Path $Dir 'bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $bin (Get-ReaJdkExe 'java')), 'java')
        if (-not $NoJavac) { [System.IO.File]::WriteAllText((Join-Path $bin (Get-ReaJdkExe 'javac')), 'javac') }
        if ($Banner) { [System.IO.File]::WriteAllText((Join-Path $Dir 'banner'), $Banner) }
        if ($Arch) { [System.IO.File]::WriteAllText((Join-Path $Dir 'arch'), $Arch) }
        if ($Stdout) { [System.IO.File]::WriteAllText((Join-Path $Dir 'stream'), 'out') }
        if ($Fail) { [System.IO.File]::WriteAllText((Join-Path $Dir 'fail'), 'x') }
    }
    $script:Runner = {
        param($Path, $Arguments)
        $home_ = Split-Path -Parent (Split-Path -Parent $Path)
        if (Test-Path -LiteralPath (Join-Path $home_ 'fail')) { return [pscustomobject]@{ ExitCode = 1; Stdout = ''; Stderr = '' } }
        $arch = 'amd64'
        if (Test-Path -LiteralPath (Join-Path $home_ 'arch')) { $arch = [System.IO.File]::ReadAllText((Join-Path $home_ 'arch')).Trim() }
        $text = "Property settings:`n    os.arch = $arch`n    os.name = Linux`n"
        if ($Arguments -notcontains '-XshowSettings:properties') { $text = '' }
        if (Test-Path -LiteralPath (Join-Path $home_ 'banner')) {
            $text += [System.IO.File]::ReadAllText((Join-Path $home_ 'banner'))
        } else {
            $text += $script:Ban21
        }
        if (Test-Path -LiteralPath (Join-Path $home_ 'stream')) { return [pscustomobject]@{ ExitCode = 0; Stdout = $text; Stderr = '' } }
        return [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = $text }
    }
    # Packs Src's entries into Out: a .zip with ZipFile, anything else a tar.gz with tar.
    function script:New-Pack {
        param([string]$Src, [string]$Out)
        if ($Out.EndsWith('.zip')) {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($Src, $Out)
        } else {
            $names = @(Get-ChildItem -LiteralPath $Src -Force | ForEach-Object { $_.Name })
            & (Get-ReaTarExe) -czf $Out -C $Src @names
            if ($LASTEXITCODE -ne 0) { throw "tar failed for $Out" }
        }
    }
    # A JDK archive named Name under Dir. Layout: normal, mac (Contents/Home), two (a second top directory),
    # badname (jdk-21.0.99+1) or j17 (a JDK 17).
    function script:New-JdkArchive {
        param([string]$Dir, [string]$Name, [string]$Layout = 'normal')
        $src = Join-Path $Dir ('src ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $src | Out-Null
        $top = $script:Rel
        if ($Layout -eq 'badname') { $top = 'jdk-21.0.99+1' }
        $homeDir = Join-Path $src $top
        if ($Layout -eq 'mac') { $homeDir = Join-Path (Join-Path $homeDir 'Contents') 'Home' }
        $banner = ''
        if ($Layout -eq 'j17') { $banner = $script:Ban17 }
        New-FakeJdk -Dir $homeDir -Banner $banner
        if ($Layout -eq 'two') {
            New-Item -ItemType Directory -Path (Join-Path $src 'jdk-notes') | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $src 'jdk-notes/readme'), 'x')
        }
        $out = Join-Path $Dir $Name
        New-Pack -Src $src -Out $out
        return $out
    }
    function script:Set-Sidecar {
        param([string]$Path, [string]$Hash, [string]$Name)
        [System.IO.File]::WriteAllText($Path, "$Hash  $Name`n")
    }
    function script:Get-ListingName {
        param([string]$Dir)
        if (-not (Test-Path -LiteralPath $Dir)) { return @() }
        return @(Get-ChildItem -LiteralPath $Dir -Force | ForEach-Object { $_.Name })
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'jdk' {
    BeforeEach {
        $script:Case = Join-Path $script:T ('case ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case | Out-Null
        $script:ToolsDir = Join-Path $script:Case 'tools dir'
        $script:LogFile = Join-Path $script:Case 'run.log'
        $script:ConsoleLevel = 'ERROR'
        $script:Summary = @{}
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:JavaRunner = $script:Runner
        $script:JavaHomeSelected = ''
        $script:Served = @{}
        $script:SavedBound = $script:Bound
        $script:SavedJavaHome = $script:Opt.JavaHome
        $script:SavedEnvJavaHome = $env:JAVA_HOME
        Remove-Item Env:\JAVA_HOME -ErrorAction SilentlyContinue
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
        Mock Resolve-ReaRedirect { return [pscustomobject]@{ Code = 0; Url = $Url } }
        Mock Invoke-ReaHttpGet {
            if (-not $script:Served.ContainsKey($Url)) { return $false }
            Copy-Item -LiteralPath $script:Served[$Url] -Destination $Destination
            return $true
        }
    }
    AfterEach {
        $script:Bound = $script:SavedBound
        $script:Opt.JavaHome = $script:SavedJavaHome
        if ($script:SavedEnvJavaHome) { $env:JAVA_HOME = $script:SavedEnvJavaHome } else { Remove-Item Env:\JAVA_HOME -ErrorAction SilentlyContinue }
        $script:LogFile = $null
        $script:JavaRunner = $null
        $script:Opt.DryRun = $false
        foreach ($d in @($script:LockHeld)) { Unlock-ReaDir -Dir $d }
        Clear-ReaTempFile
    }

    Context 'Test-ReaJdkValid' {
        It 'accepts 21.0.13, 64-bit, amd64 on x64' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j 21')
            $r = Test-ReaJdkValid -Dir (Join-Path $script:Case 'j 21') -Arch x64
            $r.Valid | Should -BeTrue
            $r.Reason | Should -Be ''
        }
        It 'refuses 17 with the reason' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j 17') -Banner $script:Ban17
            $r = Test-ReaJdkValid -Dir (Join-Path $script:Case 'j 17') -Arch x64
            $r.Valid | Should -BeFalse
            $r.Reason | Should -Be 'major 17 < 21'
        }
        It 'refuses a 32-bit banner' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j 32') -Banner "openjdk version `"21`"`nOpenJDK Client VM (build 21+35, mixed mode)`nOpenJDK 32-Bit Server VM`n"
            $r = Test-ReaJdkValid -Dir (Join-Path $script:Case 'j 32') -Arch x64
            $r.Valid | Should -BeFalse
            $r.Reason | Should -Match '64-bit'
        }
        It 'refuses a JRE (no javac)' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j jre') -NoJavac
            $r = Test-ReaJdkValid -Dir (Join-Path $script:Case 'j jre') -Arch x64
            $r.Valid | Should -BeFalse
            $r.Reason | Should -Match 'javac.*JRE'
        }
        It 'refuses a missing java and a missing directory' {
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'nope') -Arch x64).Valid | Should -BeFalse
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'nope') -Arch x64).Reason | Should -Match 'no bin/'
        }
        It 'reads 1.8.0_392 as major 8 and refuses it' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j 8') -Banner "java version `"1.8.0_392`"`nJava HotSpot(TM) 64-Bit Server VM (build 25.392-b08, mixed mode)`n"
            $r = Test-ReaJdkValid -Dir (Join-Path $script:Case 'j 8') -Arch x64
            $r.Valid | Should -BeFalse
            $r.Reason | Should -Be 'major 8 < 21'
        }
        It 'accepts a version without dots, a later major, CRLF output and a banner on stdout' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j bare') -Banner "openjdk version `"21`"`nOpenJDK 64-Bit Server VM (build 21+35)`n"
            New-FakeJdk -Dir (Join-Path $script:Case 'j 22') -Banner "openjdk version `"22.0.1`" 2024-04-16`nOpenJDK 64-Bit Server VM`n"
            New-FakeJdk -Dir (Join-Path $script:Case 'j crlf') -Banner "openjdk version `"21.0.13`" 2026-10-21 LTS`r`nOpenJDK 64-Bit Server VM (build 21.0.13+9-LTS)`r`n" -Arch "amd64`r`n"
            New-FakeJdk -Dir (Join-Path $script:Case 'j out') -Stdout
            foreach ($n in @('j bare', 'j 22', 'j crlf', 'j out')) {
                (Test-ReaJdkValid -Dir (Join-Path $script:Case $n) -Arch x64).Valid | Should -BeTrue -Because $n
            }
        }
        It 'refuses output without a version and a failing java' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j nover') -Banner "something odd`n"
            New-FakeJdk -Dir (Join-Path $script:Case 'j fail') -Fail
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'j nover') -Arch x64).Reason | Should -Match 'cannot read the version'
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'j fail') -Arch x64).Valid | Should -BeFalse
        }
        It 'maps the architecture names' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j x86') -Arch 'x86_64'
            New-FakeJdk -Dir (Join-Path $script:Case 'j arm') -Arch 'aarch64'
            New-FakeJdk -Dir (Join-Path $script:Case 'j arm64') -Arch 'arm64'
            New-FakeJdk -Dir (Join-Path $script:Case 'j 386') -Arch 'x86'
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'j x86') -Arch x64).Valid | Should -BeTrue
            $r = Test-ReaJdkValid -Dir (Join-Path $script:Case 'j arm') -Arch x64
            $r.Valid | Should -BeFalse
            $r.Reason | Should -Be 'architecture aarch64 does not match this host (x64)'
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'j arm') -Arch aarch64).Valid | Should -BeTrue
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'j arm64') -Arch aarch64).Valid | Should -BeTrue
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'j x86') -Arch aarch64).Valid | Should -BeFalse
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'j 386') -Arch x64).Valid | Should -BeFalse
        }
        It 'takes the host architecture from Get-ReaPlatform by default' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j arm') -Arch 'aarch64'
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'j arm')).Valid | Should -BeFalse
            Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'aarch64' } }
            (Test-ReaJdkValid -Dir (Join-Path $script:Case 'j arm')).Valid | Should -BeTrue
        }
        It 'runs the real stub of tests/fixtures/fake-jdk through the default runner' -Skip:$script:OnWindows {
            $script:JavaRunner = $null
            $fake = Join-Path $script:Root 'tests/fixtures/fake-jdk'
            (Test-ReaJdkValid -Dir $fake -Arch x64).Valid | Should -BeTrue
            (Test-ReaJdkValid -Dir $fake -Arch aarch64).Reason | Should -Match 'does not match this host'
        }
    }

    Context 'Get-ReaJdkHomeCandidate' {
        It 'returns Contents\Home only on macOS and only when it exists' {
            $mac = Join-Path $script:Case 'h mac'
            New-Item -ItemType Directory -Path (Join-Path (Join-Path $mac 'Contents') 'Home') -Force | Out-Null
            $plain = Join-Path $script:Case 'h plain'
            New-Item -ItemType Directory -Path $plain | Out-Null
            Get-ReaJdkHomeCandidate -Dir $plain | Should -Be $plain
            Get-ReaJdkHomeCandidate -Dir $mac | Should -Be $mac
            Get-ReaJdkHomeCandidate -Dir $mac -Os mac | Should -Be (Join-Path (Join-Path $mac 'Contents') 'Home')
            Get-ReaJdkHomeCandidate -Dir $plain -Os mac | Should -Be $plain
        }
    }

    Context 'Get-ReaJdkFallback' {
        It 'returns the right pin for each platform' {
            $pins = @{
                'linux-x64'   = $script:PIN_JDK_FALLBACK_LINUX_X64
                'mac-x64'     = $script:PIN_JDK_FALLBACK_MAC_X64
                'mac-aarch64' = $script:PIN_JDK_FALLBACK_MAC_AARCH64
                'windows-x64' = $script:PIN_JDK_FALLBACK_WINDOWS_X64
            }
            foreach ($k in $pins.Keys) {
                $os, $arch = $k -split '-'
                $name, $sha = $pins[$k] -split ':'
                $f = Get-ReaJdkFallback -Os $os -Arch $arch
                $f.Release | Should -Be 'jdk-21.0.13+9'
                $f.Url | Should -Be ($script:PIN_JDK_FALLBACK_URL_BASE + $name) -Because $k
                $f.Sha256 | Should -Be $sha -Because $k
                $f.SidecarUrl | Should -Be ($script:PIN_JDK_FALLBACK_URL_BASE + $name + '.sha256.txt')
            }
            Get-ReaJdkFallback -Os linux -Arch aarch64 | Should -BeNullOrEmpty
        }
    }

    Context 'Select-ReaJdk precedence' {
        It 'dies with 1 when -JavaHome is a JRE, and says why' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j jre') -NoJavac
            Get-Code { Select-ReaJdk -FlagHome (Join-Path $script:Case 'j jre') -EnvHome '' } | Should -Be 1
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'not a usable JDK: no bin/.*javac.*JRE'
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'dies with 1 when -JavaHome is a JDK 17' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j 17') -Banner $script:Ban17
            Get-Code { Select-ReaJdk -FlagHome (Join-Path $script:Case 'j 17') -EnvHome '' } | Should -Be 1
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'major 17 < 21'
        }
        It 'uses a valid -JavaHome' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j 21')
            Select-ReaJdk -FlagHome (Join-Path $script:Case 'j 21') -EnvHome ''
            $script:JavaHomeSelected | Should -Be (Join-Path $script:Case 'j 21')
            $script:Summary['jdk'] | Should -Match 'reused -JavaHome'
        }
        It 'warns about an invalid JAVA_HOME and uses the valid tools-dir install' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j jre') -NoJavac
            $jdk = Join-Path $script:ToolsDir 'jdk-21.0.13+9'
            New-FakeJdk -Dir $jdk
            [System.IO.File]::WriteAllText((Join-Path $jdk '.install-complete'), 'x')
            Select-ReaJdk -FlagHome '' -EnvHome (Join-Path $script:Case 'j jre')
            $script:JavaHomeSelected | Should -Be $jdk
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'WARN.*JAVA_HOME .*j jre is not a usable JDK .*JRE.*ignoring it'
            $log | Should -Match 'reusing jdk-21\.0\.13\+9'
        }
        It 'uses a valid JAVA_HOME before the tools dir, without a WARN' {
            New-FakeJdk -Dir (Join-Path $script:Case 'j 21')
            $jdk = Join-Path $script:ToolsDir 'jdk-21.0.13+9'
            New-FakeJdk -Dir $jdk
            [System.IO.File]::WriteAllText((Join-Path $jdk '.install-complete'), 'x')
            Select-ReaJdk -FlagHome '' -EnvHome (Join-Path $script:Case 'j 21')
            $script:JavaHomeSelected | Should -Be (Join-Path $script:Case 'j 21')
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Not -Match 'WARN'
        }
        It 'reads -JavaHome from the bound parameters, not from its JAVA_HOME default' {
            $script:Bound = @{}
            Get-ReaJavaHomeFlag | Should -Be ''
            $script:Bound = @{ JavaHome = 'x' }
            $script:Opt.JavaHome = 'some dir'
            Get-ReaJavaHomeFlag | Should -Be 'some dir'
        }
        It 'picks the newest valid install and skips one without the sentinel and one that is a JDK 17' {
            $a = Join-Path $script:ToolsDir 'jdk-21.0.20+1'
            New-FakeJdk -Dir $a
            [System.IO.File]::WriteAllText((Join-Path $a '.install-complete'), 'x')
            New-FakeJdk -Dir (Join-Path $script:ToolsDir 'jdk-21.0.99+1')
            $c = Join-Path $script:ToolsDir 'jdk-21.1.0+1'
            New-FakeJdk -Dir $c -Banner $script:Ban17
            [System.IO.File]::WriteAllText((Join-Path $c '.install-complete'), 'x')
            Select-ReaJdk -FlagHome '' -EnvHome ''
            $script:JavaHomeSelected | Should -Be $a
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'WARN.*ignoring the install jdk-21\.1\.0\+1: major 17 < 21'
            $log | Should -Match 'DEBUG.*ignoring jdk-21\.0\.99\+1: no \.install-complete'
        }
        It 'resolves macOS installs to Contents\Home' {
            Mock Get-ReaPlatform { return @{ Os = 'mac'; Arch = 'x64' } }
            $jdk = Join-Path $script:ToolsDir 'jdk-21.0.13+9'
            $homeDir = Join-Path (Join-Path $jdk 'Contents') 'Home'
            New-FakeJdk -Dir $homeDir
            [System.IO.File]::WriteAllText((Join-Path $jdk '.install-complete'), 'x')
            Select-ReaJdk -FlagHome '' -EnvHome ''
            $script:JavaHomeSelected | Should -Be $homeDir
        }
    }

    Context 'Assert-ReaFreeMb' {
        It 'stops with 1 and the shortfall when there is too little space' {
            Mock Get-ReaFreeMb { return 100 }
            Get-Code { Assert-ReaFreeMb -Path $script:ToolsDir -Mb 600 } | Should -Be 1
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'need 600 MB, have 100 MB \(short by 500 MB\)'
        }
        It 'passes when there is enough' {
            Mock Get-ReaFreeMb { return 5000 }
            Get-Code { Assert-ReaFreeMb -Path $script:ToolsDir -Mb 600 } | Should -Be 0
        }
    }

    Context 'Install-ReaJdk' {
        BeforeEach {
            $script:Srv = Join-Path $script:Case 'srv dir'
            New-Item -ItemType Directory -Path $script:Srv | Out-Null
            $script:Name = 'OpenJDK21U-jdk_x64_windows_hotspot_21.0.13_9.zip'
            $script:Url = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/' + $script:Name
            $script:ApiCode = 0
            $script:ApiSha = ''
            Mock Resolve-ReaAdoptium {
                if ($script:ApiCode -ne 0) { return [pscustomobject]@{ Code = $script:ApiCode; Jdk = $null } }
                return [pscustomobject]@{ Code = 0; Jdk = [pscustomobject]@{
                        Release = 'jdk-21.0.13+9'; Url = $script:Url; Sha256 = $script:ApiSha
                        SidecarUrl = $script:Url + '.sha256.txt'; Bytes = '12345'
                    }
                }
            }
        }
        # Defined in a BeforeAll, not in the Context body: a body runs at discovery, where a same-named helper of another
        # file would overwrite this one (see tests/pester/Harness.Tests.ps1).
        BeforeAll {
            # Builds the archive for Layout, serves it (and its sidecar unless Side is 'none'; Side 'bad' serves a
            # different digest) and records the digest the API will report (ApiSha, or wrong with -BadApi).
            function script:Initialize-JdkServe {
                param([string]$Layout = 'normal', [string]$Side = 'ok', [switch]$BadApi)
                $arc = New-JdkArchive -Dir $script:Srv -Name $script:Name -Layout $Layout
                $sha = Get-ReaFileSha256 $arc
                $script:ApiSha = $sha
                if ($BadApi) { $script:ApiSha = '0' * 64 }
                $script:Served[$script:Url] = $arc
                if ($Side -ne 'none') {
                    $sidePath = Join-Path $script:Srv 'side.txt'
                    $shown = $sha
                    if ($Side -eq 'bad') { $shown = '1' * 64 }
                    Set-Sidecar -Path $sidePath -Hash $shown -Name $script:Name
                    $script:Served[$script:Url + '.sha256.txt'] = $sidePath
                }
            }
        }
        It 'installs a zip: final dir, sentinel, no archive or staging left, JAVA_HOME set, size logged' {
            Initialize-JdkServe
            $home_ = Install-ReaJdk
            $final = Join-Path $script:ToolsDir 'jdk-21.0.13+9'
            $home_ | Should -Be $final
            $script:JavaHomeSelected | Should -Be $final
            Get-ListingName $script:ToolsDir | Should -Be @('jdk-21.0.13+9')
            Test-Path -LiteralPath (Join-Path $final '.install-complete') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path (Join-Path $final 'bin') (Get-ReaJdkExe 'javac')) | Should -BeTrue
            $script:Summary['jdk'] | Should -Match '^jdk-21\.0\.13\+9 installed'
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'resolved jdk-21\.0\.13\+9: https://github\.com/adoptium/temurin21-binaries/.*\.zip \(12345 bytes\)'
            $log | Should -Match 'installed jdk-21\.0\.13\+9'
        }
        It 'installs a tar.gz' {
            $script:Name = 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz'
            $script:Url = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/' + $script:Name
            Initialize-JdkServe
            Install-ReaJdk | Should -Be (Join-Path $script:ToolsDir 'jdk-21.0.13+9')
            Get-ListingName $script:ToolsDir | Should -Be @('jdk-21.0.13+9')
        }
        It 'installs the macOS layout and returns Contents\Home' {
            Mock Get-ReaPlatform { return @{ Os = 'mac'; Arch = 'x64' } }
            Initialize-JdkServe -Layout mac
            $home_ = Install-ReaJdk
            $expected = Join-Path (Join-Path (Join-Path $script:ToolsDir 'jdk-21.0.13+9') 'Contents') 'Home'
            $home_ | Should -Be $expected
            Test-Path -LiteralPath (Join-Path (Join-Path $script:ToolsDir 'jdk-21.0.13+9') '.install-complete') | Should -BeTrue
        }
        It 'goes through Select-ReaJdk and Invoke-ReaStepJdk, and a second run reuses the install' {
            Initialize-JdkServe
            Invoke-ReaStepJdk
            $script:JavaHomeSelected | Should -Be (Join-Path $script:ToolsDir 'jdk-21.0.13+9')
            Should -Invoke Invoke-ReaHttpGet -Times 2 -Exactly
            Invoke-ReaStepJdk
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'reusing jdk-21\.0\.13\+9'
            Should -Invoke Invoke-ReaHttpGet -Times 2 -Exactly
        }
        It 'rechecks an install plan under the lock: a JDK another run installed meanwhile is reused, not downloaded again' {
            Initialize-JdkServe
            Invoke-ReaStepJdk
            Should -Invoke Invoke-ReaHttpGet -Times 2 -Exactly
            $script:PlanJdk = 'install'
            try { Invoke-ReaStepJdk } finally { $script:PlanJdk = $null }
            Should -Invoke Invoke-ReaHttpGet -Times 2 -Exactly
            $script:JdkReused | Should -BeTrue
            $script:JavaHomeSelected | Should -Be (Join-Path $script:ToolsDir 'jdk-21.0.13+9')
        }
        It 'uses the embedded pin with the verbatim WARN when Adoptium is unreachable' {
            Initialize-JdkServe
            $script:ApiCode = 2
            $saved = $script:PIN_JDK_FALLBACK_WINDOWS_X64
            try {
                $script:PIN_JDK_FALLBACK_WINDOWS_X64 = $script:Name + ':' + $script:ApiSha
                Install-ReaJdk | Should -Be (Join-Path $script:ToolsDir 'jdk-21.0.13+9')
            } finally {
                $script:PIN_JDK_FALLBACK_WINDOWS_X64 = $saved
            }
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'WARN.*Adoptium API unreachable; installing the embedded fallback jdk-21\.0\.13\+9, possibly outdated'
            $log | Should -Match 'resolved jdk-21\.0\.13\+9: https://github\.com/adoptium/temurin21-binaries/releases/download/jdk-21\.0\.13%2B9/OpenJDK21U-jdk_x64_windows'
        }
        It 'refuses a fallback pin whose checksum does not match, with 5' {
            Initialize-JdkServe
            $script:ApiCode = 2
            Get-Code { Install-ReaJdk } | Should -Be 5
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'exits 5 when the Adoptium answer fails validation' {
            $script:ApiCode = 1
            Get-Code { Install-ReaJdk } | Should -Be 5
        }
        It 'exits 5 and installs nothing on an archive checksum mismatch' {
            Initialize-JdkServe -BadApi -Side none
            Get-Code { Install-ReaJdk } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'checksum mismatch'
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'exits 5 when the sidecar disagrees with the API, before downloading the archive' {
            Initialize-JdkServe -Side bad
            Get-Code { Install-ReaJdk } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'checksum mismatch for jdk-21\.0\.13\+9'
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
            Should -Invoke Invoke-ReaHttpGet -Times 1 -Exactly -ParameterFilter { $Url -like '*sha256.txt' }
            Should -Invoke Invoke-ReaHttpGet -Times 0 -Exactly -ParameterFilter { $Url -notlike '*sha256.txt' }
        }
        It 'warns and goes on when the sidecar is unreachable' {
            Initialize-JdkServe -Side none
            Install-ReaJdk | Should -Be (Join-Path $script:ToolsDir 'jdk-21.0.13+9')
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'WARN.*checksum sidecar of jdk-21\.0\.13\+9 is unreachable'
        }
        It 'exits 5 and installs nothing for two top directories' {
            Initialize-JdkServe -Layout two
            Get-Code { Install-ReaJdk } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'exactly one top directory'
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'exits 5 and installs nothing for a wrongly named top directory' {
            Initialize-JdkServe -Layout badname
            Get-Code { Install-ReaJdk } | Should -Be 5
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'exits 5 and installs nothing when the downloaded JDK is a 17' {
            Initialize-JdkServe -Layout j17
            Get-Code { Install-ReaJdk } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'not a usable JDK: major 17 < 21'
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'a dry run logs the release, URL and size and writes nothing' {
            Initialize-JdkServe
            $script:Opt.DryRun = $true
            Install-ReaJdk | Should -BeNullOrEmpty
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'resolved jdk-21\.0\.13\+9: https://github\.com/.*\.zip \(12345 bytes\)'
            $log | Should -Match 'read-only run, nothing installed'
            Test-Path -LiteralPath $script:ToolsDir | Should -BeFalse
            Should -Invoke Invoke-ReaHttpGet -Times 0 -Exactly
        }
        It 'prunes old installs, keeping the newest two, and never touches jdk-notes' {
            Initialize-JdkServe
            foreach ($v in @('21.0.1+1', '21.0.2+1', '21.0.3+1')) {
                $d = Join-Path $script:ToolsDir "jdk-$v"
                New-FakeJdk -Dir $d
                [System.IO.File]::WriteAllText((Join-Path $d '.install-complete'), 'x')
            }
            New-Item -ItemType Directory -Path (Join-Path $script:ToolsDir 'jdk-notes') | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $script:ToolsDir 'jdk-notes/readme.txt'), 'keep')
            New-Item -ItemType Directory -Path (Join-Path $script:ToolsDir 'jdk-21.0.0+1 stray') | Out-Null
            Install-ReaJdk | Out-Null
            (Get-ListingName $script:ToolsDir | Sort-Object) | Should -Be @('jdk-21.0.0+1 stray', 'jdk-21.0.13+9', 'jdk-21.0.3+1', 'jdk-notes')
            Test-Path -LiteralPath (Join-Path $script:ToolsDir 'jdk-notes/readme.txt') | Should -BeTrue
        }
    }
}
