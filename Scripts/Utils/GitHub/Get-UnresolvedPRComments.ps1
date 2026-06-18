#!/usr/bin/env pwsh

<#
.SYNOPSIS
Fetch unresolved GitHub PR review threads and render plain text or JSON output.

.DESCRIPTION
Given a GitHub PR URL, or through an interactive owner/repo/PR picker, this script reads
unresolved review threads and outputs each thread in the required text block format:
---
(path/to/file.ext) lineStart-lineEnd
Suggestion:
<normalized comment body>
Suggested change:
<verbatim suggested code, when present>
---

For automation, use -OutputFormat json to emit a compact array containing only
file, line range, suggestion text, and suggested changes.

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

.PARAMETER GitHubWebCookie
Optional GitHub web UI Cookie header value for best-effort extraction of web-only
Copilot automated changesets from private PR pages. The regular GitHub API token
does not authenticate the github.com web UI; use this only when you intentionally
want to provide a browser/session cookie to the web-page enrichment request.
When omitted, WALLSTOP_GITHUB_WEB_COOKIE or GITHUB_WEB_COOKIE may provide it.

.PARAMETER OutputFormat
text (default) or json.

.PARAMETER OutputPath
Optional file path to also write the rendered output. The script writes UTF-8 text,
creates parent directories when needed, and still writes output to stdout.

.PARAMETER Interactive
Prompt for owner/repo and let the user select an open PR when PullRequestUrl is not provided.

.PARAMETER WaitOnRateLimit
If set, wait until rate-limit reset when 429/403 rate-limit is encountered.

.PARAMETER Truncate
If set, truncate thread comments for compact terminal readability using legacy limits
(500 for top-level comments, 300 for latest replies). By default comments are not truncated.

.PARAMETER KeepMarkup
If set, preserve markup in comment bodies. By default, bot metadata, HTML tags,
image embeds, and link URLs are stripped from rendered comment text. Embedded
bot locations are still parsed and can still drive the rendered range.

.PARAMETER Copy
If set, copy the rendered output to clipboard in addition to writing to stdout.
Clipboard copy failures are non-fatal and emit a warning.

.PARAMETER CopyStrict
Only valid together with -Copy. If set, clipboard copy failure becomes a terminating
error after output is rendered.

.PARAMETER NoFastExit
Optional opt-out. By default, after output is rendered and flushed, the process terminates
immediately, skipping the slow .NET/PowerShell managed teardown (finalizers and HTTP
connection-pool shutdown) that dominates wall time on slow container filesystems. On Unix
this uses libc _exit (a clean exit that preserves the exit code and emits no "Killed"
message); on Windows, or if the native call is unavailable, it falls back to
[System.Environment]::Exit. Set -NoFastExit to restore the standard managed teardown (for
example if a wrapping tool depends on normal process shutdown). Output, clipboard, and
-OutputPath writes all complete before termination either way, so the result is identical.
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
    [string]$GitHubWebCookie,

    [Parameter(Mandatory = $false)]
    [ValidateSet("text", "json")]
    [string]$OutputFormat = "text",

    [Parameter(Mandatory = $false)]
    [Alias("OutFile")]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$Interactive,

    [Parameter(Mandatory = $false)]
    [switch]$WaitOnRateLimit,

    [Parameter(Mandatory = $false)]
    [switch]$Truncate,

    [Parameter(Mandatory = $false)]
    [switch]$KeepMarkup,

    [Parameter(Mandatory = $false)]
    [switch]$Copy,

    [Parameter(Mandatory = $false)]
    [switch]$CopyStrict,

    [Parameter(Mandatory = $false)]
    [switch]$NoFastExit,

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
# One reusable web session per run so every GitHub API call (token validation + paginated
# GraphQL/REST) shares a single pooled TCP/TLS connection to the host instead of opening a fresh
# connection (DNS + TCP + TLS handshake) per request. Declared at script scope with a StrictMode-safe
# default of $null and populated in Invoke-Main; the low-level request functions attach it only when
# non-null, so dot-sourced unit tests keep their existing behavior.
$script:GitHubWebSession = $null

$strictModeHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/StrictModeHelpers.ps1"
if (-not (Test-Path -Path $strictModeHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Strict mode helper file not found at '$strictModeHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

.$strictModeHelpersPath

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/CompatibilityHelpers.ps1"
if (-not (Test-Path -Path $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Compatibility helper file not found at '$compatibilityHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

.$compatibilityHelpersPath

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
    $redacted = $redacted -replace "gh[pousr]_[A-Za-z0-9_]{20,}", "***REDACTED***"
    $redacted = $redacted -replace "github_pat_[A-Za-z0-9_]{20,}", "***REDACTED***"
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
            }
            catch {
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
            }
            else {
                $_
            }
        })

    $previewText = if ($preview.Count -gt 0) {
        "'" + ($preview -join "', '") + "'"
    }
    else {
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

        $headerDiagnostics = Get-HeaderValueDiagnostics -Key $Key -Values $values
        throw "${ErrorCode}: Missing $Context. $headerDiagnostics"
    }

    if ($valueCount -gt 1) {
        $headerDiagnostics = Get-HeaderValueDiagnostics -Key $Key -Values $values
        throw "${ErrorCode}: Expected exactly one value for $Context but received $valueCount. $headerDiagnostics"
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
        Repo  = $normalizedRepo
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
        Host              = $hostValue
        Owner             = $validatedOwnerRepo.Owner
        Repo              = $validatedOwnerRepo.Repo
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
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ALLOWED_HOSTS)) {
            $env:GITHUB_ALLOWED_HOSTS
        }
        else {
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
        }
        catch {
            $safeMessage = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens @()
            throw "E_CONFIG_ERROR: Invalid host allowlist entry '$rawHost'. $safeMessage"
        }

        if ($seenHosts.Add($normalizedHost)) {
            $normalizedHosts.Add($normalizedHost) | Out-Null
        }
    }

    return $normalizedHosts.ToArray()
}

function Get-GitHubRequestUriAllowlist {
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHosts = @()
    )

    if ((Get-SafeCount -InputObject $AllowedGitHubHosts) -eq 0) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    $seenHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $requestHosts = New-Object System.Collections.Generic.List[string]
    foreach ($allowedHost in @($AllowedGitHubHosts)) {
        if ([string]::IsNullOrWhiteSpace($allowedHost)) {
            continue
        }

        $normalizedAllowedHost = Assert-GitHubHostFormat -GitHubHost $allowedHost -Context "AllowedGitHubHosts"
        if ($seenHosts.Add($normalizedAllowedHost)) {
            $requestHosts.Add($normalizedAllowedHost) | Out-Null
        }

        if ($normalizedAllowedHost.Equals("github.com", [System.StringComparison]::OrdinalIgnoreCase) -and $seenHosts.Add("api.github.com")) {
            $requestHosts.Add("api.github.com") | Out-Null
        }
    }

    return $requestHosts.ToArray()
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
    $requestAllowedHosts = Get-GitHubRequestUriAllowlist -AllowedGitHubHosts $AllowedGitHubHosts
    Assert-GitHubHostInAllowlist -GitHubHost $normalizedHost -AllowedGitHubHosts $requestAllowedHosts -Context "$Context URI"
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

function Resolve-GitHubRestApiBaseUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitHubHost
    )

    $normalizedHost = Assert-GitHubHostFormat -GitHubHost $GitHubHost -Context "Resolve-GitHubRestApiBaseUri"

    if ($normalizedHost.Equals("github.com", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "https://api.github.com"
    }

    return "https://$normalizedHost/api/v3"
}

function Get-GitHubHeaders {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AuthToken
    )

    [hashtable]$headers = @{
        "Accept"     = "application/vnd.github+json"
        "User-Agent" = "wallstop-utils-unresolved-pr-comments"
    }

    if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
        $headers["Authorization"] = "Bearer $AuthToken"
    }

    return [hashtable]$headers
}

function ConvertTo-EmbeddedLocationPath {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    $candidate = $Target.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    $parsedUri = $null
    if ([System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$parsedUri) -and
        (($parsedUri.Scheme -eq "https") -or ($parsedUri.Scheme -eq "http"))) {
        $absolutePath = [System.Uri]::UnescapeDataString($parsedUri.AbsolutePath.TrimStart("/"))
        $segments = @($absolutePath -split "/" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $blobIndex = -1
        for ($index = 0; $index -lt $segments.Count; $index++) {
            if ($segments[$index] -ceq "blob") {
                $blobIndex = $index
                break
            }
        }

        if ($blobIndex -ge 0 -and $segments.Count -gt ($blobIndex + 2)) {
            $candidate = ($segments[($blobIndex + 2)..($segments.Count - 1)] -join "/")
        }
        else {
            $candidate = $absolutePath
        }
    }
    else {
        $candidate = [System.Uri]::UnescapeDataString($candidate)
    }

    $normalizedPath = (($candidate -replace "\\", "/").Trim()).TrimStart("/")
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        return $null
    }

    return $normalizedPath
}

function Get-EmbeddedCommentLocations {
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    $locations = New-Object System.Collections.Generic.List[object]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $blocks = [regex]::Matches($Text, '<!--\s*LOCATIONS\s+START\s+(?<payload>[\s\S]*?)\s+LOCATIONS\s+END\s*-->', $ignoreCase)

    foreach ($block in $blocks) {
        $payload = $block.Groups["payload"].Value
        $locationMatches = [regex]::Matches($payload, '(?<target>\S+?)#L(?<start>\d+)(?:-L?(?<end>\d+))?')
        foreach ($locationMatch in $locationMatches) {
            $path = ConvertTo-EmbeddedLocationPath -Target $locationMatch.Groups["target"].Value
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }

            $lineStart = 0
            if (-not [int]::TryParse($locationMatch.Groups["start"].Value, [ref]$lineStart) -or $lineStart -lt 1) {
                continue
            }

            $lineEnd = $lineStart
            if ($locationMatch.Groups["end"].Success) {
                $parsedEnd = 0
                if ([int]::TryParse($locationMatch.Groups["end"].Value, [ref]$parsedEnd) -and $parsedEnd -ge 1) {
                    $lineEnd = $parsedEnd
                }
            }

            if ($lineEnd -lt $lineStart) {
                Write-Verbose "W_EMBEDDED_LOCATION_RANGE_INVERTED: Embedded comment location '$path' has end line $lineEnd before start line $lineStart; clamping end to start."
                $lineEnd = $lineStart
            }

            $key = "{0}|{1}|{2}" -f $path, $lineStart, $lineEnd
            if (-not $seen.Add($key)) {
                continue
            }

            $locations.Add([pscustomobject]@{
                    path      = $path
                    lineStart = $lineStart
                    lineEnd   = $lineEnd
                }) | Out-Null
        }
    }

    return @($locations.ToArray())
}

function Resolve-OutputCommentLocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DefaultPath,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $DefaultStart,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $DefaultEnd,

        [Parameter(Mandatory = $false)]
        [object[]]$EmbeddedLocations = @()
    )

    $locations = @($EmbeddedLocations)
    if ((Get-SafeCount -InputObject $locations) -gt 0) {
        $preferredLocation = $null
        if (-not [string]::IsNullOrWhiteSpace($DefaultPath) -and $DefaultPath -ne "<conversation>") {
            foreach ($location in $locations) {
                if ([string]$location.path -ceq $DefaultPath) {
                    $preferredLocation = $location
                    break
                }
            }

            if ($null -eq $preferredLocation) {
                foreach ($location in $locations) {
                    if ([string]$location.path -ieq $DefaultPath) {
                        $preferredLocation = $location
                        break
                    }
                }
            }
        }

        if ($null -eq $preferredLocation) {
            Write-Verbose "W_EMBEDDED_LOCATION_PATH_MISMATCH: No embedded location path matched '$DefaultPath'; using first embedded location '$($locations[0].path)'."
            $preferredLocation = $locations[0]
        }

        return [pscustomobject]@{
            Path   = [string]$preferredLocation.path
            Start  = [int]$preferredLocation.lineStart
            End    = [int]$preferredLocation.lineEnd
            Source = "embedded"
        }
    }

    return [pscustomobject]@{
        Path   = $DefaultPath
        Start  = $DefaultStart
        End    = $DefaultEnd
        Source = "github"
    }
}

function Remove-HtmlBlocksContainingText {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$ElementName,

        [Parameter(Mandatory = $true)]
        [string]$MarkerPattern
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $escapedElementName = [regex]::Escape($ElementName)
    $blockPattern = "<$escapedElementName\b[^>]*>[\s\S]*?</$escapedElementName>"
    $matches = [regex]::Matches($Text, $blockPattern, $ignoreCase)
    if ($matches.Count -eq 0) {
        return $Text
    }

    $builder = [System.Text.StringBuilder]::new($Text)
    for ($index = $matches.Count - 1; $index -ge 0; $index--) {
        $match = $matches[$index]
        if (-not [regex]::IsMatch($match.Value, $MarkerPattern, $ignoreCase)) {
            continue
        }

        $builder.Remove($match.Index, $match.Length).Insert($match.Index, " ") | Out-Null
    }

    return $builder.ToString()
}

function Get-SuggestionFenceRegex {
    # Single source of truth for matching GitHub "suggested change" fenced blocks so the
    # extractor (Get-CommentSuggestionBlocks) and the prose stripper (Remove-MarkupFromCommentText)
    # never drift. Matches an opening fence of three or more backticks, the case-insensitive
    # "suggestion" info string (optionally with trailing attributes), the verbatim body, then a
    # closing fence of the same length. Operates on LF-normalized text; the named backreference
    # \k<fence> guarantees the closing fence length matches the opening fence.
    [OutputType([regex])]
    [CmdletBinding()]
    param()

    # The named backreference \k<fence> guarantees the closing fence length matches the opening
    # fence. The optional (?:\n)? before the closing-fence anchor lets the lazy (?<code>...)
    # group stop one newline early so a single-line empty block (open fence directly followed by
    # close fence) still matches with an empty code capture.
    $pattern = '(?m)^[ \t]*(?<fence>`{3,})[ \t]*suggestion\b[^\n]*\n(?<code>[\s\S]*?)(?:\n)?^[ \t]*\k<fence>[ \t]*$'
    return [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-CommentSuggestionBlocks {
    # Extracts GitHub "```suggestion" blocks (Copilot, Cursor, and human reviewers) verbatim so
    # suggested implementations can be rendered exactly instead of being whitespace-collapsed into
    # unusable single-line text. Returns an array of objects with `kind`, verbatim `code`, and
    # optional source-comment metadata for internal processing.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$AuthorLogin,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $CommentIndex,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $regex = Get-SuggestionFenceRegex
    $suggestions = New-Object System.Collections.Generic.List[object]
    foreach ($match in $regex.Matches($normalized)) {
        $code = $match.Groups["code"].Value
        # Drop the trailing newline artifact that precedes the closing fence while preserving
        # interior blank lines and indentation exactly.
        $code = $code -replace "`n+$", ""
        $suggestions.Add([pscustomobject]@{
                kind         = "suggestion"
                code         = $code
                authorLogin  = if ([string]::IsNullOrWhiteSpace($AuthorLogin)) { $null } else { $AuthorLogin }
                commentIndex = $CommentIndex
                url          = if ([string]::IsNullOrWhiteSpace($Url)) { $null } else { $Url }
            }) | Out-Null
    }

    return @($suggestions.ToArray())
}

function Get-ReviewCommentAuthorLogin {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Comment
    )

    if ($null -eq $Comment) {
        return $null
    }

    $author = Get-ObjectPropertyValue -InputObject $Comment -Name "author"
    $authorLogin = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $author -Name "login")
    if (-not [string]::IsNullOrWhiteSpace($authorLogin)) {
        return $authorLogin
    }

    $user = Get-ObjectPropertyValue -InputObject $Comment -Name "user"
    return (Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $user -Name "login"))
}

