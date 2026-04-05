# Remove-BOM PowerShell Script
# This script removes the UTF-8 BOM (Byte Order Mark) from text files in a repository
#
# Features:
# - Uses git-native file discovery for accurate .gitignore semantics
# - Falls back to filesystem traversal when git discovery is unavailable
# - Has a detection mode to find BOMs without removing them
# - Provides detailed progress feedback and performance metrics
# - Automatically detects and skips binary files
#
# Usage:
#   .\remove-bom.ps1                      # Remove BOMs from all text files in current directory and subdirectories
#   .\remove-bom.ps1 -DetectOnly          # Just detect BOMs without removing them
#   .\remove-bom.ps1 -ShowProgress        # Show detailed processing information for each file
#   .\remove-bom.ps1 -Path "D:\MyRepo"    # Process files in a specific directory

# Script parameters
param(
    [switch]$DetectOnly,
    [switch]$ShowProgress,
    [string]$Path = ""
)

$script:prefixReadFailures = 0

function Get-DefaultExclusionPatterns {
    return @(
        # Version control
        "*/.git/*",
        "*/.svn/*",
        "*/.hg/*",

        # Build directories
        "*/bin/*",
        "*/obj/*",
        "*/build/*",
        "*/dist/*",
        "*/target/*",
        "*/out/*",
        "*/output/*",
        "*/node_modules/*",
        "*/.next/*",
        "*/.nuxt/*",
        "*/.vite/*",
        "*/.svelte-kit/*",
        "*/.turbo/*",
        "*/cdk.out/*",

        # IDE files
        "*/.vs/*",
        "*/.idea/*",
        "*/.vscode/*",

        # Logs and temp files
        "*/logs/*",
        "*/coverage/*",
        "*/.nyc_output/*",
        "*/*.log",
        "*/*.tmp",
        "*/*.tsbuildinfo"
    )
}

function Test-PathAgainstPatterns {
    param(
        [string]$path,
        [string[]]$patterns
    )

    # Normalize to forward slashes for cross-platform matching (patterns use '/')
    $normalizedPath = $path -replace '\\', '/'

    foreach ($pattern in $patterns) {
        if ($normalizedPath -like $pattern) {
            return $true
        }
    }

    return $false
}

function Test-IsPathUnderRoot {
    param(
        [string]$path,
        [string]$root
    )

    $normalizedPath = ((Resolve-TopLevelPathAlias -path $path) -replace '\\', '/').TrimEnd('/')
    $normalizedRoot = ((Resolve-TopLevelPathAlias -path $root) -replace '\\', '/').TrimEnd('/')

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    if ($normalizedPath.Equals($normalizedRoot, $comparison)) {
        return $true
    }

    return $normalizedPath.StartsWith("$normalizedRoot/", $comparison)
}

# Cache top-level alias resolutions (for example, /var -> /private/var on macOS)
# for the current PowerShell session to avoid repeated filesystem probes.
$script:topLevelAliasCache = @{}

