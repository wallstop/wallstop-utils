Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:initializerPath = Join-Path -Path $script:repoRoot -ChildPath ".devcontainer/Initialize-DevcontainerHost.ps1"

    function New-FakeDockerScript {
        param(
            [Parameter(Mandatory = $true)]
            [string]$TempRoot,

            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]]$Containers
        )

        $statePath = Join-Path -Path $TempRoot -ChildPath "containers.json"
        $logPath = Join-Path -Path $TempRoot -ChildPath "docker.log"
        $rmLogPath = Join-Path -Path $TempRoot -ChildPath "rm.log"
        $dockerPath = Join-Path -Path $TempRoot -ChildPath "docker.ps1"

        [System.IO.File]::WriteAllText(
            $statePath,
        ($Containers | ConvertTo-Json -Depth 10),
            [System.Text.UTF8Encoding]::new($false)
        )

        [System.IO.File]::WriteAllText(
            $dockerPath,
            @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$DockerArgs
)

$ErrorActionPreference = "Stop"
$statePath = $env:WALLSTOP_TEST_DOCKER_STATE
$logPath = $env:WALLSTOP_TEST_DOCKER_LOG
$rmLogPath = $env:WALLSTOP_TEST_DOCKER_RM_LOG

[System.IO.File]::AppendAllText($logPath, (($DockerArgs -join '|') + "`n"), [System.Text.UTF8Encoding]::new($false))
$containers = @(Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)

if ($DockerArgs.Count -eq 0) {
    exit 2
}

switch ($DockerArgs[0]) {
    'ps' {
        foreach ($container in $containers) {
            [string]$container.Id
        }
        exit 0
    }
    'inspect' {
        $id = $DockerArgs[-1]
        $container = @($containers | Where-Object { [string]$_.Id -eq [string]$id } | Select-Object -First 1)
        if ($container.Count -eq 0) {
            exit 1
        }

        $inspectObject = [pscustomobject]@{
            Id = [string]$container[0].Id
            State = [pscustomobject]@{
                Status = [string]$container[0].StateStatus
            }
            Mounts = @($container[0].Mounts)
        }
        ConvertTo-Json -InputObject @($inspectObject) -Depth 10
        exit 0
    }
    'rm' {
        $id = $DockerArgs[-1]
        [System.IO.File]::AppendAllText($rmLogPath, ([string]$id + "`n"), [System.Text.UTF8Encoding]::new($false))
        $container = @($containers | Where-Object { [string]$_.Id -eq [string]$id } | Select-Object -First 1)
        $rmFailsProperty = if ($container.Count -gt 0) {
            $container[0].PSObject.Properties['RmFails']
        }
        else {
            $null
        }
        if ($null -ne $rmFailsProperty -and $rmFailsProperty.Value -eq $true) {
            Write-Error "fake docker rm failed for $id"
            exit 1
        }
        [string]$id
        exit 0
    }
    default {
        exit 2
    }
}
'@,
            [System.Text.UTF8Encoding]::new($false)
        )

        return [pscustomobject]@{
            DockerPath = $dockerPath
            LogPath = $logPath
            RmLogPath = $rmLogPath
            StatePath = $statePath
        }
    }

    function Invoke-HostInitializerWithFakeDocker {
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]]$Containers,

            [string]$WorkspaceFolder = "/home/wallstop/wallstop-utils",

            [hashtable]$Environment = @{}
        )

        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-devcontainer-host-" + [guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null

        $fakeDocker = New-FakeDockerScript -TempRoot $tempRoot -Containers $Containers
        $savedDockerPath = $env:WALLSTOP_DEVCONTAINER_DOCKER_PATH
        $savedState = $env:WALLSTOP_TEST_DOCKER_STATE
        $savedLog = $env:WALLSTOP_TEST_DOCKER_LOG
        $savedRmLog = $env:WALLSTOP_TEST_DOCKER_RM_LOG
        $savedCleanup = $env:WALLSTOP_DEVCONTAINER_HOST_CLEANUP

        try {
            $env:WALLSTOP_DEVCONTAINER_DOCKER_PATH = $fakeDocker.DockerPath
            $env:WALLSTOP_TEST_DOCKER_STATE = $fakeDocker.StatePath
            $env:WALLSTOP_TEST_DOCKER_LOG = $fakeDocker.LogPath
            $env:WALLSTOP_TEST_DOCKER_RM_LOG = $fakeDocker.RmLogPath

            foreach ($entry in $Environment.GetEnumerator()) {
                Set-Item -Path "Env:$($entry.Key)" -Value ([string]$entry.Value)
            }

            $output = @(& $script:initializerPath -WorkspaceFolder $WorkspaceFolder 2>&1)
            $dockerLog = if (Test-Path -LiteralPath $fakeDocker.LogPath) {
                Get-Content -LiteralPath $fakeDocker.LogPath -Raw
            }
            else {
                ""
            }
            $removed = if (Test-Path -LiteralPath $fakeDocker.RmLogPath) {
                @(Get-Content -LiteralPath $fakeDocker.RmLogPath)
            }
            else {
                @()
            }

            return [pscustomobject]@{
                Output = $output
                DockerLog = $dockerLog
                Removed = $removed
            }
        }
        finally {
            if ($null -eq $savedDockerPath) {
                Remove-Item Env:WALLSTOP_DEVCONTAINER_DOCKER_PATH -ErrorAction SilentlyContinue
            }
            else {
                $env:WALLSTOP_DEVCONTAINER_DOCKER_PATH = $savedDockerPath
            }
            if ($null -eq $savedState) {
                Remove-Item Env:WALLSTOP_TEST_DOCKER_STATE -ErrorAction SilentlyContinue
            }
            else {
                $env:WALLSTOP_TEST_DOCKER_STATE = $savedState
            }
            if ($null -eq $savedLog) {
                Remove-Item Env:WALLSTOP_TEST_DOCKER_LOG -ErrorAction SilentlyContinue
            }
            else {
                $env:WALLSTOP_TEST_DOCKER_LOG = $savedLog
            }
            if ($null -eq $savedRmLog) {
                Remove-Item Env:WALLSTOP_TEST_DOCKER_RM_LOG -ErrorAction SilentlyContinue
            }
            else {
                $env:WALLSTOP_TEST_DOCKER_RM_LOG = $savedRmLog
            }
            if ($null -eq $savedCleanup) {
                Remove-Item Env:WALLSTOP_DEVCONTAINER_HOST_CLEANUP -ErrorAction SilentlyContinue
            }
            else {
                $env:WALLSTOP_DEVCONTAINER_HOST_CLEANUP = $savedCleanup
            }
            foreach ($entry in $Environment.GetEnumerator()) {
                if ($entry.Key -ne "WALLSTOP_DEVCONTAINER_HOST_CLEANUP") {
                    Remove-Item -Path "Env:$($entry.Key)" -ErrorAction SilentlyContinue
                }
            }
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}