function Get-ReviewCommentUrl {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Comment
    )

    if ($null -eq $Comment) {
        return $null
    }

    $url = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $Comment -Name "url")
    if (-not [string]::IsNullOrWhiteSpace($url)) {
        return $url
    }

    return (Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $Comment -Name "html_url"))
}

function Get-ReviewCommentDatabaseId {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Comment
    )

    if ($null -eq $Comment) {
        return $null
    }

    foreach ($propertyName in @("databaseId", "fullDatabaseId", "database_id")) {
        $value = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $Comment -Name $propertyName)
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value -match '^\d+$') {
            return $value
        }
    }

    $url = Get-ReviewCommentUrl -Comment $Comment
    if (-not [string]::IsNullOrWhiteSpace($url)) {
        $match = [regex]::Match($url, '(?:#|/)discussion_r(?<id>\d+)(?:\b|$)')
        if ($match.Success) {
            return $match.Groups["id"].Value
        }
    }

    return $null
}

function Get-GitHubWebCookie {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ExplicitCookie
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitCookie)) {
        return $ExplicitCookie
    }

    foreach ($variableName in @("WALLSTOP_GITHUB_WEB_COOKIE", "GITHUB_WEB_COOKIE")) {
        $variable = Get-Item -LiteralPath "env:$variableName" -ErrorAction SilentlyContinue
        if ($null -ne $variable -and -not [string]::IsNullOrWhiteSpace([string]$variable.Value)) {
            return [string]$variable.Value
        }
    }

    return $null
}

function Get-ReviewCommentDiffHunk {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Comment
    )

    if ($null -eq $Comment) {
        return $null
    }

    $diffHunk = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $Comment -Name "diffHunk")
    if ([string]::IsNullOrWhiteSpace($diffHunk)) {
        $diffHunk = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $Comment -Name "diff_hunk")
    }

    if ([string]::IsNullOrWhiteSpace($diffHunk)) {
        return $null
    }

    return ($diffHunk -replace "`r`n", "`n" -replace "`r", "`n")
}

function New-CommentRecommendationRecord {
    [OutputType([object])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("comment", "suggestion")]
        [string]$Kind,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$AuthorLogin,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Text,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Code,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $CommentIndex,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Url
    )

    $textValue = if ($null -eq $Text) { $null } else { [string]$Text }
    $codeValue = if ($null -eq $Code) { $null } else { [string]$Code }

    return [pscustomobject]@{
        kind         = $Kind
        authorLogin  = if ([string]::IsNullOrWhiteSpace($AuthorLogin)) { $null } else { $AuthorLogin }
        text         = $textValue
        code         = $codeValue
        commentIndex = $CommentIndex
        url          = if ([string]::IsNullOrWhiteSpace($Url)) { $null } else { $Url }
    }
}

function New-ThreadCommentRecord {
    [OutputType([object])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $CommentIndex,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$DatabaseId,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Body,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $DiffHunk,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $SuggestedChanges = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $SuggestedDiffs = @(),

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$SuggestedDiffsUnavailableReason,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Url
    )

    $bodyValue = if ($null -eq $Body) { $null } else { [string]$Body }
    if ($bodyValue -eq "(none)") {
        $bodyValue = $null
    }

    $diffHunkValue = if ($null -eq $DiffHunk) { $null } else { [string]$DiffHunk }

    return [pscustomobject]@{
        commentIndex = $CommentIndex
        databaseId   = if ([string]::IsNullOrWhiteSpace($DatabaseId)) { $null } else { [string]$DatabaseId }
        body         = if ([string]::IsNullOrWhiteSpace($bodyValue)) { $null } else { $bodyValue }
        diffHunk     = if ([string]::IsNullOrWhiteSpace($diffHunkValue)) { $null } else { ($diffHunkValue -replace "`r`n", "`n" -replace "`r", "`n") }
        suggestedChanges = @($SuggestedChanges)
        suggestedDiffs = @($SuggestedDiffs)
        suggestedDiffsUnavailable = -not [string]::IsNullOrWhiteSpace($SuggestedDiffsUnavailableReason)
        suggestedDiffsUnavailableReason = if ([string]::IsNullOrWhiteSpace($SuggestedDiffsUnavailableReason)) { $null } else { $SuggestedDiffsUnavailableReason }
        url          = if ([string]::IsNullOrWhiteSpace($Url)) { $null } else { $Url }
    }
}

function Get-SuggestedDiffsUnavailableReason {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$AuthorLogin,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Body,

        [Parameter(Mandatory = $false)]
        [int]$SuggestedChangeCount = 0
    )

    if ($SuggestedChangeCount -gt 0) {
        return $null
    }

    if ($AuthorLogin -imatch '^copilot-pull-request-reviewer(\[bot\])?$') {
        return "copilot_suggested_diff_may_be_web_only_or_unavailable"
    }

    if ($Body -match "BUGBOT_BUG_ID|cursor\.com/(open|agents)") {
        return "external_bot_suggested_fix_not_exposed_by_github_api"
    }

    return $null
}

function Convert-GitHubWebAutomatedDiffEntriesToSuggestedDiffs {
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $DiffEntries
    )

    $suggestedDiffs = New-Object System.Collections.Generic.List[object]
    foreach ($diffEntry in @($DiffEntries)) {
        if ($null -eq $diffEntry) {
            continue
        }

        $path = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $diffEntry -Name "path")
        $diffLines = Get-ObjectPropertyValue -InputObject $diffEntry -Name "diffLines" -NoEnumerate
        $changedLines = New-Object System.Collections.Generic.List[string]

        foreach ($diffLine in @($diffLines)) {
            if ($null -eq $diffLine) {
                continue
            }

            $lineType = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $diffLine -Name "type")
            if ([string]::IsNullOrWhiteSpace($lineType)) {
                continue
            }

            $textValue = Get-ObjectPropertyValue -InputObject $diffLine -Name "text"
            $text = if ($null -eq $textValue) { "" } else { [string]$textValue }
            if ($lineType.Equals("DELETION", [System.StringComparison]::OrdinalIgnoreCase)) {
                $changedLines.Add("-$text") | Out-Null
            }
            elseif ($lineType.Equals("ADDITION", [System.StringComparison]::OrdinalIgnoreCase)) {
                $changedLines.Add("+$text") | Out-Null
            }
        }

        if ($changedLines.Count -eq 0) {
            continue
        }

        $suggestedDiffs.Add([pscustomobject]@{
                kind   = "changedLines"
                path   = if ([string]::IsNullOrWhiteSpace($path)) { $null } else { $path }
                diff   = ($changedLines.ToArray() -join "`n")
                source = "github_web_automated_comment"
            }) | Out-Null
    }

    return @($suggestedDiffs.ToArray())
}

function Convert-GitHubWebEmbeddedJsonToObject {
    [OutputType([object])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Json
    )

    foreach ($candidate in @($Json, [System.Net.WebUtility]::HtmlDecode($Json))) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        try {
            return (ConvertFrom-JsonSingleObject -Json $candidate -Context "GitHub web embedded comment JSON")
        }
        catch {
            continue
        }
    }

    return $null
}

function Get-GitHubWebAutomatedSuggestedDiffsByCommentIdFromHtml {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Html
    )

    $suggestedDiffsByCommentId = @{}
    if ([string]::IsNullOrWhiteSpace($Html)) {
        return $suggestedDiffsByCommentId
    }

    $normalizedHtml = $Html -replace "`r`n", "`n" -replace "`r", "`n"
    $scriptPattern = '<script\b[^>]*data-target\s*=\s*["'']react-partial\.embeddedData["''][^>]*>(?<json>[\s\S]*?)</script>'
    $scriptMatches = [regex]::Matches($normalizedHtml, $scriptPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($scriptMatch in $scriptMatches) {
        $json = $scriptMatch.Groups["json"].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($json)) {
            continue
        }

        $payload = Convert-GitHubWebEmbeddedJsonToObject -Json $json
        if ($null -eq $payload) {
            continue
        }

        $props = Get-ObjectPropertyValue -InputObject $payload -Name "props"
        $comment = Get-ObjectPropertyValue -InputObject $props -Name "comment"
        if ($null -eq $comment) {
            continue
        }

        $commentId = Get-ReviewCommentDatabaseId -Comment $comment
        if ([string]::IsNullOrWhiteSpace($commentId)) {
            continue
        }

        $automatedComment = Get-ObjectPropertyValue -InputObject $comment -Name "automatedComment"
        $suggestion = Get-ObjectPropertyValue -InputObject $automatedComment -Name "suggestion"
        $diffEntries = Get-ObjectPropertyValue -InputObject $suggestion -Name "diffEntries" -NoEnumerate
        $suggestedDiffs = @(Convert-GitHubWebAutomatedDiffEntriesToSuggestedDiffs -DiffEntries $diffEntries)
        if ((Get-SafeCount -InputObject $suggestedDiffs) -eq 0) {
            continue
        }

        if (-not $suggestedDiffsByCommentId.ContainsKey($commentId)) {
            $suggestedDiffsByCommentId[$commentId] = @()
        }

        $suggestedDiffsByCommentId[$commentId] = @($suggestedDiffsByCommentId[$commentId]) + @($suggestedDiffs)
    }

    return $suggestedDiffsByCommentId
}

function Set-ObjectNotePropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    if ($InputObject.PSObject.Properties.Name -ccontains $Name) {
        $InputObject.$Name = $Value
        return
    }

    Add-Member -InputObject $InputObject -MemberType NoteProperty -Name $Name -Value $Value
}

function Add-GitHubWebAutomatedSuggestedDiffsToRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$Records = @(),

        [Parameter(Mandatory = $false)]
        [hashtable]$SuggestedDiffsByCommentId = @{}
    )

    if ($null -eq $SuggestedDiffsByCommentId -or $SuggestedDiffsByCommentId.Count -eq 0) {
        return
    }

    foreach ($record in @($Records)) {
        if ($null -eq $record) {
            continue
        }

        foreach ($comment in @(Get-ObjectPropertyValue -InputObject $record -Name "comments")) {
            if ($null -eq $comment) {
                continue
            }

            $commentId = Get-ReviewCommentDatabaseId -Comment $comment
            if ([string]::IsNullOrWhiteSpace($commentId) -or -not $SuggestedDiffsByCommentId.ContainsKey($commentId)) {
                continue
            }

            $existingDiffs = @(Get-ObjectPropertyValue -InputObject $comment -Name "suggestedDiffs")
            $mergedDiffs = New-Object System.Collections.Generic.List[object]
            $seenDiffs = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
            foreach ($existingDiff in $existingDiffs) {
                if ($null -eq $existingDiff) {
                    continue
                }

                $existingText = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $existingDiff -Name "diff")
                if (-not [string]::IsNullOrWhiteSpace($existingText)) {
                    $seenDiffs.Add($existingText) | Out-Null
                }

                $mergedDiffs.Add($existingDiff) | Out-Null
            }

            foreach ($suggestedDiff in @($SuggestedDiffsByCommentId[$commentId])) {
                if ($null -eq $suggestedDiff) {
                    continue
                }

                $diffText = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $suggestedDiff -Name "diff")
                if ([string]::IsNullOrWhiteSpace($diffText)) {
                    continue
                }

                if (-not $seenDiffs.Add($diffText)) {
                    continue
                }

                $mergedDiffs.Add($suggestedDiff) | Out-Null
            }

            if ($mergedDiffs.Count -eq 0) {
                continue
            }

            Set-ObjectNotePropertyValue -InputObject $comment -Name "suggestedDiffs" -Value @($mergedDiffs.ToArray())
            Set-ObjectNotePropertyValue -InputObject $comment -Name "suggestedDiffsUnavailable" -Value $false
            Set-ObjectNotePropertyValue -InputObject $comment -Name "suggestedDiffsUnavailableReason" -Value $null
        }
    }
}

function Get-GitHubWebAutomatedSuggestedDiffsByCommentId {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [int]$PrNumber,

        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 300)]
        [int]$RequestTimeoutSeconds = 60,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$GitHubWebCookie,

        [Parameter(Mandatory = $true)]
        [datetime]$OverallDeadlineUtc,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHostsNormalized = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    $emptyMap = @{}
    if (-not $GitHubHost.Equals("github.com", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $emptyMap
    }

    $uri = "https://$GitHubHost/$Owner/$Repo/pull/$PrNumber"
    Assert-GitHubRequestUri -Uri $uri -Context "Get-GitHubWebAutomatedSuggestedDiffsByCommentId" -AllowedGitHubHosts $AllowedGitHubHostsNormalized

    $ProgressPreference = "SilentlyContinue"
    $remainingSeconds = [int][math]::Floor(($OverallDeadlineUtc - [datetime]::UtcNow).TotalSeconds)
    if ($remainingSeconds -lt 1) {
        Write-Verbose "W_GITHUB_WEB_SUGGESTIONS_SKIPPED: No timeout budget remains for GitHub web suggested changeset enrichment."
        return $emptyMap
    }

    $effectiveRequestTimeoutSeconds = [math]::Min($RequestTimeoutSeconds, $remainingSeconds)
    if ($effectiveRequestTimeoutSeconds -lt 1) {
        Write-Verbose "W_GITHUB_WEB_SUGGESTIONS_SKIPPED: Request timeout budget is exhausted for GitHub web suggested changeset enrichment."
        return $emptyMap
    }

    $headers = @{
        Accept       = "text/html,application/xhtml+xml"
        "User-Agent" = "Mozilla/5.0"
    }
    if (-not [string]::IsNullOrWhiteSpace($GitHubWebCookie)) {
        $headers["Cookie"] = $GitHubWebCookie
    }

    try {
        # Do not reuse the API WebRequestSession here. PowerShell web sessions can retain default
        # headers from prior API calls, and the GitHub web UI request must not inherit an API
        # Authorization header. Any intentional web auth is passed only through the explicit Cookie
        # header above.
        $response = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -TimeoutSec $effectiveRequestTimeoutSeconds -UseBasicParsing
        return (Get-GitHubWebAutomatedSuggestedDiffsByCommentIdFromHtml -Html $response.Content)
    }
    catch {
        $message = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $SensitiveTokens
        if (-not [string]::IsNullOrWhiteSpace($GitHubWebCookie)) {
            throw "E_GITHUB_WEB_SUGGESTIONS_UNAVAILABLE: GitHub web suggested changeset enrichment failed even though a web cookie was provided for $Owner/$Repo#$PrNumber. $message"
        }

        Write-Verbose "W_GITHUB_WEB_SUGGESTIONS_UNAVAILABLE: GitHub web suggested changeset enrichment was unavailable for $Owner/$Repo#$PrNumber. $message"
        return $emptyMap
    }
}

