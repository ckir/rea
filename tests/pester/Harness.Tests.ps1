# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

Describe 'Pester harness' {
    BeforeAll {
        # Like tests/sh/harness.sh, this file tests the harness alone, so it declares that setup.ps1 need not
        # exist yet; the value is restored in AfterAll so no other test file inherits it.
        $script:savedNoSource = $env:TEST_NO_SOURCE
        $env:TEST_NO_SOURCE = '1'
        if ($env:TEST_NO_SOURCE -ne '1') {
            . "$PSScriptRoot/../../setup.ps1"
        }
    }

    AfterAll {
        $env:TEST_NO_SOURCE = $script:savedNoSource
    }

    It 'runs under Pester 5 or newer' {
        (Get-Module Pester).Version.Major | Should -BeGreaterOrEqual 5
    }
}
