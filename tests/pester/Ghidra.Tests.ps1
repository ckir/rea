# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

# Tests for the setup.ps1 step ghidra; they mirror tests/sh/ghidra.sh. The network is replaced at the seams of the
# jdk tests (the redirect walk and the HTTP GET, which copies a prepared file), so Get-ReaDownload, the checksum,
# the archive checks, the extraction and the commit all run for real, on a real small zip shaped like the Ghidra
# release. The test replaces the embedded digest and size with those of that zip by assigning the script
# variables; the product never reads them from the environment. Every directory has a space in its name.

BeforeDiscovery {
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
}

BeforeAll {
    # BeforeDiscovery variables are empty in the run phase, so the run-phase reads need their own copy
    $script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
    $env:REA_SETUP_NO_MAIN = '1'
    . (Resolve-Path (Join-Path $PSScriptRoot '../../setup.ps1')).Path
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('rea ghidra work ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:T | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:F412 = Join-Path $script:Root 'tests/fixtures/fake-ghidra'
    $script:F122 = Join-Path $script:Root 'tests/fixtures/fake-ghidra-12.2.0'
    $script:WarnMac = 'the official 12.1.4 archive has no macOS native decompiler; rea doctor will report native_decompiler missing until it is built (rea docs/installation.md, "Missing macOS native decompiler" / "macOS arm64 native decompiler")'
    $script:Top = 'ghidra_12.1.4_PUBLIC'

    function script:Get-Code {
        param([scriptblock]$Block)
        try { & $Block } catch { return $_.Exception.Data['ReaCode'] }
        return 0
    }
    function script:New-GhidraProperty {
        param([string]$Dir, [string]$Text)
        New-Item -ItemType Directory -Path (Join-Path $Dir 'Ghidra') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $Dir 'Ghidra') 'application.properties'), $Text)
    }
    function script:Get-ListingName {
        param([string]$Dir)
        if (-not (Test-Path -LiteralPath $Dir)) { return @() }
        return @(Get-ChildItem -LiteralPath $Dir -Force | ForEach-Object { $_.Name })
    }
    # A zip shaped like the Ghidra release under Out. Layout: normal, badver (application.version 12.1.3), two (a
    # second top directory) or badname (the top directory ghidra_12.1.9_PUBLIC).
    function script:New-GhidraZip {
        param([string]$Dir, [string]$Layout = 'normal')
        $src = Join-Path $Dir ('src ' + [guid]::NewGuid().ToString('N'))
        $top = $script:Top
        if ($Layout -eq 'badname') { $top = 'ghidra_12.1.9_PUBLIC' }
        $version = '12.1.4'
        if ($Layout -eq 'badver') { $version = '12.1.3' }
        $root = Join-Path $src $top
        New-GhidraProperty -Dir $root -Text "application.name=Ghidra`napplication.version=$version`n"
        New-Item -ItemType Directory -Path (Join-Path $root 'support') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'ghidraRun'), 'x')
        [System.IO.File]::WriteAllText((Join-Path $root 'support/analyzeHeadless'), 'x')
        if ($Layout -eq 'two') {
            New-Item -ItemType Directory -Path (Join-Path $src 'notes') | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $src 'notes/readme'), 'x')
        }
        $out = Join-Path $Dir 'ghidra.zip'
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $out)
        return $out
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'ghidra' {
    BeforeEach {
        $script:Case = Join-Path $script:T ('case ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case | Out-Null
        $script:ToolsDir = Join-Path $script:Case 'tools dir'
        $script:LogFile = Join-Path $script:Case 'run.log'
        $script:ConsoleLevel = 'ERROR'
        $script:Summary = @{}
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        $script:GhidraDirSelected = ''
        $script:GhidraOfficial = $false
        $script:Served = @{}
        $script:SavedSha = $script:PIN_GHIDRA_SHA256
        $script:SavedBytes = $script:PIN_GHIDRA_ZIP_BYTES
        $script:SavedBound = $script:Bound
        $script:SavedGhidraDir = $script:Opt.GhidraDir
        $script:SavedEnvGhidra = $env:GHIDRA_INSTALL_DIR
        Remove-Item Env:\GHIDRA_INSTALL_DIR -ErrorAction SilentlyContinue
        Mock Get-ReaPlatform { return @{ Os = 'windows'; Arch = 'x64' } }
        Mock Resolve-ReaRedirect { return [pscustomobject]@{ Code = 0; Url = $Url } }
        Mock Invoke-ReaHttpGet {
            if (-not $script:Served.ContainsKey($Url)) { return $false }
            Copy-Item -LiteralPath $script:Served[$Url] -Destination $Destination
            return $true
        }
    }
    AfterEach {
        $script:PIN_GHIDRA_SHA256 = $script:SavedSha
        $script:PIN_GHIDRA_ZIP_BYTES = $script:SavedBytes
        $script:Bound = $script:SavedBound
        $script:Opt.GhidraDir = $script:SavedGhidraDir
        if ($script:SavedEnvGhidra) { $env:GHIDRA_INSTALL_DIR = $script:SavedEnvGhidra } else { Remove-Item Env:\GHIDRA_INSTALL_DIR -ErrorAction SilentlyContinue }
        $script:LogFile = $null
        $script:Opt.DryRun = $false
        $script:Opt.CheckUpstream = $false
        foreach ($d in @($script:LockHeld)) { Unlock-ReaDir -Dir $d }
        Clear-ReaTempFile
    }

    Context 'Get-ReaGhidraVersion and Test-ReaGhidraValid' {
        It 'reads both fixtures' {
            Get-ReaGhidraVersion -Dir $script:F412 | Should -Be '12.1.4'
            Get-ReaGhidraVersion -Dir $script:F122 | Should -Be '12.2.0'
        }
        It 'is empty for a missing directory and a directory without application.properties' {
            Get-ReaGhidraVersion -Dir (Join-Path $script:Case 'nothing here') | Should -Be ''
            New-Item -ItemType Directory -Path (Join-Path $script:Case 'no props/Ghidra') -Force | Out-Null
            Get-ReaGhidraVersion -Dir (Join-Path $script:Case 'no props') | Should -Be ''
        }
        It 'tolerates CRLF, blanks and other properties' {
            $d = Join-Path $script:Case 'crlf'
            New-GhidraProperty -Dir $d -Text "application.name=Ghidra`r`napplication.version=12.1.9`r`napplication.layout.version=2`r`n"
            Get-ReaGhidraVersion -Dir $d | Should -Be '12.1.9'
            New-GhidraProperty -Dir $d -Text "  application.version = 12.1.5  `napplication.layout.version=2`n"
            Get-ReaGhidraVersion -Dir $d | Should -Be '12.1.5'
            New-GhidraProperty -Dir $d -Text "application.layout.version=2`n"
            Get-ReaGhidraVersion -Dir $d | Should -Be ''
        }
        It 'accepts <v>' -ForEach @(@{ v = '12.1' }, @{ v = '12.1.4' }, @{ v = '12.1.9' }) {
            $d = Join-Path $script:Case 'v'
            New-GhidraProperty -Dir $d -Text "application.version=$v`n"
            (Test-ReaGhidraValid -Dir $d).Valid | Should -BeTrue
        }
        It 'refuses <v>' -ForEach @(@{ v = '12.2.0' }, @{ v = '11.3.1' }, @{ v = '12.10.0' }, @{ v = '12.1.x' }, @{ v = '' }) {
            $d = Join-Path $script:Case 'v'
            New-GhidraProperty -Dir $d -Text "application.version=$v`n"
            $r = Test-ReaGhidraValid -Dir $d
            $r.Valid | Should -BeFalse
            $r.Reason | Should -Not -BeNullOrEmpty
        }
        It 'refuses a directory without application.properties and a missing directory' {
            New-Item -ItemType Directory -Path (Join-Path $script:Case 'no props/Ghidra') -Force | Out-Null
            (Test-ReaGhidraValid -Dir (Join-Path $script:Case 'no props')).Valid | Should -BeFalse
            (Test-ReaGhidraValid -Dir (Join-Path $script:Case 'nothing here')).Valid | Should -BeFalse
        }
    }

    Context 'Select-ReaGhidra precedence' {
        It 'dies with 1 when -GhidraDir is a 12.2 install, and says why' {
            Get-Code { Select-ReaGhidra -FlagDir $script:F122 -EnvDir '' } | Should -Be 1
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'not a usable Ghidra: version 12\.2\.0'
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'dies with 1 when -GhidraDir is missing' {
            Get-Code { Select-ReaGhidra -FlagDir (Join-Path $script:Case 'nothing here') -EnvDir '' } | Should -Be 1
        }
        It 'uses a valid -GhidraDir over the environment' {
            Select-ReaGhidra -FlagDir $script:F412 -EnvDir $script:F122
            $script:GhidraDirSelected | Should -Be $script:F412
            $script:Summary['ghidra'] | Should -Match 'reused -GhidraDir'
        }
        It 'uses a valid GHIDRA_INSTALL_DIR without a WARN' {
            Select-ReaGhidra -FlagDir '' -EnvDir $script:F412
            $script:GhidraDirSelected | Should -Be $script:F412
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Not -Match 'WARN'
        }
        It 'warns for an invalid environment value and reuses the marked tools-dir install' {
            $d = Join-Path $script:ToolsDir $script:Top
            New-GhidraProperty -Dir $d -Text "application.version=12.1.4`n"
            [System.IO.File]::WriteAllText((Join-Path $d '.install-complete'), 'x')
            Select-ReaGhidra -FlagDir '' -EnvDir (Join-Path $script:Case 'nothing here')
            $script:GhidraDirSelected | Should -Be $d
            $script:GhidraOfficial | Should -BeTrue
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'WARN.*GHIDRA_INSTALL_DIR .*nothing here is not a usable Ghidra .*ignoring it'
            $log | Should -Match 'reusing ghidra_12\.1\.4_PUBLIC'
        }
        It 'logs the verbatim 12.2 WARN' {
            $d = Join-Path $script:ToolsDir $script:Top
            New-GhidraProperty -Dir $d -Text "application.version=12.1.4`n"
            [System.IO.File]::WriteAllText((Join-Path $d '.install-complete'), 'x')
            Select-ReaGhidra -FlagDir '' -EnvDir $script:F122
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match '(?m)WARN +\[ghidra\] 12\.2 is not accepted by rea 6\.8\.0; installing 12\.1\.4 alongside\s*$'
        }
        It 'treats a tools-dir install without .install-complete as absent' {
            $d = Join-Path $script:ToolsDir $script:Top
            New-GhidraProperty -Dir $d -Text "application.version=12.1.4`n"
            $script:Opt.DryRun = $true
            Select-ReaGhidra -FlagDir '' -EnvDir ''
            $script:GhidraDirSelected | Should -Be ''
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match 'DEBUG.*ignoring ghidra_12\.1\.4_PUBLIC: no \.install-complete'
            $log | Should -Match 'will install Ghidra 12\.1\.4'
        }
        It 'does not reuse a marked tools-dir install of 12.2' {
            $d = Join-Path $script:ToolsDir $script:Top
            New-GhidraProperty -Dir $d -Text "application.version=12.2.0`n"
            [System.IO.File]::WriteAllText((Join-Path $d '.install-complete'), 'x')
            $script:Opt.DryRun = $true
            Select-ReaGhidra -FlagDir '' -EnvDir ''
            $script:GhidraDirSelected | Should -Be ''
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'WARN.*ignoring the install ghidra_12\.1\.4_PUBLIC: version 12\.2\.0'
        }
        It 'tells the flag from the environment through the bound parameters' {
            $script:Bound = @{}
            $script:Opt.GhidraDir = 'C:\from\env'
            Get-ReaGhidraDirFlag | Should -Be ''
            $script:Bound = @{ GhidraDir = 'C:\x' }
            $script:Opt.GhidraDir = 'C:\x'
            Get-ReaGhidraDirFlag | Should -Be 'C:\x'
        }
    }

    Context 'Install-ReaGhidra' {
        # Builds the zip for Layout, serves it at the pinned URL and points the embedded digest and size at it.
        function script:Initialize-Serve {
            param([string]$Layout = 'normal')
            $srv = Join-Path $script:Case 'srv dir'
            New-Item -ItemType Directory -Path $srv -Force | Out-Null
            $zip = New-GhidraZip -Dir $srv -Layout $Layout
            $script:ZipSize = (Get-Item -LiteralPath $zip).Length
            $script:PIN_GHIDRA_SHA256 = Get-ReaFileSha256 $zip
            $script:PIN_GHIDRA_ZIP_BYTES = [string]$script:ZipSize
            $script:Served[$script:PIN_GHIDRA_URL] = $zip
        }
        It 'installs: final dir, sentinel, no zip or staging left, selected dir and summary set, size logged' {
            Initialize-Serve
            $final = Join-Path $script:ToolsDir $script:Top
            Install-ReaGhidra | Should -Be $final
            $script:GhidraDirSelected | Should -Be $final
            Get-ListingName $script:ToolsDir | Should -Be @($script:Top)
            Test-Path -LiteralPath (Join-Path $final '.install-complete') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $final 'Ghidra/application.properties') | Should -BeTrue
            $script:Summary['ghidra'] | Should -Match '^12\.1\.4 installed'
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match "will install Ghidra 12\.1\.4 from https://github\.com/.*\.zip \($($script:ZipSize) bytes\) into"
            $log | Should -Match 'installed Ghidra 12\.1\.4'
            Should -Invoke Invoke-ReaHttpGet -Times 1 -Exactly
        }
        It 'goes through Select-ReaGhidra and Invoke-ReaStepGhidra, and a second run reuses the install' {
            Initialize-Serve
            Invoke-ReaStepGhidra
            $script:GhidraDirSelected | Should -Be (Join-Path $script:ToolsDir $script:Top)
            Should -Invoke Invoke-ReaHttpGet -Times 1 -Exactly
            Invoke-ReaStepGhidra
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'reusing ghidra_12\.1\.4_PUBLIC'
            Should -Invoke Invoke-ReaHttpGet -Times 1 -Exactly
        }
        It 'rechecks an install plan under the lock: a Ghidra another run installed meanwhile is reused, not downloaded again' {
            Initialize-Serve
            Invoke-ReaStepGhidra
            Should -Invoke Invoke-ReaHttpGet -Times 1 -Exactly
            $script:PlanGhidra = 'install'
            try { Invoke-ReaStepGhidra } finally { $script:PlanGhidra = $null }
            Should -Invoke Invoke-ReaHttpGet -Times 1 -Exactly
            $script:GhidraReused | Should -BeTrue
            $script:GhidraDirSelected | Should -Be (Join-Path $script:ToolsDir $script:Top)
        }
        It 'replaces an install directory without .install-complete (rename over the existing directory)' {
            Initialize-Serve
            $old = Join-Path $script:ToolsDir $script:Top
            New-GhidraProperty -Dir $old -Text "application.version=12.1.4`n"
            [System.IO.File]::WriteAllText((Join-Path $old 'stale-file'), 'half')
            Invoke-ReaStepGhidra
            Test-Path -LiteralPath (Join-Path $old '.install-complete') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $old 'ghidraRun') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $old 'stale-file') | Should -BeFalse
            Get-ListingName $script:ToolsDir | Should -Be @($script:Top)
        }
        It 'on macOS installs, logs the verbatim WARN, sets a warn summary and does not fail' {
            Mock Get-ReaPlatform { return @{ Os = 'mac'; Arch = 'x64' } }
            Initialize-Serve
            Invoke-ReaStepGhidra
            Test-Path -LiteralPath (Join-Path (Join-Path $script:ToolsDir $script:Top) '.install-complete') | Should -BeTrue
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match ('(?m)WARN +\[ghidra\] ' + [regex]::Escape($script:WarnMac) + '\s*$')
            $script:Summary['ghidra'] | Should -Match '^warn: 12\.1\.4 installed'
        }
        It 'installs alongside a 12.2 GHIDRA_INSTALL_DIR after the verbatim WARN' {
            Initialize-Serve
            $env:GHIDRA_INSTALL_DIR = $script:F122
            Invoke-ReaStepGhidra
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'WARN.*12\.2 is not accepted by rea 6\.8\.0; installing 12\.1\.4 alongside'
            $script:GhidraDirSelected | Should -Be (Join-Path $script:ToolsDir $script:Top)
            Test-Path -LiteralPath (Join-Path (Join-Path $script:ToolsDir $script:Top) '.install-complete') | Should -BeTrue
        }
        It 'exits 5 and installs nothing when the archive reports another version' {
            Initialize-Serve -Layout badver
            Get-Code { Install-ReaGhidra } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match "reports version '12\.1\.3', expected 12\.1\.4"
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'exits 5 and installs nothing for two top directories' {
            Initialize-Serve -Layout two
            Get-Code { Install-ReaGhidra } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'exactly one top directory'
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'exits 5 and installs nothing for a wrongly named top directory' {
            Initialize-Serve -Layout badname
            Get-Code { Install-ReaGhidra } | Should -Be 5
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'exits 5 and installs nothing on a size mismatch' {
            Initialize-Serve
            $script:PIN_GHIDRA_ZIP_BYTES = [string]($script:ZipSize + 1)
            Get-Code { Install-ReaGhidra } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match "is $($script:ZipSize) bytes, expected $($script:ZipSize + 1)"
            Get-ListingName $script:ToolsDir | Should -BeNullOrEmpty
        }
        It 'exits 5 and installs nothing on a hash mismatch, leaving an old directory as it was' {
            Initialize-Serve
            $script:PIN_GHIDRA_SHA256 = '0' * 64
            $old = Join-Path $script:ToolsDir $script:Top
            New-Item -ItemType Directory -Path $old -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $old 'old-file'), 'keep')
            Get-Code { Install-ReaGhidra } | Should -Be 5
            Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'checksum mismatch'
            Get-ListingName $script:ToolsDir | Should -Be @($script:Top)
            Test-Path -LiteralPath (Join-Path $old 'old-file') | Should -BeTrue
        }
        It 'a dry run logs URL, size and target and downloads nothing' {
            Initialize-Serve
            $script:Opt.DryRun = $true
            Install-ReaGhidra | Should -BeNullOrEmpty
            $log = Get-Content -LiteralPath $script:LogFile -Raw
            $log | Should -Match "will install Ghidra 12\.1\.4 from https://github\.com/.*\.zip \($($script:ZipSize) bytes\) into .*ghidra_12\.1\.4_PUBLIC"
            $log | Should -Match 'read-only run, nothing installed'
            Test-Path -LiteralPath $script:ToolsDir | Should -BeFalse
            Should -Invoke Invoke-ReaHttpGet -Times 0 -Exactly
        }
        It 'a check-upstream run writes nothing either' {
            Initialize-Serve
            $script:Opt.CheckUpstream = $true
            Install-ReaGhidra | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:ToolsDir | Should -BeFalse
            Should -Invoke Invoke-ReaHttpGet -Times 0 -Exactly
        }
    }
}