function Remove-MarkupFromCommentText {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    # Normalize line endings so multiline-anchored cleanup behaves identically for CRLF/LF
    # source. Downstream single-line normalization collapses remaining whitespace, so this is
    # safe for prose output.
    $cleaned = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    # "```suggestion" blocks are rendered separately and verbatim, so strip them from prose to
    # avoid duplicated or whitespace-mangled inline copies.
    $cleaned = (Get-SuggestionFenceRegex).Replace($cleaned, ' ')
    $cleaned = [regex]::Replace($cleaned, '<details\b[^>]*>\s*<summary\b[^>]*>\s*Additional Locations[\s\S]*?</details>', ' ', $ignoreCase)
    $cleaned = Remove-HtmlBlocksContainingText -Text $cleaned -ElementName "div" -MarkerPattern 'cursor\.com/(?:open|agents)|fix-in-(?:cursor|web)'
    $cleaned = Remove-HtmlBlocksContainingText -Text $cleaned -ElementName "sup" -MarkerPattern 'Reviewed by\s+\[?Cursor Bugbot|cursor\.com/bugbot'
    $cleaned = [regex]::Replace($cleaned, '<!--[\s\S]*?-->', ' ')
    $cleaned = $cleaned -replace '!\[[^\]]*\]\([^)]*\)', ' '
    $cleaned = $cleaned -replace '(?<!!)\[([^\]]+)\]\([^)]*\)', '$1'
    $cleaned = $cleaned -replace '</?[A-Za-z][^>]*>', ' '
    $cleaned = $cleaned -replace '&nbsp;', ' '

    return $cleaned
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
        [switch]$DisableTruncation,

        [Parameter(Mandatory = $false)]
        [switch]$KeepMarkup
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "(none)"
    }

    $cleanedText = if ($KeepMarkup.IsPresent) { $Text } else { Remove-MarkupFromCommentText -Text $Text }
    if ([string]::IsNullOrWhiteSpace($cleanedText)) {
        return "(none)"
    }

    $singleLine = ($cleanedText -replace "\s+", " ").Trim()
    if ($DisableTruncation.IsPresent) {
        return $singleLine
    }

    if ($singleLine.Length -le $MaxLength) {
        return $singleLine
    }

    # Never split a UTF-16 surrogate pair (for example an emoji) at the truncation boundary:
    # a lone surrogate round-trips through UTF-8 as the U+FFFD replacement character and
    # corrupts copied/rendered output. Back off one unit when the boundary lands on a high
    # surrogate so the pair is dropped whole. The explicit (string, int) overload avoids any
    # char/string overload ambiguity from indexer extraction.
    $cutLength = $MaxLength
    if ($cutLength -gt 0 -and [System.Char]::IsHighSurrogate($singleLine, $cutLength - 1)) {
        $cutLength--
    }

    return ($singleLine.Substring(0, $cutLength) + " [...]")
}

function Resolve-ReviewThreadGitHubAnchor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Thread
    )

    $currentStart = Get-FirstIntegerPropertyValue -InputObject $Thread -Names @("startLine")
    $currentEnd = Get-FirstIntegerPropertyValue -InputObject $Thread -Names @("line")
    $originalStart = Get-FirstIntegerPropertyValue -InputObject $Thread -Names @("originalStartLine")
    $originalEnd = Get-FirstIntegerPropertyValue -InputObject $Thread -Names @("originalLine")

    $start = if ($null -ne $currentStart) {
        $currentStart
    }
    elseif ($null -ne $currentEnd) {
        $currentEnd
    }
    elseif ($null -ne $originalStart) {
        $originalStart
    }
    else {
        $originalEnd
    }

    $end = if ($null -ne $currentEnd) {
        $currentEnd
    }
    elseif ($null -ne $currentStart) {
        $currentStart
    }
    elseif ($null -ne $originalEnd) {
        $originalEnd
    }
    else {
        $originalStart
    }

    if ($null -ne $start -and $null -ne $end -and $end -lt $start) {
        $end = $start
    }

    return [pscustomobject]@{
        Start = $start
        End   = $end
    }
}

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [switch]$NoEnumerate
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $dictionary = [System.Collections.IDictionary]$InputObject

        foreach ($key in $dictionary.Keys) {
            if ([string]$key -ceq $Name) {
                $value = $dictionary[$key]
                if ($NoEnumerate.IsPresent) {
                    Microsoft.PowerShell.Utility\Write-Output -NoEnumerate $value
                    return
                }

                return $value
            }
        }

        foreach ($key in $dictionary.Keys) {
            if ([string]$key -ieq $Name) {
                $value = $dictionary[$key]
                if ($NoEnumerate.IsPresent) {
                    Microsoft.PowerShell.Utility\Write-Output -NoEnumerate $value
                    return
                }

                return $value
            }
        }

        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    if ($NoEnumerate.IsPresent) {
        Microsoft.PowerShell.Utility\Write-Output -NoEnumerate $property.Value
        return
    }

    return $property.Value
}

function Get-FirstIntegerPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-ObjectPropertyValue -InputObject $InputObject -Name $name
        if ($null -ne $value) {
            return [int]$value
        }
    }

    return $null
}

function Resolve-ReviewThreadLineRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Thread
    )

    $currentStart = Get-FirstIntegerPropertyValue -InputObject $Thread -Names @("startLine")
    $currentEnd = Get-FirstIntegerPropertyValue -InputObject $Thread -Names @("line")
    $originalStart = Get-FirstIntegerPropertyValue -InputObject $Thread -Names @("originalStartLine")
    $originalEnd = Get-FirstIntegerPropertyValue -InputObject $Thread -Names @("originalLine")
    $isOutdated = [bool](Get-ObjectPropertyValue -InputObject $Thread -Name "isOutdated")

    $start = $null
    $end = $null

    if ($isOutdated -and ($null -ne $originalStart -or $null -ne $originalEnd)) {
        $start = if ($null -ne $originalStart) { $originalStart } else { $originalEnd }
        $end = if ($null -ne $originalEnd) { $originalEnd } else { $originalStart }
    }
    elseif ($null -ne $currentStart) {
        $start = $currentStart
        if ($null -ne $currentEnd) {
            $end = $currentEnd
        }
        elseif ($null -ne $originalEnd) {
            $end = $originalEnd
        }
    }
    elseif ($null -ne $currentEnd) {
        $start = if ($null -ne $originalStart) { $originalStart } else { $currentEnd }
        $end = $currentEnd
    }
    elseif ($null -ne $originalStart) {
        $start = $originalStart
        $end = $originalEnd
    }
    elseif ($null -ne $originalEnd) {
        $start = $originalEnd
        $end = $originalEnd
    }

    if ($null -ne $start -and $null -ne $end -and $end -lt $start) {
        $end = $start
    }

    return [pscustomobject]@{
        Start = $start
        End   = $end
    }
}

function ConvertTo-Osc52Sequence {
    # Builds the OSC52 terminal escape that copies $Text to the system clipboard. The payload is
    # the UTF-8 bytes of $Text, base64-encoded, wrapped as ESC ] 52 ; c ; <base64> BEL. The
    # explicit "c" clipboard selector is honored by every compliant terminal; an empty selector
    # (as emitted by Set-Clipboard -AsOSC52) is ambiguous and not reliably mapped to the system
    # clipboard by some terminals (for example VS Code). The whole sequence is pure ASCII, so it
    # transmits byte-for-byte regardless of console/output encoding.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $base64 = [System.Convert]::ToBase64String($bytes)
    $esc = [char]27
    $bel = [char]7
    return "$esc]52;c;$base64$bel"
}

function Write-ConsoleHostSequence {
    # Thin, mockable seam that writes a raw terminal control sequence directly to the console
    # host so OSC52 reaches the terminal emulator. Isolated so clipboard tests can assert the
    # emitted sequence without writing escape bytes to the test runner's console.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Sequence
    )

    [System.Console]::Out.Write($Sequence)
    [System.Console]::Out.Flush()
}

function Get-Osc52MaxClipboardByteBudget {
    # Resolves the advisory OSC52 payload-size budget. Terminals cap OSC52 length and silently
    # truncate larger payloads, which corrupts trailing (often multibyte) characters. The budget
    # is overridable via WALLSTOP_CLIPBOARD_OSC52_MAX_BYTES for terminals with different limits.
    [OutputType([int])]
    [CmdletBinding()]
    param()

    $default = 100000
    $raw = $env:WALLSTOP_CLIPBOARD_OSC52_MAX_BYTES
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = 0
        if ([int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }
    }

    return $default
}

function Write-Osc52Clipboard {
    # Copies $Text to the system clipboard via an OSC52 terminal escape (the only clipboard
    # bridge available over SSH, inside containers, and in VS Code's integrated terminal). The
    # emitted sequence is UTF-8-correct and verbatim. Because terminals cap OSC52 payload size,
    # oversize content can be silently truncated by the terminal (a common cause of corrupted
    # trailing characters), so a size guard warns and recommends -OutputPath rather than failing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [int]$MaxClipboardBytes = -1
    )

    $budget = if ($MaxClipboardBytes -gt 0) { $MaxClipboardBytes } else { Get-Osc52MaxClipboardByteBudget }
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($Text)
    if ($byteCount -gt $budget) {
        Write-Warning "W_CLIPBOARD_OSC52_TRUNCATION_RISK: Clipboard payload is $byteCount bytes, exceeding the OSC52 safe budget of $budget bytes; the terminal may truncate it and corrupt the copied text. Use -OutputPath to capture the full output verbatim, or set WALLSTOP_CLIPBOARD_OSC52_MAX_BYTES to adjust the threshold."
    }

    $sequence = ConvertTo-Osc52Sequence -Text $Text
    Write-ConsoleHostSequence -Sequence $sequence
}

function Get-ClipboardCommand {
    [OutputType([string])]
    [CmdletBinding()]
    param()

    $commands = @(Get-ClipboardCommandPriority)
    if ((Get-SafeCount -InputObject $commands) -eq 0) {
        return $null
    }

    return $commands[0]
}

function Test-IsConsoleOutputRedirected {
    # Mockable seam over [System.Console]::IsOutputRedirected. Isolated so the OSC52 gate is
    # unit-testable and so the property probe can never throw on hosts without a console.
    [OutputType([bool])]
    [CmdletBinding()]
    param()

    try {
        return [System.Console]::IsOutputRedirected
    }
    catch {
        return $false
    }
}

function Test-ShouldUseClipboardOsc52 {
    [OutputType([bool])]
    [CmdletBinding()]
    param()

    # OSC52 is a terminal control sequence written to stdout. If stdout is redirected to a file
    # or pipe, emitting it would inject raw escape bytes into that output (corrupting, for
    # example, `... -Copy > out.txt` or `... -Copy | cat`) and it would never reach a terminal
    # anyway. Disable OSC52 whenever stdout is not a live terminal.
    if (Test-IsConsoleOutputRedirected) {
        return $false
    }

    return ($env:TERM_PROGRAM -eq "vscode") -or
    (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION)) -or
    (-not [string]::IsNullOrWhiteSpace($env:SSH_CLIENT)) -or
    (-not [string]::IsNullOrWhiteSpace($env:SSH_TTY))
}

function Get-ClipboardCommandPriority {
    [OutputType([string[]])]
    [CmdletBinding()]
    param()

    $commands = New-Object System.Collections.Generic.List[string]
    $onWindows = Test-IsWindowsPlatform
    $hasSetClipboard = $null -ne (Get-Command Set-Clipboard -ErrorAction SilentlyContinue)

    # The Windows GUI clipboard is unbounded and Unicode-correct, so it is always preferred over
    # OSC52 on Windows (OSC52 has a terminal payload cap that can truncate large content).
    if ($onWindows -and $hasSetClipboard) {
        $commands.Add("Set-Clipboard") | Out-Null
    }

    # OSC52 bridges remote/terminal contexts (VS Code, SSH, Windows Terminal) where no local GUI
    # clipboard is reachable. It emits an explicit, UTF-8-correct sequence (Write-Osc52Clipboard).
    if (Test-ShouldUseClipboardOsc52) {
        $commands.Add("Osc52") | Out-Null
    }

    # Non-Windows Set-Clipboard provider (where present) ranks after OSC52 because it is not a
    # reliable system clipboard on every non-Windows host.
    if ((-not $onWindows) -and $hasSetClipboard) {
        $commands.Add("Set-Clipboard") | Out-Null
    }

    $fallbackCommands = @("pbcopy", "xclip", "xsel", "wl-copy")
    foreach ($commandName in $fallbackCommands) {
        if ($null -ne (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            $commands.Add($commandName) | Out-Null
        }
    }

    if ($commands.Count -eq 0) {
        return @() # array-unwrap-safe: callers always wrap with @()
    }

    $deduplicated = New-Object System.Collections.Generic.List[string]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($command in $commands) {
        if ($seen.Add($command)) {
            $deduplicated.Add($command) | Out-Null
        }
    }

    return $deduplicated.ToArray()
}

function Set-ClipboardValue {
    # Thin, mockable seam over Set-Clipboard for the Windows/native GUI clipboard strategy. OSC52
    # no longer routes through Set-Clipboard (see Write-Osc52Clipboard), so this seam is
    # edition-stable and needs no -AsOSC52 capability handling.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    Set-Clipboard -Value $Value
}

function Wait-TaskObserved {
    # Waits up to a timeout for a Task and ALWAYS observes any fault, so a task that faults (for
    # example a pending WriteAsync/ReadToEndAsync broken by killing the child process) can never
    # surface later as an unobserved task exception. Returns $true if the task completed within the
    # timeout. Best-effort: never throws.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Threading.Tasks.Task]$Task,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60000)]
        [int]$TimeoutMilliseconds = 200
    )

    if ($null -eq $Task) {
        return $false
    }

    $completed = $false
    try {
        $completed = $Task.Wait($TimeoutMilliseconds)
    }
    catch {
        # A faulted task throws an AggregateException from Wait; observing it here marks the task
        # exception as handled so the finalizer never re-raises it.
        $completed = $Task.IsCompleted
    }

    # Touch the Exception property so a fault that completed between the Wait and here is observed.
    if ($Task.IsFaulted) {
        $null = $Task.Exception
    }

    return $completed
}