function Resolve-TopLevelPathAlias {
    param(
        [string]$path
    )

    $fullPath = [System.IO.Path]::GetFullPath($path)

    if ($IsWindows -or [string]::IsNullOrWhiteSpace($fullPath) -or -not $fullPath.StartsWith('/')) {
        return $fullPath
    }

    if ($fullPath.Length -eq 1) {
        return $fullPath
    }

    $segmentSeparatorIndex = $fullPath.IndexOf('/', 1)
    $topLevelSegment = if ($segmentSeparatorIndex -gt 0) {
        $fullPath.Substring(0, $segmentSeparatorIndex)
    }
    else {
        $fullPath
    }

    if ($topLevelSegment -eq "/") {
        return $fullPath
    }

    if (-not $script:topLevelAliasCache.ContainsKey($topLevelSegment)) {
        $resolvedTopLevelAliasTarget = $topLevelSegment
        $aliasResolutionSource = "identity"

        try {
            $topLevelItem = Get-Item -LiteralPath $topLevelSegment -ErrorAction Stop

            $resolvedAliasTarget = $null
            if ($topLevelItem.PSObject.Methods.Name -contains "ResolveLinkTarget") {
                try {
                    $resolvedAliasTarget = $topLevelItem.ResolveLinkTarget($true)
                }
                catch {
                    $resolvedAliasTarget = $null
                }
            }

            if ($null -ne $resolvedAliasTarget -and -not [string]::IsNullOrWhiteSpace($resolvedAliasTarget.FullName)) {
                $resolvedTopLevelAliasTarget = [System.IO.Path]::GetFullPath($resolvedAliasTarget.FullName)
                $aliasResolutionSource = "ResolveLinkTarget"
            }
            else {
                $linkTargetProperty = $null
                $linkTargetPropertyName = $null
                if ($topLevelItem.PSObject.Properties.Name -contains "LinkTarget") {
                    $linkTargetProperty = [string]$topLevelItem.LinkTarget
                    $linkTargetPropertyName = "LinkTarget"
                }
                elseif ($topLevelItem.PSObject.Properties.Name -contains "Target") {
                    $linkTargetProperty = [string]$topLevelItem.Target
                    $linkTargetPropertyName = "Target"
                }

                if (-not [string]::IsNullOrWhiteSpace($linkTargetProperty)) {
                    $linkTargetPath = if ([System.IO.Path]::IsPathRooted($linkTargetProperty)) {
                        $linkTargetProperty
                    }
                    else {
                        $topLevelParent = Split-Path -Path $topLevelSegment -Parent
                        if ([string]::IsNullOrWhiteSpace($topLevelParent)) {
                            $topLevelParent = "/"
                        }

                        Join-Path -Path $topLevelParent -ChildPath $linkTargetProperty
                    }

                    $resolvedTopLevelAliasTarget = [System.IO.Path]::GetFullPath($linkTargetPath)
                    $aliasResolutionSource = "property:$linkTargetPropertyName"
                }
                elseif (-not [string]::IsNullOrWhiteSpace($topLevelItem.FullName)) {
                    # On some platforms/providers Get-Item can already expose the canonical target in FullName
                    # even when explicit link-target APIs are unavailable.
                    $resolvedTopLevelAliasTarget = [System.IO.Path]::GetFullPath($topLevelItem.FullName)
                    $aliasResolutionSource = "FullName"
                }
            }

            if ($resolvedTopLevelAliasTarget.Equals($topLevelSegment, [System.StringComparison]::Ordinal)) {
                # Some providers expose identity FullName for top-level aliases (for example /var on macOS).
                # Re-probe with Resolve-Path before accepting identity mapping.
                try {
                    $resolvePathAliasCandidate = (Resolve-Path -LiteralPath $topLevelSegment -ErrorAction Stop).Path
                    if (-not [string]::IsNullOrWhiteSpace($resolvePathAliasCandidate)) {
                        $resolvePathAliasCandidate = [System.IO.Path]::GetFullPath($resolvePathAliasCandidate)
                        if (-not $resolvePathAliasCandidate.Equals($topLevelSegment, [System.StringComparison]::Ordinal)) {
                            $resolvedTopLevelAliasTarget = $resolvePathAliasCandidate
                            $aliasResolutionSource = "Resolve-Path"
                        }
                    }
                }
                catch {
                    # Keep identity mapping when alias re-probe is unavailable.
                }

                # Unix-specific fallback: readlink resolves symlinks that
                # .NET/PowerShell providers may not detect (for example macOS
                # /var -> /private/var, where readlink returns relative target "private/var").
                if (-not $IsWindows -and $resolvedTopLevelAliasTarget.Equals($topLevelSegment, [System.StringComparison]::Ordinal)) {
                    try {
                        $readlinkOutput = (& readlink $topLevelSegment 2>$null)
                        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($readlinkOutput)) {
                            $readlinkPath = ([string]$readlinkOutput).Trim()
                            if (-not [System.IO.Path]::IsPathRooted($readlinkPath)) {
                                $readlinkParent = Split-Path -Path $topLevelSegment -Parent
                                if ([string]::IsNullOrWhiteSpace($readlinkParent)) {
                                    $readlinkParent = "/"
                                }
                                $readlinkPath = [System.IO.Path]::GetFullPath((Join-Path -Path $readlinkParent -ChildPath $readlinkPath))
                            }
                            if (-not $readlinkPath.Equals($topLevelSegment, [System.StringComparison]::Ordinal)) {
                                $resolvedTopLevelAliasTarget = $readlinkPath
                                $aliasResolutionSource = "readlink"
                            }
                        }
                    }
                    catch {
                        # readlink unavailable or failed; keep identity mapping.
                    }
                }
            }
        }
        catch {
            $resolvedTopLevelAliasTarget = $topLevelSegment
            $aliasResolutionSource = "fallback-on-error"
        }

        $script:topLevelAliasCache[$topLevelSegment] = $resolvedTopLevelAliasTarget

        if (-not $resolvedTopLevelAliasTarget.Equals($topLevelSegment, [System.StringComparison]::Ordinal)) {
            Write-Verbose "Remove-BOM alias diagnostics: mapped top-level segment '$topLevelSegment' to '$resolvedTopLevelAliasTarget' via $aliasResolutionSource."
        }
        else {
            Write-Verbose "Remove-BOM alias diagnostics: top-level segment '$topLevelSegment' remained identity via $aliasResolutionSource."
        }
    }

    $aliasTarget = $script:topLevelAliasCache[$topLevelSegment]
    if ([string]::IsNullOrWhiteSpace($aliasTarget) -or $aliasTarget.Equals($topLevelSegment, [System.StringComparison]::Ordinal)) {
        return $fullPath
    }

    if ($fullPath.Length -eq $topLevelSegment.Length) {
        return $aliasTarget
    }

    $remainingPath = $fullPath.Substring($topLevelSegment.Length).TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($remainingPath)) {
        return $aliasTarget
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $aliasTarget -ChildPath $remainingPath))
}

