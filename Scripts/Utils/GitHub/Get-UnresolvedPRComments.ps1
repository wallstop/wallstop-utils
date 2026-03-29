#!/usr/bin/env pwsh
<#!
.SYNOPSIS
Fetch unresolved GitHub PR review threads and render plain text or JSON output.

.DESCRIPTION
Given a GitHub PR URL, or through an interactive owner/repo/PR picker, this script reads
unresolved review threads and outputs each thread in the required text block format:
---
(path/to/file.ext) lineStart-lineEnd
Comment message
Latest reply summary: <text or (none)>
---

For automation, use -OutputFormat json to emit an array of objects.

.PARAMETER PullRequestUrl
GitHub pull request URL. Supports github.com and GitHub Enterprise Server hosts.
When -GitHubHost is explicitly provided together with -PullRequestUrl, the parsed URL
host must match -GitHubHost exactly after normalization.

.PARAMETER GitHubHost
GitHub host (default: github.com). Used for direct owner/repo mode and interactive
mode. If provided with -PullRequestUrl, it must match the host parsed from the URL.

.PARAMETER AllowedGitHubHosts
Optional host allowlist for defense-in-depth host egress control. Accepts one or
more host values. When omitted, the script also checks environment variables
WALLSTOP_GITHUB_ALLOWED_HOSTS and GITHUB_ALLOWED_HOSTS (comma/semicolon/whitespace
separated), in that order. If an allowlist is present, all resolved hosts and
outbound request hosts must belong to it. Non-empty -AllowedGitHubHosts values
always take precedence over environment fallbacks.

.PARAMETER Owner
Repository owner for interactive or direct owner/repo mode.

.PARAMETER Repo
Repository name for interactive or direct owner/repo mode.

.PARAMETER PullRequestNumber
Pull request number for direct owner/repo mode.

.PARAMETER Token
Explicit GitHub token. This has highest priority if provided.

.PARAMETER OutputFormat
text (default) or json.

.PARAMETER Interactive
Prompt for owner/repo and let the user select an open PR when PullRequestUrl is not provided.

.PARAMETER WaitOnRateLimit
If set, wait until rate-limit reset when 429/403 rate-limit is encountered.

.PARAMETER Truncate
If set, truncate thread comments for compact terminal readability using legacy limits
(500 for top-level comments, 300 for latest replies). By default comments are not truncated.

.PARAMETER Copy
If set, copy the rendered output to clipboard in addition to writing to stdout.
Clipboard copy failures are non-fatal and emit a warning.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PullRequestUrl,

    [Parameter(Mandatory = $false)]
    [string]$Owner,

    [Parameter(Mandatory = $false)]
    [string]$Repo,

    [Parameter(Mandatory = $false)]
    [string]$GitHubHost = "github.com",

    [Parameter(Mandatory = $false)]
    [string[]]$AllowedGitHubHosts = @(),

    [Parameter(Mandatory = $false)]
    [int]$PullRequestNumber,

    [Parameter(Mandatory = $false)]
    [string]$Token,

    [Parameter(Mandatory = $false)]
    [ValidateSet("text", "json")]
    [string]$OutputFormat = "text",

    [Parameter(Mandatory = $false)]
    [switch]$Interactive,

    [Parameter(Mandatory = $false)]
    [switch]$WaitOnRateLimit,

    [Parameter(Mandatory = $false)]
    [switch]$Truncate,

    [Parameter(Mandatory = $false)]
    [switch]$Copy,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$PerPage = 100,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MaxPages = 100,

    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 300)]
    [int]$RequestTimeoutSeconds = 60,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 3600)]
    [int]$OverallTimeoutSeconds = 300,

    [Parameter(Mandatory = $false)]
    [switch]$NoRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:TopLevelBoundParameters = @{} + $PSBoundParameters

$strictModeHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/StrictModeHelpers.ps1"
if (-not (Test-Path -Path $strictModeHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Strict mode helper file not found at '$strictModeHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

. $strictModeHelpersPath

function Redact-SensitiveText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    $redacted = $Text
    foreach ($secret in $SensitiveTokens) {
        if ([string]::IsNullOrWhiteSpace($secret)) {
            continue
        }

        $escaped = [regex]::Escape($secret)
        $redacted = [regex]::Replace($redacted, $escaped, "***REDACTED***")
    }

    # Generic token redaction for accidental echoes.
    $redacted = $redacted -replace "ghp_[A-Za-z0-9]{36}", "***REDACTED***"
    $redacted = $redacted -replace "github_pat_[A-Za-z0-9_]{80,}", "***REDACTED***"
    $redacted = $redacted -replace "(Bearer|token)\s+[A-Za-z0-9_\-\.]{20,}", '$1 ***REDACTED***'

    return $redacted
}

function Get-HttpStatusCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    if ($null -ne $Exception.PSObject.Properties["Response"] -and $null -ne $Exception.Response) {
        if ($null -ne $Exception.Response.PSObject.Properties["StatusCode"] -and $null -ne $Exception.Response.StatusCode) {
            return [int]$Exception.Response.StatusCode
        }
    }

    if ($Exception.PSObject.Properties["StatusCode"] -and $null -ne $Exception.StatusCode) {
        return [int]$Exception.StatusCode
    }

    return $null
}

function Get-ResponseHeaders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    if ($null -ne $Exception.PSObject.Properties["Response"] -and $null -ne $Exception.Response) {
        if ($null -ne $Exception.Response.PSObject.Properties["Headers"] -and $null -ne $Exception.Response.Headers) {
            return $Exception.Response.Headers
        }
    }

    return $null
}

function Convert-ToStringArray {
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    if ($Value -is [string]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $result = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            if ($null -eq $item) {
                continue
            }

            $result.Add([string]$item) | Out-Null
        }

        return @($result)
    }

    return @([string]$Value)
}

function Get-HeaderValues {
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Headers,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ($null -eq $Headers) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    $possibleKeys = @($Key, $Key.ToLowerInvariant(), $Key.ToUpperInvariant())
    foreach ($candidate in $possibleKeys) {
        if ($Headers.PSObject.Methods.Name -contains "TryGetValues") {
            $values = $null
            try {
                if ($Headers.TryGetValues($candidate, [ref]$values)) {
                    return @(Convert-ToStringArray -Value $values)
                }
            } catch {
                # Continue to alternative lookup paths.
            }
        }

        if ($Headers.PSObject.Methods.Name -contains "ContainsKey") {
            if ($Headers.ContainsKey($candidate)) {
                return @(Convert-ToStringArray -Value $Headers[$candidate])
            }
        }

        if ($Headers -is [System.Collections.IDictionary] -and $Headers.Keys -contains $candidate) {
            return @(Convert-ToStringArray -Value $Headers[$candidate])
        }

        if ($Headers.PSObject.Properties.Name -contains $candidate) {
            return @(Convert-ToStringArray -Value $Headers.$candidate)
        }
    }

    if ($Headers.PSObject.Methods.Name -notcontains "GetEnumerator") {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    # Fallback for dictionary enumerables with case-insensitive keys.
    foreach ($entry in $Headers.GetEnumerator()) {
        if ($null -eq $entry) {
            continue
        }

        if ($entry.PSObject.Properties.Name -contains "Key" -and $null -ne $entry.Key) {
            if ([string]$entry.Key -ieq $Key) {
                return @(Convert-ToStringArray -Value $entry.Value)
            }
        }
    }

    return @() # array-unwrap-safe: callers always wrap with @()
}

function Get-HeaderValueDiagnostics {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $false)]
        [string[]]$Values = @()
    )

    $valueCount = Get-SafeCount -InputObject $Values
    if ($valueCount -eq 0) {
        return "Header '$Key' returned no values."
    }

    $preview = @($Values | Select-Object -First 3 | ForEach-Object {
            if ($_.Length -gt 80) {
                $_.Substring(0, 80) + "..."
            } else {
                $_
            }
        })

    $previewText = if ($preview.Count -gt 0) {
        "'" + ($preview -join "', '") + "'"
    } else {
        "(none)"
    }

    if ($valueCount -gt 3) {
        return "Header '$Key' returned $valueCount values. Preview: $previewText, '...'."
    }

    return "Header '$Key' returned $valueCount value(s). Values: $previewText."
}