function Invoke-NativeClipboardTool {
    # Runs a native clipboard CLI (pbcopy/xclip/xsel/wl-copy) with FULLY redirected standard
    # streams so the tool never inherits the caller's terminal file descriptors. This is the fix
    # for the classic "clipboard hangs the terminal" bug: tools like xclip/xsel/wl-copy fork a
    # long-lived background child to serve the X/Wayland selection, and if that child inherits the
    # terminal's stdout/stderr it keeps them open after the script's own output has printed, so the
    # shell appears to hang for several seconds. Redirecting the child's stdio to pipes we own means
    # neither the tool nor its forked children can hold the terminal open. The whole call is also
    # bounded by a timeout (kill on overrun) so a misbehaving tool can never block the script.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tool,

        [Parameter(Mandatory = $false)]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 60)]
        [int]$TimeoutSeconds = 5
    )

    $command = Get-Command -Name $Tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command -or [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return $false
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$command.Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList $Arguments

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)

        # Drain stdout/stderr asynchronously so a tool that emits output cannot deadlock on a full
        # pipe buffer while we are writing its stdin. We never block process teardown on these:
        # abandoning them on the timeout path is safe (verified — .NET does not wait on pending
        # async pipe reads at exit).
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $timeoutMilliseconds = $TimeoutSeconds * 1000

        # Write the payload as raw UTF-8 (no BOM) bytes through the base stream. This guarantees
        # byte-for-byte verbatim delivery independent of $OutputEncoding / the console code page,
        # and is portable across Windows PowerShell 5.1 and PowerShell 7 (StandardInputEncoding is
        # 7+-only, so we avoid it). The write is bounded: a tool that never drains stdin could fill
        # the pipe buffer and block a synchronous Write indefinitely, so we run it on a task and cap
        # it with the same timeout budget. On overrun we fall through to the WaitForExit timeout,
        # which kills the process and severs the stream.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $baseStream = $process.StandardInput.BaseStream
        $writeTask = $baseStream.WriteAsync($bytes, 0, $bytes.Length)
        $writeCompleted = $false
        try {
            $writeCompleted = $writeTask.Wait($timeoutMilliseconds)
        }
        catch {
            # WriteAsync faulted (for example the tool exited and broke the pipe). Treated as a
            # failed write; WaitForExit/ExitCode below still governs the overall outcome.
        }

        if ($writeCompleted) {
            try {
                $baseStream.Flush()
                $process.StandardInput.Close()
            }
            catch {
                # The tool may have exited and closed its stdin already; treat as best effort and
                # let WaitForExit/ExitCode decide success.
            }
        }

        if (-not $process.WaitForExit($timeoutMilliseconds)) {
            # Terminate the whole tool process tree (the forked selection-server child included) via
            # the portable, reflection-guarded helper so nothing lingers after the timeout.
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                # Best-effort termination; a killed tool is still treated as a failed attempt.
            }
            # Observe the write task so a pending WriteAsync faulted by the kill (broken pipe) does
            # not surface later as an unobserved task exception.
            [void](Wait-TaskObserved -Task $writeTask -TimeoutMilliseconds 200)
            return $false
        }

        # Observe the (already completed or faulted) write task before returning on the normal path.
        [void](Wait-TaskObserved -Task $writeTask -TimeoutMilliseconds 200)

        if ($null -ne $stdoutTask) { [void](Wait-TaskObserved -Task $stdoutTask -TimeoutMilliseconds 1000) }
        if ($null -ne $stderrTask) { [void](Wait-TaskObserved -Task $stderrTask -TimeoutMilliseconds 1000) }

        return ($process.ExitCode -eq 0)
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
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

    $clipboardCommands = @(Get-ClipboardCommandPriority)
    if ((Get-SafeCount -InputObject $clipboardCommands) -eq 0) {
        Write-Warning "W_CLIPBOARD_UNAVAILABLE: No clipboard command is available (tried Set-Clipboard, pbcopy, xclip, xsel, wl-copy)."
        return $false
    }

    $valueToCopy = if ($null -eq $Text) { "" } else { $Text }
    $attemptErrors = New-Object System.Collections.Generic.List[string]

    foreach ($clipboardCommand in $clipboardCommands) {
        try {
            switch ($clipboardCommand) {
                "Osc52" {
                    Write-Osc52Clipboard -Text $valueToCopy
                    return $true
                }
                "Set-Clipboard" {
                    Set-ClipboardValue -Value $valueToCopy
                    return $true
                }
                "pbcopy" {
                    if (Invoke-NativeClipboardTool -Tool "pbcopy" -Text $valueToCopy) {
                        return $true
                    }
                    $attemptErrors.Add("[pbcopy] copy attempt failed") | Out-Null
                    continue
                }
                "xclip" {
                    if (Invoke-NativeClipboardTool -Tool "xclip" -Arguments @("-selection", "clipboard") -Text $valueToCopy) {
                        return $true
                    }
                    $attemptErrors.Add("[xclip] copy attempt failed") | Out-Null
                    continue
                }
                "xsel" {
                    if (Invoke-NativeClipboardTool -Tool "xsel" -Arguments @("--clipboard", "--input") -Text $valueToCopy) {
                        return $true
                    }
                    $attemptErrors.Add("[xsel] copy attempt failed") | Out-Null
                    continue
                }
                "wl-copy" {
                    if (Invoke-NativeClipboardTool -Tool "wl-copy" -Text $valueToCopy) {
                        return $true
                    }
                    $attemptErrors.Add("[wl-copy] copy attempt failed") | Out-Null
                    continue
                }
                default {
                    $attemptErrors.Add("[$clipboardCommand] unsupported command") | Out-Null
                    continue
                }
            }
        }
        catch {
            $safeMessage = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $SensitiveTokens
            $attemptErrors.Add("[$clipboardCommand] $safeMessage") | Out-Null
            continue
        }
    }

    $attemptSummary = if ($attemptErrors.Count -gt 0) {
        ($attemptErrors -join " | ")
    }
    else {
        "(no attempt diagnostics captured)"
    }

    Write-Warning "W_CLIPBOARD_COPY_FAILED: Failed to copy output using available clipboard commands. Attempts: $attemptSummary"
    return $false
}

function Resolve-OutputFilePath {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "E_INVALID_OUTPUT_PATH: OutputPath cannot be empty."
    }

    try {
        $trimmedPath = $Path.Trim()
        $resolvedPath = if ([System.IO.Path]::IsPathRooted($trimmedPath)) {
            [System.IO.Path]::GetFullPath($trimmedPath)
        }
        else {
            $combined = Join-Path -Path (Get-Location).Path -ChildPath $trimmedPath
            [System.IO.Path]::GetFullPath($combined)
        }

        $directoryPath = [System.IO.Path]::GetDirectoryName($resolvedPath)
        if (-not [string]::IsNullOrWhiteSpace($directoryPath) -and -not (Test-Path -Path $directoryPath -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($directoryPath)
        }

        return $resolvedPath
    }
    catch {
        $safeMessage = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $SensitiveTokens
        throw "E_INVALID_OUTPUT_PATH: Failed to resolve OutputPath '$Path'. $safeMessage"
    }
}

function Write-RenderedOutputToFile {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    $resolvedPath = Resolve-OutputFilePath -Path $OutputPath -SensitiveTokens $SensitiveTokens
    $content = if ($null -eq $Text) { "" } else { $Text }

    try {
        [System.IO.File]::WriteAllText($resolvedPath, $content, [System.Text.UTF8Encoding]::new($false))
        return $resolvedPath
    }
    catch {
        $safeMessage = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $SensitiveTokens
        throw "E_OUTPUT_WRITE_FAILED: Failed to write output to '$resolvedPath'. $safeMessage"
    }
}

function Test-CanPromptForLogin {
    [CmdletBinding()]
    param()

    try {
        return (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
    }
    catch {
        return $false
    }
}

function New-AuthTokenResolutionResult {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$EnvironmentVariable
    )

    $normalizedToken = if ([string]::IsNullOrWhiteSpace($Token)) {
        $null
    }
    else {
        $Token.Trim()
    }

    $sourceCategory = "unknown"
    switch ($Source) {
        "explicit" {
            $sourceCategory = "explicit"
            break
        }
        "GH_TOKEN" {
            $sourceCategory = "environment"
            break
        }
        "GITHUB_TOKEN" {
            $sourceCategory = "environment"
            break
        }
        "gh" {
            $sourceCategory = "gh"
            break
        }
        "git-credential" {
            $sourceCategory = "git-credential"
            break
        }
        "none" {
            $sourceCategory = "none"
            break
        }
    }

    return [pscustomobject]@{
        Token               = $normalizedToken
        Source              = $Source
        SourceCategory      = $sourceCategory
        EnvironmentVariable = $EnvironmentVariable
    }
}

function Invoke-GitHubCliAuthCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,

        [Parameter(Mandatory = $false)]
        [switch]$IgnoreEnvironmentTokens
    )

    $originalGhToken = $env:GH_TOKEN
    $originalGitHubToken = $env:GITHUB_TOKEN

    try {
        if ($IgnoreEnvironmentTokens.IsPresent) {
            $env:GH_TOKEN = $null
            $env:GITHUB_TOKEN = $null
        }

        return & $Command
    }
    finally {
        if ($IgnoreEnvironmentTokens.IsPresent) {
            $env:GH_TOKEN = $originalGhToken
            $env:GITHUB_TOKEN = $originalGitHubToken
        }
    }
}

function Get-GitCredentialToken {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 30)]
        [int]$TimeoutSeconds = 5
    )

    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace([string]$gitCommand.Source)) {
        return $null
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$gitCommand.Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("credential", "fill")
    Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "GIT_TERMINAL_PROMPT" -Value "0"
    Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "GCM_INTERACTIVE" -Value "Never"

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.StandardInput.Write("protocol=https`nhost=$GitHubHost`n`n")
        $process.StandardInput.Close()

        $timeoutMilliseconds = $TimeoutSeconds * 1000
        if (-not $process.WaitForExit($timeoutMilliseconds)) {
            try {
                $process.Kill()
            }
            catch {
                # Best-effort cleanup for a non-interactive credential probe.
            }
            return $null
        }

        [void]$stdoutTask.Wait(1000)
        [void]$stderrTask.Wait(1000)

        if ($process.ExitCode -ne 0) {
            return $null
        }

        $output = [string]$stdoutTask.Result
        foreach ($line in @($output -split "`r?`n")) {
            if ($line.StartsWith("password=", [System.StringComparison]::Ordinal)) {
                $candidate = $line.Substring("password=".Length).Trim()
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    return $candidate
                }
            }
        }

        return $null
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Resolve-AuthTokenWithSource {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ExplicitToken,

        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $false)]
        [switch]$AllowInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$IgnoreEnvironmentTokens,

        [Parameter(Mandatory = $false)]
        [string[]]$RejectedTokenValues = @()
    )

    $rejectedTokenSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    foreach ($rejectedTokenValue in $RejectedTokenValues) {
        if ([string]::IsNullOrWhiteSpace($rejectedTokenValue)) {
            continue
        }

        $trimmedRejectedTokenValue = $rejectedTokenValue.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmedRejectedTokenValue)) {
            $rejectedTokenSet.Add($trimmedRejectedTokenValue) | Out-Null
        }
    }

    $resolveCandidate = {
        param(
            [Parameter(Mandatory = $false)]
            [AllowNull()]
            [string]$CandidateToken,

            [Parameter(Mandatory = $true)]
            [string]$Source,

            [Parameter(Mandatory = $false)]
            [AllowNull()]
            [string]$EnvironmentVariable
        )

        if ([string]::IsNullOrWhiteSpace($CandidateToken)) {
            return $null
        }

        $trimmedCandidateToken = $CandidateToken.Trim()
        if ($rejectedTokenSet.Contains($trimmedCandidateToken)) {
            Write-Verbose "Skipping previously rejected token from source '$Source'."
            return $null
        }

        return New-AuthTokenResolutionResult -Token $trimmedCandidateToken -Source $Source -EnvironmentVariable $EnvironmentVariable
    }

    $explicitResolution = & $resolveCandidate -CandidateToken $ExplicitToken -Source "explicit" -EnvironmentVariable $null
    if ($null -ne $explicitResolution) {
        return $explicitResolution
    }

    if (-not $IgnoreEnvironmentTokens.IsPresent) {
        $ghTokenResolution = & $resolveCandidate -CandidateToken $env:GH_TOKEN -Source "GH_TOKEN" -EnvironmentVariable "GH_TOKEN"
        if ($null -ne $ghTokenResolution) {
            return $ghTokenResolution
        }

        $githubTokenResolution = & $resolveCandidate -CandidateToken $env:GITHUB_TOKEN -Source "GITHUB_TOKEN" -EnvironmentVariable "GITHUB_TOKEN"
        if ($null -ne $githubTokenResolution) {
            return $githubTokenResolution
        }
    }

    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue

    if ($null -ne $ghCmd) {
        try {
            $tokenOutput = Invoke-GitHubCliAuthCommand -IgnoreEnvironmentTokens -Command {
                & gh auth token --hostname $GitHubHost 2>$null
            }

            if ($LASTEXITCODE -eq 0) {
                $ghCliResolution = & $resolveCandidate -CandidateToken $tokenOutput -Source "gh" -EnvironmentVariable $null
                if ($null -ne $ghCliResolution) {
                    return $ghCliResolution
                }
            }
        }
        catch {
            # Continue to git credential and interactive fallback only if allowed.
        }
    }

    $gitCredentialToken = Get-GitCredentialToken -GitHubHost $GitHubHost
    $gitCredentialResolution = & $resolveCandidate -CandidateToken $gitCredentialToken -Source "git-credential" -EnvironmentVariable $null
    if ($null -ne $gitCredentialResolution) {
        return $gitCredentialResolution
    }

    if (-not $AllowInteractive.IsPresent) {
        return New-AuthTokenResolutionResult -Token $null -Source "none" -EnvironmentVariable $null
    }

    if ($null -eq $ghCmd) {
        throw "E_AUTH_REQUIRED: GitHub CLI (gh) is required for interactive login but is not installed."
    }

    if (-not (Test-CanPromptForLogin)) {
        throw "E_AUTH_REQUIRED: Interactive login is unavailable because input/output is redirected. Provide -Token or set GH_TOKEN/GITHUB_TOKEN."
    }

    Write-Host "No usable GitHub token found. Starting GitHub CLI login for $GitHubHost..." -ForegroundColor Yellow
    [void](Invoke-GitHubCliAuthCommand -IgnoreEnvironmentTokens:$IgnoreEnvironmentTokens -Command {
            & gh auth login --hostname $GitHubHost --web --git-protocol https --scopes repo | Out-Null
        })
    if ($LASTEXITCODE -ne 0) {
        throw "E_AUTH_REQUIRED: GitHub CLI login was not completed."
    }

    $tokenOutput = Invoke-GitHubCliAuthCommand -IgnoreEnvironmentTokens:$IgnoreEnvironmentTokens -Command {
        & gh auth token --hostname $GitHubHost 2>$null
    }
    if ($LASTEXITCODE -eq 0) {
        if ([string]::IsNullOrWhiteSpace($tokenOutput)) {
            throw "E_AUTH_REQUIRED: Login succeeded but no token was returned by GitHub CLI."
        }

        $postLoginResolution = & $resolveCandidate -CandidateToken $tokenOutput -Source "gh" -EnvironmentVariable $null
        if ($null -ne $postLoginResolution) {
            return $postLoginResolution
        }

        throw "E_AUTH_REQUIRED: Login succeeded but returned a token that was already rejected in this session. Refresh or unset GH_TOKEN/GITHUB_TOKEN, then retry."
    }

    throw "E_AUTH_REQUIRED: Login succeeded but no token was returned by GitHub CLI."
}

function Get-AuthToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ExplicitToken,

        [Parameter(Mandatory = $true)]
        [string]$GitHubHost,

        [Parameter(Mandatory = $false)]
        [switch]$AllowInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeSourceMetadata,

        [Parameter(Mandatory = $false)]
        [switch]$IgnoreEnvironmentTokens,

        [Parameter(Mandatory = $false)]
        [string[]]$RejectedTokenValues = @()
    )

    $resolution = Resolve-AuthTokenWithSource -ExplicitToken $ExplicitToken -GitHubHost $GitHubHost -AllowInteractive:$AllowInteractive -IgnoreEnvironmentTokens:$IgnoreEnvironmentTokens -RejectedTokenValues $RejectedTokenValues
    if ($IncludeSourceMetadata.IsPresent) {
        return $resolution
    }

    return $resolution.Token
}

