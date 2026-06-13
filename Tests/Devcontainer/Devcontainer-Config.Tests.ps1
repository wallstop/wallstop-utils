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

    It "enables init process for startup signal and zombie reaping reliability" {
        $initProperty = $script:devcontainer.PSObject.Properties["init"]
        $null -eq $initProperty | Should -BeFalse
        [bool]$initProperty.Value | Should -BeTrue
    }

    It "defines persistent cache mounts for heavy tool bootstrap paths" {
        $mountsProperty = $script:devcontainer.PSObject.Properties["mounts"]
        $null -eq $mountsProperty | Should -BeFalse

        $mounts = @($mountsProperty.Value)
        $mounts.Count | Should -BeGreaterThan 0

        $normalizedMounts = @($mounts | ForEach-Object { [string]$_ -replace "`r", "" })
        $normalizedMounts -join "`n" | Should -Match 'target=/home/vscode/\.cache/pip,type=volume'
        $normalizedMounts -join "`n" | Should -Match 'target=/home/vscode/\.cache/pre-commit,type=volume'
        $normalizedMounts -join "`n" | Should -Match 'target=/home/vscode/\.npm,type=volume'
    }

    It "disables Codex bootstrap by default to prioritize cold-start attach" {
        $containerEnvProperty = $script:devcontainer.PSObject.Properties["containerEnv"]
        $null -eq $containerEnvProperty | Should -BeFalse

        $containerEnv = $containerEnvProperty.Value
        $containerEnv.WALLSTOP_DEVCONTAINER_ENABLE_CODEX | Should -Be "0"
    }

    It "defines an explicit bounded Codex npm install timeout" {
        $containerEnv = $script:devcontainer.PSObject.Properties["containerEnv"].Value
        $containerEnv.WALLSTOP_DEVCONTAINER_CODEX_NPM_TIMEOUT_SECONDS | Should -Match '^[0-9]+$'
        [int]$containerEnv.WALLSTOP_DEVCONTAINER_CODEX_NPM_TIMEOUT_SECONDS | Should -BeGreaterOrEqual 30
    }
}

Describe "devcontainer validate workflow policy contract" {
    It "includes an explicit image-first policy check step" {
        $script:workflowContent | Should -Match 'name:\s+Validate image-first devcontainer contract'
    }
}