function Get-GitCommandDetails {
    param(
        [string]$gitExecutable,
        [string]$workingDirectory,
        [string[]]$arguments
    )

    $commandOutput = @(& $gitExecutable -C $workingDirectory @arguments 2>&1)
    $commandExitCode = $LASTEXITCODE

    $firstOutputLine = $null
    foreach ($line in $commandOutput) {
        $normalizedLine = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($normalizedLine)) {
            $firstOutputLine = $normalizedLine.Trim()
            break
        }
    }

    return [PSCustomObject]@{
        ExitCode  = $commandExitCode
        Output    = @($commandOutput)
        FirstLine = $firstOutputLine
        HasOutput = $null -ne $firstOutputLine
    }
}

function Resolve-CanonicalFileSystemPath {
    param(
        [string]$path
    )

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
        $resolvedItem = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop

        $resolvedLinkTarget = $null
        if ($resolvedItem.PSObject.Methods.Name -contains "ResolveLinkTarget") {
            try {
                $resolvedLinkTarget = $resolvedItem.ResolveLinkTarget($true)
            }
            catch {
                $resolvedLinkTarget = $null
            }
        }

        $canonicalCandidate = if ($null -ne $resolvedLinkTarget) {
            $resolvedLinkTarget.FullName
        }
        else {
            $resolvedItem.FullName
        }

        return Resolve-TopLevelPathAlias -path $canonicalCandidate
    }
    catch {
        throw "E_REMOVE_BOM_CANONICAL_PATH_RESOLUTION_FAILED: Failed to canonicalize '$path' - $($_.Exception.Message)"
    }
}