function Convert-ToAuthTokenResolutionResult {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $AuthTokenValue,

        [Parameter(Mandatory = $false)]
        [string]$FallbackSource = "unknown"
    )

    if ($null -eq $AuthTokenValue) {
        return New-AuthTokenResolutionResult -Token $null -Source "none" -EnvironmentVariable $null
    }

    if ($AuthTokenValue -is [string]) {
        return New-AuthTokenResolutionResult -Token $AuthTokenValue -Source $FallbackSource -EnvironmentVariable $null
    }

    $tokenValue = $null
    $sourceValue = $FallbackSource
    $sourceCategoryValue = $null
    $environmentVariableValue = $null
    $hasToken = $false

    if ($AuthTokenValue -is [System.Collections.IDictionary]) {
        if ($AuthTokenValue.Contains("Token")) {
            $tokenValue = $AuthTokenValue["Token"]
            $hasToken = $true
        }
        if ($AuthTokenValue.Contains("Source") -and -not [string]::IsNullOrWhiteSpace([string]$AuthTokenValue["Source"])) {
            $sourceValue = [string]$AuthTokenValue["Source"]
        }
        if ($AuthTokenValue.Contains("SourceCategory") -and -not [string]::IsNullOrWhiteSpace([string]$AuthTokenValue["SourceCategory"])) {
            $sourceCategoryValue = [string]$AuthTokenValue["SourceCategory"]
        }
        if ($AuthTokenValue.Contains("EnvironmentVariable") -and -not [string]::IsNullOrWhiteSpace([string]$AuthTokenValue["EnvironmentVariable"])) {
            $environmentVariableValue = [string]$AuthTokenValue["EnvironmentVariable"]
        }
    }
    else {
        if ($AuthTokenValue.PSObject.Properties.Name -contains "Token") {
            $tokenValue = $AuthTokenValue.Token
            $hasToken = $true
        }
        if ($AuthTokenValue.PSObject.Properties.Name -contains "Source" -and -not [string]::IsNullOrWhiteSpace([string]$AuthTokenValue.Source)) {
            $sourceValue = [string]$AuthTokenValue.Source
        }
        if ($AuthTokenValue.PSObject.Properties.Name -contains "SourceCategory" -and -not [string]::IsNullOrWhiteSpace([string]$AuthTokenValue.SourceCategory)) {
            $sourceCategoryValue = [string]$AuthTokenValue.SourceCategory
        }
        if ($AuthTokenValue.PSObject.Properties.Name -contains "EnvironmentVariable" -and -not [string]::IsNullOrWhiteSpace([string]$AuthTokenValue.EnvironmentVariable)) {
            $environmentVariableValue = [string]$AuthTokenValue.EnvironmentVariable
        }
    }

    if (-not $hasToken) {
        return New-AuthTokenResolutionResult -Token ([string]$AuthTokenValue) -Source $FallbackSource -EnvironmentVariable $null
    }

    $normalizedResolution = New-AuthTokenResolutionResult -Token ([string]$tokenValue) -Source $sourceValue -EnvironmentVariable $environmentVariableValue
    if (-not [string]::IsNullOrWhiteSpace($sourceCategoryValue)) {
        $normalizedResolution.SourceCategory = $sourceCategoryValue
    }

    return $normalizedResolution
}
function Resolve-WebRequestSessionType {
    [OutputType([type])]
    [CmdletBinding()]
    param()

    $typeName = "Microsoft.PowerShell.Commands.WebRequestSession"
    foreach ($assembly in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
        $candidateType = $assembly.GetType($typeName, $false, $false)
        if ($null -ne $candidateType) {
            return $candidateType
        }
    }

    try {
        Import-Module -Name Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
    }
    catch {
        return $null
    }

    foreach ($assembly in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
        $candidateType = $assembly.GetType($typeName, $false, $false)
        if ($null -ne $candidateType) {
            return $candidateType
        }
    }

    return $null
}

function New-GitHubWebSession {
    # Creates one reusable web session for the whole run. Passing the SAME session object to every
    # Invoke-RestMethod / Invoke-WebRequest call makes PowerShell reuse a single pooled TCP/TLS
    # connection to the GitHub host across all requests (token validation + paginated GraphQL/REST),
    # eliminating a redundant DNS + TCP + TLS handshake on every call after the first. The
    # WebRequestSession type can be loaded without being resolvable through a bare type literal in
    # some hosts, so creation goes through a dynamic, nullable seam.
    [CmdletBinding()]
    param()

    $sessionType = Resolve-WebRequestSessionType
    if ($null -eq $sessionType) {
        return $null
    }

    try {
        return [System.Activator]::CreateInstance($sessionType)
    }
    catch {
        return $null
    }
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

    # Suppress the PowerShell web-cmdlet progress bar. On a real terminal it hides the cursor and
    # emits DSR cursor-position queries (ESC[6n); the terminal's replies queue into stdin, and the
    # fast process exit skips PowerShell's progress/input cleanup, leaving those replies to corrupt
    # the parent shell's input (dead arrow keys / no echo) after the script finishes. It is also
    # pure noise for this non-interactive tool. Function-scoped so it never leaks to the caller.
    $ProgressPreference = "SilentlyContinue"

    while ($true) {
        $attempt++

        if ([datetime]::UtcNow -gt $OverallDeadlineUtc) {
            throw "E_NETWORK_TIMEOUT: Overall timeout exceeded while calling GitHub API."
        }

        try {
            # Reuse the per-run pooled connection when a shared session is available (it is $null in
            # dot-sourced unit tests, which keeps their behavior unchanged). Passing the same session
            # to every call makes PowerShell reuse one TCP/TLS connection to the host. Only the
            # optional session is splatted so every other parameter stays an explicit literal.
            $sessionArgs = @{}
            if ($null -ne $script:GitHubWebSession) {
                $sessionArgs["WebSession"] = $script:GitHubWebSession
            }

            if ($Method -eq "GET") {
                return Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -TimeoutSec $RequestTimeoutSeconds @sessionArgs
            }

            $jsonBody = if ($null -eq $Body) { "{}" } else { $Body | ConvertTo-Json -Depth 20 }
            return Invoke-RestMethod -Method POST -Uri $Uri -Headers $Headers -ContentType "application/json" -Body $jsonBody -TimeoutSec $RequestTimeoutSeconds @sessionArgs
        }
        catch {
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
                        }
                        else {
                            $retryAfterDate = [DateTimeOffset]::MinValue
                            if ([DateTimeOffset]::TryParseExact($retryAfterCandidate, "r", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$retryAfterDate)) {
                                $resetValue = $retryAfterDate.ToUnixTimeSeconds().ToString()
                            }
                            else {
                                $retryAfterDiagnostics = Get-HeaderValueDiagnostics -Key 'Retry-After' -Values @($retryAfterValue)
                                throw "E_RATE_LIMIT: Invalid Retry-After value '$retryAfterCandidate'. $retryAfterDiagnostics"
                            }
                        }
                    }
                }

                if ($null -ne $resetValue) {
                    $resetEpoch = [int64]0
                    if (-not [int64]::TryParse($resetValue, [ref]$resetEpoch)) {
                        $rateLimitResetDiagnostics = Get-HeaderValueDiagnostics -Key 'X-RateLimit-Reset' -Values @($resetValue)
                        throw "E_RATE_LIMIT: Invalid rate-limit reset value '$resetValue'. $rateLimitResetDiagnostics"
                    }

                    $resetUtc = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).UtcDateTime
                    if ($resetUtc -le [datetime]::UtcNow) {
                        throw "E_RATE_LIMIT: Invalid or expired rate-limit reset timestamp."
                    }

                    $timeToReset = $resetUtc - [datetime]::UtcNow
                    if ($timeToReset.TotalSeconds -gt [int]::MaxValue) {
                        throw "E_RATE_LIMIT: Rate-limit reset timestamp is too far in the future."
                    }

                    $waitSeconds = [int][math]::Ceiling($timeToReset.TotalSeconds)
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
                $baseDelay = [math]::Pow(2, $attempt - 1)
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

    # Suppress the web-cmdlet progress bar so Invoke-WebRequest cannot probe/manipulate the terminal
    # (cursor hide + DSR queries) and leave stray query-responses in the parent shell's input.
    # Function-scoped so it never leaks to the caller.
    $ProgressPreference = "SilentlyContinue"

    while ($true) {
        $attempt++

        $remainingSeconds = [int][math]::Floor(($OverallDeadlineUtc - [datetime]::UtcNow).TotalSeconds)
        if ($remainingSeconds -lt 1) {
            throw "E_NETWORK_TIMEOUT: Token validation deadline was exceeded before request start for $Owner/$Repo on $GitHubHost."
        }

        $effectiveRequestTimeoutSeconds = [math]::Min($RequestTimeoutSeconds, $remainingSeconds)
        if ($effectiveRequestTimeoutSeconds -lt 1) {
            throw "E_NETWORK_TIMEOUT: Token validation timeout budget is exhausted for $Owner/$Repo on $GitHubHost."
        }

        try {
            # -UseBasicParsing avoids the Internet Explorer engine dependency on Windows
            # PowerShell 5.1 (no-op on PowerShell 7+); it stays an explicit literal so the
            # cross-version compatibility gate can verify it. Only the optional shared session is
            # splatted, so the per-run pooled connection is reused across this validation call and
            # the subsequent GraphQL/REST calls without hiding -UseBasicParsing from the analyzer.
            $sessionArgs = @{}
            if ($null -ne $script:GitHubWebSession) {
                $sessionArgs["WebSession"] = $script:GitHubWebSession
            }
            $response = Invoke-WebRequest -Method GET -Uri $uri -Headers $Headers -TimeoutSec $effectiveRequestTimeoutSeconds -UseBasicParsing @sessionArgs
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
                    $scopeHeaderDiagnostics = Get-HeaderValueDiagnostics -Key 'X-OAuth-Scopes' -Values $scopeHeaderValues
                    throw "E_MALFORMED_RESPONSE: Token scope header did not contain any non-empty scope values. $scopeHeaderDiagnostics"
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
                $baseDelaySeconds = [math]::Pow(2, $attempt - 1)
                $jitterMs = Get-Random -Minimum 0 -Maximum 300
                $delayMs = [int]($baseDelaySeconds * 1000 + $jitterMs)

                $remainingDelayBudgetMs = [int][math]::Floor(($OverallDeadlineUtc - [datetime]::UtcNow).TotalMilliseconds)
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
                }
                else {
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
        }
        else {
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
        [switch]$Truncate,

        [Parameter(Mandatory = $false)]
        [switch]$KeepMarkup
    )

    $isResolved = Get-ObjectPropertyValue -InputObject $Thread -Name "isResolved"
    if ($isResolved) {
        return $null
    }

    $resolutionState = Get-ObjectPropertyValue -InputObject $Thread -Name "resolutionState"
    if ([string]::IsNullOrWhiteSpace([string]$resolutionState)) {
        $resolutionState = "unresolved"
    }

    $threadComments = Get-ObjectPropertyValue -InputObject $Thread -Name "comments"
    $commentNodes = Get-ObjectPropertyValue -InputObject $threadComments -Name "nodes" -NoEnumerate
    if ($null -eq $threadComments -or $null -eq $commentNodes) {
        return $null
    }

    if ($commentNodes -isnot [System.Array]) {
        throw "E_MALFORMED_RESPONSE: Review thread comments.nodes must be an array."
    }

    $comments = $commentNodes
    $commentCount = Get-SafeCount -InputObject $comments
    if ($commentCount -eq 0) {
        return $null
    }

    $top = $comments[0]
    $latestReply = if ($commentCount -gt 1) { $comments[$commentCount - 1] } else { $null }

    $topBody = Get-ObjectPropertyValue -InputObject $top -Name "body"
    if ($null -ne $topBody -and $topBody -isnot [string]) {
        $topBodyType = $topBody.GetType().FullName
        throw "E_MALFORMED_RESPONSE: Review thread top-level comment body must be a string (received '$topBodyType')."
    }

    $latestReplyBody = Get-ObjectPropertyValue -InputObject $latestReply -Name "body"
    if ($null -ne $latestReply -and $null -ne $latestReplyBody -and $latestReplyBody -isnot [string]) {
        $replyBodyType = $latestReplyBody.GetType().FullName
        throw "E_MALFORMED_RESPONSE: Review thread latest reply body must be a string (received '$replyBodyType')."
    }

    $lineRange = Resolve-ReviewThreadLineRange -Thread $Thread
    $lineStart = $lineRange.Start
    $lineEnd = $lineRange.End
    $githubAnchor = Resolve-ReviewThreadGitHubAnchor -Thread $Thread

    $threadPath = Get-ObjectPropertyValue -InputObject $Thread -Name "path"
    $safePath = if ([string]::IsNullOrWhiteSpace($threadPath)) { "<conversation>" } else { ([string]$threadPath -replace "\\", "/") }
    $embeddedLocations = @(Get-EmbeddedCommentLocations -Text $topBody)
    $outputLocation = Resolve-OutputCommentLocation -DefaultPath $safePath -DefaultStart $lineStart -DefaultEnd $lineEnd -EmbeddedLocations $embeddedLocations
    $topLevelComment = if ($Truncate.IsPresent) {
        Normalize-CommentText -Text $topBody -MaxLength 500 -KeepMarkup:$KeepMarkup
    }
    else {
        Normalize-CommentText -Text $topBody -DisableTruncation -KeepMarkup:$KeepMarkup
    }

    $topLevelAuthor = Get-ReviewCommentAuthorLogin -Comment $top
    $latestReplyAuthor = if ($null -eq $latestReply) {
        $null
    }
    else {
        Get-ReviewCommentAuthorLogin -Comment $latestReply
    }

    # Suggested-change blocks are preserved verbatim and rendered separately from prose. Plain
    # prose comments are also surfaced as structured recommendation records so bot-authored
    # recommendations (Copilot/Cursor/Bugbot) are not reduced to anonymous text.
    # KeepMarkup keeps the raw body intact, so suggestion extraction is skipped there.
    # Scan EVERY comment in the thread (in order), not just the top comment: reviewers and bots
    # (Copilot, Cursor) frequently attach the "```suggestion" block as a follow-up reply rather
    # than on the first comment, so a top-only scan would silently drop those suggestions.
    $suggestions = @()
    $recommendations = @()
    $commentRecords = @()
    $collectedSuggestions = New-Object System.Collections.Generic.List[object]
    $collectedRecommendations = New-Object System.Collections.Generic.List[object]
    $collectedCommentRecords = New-Object System.Collections.Generic.List[object]
    for ($commentIndex = 0; $commentIndex -lt $commentCount; $commentIndex++) {
        $commentNode = $comments[$commentIndex]
        $commentBody = Get-ObjectPropertyValue -InputObject $commentNode -Name "body"
        if ($null -eq $commentBody) {
            continue
        }

        if ($commentBody -isnot [string]) {
            $commentBodyType = $commentBody.GetType().FullName
            throw "E_MALFORMED_RESPONSE: Review thread comment body must be a string (received '$commentBodyType')."
        }

        $commentAuthorLogin = Get-ReviewCommentAuthorLogin -Comment $commentNode
        $commentUrl = Get-ReviewCommentUrl -Comment $commentNode
        $commentDatabaseId = Get-ReviewCommentDatabaseId -Comment $commentNode
        $commentDiffHunk = Get-ReviewCommentDiffHunk -Comment $commentNode
        $commentRecommendationText = if ($Truncate.IsPresent) {
            Normalize-CommentText -Text $commentBody -MaxLength 500 -KeepMarkup:$KeepMarkup
        }
        else {
            Normalize-CommentText -Text $commentBody -DisableTruncation -KeepMarkup:$KeepMarkup
        }

        $commentSuggestionRecords = @()
        if (-not $KeepMarkup.IsPresent) {
            $commentSuggestionRecords = @(Get-CommentSuggestionBlocks -Text $commentBody -AuthorLogin $commentAuthorLogin -CommentIndex $commentIndex -Url $commentUrl)
        }
        $suggestedDiffsUnavailableReason = Get-SuggestedDiffsUnavailableReason -AuthorLogin $commentAuthorLogin -Body $commentBody -SuggestedChangeCount (Get-SafeCount -InputObject $commentSuggestionRecords)

        if ((-not [string]::IsNullOrWhiteSpace($commentRecommendationText) -and $commentRecommendationText -ne "(none)") -or -not [string]::IsNullOrWhiteSpace($commentDiffHunk) -or (Get-SafeCount -InputObject $commentSuggestionRecords) -gt 0) {
            $collectedCommentRecords.Add((New-ThreadCommentRecord -CommentIndex $commentIndex -DatabaseId $commentDatabaseId -Body $commentRecommendationText -DiffHunk $commentDiffHunk -SuggestedChanges $commentSuggestionRecords -SuggestedDiffsUnavailableReason $suggestedDiffsUnavailableReason -Url $commentUrl)) | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($commentRecommendationText) -and $commentRecommendationText -ne "(none)") {
            $collectedRecommendations.Add((New-CommentRecommendationRecord -Kind "comment" -AuthorLogin $commentAuthorLogin -Text $commentRecommendationText -Code $null -CommentIndex $commentIndex -Url $commentUrl)) | Out-Null
        }

        foreach ($suggestion in @($commentSuggestionRecords)) {
            $collectedSuggestions.Add($suggestion) | Out-Null
            $suggestionCode = Get-ObjectPropertyValue -InputObject $suggestion -Name "code"
            $collectedRecommendations.Add((New-CommentRecommendationRecord -Kind "suggestion" -AuthorLogin $commentAuthorLogin -Text $null -Code $suggestionCode -CommentIndex $commentIndex -Url $commentUrl)) | Out-Null
        }
    }

    $suggestions = @($collectedSuggestions.ToArray())
    $recommendations = @($collectedRecommendations.ToArray())
    $commentRecords = @($collectedCommentRecords.ToArray())

    $latestReplySummary = if ($null -eq $latestReply) {
        $null
    }
    elseif ($Truncate.IsPresent) {
        Normalize-CommentText -Text $latestReplyBody -MaxLength 300 -KeepMarkup:$KeepMarkup
    }
    else {
        Normalize-CommentText -Text $latestReplyBody -DisableTruncation -KeepMarkup:$KeepMarkup
    }

    $threadId = Get-ObjectPropertyValue -InputObject $Thread -Name "id"

    return [pscustomobject]@{
        path               = $outputLocation.Path
        lineStart          = $outputLocation.Start
        lineEnd            = $outputLocation.End
        locationSource     = $outputLocation.Source
        githubPath         = $safePath
        githubLineStart    = $githubAnchor.Start
        githubLineEnd      = $githubAnchor.End
        embeddedLocations  = @($embeddedLocations)
        comments           = @($commentRecords)
        suggestions        = @($suggestions)
        recommendations    = @($recommendations)
        topLevelAuthor     = $topLevelAuthor
        topLevelComment    = $topLevelComment
        latestReplyAuthor  = $latestReplyAuthor
        latestReplySummary = $latestReplySummary
        resolutionState    = [string]$resolutionState
        threadId           = [string]$threadId
        prNumber           = $PrNumber
        owner              = $Owner
        repo               = $Repo
        url                = "https://$GitHubHost/$Owner/$Repo/pull/$PrNumber"
    }
}

function Convert-RestReviewCommentToThreadCommentNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Comment
    )

    return [pscustomobject]@{
        databaseId = Get-ObjectPropertyValue -InputObject $Comment -Name "id"
        body       = Get-ObjectPropertyValue -InputObject $Comment -Name "body"
        createdAt  = Get-ObjectPropertyValue -InputObject $Comment -Name "created_at"
        url        = Get-ObjectPropertyValue -InputObject $Comment -Name "html_url"
        diffHunk   = Get-ObjectPropertyValue -InputObject $Comment -Name "diff_hunk"
        author     = [pscustomobject]@{
            login = Get-ObjectPropertyValue -InputObject (Get-ObjectPropertyValue -InputObject $Comment -Name "user") -Name "login"
        }
    }
}

function Convert-RestReviewCommentsToThreadLikeObjects {
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$Comments = @()
    )

    $topLevelComments = New-Object System.Collections.Generic.List[object]
    $repliesByParentId = @{}

    foreach ($comment in @($Comments)) {
        if ($null -eq $comment) {
            continue
        }

        $id = Get-ObjectPropertyValue -InputObject $comment -Name "id"
        if ($null -eq $id) {
            continue
        }

        $idText = [string]$id
        if ([string]::IsNullOrWhiteSpace($idText)) {
            continue
        }

        $parentId = Get-ObjectPropertyValue -InputObject $comment -Name "in_reply_to_id"
        if ($null -eq $parentId -or [string]::IsNullOrWhiteSpace([string]$parentId)) {
            $topLevelComments.Add($comment) | Out-Null
            continue
        }

        $parentIdText = [string]$parentId
        if (-not $repliesByParentId.ContainsKey($parentIdText)) {
            $repliesByParentId[$parentIdText] = New-Object System.Collections.Generic.List[object]
        }

        $repliesByParentId[$parentIdText].Add($comment) | Out-Null
    }

    $threads = New-Object System.Collections.Generic.List[object]
    foreach ($topLevelComment in $topLevelComments) {
        $topLevelId = Get-ObjectPropertyValue -InputObject $topLevelComment -Name "id"
        if ($null -eq $topLevelId) {
            continue
        }

        $topLevelIdText = [string]$topLevelId
        if ([string]::IsNullOrWhiteSpace($topLevelIdText)) {
            continue
        }

        $commentNodes = New-Object System.Collections.Generic.List[object]
        $commentNodes.Add((Convert-RestReviewCommentToThreadCommentNode -Comment $topLevelComment)) | Out-Null

        if ($repliesByParentId.ContainsKey($topLevelIdText)) {
            foreach ($reply in @($repliesByParentId[$topLevelIdText].ToArray())) {
                $commentNodes.Add((Convert-RestReviewCommentToThreadCommentNode -Comment $reply)) | Out-Null
            }
        }

        $line = Get-ObjectPropertyValue -InputObject $topLevelComment -Name "line"
        $startLine = Get-ObjectPropertyValue -InputObject $topLevelComment -Name "start_line"
        $originalLine = Get-ObjectPropertyValue -InputObject $topLevelComment -Name "original_line"
        $originalStartLine = Get-ObjectPropertyValue -InputObject $topLevelComment -Name "original_start_line"

        $threads.Add([pscustomobject]@{
                id                = "rest:$topLevelIdText"
                isResolved        = $false
                resolutionState   = "unknown"
                path              = Get-ObjectPropertyValue -InputObject $topLevelComment -Name "path"
                startLine         = $startLine
                line              = $line
                originalStartLine = $originalStartLine
                originalLine      = $originalLine
                comments          = [pscustomobject]@{
                    nodes = $commentNodes.ToArray()
                }
            }) | Out-Null
    }

    return $threads.ToArray()
}

function Add-SuggestionRenderLines {
    # Appends verbatim "Suggested change" blocks to the rendered text output. Suggestion
    # code is preserved exactly (multi-line, no whitespace collapsing) so suggested
    # implementations from Copilot/Cursor/GitHub remain copy-paste accurate.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Lines,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Suggestions
    )

    if ($null -eq $Suggestions) {
        return
    }

    foreach ($suggestion in @($Suggestions)) {
        if ($null -eq $suggestion) {
            continue
        }

        $code = Get-ObjectPropertyValue -InputObject $suggestion -Name "code"
        $codeText = if ($null -eq $code) { "" } else { [string]$code }

        if ([string]::IsNullOrEmpty($codeText)) {
            # An empty GitHub suggestion block means "delete the targeted lines".
            $Lines.Add("Suggested change (remove the lines):") | Out-Null
            continue
        }

        $Lines.Add("Suggested change:") | Out-Null
        foreach ($codeLine in ($codeText -split "`n")) {
            $Lines.Add($codeLine) | Out-Null
        }
    }
}

function Convert-SuggestedDiffTextToPublicChangeOnlyDiff {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Diff
    )

    if ([string]::IsNullOrWhiteSpace($Diff)) {
        return $null
    }

    $normalized = $Diff -replace "`r`n", "`n" -replace "`r", "`n"
    $changedLines = New-Object System.Collections.Generic.List[string]
    $insideHunk = $false
    foreach ($line in ($normalized -split "`n")) {
        if ($line -match '^@@\s') {
            $insideHunk = $true
            continue
        }

        if (-not $insideHunk -and ($line -match '^(diff --git|index\s|---\s|\+\+\+\s)')) {
            continue
        }

        if ($line -match '^\\ No newline at end of file$') {
            continue
        }

        if ($line.StartsWith("+", [System.StringComparison]::Ordinal) -or $line.StartsWith("-", [System.StringComparison]::Ordinal)) {
            $changedLines.Add($line) | Out-Null
        }
    }

    if ($changedLines.Count -eq 0) {
        return $null
    }

    return ($changedLines.ToArray() -join "`n")
}

function Add-CommentRecommendationRenderLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Lines,

        [Parameter(Mandatory = $true)]
        $Recommendation
    )

    $text = Get-ObjectPropertyValue -InputObject $Recommendation -Name "text"
    if ([string]::IsNullOrWhiteSpace([string]$text)) {
        return
    }

    $Lines.Add("Recommendation:") | Out-Null

    foreach ($textLine in ([string]$text -split "`n")) {
        $Lines.Add($textLine) | Out-Null
    }
}

function Add-ThreadCommentRenderLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Lines,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Comments
    )

    if ($null -eq $Comments) {
        return
    }

    $commentArray = @($Comments)
    $commentCount = Get-SafeCount -InputObject $commentArray
    for ($index = 0; $index -lt $commentCount; $index++) {
        $comment = $commentArray[$index]
        if ($null -eq $comment) {
            continue
        }

        $body = Get-ObjectPropertyValue -InputObject $comment -Name "body"
        if ([string]$body -eq "(none)") {
            $body = $null
        }
        $suggestedChanges = Get-ObjectPropertyValue -InputObject $comment -Name "suggestedChanges"
        $suggestedChangeCount = Get-SafeCount -InputObject $suggestedChanges
        $suggestedDiffs = Get-ObjectPropertyValue -InputObject $comment -Name "suggestedDiffs"
        $suggestedDiffCount = Get-SafeCount -InputObject $suggestedDiffs
        $suggestedDiffsUnavailableReason = Get-ObjectPropertyValue -InputObject $comment -Name "suggestedDiffsUnavailableReason"
        if ([string]::IsNullOrWhiteSpace([string]$body) -and $suggestedChangeCount -eq 0 -and $suggestedDiffCount -eq 0 -and [string]::IsNullOrWhiteSpace([string]$suggestedDiffsUnavailableReason)) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$body)) {
            if ($commentCount -gt 1) {
                $Lines.Add(("Suggestion {0}:" -f ($index + 1))) | Out-Null
            }
            else {
                $Lines.Add("Suggestion:") | Out-Null
            }

            foreach ($bodyLine in ([string]$body -split "`n")) {
                $Lines.Add($bodyLine) | Out-Null
            }
        }

        if ($null -ne $suggestedChanges -and $suggestedChangeCount -gt 0) {
            Add-SuggestionRenderLines -Lines $Lines -Suggestions $suggestedChanges
        }

        if ($suggestedDiffCount -gt 0) {
            foreach ($suggestedDiff in @($suggestedDiffs)) {
                $diffText = Get-ObjectPropertyValue -InputObject $suggestedDiff -Name "diff"
                $publicDiffText = Convert-SuggestedDiffTextToPublicChangeOnlyDiff -Diff ([string]$diffText)
                if ([string]::IsNullOrWhiteSpace($publicDiffText)) {
                    continue
                }

                $Lines.Add("Suggested change:") | Out-Null
                $Lines.Add('```diff') | Out-Null
                foreach ($diffLine in ($publicDiffText -split "`n")) {
                    $Lines.Add($diffLine) | Out-Null
                }
                $Lines.Add('```') | Out-Null
            }
        }
    }
}

function Format-UnresolvedThreadsAsText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    $lines = New-Object System.Collections.Generic.List[string]

    foreach ($record in $Records) {
        $lineStartText = if ($null -eq $record.lineStart) { "?" } else { [string]$record.lineStart }
        $lineEndText = if ($null -eq $record.lineEnd) { "?" } else { [string]$record.lineEnd }

        # Emit a single leading delimiter for the first block; every block then ends
        # with one delimiter. This yields exactly one "---" between adjacent blocks
        # instead of the legacy doubled "---\n---" seam.
        if ($lines.Count -eq 0) {
            $lines.Add("---")
        }

        $lines.Add(("({0}) {1}-{2}" -f $record.path, $lineStartText, $lineEndText))
        $commentRecordsValue = Get-ObjectPropertyValue -InputObject $record -Name "comments"
        $commentRecords = if ($null -eq $commentRecordsValue) { @() } else { @($commentRecordsValue) }
        if ((Get-SafeCount -InputObject $commentRecords) -gt 0) {
            Add-ThreadCommentRenderLines -Lines $lines -Comments $commentRecords
        }
        else {
            $topLevelRecommendation = $null
            foreach ($recommendation in @(Get-ObjectPropertyValue -InputObject $record -Name "recommendations")) {
                if ($null -eq $recommendation) {
                    continue
                }

                $recommendationKind = Get-ObjectPropertyValue -InputObject $recommendation -Name "kind"
                $recommendationCommentIndex = Get-ObjectPropertyValue -InputObject $recommendation -Name "commentIndex"
                if ([string]$recommendationKind -eq "comment" -and [string]$recommendationCommentIndex -eq "0") {
                    $topLevelRecommendation = $recommendation
                    break
                }
            }

            if ($null -ne $topLevelRecommendation) {
                Add-CommentRecommendationRenderLines -Lines $lines -Recommendation $topLevelRecommendation
            }
            else {
                $lines.Add($record.topLevelComment)
            }
        }
        if ((Get-SafeCount -InputObject $commentRecords) -eq 0) {
            Add-SuggestionRenderLines -Lines $lines -Suggestions (Get-ObjectPropertyValue -InputObject $record -Name "suggestions")
        }
        $lines.Add("---")
    }

    if ($lines.Count -eq 0) {
        return "No unresolved review threads found."
    }

    return ($lines -join [Environment]::NewLine)
}

function Convert-SuggestedChangeForPublicOutput {
    [OutputType([object])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $SuggestedChange,

        [Parameter(Mandatory = $true)]
        [ValidateSet("suggestion", "changedLines")]
        [string]$DefaultKind
    )

    if ($null -eq $SuggestedChange) {
        return $null
    }

    $kind = Get-FirstNonEmptyStringValue -Value (Get-ObjectPropertyValue -InputObject $SuggestedChange -Name "kind")
    if ([string]::IsNullOrWhiteSpace($kind)) {
        $kind = $DefaultKind
    }

    $value = $null
    $valueIsChangedLines = $false
    $code = Get-ObjectPropertyValue -InputObject $SuggestedChange -Name "code"
    if ($null -ne $code) {
        $value = [string]$code
    }
    else {
        $diff = Get-ObjectPropertyValue -InputObject $SuggestedChange -Name "diff"
        if ($null -ne $diff) {
            $value = Convert-SuggestedDiffTextToPublicChangeOnlyDiff -Diff ([string]$diff)
            $valueIsChangedLines = $true
        }
    }

    if ($null -eq $value) {
        return $null
    }

    if ($valueIsChangedLines) {
        $kind = "changedLines"
    }

    return [pscustomobject]@{
        kind  = [string]$kind
        value = [string]$value
    }
}