function Get-SingleHeaderValueOrThrow {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Headers,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter(Mandatory = $false)]
        [string]$ErrorCode = "E_MALFORMED_RESPONSE",

        [Parameter(Mandatory = $false)]
        [switch]$AllowMissing
    )

    $values = @(Get-HeaderValues -Headers $Headers -Key $Key)
    $valueCount = Get-SafeCount -InputObject $values
    if ($valueCount -eq 0) {
        if ($AllowMissing.IsPresent) {
            return $null
        }

        throw "${ErrorCode}: Missing $Context. $(Get-HeaderValueDiagnostics -Key $Key -Values $values)"
    }

    if ($valueCount -gt 1) {
        throw "${ErrorCode}: Expected exactly one value for $Context but received $valueCount. $(Get-HeaderValueDiagnostics -Key $Key -Values $values)"
    }

    return $values[0]
}

function Get-FirstNonEmptyStringValue {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    $values = @(Convert-ToStringArray -Value $Value)
    foreach ($candidate in $values) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return $null
}

function Test-HasRateLimitHeaders {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Headers
    )

    if ($null -eq $Headers) {
        return $false
    }

    # GitHub rate-limit classification relies on reset/retry headers.
    $resetValue = Get-FirstNonEmptyStringValue -Value (Get-HeaderValues -Headers $Headers -Key "X-RateLimit-Reset")
    $retryAfterValue = Get-FirstNonEmptyStringValue -Value (Get-HeaderValues -Headers $Headers -Key "Retry-After")

    return (-not [string]::IsNullOrWhiteSpace($resetValue)) -or (-not [string]::IsNullOrWhiteSpace($retryAfterValue))
}

function Get-HeaderValue {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Headers,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ($null -eq $Headers) {
        return $null
    }

    $values = @(Get-HeaderValues -Headers $Headers -Key $Key)
    if ((Get-SafeCount -InputObject $values) -eq 0) {
        return $null
    }

    return $values[0]
}

function Assert-GitHubHostFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $false)]
        [string]$Context = "GitHub host"
    )

    if ([string]::IsNullOrWhiteSpace($GitHubHost)) {
        throw "E_INVALID_URL: Host cannot be empty in $Context."
    }

    $normalizedHost = $GitHubHost.Trim().ToLowerInvariant()

    $hostPattern = '^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$'
    if ($normalizedHost -notmatch $hostPattern) {
        throw "E_INVALID_URL: Invalid host format in $Context. Host '$normalizedHost' (length=$($normalizedHost.Length)) must use DNS labels with alphanumeric boundaries."
    }

    if (-not (Test-GitHubHostAllowed -GitHubHost $normalizedHost)) {
        throw "E_INVALID_URL: Host '$normalizedHost' is not allowed for safety reasons in $Context."
    }

    return $normalizedHost
}

function Assert-GitHubOwnerRepoFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $false)]
        [string]$Context = "owner/repo input"
    )

    if ([string]::IsNullOrWhiteSpace($Owner)) {
        throw "E_INVALID_OWNER_REPO: Owner cannot be empty in $Context."
    }

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        throw "E_INVALID_OWNER_REPO: Repository cannot be empty in $Context."
    }

    $normalizedOwner = $Owner.Trim()
    $normalizedRepo = $Repo.Trim()

    $ownerPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,38}$'
    if ($normalizedOwner -notmatch $ownerPattern) {
        throw "E_INVALID_OWNER_REPO: Invalid owner format in $Context. Owner '$normalizedOwner' (length=$($normalizedOwner.Length)) must start with alphanumeric and be 1-39 chars using letters, digits, '.', '_', or '-'."
    }

    $repoPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
    if ($normalizedRepo -notmatch $repoPattern) {
        throw "E_INVALID_OWNER_REPO: Invalid repository format in $Context. Repository '$normalizedRepo' (length=$($normalizedRepo.Length)) must start with alphanumeric and be 1-100 chars using letters, digits, '.', '_', or '-'."
    }

    return [pscustomobject]@{
        Owner = $normalizedOwner
        Repo = $normalizedRepo
    }
}

function Parse-GitHubPullRequestUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "E_INVALID_URL: Pull request URL cannot be empty."
    }

    $trimmed = $Url.Trim()
    $regex = '^https://(?<host>[A-Za-z0-9.-]+)/(?<owner>[^/\s\?#]+)/(?<repo>[^/\s\?#]+)/pull/(?<pr>\d+)(?:$|/|\?|#)'

    $match = [regex]::Match($trimmed, $regex)
    if (-not $match.Success) {
        throw "E_INVALID_URL: Expected format https://github.com/owner/repo/pull/123"
    }

    $hostValue = Assert-GitHubHostFormat -GitHubHost $match.Groups["host"].Value -Context "PullRequestUrl"
    $validatedOwnerRepo = Assert-GitHubOwnerRepoFormat -Owner $match.Groups["owner"].Value -Repo $match.Groups["repo"].Value -Context "PullRequestUrl"

    return [pscustomobject]@{
        Host            = $hostValue
        Owner           = $validatedOwnerRepo.Owner
        Repo            = $validatedOwnerRepo.Repo
        PullRequestNumber = [int]$match.Groups["pr"].Value
    }
}

function Test-GitHubHostAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitHubHost
    )

    if ([string]::IsNullOrWhiteSpace($GitHubHost)) {
        return $false
    }

    $lower = $GitHubHost.Trim().ToLowerInvariant()
    if ($lower -eq "localhost") {
        return $false
    }

    [System.Net.IPAddress]$parsedIp = $null
    if ([System.Net.IPAddress]::TryParse($lower, [ref]$parsedIp)) {
        return Test-GitHubIPAddressAllowed -IPAddress $parsedIp
    }

    return $true
}

function Test-GitHubIPAddressAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]$IPAddress
    )

    if ($IPAddress.IsIPv4MappedToIPv6) {
        return Test-GitHubIPAddressAllowed -IPAddress $IPAddress.MapToIPv4()
    }

    if ($IPAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $bytes = $IPAddress.GetAddressBytes()
        $octet0 = [int]$bytes[0]
        $octet1 = [int]$bytes[1]
        $octet2 = [int]$bytes[2]

        if ($octet0 -eq 0 -or $octet0 -eq 10 -or $octet0 -eq 127) {
            return $false
        }

        if ($octet0 -eq 100 -and $octet1 -ge 64 -and $octet1 -le 127) {
            return $false
        }

        if ($octet0 -eq 169 -and $octet1 -eq 254) {
            return $false
        }

        if ($octet0 -eq 172 -and $octet1 -ge 16 -and $octet1 -le 31) {
            return $false
        }

        if ($octet0 -eq 192 -and $octet1 -eq 168) {
            return $false
        }

        if ($octet0 -eq 192 -and $octet1 -eq 0 -and ($octet2 -eq 0 -or $octet2 -eq 2)) {
            return $false
        }

        if ($octet0 -eq 198 -and ($octet1 -eq 18 -or $octet1 -eq 19)) {
            return $false
        }

        if ($octet0 -eq 198 -and $octet1 -eq 51 -and $octet2 -eq 100) {
            return $false
        }

        if ($octet0 -eq 203 -and $octet1 -eq 0 -and $octet2 -eq 113) {
            return $false
        }

        if ($octet0 -ge 224) {
            return $false
        }

        return $true
    }

    if ($IPAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($IPAddress.Equals([System.Net.IPAddress]::IPv6Loopback) -or $IPAddress.Equals([System.Net.IPAddress]::IPv6None)) {
            return $false
        }

        if ($IPAddress.IsIPv6LinkLocal -or $IPAddress.IsIPv6SiteLocal -or $IPAddress.IsIPv6Multicast) {
            return $false
        }

        $bytes = $IPAddress.GetAddressBytes()
        if (($bytes[0] -band 0xFE) -eq 0xFC) {
            return $false
        }

        if ($bytes[0] -eq 0x20 -and $bytes[1] -eq 0x01 -and $bytes[2] -eq 0x0D -and $bytes[3] -eq 0xB8) {
            return $false
        }

        return $true
    }

    return $false
}

