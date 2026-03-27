Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    . "$PSScriptRoot/../../Scripts/Utils/Common/StrictModeHelpers.ps1"
}

Describe "Get-SafeCount" {
    It "returns 0 for null" {
        (Get-SafeCount -InputObject $null) | Should -Be 0
    }

    It "returns 1 for a scalar value" {
        (Get-SafeCount -InputObject "value") | Should -Be 1
    }

    It "returns array length for collections" {
        (Get-SafeCount -InputObject @(1, 2, 3)) | Should -Be 3
    }

    It "returns 1 for hashtable object" {
        (Get-SafeCount -InputObject @{ Name = "item" }) | Should -Be 1
    }
}

Describe "Assert-IsHashtableLike" {
    It "accepts hashtable" {
        { Assert-IsHashtableLike -Value @{ A = 1 } -Name "Headers" } | Should -Not -Throw
    }

    It "accepts ordered dictionary" {
        $ordered = [ordered]@{ A = 1 }
        { Assert-IsHashtableLike -Value $ordered -Name "Headers" } | Should -Not -Throw
    }

    It "throws for arrays" {
        { Assert-IsHashtableLike -Value @("a", "b") -Name "Headers" } | Should -Throw "*E_TYPE_ERROR*"
    }
}

Describe "ConvertFrom-JsonSingleObject" {
    It "returns parsed object for single JSON object" {
        $result = ConvertFrom-JsonSingleObject -Json '{"name":"wallstop"}' -Context "test payload"
        $result.name | Should -Be "wallstop"
    }

    It "throws for multi-item JSON arrays" {
        {
            ConvertFrom-JsonSingleObject -Json '[{"name":"a"},{"name":"b"}]' -Context "test payload"
        } | Should -Throw "*E_MALFORMED_RESPONSE*"
    }
}
