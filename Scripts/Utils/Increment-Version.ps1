<#
.SYNOPSIS
  Increments the version in a package.json file found in the current or parent directories.

.DESCRIPTION
  This script searches for a 'package.json' file by traversing upwards from the current directory.
  It reads the 'version' field, increments it according to SemVer rules, and writes the changes back.
  Supports standard increments, pre-release increments, and promotion of pre-releases to releases.

  You can display a quick help summary by running:
    Increment-Version help
    Increment-Version --help
    Increment-Version /?

.PARAMETER PromoteToRelease
  If specified, and the current version is a pre-release (e.g., X.Y.Z-rc.N), it will be promoted
  to the release version X.Y.Z. If the current version is already a release (e.g., X.Y.Z),
  its patch component will be incremented (e.g., to X.Y.(Z+1)).

.PARAMETER HelpArgument
  Used to trigger the built-in help summary. Pass 'help', '--help', or '/?' as the first argument.
  This parameter is primarily for the custom help invocation and not meant for other values.

.EXAMPLE
  Increment-Version
  # Increments the version normally (e.g., 1.0.0 -> 1.0.1, or 1.0.0-rc.1 -> 1.0.0-rc.2).

.EXAMPLE
  Increment-Version -PromoteToRelease
  # Promotes a pre-release to release (e.g., 1.0.0-rc.2 -> 1.0.0) or increments patch of a release.

.EXAMPLE
  Increment-Version -WhatIf
  # Shows the intended version change without modifying the file.

.EXAMPLE
  Increment-Version help
  # Displays the built-in quick help summary with color coding.

.INPUTS
  None. You cannot pipe objects to this cmdlet.

.OUTPUTS
  System.Void. This cmdlet does not generate any output to the pipeline beyond status messages or errors.

.NOTES
  Author: Google AI Assistant
  Version: 1.4 (as of 2025-05-06)
  For full PowerShell integrated help, use: Get-Help Increment-Version -Full

.LINK
  Get-Help
  about_Comment_Based_Help
