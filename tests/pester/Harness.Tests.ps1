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