Describe "Initialize-DevcontainerHost.ps1 stale Wayland cleanup" {
    It "exists at .devcontainer/Initialize-DevcontainerHost.ps1" {
        $script:initializerPath | Should -Exist
    }

    It "parses docker inspect JSON from stdout only so stderr warnings cannot poison JSON" {
        $content = Get-Content -Path $script:initializerPath -Raw

        $content | Should -Match 'Stdout\s*=\s*@\(Split-ProcessOutputLines'
        $content | Should -Match 'Stderr\s*=\s*@\(Split-ProcessOutputLines'
        $content | Should -Match '\$inspectJson\s*=\s*\(\$inspectResult\.Stdout'
        $content | Should -Not -Match '\$inspectJson\s*=\s*\(\$inspectResult\.Output'
    }

    It "uses exact devcontainer label filters for this workspace and config file" {
        $workspaceFolder = "/home/wallstop/wallstop-utils"
        $expectedConfigFile = Join-Path -Path (Join-Path -Path $workspaceFolder -ChildPath ".devcontainer") -ChildPath "devcontainer.json"

        $result = Invoke-HostInitializerWithFakeDocker -WorkspaceFolder $workspaceFolder -Containers @()

        $result.DockerLog | Should -Match 'ps\|-q\|-a'
        $result.DockerLog | Should -Match ([regex]::Escape("label=devcontainer.local_folder=$workspaceFolder"))
        $result.DockerLog | Should -Match ([regex]::Escape("label=devcontainer.config_file=$expectedConfigFile"))
        $result.DockerLog | Should -Not -Match 'docker container prune'
    }

    It "removes only stopped containers that have VS Code managed Wayland socket bind mounts" {
        $containers = @(
            [pscustomobject]@{
                Id = "stale-exited"
                StateStatus = "exited"
                Mounts = @(
                    [pscustomobject]@{
                        Type = "bind"
                        Source = "/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/Ubuntu/stale"
                        Destination = "/tmp/vscode-wayland-1111.sock"
                    }
                )
            },
            [pscustomobject]@{
                Id = "created-stale"
                StateStatus = "created"
                Mounts = @(
                    [pscustomobject]@{
                        Type = "bind"
                        Source = "/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/Ubuntu/created"
                        Destination = "/tmp/vscode-wayland-2222.sock"
                    }
                )
            },
            [pscustomobject]@{
                Id = "running-wayland"
                StateStatus = "running"
                Mounts = @(
                    [pscustomobject]@{
                        Type = "bind"
                        Source = "/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/Ubuntu/running"
                        Destination = "/tmp/vscode-wayland-3333.sock"
                    }
                )
            },
            [pscustomobject]@{
                Id = "exited-normal"
                StateStatus = "exited"
                Mounts = @(
                    [pscustomobject]@{
                        Type = "bind"
                        Source = "/repo"
                        Destination = "/workspaces/wallstop-utils"
                    }
                )
            }
        )

        $result = Invoke-HostInitializerWithFakeDocker -Containers $containers

        @($result.Removed | Sort-Object) | Should -Be @("created-stale", "stale-exited")
    }

    It "does not remove stale containers when host cleanup is explicitly disabled" {
        $containers = @(
            [pscustomobject]@{
                Id = "stale-exited"
                StateStatus = "exited"
                Mounts = @(
                    [pscustomobject]@{
                        Type = "bind"
                        Source = "/run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/Ubuntu/stale"
                        Destination = "/tmp/vscode-wayland-1111.sock"
                    }
                )
            }
        )

        $result = Invoke-HostInitializerWithFakeDocker `
            -Containers $containers `
            -Environment @{ WALLSTOP_DEVCONTAINER_HOST_CLEANUP = "0" }

        @($result.Removed).Count | Should -Be 0
    }
}
