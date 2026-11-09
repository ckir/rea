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