function Get-NormalizedGitHubHostAllowlist {
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHosts = @()
    )

    $rawHosts = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($AllowedGitHubHosts)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $rawHosts.Add($candidate.Trim()) | Out-Null
        }
    }

    if ($rawHosts.Count -eq 0) {
        $envAllowlist = if (-not [string]::IsNullOrWhiteSpace($env:WALLSTOP_GITHUB_ALLOWED_HOSTS)) {
            $env:WALLSTOP_GITHUB_ALLOWED_HOSTS
        } elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ALLOWED_HOSTS)) {
            $env:GITHUB_ALLOWED_HOSTS
        } else {
            $null
        }

        if (-not [string]::IsNullOrWhiteSpace($envAllowlist)) {
            $parts = @([regex]::Split($envAllowlist, '[,;\s]+'))
            foreach ($part in $parts) {
                if (-not [string]::IsNullOrWhiteSpace($part)) {
                    $rawHosts.Add($part.Trim()) | Out-Null
                }
            }
        }
    }

    if ($rawHosts.Count -eq 0) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    $seenHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $normalizedHosts = New-Object System.Collections.Generic.List[string]
    foreach ($rawHost in $rawHosts) {
        try {
            $normalizedHost = Assert-GitHubHostFormat -GitHubHost $rawHost -Context "AllowedGitHubHosts"
        } catch {
            $safeMessage = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens @()
            throw "E_CONFIG_ERROR: Invalid host allowlist entry '$rawHost'. $safeMessage"
        }

        if ($seenHosts.Add($normalizedHost)) {
            $normalizedHosts.Add($normalizedHost) | Out-Null
        }
    }

    return $normalizedHosts.ToArray()
}

function Assert-GitHubHostInAllowlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHosts = @(),

        [Parameter(Mandatory = $false)]
        [string]$Context = "GitHub host"
    )

    if ((Get-SafeCount -InputObject $AllowedGitHubHosts) -eq 0) {
        return
    }

    $normalizedHost = $GitHubHost.Trim().ToLowerInvariant()
    if (-not (@($AllowedGitHubHosts) -contains $normalizedHost)) {
        throw "E_INVALID_URL: Host '$normalizedHost' is not in the configured allowed GitHub host list for $Context."
    }
}

function Assert-GitHubRequestUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [string]$Context = "GitHub request",

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHosts = @()
    )

    if ([string]::IsNullOrWhiteSpace($Uri)) {
        throw "E_INVALID_URL: Request URI cannot be empty in $Context."
    }

    [System.Uri]$parsedUri = $null
    if (-not [System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$parsedUri)) {
        throw "E_INVALID_URL: Request URI '$Uri' is not a valid absolute URI in $Context."
    }

    if (-not $parsedUri.Scheme.Equals("https", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "E_INVALID_URL: Only https request URIs are allowed in $Context (received '$($parsedUri.Scheme)')."
    }

    if (-not [string]::IsNullOrWhiteSpace($parsedUri.UserInfo)) {
        throw "E_INVALID_URL: Request URI user-info is not allowed in $Context."
    }

    $normalizedHost = Assert-GitHubHostFormat -GitHubHost $parsedUri.DnsSafeHost -Context "$Context URI"
    Assert-GitHubHostInAllowlist -GitHubHost $normalizedHost -AllowedGitHubHosts $AllowedGitHubHosts -Context "$Context URI"
}

function Resolve-GitHubGraphQLEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitHubHost
    )

    $normalizedHost = Assert-GitHubHostFormat -GitHubHost $GitHubHost -Context "Resolve-GitHubGraphQLEndpoint"

    if ($normalizedHost.Equals("github.com", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "https://api.github.com/graphql"
    }

    return "https://$normalizedHost/api/graphql"
}

function Get-GitHubHeaders {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AuthToken
    )

    [hashtable]$headers = @{
        "Accept" = "application/vnd.github+json"
        "User-Agent" = "wallstop-utils-unresolved-pr-comments"
    }

    if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
        $headers["Authorization"] = "Bearer $AuthToken"
    }

    return [hashtable]$headers
}

function Normalize-CommentText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [ValidateRange(10, 20000)]
        [int]$MaxLength = 500,

        [Parameter(Mandatory = $false)]
        [switch]$DisableTruncation
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "(none)"
    }

    $singleLine = (($Text -replace "\r\n", " ") -replace "\n", " " -replace "\r", " ").Trim()
    if ($DisableTruncation.IsPresent) {
        return $singleLine
    }

    if ($singleLine.Length -le $MaxLength) {
        return $singleLine
    }

    return ($singleLine.Substring(0, $MaxLength) + " [...]")
}

function Get-ClipboardCommand {
    [OutputType([string])]
    [CmdletBinding()]
    param()

    if ($null -ne (Get-Command Set-Clipboard -ErrorAction SilentlyContinue)) {
        return "Set-Clipboard"
    }

    $fallbackCommands = @("pbcopy", "xclip", "xsel", "wl-copy")
    foreach ($commandName in $fallbackCommands) {
        if ($null -ne (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            return $commandName
        }
    }

    return $null
}

function Copy-ToClipboard {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    $clipboardCommand = Get-ClipboardCommand
    if ([string]::IsNullOrWhiteSpace($clipboardCommand)) {
        Write-Warning "W_CLIPBOARD_UNAVAILABLE: No clipboard command is available (tried Set-Clipboard, pbcopy, xclip, xsel, wl-copy)."
        return $false
    }

    $valueToCopy = if ($null -eq $Text) { "" } else { $Text }

    try {
        switch ($clipboardCommand) {
            "Set-Clipboard" {
                Set-Clipboard -Value $valueToCopy
                break
            }
            "pbcopy" {
                $valueToCopy | & pbcopy
                break
            }
            "xclip" {
                $valueToCopy | & xclip -selection clipboard
                break
            }
            "xsel" {
                $valueToCopy | & xsel --clipboard --input
                break
            }
            "wl-copy" {
                $valueToCopy | & wl-copy
                break
            }
            default {
                Write-Warning "W_CLIPBOARD_UNAVAILABLE: Clipboard command '$clipboardCommand' is not supported by this script."
                return $false
            }
        }

        return $true
    } catch {
        $safeMessage = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $SensitiveTokens
        Write-Warning "W_CLIPBOARD_COPY_FAILED: Failed to copy output using '$clipboardCommand'. $safeMessage"
        return $false
    }
}

function Test-CanPromptForLogin {
    [CmdletBinding()]
    param()

    try {
        return (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
    } catch {
        return $false
    }
}

function Get-AuthToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ExplicitToken,

        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $false)]
        [switch]$AllowInteractive
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitToken)) {
        return $ExplicitToken.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        return $env:GITHUB_TOKEN.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        return $env:GH_TOKEN.Trim()
    }

    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $ghCmd) {
        if ($AllowInteractive.IsPresent) {
            throw "E_AUTH_REQUIRED: GitHub CLI (gh) is required for interactive login but is not installed."
        }

        return $null
    }

    try {
        $tokenOutput = & gh auth token --hostname $GitHubHost 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($tokenOutput)) {
            return $tokenOutput.Trim()
        }
    } catch {
        # Continue to interactive fallback only if allowed.
    }

    if (-not $AllowInteractive.IsPresent) {
        return $null
    }

    if (-not (Test-CanPromptForLogin)) {
        throw "E_AUTH_REQUIRED: Interactive login is unavailable because input/output is redirected. Provide -Token or set GITHUB_TOKEN/GH_TOKEN."
    }

    Write-Host "No GitHub token found. Starting GitHub CLI login for $GitHubHost..." -ForegroundColor Yellow
    & gh auth login --hostname $GitHubHost --web --git-protocol https --scopes repo | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "E_AUTH_REQUIRED: GitHub CLI login was not completed."
    }

    $tokenOutput = & gh auth token --hostname $GitHubHost 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($tokenOutput)) {
        return $tokenOutput.Trim()
    }

    throw "E_AUTH_REQUIRED: Login succeeded but no token was returned by GitHub CLI."
}