function Get-FallbackSafetyAssessment {
    param(
        [string]$resolvedScanRoot,
        [System.StringComparison]$comparison
    )

    $gitMetadataBoundary = $null
    $boundaryProbe = $resolvedScanRoot
    while ($true) {
        $gitMetadataPath = Join-Path -Path $boundaryProbe -ChildPath ".git"
        if (Test-Path -LiteralPath $gitMetadataPath) {
            $gitMetadataBoundary = $boundaryProbe
            break
        }

        $parentProbe = Split-Path -Path $boundaryProbe -Parent
        if ([string]::IsNullOrWhiteSpace($parentProbe) -or $parentProbe.Equals($boundaryProbe, $comparison)) {
            break
        }

        $boundaryProbe = $parentProbe
    }

    $isRepositoryScopedFallback = -not [string]::IsNullOrWhiteSpace($gitMetadataBoundary)
    $fallbackScope = if ($isRepositoryScopedFallback) {
        "repository-ancestors"
    }
    else {
        "scan-root-only"
    }

    $gitIgnorePaths = @()
    $gitIgnoreProbe = $resolvedScanRoot
    $checkedAncestors = 0
    while ($true) {
        $checkedAncestors++
        $gitIgnorePath = Join-Path -Path $gitIgnoreProbe -ChildPath ".gitignore"
        if (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf) {
            $gitIgnorePaths += $gitIgnorePath
        }

        if (-not $isRepositoryScopedFallback) {
            # Keep non-repository fallback behavior scoped to the requested root only.
            break
        }

        if ($gitIgnoreProbe.Equals($gitMetadataBoundary, $comparison)) {
            break
        }

        $parentProbe = Split-Path -Path $gitIgnoreProbe -Parent
        if ([string]::IsNullOrWhiteSpace($parentProbe) -or $parentProbe.Equals($gitIgnoreProbe, $comparison)) {
            break
        }

        $gitIgnoreProbe = $parentProbe
    }

    $boundaryDiagnosticsValue = if ($isRepositoryScopedFallback) {
        $gitMetadataBoundary
    }
    else {
        "none"
    }

    return [PSCustomObject]@{
        GitMetadataBoundary = $gitMetadataBoundary
        GitIgnorePaths      = @($gitIgnorePaths)
        FallbackScope       = $fallbackScope
        CheckedAncestors    = $checkedAncestors
        Diagnostics         = "fallbackScope=$fallbackScope checkedAncestors=$checkedAncestors gitBoundary=$boundaryDiagnosticsValue"
    }
}

