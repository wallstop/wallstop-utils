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
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([void])]
  param(
    [Parameter(Position = 0,Mandatory = $false,HelpMessage = "Type 'help', '--help', or '/?' to display built-in help summary.")]
    [string]$HelpArgument,

    [Parameter(Mandatory = $false)]
    [switch]$PromoteToRelease,

    [Parameter(Mandatory = $false,HelpMessage = "Specifies increment mode. Default: 'Default'. RolloverAt9: '0.0.9' -> '0.1.0', '-rc.07.9' -> '-rc.08.0'.")]
    [ValidateSet("Default","RolloverAt9")]
    [string]$IncrementMode = "RolloverAt9"
  )

  # Check for custom help invocation first
  if ($PSBoundParameters.ContainsKey('HelpArgument')) {
    $helpTriggers = @('help','--help','/?')
    if ($helpTriggers -contains $HelpArgument.ToLowerInvariant()) {

      # Define colors for help text
      $headerColor = "Yellow"
      $commandColor = "Green"
      $paramColor = "Cyan"
      $placeholderColor = "Gray"

      Write-Host "Increment-Version Script Quick Help:" # Default color for main title
      Write-Host "------------------------------------" # Default color
      Write-Host # Blank line

      Write-Host "SYNOPSIS" -ForegroundColor $headerColor
      Write-Host "  Increments the version in a package.json file found in the current or parent directories."
      Write-Host # Blank line

      Write-Host "SYNTAX" -ForegroundColor $headerColor
      Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
      Write-Host -NoNewline " [-"; Write-Host "PromoteToRelease" -ForegroundColor $paramColor -NoNewline; Write-Host -NoNewline "]"
      Write-Host -NoNewline " [-"; Write-Host "IncrementMode" -ForegroundColor $paramColor -NoNewline; Write-Host -NoNewline " <"; Write-Host "Default" -ForegroundColor $placeholderColor -NoNewline; Write-Host -NoNewline "|"; Write-Host "RolloverAt9" -ForegroundColor $placeholderColor -NoNewline; Write-Host -NoNewline ">]"
      Write-Host -NoNewline " [-"; Write-Host "WhatIf" -ForegroundColor $paramColor -NoNewline; Write-Host -NoNewline "]"
      Write-Host -NoNewline " [-"; Write-Host "Confirm" -ForegroundColor $paramColor -NoNewline; Write-Host -NoNewline "]"
      Write-Host -NoNewline " ["; Write-Host "<CommonParameters>" -ForegroundColor $placeholderColor -NoNewline; Write-Host "]"

      Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
      Write-Host -NoNewline " [ "; Write-Host "help" -ForegroundColor $paramColor -NoNewline
      Write-Host -NoNewline " | "; Write-Host "--help" -ForegroundColor $paramColor -NoNewline
      Write-Host -NoNewline " | "; Write-Host "/?" -ForegroundColor $paramColor -NoNewline; Write-Host " ]"
      Write-Host # Blank line

      Write-Host "DESCRIPTION" -ForegroundColor $headerColor
      Write-Host "  This script searches for a 'package.json' file by traversing upwards from the current directory."
      Write-Host "  It reads the 'version' field, increments it according to SemVer rules (or specified mode),"
      Write-Host "  and writes the changes back. Supports standard increments, pre-release increments,"
      Write-Host "  promotion of pre-releases, and a special 'RolloverAt9' mode."
      Write-Host # Blank line

      Write-Host "PARAMETERS" -ForegroundColor $headerColor
      Write-Host -NoNewline "  -"; Write-Host "PromoteToRelease" -ForegroundColor $paramColor
      Write-Host "    If specified, and the current version is a pre-release (e.g., X.Y.Z-rc.N), it will be promoted"
      Write-Host "    to the release version X.Y.Z. If the current version is already a release, its patch"
      Write-Host "    component will be incremented based on the selected -IncrementMode."
      Write-Host # Blank line

      Write-Host -NoNewline "  -"; Write-Host "IncrementMode" -ForegroundColor $paramColor -NoNewline; Write-Host " <Default | RolloverAt9>" -ForegroundColor $placeholderColor
      Write-Host "    Specifies how numeric version components are incremented. Default is 'Default'."
      Write-Host "    - Default: Standard SemVer increment."
      Write-Host "        - M.m.p: Patch increments (e.g., 0.0.9 -> 0.0.10)."
      Write-Host "        - Pre-release: Only the rightmost numeric identifier increments (e.g., -rc.07.9 -> -rc.07.10)."
      Write-Host "    - RolloverAt9: Numeric components 'roll over' at 9."
      Write-Host "        - M.m.p: e.g., 0.0.9 -> 0.1.0; 0.9.9 -> 1.0.0."
      Write-Host "        - Pre-release: Applies hierarchically from right to left to numeric/alpha-numeric segments."
      Write-Host "                       e.g., -rc.07.9 -> -rc.08.0."
      Write-Host # Blank line

      Write-Host -NoNewline "  "; Write-Host "help" -ForegroundColor $paramColor -NoNewline
      Write-Host -NoNewline " | "; Write-Host "--help" -ForegroundColor $paramColor -NoNewline
      Write-Host -NoNewline " | "; Write-Host "/?" -ForegroundColor $paramColor
      Write-Host "    Displays this help summary."
      Write-Host # Blank line

      Write-Host "COMMON PARAMETERS" -ForegroundColor $headerColor
      Write-Host -NoNewline "  This cmdlet supports common parameters like "; Write-Host "-WhatIf" -ForegroundColor $paramColor -NoNewline
      Write-Host -NoNewline ", "; Write-Host "-Confirm" -ForegroundColor $paramColor -NoNewline
      Write-Host -NoNewline ", "; Write-Host "-Verbose" -ForegroundColor $paramColor -NoNewline
      Write-Host -NoNewline ", "; Write-Host "-Debug" -ForegroundColor $paramColor -NoNewline; Write-Host ", etc."
      Write-Host "  For more information, type: Get-Help about_CommonParameters"
      Write-Host # Blank line

      Write-Host "EXAMPLES" -ForegroundColor $headerColor
      Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor
      Write-Host "    # Default mode: 0.0.9 -> 0.0.10;  1.0.0-rc.07.9 -> 1.0.0-rc.07.10"
      Write-Host # Blank line

      Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
      Write-Host -NoNewline " -"; Write-Host "IncrementMode" -ForegroundColor $paramColor -NoNewline; Write-Host " RolloverAt9" -ForegroundColor $placeholderColor
      Write-Host "    # RolloverAt9 mode: 0.0.9 -> 0.1.0;  1.0.0-rc.07.9 -> 1.0.0-rc.08.0"
      Write-Host # Blank line

      Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
      Write-Host -NoNewline " -"; Write-Host "PromoteToRelease" -ForegroundColor $paramColor
      Write-Host "    # Promotes a pre-release (e.g., 1.0.0-rc.2 -> 1.0.0)."
      Write-Host # Blank line

      Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
      Write-Host -NoNewline " -"; Write-Host "WhatIf" -ForegroundColor $paramColor
      Write-Host "    # Shows the intended version change without modifying the file."
      Write-Host # Blank line

      Write-Host -NoNewline "  "; Write-Host "Increment-Version" -ForegroundColor $commandColor -NoNewline
      Write-Host -NoNewline " "; Write-Host "help" -ForegroundColor $paramColor
      Write-Host "    # Displays this help summary."
      Write-Host # Blank line

      Write-Host "NOTES" -ForegroundColor $headerColor
      Write-Host "  This script provides a custom quick help. For more detailed and standard PowerShell help,"
      Write-Host "  which includes full parameter descriptions generated from comment-based help within the script,"
      Write-Host -NoNewline "  please type: "; Write-Host "Get-Help Increment-Version -Full" -ForegroundColor Green
      Write-Host # Blank line
      return
    }
    # If $HelpArgument was provided but wasn't a recognized help trigger, it's an unknown command for this script.
    Write-Error "Unknown command or argument: '$($HelpArgument)'. For usage information, type 'Increment-Version help' or 'Get-Help Increment-Version'."
    return
  }

  # Helper function to find the nearest package.json by searching upwards
  function Get-NearestPackageJsonInternal {
    param(
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
    if (-not $packageJsonPath) { Write-Error "package.json not found."; return }
    Write-Host "Found package.json at: $packageJsonPath"
    $fileContentRaw = Get-Content -Path $packageJsonPath -Raw -Encoding UTF8 -ErrorAction Stop

    $jsonForParsing = $null; try { $jsonForParsing = $fileContentRaw | ConvertFrom-Json -ErrorAction Stop } catch { Write-Error "Failed to parse JSON from '$($packageJsonPath)'. Error: $($_.Exception.Message)"; return }
    if (-not $jsonForParsing.PSObject.Properties.Name.Contains('version')) { Write-Error "'version' field not found."; return }
    $originalVersionObject = $jsonForParsing.version; if ($null -eq $originalVersionObject) { Write-Error "'version' field is null."; return }
    $originalVersion = $originalVersionObject.ToString(); Write-Host "Current version: $originalVersion"

    $semVerRegex = "^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<prerelease>(?:\d+|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:\d+|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+(?<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$"
    $match = [regex]::Match($originalVersion,$semVerRegex)
    if (-not $match.Success) { Write-Error "Version '$originalVersion' is not valid per SemVer (even with lenient pre-release parsing)."; return }

    $major_str = $match.Groups['major'].Value; $minor_str = $match.Groups['minor'].Value; $patch_str = $match.Groups['patch'].Value
    $prerelease = $match.Groups['prerelease'].Value
    $newVersion = ""; $actionMessage = ""; $mainVersionCarry = 0

    if ($PromoteToRelease.IsPresent -and -not [string]::IsNullOrEmpty($prerelease)) {
      $newVersion = "$major_str.$minor_str.$patch_str"
      $actionMessage = "Action: Promoting pre-release '$($originalVersion)' to release version '$($newVersion)'."
      $prerelease = "" # Clear prerelease as it's now promoted
    }

    if (-not [string]::IsNullOrEmpty($prerelease)) {
      # If still has prerelease (and not promoted)
      if ($IncrementMode -eq "RolloverAt9") {
        $actionMessage = "Action: Incrementing pre-release of '$($originalVersion)' using RolloverAt9 mode."

        # --- START: Refined RolloverAt9 Pre-release Logic ---
        $preParts = $prerelease.Split('.')

        # Normalization for incrementing: if the last part that can have a sub-number doesn't, append ".0" conceptually
        # Example: "01rc10" treated as "01rc10.0" for increment. "01rc09.9" is fine.
        # For this, we'll check the last part. If it's not purely numeric, or if it is numeric but we want to append a sub-version.
        # This logic assumes a structure like prefixNUMBER.SUBNUMBER or just prefixNUMBER (implying .0)

        $lastPartIdx = $preParts.Length - 1
        $lastPartPattern = "^(?<prefix>[a-zA-Z0-9\-]*)?(?<num>\d+)$" # General pattern for a part that is or ends in a number
        $matchLastPart = $preParts[$lastPartIdx] | Select-String -Pattern $lastPartPattern

        # If last part doesn't look like a simple number (e.g., "rc10" not "10"), append a conceptual ".0"
        # Or if user wants to always add a sub-number if one isn't there.
        # Based on "1.0.01rc10" -> "1.0.01rc10.1", implies "1.0.01rc10" is treated as "1.0.01rc10.0"
        if ($matchLastPart -and $matchLastPart.Matches[0].Groups["prefix"].Value -ne "") {
          # e.g., "rc10", not "10"
          if (-not (($preParts.Length -gt 1) -and ($preParts[$preParts.Length - 1] -match "^\d+$") -and ($preParts[$preParts.Length - 2] | Select-String -Pattern $lastPartPattern))) {
            # Heuristic: if last part is like "rc10", treat as "rc10.0" by adding "0" to parts array for processing
            $preParts = $preParts + "0" # Conceptually append ".0"
          }
        }


        $carry = 1 # Initial increment signal

        for ($i = $preParts.Length - 1; $i -ge 0; $i --) {
          if ($carry -eq 0) { break }

          $currentPrePart = $preParts[$i]
          $originalCurrentPrePartLength = $currentPrePart.Length # For formatting purely numeric parts

          # Regex to find an optional prefix and a mandatory numeric suffix in a part
          # e.g., "rc07" -> prefix="rc", num="07"; "07" -> prefix="", num="07"
          $partPattern = "^(?<prefix>[a-zA-Z\-\.]*?)?(?<num>\d+)$" # Non-greedy prefix, numeric suffix
          $partMatch = $currentPrePart | Select-String -Pattern $partPattern

          if ($partMatch) {
            $prefix = $partMatch.Matches[0].Groups["prefix"].Value
            $numStr = $partMatch.Matches[0].Groups["num"].Value
            $originalNumStrLength = $numStr.Length # Length of the "07" or "9"
            [long]$numVal = $numStr # Use long for safety, though int is likely fine

            $numVal += $carry

            # Determine if this segment should apply full "rollover at 9 to 0" or standard increment
            $isRightmostNumericSegment = ($i -eq ($preParts.Length - 1)) # Is it the actual last segment?

            if ($isRightmostNumericSegment) {
              # Rightmost numeric segment ALWAYS uses "rollover at 9 to 0"
              if ($numVal -gt 9) {
                $numVal = 0
                $carry = 1 # Propagate carry
              }
              else {
                $carry = 0 # Carry consumed
              }
            }
            else {
              # Internal numeric segment that received a carry
              # It just increments, does not roll over at 9 itself to 0 unless it naturally hits a higher multiple (e.g. 99 -> 100)
              # The example "01rc09.9" -> "01rc10" means "09"+carry = "10"
              # So this segment consumes the carry by standard increment.
              $carry = 0
            }
            $preParts[$i] = $prefix + $numVal.ToString("D$($originalNumStrLength)")
          }
          else {
            # Part is purely non-numeric (e.g., "alpha", "rc" if it's a standalone part)
            # If it's the rightmost part and was meant to be incremented:
            if ($i -eq ($preParts.Length - 1) -and $carry -eq 1) {
              $preParts = $preParts + "1" # Append ".1"
              $carry = 0
            }
            # Otherwise, an intermediate non-numeric part is unchanged. Carry continues.
          }
        }

        if ($carry -eq 1) {
          $prerelease = ""
          $mainVersionCarry = 1
          $actionMessage += " Pre-release rolled over completely."
        }
        else {
          $prerelease = $preParts -join "."
          # Output formatting: if ends in ".0" and not just "0", remove ".0"
          # Example: "01rc10.0" -> "01rc10"
          if ($prerelease.EndsWith(".0") -and $prerelease.Length -gt 2) {
            # Check length to avoid "0" -> ""
            $prerelease = $prerelease.Substring(0,$prerelease.Length - 2)
          }
        }
        # --- END: Refined RolloverAt9 Pre-release Logic ---

      }
      else {
        # Default pre-release increment (IncrementMode is "Default")
        $actionMessage = "Action: Incrementing pre-release part of '$($originalVersion)' (Default mode)."
        $preParts = $prerelease.Split('.')
        $lastPrePartIdx = $preParts.Length - 1
        $lastPrePart = $preParts[$lastPrePartIdx]
        # For default mode, use original length of the *entire last part* for formatting if it's numeric
        $originalFormatLength = $lastPrePart.Length

        # Check if the last part is purely numeric
        if ($lastPrePart -match "^\d+$") {
          [long]$numericValue = $lastPrePart # Use long to handle potentially large numbers if not just 0-9
          $numericValue++ # Simple increment
          $preParts[$lastPrePartIdx] = $numericValue.ToString("D$($originalFormatLength)")
        }
        else {
          # If last part is not purely numeric (e.g. "alpha", "rc1"), append ".1"
          $preParts = $preParts + "1"
        }
        $prerelease = $preParts -join "."
      }

      # If no main version carry resulted from pre-release processing, construct the new version
      if (-not $mainVersionCarry) {
        $newVersion = "$major_str.$minor_str.$patch_str"
        if (-not [string]::IsNullOrEmpty($prerelease)) {
          $newVersion += "-$prerelease"
        }
      }
    }

    # Increment MAJOR.MINOR.PATCH if no prerelease initially, or if promotion occurred, or if pre-release rollover carried to main version
    if ([string]::IsNullOrEmpty($prerelease)) {
      # True if initially no prerelease, or promoted, or pre-release fully rolled over
      [int]$major_val = $major_str; [int]$minor_val = $minor_str; [int]$patch_val = $patch_str
      $initial_carry_for_main = if ($mainVersionCarry -eq 1) { 1 } else { if (-not $PromoteToRelease.IsPresent) { 1 } else { 0 } } # if promoted, M.m.p is target, no auto-bump unless pre-release carry
      # if not promoted and no pre-release, then initial carry is 1

      if ($initial_carry_for_main -eq 1) {
        # Only increment M.m.p if there's a reason to (initial bump or carry)
        if ($IncrementMode -eq "RolloverAt9") {
          if (-not ($actionMessage.Contains("RolloverAt9"))) { $actionMessage += " Incrementing M.m.p of '$($originalVersion)' using RolloverAt9 mode." }
          $patch_val += $initial_carry_for_main # Effectively patch_val++ if initial_carry_for_main is 1
          if ($patch_val -gt 9) {
            $patch_val = 0; $minor_val++
            if ($minor_val -gt 9) { $minor_val = 0; $major_val++ }
          }
        }
        else {
          # Default increment mode for M.m.p
          if (-not ($actionMessage.Contains("Default mode"))) { $actionMessage += " Incrementing patch of '$($originalVersion)' using Default mode." }
          $patch_val += $initial_carry_for_main
        }
      }
      elseif ($PromoteToRelease.IsPresent -and $actionMessage.Contains("Promoting pre-release")) {
        # No further increment if it was just a promotion to an existing M.m.p
        # $actionMessage already set.
      }

      $newVersion = "$major_val.$minor_val.$patch_val"
    }


    Write-Host $actionMessage -Replace '\s{2,}',' ' # Clean up potential double spaces in message
    Write-Host "New version will be: $newVersion"
    $oldVersionPattern = '"version"\s*:\s*"' + [regex]::Escape($originalVersion) + '"'
    $newVersionJsonFragment = '"version": "' + $newVersion + '"'
    if ($fileContentRaw -match $oldVersionPattern) {
      $updatedFileContent = $fileContentRaw -replace $oldVersionPattern,$newVersionJsonFragment
      if ($pscmdlet.ShouldProcess($packageJsonPath,"Update version from '$originalVersion' to '$newVersion'")) {
        try { Set-Content -Path $packageJsonPath -Value $updatedFileContent -Encoding UTF8 -ErrorAction Stop; Write-Host "Successfully updated." }
        catch { Write-Error "Could not write. Error: $($_.Exception.Message)"; return }
      }
      else { Write-Host "Operation cancelled." }
    }
    else { Write-Error "Could not find pattern for replacement. File not modified."; return }

  }
  catch { Write-Error "Unexpected error: $($_.Exception.Message)"; if ($_.Exception.ErrorRecord) { Write-Error "Details: $($_.Exception.ErrorRecord)" } }
}
