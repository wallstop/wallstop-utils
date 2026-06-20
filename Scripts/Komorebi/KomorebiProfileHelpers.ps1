$canonicalJsonHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Utils/Common/CanonicalJsonHelpers.ps1"
if (-not (Test-Path -LiteralPath $canonicalJsonHelpersPath -PathType Leaf)) {
    throw "E_KOMOREBI_CANONICAL_JSON_HELPER_MISSING: canonical JSON helper file not found at '$canonicalJsonHelpersPath'."
}

. $canonicalJsonHelpersPath

function Get-KomorebiRequiredConfigFileNames {
    [OutputType([string[]])]
    param()

    return "komorebi.json", "komorebi.bar.json", "applications.json"
}

function Get-KomorebiLegacyRootConfigFileNames {
    [OutputType([string[]])]
    param()

    return "komorebi.json", "komorebi.bar.json", "applications.yaml"
}

function Assert-KomorebiProfileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName
    )

    $reservedNames = @("con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9")
    $profileBaseName = if ($ProfileName -match '^(?<name>[^.]+)') { $Matches["name"] } else { $ProfileName }
    if ($ProfileName -cnotmatch '^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$' -or $ProfileName -match '\.\.' -or $reservedNames -contains $profileBaseName) {
        throw (
            "E_KOMOREBI_PROFILE_NAME_INVALID: Komorebi profile name '{0}' must be lowercase, 1-64 characters, start and end with an alphanumeric character, avoid reserved Windows device names, and contain only letters, numbers, '.', '_' or '-'." -f
            $ProfileName
        )
    }
}

function ConvertTo-KomorebiMachineProfileName {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineName
    )

    $normalized = $MachineName.Trim().ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[^a-z0-9._-]+', '-')
    $normalized = [regex]::Replace($normalized, '-{2,}', '-')
    $normalized = $normalized.Trim('-', '_', '.')

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "E_KOMOREBI_PROFILE_NAME_UNAVAILABLE: Unable to derive a Komorebi profile name from the current machine name."
    }

    if ($normalized.Length -gt 64) {
        $normalized = $normalized.Substring(0, 64).Trim('-', '_', '.')
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "E_KOMOREBI_PROFILE_NAME_UNAVAILABLE: Unable to derive a Komorebi profile name from the current machine name after normalization."
    }

    Assert-KomorebiProfileName -ProfileName $normalized
    return $normalized
}

function Resolve-KomorebiProfileSelection {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$EnvironmentProfileName = $env:WALLSTOP_KOMOREBI_PROFILE,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$MachineName = [Environment]::MachineName
    )

    if (-not [string]::IsNullOrWhiteSpace($ProfileName)) {
        $candidate = $ProfileName.Trim()
        Assert-KomorebiProfileName -ProfileName $candidate
        return [pscustomobject]@{
            Name       = $candidate
            Source     = "parameter"
            IsExplicit = $true
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentProfileName)) {
        $candidate = $EnvironmentProfileName.Trim()
        Assert-KomorebiProfileName -ProfileName $candidate
        return [pscustomobject]@{
            Name       = $candidate
            Source     = "environment"
            IsExplicit = $true
        }
    }

    if ([string]::IsNullOrWhiteSpace($MachineName)) {
        throw "E_KOMOREBI_PROFILE_NAME_UNAVAILABLE: No -ProfileName, WALLSTOP_KOMOREBI_PROFILE, or machine name was available for Komorebi profile selection."
    }

    return [pscustomobject]@{
        Name       = ConvertTo-KomorebiMachineProfileName -MachineName $MachineName
        Source     = "machine"
        IsExplicit = $false
    }
}

function Resolve-KomorebiExistingDirectory {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ErrorCode,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw ("{0}: Komorebi {1} directory not found at '{2}'." -f $ErrorCode, $Description, $Path)
    }

    return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Resolve-KomorebiRepositoryRoot {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    return Resolve-KomorebiExistingDirectory -Path $RepositoryRoot -ErrorCode "E_KOMOREBI_REPOSITORY_ROOT_MISSING" -Description "repository root"
}