function Invoke-GitHubRequestWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Body,

        [Parameter(Mandatory = $true)]
        [int]$RequestTimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxRetries,

        [Parameter(Mandatory = $true)]
        [datetime]$OverallDeadlineUtc,

        [Parameter(Mandatory = $false)]
        [switch]$WaitOnRateLimit,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHostsNormalized = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    $attempt = 0
    Assert-GitHubRequestUri -Uri $Uri -Context "Invoke-GitHubRequestWithRetry" -AllowedGitHubHosts $AllowedGitHubHostsNormalized

    while ($true) {
        $attempt++

        if ([datetime]::UtcNow -gt $OverallDeadlineUtc) {
            throw "E_NETWORK_TIMEOUT: Overall timeout exceeded while calling GitHub API."
        }

        try {
            if ($Method -eq "GET") {
                return Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -TimeoutSec $RequestTimeoutSeconds
            }

            $jsonBody = if ($null -eq $Body) { "{}" } else { $Body | ConvertTo-Json -Depth 20 }
            return Invoke-RestMethod -Method POST -Uri $Uri -Headers $Headers -ContentType "application/json" -Body $jsonBody -TimeoutSec $RequestTimeoutSeconds
        } catch {
            $statusCode = Get-HttpStatusCode -Exception $_.Exception
            $responseHeaders = Get-ResponseHeaders -Exception $_.Exception

            if (($statusCode -eq 429 -or $statusCode -eq 403) -and $WaitOnRateLimit.IsPresent) {
                $resetValue = Get-SingleHeaderValueOrThrow -Headers $responseHeaders -Key "X-RateLimit-Reset" -Context "X-RateLimit-Reset while handling status $statusCode" -ErrorCode "E_RATE_LIMIT" -AllowMissing
                if ($null -eq $resetValue) {
                    $retryAfterValue = Get-SingleHeaderValueOrThrow -Headers $responseHeaders -Key "Retry-After" -Context "Retry-After while handling status $statusCode" -ErrorCode "E_RATE_LIMIT" -AllowMissing
                    if (-not [string]::IsNullOrWhiteSpace($retryAfterValue)) {
                        $retryAfterCandidate = $retryAfterValue.Trim()
                        $retryAfterSeconds = 0
                        if ([int]::TryParse($retryAfterCandidate, [ref]$retryAfterSeconds) -and $retryAfterSeconds -gt 0) {
                            $resetValue = ([DateTimeOffset]::UtcNow.AddSeconds($retryAfterSeconds + 1).ToUnixTimeSeconds()).ToString()
                        } else {
                            $retryAfterDate = [DateTimeOffset]::MinValue
                            if ([DateTimeOffset]::TryParseExact($retryAfterCandidate, "r", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$retryAfterDate)) {
                                $resetValue = $retryAfterDate.ToUnixTimeSeconds().ToString()
                            } else {
                                throw "E_RATE_LIMIT: Invalid Retry-After value '$retryAfterCandidate'. $(Get-HeaderValueDiagnostics -Key 'Retry-After' -Values @($retryAfterValue))"
                            }
                        }
                    }
                }

                if ($null -ne $resetValue) {
                    $resetEpoch = [int64]0
                    if (-not [int64]::TryParse($resetValue, [ref]$resetEpoch)) {
                        throw "E_RATE_LIMIT: Invalid rate-limit reset value '$resetValue'. $(Get-HeaderValueDiagnostics -Key 'X-RateLimit-Reset' -Values @($resetValue))"
                    }

                    $resetUtc = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).UtcDateTime
                    if ($resetUtc -le [datetime]::UtcNow) {
                        throw "E_RATE_LIMIT: Invalid or expired rate-limit reset timestamp."
                    }

                    $timeToReset = $resetUtc - [datetime]::UtcNow
                    if ($timeToReset.TotalSeconds -gt [int]::MaxValue) {
                        throw "E_RATE_LIMIT: Rate-limit reset timestamp is too far in the future."
                    }

                    $waitSeconds = [int][Math]::Ceiling($timeToReset.TotalSeconds)
                    if ($waitSeconds -lt 1) {
                        $waitSeconds = 1
                    }

                    if ([datetime]::UtcNow.AddSeconds($waitSeconds) -gt $OverallDeadlineUtc) {
                        throw "E_NETWORK_TIMEOUT: Overall timeout would be exceeded while waiting for rate-limit reset."
                    }

                    Start-Sleep -Seconds $waitSeconds
                    continue
                }
            }

            if (($statusCode -eq 429 -or $statusCode -eq 403 -or $statusCode -ge 500 -or $null -eq $statusCode) -and $attempt -le $MaxRetries) {
                $baseDelay = [Math]::Pow(2, $attempt - 1)
                $jitterMs = Get-Random -Minimum 0 -Maximum 300
                Start-Sleep -Milliseconds ([int]($baseDelay * 1000 + $jitterMs))
                continue
            }

            $errorText = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $SensitiveTokens
            if ($statusCode -eq 401) {
                throw "E_AUTH_INVALID: Authentication failed. $errorText"
            }
            if ($statusCode -eq 403) {
                $hasRateLimitHeaders = Test-HasRateLimitHeaders -Headers $responseHeaders
                if ($hasRateLimitHeaders) {
                    throw "E_RATE_LIMIT_403: GitHub API temporarily rate-limited this request. Retry with -WaitOnRateLimit or reduce request frequency. $errorText"
                }

                throw "E_FORBIDDEN: Access denied. $errorText"
            }
            if ($statusCode -eq 404) {
                throw "E_NOT_FOUND: Resource not found. $errorText"
            }

            if ($null -eq $statusCode) {
                throw "E_NETWORK_ERROR: GitHub request failed without an HTTP status (attempt $attempt of $($MaxRetries + 1)). $errorText"
            }

            throw "E_GITHUB_API_ERROR($statusCode): GitHub request failed (attempt $attempt of $($MaxRetries + 1)). $errorText"
        }
    }
}

