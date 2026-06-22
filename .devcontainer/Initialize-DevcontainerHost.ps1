[CmdletBinding()]
param(
    [string]$WorkspaceFolder = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$compatibilityHelpersPath = Join-Path -Path $repositoryRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1"
if (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf) {
    . $compatibilityHelpersPath
}
else {
    throw "E_DEVCONTAINER_HOST_COMPATIBILITY_HELPERS_MISSING: expected compatibility helpers at '$compatibilityHelpersPath'."
}

function Write-DevcontainerHostLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[devcontainer:init] $Message"
}

function Write-DevcontainerHostWarning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Warning "[devcontainer:init] $Message"
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-HostCleanupEnabled {
    $value = [string]$env:WALLSTOP_DEVCONTAINER_HOST_CLEANUP
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $true
    }

    switch ($value.ToLowerInvariant()) {
        { $_ -in @("1", "true", "yes", "on") } { return $true }
        { $_ -in @("0", "false", "no", "off") } { return $false }
        default {
            Write-DevcontainerHostWarning "W_DEVCONTAINER_HOST_CLEANUP_CONFIG: unsupported WALLSTOP_DEVCONTAINER_HOST_CLEANUP value '$value'; cleanup remains enabled."
            return $true
        }
    }
}

function Resolve-DockerCommandPath {
    $overridePath = [string]$env:WALLSTOP_DEVCONTAINER_DOCKER_PATH
    if (-not [string]::IsNullOrWhiteSpace($overridePath)) {
        if (Test-Path -LiteralPath $overridePath -PathType Leaf) {
            return $overridePath
        }

        Write-DevcontainerHostWarning "W_DEVCONTAINER_HOST_DOCKER_OVERRIDE_MISSING: docker override path '$overridePath' was not found; falling back to PATH discovery."
    }

    $dockerCommand = Get-Command -Name "docker" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $dockerCommand -or [string]::IsNullOrWhiteSpace([string]$dockerCommand.Path)) {
        Write-DevcontainerHostWarning "W_DEVCONTAINER_HOST_DOCKER_NOT_AVAILABLE: docker was not found on PATH; stale devcontainer cleanup skipped."
        return $null
    }

    return [string]$dockerCommand.Path
}

function Get-DockerCommandTimeoutSeconds {
    $value = [string]$env:WALLSTOP_DEVCONTAINER_HOST_DOCKER_TIMEOUT_SECONDS
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 45
    }

    $parsedValue = 0
    if (-not [int]::TryParse($value, [ref]$parsedValue) -or $parsedValue -lt 5) {
        Write-DevcontainerHostWarning "W_DEVCONTAINER_HOST_DOCKER_TIMEOUT_CONFIG: WALLSTOP_DEVCONTAINER_HOST_DOCKER_TIMEOUT_SECONDS must be an integer >= 5; using 45 seconds."
        return 45
    }

    return $parsedValue
}

function Split-ProcessOutputLines {
    param(
        [string]$Text
    )

    $lines = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    foreach ($line in ($Text -split "\r?\n")) {
        if ($line.Length -gt 0) {
            $lines.Add($line) | Out-Null
        }
    }

    return $lines.ToArray()
}

