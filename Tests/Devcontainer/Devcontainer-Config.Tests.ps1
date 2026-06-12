Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:devcontainerPath = Join-Path -Path $script:repoRoot -ChildPath ".devcontainer/devcontainer.json"
    $script:workflowPath = Join-Path -Path $script:repoRoot -ChildPath ".github/workflows/devcontainer-validate.yml"

    $script:devcontainerContent = Get-Content -Path $script:devcontainerPath -Raw
    $script:devcontainer = $script:devcontainerContent | ConvertFrom-Json
    $script:workflowContent = Get-Content -Path $script:workflowPath -Raw
}

Describe "devcontainer.json image-first contract" {
    It "exists at .devcontainer/devcontainer.json" {
        $script:devcontainerPath | Should -Exist
    }

    It "uses a prebuilt image from the official devcontainers registry" {
        $script:devcontainer.image | Should -Not -BeNullOrEmpty
        [string]$script:devcontainer.image | Should -Match '^mcr\.microsoft\.com/devcontainers/'
    }

    It "pins the prebuilt image with a sha256 digest" {
        [string]$script:devcontainer.image | Should -Match '@sha256:[0-9a-f]{64}$'
    }

    It "does not define a build block" {
        $null -eq $script:devcontainer.PSObject.Properties["build"] | Should -BeTrue
    }

    It "keeps feature-based image mutation disabled" {
        $featuresProperty = $script:devcontainer.PSObject.Properties["features"]
        if ($null -eq $featuresProperty) {
            $true | Should -BeTrue
            return
        }

        @($featuresProperty.Value.PSObject.Properties).Count | Should -Be 0
    }
}

Describe "devcontainer validate workflow policy contract" {
    It "includes an explicit image-first policy check step" {
        $script:workflowContent | Should -Match 'name:\s+Validate image-first devcontainer contract'
    }
}