function Get-OpenPullRequests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [ValidateRange(5, 300)]
        [int]$RequestTimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [datetime]$OverallDeadlineUtc,

        [Parameter(Mandatory = $false)]
        [switch]$WaitOnRateLimit,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHostsNormalized = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    $base = if ($GitHubHost -eq "github.com") { "https://api.github.com" } else { "https://$GitHubHost/api/v3" }
    $uri = "$base/repos/$Owner/$Repo/pulls?state=open&per_page=50"

    $pulls = Invoke-GitHubRequestWithRetry -Method GET -Uri $uri -Headers $Headers -RequestTimeoutSeconds $RequestTimeoutSeconds -MaxRetries 3 -OverallDeadlineUtc $OverallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -AllowedGitHubHostsNormalized $AllowedGitHubHostsNormalized -SensitiveTokens $SensitiveTokens
    if ($null -eq $pulls) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    return @($pulls)
}

function Validate-GitHubTokenForRepoAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [datetime]$OverallDeadlineUtc,

        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 300)]
        [int]$RequestTimeoutSeconds = 60,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHostsNormalized = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    $base = if ($GitHubHost -eq "github.com") { "https://api.github.com" } else { "https://$GitHubHost/api/v3" }
    $uri = "$base/repos/$Owner/$Repo"
    $maxRetries = 2
    $attempt = 0
    Assert-GitHubRequestUri -Uri $uri -Context "Validate-GitHubTokenForRepoAccess" -AllowedGitHubHosts $AllowedGitHubHostsNormalized

    while ($true) {
        $attempt++

        $remainingSeconds = [int][Math]::Floor(($OverallDeadlineUtc - [datetime]::UtcNow).TotalSeconds)
        if ($remainingSeconds -lt 1) {
            throw "E_NETWORK_TIMEOUT: Token validation deadline was exceeded before request start for $Owner/$Repo on $GitHubHost."
        }

        $effectiveRequestTimeoutSeconds = [Math]::Min($RequestTimeoutSeconds, $remainingSeconds)
        if ($effectiveRequestTimeoutSeconds -lt 1) {
            throw "E_NETWORK_TIMEOUT: Token validation timeout budget is exhausted for $Owner/$Repo on $GitHubHost."
        }

        try {
            $response = Invoke-WebRequest -Method GET -Uri $uri -Headers $Headers -TimeoutSec $effectiveRequestTimeoutSeconds
            $repoMetadata = $null
            if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
                $repoMetadata = ConvertFrom-JsonSingleObject -Json $response.Content -Context "Repository metadata response"
            }

            if ($GitHubHost -eq "github.com") {
                $scopeHeaderValues = @(Get-HeaderValues -Headers $response.Headers -Key "X-OAuth-Scopes")
                if ((Get-SafeCount -InputObject $scopeHeaderValues) -eq 0) {
                    throw "E_MALFORMED_RESPONSE: Token scope header was not returned by GitHub."
                }

                $scopes = @()
                foreach ($scopeHeaderValue in $scopeHeaderValues) {
                    foreach ($scope in $scopeHeaderValue.Split(",")) {
                        $trimmed = $scope.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                            $scopes += $trimmed
                        }
                    }
                }

                if ($scopes.Count -eq 0) {
                    throw "E_MALFORMED_RESPONSE: Token scope header did not contain any non-empty scope values. $(Get-HeaderValueDiagnostics -Key 'X-OAuth-Scopes' -Values $scopeHeaderValues)"
                }

                $isPrivateRepo = $false
                if ($null -ne $repoMetadata -and $repoMetadata.PSObject.Properties.Name -contains "private") {
                    $isPrivateRepo = [bool]$repoMetadata.private
                }

                if ($isPrivateRepo -and -not ($scopes -contains "repo")) {
                    throw "E_AUTH_INSUFFICIENT_SCOPE: Token does not include required 'repo' scope for private repository access."
                }

                if (-not $isPrivateRepo -and -not (($scopes -contains "repo") -or ($scopes -contains "public_repo"))) {
                    throw "E_AUTH_INSUFFICIENT_SCOPE: Token does not include 'repo' or 'public_repo' scope."
                }
            }

            return
        }
        catch {
            $responseHeaders = Get-ResponseHeaders -Exception $_.Exception
            $statusCode = Get-HttpStatusCode -Exception $_.Exception
            $rawMessage = [string]$_.Exception.Message
            $safeMessage = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $SensitiveTokens

            if ($rawMessage -like "E_AUTH_INSUFFICIENT_SCOPE:*" -or $rawMessage -like "E_MALFORMED_RESPONSE:*" -or $rawMessage -like "E_CONFIG_ERROR:*" -or $rawMessage -like "E_NETWORK_TIMEOUT:*") {
                throw $safeMessage
            }

            $isRetryableTransient = $null -eq $statusCode -or $statusCode -ge 500
            if ($isRetryableTransient -and $attempt -le $maxRetries) {
                $baseDelaySeconds = [Math]::Pow(2, $attempt - 1)
                $jitterMs = Get-Random -Minimum 0 -Maximum 300
                $delayMs = [int]($baseDelaySeconds * 1000 + $jitterMs)

                $remainingDelayBudgetMs = [int][Math]::Floor(($OverallDeadlineUtc - [datetime]::UtcNow).TotalMilliseconds)
                if ($remainingDelayBudgetMs -le 0 -or $delayMs -gt $remainingDelayBudgetMs) {
                    throw "E_NETWORK_TIMEOUT: Token validation retry budget exceeded for $Owner/$Repo on $GitHubHost after attempt $attempt of $($maxRetries + 1)."
                }

                Write-Verbose "Retrying token validation request for $Owner/$Repo on $GitHubHost after transient failure (status=$statusCode, attempt=$attempt of $($maxRetries + 1))."
                Start-Sleep -Milliseconds $delayMs
                continue
            }

            if ($statusCode -eq 401) {
                throw "E_AUTH_INVALID: Token authentication failed while validating repository access. $safeMessage"
            }

            if ($statusCode -eq 429) {
                throw "E_AUTH_RATE_LIMITED: Token validation was rate-limited by GitHub (HTTP $statusCode). Retry after a short delay. $safeMessage"
            }

            if ($statusCode -eq 403) {
                $hasRateLimitHeaders = Test-HasRateLimitHeaders -Headers $responseHeaders
                if ($hasRateLimitHeaders) {
                    throw "E_AUTH_RATE_LIMITED: Token validation was rate-limited by GitHub (HTTP $statusCode). Retry after a short delay. $safeMessage"
                }

                $headerKeys = @()
                if ($null -ne $responseHeaders -and $responseHeaders -is [System.Collections.IDictionary]) {
                    $headerKeys = @($responseHeaders.Keys | ForEach-Object { [string]$_ })
                }

                $headerDiagnostics = if ((Get-SafeCount -InputObject $headerKeys) -gt 0) {
                    "Headers seen: $($headerKeys -join ', ')"
                } else {
                    "Headers seen: (none)"
                }

                throw "E_FORBIDDEN: Token could not access repository metadata for $Owner/$Repo on $GitHubHost. $headerDiagnostics $safeMessage"
            }

            if ($statusCode -eq 404) {
                throw "E_NOT_FOUND: Repository $Owner/$Repo was not found on $GitHubHost. $safeMessage"
            }

            if ($null -eq $statusCode) {
                throw "E_NETWORK_ERROR: Token validation request did not receive an HTTP response after attempt $attempt of $($maxRetries + 1). $safeMessage"
            }

            throw "E_GITHUB_API_ERROR($statusCode): Token validation request failed after attempt $attempt of $($maxRetries + 1). $safeMessage"
        }
    }
}