function Invoke-DockerApplicationCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DockerPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $DockerPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList $Arguments

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeoutMilliseconds = [Math]::Min([int64][int]::MaxValue, [int64]$TimeoutSeconds * 1000)
        if (-not $process.WaitForExit([int]$timeoutMilliseconds)) {
            try {
                $process.Kill($true)
            }
            catch {
                try {
                    $process.Kill()
                }
                catch {
                    # Best effort cleanup; the caller receives a timeout diagnostic.
                }
            }

            return [pscustomobject]@{
                ExitCode = 124
                Stdout = @()
                Stderr = @("docker command timed out after ${TimeoutSeconds}s: docker $($Arguments -join ' ')")
                Output = @("docker command timed out after ${TimeoutSeconds}s: docker $($Arguments -join ' ')")
            }
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Stdout = @(Split-ProcessOutputLines -Text $stdout)
            Stderr = @(Split-ProcessOutputLines -Text $stderr)
            Output = @(
                Split-ProcessOutputLines -Text $stdout
                Split-ProcessOutputLines -Text $stderr
            )
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-DockerCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DockerPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $extension = [System.IO.Path]::GetExtension($DockerPath)
    if ($extension -notin @(".ps1", ".psm1")) {
        return Invoke-DockerApplicationCommand `
            -DockerPath $DockerPath `
            -Arguments $Arguments `
            -TimeoutSeconds (Get-DockerCommandTimeoutSeconds)
    }

    $output = @()
    $exitCode = 0
    try {
        $output = @(& $DockerPath @Arguments 2>&1)
        if ($global:LASTEXITCODE -is [int]) {
            $exitCode = $global:LASTEXITCODE
        }
    }
    catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = @($output)
        Stderr = @()
        Output = @($output)
    }
}

function Get-DevcontainerConfigLabelPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    $devcontainerDirectory = Join-Path -Path $WorkspacePath -ChildPath ".devcontainer"
    return (Join-Path -Path $devcontainerDirectory -ChildPath "devcontainer.json")
}

function Test-ContainerHasManagedWaylandMount {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Container
    )

    $state = Get-ObjectPropertyValue -InputObject $Container -Name "State"
    if ($null -eq $state) {
        return $false
    }

    $status = [string](Get-ObjectPropertyValue -InputObject $state -Name "Status")
    if ($status -notin @("created", "exited")) {
        return $false
    }

    $mounts = @(Get-ObjectPropertyValue -InputObject $Container -Name "Mounts")
    foreach ($mount in $mounts) {
        if ($null -eq $mount) {
            continue
        }

        $type = [string](Get-ObjectPropertyValue -InputObject $mount -Name "Type")
        $destination = [string](Get-ObjectPropertyValue -InputObject $mount -Name "Destination")
        if ([string]::IsNullOrWhiteSpace($destination)) {
            $destination = [string](Get-ObjectPropertyValue -InputObject $mount -Name "Target")
        }

        if ($type -eq "bind" -and $destination -match '^/tmp/vscode-wayland-[^/]+\.sock$') {
            return $true
        }
    }

    return $false
}

if (-not (Test-HostCleanupEnabled)) {
    Write-DevcontainerHostLog "Host stale-container cleanup disabled by WALLSTOP_DEVCONTAINER_HOST_CLEANUP."
    return
}

$dockerPath = Resolve-DockerCommandPath
if ([string]::IsNullOrWhiteSpace($dockerPath)) {
    return
}

if ([string]::IsNullOrWhiteSpace($WorkspaceFolder)) {
    Write-DevcontainerHostWarning "W_DEVCONTAINER_HOST_WORKSPACE_MISSING: WorkspaceFolder is empty; stale devcontainer cleanup skipped."
    return
}

$configFile = Get-DevcontainerConfigLabelPath -WorkspacePath $WorkspaceFolder
$psArguments = @(
    "ps",
    "-q",
    "-a",
    "--filter",
    "label=devcontainer.local_folder=$WorkspaceFolder",
    "--filter",
    "label=devcontainer.config_file=$configFile"
)
$psResult = Invoke-DockerCommand -DockerPath $dockerPath -Arguments $psArguments
if ($psResult.ExitCode -ne 0) {
    Write-DevcontainerHostWarning ("W_DEVCONTAINER_HOST_DOCKER_PS_FAILED: docker ps failed; stale devcontainer cleanup skipped. output={0}" -f (($psResult.Output | Select-Object -First 3) -join " "))
    return
}

$containerIds = @(
    $psResult.Output |
        ForEach-Object { [string]$_ } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

foreach ($containerId in $containerIds) {
    $inspectResult = Invoke-DockerCommand -DockerPath $dockerPath -Arguments @("inspect", "--type", "container", $containerId)
    if ($inspectResult.ExitCode -ne 0) {
        Write-DevcontainerHostWarning ("W_DEVCONTAINER_HOST_DOCKER_INSPECT_FAILED: docker inspect failed for container '$containerId'; skipping. output={0}" -f (($inspectResult.Output | Select-Object -First 3) -join " "))
        continue
    }

    $inspectJson = ($inspectResult.Stdout | ForEach-Object { [string]$_ }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($inspectJson)) {
        continue
    }

    $containers = @($inspectJson | ConvertFrom-Json)
    foreach ($container in $containers) {
        if (-not (Test-ContainerHasManagedWaylandMount -Container $container)) {
            continue
        }

        Write-DevcontainerHostLog "Removing stopped devcontainer '$containerId' with a stale VS Code Wayland socket bind mount."
        $rmResult = Invoke-DockerCommand -DockerPath $dockerPath -Arguments @("rm", $containerId)
        if ($rmResult.ExitCode -ne 0) {
            throw ("E_DEVCONTAINER_HOST_STALE_CONTAINER_REMOVE_FAILED: docker rm failed for stale devcontainer '$containerId'. output={0}" -f (($rmResult.Output | Select-Object -First 5) -join " "))
        }
    }
}