#>
function Increment-Version {
    [CmdletBinding(SupportsShouldProcess=$true)]
    [OutputType([void])]
    param (
        [Parameter(Position=0, Mandatory=$false, HelpMessage="Type 'help', '--help', or '/?' to display built-in help summary.")]
        [string]$HelpArgument,

        [Parameter(Mandatory=$false)] # Detailed help for this parameter is in the comment-based help block above
        [switch]$PromoteToRelease
    )

    # Check for custom help invocation first
    if ($PSBoundParameters.ContainsKey('HelpArgument')) {
        $helpTriggers = @('help', '--help', '/?')
        if ($helpTriggers -contains $HelpArgument.ToLowerInvariant()) {
            
            # Define colors for help text
            $headerColor = "Yellow"
            $commandColor = "Green"
            $paramColor = "Cyan"
            $placeholderColor = "Gray" # Using Gray for better visibility on various backgrounds

            Write-Host "Increment-Version Script Quick Help:" # Default color for main title
            Write-Host "------------------------------------" # Default color
            Write-Host # Blank line

            Write-Host "SYNOPSIS" -ForegroundColor $headerColor
            Write-Host "  Increments the version in a package.json file found in the current or parent directories."
            Write-Host # Blank line

            Write-Host "SYNTAX" -ForegroundColor $headerColor
            Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
            Write-Host -NoNewline " ["; Write-Host "-PromoteToRelease" -ForegroundColor $paramColor -NoNewline; Write-Host -NoNewline "]"
            Write-Host -NoNewline " ["; Write-Host "-WhatIf" -ForegroundColor $paramColor -NoNewline; Write-Host -NoNewline "]"
            Write-Host -NoNewline " ["; Write-Host "-Confirm" -ForegroundColor $paramColor -NoNewline; Write-Host -NoNewline "]"
            Write-Host -NoNewline " ["; Write-Host "<CommonParameters>" -ForegroundColor $placeholderColor -NoNewline; Write-Host "]"

            Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
            Write-Host -NoNewline " [ "; Write-Host "help" -ForegroundColor $paramColor -NoNewline
            Write-Host -NoNewline " | "; Write-Host "--help" -ForegroundColor $paramColor -NoNewline
            Write-Host -NoNewline " | "; Write-Host "/?" -ForegroundColor $paramColor -NoNewline; Write-Host " ]"
            Write-Host # Blank line

            Write-Host "DESCRIPTION" -ForegroundColor $headerColor
            Write-Host "  This script searches for a 'package.json' file by traversing upwards from the current directory."
            Write-Host "  It reads the 'version' field, increments it according to SemVer rules, and writes the changes back."
            Write-Host "  Supports standard increments, pre-release increments, and promotion of pre-releases to releases."
            Write-Host # Blank line

            Write-Host "PARAMETERS" -ForegroundColor $headerColor
            Write-Host -NoNewline "  "; Write-Host "-PromoteToRelease" -ForegroundColor $paramColor
            Write-Host "    If specified, and the current version is a pre-release (e.g., X.Y.Z-rc.N), it will be promoted"
            Write-Host "    to the release version X.Y.Z. If the current version is already a release (e.g., X.Y.Z),"
            Write-Host "    its patch component will be incremented (e.g., to X.Y.(Z+1))."
            Write-Host # Blank line for spacing before next parameter
            Write-Host -NoNewline "  "; Write-Host "help" -ForegroundColor $paramColor -NoNewline
            Write-Host -NoNewline " | "; Write-Host "--help" -ForegroundColor $paramColor -NoNewline
            Write-Host -NoNewline " | "; Write-Host "/?" -ForegroundColor $paramColor
            Write-Host "    Displays this help summary."
            Write-Host # Blank line

            Write-Host "COMMON PARAMETERS" -ForegroundColor $headerColor
            Write-Host -NoNewline "  This cmdlet supports common parameters like "; Write-Host "-WhatIf" -ForegroundColor $paramColor -NoNewline
            Write-Host -NoNewline ", "; Write-Host "-Confirm" -ForegroundColor $paramColor -NoNewline
            Write-Host -NoNewline ", "; Write-Host "-Verbose" -ForegroundColor $paramColor -NoNewline
            Write-Host -NoNewline ", "; Write-Host "-Debug" -ForegroundColor $paramColor -NoNewline
            Write-Host ", etc."
            Write-Host "  For more information, type: Get-Help about_CommonParameters"
            Write-Host # Blank line

            Write-Host "EXAMPLES" -ForegroundColor $headerColor
            Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor
            Write-Host "    # Increments the version normally."
            Write-Host # Blank line
            Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
            Write-Host -NoNewline " "; Write-Host "-PromoteToRelease" -ForegroundColor $paramColor
            Write-Host "    # Promotes a pre-release to release or increments patch of a release."
            Write-Host # Blank line
            Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
            Write-Host -NoNewline " "; Write-Host "-WhatIf" -ForegroundColor $paramColor
            Write-Host "    # Shows the intended version change without modifying the file."
            Write-Host # Blank line
            Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
            Write-Host -NoNewline " "; Write-Host "help" -ForegroundColor $paramColor
            Write-Host "    # Displays this help summary."
            Write-Host # Blank line

            Write-Host "NOTES" -ForegroundColor $headerColor
            Write-Host "  For more detailed and standard PowerShell help, which includes full parameter descriptions"
            Write-Host "  and additional examples, please type:"
            Write-Host -NoNewline "    Get-Help "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline; Write-Host " -Full"
            Write-Host # Blank line
            return
        }
        # If $HelpArgument was provided but wasn't a recognized help trigger, it's an unknown command for this script.
        Write-Error "Unknown command or argument: '$($HelpArgument)'. For usage information, type 'Increment-Version help' or 'Get-Help Increment-Version'."
        return
    }

    # Helper function to find the nearest package.json by searching upwards
    Function Get-NearestPackageJsonInternal {
        param (
            [string]$startDir = (Get-Location).Path
        )
        $currentDir = $startDir
        while ($true) {
            $filePath = Join-Path -Path $currentDir -ChildPath "package.json"
            if (Test-Path $filePath -PathType Leaf) {
                return $filePath
            }
            $parentDir = Split-Path -Path $currentDir
            if ($parentDir -eq $currentDir -or [string]::IsNullOrEmpty($parentDir)) {
                Write-Verbose "Reached root directory or could not go further up from '$($currentDir)'. Searched from '$($startDir)'."
                return $null
            }
            $currentDir = $parentDir
        }
    }

    try {
        $packageJsonPath = Get-NearestPackageJsonInternal

        if (-not $packageJsonPath) {
            Write-Error "package.json not found in the current directory or any parent directory."
            return 
        }

        Write-Host "Found package.json at: $packageJsonPath"

        $fileContentRaw = Get-Content -Path $packageJsonPath -Raw -Encoding UTF8 -ErrorAction Stop
        
        $jsonForParsing = $null
        try {
            $jsonForParsing = $fileContentRaw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Error "Failed to parse JSON content from '$($packageJsonPath)'. Error: $($_.Exception.Message)"
            return
        }
        
        if (-not $jsonForParsing.PSObject.Properties.Name.Contains('version')) {
             Write-Error "The 'version' field was not found in '$($packageJsonPath)'."
             return
        }
        $originalVersionObject = $jsonForParsing.version

        if ($null -eq $originalVersionObject) {
            Write-Error "The 'version' field is present but its value is null in '$($packageJsonPath)'."
            return
        }
        $originalVersion = $originalVersionObject.ToString()

        Write-Host "Current version: $originalVersion"

        $semVerRegex = "^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+(?<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$"
        $match = [regex]::Match($originalVersion, $semVerRegex)

        if (-not $match.Success) {
            Write-Error "Version '$originalVersion' in '$($packageJsonPath)' is not a valid SemVer string."
            return
        }

        $major = $match.Groups['major'].Value
        $minor = $match.Groups['minor'].Value
        $patch = $match.Groups['patch'].Value
        $prerelease = $match.Groups['prerelease'].Value

        $newVersion = ""
        $actionMessage = ""

        if ($PromoteToRelease.IsPresent -and -not [string]::IsNullOrEmpty($prerelease)) {
            $newVersion = "$major.$minor.$patch"
            $actionMessage = "Action: Promoting pre-release '$($originalVersion)' to release version '$($newVersion)'."
        } else {
            if ([string]::IsNullOrEmpty($prerelease)) {
                if ($PromoteToRelease.IsPresent) {
                    $actionMessage = "Action: -PromoteToRelease specified, but version is already a release. Incrementing patch."
                } else {
                    $actionMessage = "Action: Incrementing release version patch."
                }
                $newPatch = [int]$patch + 1
                $newVersion = "$major.$minor.$newPatch"
            } else {
                $actionMessage = "Action: Incrementing pre-release version."
                $prereleaseParts = $prerelease.Split('.')
                $lastPrereleasePartIndex = $prereleaseParts.Length - 1
                $lastPrereleasePart = $prereleaseParts[$lastPrereleasePartIndex]

                $numericPart = 0 
                $isNumeric = [int]::TryParse($lastPrereleasePart, [ref]$numericPart)

                if ($isNumeric) {
                    $newPrereleaseNumeric = $numericPart + 1
                    $prereleaseParts[$lastPrereleasePartIndex] = $newPrereleaseNumeric.ToString()
                    $newPrereleaseString = $prereleaseParts -join "."
                    $newVersion = "$major.$minor.$patch-$newPrereleaseString"
                } else { 
                    $newPrereleaseString = "$prerelease.1"
                    $newVersion = "$major.$minor.$patch-$newPrereleaseString"
                }
            }
        }

        Write-Host $actionMessage
        Write-Host "New version will be: $newVersion"

        $oldVersionPattern = '"version"\s*:\s*"' + [regex]::Escape($originalVersion) + '"'
        $newVersionJsonFragment = '"version": "' + $newVersion + '"'

        if ($fileContentRaw -match $oldVersionPattern) {
            $updatedFileContent = $fileContentRaw -replace $oldVersionPattern, $newVersionJsonFragment
            
            if ($pscmdlet.ShouldProcess($packageJsonPath, "Update version from '$originalVersion' to '$newVersion'")) {
                try {
                    Set-Content -Path $packageJsonPath -Value $updatedFileContent -Encoding UTF8 -ErrorAction Stop
                    Write-Host "Successfully updated version in '$($packageJsonPath)' from '$($originalVersion)' to '$($newVersion)'."
                } catch {
                    Write-Error "Could not write changes to '$($packageJsonPath)'. Error: $($_.Exception.Message)"
                    Write-Warning "Please check file permissions or if the file is in use."
                    return
                }
            } else {
                Write-Host "Operation cancelled by -WhatIf or user. No changes made to '$($packageJsonPath)'."
            }
        } else {
            Write-Error "Could not find the exact pattern '""version"" : ""$originalVersion""' in '$($packageJsonPath)' for replacement using regex."
            Write-Warning "File was not modified. Please ensure the version field format is standard (e.g. ""version"": ""1.2.3"")."
            return
        }

    } catch {
        Write-Error "An unexpected error occurred: $($_.Exception.Message)"
        $exceptionErrorRecord = $_.Exception.ErrorRecord
        if ($exceptionErrorRecord) {
            Write-Error "Details: $($exceptionErrorRecord.ToString())"
            if ($exceptionErrorRecord.InvocationInfo) {
                Write-Error "Error occurred near line: $($exceptionErrorRecord.InvocationInfo.ScriptLineNumber)"
            }
        }
    }
}