function Select-PullRequestInteractively {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [ValidateRange(5, 300)]
        [int]$RequestTimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [datetime]$OverallDeadlineUtc,

        [Parameter(Mandatory = $false)]
        [switch]$WaitOnRateLimit,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHostsNormalized = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    $ownerInput = Read-Host "GitHub owner"
    if ([string]::IsNullOrWhiteSpace($ownerInput)) {
        throw "E_INVALID_OWNER_REPO: Owner cannot be empty."
    }

    $repoInput = Read-Host "Repository"
    if ([string]::IsNullOrWhiteSpace($repoInput)) {
        throw "E_INVALID_OWNER_REPO: Repository cannot be empty."
    }

    $ownerInput = $ownerInput.Trim()
    $repoInput = $repoInput.Trim()

    $validatedOwnerRepo = Assert-GitHubOwnerRepoFormat -Owner $ownerInput -Repo $repoInput -Context "interactive input"
    $ownerInput = $validatedOwnerRepo.Owner
    $repoInput = $validatedOwnerRepo.Repo

    $pulls = @(Get-OpenPullRequests -Owner $ownerInput -Repo $repoInput -GitHubHost $GitHubHost -Headers $Headers -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $OverallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -AllowedGitHubHostsNormalized $AllowedGitHubHostsNormalized -SensitiveTokens $SensitiveTokens)
    $pullCount = Get-SafeCount -InputObject $pulls
    if ($pullCount -eq 0) {
        throw "E_NOT_FOUND: No open pull requests were found for $ownerInput/$repoInput."
    }

    Write-Host "Open pull requests:" -ForegroundColor Cyan
    $i = 1
    foreach ($pr in $pulls) {
        $title = Normalize-CommentText -Text $pr.title -MaxLength 90
        Write-Host ("[{0}] #{1} {2}" -f $i, $pr.number, $title)
        $i++
    }

    $selection = Read-Host "Choose an index or PR number"
    if ([string]::IsNullOrWhiteSpace($selection)) {
        throw "E_INVALID_URL: No selection was provided."
    }

    if ($selection -eq "q") {
        return $null
    }

    $selectedPr = $null
    if ($selection -match "^\d+$") {
        $numeric = [int]$selection
        if ($numeric -ge 1 -and $numeric -le $pullCount) {
            $selectedPr = $pulls[$numeric - 1]
        } else {
            $selectedPr = $pulls | Where-Object { $_.number -eq $numeric } | Select-Object -First 1
        }
    }

    if ($null -eq $selectedPr) {
        throw "E_INVALID_URL: Selection did not match a listed pull request."
    }

    return [pscustomobject]@{
        Host              = $GitHubHost
        Owner             = $ownerInput
        Repo              = $repoInput
        PullRequestNumber = [int]$selectedPr.number
    }
}

function Convert-ReviewThreadToOutputRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Thread,

        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [int]$PrNumber,

        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $false)]
        [switch]$Truncate
    )

    if ($Thread.isResolved) {
        return $null
    }

    if ($null -eq $Thread.comments -or $null -eq $Thread.comments.nodes) {
        return $null
    }

    if ($Thread.comments.nodes -isnot [System.Array]) {
        throw "E_MALFORMED_RESPONSE: Review thread comments.nodes must be an array."
    }

    $comments = $Thread.comments.nodes
    $commentCount = Get-SafeCount -InputObject $comments
    if ($commentCount -eq 0) {
        return $null
    }

    $top = $comments[0]
    $latestReply = if ($commentCount -gt 1) { $comments[$commentCount - 1] } else { $null }

    if ($null -ne $top.body -and $top.body -isnot [string]) {
        $topBodyType = $top.body.GetType().FullName
        throw "E_MALFORMED_RESPONSE: Review thread top-level comment body must be a string (received '$topBodyType')."
    }

    if ($null -ne $latestReply -and $null -ne $latestReply.body -and $latestReply.body -isnot [string]) {
        $replyBodyType = $latestReply.body.GetType().FullName
        throw "E_MALFORMED_RESPONSE: Review thread latest reply body must be a string (received '$replyBodyType')."
    }

    $lineStart = if ($null -ne $Thread.startLine) { [int]$Thread.startLine } elseif ($null -ne $Thread.line) { [int]$Thread.line } else { $null }
    $lineEnd = if ($null -ne $Thread.line) { [int]$Thread.line } elseif ($null -ne $lineStart) { [int]$lineStart } else { $null }

    $safePath = if ([string]::IsNullOrWhiteSpace($Thread.path)) { "<conversation>" } else { ($Thread.path -replace "\\", "/") }
    $topLevelComment = if ($Truncate.IsPresent) {
        Normalize-CommentText -Text $top.body -MaxLength 500
    } else {
        Normalize-CommentText -Text $top.body -DisableTruncation
    }

    $latestReplySummary = if ($null -eq $latestReply) {
        $null
    } elseif ($Truncate.IsPresent) {
        Normalize-CommentText -Text $latestReply.body -MaxLength 300
    } else {
        Normalize-CommentText -Text $latestReply.body -DisableTruncation
    }

    return [pscustomobject]@{
        path               = $safePath
        lineStart          = $lineStart
        lineEnd            = $lineEnd
        topLevelComment    = $topLevelComment
        latestReplySummary = $latestReplySummary
        threadId           = [string]$Thread.id
        prNumber           = $PrNumber
        owner              = $Owner
        repo               = $Repo
        url                = "https://$GitHubHost/$Owner/$Repo/pull/$PrNumber"
    }
}

function Format-UnresolvedThreadsAsText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Records
    )

    $lines = New-Object System.Collections.Generic.List[string]

    foreach ($record in $Records) {
        $lineStartText = if ($null -eq $record.lineStart) { "?" } else { [string]$record.lineStart }
        $lineEndText = if ($null -eq $record.lineEnd) { "?" } else { [string]$record.lineEnd }

        $lines.Add("---")
        $lines.Add(("({0}) {1}-{2}" -f $record.path, $lineStartText, $lineEndText))
        $lines.Add($record.topLevelComment)
        if ($null -eq $record.latestReplySummary) {
            $lines.Add("Latest reply summary: (none)")
        } else {
            $lines.Add(("Latest reply summary: {0}" -f $record.latestReplySummary))
        }
        $lines.Add("---")
    }

    if ($lines.Count -eq 0) {
        return "No unresolved review threads found."
    }

    return ($lines -join [Environment]::NewLine)
}

function Format-UnresolvedThreadsAsJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Records
    )

    return ($Records | ConvertTo-Json -Depth 8)
}

function Get-UnresolvedReviewThreads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [int]$PrNumber,

        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $true)]
        [int]$PerPage,

        [Parameter(Mandatory = $true)]
        [int]$MaxPages,

        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 300)]
        [int]$RequestTimeoutSeconds = 60,

        [Parameter(Mandatory = $true)]
        [datetime]$OverallDeadlineUtc,

        [Parameter(Mandatory = $false)]
        [switch]$WaitOnRateLimit,

        [Parameter(Mandatory = $false)]
        [switch]$Truncate,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHostsNormalized = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

        $query = @'