function Resolve-ScannableFileDiscovery {
    param(
        [string]$scanRoot
    )

    $scanRootInput = (Resolve-Path -LiteralPath $scanRoot -ErrorAction Stop).Path
    $resolvedScanRoot = Resolve-CanonicalFileSystemPath -path $scanRoot
    if (-not $resolvedScanRoot.Equals($scanRootInput, [System.StringComparison]::Ordinal)) {
        Write-Verbose "Remove-BOM symlink origin diagnostics: scan root '$scanRootInput' canonicalized to '$resolvedScanRoot'."
    }

    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    $gitDiscoveryFailureReason = ""

    if ($null -ne $gitCommand) {
        $gitRootResult = Get-GitCommandDetails -gitExecutable $gitCommand.Source -workingDirectory $resolvedScanRoot -arguments @("rev-parse", "--show-toplevel")
        if ($gitRootResult.ExitCode -eq 0 -and $gitRootResult.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($gitRootResult.Output[0])) {
            $gitRootCandidate = [System.IO.Path]::GetFullPath(([string]$gitRootResult.Output[0]).Trim())
            $gitRoot = Resolve-CanonicalFileSystemPath -path $gitRootCandidate
            $gitPrefixResult = Get-GitCommandDetails -gitExecutable $gitCommand.Source -workingDirectory $resolvedScanRoot -arguments @("rev-parse", "--show-prefix")

            if ($gitPrefixResult.ExitCode -eq 0) {
                $gitPrefix = ""
                if ($gitPrefixResult.Output.Count -gt 0) {
                    $gitPrefix = ([string]$gitPrefixResult.Output[0]).Trim()
                }

                $relativeScanRoot = ($gitPrefix -replace '\\', '/').Trim().Trim('/')
            }
            else {
                $gitPrefixFailureDetails = if ($gitPrefixResult.HasOutput) {
                    " First output: '$($gitPrefixResult.FirstLine)'."
                }
                else {
                    ""
                }
                Write-Verbose "W_REMOVE_BOM_GIT_PREFIX_UNAVAILABLE: git rev-parse --show-prefix failed with exit code $($gitPrefixResult.ExitCode). Enumerating git root and relying on post-filtering.$gitPrefixFailureDetails"
                # Use "." for git pathspec (enumerate entire repo), but preserve
                # the caller's original $resolvedScanRoot for post-filtering so
                # that scope restriction is not lost.
                $relativeScanRoot = "."
            }

            if ([string]::IsNullOrWhiteSpace($relativeScanRoot) -or $relativeScanRoot -eq ".") {
                $relativeScanRoot = "."
            }
            elseif ($relativeScanRoot -eq ".." -or $relativeScanRoot.StartsWith("../") -or $relativeScanRoot.StartsWith("..\\")) {
                Write-Verbose "W_REMOVE_BOM_GIT_PREFIX_OUTSIDE_ROOT: Computed relative scan root '$relativeScanRoot' is outside git root '$gitRoot'. Enumerating git root and relying on post-filtering."
                $relativeScanRoot = "."
            }

            # $gitPathspec controls git ls-files scope; $canonicalScanRoot
            # controls post-filter scope via Test-IsPathUnderRoot.
            # When $relativeScanRoot is "." (whole-repo enumerate), preserve
            # the caller's original scan root for post-filtering to prevent
            # scope leaks when --show-prefix is unavailable.
            # Both scan and git roots are canonicalized via Resolve-CanonicalFileSystemPath,
            # which resolves symlink segments consistently before post-filtering.
            $canonicalScanRoot = if ($relativeScanRoot -eq ".") {
                $resolvedScanRoot
            }
            else {
                Resolve-CanonicalFileSystemPath -path (Join-Path -Path $gitRoot -ChildPath $relativeScanRoot)
            }

            Write-Verbose "Remove-BOM canonicalization diagnostics: scanRootInput='$scanRootInput' resolvedScanRoot='$resolvedScanRoot' gitRootRaw='$gitRootCandidate' gitRootCanonical='$gitRoot' canonicalScanRoot='$canonicalScanRoot'"

            $gitListArguments = @("ls-files", "--cached", "--others", "--exclude-standard")
            if (-not [string]::IsNullOrWhiteSpace($relativeScanRoot) -and $relativeScanRoot -ne ".") {
                $gitListArguments += @("--", $relativeScanRoot)
            }

            Write-Verbose "Remove-BOM discovery diagnostics: deferring git ls-files enumeration to streaming pass for '$canonicalScanRoot'."
            return [PSCustomObject]@{
                Mode             = "git-ls-files"
                Diagnostics      = "scanRootInput=$scanRootInput gitRoot=$gitRoot scanRoot=$canonicalScanRoot relativeScanRoot=$relativeScanRoot resolvedScanRoot=$resolvedScanRoot listedPaths=deferred streaming=true"
                ResolvedScanRoot = $canonicalScanRoot
                GitExecutable    = $gitCommand.Source
                GitRoot          = $gitRoot
                GitListArguments = @($gitListArguments)
            }
        }
        else {
            $gitRootFailureDetails = if ($gitRootResult.HasOutput) {
                " first output: '$($gitRootResult.FirstLine)'"
            }
            else {
                ""
            }
            $gitDiscoveryFailureReason = "git rev-parse did not resolve a worktree for '$resolvedScanRoot' (exit code $($gitRootResult.ExitCode)$gitRootFailureDetails)"
        }
    }
    else {
        $gitDiscoveryFailureReason = "git command not found on PATH"
    }

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    $fallbackSafetyAssessment = Get-FallbackSafetyAssessment -resolvedScanRoot $resolvedScanRoot -comparison $comparison
    $gitIgnorePaths = @($fallbackSafetyAssessment.GitIgnorePaths)

    if ($gitIgnorePaths.Count -gt 0) {
        $gitIgnoreList = $gitIgnorePaths -join "', '"
        throw "E_REMOVE_BOM_GIT_DISCOVERY_REQUIRED: .gitignore found at '$gitIgnoreList', but git-native file discovery is unavailable ($gitDiscoveryFailureReason). Refusing unsafe fallback because ignore-rule semantics cannot be guaranteed. Diagnostics: $($fallbackSafetyAssessment.Diagnostics)"
    }

    if (-not [string]::IsNullOrWhiteSpace($gitDiscoveryFailureReason)) {
        Write-Warning "W_REMOVE_BOM_GIT_DISCOVERY_FALLBACK: $gitDiscoveryFailureReason. Falling back to filesystem traversal after fallback-safety checks. Diagnostics: $($fallbackSafetyAssessment.Diagnostics)"
    }

    $defaultExclusionPatterns = Get-DefaultExclusionPatterns
    return [PSCustomObject]@{
        Mode                     = "filesystem-fallback"
        Diagnostics              = "scanRootInput=$scanRootInput resolvedScanRoot=$resolvedScanRoot fallbackPatterns=$($defaultExclusionPatterns.Count) $($fallbackSafetyAssessment.Diagnostics) streaming=true"
        ResolvedScanRoot         = $resolvedScanRoot
        DefaultExclusionPatterns = @($defaultExclusionPatterns)
    }
}