function Resolve-KomorebiUserProfileRoot {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$UserProfileRoot
    )

    $candidate = $UserProfileRoot
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $HOME
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw "E_KOMOREBI_USER_PROFILE_UNAVAILABLE: Unable to resolve a user profile directory for Komorebi config files."
    }

    return Resolve-KomorebiExistingDirectory -Path $candidate -ErrorCode "E_KOMOREBI_USER_PROFILE_MISSING" -Description "user profile"
}

function Get-KomorebiConfigRoot {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $configRoot = Join-Path -Path $RepositoryRoot -ChildPath "Config"
    return Join-Path -Path $configRoot -ChildPath "Komorebi"
}

function Get-KomorebiProfilesRoot {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    return Join-Path -Path (Get-KomorebiConfigRoot -RepositoryRoot $RepositoryRoot) -ChildPath "profiles"
}

function Get-KomorebiProfileDirectory {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName
    )

    Assert-KomorebiProfileName -ProfileName $ProfileName
    return Join-Path -Path (Get-KomorebiProfilesRoot -RepositoryRoot $RepositoryRoot) -ChildPath $ProfileName
}

function Get-KomorebiSnapshotMissingFiles {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $missingFiles = New-Object System.Collections.Generic.List[string]
    foreach ($fileName in Get-KomorebiRequiredConfigFileNames) {
        $path = Join-Path -Path $Directory -ChildPath $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$missingFiles.Add($fileName)
        }
    }

    return $missingFiles.ToArray()
}

function Get-KomorebiSnapshotDirectoryState {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $exists = Test-Path -LiteralPath $Directory -PathType Container
    $missingFiles = @(
        if ($exists) {
            Get-KomorebiSnapshotMissingFiles -Directory $Directory
        }
        else {
            Get-KomorebiRequiredConfigFileNames
        }
    )

    return [pscustomobject]@{
        Directory = $Directory
        Exists    = $exists
        Missing   = @($missingFiles)
        IsComplete = ($exists -and $missingFiles.Count -eq 0)
    }
}

function Assert-KomorebiSnapshotDirectoryComplete {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$ErrorCode,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $state = Get-KomorebiSnapshotDirectoryState -Directory $Directory
    if (-not $state.IsComplete) {
        throw (
            "{0}: Missing required Komorebi {1} file(s) under '{2}': {3}" -f
            $ErrorCode,
            $Context,
            $Directory,
            ($state.Missing -join ", ")
        )
    }
}

function Assert-KomorebiSnapshotJsonValid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$ErrorCode,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    foreach ($fileName in Get-KomorebiRequiredConfigFileNames) {
        $path = Join-Path -Path $Directory -ChildPath $fileName
        try {
            $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $null = $content | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw (
                "{0}: Invalid JSON in Komorebi {1} file '{2}': {3}" -f
                $ErrorCode,
                $Context,
                $path,
                $_.Exception.Message
            )
        }
    }
}

function ConvertFrom-KomorebiLegacyYamlScalar {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2 -and (($trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) -or ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')))) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }

    return $trimmed
}

function New-KomorebiLegacyMatcherObject {
    [OutputType([ordered])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    foreach ($key in @("kind", "id", "matching_strategy")) {
        if (-not $Values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$Values[$key])) {
            if ($key -eq "id" -and $Values.ContainsKey($key)) {
                continue
            }

            throw "E_KOMOREBI_MIGRATION_YAML_INVALID: Legacy applications.yaml matcher is missing required key '$key'."
        }
    }

    return [ordered]@{
        kind              = [string]$Values["kind"]
        id                = [string]$Values["id"]
        matching_strategy = [string]$Values["matching_strategy"]
    }
}

function Get-KomorebiLegacyYamlAppBlocks {
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines
    )

    $blocks = New-Object System.Collections.Generic.List[object]
    $currentName = $null
    $currentLines = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        $match = [regex]::Match($line, '^- name:\s*(?<name>.+?)\s*$')
        if ($match.Success) {
            if (-not [string]::IsNullOrWhiteSpace($currentName)) {
                [void]$blocks.Add([pscustomobject]@{
                        Name  = $currentName
                        Lines = @($currentLines.ToArray())
                    })
            }

            $currentName = ConvertFrom-KomorebiLegacyYamlScalar -Value $match.Groups["name"].Value
            $currentLines = New-Object System.Collections.Generic.List[string]
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($currentName)) {
            [void]$currentLines.Add($line)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($currentName)) {
        [void]$blocks.Add([pscustomobject]@{
                Name  = $currentName
                Lines = @($currentLines.ToArray())
            })
    }

    return $blocks.ToArray()
}