query GetReviewThreads(
  $owner: String!,
  $repo: String!,
  $prNumber: Int!,
  $first: Int!,
  $after: String
) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      reviewThreads(first: $first, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isResolved
          path
          startLine
          line
          comments(first: 100) {
            nodes {
              body
              createdAt
              url
              author {
                login
              }
            }
          }
        }
      }
    }
  }
}
'@

    $cursor = $null
    $page = 0
    $allRecords = New-Object System.Collections.Generic.List[object]
    $seenThreadIds = New-Object System.Collections.Generic.HashSet[string]

    while ($page -lt $MaxPages) {
        $page++

        $variables = @{
            owner = $Owner
            repo = $Repo
            prNumber = $PrNumber
            first = $PerPage
            after = $cursor
        }

        $body = @{
            query = $query
            variables = $variables
        }

        $response = Invoke-GitHubRequestWithRetry -Method POST -Uri $Endpoint -Headers $Headers -Body $body -RequestTimeoutSeconds $RequestTimeoutSeconds -MaxRetries 3 -OverallDeadlineUtc $OverallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -AllowedGitHubHostsNormalized $AllowedGitHubHostsNormalized -SensitiveTokens $SensitiveTokens

        $errors = $null
        if ($response -is [System.Collections.IDictionary]) {
            if ($response.Contains("errors")) {
                $errors = $response["errors"]
            }
        } elseif ($response.PSObject.Properties.Name -contains "errors") {
            $errors = $response.errors
        }

        $errorCount = Get-SafeCount -InputObject $errors
        if ($null -ne $errors -and $errorCount -gt 0) {
            $firstError = @($errors)[0]
            $message = "GraphQL returned an error payload without a message field."
            if ($null -ne $firstError) {
                if ($firstError -is [System.Collections.IDictionary]) {
                    if ($firstError.Contains("message")) {
                        $messageValue = Get-FirstNonEmptyStringValue -Value $firstError["message"]
                        if (-not [string]::IsNullOrWhiteSpace($messageValue)) {
                            $message = $messageValue
                        }
                    }
                } elseif ($firstError.PSObject.Properties.Name -contains "message") {
                    $messageValue = Get-FirstNonEmptyStringValue -Value $firstError.message
                    if (-not [string]::IsNullOrWhiteSpace($messageValue)) {
                        $message = $messageValue
                    }
                }
            }
            $safeMessage = Redact-SensitiveText -Text $message -SensitiveTokens $SensitiveTokens
            throw "E_GRAPHQL_ERROR: $safeMessage"
        }

        if ($null -eq $response.data) {
            throw "E_MALFORMED_RESPONSE: Missing response.data in GraphQL response."
        }

        if ($null -eq $response.data.repository) {
            throw "E_MALFORMED_RESPONSE: Missing response.data.repository in GraphQL response."
        }

        if ($null -eq $response.data.repository.pullRequest) {
            throw "E_MALFORMED_RESPONSE: Missing response.data.repository.pullRequest in GraphQL response."
        }

        $threadsNode = $response.data.repository.pullRequest.reviewThreads
        if ($null -eq $threadsNode -or $null -eq $threadsNode.nodes) {
            break
        }

        if ($threadsNode.nodes -isnot [System.Array]) {
            $nodesType = $threadsNode.nodes.GetType().FullName
            throw "E_MALFORMED_RESPONSE: response.data.repository.pullRequest.reviewThreads.nodes must be an array (received '$nodesType')."
        }

        $threads = $threadsNode.nodes
        foreach ($thread in $threads) {
            if ($null -eq $thread.id) {
                continue
            }

            if ($seenThreadIds.Contains([string]$thread.id)) {
                continue
            }

            $seenThreadIds.Add([string]$thread.id) | Out-Null
            $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner $Owner -Repo $Repo -PrNumber $PrNumber -GitHubHost $GitHubHost -Truncate:$Truncate
            if ($null -ne $record) {
                $allRecords.Add($record)
            }
        }

        if ($null -eq $threadsNode.pageInfo) {
            throw "E_MALFORMED_RESPONSE: Missing response.data.repository.pullRequest.reviewThreads.pageInfo in GraphQL response."
        }

        $pageInfo = $threadsNode.pageInfo
        $hasHasNextPageField = $false
        $hasEndCursorField = $false
        $hasNextValue = $null
        $nextCursor = $null

        if ($pageInfo -is [System.Collections.IDictionary]) {
            $hasHasNextPageField = $pageInfo.Contains("hasNextPage")
            $hasEndCursorField = $pageInfo.Contains("endCursor")
            if ($hasHasNextPageField) {
                $hasNextValue = $pageInfo["hasNextPage"]
            }
            if ($hasEndCursorField) {
                $nextCursor = $pageInfo["endCursor"]
            }
        } else {
            $hasHasNextPageField = $pageInfo.PSObject.Properties.Name -contains "hasNextPage"
            $hasEndCursorField = $pageInfo.PSObject.Properties.Name -contains "endCursor"
            if ($hasHasNextPageField) {
                $hasNextValue = $pageInfo.hasNextPage
            }
            if ($hasEndCursorField) {
                $nextCursor = $pageInfo.endCursor
            }
        }

        if (-not $hasHasNextPageField) {
            throw "E_MALFORMED_RESPONSE: Missing response.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage in GraphQL response."
        }

        if (-not $hasEndCursorField) {
            throw "E_MALFORMED_RESPONSE: Missing response.data.repository.pullRequest.reviewThreads.pageInfo.endCursor in GraphQL response."
        }

        $hasNext = [bool]$hasNextValue

        if ($null -ne $nextCursor -and $nextCursor -isnot [string]) {
            $cursorType = $nextCursor.GetType().FullName
            throw "E_MALFORMED_RESPONSE: response.data.repository.pullRequest.reviewThreads.pageInfo.endCursor must be a string or null (received '$cursorType')."
        }

        if ($hasNext -and [string]::IsNullOrWhiteSpace([string]$nextCursor)) {
            throw "E_MALFORMED_RESPONSE: response.data.repository.pullRequest.reviewThreads.pageInfo.endCursor must be non-empty when hasNextPage is true."
        }

        if (-not $hasNext) {
            break
        }

        if ($cursor -eq $nextCursor) {
            throw "E_PAGINATION_LOOP: Cursor did not advance."
        }

        $cursor = [string]$nextCursor
    }

    return $allRecords.ToArray()
}