function Get-ScannableFileStream {
    param(
        [pscustomobject]$scanPlan
    )

    if ($scanPlan.Mode -eq "git-ls-files") {
        $scopeFilteredCount = 0
        $scopeFilteredSample = $null

        & $scanPlan.GitExecutable -C $scanPlan.GitRoot @($scanPlan.GitListArguments) 2>$null |
            ForEach-Object {
                $trimmedRelativePath = $_.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmedRelativePath)) {
                    return
                }

                $candidatePath = Join-Path -Path $scanPlan.GitRoot -ChildPath $trimmedRelativePath
                try {
                    $candidateItem = Get-Item -LiteralPath $candidatePath -ErrorAction Stop
                    if ($candidateItem -is [System.IO.FileInfo]) {
                        if (Test-IsPathUnderRoot -path $candidateItem.FullName -root $scanPlan.ResolvedScanRoot) {
                            Write-Output $candidateItem
                        }
                        else {
                            $scopeFilteredCount++
                            if ($null -eq $scopeFilteredSample) {
                                $scopeFilteredSample = $candidateItem.FullName
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "W_REMOVE_BOM_GIT_DISCOVERY_ITEM_SKIP: Unable to materialize '$candidatePath' from git file list - $($_.Exception.Message)"
                }
            }

        if ($scopeFilteredCount -gt 0) {
            Write-Verbose "Remove-BOM discovery diagnostics: scope-filtered $scopeFilteredCount git-listed file(s) outside '$($scanPlan.ResolvedScanRoot)'. Sample='$scopeFilteredSample'."
        }

        $streamExitCode = $LASTEXITCODE
        if ($streamExitCode -ne 0) {
            $failureProbe = Get-GitCommandDetails -gitExecutable $scanPlan.GitExecutable -workingDirectory $scanPlan.GitRoot -arguments @($scanPlan.GitListArguments)
            $failureDetails = if ($failureProbe.HasOutput) {
                " First output: '$($failureProbe.FirstLine)'."
            }
            else {
                ""
            }
            throw "E_REMOVE_BOM_GIT_STREAM_FAILED: git ls-files failed during streaming enumeration with exit code $streamExitCode for '$($scanPlan.ResolvedScanRoot)'.$failureDetails"
        }
        return
    }

    if ($scanPlan.Mode -eq "filesystem-fallback") {
        Get-ChildItem -LiteralPath $scanPlan.ResolvedScanRoot -File -Recurse |
            Where-Object {
                -not (Test-PathAgainstPatterns -path $_.FullName -patterns $scanPlan.DefaultExclusionPatterns)
            }
        return
    }

    throw "E_REMOVE_BOM_UNKNOWN_DISCOVERY_MODE: Unknown scan discovery mode '$($scanPlan.Mode)'."
}

function Get-ScannableFiles {
    param(
        [string]$scanRoot
    )

    $scanPlan = Resolve-ScannableFileDiscovery -scanRoot $scanRoot
    $files = @(Get-ScannableFileStream -scanPlan $scanPlan)

    if ($scanPlan.Mode -eq "git-ls-files" -and $files.Count -eq 0) {
        $scopeDiagnostics = $null
        $canonicalGitRoot = Resolve-TopLevelPathAlias -path $scanPlan.GitRoot
        $canonicalScanRoot = Resolve-TopLevelPathAlias -path $scanPlan.ResolvedScanRoot
        try {
            $scopeDiagnostics = [System.IO.Path]::GetRelativePath(
                $canonicalGitRoot,
                $canonicalScanRoot
            )
        }
        catch {
            $scopeDiagnostics = $null
        }

        if ([string]::IsNullOrWhiteSpace($scopeDiagnostics)) {
            Write-Verbose "W_REMOVE_BOM_GIT_DISCOVERY_EMPTY_RESULT: Git discovery returned zero files for scan root '$scanRoot'. Diagnostics: $($scanPlan.Diagnostics) canonicalGitRoot=$canonicalGitRoot canonicalScanRoot=$canonicalScanRoot"
        }
        else {
            Write-Verbose "W_REMOVE_BOM_GIT_DISCOVERY_EMPTY_RESULT: Git discovery returned zero files for scan root '$scanRoot'. Diagnostics: $($scanPlan.Diagnostics) relativeScopeFromGitRoot=$scopeDiagnostics canonicalGitRoot=$canonicalGitRoot canonicalScanRoot=$canonicalScanRoot"
        }
    }

    return [PSCustomObject]@{
        Files       = @($files)
        Mode        = $scanPlan.Mode
        Diagnostics = "$($scanPlan.Diagnostics) selectedFiles=$($files.Count)"
    }
}

function Read-FilePrefixBytes {
    param(
        [string]$filePath,
        [ValidateRange(1, 1048576)]
        [int]$byteCount,
        [string]$context
    )

    $fileStream = $null
    try {
        $fileStream = [System.IO.File]::OpenRead($filePath)
        $buffer = New-Object byte[] $byteCount
        $bytesRead = $fileStream.Read($buffer, 0, $byteCount)

        return @{
            Buffer    = $buffer
            BytesRead = $bytesRead
        }
    }
    catch {
        $script:prefixReadFailures++
        Write-Verbose "W_REMOVE_BOM_READ_PREFIX_FAILED ($context): Could not read '$filePath' - $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
    }
}

function Test-IsBinaryFile {
    param(
        [string]$filePath
    )

    try {
        # Check the file extension first for common binary types
        $extension = [System.IO.Path]::GetExtension($filePath).ToLower()
        $binaryExtensions = @(
            '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.ico', '.tiff',
            '.zip', '.gz', '.tar', '.7z', '.rar',
            '.exe', '.dll', '.so', '.dylib',
            '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
            '.mp3', '.mp4', '.avi', '.mov', '.mkv'
        )

        if ($binaryExtensions -contains $extension) {
            return $true
        }

        # Read the first 8KB of the file to check for binary content
        $prefixRead = Read-FilePrefixBytes -filePath $filePath -byteCount 8192 -context "Test-IsBinaryFile"
        if ($null -eq $prefixRead) {
            return $false
        }

        $buffer = $prefixRead.Buffer
        $bytesRead = $prefixRead.BytesRead
        $hasUtf8BomPrefix = $bytesRead -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF
        $contentStartIndex = if ($hasUtf8BomPrefix) { 3 } else { 0 }

        # Check if the content has null bytes (common in binary files)
        for ($i = $contentStartIndex; $i -lt $bytesRead; $i++) {
            if ($buffer[$i] -eq 0) {
                return $true
            }
        }

        # Check for high proportion of non-printable characters
        $nonPrintableCount = 0
        for ($i = $contentStartIndex; $i -lt $bytesRead; $i++) {
            # Consider bytes outside typical ASCII text range as non-printable
            # Excluding common whitespace: tab (9), newline (10), carriage return (13), space (32)
            if (($buffer[$i] -lt 32 -and $buffer[$i] -ne 9 -and $buffer[$i] -ne 10 -and $buffer[$i] -ne 13) -or $buffer[$i] -gt 126) {
                $nonPrintableCount++
            }
        }

        # If more than 10% of characters are non-printable, consider it binary
        $analyzedLength = $bytesRead - $contentStartIndex
        if ($analyzedLength -gt 0 -and ($nonPrintableCount / $analyzedLength) -gt 0.1) {
            return $true
        }
    }
    catch {
        # On error, assume it's not binary to be safe
        Write-Verbose "W_REMOVE_BOM_BINARY_CHECK_FAILED: Error checking if file is binary '$filePath' - $($_.Exception.Message)"
    }

    return $false
}

function Remove-BOMFromFile {
    param(
        [string]$filePath
    )

    try {
        # First check if the file is binary to avoid unnecessary processing
        if (Test-IsBinaryFile -FilePath $filePath) {
            return $false
        }

        # Check if file has BOM by reading just the first few bytes (more efficient)
        $prefixRead = Read-FilePrefixBytes -filePath $filePath -byteCount 3 -context "Remove-BOMFromFile"
        if ($null -eq $prefixRead) {
            return $false
        }

        $buffer = $prefixRead.Buffer
        $bytesRead = $prefixRead.BytesRead

        # Check if file has UTF-8 BOM (EF BB BF)
        if ($bytesRead -eq 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
            # Use the built-in UTF8NoBOM encoding
            $utf8NoBomEncoding = [System.Text.UTF8Encoding]::new($false)

            # Read the entire file content
            $content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)

            # Write the content back without BOM
            # The UTF8Encoding with false parameter will write without BOM
            [System.IO.File]::WriteAllText($filePath, $content, $utf8NoBomEncoding)

            Write-Host "Removed BOM from: $filePath"
            return $true
        }
    }
    catch {
        Write-Warning "W_REMOVE_BOM_PROCESS_FILE_FAILED: Error processing '$filePath' - $($_.Exception.Message)"
    }

    return $false
}