function Convert-ThreadCommentForPublicOutput {
    [OutputType([object])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Comment
    )

    if ($null -eq $Comment) {
        return $null
    }

    $body = Get-ObjectPropertyValue -InputObject $Comment -Name "body"
    $suggestion = if ($null -eq $body) { $null } else { [string]$body }
    if ($suggestion -eq "(none)") {
        $suggestion = $null
    }
    $suggestedChangeRecords = New-Object System.Collections.Generic.List[object]

    foreach ($suggestedChange in @(Get-ObjectPropertyValue -InputObject $Comment -Name "suggestedChanges")) {
        if ($null -eq $suggestedChange) {
            continue
        }

        $record = Convert-SuggestedChangeForPublicOutput -SuggestedChange $suggestedChange -DefaultKind "suggestion"
        if ($null -ne $record) {
            $suggestedChangeRecords.Add($record) | Out-Null
        }
    }

    foreach ($suggestedDiff in @(Get-ObjectPropertyValue -InputObject $Comment -Name "suggestedDiffs")) {
        if ($null -eq $suggestedDiff) {
            continue
        }

        $record = Convert-SuggestedChangeForPublicOutput -SuggestedChange $suggestedDiff -DefaultKind "changedLines"
        if ($null -ne $record) {
            $suggestedChangeRecords.Add($record) | Out-Null
        }
    }

    if ([string]::IsNullOrWhiteSpace($suggestion) -and $suggestedChangeRecords.Count -eq 0) {
        return $null
    }

    return [pscustomobject]@{
        suggestion       = if ([string]::IsNullOrWhiteSpace($suggestion)) { $null } else { $suggestion }
        suggestedChanges = @($suggestedChangeRecords.ToArray())
    }
}

function Convert-ThreadRecordForPublicOutput {
    [OutputType([object])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Record
    )

    $commentRecords = New-Object System.Collections.Generic.List[object]
    $comments = Get-ObjectPropertyValue -InputObject $Record -Name "comments"
    foreach ($comment in @($comments)) {
        $publicComment = Convert-ThreadCommentForPublicOutput -Comment $comment
        if ($null -ne $publicComment) {
            $commentRecords.Add($publicComment) | Out-Null
        }
    }

    if ($commentRecords.Count -eq 0) {
        $fallbackComment = [pscustomobject]@{
            body             = (Get-ObjectPropertyValue -InputObject $Record -Name "topLevelComment")
            suggestedChanges = @(Get-ObjectPropertyValue -InputObject $Record -Name "suggestions")
            suggestedDiffs   = @()
        }
        $publicComment = Convert-ThreadCommentForPublicOutput -Comment $fallbackComment
        if ($null -ne $publicComment) {
            $commentRecords.Add($publicComment) | Out-Null
        }
    }

    return [pscustomobject]@{
        path      = Get-ObjectPropertyValue -InputObject $Record -Name "path"
        lineStart = Get-ObjectPropertyValue -InputObject $Record -Name "lineStart"
        lineEnd   = Get-ObjectPropertyValue -InputObject $Record -Name "lineEnd"
        comments  = @($commentRecords.ToArray())
    }
}

function Format-UnresolvedThreadsAsJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    $outputRecords = @(
        foreach ($record in $Records) {
            Convert-ThreadRecordForPublicOutput -Record $record
        }
    )

    return (ConvertTo-JsonArrayCompat -InputObject $outputRecords -Depth 8)
}

function Assert-GraphQLVariableMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [hashtable]$Variables,

        [Parameter(Mandatory = $false)]
        [string]$Context = "GraphQL request",

        [Parameter(Mandatory = $false)]
        [switch]$RejectUnexpectedVariables
    )

    $declarationMatches = [regex]::Matches($Query, '\$(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*:')
    $expectedVariableNames = New-Object System.Collections.Generic.List[string]
    $seenExpectedVariableNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)

    foreach ($declarationMatch in $declarationMatches) {
        $variableName = [string]$declarationMatch.Groups["name"].Value
        if ([string]::IsNullOrWhiteSpace($variableName)) {
            continue
        }

        if ($seenExpectedVariableNames.Add($variableName)) {
            $expectedVariableNames.Add($variableName) | Out-Null
        }
    }

    if ($expectedVariableNames.Count -eq 0) {
        throw "E_CONFIG_ERROR: $Context query does not declare any GraphQL variables."
    }

    $actualVariableNames = New-Object System.Collections.Generic.List[string]
    foreach ($variableKey in $Variables.Keys) {
        if ($null -eq $variableKey) {
            continue
        }

        $actualVariableNames.Add([string]$variableKey) | Out-Null
    }

    $missingVariables = New-Object System.Collections.Generic.List[string]
    $caseMismatchedVariables = New-Object System.Collections.Generic.List[string]
    $unexpectedVariables = New-Object System.Collections.Generic.List[string]

    foreach ($expectedVariableName in $expectedVariableNames) {
        if ($actualVariableNames -ccontains $expectedVariableName) {
            continue
        }

        $caseInsensitiveMatches = @($actualVariableNames | Where-Object { $_ -ieq $expectedVariableName })
        if ($caseInsensitiveMatches.Count -gt 0) {
            $caseMismatchedVariables.Add(("{0} (provided: {1})" -f $expectedVariableName, ($caseInsensitiveMatches -join ", "))) | Out-Null
            continue
        }

        $missingVariables.Add($expectedVariableName) | Out-Null
    }

    if ($RejectUnexpectedVariables.IsPresent) {
        foreach ($actualVariableName in $actualVariableNames) {
            if ($expectedVariableNames -ccontains $actualVariableName) {
                continue
            }

            $caseInsensitiveExpectedMatches = @($expectedVariableNames | Where-Object { $_ -ieq $actualVariableName })
            if ($caseInsensitiveExpectedMatches.Count -gt 0) {
                continue
            }

            $unexpectedVariables.Add($actualVariableName) | Out-Null
        }
    }

    if ($missingVariables.Count -eq 0 -and $caseMismatchedVariables.Count -eq 0 -and $unexpectedVariables.Count -eq 0) {
        return
    }

    $issues = New-Object System.Collections.Generic.List[string]
    if ($missingVariables.Count -gt 0) {
        $issues.Add(("missing variables: {0}" -f ($missingVariables -join ", "))) | Out-Null
    }

    if ($caseMismatchedVariables.Count -gt 0) {
        $issues.Add(("case mismatch: {0}" -f ($caseMismatchedVariables -join "; "))) | Out-Null
    }

    if ($unexpectedVariables.Count -gt 0) {
        $issues.Add(("unexpected variables: {0}" -f ($unexpectedVariables -join ", "))) | Out-Null
    }

    throw ("E_CONFIG_ERROR: {0} GraphQL variables are invalid ({1})." -f $Context, ($issues -join "; "))
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
        [switch]$KeepMarkup,

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
          isOutdated
          path
          startLine
          line
          originalStartLine
          originalLine
          comments(first: 100) {
            nodes {
              databaseId
              fullDatabaseId
              body
              createdAt
              url
              diffHunk
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
            owner    = $Owner
            repo     = $Repo
            prNumber = $PrNumber
            first    = $PerPage
            after    = $cursor
        }

        Assert-GraphQLVariableMap -Query $query -Variables $variables -Context "Get-UnresolvedReviewThreads" -RejectUnexpectedVariables

        $body = @{
            query     = $query
            variables = $variables
        }

        $response = Invoke-GitHubRequestWithRetry -Method POST -Uri $Endpoint -Headers $Headers -Body $body -RequestTimeoutSeconds $RequestTimeoutSeconds -MaxRetries 3 -OverallDeadlineUtc $OverallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -AllowedGitHubHostsNormalized $AllowedGitHubHostsNormalized -SensitiveTokens $SensitiveTokens

        $errors = $null
        if ($response -is [System.Collections.IDictionary]) {
            if ($response.Contains("errors")) {
                $errors = $response["errors"]
            }
        }
        elseif ($response.PSObject.Properties.Name -contains "errors") {
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
                }
                elseif ($firstError.PSObject.Properties.Name -contains "message") {
                    $messageValue = Get-FirstNonEmptyStringValue -Value $firstError.Message
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
            $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner $Owner -Repo $Repo -PrNumber $PrNumber -GitHubHost $GitHubHost -Truncate:$Truncate -KeepMarkup:$KeepMarkup
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
        }
        else {
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

function Get-PublicPullRequestReviewCommentsFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [int]$PrNumber,

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
        [switch]$KeepMarkup,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedGitHubHostsNormalized = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$SensitiveTokens = @()
    )

    $headers = Get-GitHubHeaders -AuthToken $null
    Assert-IsHashtableLike -Value $headers -Name "Headers"
    $base = Resolve-GitHubRestApiBaseUri -GitHubHost $GitHubHost
    $allComments = New-Object System.Collections.Generic.List[object]

    for ($page = 1; $page -le $MaxPages; $page++) {
        $uri = "$base/repos/$Owner/$Repo/pulls/$PrNumber/comments?per_page=$PerPage&page=$page&sort=created&direction=asc"
        $response = Invoke-GitHubRequestWithRetry -Method GET -Uri $uri -Headers $headers -Body $null -RequestTimeoutSeconds $RequestTimeoutSeconds -MaxRetries 3 -OverallDeadlineUtc $OverallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -AllowedGitHubHostsNormalized $AllowedGitHubHostsNormalized -SensitiveTokens $SensitiveTokens

        if ($null -eq $response) {
            break
        }

        $comments = @($response)
        if ((Get-SafeCount -InputObject $comments) -eq 0) {
            break
        }

        foreach ($comment in $comments) {
            $allComments.Add($comment) | Out-Null
        }

        if ((Get-SafeCount -InputObject $comments) -lt $PerPage) {
            break
        }
    }

    $threads = @(Convert-RestReviewCommentsToThreadLikeObjects -Comments $allComments.ToArray())
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($thread in $threads) {
        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner $Owner -Repo $Repo -PrNumber $PrNumber -GitHubHost $GitHubHost -Truncate:$Truncate -KeepMarkup:$KeepMarkup
        if ($null -ne $record) {
            $records.Add($record) | Out-Null
        }
    }

    Write-Warning "W_PUBLIC_REST_FALLBACK_RESOLUTION_UNKNOWN: Public REST fallback cannot determine review-thread resolution state; returned records use resolutionState='unknown'."
    return $records.ToArray()
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

function Test-RecoverableGitHubAuthFailureMessage {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )

    return $Message -like "E_AUTH_INVALID*" -or
    $Message -like "E_FORBIDDEN*" -or
    $Message -like "E_AUTH_INSUFFICIENT_SCOPE*" -or
    $Message -like "E_AUTH_RATE_LIMITED*" -or
    $Message -like "E_RATE_LIMIT_403*"
}

function Test-GitHubFallbackFailureMayRequireAuth {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )

    return (Test-RecoverableGitHubAuthFailureMessage -Message $Message) -or
    $Message -like "E_NOT_FOUND*"
}

function Get-ConsoleOutputEncoding {
    # Mockable seam over the [System.Console]::OutputEncoding getter. Reading the current console
    # encoding is cheap and side-effect-free (unlike the setter), so it is safe to probe first.
    [OutputType([System.Text.Encoding])]
    [CmdletBinding()]
    param()

    return [System.Console]::OutputEncoding
}

function Set-ConsoleOutputEncoding {
    # Mockable seam over the [System.Console]::OutputEncoding setter. On Windows this triggers
    # SetConsoleOutputCP (a console code-page switch) which is comparatively slow and can flicker,
    # so callers must only invoke it when the encoding actually needs to change.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.Encoding]$Encoding
    )

    [System.Console]::OutputEncoding = $Encoding
}

function Initialize-Utf8ConsoleOutputEncoding {
    # Ensures terminal-rendered output is UTF-8 so on-screen comment text stays verbatim,
    # WITHOUT paying the per-invocation cost of an unconditional console code-page switch.
    #
    # Setting [System.Console]::OutputEncoding triggers SetConsoleOutputCP on Windows, which is a
    # comparatively slow, sometimes visibly flickery operation and was observed to add noticeable
    # latency to every run. Modern terminals (Windows Terminal, VS Code, macOS, Linux) are already
    # UTF-8, so we read the current encoding first (cheap, side-effect-free) and only change it
    # when it is not already UTF-8 (code page 65001). Both the probe and the set are best-effort:
    # they throw when no console is attached (for example when all standard streams are redirected).
    try {
        $current = Get-ConsoleOutputEncoding
        if ($null -ne $current -and $current.CodePage -eq 65001) {
            return
        }
    }
    catch {
        Write-Verbose "W_CONSOLE_ENCODING_UNAVAILABLE: Unable to read console output encoding: $($_.Exception.Message)"
        return
    }

    try {
        Set-ConsoleOutputEncoding -Encoding (New-Object System.Text.UTF8Encoding($false))
    }
    catch {
        Write-Verbose "W_CONSOLE_ENCODING_UNAVAILABLE: Unable to set console output encoding to UTF-8: $($_.Exception.Message)"
    }
}

function Invoke-ConsoleFlush {
    # Mockable seam that commits all buffered console output to the OS before a fast process exit.
    # Isolated so Invoke-FastProcessExit can be unit-tested without actually flushing/terminating.
    [CmdletBinding()]
    param()

    [System.Console]::Out.Flush()
    [System.Console]::Error.Flush()
}

function Stop-CurrentProcessImmediately {
    # Terminates the current process with $ExitCode, skipping the slow .NET/PowerShell managed
    # shutdown (finalizers, HTTP connection-pool teardown) that dominates wall time on slow
    # container filesystems. On Unix this calls libc `_exit`, which terminates immediately without
    # running finalizers and without raising a SIGKILL "Killed" message (it is a normal exit, so the
    # requested exit code is preserved). On Windows (and if the native call is unavailable) it falls
    # back to [System.Environment]::Exit. Callers MUST flush output first (see Invoke-FastProcessExit)
    # because this bypasses the managed flush. This is a mockable seam: tests stub it so they never
    # actually terminate the test runner.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    if (-not (Test-IsWindowsPlatform)) {
        try {
            if ($null -eq ('WallstopNativeExit.Libc' -as [type])) {
                Add-Type -Namespace WallstopNativeExit -Name Libc -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("libc", EntryPoint = "_exit")]
public static extern void _exit(int code);
'@
            }

            [WallstopNativeExit.Libc]::_exit($ExitCode)
        }
        catch {
            # The native fast exit is unavailable on this host (for example a libc/_exit resolution
            # failure). Surface it so the degradation to the slower managed exit is visible rather
            # than silent, then fall through to the portable terminator below.
            Write-Warning "W_FAST_EXIT_NATIVE_UNAVAILABLE: Fast native exit (libc _exit) is unavailable on this host; using the slower managed exit instead. $($_.Exception.Message)"
        }
    }

    # Windows path and Unix fallback: the documented cross-platform terminator. Slower than libc
    # _exit on a loaded Linux container, but always correct.
    [System.Environment]::Exit($ExitCode)
}

function Invoke-FastProcessExit {
    # Flushes buffered output and then terminates the process immediately, skipping the slow managed
    # teardown. This is the default behavior; the script's -NoFastExit switch opts out. The output
    # and any -OutputPath file writes are already committed before this runs (rendering completes
    # synchronously and the flush below commits console buffers), so the only thing skipped is
    # dead-weight runtime shutdown.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$ExitCode = 0
    )

    try {
        Invoke-ConsoleFlush
    }
    catch {
        # A missing/redirected console must not prevent termination; bytes already written to a
        # redirected stream are committed by the OS regardless.
    }

    Stop-CurrentProcessImmediately -ExitCode $ExitCode
}