function Get-KomorebiLegacyYamlIdentifier {
    [OutputType([ordered])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines,

        [Parameter(Mandatory = $true)]
        [string]$AppName
    )

    $identifierIndex = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^  identifier:\s*$') {
            $identifierIndex = $index
            break
        }
    }

    if ($identifierIndex -lt 0) {
        throw "E_KOMOREBI_MIGRATION_YAML_INVALID: Legacy applications.yaml app '$AppName' is missing an identifier block."
    }

    $values = @{}
    for ($index = $identifierIndex + 1; $index -lt $Lines.Count; $index++) {
        $line = $Lines[$index]
        if ($line -notmatch '^    (?<key>kind|id|matching_strategy):\s*(?<value>.*)$') {
            break
        }

        $values[$Matches["key"]] = ConvertFrom-KomorebiLegacyYamlScalar -Value $Matches["value"]
    }

    return New-KomorebiLegacyMatcherObject -Values $values
}

function Get-KomorebiLegacyYamlOptions {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines
    )

    $options = New-Object System.Collections.Generic.List[string]
    $optionsIndex = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^  options:\s*$') {
            $optionsIndex = $index
            break
        }
    }

    if ($optionsIndex -lt 0) {
        return $options.ToArray()
    }

    for ($index = $optionsIndex + 1; $index -lt $Lines.Count; $index++) {
        $line = $Lines[$index]
        if ($line -notmatch '^  - (?<value>.+?)\s*$') {
            break
        }

        [void]$options.Add((ConvertFrom-KomorebiLegacyYamlScalar -Value $Matches["value"]))
    }

    return $options.ToArray()
}

function Read-KomorebiLegacyMatcherAtIndex {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines,

        [Parameter(Mandatory = $true)]
        [int]$Index,

        [Parameter(Mandatory = $true)]
        [string]$KindPattern,

        [Parameter(Mandatory = $true)]
        [string]$ContinuationPattern
    )

    $line = $Lines[$Index]
    $match = [regex]::Match($line, $KindPattern)
    if (-not $match.Success) {
        throw "E_KOMOREBI_MIGRATION_YAML_INVALID: Legacy applications.yaml matcher line has unexpected shape: '$line'."
    }

    $values = @{
        kind = ConvertFrom-KomorebiLegacyYamlScalar -Value $match.Groups["kind"].Value
    }

    $nextIndex = $Index + 1
    while ($nextIndex -lt $Lines.Count) {
        $continuationMatch = [regex]::Match($Lines[$nextIndex], $ContinuationPattern)
        if (-not $continuationMatch.Success) {
            break
        }

        $values[$continuationMatch.Groups["key"].Value] = ConvertFrom-KomorebiLegacyYamlScalar -Value $continuationMatch.Groups["value"].Value
        $nextIndex++
    }

    return [pscustomobject]@{
        Matcher = New-KomorebiLegacyMatcherObject -Values $values
        NextIndex = $nextIndex
    }
}