function Resolve-PullRequestTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$PullRequestUrl,

        [Parameter(Mandatory = $false)]
        [string]$Owner,

        [Parameter(Mandatory = $false)]
        [string]$Repo,

        [Parameter(Mandatory = $false)]
        [string]$GitHubHost = "github.com",

        [Parameter(Mandatory = $false)]
        [switch]$GitHubHostProvided,

        [Parameter(Mandatory = $false)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory = $false)]
        [switch]$Interactive,

        [Parameter(Mandatory = $false)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 300)]
        [int]$RequestTimeoutSeconds = 60,

        [Parameter(Mandatory = $false)]
        [datetime]$OverallDeadlineUtc,

        [Parameter(Mandatory = $false)]
        [switch]$WaitOnRateLimit,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHostsNormalized = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    if (-not [string]::IsNullOrWhiteSpace($PullRequestUrl)) {
        $target = Parse-GitHubPullRequestUrl -Url $PullRequestUrl

        if ($GitHubHostProvided.IsPresent) {
            $normalizedExpectedHost = Assert-GitHubHostFormat -GitHubHost $GitHubHost -Context "GitHubHost parameter"
            if (-not $target.Host.Equals($normalizedExpectedHost, [System.StringComparison]::Ordinal)) {
                throw "E_INVALID_URL: PullRequestUrl host '$($target.Host)' does not match explicitly provided -GitHubHost '$normalizedExpectedHost'."
            }
        }

        Assert-GitHubHostInAllowlist -GitHubHost $target.Host -AllowedGitHubHosts $AllowedGitHubHostsNormalized -Context "PullRequestUrl"
        return $target
    }

    if (-not [string]::IsNullOrWhiteSpace($Owner) -and -not [string]::IsNullOrWhiteSpace($Repo) -and $PullRequestNumber -gt 0) {
        $normalizedHost = Assert-GitHubHostFormat -GitHubHost $GitHubHost -Context "direct parameters"
        $validatedOwnerRepo = Assert-GitHubOwnerRepoFormat -Owner $Owner -Repo $Repo -Context "direct parameters"
        Assert-GitHubHostInAllowlist -GitHubHost $normalizedHost -AllowedGitHubHosts $AllowedGitHubHostsNormalized -Context "direct parameters"

        return [pscustomobject]@{
            Host              = $normalizedHost
            Owner             = $validatedOwnerRepo.Owner
            Repo              = $validatedOwnerRepo.Repo
            PullRequestNumber = $PullRequestNumber
        }
    }

    if ($Interactive.IsPresent) {
        if ($null -eq $Headers) {
            throw "E_CONFIG_ERROR: Interactive mode requires non-null request headers (required for request threading)."
        }

        if ($null -eq $OverallDeadlineUtc -or $OverallDeadlineUtc -le [datetime]::UtcNow) {
            throw "E_CONFIG_ERROR: Interactive mode requires a future overall deadline timestamp (required for request threading)."
        }

        $hostInput = Read-Host "GitHub host [github.com]"
        if ([string]::IsNullOrWhiteSpace($hostInput)) {
            $hostInput = "github.com"
        }

        $resolvedHost = Assert-GitHubHostFormat -GitHubHost $hostInput -Context "interactive host input"
        Assert-GitHubHostInAllowlist -GitHubHost $resolvedHost -AllowedGitHubHosts $AllowedGitHubHostsNormalized -Context "interactive host input"

        return Select-PullRequestInteractively -GitHubHost $resolvedHost -Headers $Headers -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $OverallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -AllowedGitHubHostsNormalized $AllowedGitHubHostsNormalized -SensitiveTokens $SensitiveTokens
    }

    throw "E_INVALID_URL: Provide -PullRequestUrl or use -Interactive."
}

function Invoke-Main {
    [CmdletBinding()]
    param()

    $overallDeadlineUtc = [datetime]::UtcNow.AddSeconds($OverallTimeoutSeconds)
    $initialSensitive = @()
    $isGitHubHostExplicitlyProvided = $script:TopLevelBoundParameters.ContainsKey("GitHubHost")
    $allowedGitHubHostsNormalized = Get-NormalizedGitHubHostAllowlist -AllowedGitHubHosts $AllowedGitHubHosts

    # First pass target resolution may require anonymous headers for interactive listing.
    $tempHeaders = Get-GitHubHeaders -AuthToken $null
    Assert-IsHashtableLike -Value $tempHeaders -Name "Headers"

    $target = Resolve-PullRequestTarget -PullRequestUrl $PullRequestUrl -Owner $Owner -Repo $Repo -GitHubHost $GitHubHost -GitHubHostProvided:$isGitHubHostExplicitlyProvided -PullRequestNumber $PullRequestNumber -Interactive:$Interactive -Headers $tempHeaders -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $overallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $initialSensitive
    if ($null -eq $target) {
        return
    }

    $authToken = Get-AuthToken -ExplicitToken $Token -GitHubHost $target.Host -AllowInteractive:$Interactive
    if ($null -ne $authToken) {
        $authToken = [string]$authToken
    }

    $sensitiveTokens = @()
    if (-not [string]::IsNullOrWhiteSpace($authToken)) {
        $sensitiveTokens += [string]$authToken
    }

    $headers = Get-GitHubHeaders -AuthToken $authToken
    Assert-IsHashtableLike -Value $headers -Name "Headers"

    $allowPromptedLoginFallback = $Interactive.IsPresent -or -not [string]::IsNullOrWhiteSpace($PullRequestUrl)

    $endpoint = Resolve-GitHubGraphQLEndpoint -GitHubHost $target.Host

    try {
        if (-not [string]::IsNullOrWhiteSpace($authToken)) {
            Validate-GitHubTokenForRepoAccess -Owner $target.Owner -Repo $target.Repo -GitHubHost $target.Host -Headers $headers -OverallDeadlineUtc $overallDeadlineUtc -RequestTimeoutSeconds $RequestTimeoutSeconds -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens
        }

        $records = Get-UnresolvedReviewThreads -Owner $target.Owner -Repo $target.Repo -PrNumber $target.PullRequestNumber -Endpoint $endpoint -Headers $headers -GitHubHost $target.Host -PerPage $PerPage -MaxPages $MaxPages -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $overallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -Truncate:$Truncate -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens
    } catch {
        $message = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $sensitiveTokens

        $isAuthRecoverableFailure = $message -like "E_AUTH_INVALID*" -or $message -like "E_FORBIDDEN*" -or $message -like "E_AUTH_INSUFFICIENT_SCOPE*" -or $message -like "E_AUTH_RATE_LIMITED*" -or $message -like "E_RATE_LIMIT_403*"

        if ($allowPromptedLoginFallback -and $isAuthRecoverableFailure -and -not (Test-CanPromptForLogin)) {
            throw "E_AUTH_REQUIRED: Authentication is missing or invalid, but interactive login prompt is unavailable because input/output is redirected. Provide -Token or set GITHUB_TOKEN/GH_TOKEN."
        }

        if ($allowPromptedLoginFallback -and $isAuthRecoverableFailure) {
            $choice = Read-Host "Authentication is missing or invalid. Log in using GitHub CLI now? [y/N]"
            if ($choice -match "^(y|yes)$") {
                $authToken = Get-AuthToken -ExplicitToken $null -GitHubHost $target.Host -AllowInteractive
                if ($null -ne $authToken) {
                    $authToken = [string]$authToken
                }

                if ([string]::IsNullOrWhiteSpace($authToken)) {
                    throw "E_AUTH_REQUIRED: Login completed but no token is available."
                }

                $sensitiveTokens = @()
                if (-not [string]::IsNullOrWhiteSpace($authToken)) {
                    $sensitiveTokens += [string]$authToken
                }

                $headers = Get-GitHubHeaders -AuthToken $authToken
                Assert-IsHashtableLike -Value $headers -Name "Headers"

                Validate-GitHubTokenForRepoAccess -Owner $target.Owner -Repo $target.Repo -GitHubHost $target.Host -Headers $headers -OverallDeadlineUtc $overallDeadlineUtc -RequestTimeoutSeconds $RequestTimeoutSeconds -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens
                $records = Get-UnresolvedReviewThreads -Owner $target.Owner -Repo $target.Repo -PrNumber $target.PullRequestNumber -Endpoint $endpoint -Headers $headers -GitHubHost $target.Host -PerPage $PerPage -MaxPages $MaxPages -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $overallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -Truncate:$Truncate -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens
            } else {
                throw $message
            }
        } else {
            throw $message
        }
    }

    $output = $null
    if ($OutputFormat -eq "json") {
        $output = Format-UnresolvedThreadsAsJson -Records $records
    } else {
        $output = Format-UnresolvedThreadsAsText -Records $records
    }

    if ($Copy.IsPresent) {
        [void](Copy-ToClipboard -Text $output -SensitiveTokens $sensitiveTokens)
    }

    Write-Output $output
}

# Allow tests to dot-source without executing main flow.
if (-not $NoRun.IsPresent -and $MyInvocation.InvocationName -ne ".") {
    try {
        Invoke-Main
    } catch {
        Write-Error $_
        exit 1
    }
}
