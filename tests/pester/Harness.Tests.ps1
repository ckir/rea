# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

Describe 'Pester harness' {
    BeforeAll {
        # This file tests the harness alone, so it never sources setup.ps1 (it need not exist yet). Files that
        # test setup.ps1 begin with: $env:REA_SETUP_NO_MAIN = '1'; . "$PSScriptRoot/../../setup.ps1"
    }

    It 'runs under Pester 5 or newer' {
        (Get-Module Pester).Version.Major | Should -BeGreaterOrEqual 5
    }
}

Describe 'Pester files that read $script:OnWindows' {
    # A BeforeDiscovery variable is empty in the run phase of Pester 5, so a run-phase read (an `if` inside an It)
    # sees nothing on Windows. Every file that assigns it in BeforeDiscovery must assign it in BeforeAll too.
    It 'assigns it in BeforeAll as well as in BeforeDiscovery: <_.Name>' -ForEach @(Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' -File | Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match '(?s)BeforeDiscovery\s*\{[^}]*OnWindows' }) {
        $text = [System.IO.File]::ReadAllText($_.FullName)
        $m = [regex]::Match($text, '(?s)BeforeAll\s*\{(.*?)\n\}')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Match '\$script:OnWindows\s*='
    }
}

Describe 'Pester helper functions' {
    # A function defined in a Describe or Context body (or at the top of a file) is defined while Pester DISCOVERS
    # every file, before any file runs, so two files that give a helper the same name overwrite each other and the
    # last discovered wins: Ghidra.Tests.ps1 once ran Jdk.Tests.ps1's Initialize-Serve that way (CommandNotFound
    # for New-JdkArchive), on Pester 5.9.0 only. A helper belongs in a BeforeAll or BeforeEach, which runs per file.
    It 'is defined inside BeforeAll or BeforeEach, never in a Describe/Context body: <_.Name>' -ForEach @(Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' -File | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $misplaced = @()
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $ok = $false
            for ($p = $fn.Parent; $null -ne $p; $p = $p.Parent) {
                if ($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -in @('BeforeAll', 'BeforeEach')) { $ok = $true; break }
            }
            if (-not $ok) { $misplaced += "$($fn.Name) (line $($fn.Extent.StartLineNumber))" }
        }
        $misplaced | Should -BeNullOrEmpty
    }
}

Describe 'Pester native calls' {
    # Windows PowerShell 5.1 turns each stderr line merged with 2>&1 from a native command into a terminating
    # error under $ErrorActionPreference = 'Stop' (Pester sets it), and the script prints its log-path line on stderr
    # first. A test that runs a child process reads its streams through Invoke-ReaTestProcess, never 2>&1.
    It 'does not merge the stderr of a native command with 2>&1: <_.Name>' -ForEach @(Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' -File | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }) {
        $hits = @([System.IO.File]::ReadAllLines($Path) | Where-Object { $_ -match '^\s*[^#]*&\s+\$script:Pwsh\b.*2>&1' })
        $hits | Should -BeNullOrEmpty
    }
}