function Get-KomorebiLegacyYamlFloatIdentifiers {
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines
    )

    $floatIndex = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^  float_identifiers:\s*$') {
            $floatIndex = $index
            break
        }
    }

    $identifiers = New-Object System.Collections.Generic.List[object]
    if ($floatIndex -lt 0) {
        return $identifiers.ToArray()
    }

    $index = $floatIndex + 1
    while ($index -lt $Lines.Count) {
        $line = $Lines[$index]
        if ($line -match '^  - - kind:\s*(?<kind>.+?)\s*$') {
            $compound = New-Object System.Collections.Generic.List[object]
            $first = Read-KomorebiLegacyMatcherAtIndex -Lines $Lines -Index $index -KindPattern '^  - - kind:\s*(?<kind>.+?)\s*$' -ContinuationPattern '^      (?<key>id|matching_strategy):\s*(?<value>.*)$'
            [void]$compound.Add($first.Matcher)
            $index = $first.NextIndex

            while ($index -lt $Lines.Count -and $Lines[$index] -match '^    - kind:\s*(?<kind>.+?)\s*$') {
                $next = Read-KomorebiLegacyMatcherAtIndex -Lines $Lines -Index $index -KindPattern '^    - kind:\s*(?<kind>.+?)\s*$' -ContinuationPattern '^      (?<key>id|matching_strategy):\s*(?<value>.*)$'
                [void]$compound.Add($next.Matcher)
                $index = $next.NextIndex
            }

            [void]$identifiers.Add(@($compound.ToArray()))
            continue
        }

        if ($line -match '^  - kind:\s*(?<kind>.+?)\s*$') {
            $simple = Read-KomorebiLegacyMatcherAtIndex -Lines $Lines -Index $index -KindPattern '^  - kind:\s*(?<kind>.+?)\s*$' -ContinuationPattern '^    (?<key>id|matching_strategy):\s*(?<value>.*)$'
            [void]$identifiers.Add($simple.Matcher)
            $index = $simple.NextIndex
            continue
        }

        break
    }

    return $identifiers.ToArray()
}

function Convert-KomorebiLegacyApplicationsYamlToJsonText {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YamlPath
    )

    $lines = [System.IO.File]::ReadAllLines($YamlPath, [System.Text.Encoding]::UTF8)
    $appBlocks = @(Get-KomorebiLegacyYamlAppBlocks -Lines $lines)
    if ($appBlocks.Count -eq 0) {
        throw "E_KOMOREBI_MIGRATION_YAML_INVALID: Legacy applications.yaml contains no app entries."
    }

    $output = [ordered]@{
        '$schema' = "https://raw.githubusercontent.com/LGUG2Z/komorebi/master/schema.asc.json"
    }

    foreach ($appBlock in $appBlocks) {
        $identifier = Get-KomorebiLegacyYamlIdentifier -Lines $appBlock.Lines -AppName $appBlock.Name
        $options = @(Get-KomorebiLegacyYamlOptions -Lines $appBlock.Lines)
        $floatIdentifiers = @(Get-KomorebiLegacyYamlFloatIdentifiers -Lines $appBlock.Lines)
        $appConfig = [ordered]@{}

        foreach ($option in $options) {
            switch ($option) {
                "force" {
                    $appConfig["manage"] = @($identifier)
                }
                { $_ -in @("tray_and_multi_window", "object_name_change", "layered") } {
                    $appConfig[$option] = @($identifier)
                }
                default {
                    throw "E_KOMOREBI_MIGRATION_YAML_INVALID: Legacy applications.yaml app '$($appBlock.Name)' has unsupported option '$option'."
                }
            }
        }

        if ($floatIdentifiers.Count -gt 0) {
            $appConfig["ignore"] = @($floatIdentifiers)
        }

        if ($appConfig.Count -gt 0) {
            $output[$appBlock.Name] = $appConfig
        }
    }

    return ($output | ConvertTo-Json -Depth 32)
}