function Invoke-Main {
    param(
        [switch]$DetectOnly,
        [switch]$ShowProgress,
        [string]$Path = ""
    )

    # Main script execution
    $repoRoot = if ($Path) {
        (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }
    else {
        (Get-Location).Path
    }

    $bomCount = 0
    $filesChecked = 0
    $script:prefixReadFailures = 0

    # Show execution mode
    if ($DetectOnly) {
        Write-Host "Running in detection-only mode - no changes will be made" -ForegroundColor Yellow
    }

    $scanPlan = Resolve-ScannableFileDiscovery -scanRoot $repoRoot

    Write-Host "File discovery mode: $($scanPlan.Mode)"
    Write-Verbose "File discovery diagnostics: $($scanPlan.Diagnostics)"
    Write-Host "Scanning files for BOM (this may take a while for large repositories)..."

    # Create a timer to measure performance
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    Get-ScannableFileStream -scanPlan $scanPlan |
        ForEach-Object {
            $file = $_
            $filesChecked++

            # Status update every 1000 files to show progress
            if ($filesChecked % 1000 -eq 0) {
                Write-Verbose "Checked $filesChecked files so far..."
            }

            # Show file being processed if ShowProgress is enabled
            if ($ShowProgress) {
                Write-Host "Processing: $($file.FullName)" -ForegroundColor DarkGray
            }

            if ($DetectOnly) {
                # Just check for BOM but don't remove
                $prefixRead = Read-FilePrefixBytes -filePath $file.FullName -byteCount 3 -context "DetectOnly"

                if ($null -ne $prefixRead) {
                    $buffer = $prefixRead.Buffer
                    $bytesRead = $prefixRead.BytesRead

                    if ($bytesRead -eq 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
                        Write-Host "BOM found in: $($file.FullName)" -ForegroundColor Yellow
                        $bomCount++
                    }
                }
            }
            else {
                # Remove BOM
                if (Remove-BOMFromFile -FilePath $file.FullName) {
                    $bomCount++
                }
            }
        }

    # Stop the timer
    $timer.Stop()
    $elapsedTime = $timer.Elapsed

    # Show summary
    Write-Host ""
    Write-Host "======== Summary ========" -ForegroundColor Cyan
    Write-Host "Mode: $(if ($DetectOnly) { 'Detection only' } else { 'Active (BOM removal)' })"
    Write-Host "File discovery mode: $($scanPlan.Mode)"
    Write-Host "Files checked: $filesChecked"
    Write-Host "Files with BOM: $bomCount"
    Write-Host "Prefix read failures: $script:prefixReadFailures"
    Write-Host "Time taken: $($elapsedTime.ToString('hh\:mm\:ss\.fff'))"
    Write-Host "=========================" -ForegroundColor Cyan

    if ($script:prefixReadFailures -gt 0) {
        Write-Warning "W_REMOVE_BOM_PREFIX_READ_FAILURES: $script:prefixReadFailures file(s) could not be read while scanning file prefixes. Re-run with -Verbose for per-file details."
    }

    if ($DetectOnly) {
        Write-Host "Run the script without -DetectOnly to remove BOMs from the files" -ForegroundColor Yellow
    }
    else {
        Write-Host "BOM removal completed. Total files processed with BOM: $bomCount" -ForegroundColor Green
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Main -DetectOnly:$DetectOnly -ShowProgress:$ShowProgress -Path $Path
}