function Invoke-Main {
    [CmdletBinding()]
    param()

    # Render terminal output as UTF-8 so copied (terminal-screen selection) comment text stays
    # verbatim, independent of the host's default code page. This is intentionally a no-op when
    # the console is already UTF-8 so it never adds per-invocation terminal latency. ($OutputEncoding,
    # which governs only native-program pipes, is set locally in Copy-ToClipboard where the native
    # clipboard pipes actually run.)
    Initialize-Utf8ConsoleOutputEncoding

    # Establish one reusable connection for every GitHub API call in this run (token validation +
    # paginated GraphQL/REST) so they share a single pooled TCP/TLS connection instead of opening a
    # fresh connection per request. Set before the first network call (interactive listing included).
    $script:GitHubWebSession = New-GitHubWebSession

    $overallDeadlineUtc = [datetime]::UtcNow.AddSeconds($OverallTimeoutSeconds)
    if ($CopyStrict.IsPresent -and -not $Copy.IsPresent) {
        throw "E_CONFIG_ERROR: -CopyStrict requires -Copy."
    }

    $initialSensitive = @()
    $records = @()
    $isGitHubHostExplicitlyProvided = $script:TopLevelBoundParameters.ContainsKey("GitHubHost")
    $allowedGitHubHostsNormalized = Get-NormalizedGitHubHostAllowlist -AllowedGitHubHosts $AllowedGitHubHosts

    # First pass target resolution may require anonymous headers for interactive listing.
    $tempHeaders = Get-GitHubHeaders -AuthToken $null
    Assert-IsHashtableLike -Value $tempHeaders -Name "Headers"

    $target = Resolve-PullRequestTarget -PullRequestUrl $PullRequestUrl -Owner $Owner -Repo $Repo -GitHubHost $GitHubHost -GitHubHostProvided:$isGitHubHostExplicitlyProvided -PullRequestNumber $PullRequestNumber -Interactive:$Interactive -Headers $tempHeaders -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $overallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $initialSensitive
    if ($null -eq $target) {
        return
    }

    $rejectedTokenValues = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    $explicitTokenProvided = -not [string]::IsNullOrWhiteSpace($Token)

    $authResolution = Convert-ToAuthTokenResolutionResult -AuthTokenValue (Get-AuthToken -ExplicitToken $Token -GitHubHost $target.Host -AllowInteractive:$false -IncludeSourceMetadata) -FallbackSource "unknown"
    $authToken = $authResolution.Token
    $authTokenSourceCategory = $authResolution.SourceCategory
    $authTokenEnvironmentVariable = $authResolution.EnvironmentVariable
    if ($null -ne $authToken) {
        $authToken = [string]$authToken
    }

    $githubWebCookieValue = Get-GitHubWebCookie -ExplicitCookie $GitHubWebCookie

    $sensitiveTokens = @()
    if (-not [string]::IsNullOrWhiteSpace($authToken)) {
        $sensitiveTokens += [string]$authToken
    }
    if (-not [string]::IsNullOrWhiteSpace($githubWebCookieValue)) {
        $sensitiveTokens += [string]$githubWebCookieValue
    }

    $headers = Get-GitHubHeaders -AuthToken $authToken
    Assert-IsHashtableLike -Value $headers -Name "Headers"

    # Recovery prompts are intentionally limited to URL and interactive workflows.
    # Direct owner/repo mode remains non-prompting but may still use non-interactive
    # stored credentials and public REST fallback unless an explicit token failed.
    $allowPromptedLoginFallback = $Interactive.IsPresent -or -not [string]::IsNullOrWhiteSpace($PullRequestUrl)
    $allowStoredCredentialRetry = $allowPromptedLoginFallback -or (-not $explicitTokenProvided)

    $endpoint = Resolve-GitHubGraphQLEndpoint -GitHubHost $target.Host
    $retrievedRecords = $false
    $message = $null
    $isAuthRecoverableFailure = $false
    $isAuthRateLimitFailure = $false
    $lastFailureMayRequireAuth = $false
    $publicRestFallbackAttempted = $false

    try {
        if ([string]::IsNullOrWhiteSpace($authToken)) {
            $publicRestFallbackAttempted = $true
            $records = @(Get-PublicPullRequestReviewCommentsFallback -Owner $target.Owner -Repo $target.Repo -PrNumber $target.PullRequestNumber -GitHubHost $target.Host -PerPage $PerPage -MaxPages $MaxPages -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $overallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -Truncate:$Truncate -KeepMarkup:$KeepMarkup -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens)
        }
        else {
            Validate-GitHubTokenForRepoAccess -Owner $target.Owner -Repo $target.Repo -GitHubHost $target.Host -Headers $headers -OverallDeadlineUtc $overallDeadlineUtc -RequestTimeoutSeconds $RequestTimeoutSeconds -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens
            $records = @(Get-UnresolvedReviewThreads -Owner $target.Owner -Repo $target.Repo -PrNumber $target.PullRequestNumber -Endpoint $endpoint -Headers $headers -GitHubHost $target.Host -PerPage $PerPage -MaxPages $MaxPages -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $overallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -Truncate:$Truncate -KeepMarkup:$KeepMarkup -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens)
        }

        $retrievedRecords = $true
    }
    catch {
        $message = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $sensitiveTokens
        $isAuthRateLimitFailure = $message -like "E_AUTH_RATE_LIMITED*" -or $message -like "E_RATE_LIMIT_403*"
        $isAuthRecoverableFailure = Test-RecoverableGitHubAuthFailureMessage -Message $message
        $lastFailureMayRequireAuth = Test-GitHubFallbackFailureMayRequireAuth -Message $message

        if ($isAuthRecoverableFailure -and -not [string]::IsNullOrWhiteSpace($authToken)) {
            $rejectedTokenValues.Add($authToken) | Out-Null
        }
    }

    if (-not $retrievedRecords -and $allowStoredCredentialRetry -and $isAuthRecoverableFailure -and -not [string]::IsNullOrWhiteSpace($authToken)) {
        $rejectedTokenValuesArray = @($rejectedTokenValues)
        $storedAuthResolution = Convert-ToAuthTokenResolutionResult -AuthTokenValue (Get-AuthToken -ExplicitToken $null -GitHubHost $target.Host -AllowInteractive:$false -IncludeSourceMetadata -IgnoreEnvironmentTokens -RejectedTokenValues $rejectedTokenValuesArray) -FallbackSource "unknown"
        $storedAuthToken = $storedAuthResolution.Token
        if ($null -ne $storedAuthToken) {
            $storedAuthToken = [string]$storedAuthToken
        }

        if (-not [string]::IsNullOrWhiteSpace($storedAuthToken)) {
            Write-Verbose "Recoverable authentication failure detected. Retrying with stored GitHub credentials before public REST fallback."
            $authToken = $storedAuthToken
            $authTokenSourceCategory = $storedAuthResolution.SourceCategory
            $authTokenEnvironmentVariable = $storedAuthResolution.EnvironmentVariable
            $sensitiveTokens = @($authToken)
            if (-not [string]::IsNullOrWhiteSpace($githubWebCookieValue)) {
                $sensitiveTokens += [string]$githubWebCookieValue
            }
            $headers = Get-GitHubHeaders -AuthToken $authToken
            Assert-IsHashtableLike -Value $headers -Name "Headers"

            try {
                Validate-GitHubTokenForRepoAccess -Owner $target.Owner -Repo $target.Repo -GitHubHost $target.Host -Headers $headers -OverallDeadlineUtc $overallDeadlineUtc -RequestTimeoutSeconds $RequestTimeoutSeconds -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens
                $records = @(Get-UnresolvedReviewThreads -Owner $target.Owner -Repo $target.Repo -PrNumber $target.PullRequestNumber -Endpoint $endpoint -Headers $headers -GitHubHost $target.Host -PerPage $PerPage -MaxPages $MaxPages -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $overallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -Truncate:$Truncate -KeepMarkup:$KeepMarkup -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens)
                $retrievedRecords = $true
            }
            catch {
                $message = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $sensitiveTokens
                $isAuthRateLimitFailure = $message -like "E_AUTH_RATE_LIMITED*" -or $message -like "E_RATE_LIMIT_403*"
                $isAuthRecoverableFailure = Test-RecoverableGitHubAuthFailureMessage -Message $message
                $lastFailureMayRequireAuth = Test-GitHubFallbackFailureMayRequireAuth -Message $message

                if ($isAuthRecoverableFailure -and -not [string]::IsNullOrWhiteSpace($authToken)) {
                    $rejectedTokenValues.Add($authToken) | Out-Null
                }
            }
        }
    }

    $isDirectModeExplicitTokenFailure = (-not $allowPromptedLoginFallback) -and $explicitTokenProvided -and $isAuthRecoverableFailure

    if (-not $retrievedRecords -and -not $publicRestFallbackAttempted -and -not $isDirectModeExplicitTokenFailure -and ([string]::IsNullOrWhiteSpace($authToken) -or $isAuthRecoverableFailure)) {
        $publicRestFallbackAttempted = $true
        $restSensitiveTokens = @($sensitiveTokens) + @($rejectedTokenValues)
        try {
            $records = @(Get-PublicPullRequestReviewCommentsFallback -Owner $target.Owner -Repo $target.Repo -PrNumber $target.PullRequestNumber -GitHubHost $target.Host -PerPage $PerPage -MaxPages $MaxPages -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $overallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -Truncate:$Truncate -KeepMarkup:$KeepMarkup -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $restSensitiveTokens)
            $authToken = $null
            $authTokenSourceCategory = "none"
            $authTokenEnvironmentVariable = $null
            $sensitiveTokens = @()
            if (-not [string]::IsNullOrWhiteSpace($githubWebCookieValue)) {
                $sensitiveTokens += [string]$githubWebCookieValue
            }
            $retrievedRecords = $true
        }
        catch {
            $message = Redact-SensitiveText -Text $_.Exception.Message -SensitiveTokens $restSensitiveTokens
            $isAuthRateLimitFailure = $message -like "E_AUTH_RATE_LIMITED*" -or $message -like "E_RATE_LIMIT_403*"
            $isAuthRecoverableFailure = Test-RecoverableGitHubAuthFailureMessage -Message $message
            $lastFailureMayRequireAuth = Test-GitHubFallbackFailureMayRequireAuth -Message $message
        }
    }

    if (-not $retrievedRecords -and $allowPromptedLoginFallback -and $lastFailureMayRequireAuth -and -not (Test-CanPromptForLogin)) {
        throw "E_AUTH_REQUIRED: Authentication is missing or invalid, and public REST fallback could not read the PR. Interactive login prompt is unavailable because input/output is redirected. Provide -Token or set GH_TOKEN/GITHUB_TOKEN."
    }

    if (-not $retrievedRecords -and $allowPromptedLoginFallback -and $lastFailureMayRequireAuth) {
        $choice = Read-Host "Authentication is missing or invalid. Log in using GitHub CLI now? [y/N]"
        if ($choice -match "^(y|yes)$") {
            $rejectedTokenValuesArray = @($rejectedTokenValues)
            $promptedAuthResolution = Convert-ToAuthTokenResolutionResult -AuthTokenValue (Get-AuthToken -ExplicitToken $null -GitHubHost $target.Host -AllowInteractive -IncludeSourceMetadata -IgnoreEnvironmentTokens -RejectedTokenValues $rejectedTokenValuesArray) -FallbackSource "unknown"
            $authToken = $promptedAuthResolution.Token
            $authTokenSourceCategory = $promptedAuthResolution.SourceCategory
            $authTokenEnvironmentVariable = $promptedAuthResolution.EnvironmentVariable
            if ($null -ne $authToken) {
                $authToken = [string]$authToken
            }

            if ([string]::IsNullOrWhiteSpace($authToken)) {
                throw "E_AUTH_REQUIRED: Login completed but no token is available."
            }

            $sensitiveTokens = @($authToken)
            if (-not [string]::IsNullOrWhiteSpace($githubWebCookieValue)) {
                $sensitiveTokens += [string]$githubWebCookieValue
            }
            $headers = Get-GitHubHeaders -AuthToken $authToken
            Assert-IsHashtableLike -Value $headers -Name "Headers"

            Validate-GitHubTokenForRepoAccess -Owner $target.Owner -Repo $target.Repo -GitHubHost $target.Host -Headers $headers -OverallDeadlineUtc $overallDeadlineUtc -RequestTimeoutSeconds $RequestTimeoutSeconds -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens
            $records = @(Get-UnresolvedReviewThreads -Owner $target.Owner -Repo $target.Repo -PrNumber $target.PullRequestNumber -Endpoint $endpoint -Headers $headers -GitHubHost $target.Host -PerPage $PerPage -MaxPages $MaxPages -RequestTimeoutSeconds $RequestTimeoutSeconds -OverallDeadlineUtc $overallDeadlineUtc -WaitOnRateLimit:$WaitOnRateLimit -Truncate:$Truncate -KeepMarkup:$KeepMarkup -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens)
            $retrievedRecords = $true
        }
        else {
            throw $message
        }
    }

    if (-not $retrievedRecords) {
        $isDirectModeEnvironmentTokenFailure = (-not $allowPromptedLoginFallback) -and $isAuthRecoverableFailure -and -not $isAuthRateLimitFailure -and ($authTokenSourceCategory -eq "environment" -or -not [string]::IsNullOrWhiteSpace($authTokenEnvironmentVariable))
        if ($isDirectModeEnvironmentTokenFailure -and $message -notlike "*GH_TOKEN takes precedence over GITHUB_TOKEN*") {
            $message = "$message Refresh or unset GH_TOKEN (GH_TOKEN takes precedence over GITHUB_TOKEN), or set GITHUB_TOKEN, then retry; you can also pass -Token explicitly."
        }

        throw $message
    }

    if ((Get-SafeCount -InputObject $records) -gt 0) {
        $webSuggestedDiffsByCommentId = Get-GitHubWebAutomatedSuggestedDiffsByCommentId -Owner $target.Owner -Repo $target.Repo -PrNumber $target.PullRequestNumber -GitHubHost $target.Host -RequestTimeoutSeconds $RequestTimeoutSeconds -GitHubWebCookie $githubWebCookieValue -OverallDeadlineUtc $overallDeadlineUtc -AllowedGitHubHostsNormalized $allowedGitHubHostsNormalized -SensitiveTokens $sensitiveTokens
        Add-GitHubWebAutomatedSuggestedDiffsToRecords -Records $records -SuggestedDiffsByCommentId $webSuggestedDiffsByCommentId
    }

    $output = $null
    if ($OutputFormat -eq "json") {
        $output = Format-UnresolvedThreadsAsJson -Records $records
    }
    else {
        $output = Format-UnresolvedThreadsAsText -Records $records
    }

    if ($Copy.IsPresent) {
        $copied = Copy-ToClipboard -Text $output -SensitiveTokens $sensitiveTokens
        if (-not $copied -and $CopyStrict.IsPresent) {
            throw "E_CLIPBOARD_COPY_FAILED: Clipboard copy failed and -CopyStrict was specified."
        }
    }

    if ($script:TopLevelBoundParameters.ContainsKey("OutputPath")) {
        [void](Write-RenderedOutputToFile -Text $output -OutputPath $OutputPath -SensitiveTokens $sensitiveTokens)
    }

    Write-Output $output
}

# Allow tests to dot-source without executing main flow.
if (-not $NoRun.IsPresent -and $MyInvocation.InvocationName -ne ".") {
    try {
        Invoke-Main
        # By default the process terminates immediately after a successful run, skipping the slow
        # .NET/PowerShell managed teardown (finalizers + HTTP connection-pool shutdown) that
        # dominates wall time on slow container filesystems. Output is already rendered and flushed
        # before this point. -NoFastExit opts out and restores the standard managed teardown.
        if (-not $NoFastExit.IsPresent) {
            Invoke-FastProcessExit -ExitCode 0
        }
    }
    catch {
        if ($null -ne $_) {
            Microsoft.PowerShell.Utility\Write-Error -ErrorRecord $_
        }
        else {
            Microsoft.PowerShell.Utility\Write-Error "E_UNEXPECTED: Script failed with an unknown error."
        }
        if (-not $NoFastExit.IsPresent) {
            Invoke-FastProcessExit -ExitCode 1
        }
        exit 1
    }
}