function Write-KomorebiConfigForJsonApplications {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    try {
        $config = [System.IO.File]::ReadAllText($SourcePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "E_KOMOREBI_MIGRATION_JSON_INVALID: Legacy Komorebi config '$SourcePath' is invalid JSON. $($_.Exception.Message)"
    }

    $config.app_specific_configuration_path = ('$Env' + ':USERPROFILE/applications.json')
    $jsonText = $config | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText($DestinationPath, $jsonText, [System.Text.UTF8Encoding]::new($false))
}

function Copy-KomorebiSnapshotFiles {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,

        [Parameter(Mandatory = $true)]
        [string]$MissingErrorCode,

        [Parameter(Mandatory = $true)]
        [string]$InvalidJsonErrorCode,

        [Parameter(Mandatory = $true)]
        [string]$CopyErrorCode,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    Assert-KomorebiSnapshotDirectoryComplete -Directory $SourceDirectory -ErrorCode $MissingErrorCode -Context $Context
    Assert-KomorebiSnapshotJsonValid -Directory $SourceDirectory -ErrorCode $InvalidJsonErrorCode -Context $Context

    try {
        return Update-KomorebiSnapshotFilesTransactionally `
            -SourceDirectory $SourceDirectory `
            -DestinationDirectory $DestinationDirectory `
            -CopyErrorCode $CopyErrorCode `
            -RollbackErrorCode "E_KOMOREBI_PROFILE_ROLLBACK_FAILED" `
            -Context $Context `
            -RemoveEmptyDestinationOnFailure
    }
    catch {
        if (Test-Path -LiteralPath $DestinationDirectory -PathType Container) {
            $remainingItems = @(Get-ChildItem -LiteralPath $DestinationDirectory -Force -ErrorAction Stop)
            if ($remainingItems.Count -eq 0) {
                Remove-Item -LiteralPath $DestinationDirectory -Force -ErrorAction Stop
            }
        }

        throw
    }
}

function Update-KomorebiSnapshotFilesTransactionally {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,

        [Parameter(Mandatory = $true)]
        [string]$CopyErrorCode,

        [Parameter(Mandatory = $true)]
        [string]$RollbackErrorCode,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter(Mandatory = $false)]
        [switch]$RemoveEmptyDestinationOnFailure
    )

    $destinationExistedBeforeTransaction = Test-Path -LiteralPath $DestinationDirectory -PathType Container
    try {
        [System.IO.Directory]::CreateDirectory($DestinationDirectory) | Out-Null
    }
    catch {
        throw (
            "{0}: Failed to create Komorebi destination directory '{1}': {2}" -f
            $CopyErrorCode,
            $DestinationDirectory,
            $_.Exception.Message
        )
    }

    $transactionRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("komorebi-restore-" + [System.Guid]::NewGuid().ToString("N"))
    $stagingDirectory = Join-Path -Path $transactionRoot -ChildPath "staging"
    $backupDirectory = Join-Path -Path $transactionRoot -ChildPath "backup"
    $copiedFiles = New-Object System.Collections.Generic.List[string]

    try {
        [System.IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
        [System.IO.Directory]::CreateDirectory($backupDirectory) | Out-Null

        foreach ($fileName in Get-KomorebiRequiredConfigFileNames) {
            $sourcePath = Join-Path -Path $SourceDirectory -ChildPath $fileName
            $stagedPath = Join-Path -Path $stagingDirectory -ChildPath $fileName
            Copy-Item -LiteralPath $sourcePath -Destination $stagedPath -Force -ErrorAction Stop
            # Canonicalize the staged JSON so the bytes the transaction commits are byte-identical to the
            # pretty-format-json hook output. Komorebi (and the live OS) emit their own indentation/line
            # endings; without this an unattended `--no-verify` backup would land non-canonical bytes that
            # conflict on every line with an attended/hook commit. Canonicalizing on the staged copy keeps
            # the source untouched and applies uniformly to backup, restore, and legacy migration.
            if ([System.IO.Path]::GetExtension($stagedPath) -eq ".json") {
                [void](Write-CanonicalJsonFile -Path $stagedPath)
            }
        }

        foreach ($fileName in Get-KomorebiRequiredConfigFileNames) {
            $destinationPath = Join-Path -Path $DestinationDirectory -ChildPath $fileName
            if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
                $backupPath = Join-Path -Path $backupDirectory -ChildPath $fileName
                Copy-Item -LiteralPath $destinationPath -Destination $backupPath -Force -ErrorAction Stop
            }
        }

        try {
            foreach ($fileName in Get-KomorebiRequiredConfigFileNames) {
                $stagedPath = Join-Path -Path $stagingDirectory -ChildPath $fileName
                $destinationPath = Join-Path -Path $DestinationDirectory -ChildPath $fileName
                Copy-Item -LiteralPath $stagedPath -Destination $destinationPath -Force -ErrorAction Stop
                [void]$copiedFiles.Add($destinationPath)
            }
        }
        catch {
            $restoreErrorMessage = $_.Exception.Message
            try {
                foreach ($fileName in Get-KomorebiRequiredConfigFileNames) {
                    $destinationPath = Join-Path -Path $DestinationDirectory -ChildPath $fileName
                    $backupPath = Join-Path -Path $backupDirectory -ChildPath $fileName
                    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                        Copy-Item -LiteralPath $backupPath -Destination $destinationPath -Force -ErrorAction Stop
                    }
                    elseif (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
                        Remove-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
                    }
                }

                if ($RemoveEmptyDestinationOnFailure.IsPresent -and (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
                    $remainingItems = @(Get-ChildItem -LiteralPath $DestinationDirectory -Force -ErrorAction Stop)
                    if ($remainingItems.Count -eq 0) {
                        Remove-Item -LiteralPath $DestinationDirectory -Force -ErrorAction Stop
                    }
                }
                elseif (-not $destinationExistedBeforeTransaction -and (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
                    Remove-Item -LiteralPath $DestinationDirectory -Recurse -Force -ErrorAction Stop
                }
            }
            catch {
                throw (
                    "{0}: Komorebi {1} copy failed and rollback also failed (destination='{2}'; copyError='{3}'; rollbackError='{4}')." -f
                    $RollbackErrorCode,
                    $Context,
                    $DestinationDirectory,
                    $restoreErrorMessage,
                    $_.Exception.Message
                )
            }

            throw (
                "{0}: Failed to copy Komorebi {1} files to '{2}'. Rollback restored previous destination state. originalError='{3}'." -f
                $CopyErrorCode,
                $Context,
                $DestinationDirectory,
                $restoreErrorMessage
            )
        }
    }
    catch {
        if ($_.Exception.Message -match '^E_KOMOREBI_') {
            throw
        }

        throw (
            "{0}: Failed during Komorebi {1} transaction for destination '{2}': {3}" -f
            $CopyErrorCode,
            $Context,
            $DestinationDirectory,
            $_.Exception.Message
        )
    }
    finally {
        if (Test-Path -LiteralPath $transactionRoot -PathType Container) {
            Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $copiedFiles.ToArray()
}

function Restore-KomorebiSnapshotFiles {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    Assert-KomorebiSnapshotDirectoryComplete -Directory $SourceDirectory -ErrorCode "E_KOMOREBI_RESTORE_SOURCE_MISSING" -Context "restore source"
    Assert-KomorebiSnapshotJsonValid -Directory $SourceDirectory -ErrorCode "E_KOMOREBI_RESTORE_JSON_INVALID" -Context "restore source"

    return Update-KomorebiSnapshotFilesTransactionally `
        -SourceDirectory $SourceDirectory `
        -DestinationDirectory $DestinationDirectory `
        -CopyErrorCode "E_KOMOREBI_RESTORE_COPY_FAILED" `
        -RollbackErrorCode "E_KOMOREBI_RESTORE_ROLLBACK_FAILED" `
        -Context "restore"
}

function Resolve-KomorebiRestoreSourceDirectory {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Selection
    )

    $profileDirectory = Get-KomorebiProfileDirectory -RepositoryRoot $RepositoryRoot -ProfileName $Selection.Name
    $profileState = Get-KomorebiSnapshotDirectoryState -Directory $profileDirectory
    if ($profileState.IsComplete) {
        return [pscustomobject]@{
            Directory     = $profileDirectory
            ProfileName   = $Selection.Name
            ProfileSource = $Selection.Source
        }
    }

    if ($profileState.Exists) {
        throw (
            "E_KOMOREBI_RESTORE_PROFILE_INCOMPLETE: Komorebi profile '{0}' exists at '{1}' but is missing required file(s): {2}" -f
            $Selection.Name,
            $profileDirectory,
            ($profileState.Missing -join ", ")
        )
    }

    throw (
        "E_KOMOREBI_RESTORE_PROFILE_MISSING: Komorebi profile '{0}' selected by {1} was not found at '{2}'. Restore will not silently fall back to another machine, default profile, or legacy root snapshot." -f
        $Selection.Name,
        $Selection.Source,
        $profileDirectory
    )
}

function Invoke-KomorebiProfileBackup {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$UserProfileRoot,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$EnvironmentProfileName = $env:WALLSTOP_KOMOREBI_PROFILE,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$MachineName = [Environment]::MachineName
    )

    $resolvedRepositoryRoot = Resolve-KomorebiRepositoryRoot -RepositoryRoot $RepositoryRoot
    $resolvedUserProfileRoot = Resolve-KomorebiUserProfileRoot -UserProfileRoot $UserProfileRoot
    $selection = Resolve-KomorebiProfileSelection -ProfileName $ProfileName -EnvironmentProfileName $EnvironmentProfileName -MachineName $MachineName
    $profileDirectory = Get-KomorebiProfileDirectory -RepositoryRoot $resolvedRepositoryRoot -ProfileName $selection.Name

    $copiedFiles = Copy-KomorebiSnapshotFiles `
        -SourceDirectory $resolvedUserProfileRoot `
        -DestinationDirectory $profileDirectory `
        -MissingErrorCode "E_KOMOREBI_BACKUP_SOURCE_MISSING" `
        -InvalidJsonErrorCode "E_KOMOREBI_BACKUP_JSON_INVALID" `
        -CopyErrorCode "E_KOMOREBI_BACKUP_COPY_FAILED" `
        -Context "backup source"

    return [pscustomobject]@{
        ProfileName      = $selection.Name
        ProfileSource    = $selection.Source
        ProfileDirectory = $profileDirectory
        CopiedFiles      = @($copiedFiles)
    }
}

function Initialize-KomorebiProfileFromLegacyRoot {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$EnvironmentProfileName = $env:WALLSTOP_KOMOREBI_PROFILE,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$MachineName = [Environment]::MachineName,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    $resolvedRepositoryRoot = Resolve-KomorebiRepositoryRoot -RepositoryRoot $RepositoryRoot
    $selection = Resolve-KomorebiProfileSelection -ProfileName $ProfileName -EnvironmentProfileName $EnvironmentProfileName -MachineName $MachineName
    $legacyDirectory = Get-KomorebiConfigRoot -RepositoryRoot $resolvedRepositoryRoot
    $profileDirectory = Get-KomorebiProfileDirectory -RepositoryRoot $resolvedRepositoryRoot -ProfileName $selection.Name

    if ((Test-Path -LiteralPath $profileDirectory -PathType Container) -and -not $Force.IsPresent) {
        throw (
            "E_KOMOREBI_PROFILE_ALREADY_EXISTS: Komorebi profile '{0}' already exists at '{1}'. Pass -Force to overwrite it from the legacy root snapshot." -f
            $selection.Name,
            $profileDirectory
        )
    }

    $legacyMissing = New-Object System.Collections.Generic.List[string]
    foreach ($fileName in Get-KomorebiLegacyRootConfigFileNames) {
        $path = Join-Path -Path $legacyDirectory -ChildPath $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$legacyMissing.Add($fileName)
        }
    }

    if ($legacyMissing.Count -gt 0) {
        throw (
            "E_KOMOREBI_MIGRATION_SOURCE_MISSING: Missing required legacy Komorebi migration file(s) under '{0}': {1}" -f
            $legacyDirectory,
            ($legacyMissing -join ", ")
        )
    }

    $migrationSourceRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("komorebi-migration-source-" + [System.Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.Directory]::CreateDirectory($migrationSourceRoot) | Out-Null
        $legacyConfigPath = Join-Path -Path $legacyDirectory -ChildPath "komorebi.json"
        $legacyBarPath = Join-Path -Path $legacyDirectory -ChildPath "komorebi.bar.json"
        $legacyApplicationsYamlPath = Join-Path -Path $legacyDirectory -ChildPath "applications.yaml"

        Write-KomorebiConfigForJsonApplications -SourcePath $legacyConfigPath -DestinationPath (Join-Path -Path $migrationSourceRoot -ChildPath "komorebi.json")
        Copy-Item -LiteralPath $legacyBarPath -Destination (Join-Path -Path $migrationSourceRoot -ChildPath "komorebi.bar.json") -Force -ErrorAction Stop

        $applicationsJson = Convert-KomorebiLegacyApplicationsYamlToJsonText -YamlPath $legacyApplicationsYamlPath
        [System.IO.File]::WriteAllText(
            (Join-Path -Path $migrationSourceRoot -ChildPath "applications.json"),
            $applicationsJson,
            [System.Text.UTF8Encoding]::new($false)
        )

        $copiedFiles = Copy-KomorebiSnapshotFiles `
            -SourceDirectory $migrationSourceRoot `
            -DestinationDirectory $profileDirectory `
            -MissingErrorCode "E_KOMOREBI_MIGRATION_SOURCE_MISSING" `
            -InvalidJsonErrorCode "E_KOMOREBI_MIGRATION_JSON_INVALID" `
            -CopyErrorCode "E_KOMOREBI_MIGRATION_COPY_FAILED" `
            -Context "legacy migration source"
    }
    catch {
        if ($_.Exception.Message -match '^E_KOMOREBI_') {
            throw
        }

        throw "E_KOMOREBI_MIGRATION_COPY_FAILED: Failed to prepare or copy legacy Komorebi migration snapshot from '$legacyDirectory' to '$profileDirectory'. $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $migrationSourceRoot -PathType Container) {
            Remove-Item -LiteralPath $migrationSourceRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        ProfileName      = $selection.Name
        ProfileSource    = $selection.Source
        ProfileDirectory = $profileDirectory
        CopiedFiles      = @($copiedFiles)
    }
}

function Invoke-KomorebiProfileRestore {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$UserProfileRoot,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$EnvironmentProfileName = $env:WALLSTOP_KOMOREBI_PROFILE,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$MachineName = [Environment]::MachineName
    )

    $resolvedRepositoryRoot = Resolve-KomorebiRepositoryRoot -RepositoryRoot $RepositoryRoot
    $resolvedUserProfileRoot = Resolve-KomorebiUserProfileRoot -UserProfileRoot $UserProfileRoot
    $selection = Resolve-KomorebiProfileSelection -ProfileName $ProfileName -EnvironmentProfileName $EnvironmentProfileName -MachineName $MachineName
    $source = Resolve-KomorebiRestoreSourceDirectory -RepositoryRoot $resolvedRepositoryRoot -Selection $selection

    $copiedFiles = Restore-KomorebiSnapshotFiles -SourceDirectory $source.Directory -DestinationDirectory $resolvedUserProfileRoot

    return [pscustomobject]@{
        ProfileName      = $source.ProfileName
        ProfileSource    = $source.ProfileSource
        ProfileDirectory = $source.Directory
        UserProfileRoot  = $resolvedUserProfileRoot
        CopiedFiles      = @($copiedFiles)
    }
}
