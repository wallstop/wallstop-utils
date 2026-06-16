Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    . "$PSScriptRoot/../../Scripts/Utils/Common/CompatibilityHelpers.ps1"
    . "$PSScriptRoot/../../Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1" -NoRun
}

Describe "Parse-GitHubPullRequestUrl" {
    It "parses github.com pull request URLs" {
        $result = Parse-GitHubPullRequestUrl -Url "https://github.com/octo-org/octo-repo/pull/123"

        $result.Host | Should -Be "github.com"
        $result.Owner | Should -Be "octo-org"
        $result.Repo | Should -Be "octo-repo"
        $result.PullRequestNumber | Should -Be 123
    }

    It "parses GitHub Enterprise URLs" {
        $result = Parse-GitHubPullRequestUrl -Url "https://github.enterprise.local/platform/api-repo/pull/42/files"

        $result.Host | Should -Be "github.enterprise.local"
        $result.Owner | Should -Be "platform"
        $result.Repo | Should -Be "api-repo"
        $result.PullRequestNumber | Should -Be 42
    }

    It "fails on invalid URLs" {
        { Parse-GitHubPullRequestUrl -Url "https://github.com/octo/repo/issues/10" } | Should -Throw "*E_INVALID_URL*"
    }

    It "rejects localhost and private-network hosts" {
        { Parse-GitHubPullRequestUrl -Url "https://localhost/octo/repo/pull/10" } | Should -Throw "*E_INVALID_URL*"
    }

    It "rejects PullRequestUrl hosts in RFC1918 ranges" {
        { Parse-GitHubPullRequestUrl -Url "https://192.168.1.10/octo/repo/pull/10" } | Should -Throw "*E_INVALID_URL*not allowed for safety reasons*"
    }

    It "accepts owner values up to 39 characters" {
        $owner39 = "o" + ("a" * 38)
        $result = Parse-GitHubPullRequestUrl -Url "https://github.com/$owner39/octo-repo/pull/123"

        $result.Owner | Should -Be $owner39
    }

    It "rejects owner values longer than 39 characters" {
        $owner40 = "o" + ("a" * 39)
        { Parse-GitHubPullRequestUrl -Url "https://github.com/$owner40/octo-repo/pull/123" } | Should -Throw "*E_INVALID_OWNER_REPO*"
    }

    It "rejects malformed host labels" {
        { Parse-GitHubPullRequestUrl -Url "https://.github.com/octo/repo/pull/10" } | Should -Throw "*E_INVALID_URL*"
        { Parse-GitHubPullRequestUrl -Url "https://github.com./octo/repo/pull/10" } | Should -Throw "*E_INVALID_URL*"
        { Parse-GitHubPullRequestUrl -Url "https://-github.com/octo/repo/pull/10" } | Should -Throw "*E_INVALID_URL*"
        { Parse-GitHubPullRequestUrl -Url "https://github-.com/octo/repo/pull/10" } | Should -Throw "*E_INVALID_URL*"
    }

    It "rejects URL host segments that include a port" {
        { Parse-GitHubPullRequestUrl -Url "https://github.com:8443/octo/repo/pull/10" } | Should -Throw "*E_INVALID_URL*"
    }

    It "rejects URL host segments that include user-info" {
        { Parse-GitHubPullRequestUrl -Url "https://token@github.com/octo/repo/pull/10" } | Should -Throw "*E_INVALID_URL*"
        { Parse-GitHubPullRequestUrl -Url "https://user:pass@github.com/octo/repo/pull/10" } | Should -Throw "*E_INVALID_URL*"
    }
}

Describe "Test-GitHubHostAllowed" {
    It "accepts github.com" {
        (Test-GitHubHostAllowed -GitHubHost "github.com") | Should -BeTrue
    }

    It "rejects local, private, link-local, and non-global IPv4 ranges" {
        (Test-GitHubHostAllowed -GitHubHost "localhost") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "127.0.0.1") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "0.0.0.0") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "10.1.2.3") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "192.168.1.10") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "172.16.0.1") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "100.64.0.1") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "169.254.169.254") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "224.0.0.1") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "240.0.0.1") | Should -BeFalse
    }

    It "rejects non-global IPv6 ranges" {
        (Test-GitHubHostAllowed -GitHubHost "::1") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "::") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "fe80::1") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "fd12:3456::1") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "ff02::1") | Should -BeFalse
    }

    It "accepts globally routable IPv4 and IPv6 addresses" {
        (Test-GitHubHostAllowed -GitHubHost "8.8.8.8") | Should -BeTrue
        (Test-GitHubHostAllowed -GitHubHost "1.1.1.1") | Should -BeTrue
        (Test-GitHubHostAllowed -GitHubHost "2606:4700:4700::1111") | Should -BeTrue
    }

    It "rejects IPv6-mapped local/private IPv4 addresses" {
        (Test-GitHubHostAllowed -GitHubHost "::ffff:127.0.0.1") | Should -BeFalse
        (Test-GitHubHostAllowed -GitHubHost "::ffff:10.1.2.3") | Should -BeFalse
    }
}

Describe "Get-NormalizedGitHubHostAllowlist" {
    BeforeAll {
        $script:originalWallstopHostAllowlist = $env:WALLSTOP_GITHUB_ALLOWED_HOSTS
        $script:originalGitHubHostAllowlist = $env:GITHUB_ALLOWED_HOSTS
    }

    BeforeEach {
        $env:WALLSTOP_GITHUB_ALLOWED_HOSTS = $null
        $env:GITHUB_ALLOWED_HOSTS = $null
    }

    AfterAll {
        $env:WALLSTOP_GITHUB_ALLOWED_HOSTS = $script:originalWallstopHostAllowlist
        $env:GITHUB_ALLOWED_HOSTS = $script:originalGitHubHostAllowlist
    }

    It "normalizes and de-duplicates explicit allowlist hosts" {
        $normalized = @(Get-NormalizedGitHubHostAllowlist -AllowedGitHubHosts @("GitHub.COM", "github.com", "ghes.example.com"))

        $normalized.Count | Should -Be 2
        $normalized[0] | Should -Be "github.com"
        $normalized[1] | Should -Be "ghes.example.com"
    }

    It "reads allowlist hosts from environment variable fallback" {
        $env:WALLSTOP_GITHUB_ALLOWED_HOSTS = "github.com, ghes.example.com"

        $normalized = @(Get-NormalizedGitHubHostAllowlist)
        $normalized.Count | Should -Be 2
        $normalized | Should -Contain "github.com"
        $normalized | Should -Contain "ghes.example.com"
    }

    It "throws E_CONFIG_ERROR when allowlist entries are malformed" {
        { Get-NormalizedGitHubHostAllowlist -AllowedGitHubHosts @(".github.com") } | Should -Throw "*E_CONFIG_ERROR*"
    }
}

Describe "Assert-GitHubHostFormat" {
    It "normalizes host casing" {
        (Assert-GitHubHostFormat -GitHubHost "GitHub.COM" -Context "unit") | Should -Be "github.com"
    }

    It "rejects empty hosts" {
        { Assert-GitHubHostFormat -GitHubHost " " -Context "unit" } | Should -Throw "*E_INVALID_URL*"
    }

    It "rejects host values longer than DNS limits" {
        $label = "a" * 63
        $hostTooLong = "$label.$label.$label.$label"

        { Assert-GitHubHostFormat -GitHubHost $hostTooLong -Context "unit" } | Should -Throw "*E_INVALID_URL*"
    }
}

Describe "Assert-GitHubHostInAllowlist" {
    It "allows any host when allowlist is empty" {
        { Assert-GitHubHostInAllowlist -GitHubHost "github.com" -AllowedGitHubHosts @() -Context "unit" } | Should -Not -Throw
    }

    It "enforces case-insensitive allowlist matching" {
        { Assert-GitHubHostInAllowlist -GitHubHost "GitHub.COM" -AllowedGitHubHosts @("github.com") -Context "unit" } | Should -Not -Throw
    }

    It "rejects hosts not found in allowlist" {
        { Assert-GitHubHostInAllowlist -GitHubHost "github.com" -AllowedGitHubHosts @("ghes.example.com") -Context "unit" } | Should -Throw "*E_INVALID_URL*"
    }

    It "does not treat github.com as an exact target-host allowlist match for api.github.com" {
        { Assert-GitHubHostInAllowlist -GitHubHost "api.github.com" -AllowedGitHubHosts @("github.com") -Context "unit" } | Should -Throw "*E_INVALID_URL*"
    }
}

Describe "Assert-GitHubRequestUri" {
    It "requires https scheme" {
        { Assert-GitHubRequestUri -Uri "http://api.github.com/graphql" -Context "unit" } | Should -Throw "*E_INVALID_URL*Only https*"
    }

    It "rejects user-info in URI" {
        { Assert-GitHubRequestUri -Uri "https://token@api.github.com/graphql" -Context "unit" } | Should -Throw "*E_INVALID_URL*user-info*"
    }

    It "enforces allowlist when provided" {
        { Assert-GitHubRequestUri -Uri "https://api.github.com/graphql" -Context "unit" -AllowedGitHubHosts @("ghes.example.com") } | Should -Throw "*E_INVALID_URL*allowed GitHub host list*"
    }

    It "allows canonical public API URIs when github.com is allowlisted" {
        { Assert-GitHubRequestUri -Uri "https://api.github.com/graphql" -Context "unit" -AllowedGitHubHosts @("github.com") } | Should -Not -Throw
    }

    It "accepts valid https URI and host" {
        { Assert-GitHubRequestUri -Uri "https://api.github.com/graphql" -Context "unit" } | Should -Not -Throw
    }
}

Describe "Resolve-GitHubGraphQLEndpoint" {
    It "uses api.github.com for github.com" {
        Resolve-GitHubGraphQLEndpoint -GitHubHost "github.com" | Should -Be "https://api.github.com/graphql"
    }

    It "uses /api/graphql for GHES" {
        Resolve-GitHubGraphQLEndpoint -GitHubHost "ghes.example.com" | Should -Be "https://ghes.example.com/api/graphql"
    }
}

Describe "Assert-GraphQLVariableMap" {
    BeforeAll {
        $script:assertGraphQLVariableMapQuery = @'
query Demo(
    $owner: String!,
    $repo: String!,
    $prNumber: Int!
) {
    repository(owner: $owner, name: $repo) {
        pullRequest(number: $prNumber) {
            id
        }
    }
}
'@
    }

    It "validates GraphQL variable payload casing and strictness (<Name>)" -ForEach @(
        @{
            Name                 = "accepts exact-case GraphQL variable payload keys"
            Variables            = @{ owner = "org"; repo = "repo"; prNumber = 10 }
            RejectUnexpected     = $false
            ShouldThrow          = $false
            ExpectedThrowPattern = ""
        },
        @{
            Name                 = "rejects payload keys that differ by casing"
            Variables            = @{ Owner = "org"; Repo = "repo"; prNumber = 10 }
            RejectUnexpected     = $false
            ShouldThrow          = $true
            ExpectedThrowPattern = "*E_CONFIG_ERROR*case mismatch*owner*Owner*repo*Repo*"
        },
        @{
            Name                 = "rejects unexpected variables when strict mode is requested"
            Variables            = @{ owner = "org"; repo = "repo"; prNumber = 10; extra = "unexpected" }
            RejectUnexpected     = $true
            ShouldThrow          = $true
            ExpectedThrowPattern = "*E_CONFIG_ERROR*unexpected variables*extra*"
        }
    ) {
        if ($ShouldThrow) {
            {
                Assert-GraphQLVariableMap -Query $script:assertGraphQLVariableMapQuery -Variables $Variables -Context "unit" -RejectUnexpectedVariables:$RejectUnexpected
            } | Should -Throw $ExpectedThrowPattern
            return
        }

        {
            Assert-GraphQLVariableMap -Query $script:assertGraphQLVariableMapQuery -Variables $Variables -Context "unit" -RejectUnexpectedVariables:$RejectUnexpected
        } | Should -Not -Throw
    }
}

Describe "Get-GitHubHeaders" {
    It "returns a hashtable without auth token" {
        $headers = Get-GitHubHeaders -AuthToken $null
        $headers | Should -BeOfType [hashtable]
        $headers.ContainsKey("Accept") | Should -BeTrue
        $headers.ContainsKey("User-Agent") | Should -BeTrue
        $headers.ContainsKey("Authorization") | Should -BeFalse
    }

    It "returns a hashtable with bearer authorization when token is supplied" {
        $headers = Get-GitHubHeaders -AuthToken "token-123"
        $headers | Should -BeOfType [hashtable]
        $headers["Authorization"] | Should -Be "Bearer token-123"
    }
}

Describe "Get-HeaderValue" {
    It "returns null when headers are null" {
        (Get-HeaderValue -Headers $null -Key "X-RateLimit-Reset") | Should -BeNullOrEmpty
    }

    It "reads case-insensitive values from dictionary headers" {
        $headers = @{ "x-ratelimit-reset" = "123" }
        (Get-HeaderValue -Headers $headers -Key "X-RateLimit-Reset") | Should -Be "123"
    }

    It "reads values from generic dictionary headers" {
        $headers = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $headers["X-OAuth-Scopes"] = "repo"

        (Get-HeaderValue -Headers $headers -Key "X-OAuth-Scopes") | Should -Be "repo"
    }

    It "ignores enumerable entries without Key property" {
        $headers = @("a", "b")
        (Get-HeaderValue -Headers $headers -Key "X-RateLimit-Reset") | Should -BeNullOrEmpty
    }

    It "normalizes array-valued hashtable entries to first scalar for Get-HeaderValue" {
        $headers = @{ "X-RateLimit-Reset" = @("123", "456") }
        (Get-HeaderValue -Headers $headers -Key "X-RateLimit-Reset") | Should -Be "123"
    }
}

Describe "Get-HeaderValues" {
    BeforeAll {
        # System.Net.Http is auto-loaded on PowerShell 7+ but NOT on Windows PowerShell 5.1,
        # where [System.Net.Http.HttpResponseMessage] would otherwise fail to resolve ("Unable
        # to find type"). Load it explicitly so the real-HttpHeaders provider exercises
        # production's TryGetValues branch on both editions.
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

        function New-HeaderProvider {
            # Builds a headers object of the requested backing kind. Returns the headers plus
            # an optional disposable owner so HttpResponseMessage (whose Headers is a live view)
            # can be released after the lookup.
            param(
                [Parameter(Mandatory = $true)]
                [ValidateSet("HttpHeaders", "Hashtable", "GenericDictionary")]
                [string]$Backing,

                [Parameter(Mandatory = $true)]
                [hashtable]$Entries
            )

            switch ($Backing) {
                "HttpHeaders" {
                    $response = [System.Net.Http.HttpResponseMessage]::new()
                    foreach ($key in $Entries.Keys) {
                        foreach ($value in @($Entries[$key])) {
                            $response.Headers.Add($key, $value)
                        }
                    }
                    return [pscustomobject]@{ Headers = $response.Headers; Disposable = $response }
                }
                "Hashtable" {
                    return [pscustomobject]@{ Headers = $Entries; Disposable = $null }
                }
                "GenericDictionary" {
                    $dictionary = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($key in $Entries.Keys) {
                        $dictionary[$key] = [string]@($Entries[$key])[0]
                    }
                    return [pscustomobject]@{ Headers = $dictionary; Disposable = $null }
                }
            }
        }
    }

    # Data-driven across every header backing production must accept: real HttpHeaders (via the
    # TryGetValues branch), plain hashtables, and case-insensitive generic dictionaries (both
    # via the ContainsKey branch). Adding a backing here adds a row, not a copy of the body.
    It "reads <Case>" -ForEach @(
        @{ Case = "multiple values from real HttpHeaders via TryGetValues"; Backing = "HttpHeaders"; Entries = @{ "X-OAuth-Scopes" = @("repo", "read:org") }; LookupKey = "X-OAuth-Scopes"; Expected = @("repo", "read:org") }
        @{ Case = "real HttpHeaders regardless of key casing"; Backing = "HttpHeaders"; Entries = @{ "X-OAuth-Scopes" = @("repo") }; LookupKey = "x-oauth-scopes"; Expected = @("repo") }
        @{ Case = "array-valued hashtable entries"; Backing = "Hashtable"; Entries = @{ "X-OAuth-Scopes" = @("repo", "read:org") }; LookupKey = "X-OAuth-Scopes"; Expected = @("repo", "read:org") }
        @{ Case = "case-insensitive generic dictionary entries"; Backing = "GenericDictionary"; Entries = @{ "X-OAuth-Scopes" = "repo" }; LookupKey = "x-oauth-scopes"; Expected = @("repo") }
    ) {
        param($Backing, $Entries, $LookupKey, $Expected)

        if ($Backing -eq "HttpHeaders" -and -not ([System.Management.Automation.PSTypeName]'System.Net.Http.HttpResponseMessage').Type) {
            Set-ItResult -Skipped -Because "System.Net.Http could not be loaded on this runner."
            return
        }

        $provider = New-HeaderProvider -Backing $Backing -Entries $Entries
        try {
            $values = @(Get-HeaderValues -Headers $provider.Headers -Key $LookupKey)
            ($values -join '|') | Should -BeExactly ($Expected -join '|') -Because "Get-HeaderValues should return the configured values for the $Backing backing."
        }
        finally {
            if ($null -ne $provider.Disposable) {
                $provider.Disposable.Dispose()
            }
        }
    }
}

Describe "Test-HasRateLimitHeaders" {
    It "returns true when Retry-After is present" {
        (Test-HasRateLimitHeaders -Headers @{ "Retry-After" = "30" }) | Should -BeTrue
    }

    It "returns true when X-RateLimit-Reset is present" {
        (Test-HasRateLimitHeaders -Headers @{ "X-RateLimit-Reset" = "1700000000" }) | Should -BeTrue
    }

    It "returns false when only X-RateLimit-Remaining is present" {
        (Test-HasRateLimitHeaders -Headers @{ "X-RateLimit-Remaining" = "5000" }) | Should -BeFalse
    }

    It "returns false when rate-limit headers contain only empty values" {
        (Test-HasRateLimitHeaders -Headers @{ "Retry-After" = @("", " "); "X-RateLimit-Reset" = @(" ") }) | Should -BeFalse
    }
}

Describe "Redact-SensitiveText" {
    It "redacts exact token occurrences" {
        $token = ("gh" + "p_") + "abcdefghijklmnopqrstuvwxyz1234567890"
        $input = "Authorization Bearer $token failed"

        $redacted = Redact-SensitiveText -Text $input -SensitiveTokens @($token)
        $redacted | Should -Not -Match [regex]::Escape($token)
        $redacted | Should -Match "\*\*\*REDACTED\*\*\*"
    }

    $ghpToken = ("gh" + "p_") + ("a" * 20)
    $ghoToken = ("gh" + "o_") + ("b" * 20)
    $ghuToken = ("gh" + "u_") + ("c" * 20)
    $ghsToken = ("gh" + "s_") + ("d" * 20)
    $ghrToken = ("gh" + "r_") + ("e" * 20)
    $patToken = ("github_" + "pat_") + ("f" * 20)
    $headerToken = "abcdefghijklmnopqrstuvwx123456"

    $cases = @(
        @{
            Name              = "redacts generic ghp token"
            CaseInput         = "Detected token: $ghpToken"
            SensitiveTokens   = @()
            ShouldContain     = "***REDACTED***"
            ShouldNotContain  = @($ghpToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name              = "redacts generic gho token"
            CaseInput         = "Detected token: $ghoToken"
            SensitiveTokens   = @()
            ShouldContain     = "***REDACTED***"
            ShouldNotContain  = @($ghoToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name              = "redacts generic ghu token"
            CaseInput         = "Detected token: $ghuToken"
            SensitiveTokens   = @()
            ShouldContain     = "***REDACTED***"
            ShouldNotContain  = @($ghuToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name              = "redacts generic ghs token"
            CaseInput         = "Detected token: $ghsToken"
            SensitiveTokens   = @()
            ShouldContain     = "***REDACTED***"
            ShouldNotContain  = @($ghsToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name              = "redacts generic ghr token"
            CaseInput         = "Detected token: $ghrToken"
            SensitiveTokens   = @()
            ShouldContain     = "***REDACTED***"
            ShouldNotContain  = @($ghrToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name              = "redacts generic github_pat token"
            CaseInput         = "Detected token: $patToken"
            SensitiveTokens   = @()
            ShouldContain     = "***REDACTED***"
            ShouldNotContain  = @($patToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name              = "redacts authorization bearer scheme"
            CaseInput         = "Authorization: Bearer $headerToken"
            SensitiveTokens   = @()
            ShouldContain     = "Authorization: Bearer ***REDACTED***"
            ShouldNotContain  = @($headerToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name              = "redacts authorization token scheme"
            CaseInput         = "Authorization: token $headerToken"
            SensitiveTokens   = @()
            ShouldContain     = "Authorization: token ***REDACTED***"
            ShouldNotContain  = @($headerToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name              = "does not redact too short ghp token"
            CaseInput         = "Detected token: ghp_abc123"
            SensitiveTokens   = @()
            ShouldContain     = "Detected token: ghp_abc123"
            ShouldNotContain  = @()
            ShouldBeUnchanged = $true
        },
        @{
            Name              = "does not redact regex literal documentation string"
            CaseInput         = '$redacted = $redacted -replace "gh[pousr]_[A-Za-z0-9_]{20,}", "***REDACTED***"'
            SensitiveTokens   = @()
            ShouldContain     = 'gh[pousr]_[A-Za-z0-9_]{20,}'
            ShouldNotContain  = @()
            ShouldBeUnchanged = $true
        }
    )

    It "enforces redaction behavior for <Name>" -TestCases $cases {
        param($Name, $CaseInput, $SensitiveTokens, $ShouldContain, $ShouldNotContain, $ShouldBeUnchanged)

        $redacted = Redact-SensitiveText -Text $CaseInput -SensitiveTokens $SensitiveTokens

        if ($ShouldBeUnchanged) {
            $redacted | Should -BeExactly $CaseInput
        }
        else {
            $redacted | Should -Not -BeExactly $CaseInput
        }

        $redacted | Should -Match ([regex]::Escape($ShouldContain))
        foreach ($value in $ShouldNotContain) {
            $redacted | Should -Not -Match ([regex]::Escape($value))
        }
    }
}

Describe "Test-ShouldUseClipboardOsc52" {
    BeforeAll {
        $script:originalTermProgram = $env:TERM_PROGRAM
        $script:originalWtSession = $env:WT_SESSION
        $script:originalSshClient = $env:SSH_CLIENT
        $script:originalSshTty = $env:SSH_TTY
    }

    BeforeEach {
        $env:TERM_PROGRAM = $null
        $env:WT_SESSION = $null
        $env:SSH_CLIENT = $null
        $env:SSH_TTY = $null
    }

    AfterAll {
        $env:TERM_PROGRAM = $script:originalTermProgram
        $env:WT_SESSION = $script:originalWtSession
        $env:SSH_CLIENT = $script:originalSshClient
        $env:SSH_TTY = $script:originalSshTty
    }

    It "never uses OSC52 when stdout is redirected, even in a supported terminal" {
        $env:TERM_PROGRAM = "vscode"
        Mock Test-IsConsoleOutputRedirected { $true }

        Test-ShouldUseClipboardOsc52 | Should -BeFalse
    }

    It "uses OSC52 in a supported terminal when stdout is not redirected" {
        $env:TERM_PROGRAM = "vscode"
        Mock Test-IsConsoleOutputRedirected { $false }

        Test-ShouldUseClipboardOsc52 | Should -BeTrue
    }

    It "does not use OSC52 outside a supported terminal even when not redirected" {
        Mock Test-IsConsoleOutputRedirected { $false }

        Test-ShouldUseClipboardOsc52 | Should -BeFalse
    }
}

Describe "Get-ClipboardCommand" {
    It "prefers Set-Clipboard when available" {
        Mock Test-ShouldUseClipboardOsc52 { $false }
        Mock Get-Command {
            [pscustomobject]@{ Name = "Set-Clipboard" }
        } -ParameterFilter { $Name -eq "Set-Clipboard" }

        $result = Get-ClipboardCommand
        $result | Should -Be "Set-Clipboard"
    }

    It "falls back to xclip when Set-Clipboard and pbcopy are unavailable" {
        Mock Test-ShouldUseClipboardOsc52 { $false }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq "Set-Clipboard" }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq "pbcopy" }
        Mock Get-Command { [pscustomobject]@{ Name = "xclip" } } -ParameterFilter { $Name -eq "xclip" }

        $result = Get-ClipboardCommand
        $result | Should -Be "xclip"
    }
}

Describe "Get-ClipboardCommandPriority" {
    It "adds Osc52 before Set-Clipboard on non-Windows when the terminal supports it" {
        Mock Test-IsWindowsPlatform { $false }
        Mock Test-ShouldUseClipboardOsc52 { $true }
        Mock Get-Command { [pscustomobject]@{ Name = "Set-Clipboard" } } -ParameterFilter { $Name -eq "Set-Clipboard" }
        Mock Get-Command { $null } -ParameterFilter { $Name -ne "Set-Clipboard" }

        $commands = @(Get-ClipboardCommandPriority)
        $commands[0] | Should -Be "Osc52"
        $commands[1] | Should -Be "Set-Clipboard"
    }

    It "prefers the Windows GUI clipboard before Osc52" {
        Mock Test-IsWindowsPlatform { $true }
        Mock Test-ShouldUseClipboardOsc52 { $true }
        Mock Get-Command { [pscustomobject]@{ Name = "Set-Clipboard" } } -ParameterFilter { $Name -eq "Set-Clipboard" }
        Mock Get-Command { $null } -ParameterFilter { $Name -ne "Set-Clipboard" }

        $commands = @(Get-ClipboardCommandPriority)
        $commands[0] | Should -Be "Set-Clipboard"
        $commands[1] | Should -Be "Osc52"
    }

    It "omits Osc52 when the terminal context does not support it" {
        Mock Test-IsWindowsPlatform { $false }
        Mock Test-ShouldUseClipboardOsc52 { $false }
        Mock Get-Command { [pscustomobject]@{ Name = "Set-Clipboard" } } -ParameterFilter { $Name -eq "Set-Clipboard" }
        Mock Get-Command { $null } -ParameterFilter { $Name -ne "Set-Clipboard" }

        $commands = @(Get-ClipboardCommandPriority)
        $commands | Should -Not -Contain "Osc52"
        $commands | Should -Contain "Set-Clipboard"
    }
}

Describe "Copy-ToClipboard" {
    It "copies text using Set-Clipboard when available" {
        Mock Get-ClipboardCommandPriority { @("Set-Clipboard") }
        Mock Set-ClipboardValue { }

        $copied = Copy-ToClipboard -Text "copy me"

        $copied | Should -BeTrue
        Assert-MockCalled Set-ClipboardValue -Times 1 -Scope It -ParameterFilter { $Value -eq "copy me" }
    }

    It "returns false and warns when clipboard command is unavailable" {
        $script:lastWarningMessage = $null
        Mock Get-ClipboardCommandPriority { @() }
        Mock Write-Warning {
            param($Message)
            $script:lastWarningMessage = $Message
        }

        $copied = Copy-ToClipboard -Text "copy me"

        $copied | Should -BeFalse
        $script:lastWarningMessage | Should -Match "W_CLIPBOARD_UNAVAILABLE"
    }

    It "redacts sensitive tokens when clipboard copy fails" {
        $secret = "ghp_" + ("a" * 36)
        $script:lastWarningMessage = $null
        Mock Get-ClipboardCommandPriority { @("Set-Clipboard") }
        Mock Set-ClipboardValue { throw "copy failure token=$secret" }
        Mock Write-Warning {
            param($Message)
            $script:lastWarningMessage = $Message
        }

        $copied = Copy-ToClipboard -Text "copy me" -SensitiveTokens @($secret)

        $copied | Should -BeFalse
        $script:lastWarningMessage | Should -Match "W_CLIPBOARD_COPY_FAILED"
        $script:lastWarningMessage | Should -Match "\*\*\*REDACTED\*\*\*"
        $script:lastWarningMessage | Should -Not -Match [regex]::Escape($secret)
    }

    It "falls back to Set-Clipboard when the Osc52 strategy fails" {
        $script:clipboardAttemptOrder = @()
        Mock Get-ClipboardCommandPriority { @("Osc52", "Set-Clipboard") }
        Mock Write-Osc52Clipboard {
            $script:clipboardAttemptOrder += "Osc52"
            throw "osc52 failed"
        }
        Mock Set-ClipboardValue {
            $script:clipboardAttemptOrder += "Set-Clipboard"
        }

        $copied = Copy-ToClipboard -Text "copy me"

        $copied | Should -BeTrue
        (($script:clipboardAttemptOrder) -join ",") | Should -Be "Osc52,Set-Clipboard" -Because "clipboard fallback should preserve OSC52-first attempt order and then recover with the native clipboard"
        Assert-MockCalled Write-Osc52Clipboard -Times 1 -Scope It
        Assert-MockCalled Set-ClipboardValue -Times 1 -Scope It
    }

    It "invokes Write-Osc52Clipboard when the Osc52 strategy is selected" {
        Mock Get-ClipboardCommandPriority { @("Osc52") }
        Mock Write-Osc52Clipboard { }

        $copied = Copy-ToClipboard -Text "copy me"

        $copied | Should -BeTrue
        Assert-MockCalled Write-Osc52Clipboard -Times 1 -Scope It -ParameterFilter { $Text -eq "copy me" }
    }

    It "routes native clipboard tools through the detached Invoke-NativeClipboardTool seam" {
        $script:nativeToolCalled = $null
        Mock Get-ClipboardCommandPriority { @("pbcopy") }
        Mock Invoke-NativeClipboardTool {
            param($Tool, $Arguments, $Text, $TimeoutSeconds)
            $script:nativeToolCalled = $Tool
            return $true
        }

        $copied = Copy-ToClipboard -Text "copy me"

        $copied | Should -BeTrue
        $script:nativeToolCalled | Should -Be "pbcopy"
        Assert-MockCalled Invoke-NativeClipboardTool -Times 1 -Scope It -ParameterFilter { $Tool -eq "pbcopy" -and $Text -eq "copy me" }
    }

    It "falls back across native clipboard tools in priority order" {
        $script:nativeClipboardAttemptOrder = @()
        Mock Get-ClipboardCommandPriority { @("pbcopy", "xclip", "xsel") }
        Mock Invoke-NativeClipboardTool {
            param($Tool, $Arguments, $Text, $TimeoutSeconds)
            $script:nativeClipboardAttemptOrder += $Tool
            # pbcopy and xclip fail; xsel succeeds.
            return ($Tool -eq "xsel")
        }

        $copied = Copy-ToClipboard -Text "copy me"

        $copied | Should -BeTrue
        (($script:nativeClipboardAttemptOrder) -join ",") | Should -Be "pbcopy,xclip,xsel" -Because "native fallback should continue through failed tools and stop after the first success"
    }
}

Describe "Invoke-NativeClipboardTool" {
    BeforeAll {
        $script:isUnixClipboardHost = -not (Test-IsWindowsPlatform)

        function New-FakeClipboardTool {
            param(
                [Parameter(Mandatory = $true)] [string]$Name,
                [Parameter(Mandatory = $true)] [string]$BashBody
            )
            $path = Join-Path -Path $script:clipToolDir -ChildPath $Name
            $content = "#!/usr/bin/env bash`n" + $BashBody + "`n"
            [System.IO.File]::WriteAllText($path, ($content -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
            & chmod +x $path
            return $path
        }
    }

    BeforeEach {
        $script:clipToolDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("cliptool-" + [Guid]::NewGuid().ToString("N"))
        [void][System.IO.Directory]::CreateDirectory($script:clipToolDir)
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:clipToolDir) {
            Remove-Item -LiteralPath $script:clipToolDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "returns false when the tool is not found" {
        (Invoke-NativeClipboardTool -Tool "definitely-not-a-real-clipboard-tool-xyz" -Text "x") | Should -BeFalse
    }

    It "delivers the payload as UTF-8 bytes via stdin and returns true on success" {
        if (-not $script:isUnixClipboardHost) { Set-ItResult -Skipped -Because "native clipboard CLI tools are a Unix-only path; Windows uses Set-Clipboard."; return }

        $captured = Join-Path -Path $script:clipToolDir -ChildPath "captured.bin"
        $tool = New-FakeClipboardTool -Name "faketool" -BashBody "cat > '$captured'`nexit 0"

        $payload = "ascii and " + ([char]0x00E9) + " and " + [char]::ConvertFromUtf32(0x1F680)
        $result = Invoke-NativeClipboardTool -Tool $tool -Text $payload

        $result | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes($captured)
        $expected = [System.Text.Encoding]::UTF8.GetBytes($payload)
        ($bytes -join ",") | Should -Be ($expected -join ",") -Because "the payload must reach the tool as verbatim UTF-8 bytes regardless of console code page"
    }

    It "returns false when the tool exits non-zero" {
        if (-not $script:isUnixClipboardHost) { Set-ItResult -Skipped -Because "native clipboard CLI tools are a Unix-only path."; return }

        $tool = New-FakeClipboardTool -Name "failtool" -BashBody "cat > /dev/null`nexit 3"
        (Invoke-NativeClipboardTool -Tool $tool -Text "x") | Should -BeFalse
    }

    It "returns false promptly when the tool exceeds the timeout (never hangs the script)" {
        if (-not $script:isUnixClipboardHost) { Set-ItResult -Skipped -Because "native clipboard CLI tools are a Unix-only path."; return }

        $tool = New-FakeClipboardTool -Name "slowtool" -BashBody "cat > /dev/null`nsleep 30`nexit 0"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-NativeClipboardTool -Tool $tool -Text "x" -TimeoutSeconds 2
        $sw.Stop()

        $result | Should -BeFalse
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 12 -Because "a blocking clipboard tool must be killed at the timeout, not awaited for its full duration"
    }

    It "returns promptly for a daemonizing tool that forks a child holding stdout (no terminal hold)" {
        if (-not $script:isUnixClipboardHost) { Set-ItResult -Skipped -Because "native clipboard CLI tools are a Unix-only path."; return }

        # Mimics xclip/xsel/wl-copy: consume stdin, fork a long-lived child, exit immediately.
        # Because the tool's stdio is redirected (not inherited), the forked child cannot hold the
        # caller's terminal open, and the direct child exits at once, so the call returns promptly.
        $tool = New-FakeClipboardTool -Name "daemontool" -BashBody "cat > /dev/null`n( sleep 30 ) &`nexit 0"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-NativeClipboardTool -Tool $tool -Text "x" -TimeoutSeconds 10
        $sw.Stop()

        $result | Should -BeTrue
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10 -Because "a daemonizing tool's forked child must not delay the call (its stdio is redirected, so it cannot hold the terminal)"
    }

    It "does not hang on the stdin write when the tool never reads stdin" {
        if (-not $script:isUnixClipboardHost) { Set-ItResult -Skipped -Because "native clipboard CLI tools are a Unix-only path."; return }

        # A tool that closes stdin and blocks without ever draining it. A large payload written
        # synchronously to stdin could fill the pipe buffer and block forever; the write must be
        # bounded so the timeout still governs total runtime.
        $tool = New-FakeClipboardTool -Name "noreadtool" -BashBody "exec 0<&-`nsleep 30`nexit 0"
        $bigPayload = "a" * 5000000

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-NativeClipboardTool -Tool $tool -Text $bigPayload -TimeoutSeconds 2
        $sw.Stop()

        $result | Should -BeFalse
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because "a blocked stdin write must not exceed the bounded timeout budget"
    }

    It "kills the whole tool process tree on timeout so a forked child cannot linger" {
        if (-not $script:isUnixClipboardHost) { Set-ItResult -Skipped -Because "native clipboard CLI tools are a Unix-only path."; return }
        if ((Test-IsDesktopEdition)) { Set-ItResult -Skipped -Because "Process.Kill(true) tree-kill is only available on PowerShell 7+ (Core)."; return }

        $marker = Join-Path -Path $script:clipToolDir -ChildPath "grandchild.txt"
        # Direct child forks a grandchild that would write a marker after 8s, then the direct child
        # blocks so the call hits the timeout. Tree-kill must terminate the grandchild before it
        # writes the marker.
        $tool = New-FakeClipboardTool -Name "treetool" -BashBody "cat > /dev/null`n( sleep 8; echo x > '$marker' ) &`nsleep 30"

        $result = Invoke-NativeClipboardTool -Tool $tool -Text "x" -TimeoutSeconds 2
        $result | Should -BeFalse
        Start-Sleep -Seconds 10

        (Test-Path -LiteralPath $marker) | Should -BeFalse -Because "tree-kill must terminate the forked grandchild before it can act"
    }
}

Describe "Wait-TaskObserved" {
    It "returns true for a task that completes within the timeout" {
        $task = [System.Threading.Tasks.Task]::Delay(10)
        (Wait-TaskObserved -Task $task -TimeoutMilliseconds 2000) | Should -BeTrue
    }

    It "returns false for a task that does not complete within the timeout" {
        $task = [System.Threading.Tasks.Task]::Delay(5000)
        (Wait-TaskObserved -Task $task -TimeoutMilliseconds 50) | Should -BeFalse
    }

    It "returns false for a null task" {
        (Wait-TaskObserved -Task $null -TimeoutMilliseconds 50) | Should -BeFalse
    }

    It "observes a faulted task without throwing and marks its exception handled" {
        $faulting = [System.Threading.Tasks.Task]::Run([System.Action] { throw [System.IO.IOException]::new("broken pipe") })
        try { $faulting.Wait(2000) } catch { }

        { Wait-TaskObserved -Task $faulting -TimeoutMilliseconds 200 } | Should -Not -Throw
        # Touching .Exception marks it observed; the task must be in the faulted terminal state.
        $faulting.IsFaulted | Should -BeTrue
        $null = $faulting.Exception
    }
}

Describe "Clipboard copy process-teardown" {
    # End-to-end guard for the user-reported "output renders, then the terminal hangs for 10s+" bug.
    # A native clipboard tool that forks a long-lived selection-server child must not delay the host
    # PROCESS EXIT, because the detached child stdio cannot hold the parent's streams open. Unit
    # tests of Invoke-NativeClipboardTool only observe the call duration; this test observes the
    # whole process lifetime (spawn -> output -> exit) via the stdout pipe closing.
    BeforeAll {
        $script:teardownIsUnix = -not (Test-IsWindowsPlatform)
        $script:scriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
    }

    BeforeEach {
        $script:teardownToolDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("clipteardown-" + [Guid]::NewGuid().ToString("N"))
        [void][System.IO.Directory]::CreateDirectory($script:teardownToolDir)
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:teardownToolDir) {
            Remove-Item -LiteralPath $script:teardownToolDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "exits promptly even when the clipboard tool forks a child that lingers" {
        if (-not $script:teardownIsUnix) { Set-ItResult -Skipped -Because "native clipboard CLI tools and this PTY-free teardown probe are a Unix-only path."; return }

        # Resolve the running PowerShell host executable. Get-Command can resolve an apphost shim
        # under .store that is not directly launchable, so prefer the current process main module
        # (the actual pwsh binary) and fall back to $PSHOME/pwsh.
        $pwshExe = $null
        try {
            $candidate = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
                $pwshExe = $candidate
            }
        }
        catch {
            $pwshExe = $null
        }
        if ($null -eq $pwshExe) {
            $homeCandidate = Join-Path -Path $PSHOME -ChildPath "pwsh"
            if (Test-Path -LiteralPath $homeCandidate) { $pwshExe = $homeCandidate }
        }
        if ($null -eq $pwshExe) { Set-ItResult -Skipped -Because "could not resolve a launchable pwsh host for the teardown probe."; return }

        # Daemonizing fake wl-copy: consume stdin, fork a child that sleeps 30s, exit immediately.
        $fakeTool = Join-Path -Path $script:teardownToolDir -ChildPath "wl-copy"
        $bash = "#!/usr/bin/env bash`ncat > /dev/null`n( sleep 30 ) &`nexit 0`n"
        [System.IO.File]::WriteAllText($fakeTool, ($bash -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
        & chmod +x $fakeTool

        # Inner script: force the native daemonizing tool path, copy, then signal completion. If the
        # forked child held our stdout, the parent's stdout pipe would stay open well past this point.
        $doneFile = Join-Path -Path $script:teardownToolDir -ChildPath "done.txt"
        $innerScript = @"
. '$($script:scriptUnderTest)' -NoRun
function Get-ClipboardCommandPriority { @('wl-copy') }
[void](Copy-ToClipboard -Text 'render-then-exit')
[System.IO.File]::WriteAllText('$doneFile', [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString())
"@
        $innerFile = Join-Path -Path $script:teardownToolDir -ChildPath "inner.ps1"
        [System.IO.File]::WriteAllText($innerFile, $innerScript, [System.Text.UTF8Encoding]::new($false))

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = [string]$pwshExe
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $probePath = $script:teardownToolDir + [System.IO.Path]::PathSeparator + $env:PATH
        Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "PATH" -Value $probePath
        Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("-NoProfile", "-NoLogo", "-File", $innerFile)

        $proc = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        # The stdout ReadToEnd completing is the real signal: it returns only once EVERY writer of
        # the pipe (the pwsh child AND any process holding an inherited copy of its stdout) has
        # closed. With the detached-stdio fix the forked clipboard child does not inherit it, so this
        # completes shortly after pwsh exits rather than 30s later.
        $exited = $proc.WaitForExit(60000)
        $drained = $stdoutTask.Wait(20000)
        [void]$stderrTask.Wait(2000)

        try {
            $exited | Should -BeTrue -Because "the pwsh child must exit within the timeout"
            (Test-Path -LiteralPath $doneFile) | Should -BeTrue -Because "the copy must have completed"
            $drained | Should -BeTrue -Because "the parent stdout pipe must reach EOF promptly; a forked clipboard child must not keep it open"
        }
        finally {
            if (-not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
            $proc.Dispose()
        }
    }
}

Describe "Set-ClipboardValue" {
    It "routes the value to Set-Clipboard" {
        Mock Set-Clipboard { }

        Set-ClipboardValue -Value "plain copy"

        Assert-MockCalled Set-Clipboard -Times 1 -Scope It -ParameterFilter { $Value -eq "plain copy" }
    }
}

Describe "ConvertTo-Osc52Sequence" {
    It "wraps UTF-8 base64 with the explicit clipboard selector" {
        $esc = [char]27
        $bel = [char]7
        $expected = "$esc]52;c;" + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("hello")) + $bel

        ConvertTo-Osc52Sequence -Text "hello" | Should -BeExactly $expected
    }

    It "encodes multibyte characters as UTF-8 before base64 (verbatim round-trip)" {
        $text = [string]([char]0x2014) + "X" + [string]([char]0x2018) + "Y"
        $esc = [char]27
        $bel = [char]7
        $prefix = "$esc]52;c;"

        $seq = ConvertTo-Osc52Sequence -Text $text
        $seq.StartsWith($prefix) | Should -BeTrue
        $seq.EndsWith($bel) | Should -BeTrue

        $base64 = $seq.Substring($prefix.Length, $seq.Length - $prefix.Length - 1)
        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
        $decoded | Should -BeExactly $text
    }

    It "produces a pure-ASCII transmittable sequence even for astral characters" {
        $seq = ConvertTo-Osc52Sequence -Text ([char]::ConvertFromUtf32(0x1F600))
        foreach ($ch in $seq.ToCharArray()) {
            ([int]$ch) | Should -BeLessThan 128
        }
    }
}

Describe "Write-Osc52Clipboard" {
    It "writes the OSC52 sequence through the console seam" {
        $script:capturedSequence = $null
        Mock Write-ConsoleHostSequence {
            param($Sequence)
            $script:capturedSequence = $Sequence
        }

        Write-Osc52Clipboard -Text "verbatim"

        $script:capturedSequence | Should -BeExactly (ConvertTo-Osc52Sequence -Text "verbatim")
        Assert-MockCalled Write-ConsoleHostSequence -Times 1 -Scope It
    }

    It "warns about terminal truncation when the payload exceeds the OSC52 budget" {
        $script:lastWarning = $null
        Mock Write-ConsoleHostSequence { }
        Mock Write-Warning { param($Message) $script:lastWarning = $Message }

        Write-Osc52Clipboard -Text ("a" * 5000) -MaxClipboardBytes 1000

        $script:lastWarning | Should -Match "W_CLIPBOARD_OSC52_TRUNCATION_RISK"
        # The copy is still attempted as best effort after warning.
        Assert-MockCalled Write-ConsoleHostSequence -Times 1 -Scope It
    }

    It "does not warn when the payload is within the OSC52 budget" {
        $script:lastWarning = $null
        Mock Write-ConsoleHostSequence { }
        Mock Write-Warning { param($Message) $script:lastWarning = $Message }

        Write-Osc52Clipboard -Text "small" -MaxClipboardBytes 1000

        $script:lastWarning | Should -BeNullOrEmpty
    }
}

Describe "Initialize-Utf8ConsoleOutputEncoding" {
    It "skips the console code-page change when the console is already UTF-8" {
        Mock Get-ConsoleOutputEncoding { New-Object System.Text.UTF8Encoding($false) }
        Mock Set-ConsoleOutputEncoding { }

        Initialize-Utf8ConsoleOutputEncoding

        # Setting [System.Console]::OutputEncoding triggers SetConsoleOutputCP on Windows, a slow
        # and sometimes flickery code-page switch. It must be skipped when already UTF-8 (the
        # common case) so it never adds per-invocation terminal latency.
        Assert-MockCalled Set-ConsoleOutputEncoding -Times 0 -Scope It
    }

    It "sets UTF-8 only when the console is not already UTF-8" {
        $script:assignedEncoding = $null
        Mock Get-ConsoleOutputEncoding { [System.Text.Encoding]::ASCII }
        Mock Set-ConsoleOutputEncoding { param($Encoding) $script:assignedEncoding = $Encoding }

        Initialize-Utf8ConsoleOutputEncoding

        Assert-MockCalled Set-ConsoleOutputEncoding -Times 1 -Scope It
        $script:assignedEncoding | Should -Not -BeNullOrEmpty
        $script:assignedEncoding.CodePage | Should -Be 65001
    }

    It "is resilient when reading the console encoding throws" {
        Mock Get-ConsoleOutputEncoding { throw "no console attached" }
        Mock Set-ConsoleOutputEncoding { }

        { Initialize-Utf8ConsoleOutputEncoding } | Should -Not -Throw
        Assert-MockCalled Set-ConsoleOutputEncoding -Times 0 -Scope It
    }

    It "is resilient when setting the console encoding throws" {
        Mock Get-ConsoleOutputEncoding { [System.Text.Encoding]::ASCII }
        Mock Set-ConsoleOutputEncoding { throw "cannot set encoding on redirected stream" }

        { Initialize-Utf8ConsoleOutputEncoding } | Should -Not -Throw
    }
}

Describe "Write-RenderedOutputToFile" {
    It "writes UTF-8 output and creates missing parent directories" {
        $tempRoot = Join-Path -Path $TestDrive -ChildPath "nested/path"
        $targetPath = Join-Path -Path $tempRoot -ChildPath "threads.txt"

        $resolvedPath = Write-RenderedOutputToFile -Text "hello" -OutputPath $targetPath

        $resolvedPath | Should -Be $targetPath
        (Test-Path -Path $targetPath -PathType Leaf) | Should -BeTrue
        [System.IO.File]::ReadAllText($targetPath, [System.Text.Encoding]::UTF8) | Should -Be "hello"
    }

    It "throws when OutputPath is empty" {
        { Write-RenderedOutputToFile -Text "x" -OutputPath "   " } | Should -Throw "*E_INVALID_OUTPUT_PATH*"
    }
}

Describe "Normalize-CommentText" {
    It "strips comment markup by default for <Name>" -ForEach @(
        @{
            Name     = "HTML comments"
            CaseText = "<!-- LOCATIONS START file.ps1#L93-L96 LOCATIONS END --> Found a potential issue."
            Expected = "Found a potential issue."
        },
        @{
            Name     = "Markdown images"
            CaseText = "Look at this: ![screenshot](https://example.test/img.png) wow"
            Expected = "Look at this: wow"
        },
        @{
            Name     = "Markdown links"
            CaseText = "See [the docs](https://example.test/docs) for details"
            Expected = "See the docs for details"
        },
        @{
            Name     = "HTML tags"
            CaseText = "Hello<br>world<img src='x'/>"
            Expected = "Hello world"
        },
        @{
            Name     = "multiple HTML comments"
            CaseText = "<!-- a --> text <!-- b --> more"
            Expected = "text more"
        },
        @{
            Name     = "Cursor metadata block"
            CaseText = "<!-- LOCATIONS START scripts/test-llm-harness.ps1#L93-L96 scripts/test-llm-harness.ps1#L110-L118 LOCATIONS END -->`n`nPotential issue at line 96: [Read more](https://cursor.example/blog)"
            Expected = "Potential issue at line 96: Read more"
        },
        @{
            Name     = "user HTML before Cursor button block"
            CaseText = '<div>Keep this context</div><div><a href="https://cursor.com/open?link=abc">Fix in Cursor</a></div> Actual finding.'
            Expected = "Keep this context Actual finding."
        },
        @{
            Name     = "spaced comparison operators preserved"
            CaseText = "Fail if value < threshold or count > limit here"
            Expected = "Fail if value < threshold or count > limit here"
        },
        @{
            Name     = "real tag stripped while spaced comparison span preserved"
            CaseText = "<b>Note</b>: a < b and c > d"
            Expected = "Note : a < b and c > d"
        }
    ) {
        param($Name, $CaseText, $Expected)

        $normalized = Normalize-CommentText -Text $CaseText -DisableTruncation

        $normalized | Should -BeExactly $Expected
    }

    It "returns none when stripping leaves no visible text" {
        Normalize-CommentText -Text "![img](https://example.test/img.png)" -DisableTruncation | Should -Be "(none)"
    }

    It "preserves markup when KeepMarkup is set" {
        $input = "See [the docs](https://example.test/docs) <em>now</em>"

        $normalized = Normalize-CommentText -Text $input -DisableTruncation -KeepMarkup

        $normalized | Should -BeExactly $input
    }

    It "does not split a surrogate pair when truncating at the boundary" {
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $text = ("A" * 9) + $emoji
        $result = Normalize-CommentText -Text $text -MaxLength 10

        $truncatedPortion = $result -replace " \[\.\.\.\]$", ""
        $truncatedPortion | Should -BeExactly ("A" * 9)
        [System.Char]::IsHighSurrogate($truncatedPortion[$truncatedPortion.Length - 1]) | Should -BeFalse

        # A lone surrogate would round-trip through UTF-8 as U+FFFD; verbatim output must not.
        $roundTripped = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetBytes($result))
        $roundTripped | Should -BeExactly $result
    }

    It "keeps a whole surrogate pair that fits exactly at the boundary" {
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $text = ("A" * 8) + $emoji + "BBBBB"
        $result = Normalize-CommentText -Text $text -MaxLength 10

        $truncatedPortion = $result -replace " \[\.\.\.\]$", ""
        $truncatedPortion | Should -BeExactly (("A" * 8) + $emoji)
    }
}

Describe "Get-EmbeddedCommentLocations" {
    It "extracts Cursor Bugbot LOCATIONS ranges in order" {
        $body = "<!-- LOCATIONS START scripts/test-llm-harness.ps1#L93-L96 scripts/test-llm-harness.ps1#L110-L118 LOCATIONS END -->"

        $locations = @(Get-EmbeddedCommentLocations -Text $body)

        $locations.Count | Should -Be 2
        $locations[0].path | Should -Be "scripts/test-llm-harness.ps1"
        $locations[0].lineStart | Should -Be 93
        $locations[0].lineEnd | Should -Be 96
        $locations[1].path | Should -Be "scripts/test-llm-harness.ps1"
        $locations[1].lineStart | Should -Be 110
        $locations[1].lineEnd | Should -Be 118
    }

    It "normalizes GitHub blob URLs and single-line anchors" {
        $body = "<!-- LOCATIONS START https://github.com/org/repo/blob/abc123/Scripts/Some%20File.ps1#L10 scripts/other.ps1#L20-L22 LOCATIONS END -->"

        $locations = @(Get-EmbeddedCommentLocations -Text $body)

        $locations.Count | Should -Be 2
        $locations[0].path | Should -Be "Scripts/Some File.ps1"
        $locations[0].lineStart | Should -Be 10
        $locations[0].lineEnd | Should -Be 10
        $locations[1].path | Should -Be "scripts/other.ps1"
        $locations[1].lineStart | Should -Be 20
        $locations[1].lineEnd | Should -Be 22
    }

    It "clamps inverted embedded ranges to the start line" {
        $body = "<!-- LOCATIONS START scripts/test-llm-harness.ps1#L96-L93 LOCATIONS END -->"

        $locations = @(Get-EmbeddedCommentLocations -Text $body)

        $locations.Count | Should -Be 1
        $locations[0].lineStart | Should -Be 96
        $locations[0].lineEnd | Should -Be 96
    }
}

Describe "Comment suggestion blocks" {
    It "extracts a single suggestion block verbatim" {
        $body = @'
Please rename this for clarity.

```suggestion
$resolvedHostName = $candidateHost.Trim()
```
'@
        $suggestions = @(Get-CommentSuggestionBlocks -Text $body)

        $suggestions.Count | Should -Be 1
        $suggestions[0].kind | Should -Be "suggestion"
        $suggestions[0].code | Should -BeExactly '$resolvedHostName = $candidateHost.Trim()'
    }

    It "preserves multi-line suggestion code with exact indentation" {
        $body = @'
Use a guard clause.

```suggestion
if ($null -eq $value) {
    return
}
```

Thanks!
'@
        $suggestions = @(Get-CommentSuggestionBlocks -Text $body)
        $expectedCode = "if (`$null -eq `$value) {`n    return`n}"

        $suggestions.Count | Should -Be 1
        $suggestions[0].code | Should -BeExactly $expectedCode
    }

    It "extracts multiple suggestion blocks in document order" {
        $body = @'
First:
```suggestion
alpha
```
Second:
```suggestion
beta
```
'@
        $suggestions = @(Get-CommentSuggestionBlocks -Text $body)

        $suggestions.Count | Should -Be 2
        $suggestions[0].code | Should -BeExactly "alpha"
        $suggestions[1].code | Should -BeExactly "beta"
    }

    It "represents an empty suggestion block as an empty deletion" {
        $body = @'
Delete this line.

```suggestion
```
'@
        $suggestions = @(Get-CommentSuggestionBlocks -Text $body)

        $suggestions.Count | Should -Be 1
        $suggestions[0].code | Should -BeExactly ""
    }

    It "ignores non-suggestion fenced code blocks" {
        $body = @'
Example only:
```powershell
Get-Thing
```
'@
        @(Get-CommentSuggestionBlocks -Text $body).Count | Should -Be 0
    }

    It "returns an empty array when no suggestions are present" {
        @(Get-CommentSuggestionBlocks -Text "Just prose, no code.").Count | Should -Be 0
        @(Get-CommentSuggestionBlocks -Text $null).Count | Should -Be 0
        @(Get-CommentSuggestionBlocks -Text "   ").Count | Should -Be 0
    }

    It "tolerates CRLF line endings in suggestion blocks" {
        $fence = [string]([char]96) * 3
        $body = "Fix this.`r`n`r`n${fence}suggestion`r`nGet-Fixed`r`n${fence}"
        $suggestions = @(Get-CommentSuggestionBlocks -Text $body)

        $suggestions.Count | Should -Be 1
        $suggestions[0].code | Should -BeExactly "Get-Fixed"
    }

    It "captures suggestions on a record and strips them from the prose" {
        $body = @'
Consider renaming for clarity.

```suggestion
$normalizedHost = $candidate.Trim()
```
'@
        $thread = [pscustomobject]@{
            id         = "THREAD_SUGGESTION"
            isResolved = $false
            path       = "src/host.ps1"
            startLine  = 10
            line       = 10
            comments   = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = $body })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"

        @($record.suggestions).Count | Should -Be 1
        $record.suggestions[0].kind | Should -Be "suggestion"
        $record.suggestions[0].code | Should -BeExactly '$normalizedHost = $candidate.Trim()'
        $record.topLevelComment | Should -Be "Consider renaming for clarity."
        $record.topLevelComment | Should -Not -Match 'suggestion'
        $record.topLevelComment | Should -Not -Match 'normalizedHost'
    }

    It "renders captured suggestions verbatim before the latest-reply line" {
        $body = @'
Use a guard clause.

```suggestion
if ($null -eq $value) {
    return
}
```
'@
        $thread = [pscustomobject]@{
            id         = "THREAD_SUGGESTION_TEXT"
            isResolved = $false
            path       = "src/guard.ps1"
            startLine  = 3
            line       = 3
            comments   = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = $body })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"
        $normalized = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"

        $normalized | Should -Match "Suggested change:"
        $normalized | Should -Match ([regex]::Escape('if ($null -eq $value) {'))
        $normalized | Should -Match ([regex]::Escape('    return'))

        $suggestionIndex = $normalized.IndexOf("Suggested change:")
        $replyIndex = $normalized.IndexOf("Latest reply summary:")
        $suggestionIndex | Should -BeGreaterThan -1
        $suggestionIndex | Should -BeLessThan $replyIndex
    }

    It "does not extract suggestions under KeepMarkup" {
        $body = @'
Keep raw markup.

```suggestion
raw code
```
'@
        $thread = [pscustomobject]@{
            id         = "THREAD_SUGGESTION_KEEPMARKUP"
            isResolved = $false
            path       = "src/raw.ps1"
            startLine  = 1
            line       = 1
            comments   = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = $body })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com" -KeepMarkup

        @($record.suggestions).Count | Should -Be 0
        $record.topLevelComment | Should -Match 'suggestion'
    }
}

Describe "Convert-ReviewThreadToOutputRecord" {
    It "returns null for resolved threads" {
        $thread = [pscustomobject]@{
            id         = "T_x"
            isResolved = $true
            path       = "src/file.ps1"
            startLine  = 10
            line       = 11
            comments   = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = "hello" })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 1 -GitHubHost "github.com"
        $record | Should -BeNullOrEmpty
    }

    It "maps unresolved thread fields" {
        $thread = [pscustomobject]@{
            id         = "THREAD_1"
            isResolved = $false
            path       = "src/main.ts"
            startLine  = 10
            line       = 12
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{ body = "Top level comment" },
                    [pscustomobject]@{ body = "Reply summary" }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"
        $propertyNames = @($record.PSObject.Properties.Name)

        ($propertyNames -ccontains "path") | Should -BeTrue
        ($propertyNames -ccontains "locationSource") | Should -BeTrue
        ($propertyNames -ccontains "githubPath") | Should -BeTrue
        ($propertyNames -ccontains "githubLineStart") | Should -BeTrue
        ($propertyNames -ccontains "githubLineEnd") | Should -BeTrue
        ($propertyNames -ccontains "embeddedLocations") | Should -BeTrue
        ($propertyNames -ccontains "suggestions") | Should -BeTrue
        ($propertyNames -ccontains "resolutionState") | Should -BeTrue
        ($propertyNames -ccontains "authSource") | Should -BeFalse
        ($propertyNames -ccontains "owner") | Should -BeTrue
        ($propertyNames -ccontains "repo") | Should -BeTrue
        ($propertyNames -ccontains "Path") | Should -BeFalse
        ($propertyNames -ccontains "GithubLineEnd") | Should -BeFalse
        ($propertyNames -ccontains "Owner") | Should -BeFalse
        ($propertyNames -ccontains "Repo") | Should -BeFalse
        $record.path | Should -Be "src/main.ts"
        $record.lineStart | Should -Be 10
        $record.lineEnd | Should -Be 12
        $record.locationSource | Should -Be "github"
        $record.githubPath | Should -Be "src/main.ts"
        $record.githubLineStart | Should -Be 10
        $record.githubLineEnd | Should -Be 12
        @($record.embeddedLocations).Count | Should -Be 0
        $record.topLevelComment | Should -Be "Top level comment"
        $record.latestReplySummary | Should -Be "Reply summary"
        $record.resolutionState | Should -Be "unresolved"
        $record.threadId | Should -Be "THREAD_1"
        $record.owner | Should -Be "org"
        $record.repo | Should -Be "repo"
        $record.url | Should -Be "https://github.com/org/repo/pull/77"
    }

    It "preserves current GitHub anchor fields separately from merged display ranges" {
        $thread = [pscustomobject]@{
            id                = "THREAD_DIVERGED_ANCHOR"
            isResolved        = $false
            path              = "src/rebased.ts"
            startLine         = 20
            line              = 25
            originalStartLine = 10
            originalLine      = 15
            comments          = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = "Rebased range comment" })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"

        $record.locationSource | Should -Be "github"
        $record.lineStart | Should -Be 10
        $record.lineEnd | Should -Be 25
        $record.githubLineStart | Should -Be 20
        $record.githubLineEnd | Should -Be 25
    }

    It "uses original start line when current startLine is unavailable" {
        $thread = [pscustomobject]@{
            id                = "THREAD_ORIGINAL_START"
            isResolved        = $false
            path              = "src/range.ts"
            startLine         = $null
            line              = 47
            originalStartLine = 37
            originalLine      = 52
            comments          = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = "Range comment" })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"

        $record.lineStart | Should -Be 37
        $record.lineEnd | Should -Be 52

        $text = Format-UnresolvedThreadsAsText -Records @($record)
        $text | Should -Match "\(src/range\.ts\) 37-52"

        $json = Format-UnresolvedThreadsAsJson -Records @($record)
        $parsed = @($json | ConvertFrom-JsonCompat -Depth 8)
        $parsed[0].lineStart | Should -Be 37
        $parsed[0].lineEnd | Should -Be 52
    }

    It "uses original start and current line from generic dictionary threads" {
        $thread = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        $thread.Add("id", "THREAD_GENERIC_DICTIONARY")
        $thread.Add("isResolved", $false)
        $thread.Add("path", "src/generic-dictionary.ts")
        $thread.Add("startLine", $null)
        $thread.Add("line", 47)
        $thread.Add("originalStartLine", 37)
        $thread.Add("originalLine", 42)
        $thread.Add("comments", [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = "Generic dictionary range comment" })
            })

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"

        $record.path | Should -Be "src/generic-dictionary.ts"
        $record.lineStart | Should -Be 37
        $record.lineEnd | Should -Be 47
    }

    It "uses original end line when current end line is unavailable" {
        $thread = [pscustomobject]@{
            id                = "THREAD_ORIGINAL_END"
            isResolved        = $false
            path              = "src/current-start-original-end.ts"
            startLine         = 5
            line              = $null
            originalStartLine = $null
            originalLine      = 8
            comments          = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = "Mixed range comment" })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"

        $record.lineStart | Should -Be 5
        $record.lineEnd | Should -Be 8
    }

    It "uses original range when current range fields are unavailable" {
        $thread = [pscustomobject]@{
            id                = "THREAD_ORIGINAL_ONLY"
            isResolved        = $false
            path              = "src/deleted.ts"
            startLine         = $null
            line              = $null
            originalStartLine = 5
            originalLine      = 8
            comments          = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = "Deleted-side range comment" })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"

        $record.lineStart | Should -Be 5
        $record.lineEnd | Should -Be 8
    }

    It "keeps end unknown when only start metadata is available" {
        $thread = [pscustomobject]@{
            id                = "THREAD_START_ONLY"
            isResolved        = $false
            path              = "src/start-only.ts"
            startLine         = 15
            line              = $null
            originalStartLine = 12
            originalLine      = $null
            comments          = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = "Start-only range comment" })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"

        $record.lineStart | Should -Be 12
        $record.lineEnd | Should -BeNullOrEmpty

        $text = Format-UnresolvedThreadsAsText -Records @($record)
        $text | Should -Match "\(src/start-only\.ts\) 12-\?"
    }

    It "throws when comments nodes is not array-wrapped" {
        $thread = [pscustomobject]@{
            id         = "THREAD_SINGLE"
            isResolved = $false
            path       = "src/single.ts"
            startLine  = 21
            line       = 21
            comments   = [pscustomobject]@{
                nodes = [pscustomobject]@{ body = "Single comment only" }
            }
        }

        {
            [void](Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 7 -GitHubHost "github.com")
        } | Should -Throw "*E_MALFORMED_RESPONSE*comments.nodes must be an array*"
    }

    It "keeps long comments untruncated by default" {
        $topBody = "x" * 600
        $replyBody = "y" * 400
        $thread = [pscustomobject]@{
            id         = "THREAD_LONG"
            isResolved = $false
            path       = "src/long.ts"
            startLine  = 5
            line       = 9
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{ body = $topBody },
                    [pscustomobject]@{ body = $replyBody }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"
        $record.topLevelComment.Length | Should -Be 600
        $record.latestReplySummary.Length | Should -Be 400
        $record.topLevelComment | Should -Not -Match "\[\.\.\.\]"
        $record.latestReplySummary | Should -Not -Match "\[\.\.\.\]"
    }

    It "applies legacy truncation limits when Truncate is set" {
        $topBody = "x" * 600
        $replyBody = "y" * 400
        $thread = [pscustomobject]@{
            id         = "THREAD_TRUNCATE"
            isResolved = $false
            path       = "src/long.ts"
            startLine  = 5
            line       = 9
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{ body = $topBody },
                    [pscustomobject]@{ body = $replyBody }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com" -Truncate
        $record.topLevelComment.Length | Should -Be 506
        $record.latestReplySummary.Length | Should -Be 306
        $record.topLevelComment | Should -Match "\[\.\.\.\]$"
        $record.latestReplySummary | Should -Match "\[\.\.\.\]$"
    }

    It "uses embedded Cursor Bugbot locations for rendered output and strips bot chrome" {
        $body = @'
### BOM test never actually writes a BOM to file  **Low Severity**
<!-- DESCRIPTION START --> The `New-TempFile` helper does not prepend the UTF-8 BOM preamble. <!-- DESCRIPTION END -->
<!-- BUGBOT_BUG_ID: 9ba7cf02-5286-48f8-9b14-368e1013dd72 -->
<!-- LOCATIONS START scripts/test-llm-harness.ps1#L93-L96 scripts/test-llm-harness.ps1#L110-L118 LOCATIONS END -->
<details><summary>Additional Locations (1)</summary>

- [`scripts/test-llm-harness.ps1#L110-L118`](https://github.com/org/repo/blob/sha/scripts/test-llm-harness.ps1#L110-L118)
</details>
<div><a href="https://cursor.com/open?link=abc"><picture><img alt="Fix in Cursor" width="115" src="https://cursor.com/assets/fix-in-cursor-dark.png"></picture></a></div>
<sup>Reviewed by [Cursor Bugbot](https://cursor.com/bugbot) for commit abc. Configure [here](https://cursor.com/dashboard/bugbot).</sup>
'@
        $thread = [pscustomobject]@{
            id                = "THREAD_CURSOR_BUGBOT"
            isResolved        = $false
            path              = "scripts/test-llm-harness.ps1"
            startLine         = 96
            line              = 96
            originalStartLine = 96
            originalLine      = 96
            comments          = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = $body })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"

        $record.path | Should -Be "scripts/test-llm-harness.ps1"
        $record.lineStart | Should -Be 93
        $record.lineEnd | Should -Be 96
        $record.locationSource | Should -Be "embedded"
        $record.githubPath | Should -Be "scripts/test-llm-harness.ps1"
        $record.githubLineStart | Should -Be 96
        $record.githubLineEnd | Should -Be 96
        @($record.embeddedLocations).Count | Should -Be 2
        $record.embeddedLocations[1].lineStart | Should -Be 110
        $record.embeddedLocations[1].lineEnd | Should -Be 118

        $record.topLevelComment | Should -Match "BOM test never actually writes a BOM"
        $record.topLevelComment | Should -Match "UTF-8 BOM preamble"
        $record.topLevelComment | Should -Not -Match "LOCATIONS|BUGBOT_BUG_ID|Additional Locations|Fix in Cursor|Reviewed by|cursor\.com|https?://|<details|<div|<sup|!\["

        $text = Format-UnresolvedThreadsAsText -Records @($record)
        $text | Should -Match "\(scripts/test-llm-harness\.ps1\) 93-96"
    }

    It "preserves markup with KeepMarkup while still using embedded locations" {
        $body = '<!-- LOCATIONS START scripts/test-llm-harness.ps1#L93-L96 LOCATIONS END --> Finding with [docs](https://example.test/docs).'
        $thread = [pscustomobject]@{
            id         = "THREAD_KEEP_MARKUP_EMBEDDED"
            isResolved = $false
            path       = "scripts/test-llm-harness.ps1"
            startLine  = 96
            line       = 96
            comments   = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = $body })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com" -KeepMarkup

        $record.locationSource | Should -Be "embedded"
        $record.lineStart | Should -Be 93
        $record.lineEnd | Should -Be 96
        $record.topLevelComment | Should -Match '<!-- LOCATIONS START'
        $record.topLevelComment | Should -Match '\[docs\]\(https://example\.test/docs\)'
    }
}

Describe "Format-UnresolvedThreadsAsText" {
    It "renders exact delimiter contract" {
        $records = @(
            [pscustomobject]@{
                path               = "src/a.ts"
                lineStart          = 8
                lineEnd            = 8
                topLevelComment    = "Comment A"
                latestReplySummary = $null
                threadId           = "1"
                prNumber           = 1
                owner              = "o"
                repo               = "r"
                url                = "https://github.com/o/r/pull/1"
            },
            [pscustomobject]@{
                path               = "src/b.ts"
                lineStart          = 12
                lineEnd            = 20
                topLevelComment    = "Comment B"
                latestReplySummary = "Reply B"
                threadId           = "2"
                prNumber           = 1
                owner              = "o"
                repo               = "r"
                url                = "https://github.com/o/r/pull/1"
            }
        )

        $text = Format-UnresolvedThreadsAsText -Records $records
        $expected = @"
---
(src/a.ts) 8-8
Comment A
Latest reply summary: (none)
---
(src/b.ts) 12-20
Comment B
Latest reply summary: Reply B
---
"@

        $actualNormalized = $text -replace "`r`n", "`n"
        $expectedNormalized = $expected.TrimEnd("`r", "`n") -replace "`r`n", "`n"

        $actualNormalized | Should -BeExactly $expectedNormalized
    }

    It "never emits two adjacent delimiter lines between blocks" {
        $records = @(
            [pscustomobject]@{
                path               = "src/a.ts"
                lineStart          = 1
                lineEnd            = 1
                topLevelComment    = "A"
                latestReplySummary = $null
            },
            [pscustomobject]@{
                path               = "src/b.ts"
                lineStart          = 2
                lineEnd            = 2
                topLevelComment    = "B"
                latestReplySummary = $null
            },
            [pscustomobject]@{
                path               = "src/c.ts"
                lineStart          = 3
                lineEnd            = 3
                topLevelComment    = "C"
                latestReplySummary = $null
            }
        )

        $text = Format-UnresolvedThreadsAsText -Records $records
        $lines = @(($text -replace "`r`n", "`n") -split "`n")

        # A single delimiter must separate blocks (and bookend the output); two
        # consecutive "---" lines (the legacy double delimiter) must never appear.
        for ($i = 0; $i -lt ($lines.Count - 1); $i++) {
            if ($lines[$i] -eq "---") {
                $lines[$i + 1] | Should -Not -Be "---" -Because "adjacent '---' lines are the collapsed-delimiter regression"
            }
        }

        @($lines | Where-Object { $_ -eq "---" }).Count | Should -Be 4 -Because "three blocks use one leading, two separating, and one trailing delimiter"
    }

    It "renders a single bookended block for one record" {
        $records = @(
            [pscustomobject]@{
                path               = "src/only.ts"
                lineStart          = 5
                lineEnd            = 7
                topLevelComment    = "Solo comment"
                latestReplySummary = $null
            }
        )

        $text = Format-UnresolvedThreadsAsText -Records $records
        $expected = @"
---
(src/only.ts) 5-7
Solo comment
Latest reply summary: (none)
---
"@

        ($text -replace "`r`n", "`n") | Should -BeExactly (($expected.TrimEnd("`r", "`n")) -replace "`r`n", "`n")
    }
}

Describe "Format-UnresolvedThreadsAsJson" {
    It "always emits an array and preserves lower-camel schema keys" {
        $records = @(
            [pscustomobject]@{
                path               = "src/main.ts"
                lineStart          = 10
                lineEnd            = 12
                topLevelComment    = "Top"
                latestReplySummary = "Reply"
                resolutionState    = "unresolved"
                threadId           = "THREAD_1"
                prNumber           = 77
                owner              = "org"
                repo               = "repo"
                url                = "https://github.com/org/repo/pull/77"
            }
        )

        $json = Format-UnresolvedThreadsAsJson -Records $records
        $json | Should -Match '^\s*\['

        $parsed = @($json | ConvertFrom-JsonCompat -Depth 8)
        $parsed.Count | Should -Be 1
        $propertyNames = @($parsed[0].PSObject.Properties.Name)

        ($propertyNames -ccontains "path") | Should -BeTrue
        ($propertyNames -ccontains "resolutionState") | Should -BeTrue
        ($propertyNames -ccontains "authSource") | Should -BeFalse
        ($propertyNames -ccontains "owner") | Should -BeTrue
        ($propertyNames -ccontains "repo") | Should -BeTrue
        ($propertyNames -ccontains "Path") | Should -BeFalse
        ($propertyNames -ccontains "Owner") | Should -BeFalse
        ($propertyNames -ccontains "Repo") | Should -BeFalse

        $parsed[0].path | Should -Be "src/main.ts"
        $parsed[0].resolutionState | Should -Be "unresolved"
        $parsed[0].owner | Should -Be "org"
        $parsed[0].repo | Should -Be "repo"
    }
}

Describe "Get-AuthToken" {
    BeforeAll {
        $script:originalGitHubToken = $env:GITHUB_TOKEN
        $script:originalGhToken = $env:GH_TOKEN
    }

    BeforeEach {
        $env:GITHUB_TOKEN = $null
        $env:GH_TOKEN = $null
    }

    AfterAll {
        $env:GITHUB_TOKEN = $script:originalGitHubToken
        $env:GH_TOKEN = $script:originalGhToken
    }

    It "prefers explicit token over env" {
        $env:GITHUB_TOKEN = "env-token"
        $value = Get-AuthToken -ExplicitToken "explicit-token" -GitHubHost "github.com"
        $value | Should -Be "explicit-token"
    }

    It "prefers GH_TOKEN over GITHUB_TOKEN when both are set" {
        $env:GH_TOKEN = "gh-token"
        $env:GITHUB_TOKEN = "github-token"

        $value = Get-AuthToken -GitHubHost "github.com"
        $value | Should -Be "gh-token"
    }

    It "falls back to GITHUB_TOKEN when GH_TOKEN is missing" {
        $env:GITHUB_TOKEN = "github-token"

        $value = Get-AuthToken -GitHubHost "github.com"
        $value | Should -Be "github-token"
    }

    It "returns source metadata when requested" {
        $env:GH_TOKEN = "gh-token"

        $resolution = Get-AuthToken -GitHubHost "github.com" -IncludeSourceMetadata
        $resolution.Token | Should -Be "gh-token"
        $resolution.Source | Should -Be "GH_TOKEN"
        $resolution.SourceCategory | Should -Be "environment"
        $resolution.EnvironmentVariable | Should -Be "GH_TOKEN"
    }

    It "skips rejected token values while resolving environment sources" {
        $env:GH_TOKEN = "rejected-token"
        $env:GITHUB_TOKEN = "fallback-token"

        $resolution = Get-AuthToken -GitHubHost "github.com" -IncludeSourceMetadata -RejectedTokenValues @("rejected-token")

        $resolution.Token | Should -Be "fallback-token"
        $resolution.Source | Should -Be "GITHUB_TOKEN"
        $resolution.SourceCategory | Should -Be "environment"
        $resolution.EnvironmentVariable | Should -Be "GITHUB_TOKEN"
    }

    It "ignores environment tokens when requested" {
        $env:GH_TOKEN = "gh-token"
        $env:GITHUB_TOKEN = "github-token"

        Mock Get-Command { $null } -ParameterFilter { $Name -eq "gh" }
        Mock Get-GitCredentialToken { $null }

        $resolution = Get-AuthToken -GitHubHost "github.com" -IncludeSourceMetadata -IgnoreEnvironmentTokens
        $resolution.Token | Should -Be $null
        $resolution.Source | Should -Be "none"
    }

    It "clears environment tokens around stored gh credential lookup" {
        $env:GH_TOKEN = "expired-env-token"
        $env:GITHUB_TOKEN = "fallback-env-token"
        $script:ghSawGhToken = "<unset>"
        $script:ghSawGitHubToken = "<unset>"

        try {
            function gh {
                $script:ghSawGhToken = $env:GH_TOKEN
                $script:ghSawGitHubToken = $env:GITHUB_TOKEN
                $global:LASTEXITCODE = 0
                "stored-gh-token"
            }

            Mock Get-GitCredentialToken { $null }

            $resolution = Get-AuthToken -GitHubHost "github.com" -IncludeSourceMetadata -IgnoreEnvironmentTokens

            $resolution.Token | Should -Be "stored-gh-token"
            $resolution.Source | Should -Be "gh"
            $resolution.SourceCategory | Should -Be "gh"
            $script:ghSawGhToken | Should -BeNullOrEmpty
            $script:ghSawGitHubToken | Should -BeNullOrEmpty
            $env:GH_TOKEN | Should -Be "expired-env-token"
            $env:GITHUB_TOKEN | Should -Be "fallback-env-token"
        }
        finally {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It "returns git credential source metadata" {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq "gh" }
        Mock Get-GitCredentialToken { "git-credential-token" }

        $resolution = Get-AuthToken -GitHubHost "github.com" -IncludeSourceMetadata

        $resolution.Token | Should -Be "git-credential-token"
        $resolution.Source | Should -Be "git-credential"
        $resolution.SourceCategory | Should -Be "git-credential"
        $resolution.EnvironmentVariable | Should -BeNullOrEmpty
    }
}

Describe "Invoke-GitHubRequestWithRetry" {
    BeforeEach {
        Mock Start-Sleep { }
    }

    It "retries transient failures and then succeeds" {
        $script:attempt = 0
        Mock Invoke-RestMethod {
            $script:attempt++
            if ($script:attempt -eq 1) {
                throw (New-Object System.Exception "temporary failure")
            }

            return @{ ok = $true }
        }

        $result = Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 3 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $result.ok | Should -BeTrue
        $script:attempt | Should -Be 2
        Assert-MockCalled Start-Sleep -Times 1 -Scope It
    }

    It "rejects non-https request URIs before invoking the transport" {
        Mock Invoke-RestMethod { throw "should not run" }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "http://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_INVALID_URL*"
        Assert-MockCalled Invoke-RestMethod -Times 0 -Scope It
    }

    It "enforces host allowlist before invoking the transport" {
        Mock Invoke-RestMethod { throw "should not run" }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -AllowedGitHubHostsNormalized @("ghes.example.com") } | Should -Throw "*E_INVALID_URL*allowed GitHub host list*"
        Assert-MockCalled Invoke-RestMethod -Times 0 -Scope It
    }

    It "maps 401 to E_AUTH_INVALID" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "auth failed") }
        Mock Get-HttpStatusCode { 401 }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_AUTH_INVALID*"
    }

    It "retries 403 responses and eventually succeeds" {
        $script:attempt = 0
        Mock Invoke-RestMethod {
            $script:attempt++
            if ($script:attempt -le 2) {
                throw (New-Object System.Exception "forbidden")
            }

            return @{ ok = $true }
        }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{} }

        $result = Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 3 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $result.ok | Should -BeTrue
        $script:attempt | Should -Be 3
    }

    It "uses Retry-After header fallback when waiting on rate limits" {
        $script:attempt = 0
        Mock Invoke-RestMethod {
            $script:attempt++
            if ($script:attempt -eq 1) {
                throw (New-Object System.Exception "rate limited")
            }

            return @{ ok = $true }
        }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{ "Retry-After" = "1" } }

        $result = Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -WaitOnRateLimit
        $result.ok | Should -BeTrue
        $script:attempt | Should -Be 2
        Assert-MockCalled Start-Sleep -Times 1 -Scope It
    }

    It "uses Retry-After RFC date fallback when waiting on rate limits" {
        $script:attempt = 0
        $retryAfterHttpDate = [DateTimeOffset]::UtcNow.AddSeconds(10).ToString("r")

        Mock Invoke-RestMethod {
            $script:attempt++
            if ($script:attempt -eq 1) {
                throw (New-Object System.Exception "rate limited")
            }

            return @{ ok = $true }
        }
        Mock Get-HttpStatusCode { 429 }
        Mock Get-ResponseHeaders { @{ "Retry-After" = $retryAfterHttpDate } }

        $result = Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -WaitOnRateLimit
        $result.ok | Should -BeTrue
        $script:attempt | Should -Be 2
        Assert-MockCalled Start-Sleep -Times 1 -Scope It
    }

    It "uses X-RateLimit-Reset when waiting on rate limits" {
        $script:attempt = 0
        $futureReset = [DateTimeOffset]::UtcNow.AddSeconds(10).ToUnixTimeSeconds().ToString()

        Mock Invoke-RestMethod {
            $script:attempt++
            if ($script:attempt -eq 1) {
                throw (New-Object System.Exception "rate limited")
            }

            return @{ ok = $true }
        }
        Mock Get-HttpStatusCode { 429 }
        Mock Get-ResponseHeaders { @{ "X-RateLimit-Reset" = $futureReset } }

        $result = Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -WaitOnRateLimit
        $result.ok | Should -BeTrue
        $script:attempt | Should -Be 2
        Assert-MockCalled Start-Sleep -Times 1 -Scope It
    }

    It "fails fast when Retry-After is present but unparseable" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "rate limited") }
        Mock Get-HttpStatusCode { 429 }
        Mock Get-ResponseHeaders { @{ "Retry-After" = "not-a-valid-retry-after" } }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -WaitOnRateLimit } | Should -Throw "*E_RATE_LIMIT*Invalid Retry-After value*"
    }

    It "throws E_RATE_LIMIT_403 when rate-limit headers exist and waiting is disabled" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "rate limited") }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{ "Retry-After" = "60" } }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_RATE_LIMIT_403*"
    }

    It "throws E_FORBIDDEN when 403 has no rate-limit headers" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "forbidden") }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{} }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_FORBIDDEN*"
    }

    It "does not classify 403 as rate-limited when only X-RateLimit-Remaining exists" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "forbidden") }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{ "X-RateLimit-Remaining" = "5000" } }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_FORBIDDEN*"
    }

    It "does not classify 403 as rate-limited when Retry-After is empty" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "forbidden") }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{ "Retry-After" = @("", " ") } }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_FORBIDDEN*"
    }

    It "enforces overall timeout budget before sleeping for rate-limit reset" {
        $futureReset = [DateTimeOffset]::UtcNow.AddSeconds(45).ToUnixTimeSeconds().ToString()

        Mock Invoke-RestMethod { throw (New-Object System.Exception "rate limited") }
        Mock Get-HttpStatusCode { 429 }
        Mock Get-ResponseHeaders { @{ "X-RateLimit-Reset" = $futureReset } }
        Mock Start-Sleep { }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(2)) -WaitOnRateLimit } | Should -Throw "*E_NETWORK_TIMEOUT*"
        Assert-MockCalled Start-Sleep -Times 0 -Scope It
    }

    It "applies exponential backoff with jitter bounds" {
        $script:attempt = 0
        $script:delays = @()

        Mock Invoke-RestMethod {
            $script:attempt++
            if ($script:attempt -le 2) {
                throw (New-Object System.Exception "temporary failure")
            }

            return @{ ok = $true }
        }
        Mock Get-HttpStatusCode { 500 }
        Mock Get-ResponseHeaders { @{} }
        Mock Get-Random { 123 }
        Mock Start-Sleep {
            param(
                [int]$Milliseconds
            )

            if ($PSBoundParameters.ContainsKey("Milliseconds")) {
                $script:delays += $Milliseconds
            }
        }

        $result = Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 3 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $result.ok | Should -BeTrue
        $script:delays.Count | Should -Be 2
        $script:delays[0] | Should -Be 1123
        $script:delays[1] | Should -Be 2123
    }

    It "rejects negative MaxRetries values" {
        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries -1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*Cannot validate argument*"
    }

    It "rejects invalid rate-limit reset timestamps" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "rate limited") }
        Mock Get-HttpStatusCode { 429 }
        Mock Get-ResponseHeaders { @{ "X-RateLimit-Reset" = "0" } }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -WaitOnRateLimit } | Should -Throw "*E_RATE_LIMIT*"
    }

    It "throws deterministic E_RATE_LIMIT when Retry-After has multiple values" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "rate limited") }
        Mock Get-HttpStatusCode { 429 }
        Mock Get-ResponseHeaders { @{ "Retry-After" = @("5", "10") } }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -WaitOnRateLimit } | Should -Throw "*E_RATE_LIMIT*Expected exactly one value*Retry-After*"
    }

    It "throws deterministic E_RATE_LIMIT when X-RateLimit-Reset has multiple values" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "rate limited") }
        Mock Get-HttpStatusCode { 429 }
        Mock Get-ResponseHeaders { @{ "X-RateLimit-Reset" = @("1700000000", "1700000100") } }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -WaitOnRateLimit } | Should -Throw "*E_RATE_LIMIT*Expected exactly one value*X-RateLimit-Reset*"
    }

    It "does not fail with hashtable conversion when response headers are array-shaped" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "temporary failure") }
        Mock Get-HttpStatusCode { 500 }
        Mock Get-ResponseHeaders { @("header-a", "header-b") }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{ "Accept" = "application/json" } -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_GITHUB_API_ERROR(500)*"
    }

    It "maps missing HTTP status failures to E_NETWORK_ERROR" {
        Mock Invoke-RestMethod { throw (New-Object System.Exception "connection reset") }
        Mock Get-HttpStatusCode { $null }
        Mock Get-ResponseHeaders { $null }

        { Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{ "Accept" = "application/json" } -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_NETWORK_ERROR*"
    }
}

Describe "Get-OpenPullRequests" {
    It "uses GHES /api/v3 endpoint" {
        $script:capturedUri = $null
        $script:capturedTimeout = $null
        Mock Invoke-GitHubRequestWithRetry {
            param($Method, $Uri, $RequestTimeoutSeconds)
            $script:capturedUri = $Uri
            $script:capturedTimeout = $RequestTimeoutSeconds
            return @()
        }

        [void](Get-OpenPullRequests -Owner "my-org" -Repo "my-repo" -GitHubHost "ghes.example.com" -Headers @{} -RequestTimeoutSeconds 42 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        $script:capturedUri | Should -Be "https://ghes.example.com/api/v3/repos/my-org/my-repo/pulls?state=open&per_page=50"
        $script:capturedTimeout | Should -Be 42
    }
}

Describe "Validate-GitHubTokenForRepoAccess" {
    BeforeEach {
        Mock Start-Sleep { }
    }

    It "fails fast when overall deadline has already expired" {
        Mock Invoke-WebRequest { throw "should not run" }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(-1)) } | Should -Throw "*E_NETWORK_TIMEOUT*"
        Assert-MockCalled Invoke-WebRequest -Times 0 -Scope It
    }

    It "caps request timeout to remaining deadline budget" {
        Mock Invoke-WebRequest {
            return [pscustomobject]@{
                Headers = @{ "X-OAuth-Scopes" = "repo" }
                Content = '{"private": true}'
            }
        }

        Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -RequestTimeoutSeconds 300 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(20))

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -Scope It -ParameterFilter { $TimeoutSec -gt 0 -and $TimeoutSec -le 20 }
    }

    It "retries transient 5xx failures before succeeding" {
        $script:attempt = 0

        Mock Invoke-WebRequest {
            $script:attempt++
            if ($script:attempt -lt 3) {
                throw (New-Object System.Exception "temporary failure")
            }

            return [pscustomobject]@{
                Headers = @{ "X-OAuth-Scopes" = "repo" }
                Content = '{"private": true}'
            }
        }
        Mock Get-HttpStatusCode { 503 }
        Mock Get-ResponseHeaders { @{} }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Not -Throw
        $script:attempt | Should -Be 3
        Assert-MockCalled Start-Sleep -Times 2 -Scope It
    }

    It "passes when repository metadata is reachable" {
        Mock Invoke-WebRequest {
            return [pscustomobject]@{
                Headers = @{ "X-OAuth-Scopes" = "repo, read:org" }
                Content = '{"private": true}'
            }
        }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Not -Throw
    }

    It "supports multi-value OAuth scope headers" {
        Mock Invoke-WebRequest {
            return [pscustomobject]@{
                Headers = @{ "X-OAuth-Scopes" = @("repo", "read:org") }
                Content = '{"private": true}'
            }
        }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Not -Throw
    }

    It "rejects OAuth scope headers that contain only whitespace values" {
        Mock Invoke-WebRequest {
            return [pscustomobject]@{
                Headers = @{ "X-OAuth-Scopes" = @(" ", "") }
                Content = '{"private": true}'
            }
        }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_MALFORMED_RESPONSE*X-OAuth-Scopes*"
    }

    It "maps access failure to E_AUTH_INSUFFICIENT_SCOPE" {
        Mock Invoke-WebRequest {
            return [pscustomobject]@{
                Headers = @{ "X-OAuth-Scopes" = "public_repo" }
                Content = '{"private": true}'
            }
        }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_AUTH_INSUFFICIENT_SCOPE*"
    }

    It "maps malformed metadata payloads to E_MALFORMED_RESPONSE" {
        Mock Invoke-WebRequest {
            return [pscustomobject]@{
                Headers = @{ "X-OAuth-Scopes" = "repo" }
                Content = '[{"private": true}, {"private": false}]'
            }
        }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_MALFORMED_RESPONSE*"
    }

    It "maps invalid JSON payloads to E_MALFORMED_RESPONSE" {
        Mock Invoke-WebRequest {
            return [pscustomobject]@{
                Headers = @{ "X-OAuth-Scopes" = "repo" }
                Content = '{"private":'
            }
        }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_MALFORMED_RESPONSE*"
    }

    It "maps 401 failures to E_AUTH_INVALID" {
        Mock Invoke-WebRequest { throw (New-Object System.Exception "auth failed") }
        Mock Get-HttpStatusCode { 401 }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_AUTH_INVALID*"
    }

    It "maps 429 failures to E_AUTH_RATE_LIMITED" {
        Mock Invoke-WebRequest { throw (New-Object System.Exception "rate limited") }
        Mock Get-HttpStatusCode { 429 }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_AUTH_RATE_LIMITED*"
    }

    It "maps 403 failures without rate-limit headers to E_FORBIDDEN" {
        Mock Invoke-WebRequest { throw (New-Object System.Exception "forbidden") }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{} }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_FORBIDDEN*"
    }

    It "maps 403 failures with rate-limit headers to E_AUTH_RATE_LIMITED" {
        Mock Invoke-WebRequest { throw (New-Object System.Exception "forbidden") }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{ "Retry-After" = "60" } }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_AUTH_RATE_LIMITED*"
    }

    It "maps 403 failures with only X-RateLimit-Remaining to E_FORBIDDEN" {
        Mock Invoke-WebRequest { throw (New-Object System.Exception "forbidden") }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{ "X-RateLimit-Remaining" = "5000" } }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_FORBIDDEN*"
    }

    It "maps 403 failures with empty Retry-After to E_FORBIDDEN" {
        Mock Invoke-WebRequest { throw (New-Object System.Exception "forbidden") }
        Mock Get-HttpStatusCode { 403 }
        Mock Get-ResponseHeaders { @{ "Retry-After" = @("", " ") } }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_FORBIDDEN*"
    }

    It "maps missing HTTP status to E_NETWORK_ERROR" {
        Mock Invoke-WebRequest { throw (New-Object System.Exception "connection failed") }
        Mock Get-HttpStatusCode { $null }
        Mock Get-ResponseHeaders { $null }

        { Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_NETWORK_ERROR*"
    }
}

Describe "Select-PullRequestInteractively" {
    It "accepts owner values with underscores" {
        $script:readIndex = 0
        $script:responses = @("my_org", "demo-repo", "1")
        $script:capturedInteractiveTimeout = $null

        Mock Read-Host {
            $value = $script:responses[$script:readIndex]
            $script:readIndex++
            return $value
        }

        Mock Get-OpenPullRequests {
            param($RequestTimeoutSeconds)
            $script:capturedInteractiveTimeout = $RequestTimeoutSeconds
            return @(
                [pscustomobject]@{ number = 42; title = "Fix test" }
            )
        }

        $selected = Select-PullRequestInteractively -GitHubHost "github.com" -Headers @{} -RequestTimeoutSeconds 45 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $selected.Owner | Should -Be "my_org"
        $selected.Repo | Should -Be "demo-repo"
        $selected.PullRequestNumber | Should -Be 42
        $script:capturedInteractiveTimeout | Should -Be 45
    }

    It "accepts 39-character owners in interactive mode" {
        $owner39 = "o" + ("a" * 38)
        $script:readIndex = 0
        $script:responses = @($owner39, "demo-repo", "1")

        Mock Read-Host {
            $value = $script:responses[$script:readIndex]
            $script:readIndex++
            return $value
        }

        Mock Get-OpenPullRequests {
            return @(
                [pscustomobject]@{ number = 42; title = "Fix test" }
            )
        }

        $selected = Select-PullRequestInteractively -GitHubHost "github.com" -Headers @{} -RequestTimeoutSeconds 45 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $selected.Owner | Should -Be $owner39
    }

    It "rejects owners longer than 39 characters in interactive mode" {
        $owner40 = "o" + ("a" * 39)
        $script:readIndex = 0
        $script:responses = @($owner40, "demo-repo")

        Mock Read-Host {
            $value = $script:responses[$script:readIndex]
            $script:readIndex++
            return $value
        }

        { Select-PullRequestInteractively -GitHubHost "github.com" -Headers @{} -RequestTimeoutSeconds 45 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_INVALID_OWNER_REPO*"
    }
}

Describe "Get-UnresolvedReviewThreads" {
    It "filters only unresolved threads across paginated responses" {
        $script:pageCall = 0
        Mock Invoke-GitHubRequestWithRetry {
            $script:pageCall++
            if ($script:pageCall -eq 1) {
                return @{
                    data = @{
                        repository = @{
                            pullRequest = @{
                                reviewThreads = @{
                                    pageInfo = @{ hasNextPage = $true; endCursor = "CURSOR_1" }
                                    nodes    = @(
                                        @{ id = "T1"; isResolved = $false; path = "src/a.ts"; startLine = 1; line = 1; comments = @{ nodes = @(@{ body = "A" }, @{ body = "A reply" }) } },
                                        @{ id = "T2"; isResolved = $true; path = "src/b.ts"; startLine = 2; line = 2; comments = @{ nodes = @(@{ body = "B" }) } }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            return @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            reviewThreads = @{
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                nodes    = @(
                                    @{ id = "T3"; isResolved = $false; path = "src/c.ts"; startLine = 3; line = 4; comments = @{ nodes = @(@{ body = "C" }) } }
                                )
                            }
                        }
                    }
                }
            }
        }

        $records = @(Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 100 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))

        $records.Count | Should -Be 2
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "T1"
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "T3"
        ($records | Select-Object -ExpandProperty threadId) | Should -Not -Contain "T2"
    }

    It "sends lowercase GraphQL variable keys expected by the query" {
        $script:capturedGraphQLBodyJson = $null

        Mock Invoke-GitHubRequestWithRetry {
            param($Body)

            $script:capturedGraphQLBodyJson = $Body | ConvertTo-Json -Depth 20 -Compress
            return @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            reviewThreads = @{
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                nodes    = @()
                            }
                        }
                    }
                }
            }
        }

        [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))

        $capturedBody = $script:capturedGraphQLBodyJson | ConvertFrom-Json
        $variableNames = @($capturedBody.variables.PSObject.Properties.Name)

        $variableNames | Should -Contain "owner"
        $variableNames | Should -Contain "repo"
        $variableNames | Should -Contain "prNumber"
        $variableNames | Should -Contain "first"
        $variableNames | Should -Contain "after"
        ($variableNames -ccontains "Owner") | Should -BeFalse
        ($variableNames -ccontains "Repo") | Should -BeFalse
        ($variableNames -ccontains "PrNumber") | Should -BeFalse
        ($variableNames -ccontains "First") | Should -BeFalse
        ($variableNames -ccontains "After") | Should -BeFalse

        $capturedBody.query | Should -Match "(?m)^\s+originalStartLine\s*$"
        $capturedBody.query | Should -Match "(?m)^\s+originalLine\s*$"
        $capturedBody.query | Should -Not -Match "(?m)^\s+diffSide\s*$"
    }

    It "fails before request dispatch when GraphQL variable validation fails" {
        Mock Assert-GraphQLVariableMap {
            throw "E_CONFIG_ERROR: synthetic variable-map validation failure"
        }

        Mock Invoke-GitHubRequestWithRetry {
            throw "network should not be called when variable validation fails"
        }

        {
            [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_CONFIG_ERROR*synthetic variable-map validation failure*"

        Assert-MockCalled Assert-GraphQLVariableMap -Times 1 -Scope It
        Assert-MockCalled Invoke-GitHubRequestWithRetry -Times 0 -Scope It
    }

    It "redacts sensitive text in GraphQL errors" {
        $secret = ("gh" + "p_") + "verysecrettoken1234567890"
        Mock Invoke-GitHubRequestWithRetry {
            return @{ errors = @(@{ message = "failure token=$secret" }) }
        }

        $thrown = $null
        try {
            [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -SensitiveTokens @($secret))
        }
        catch {
            $thrown = $_.Exception.Message
        }

        $thrown | Should -Match "E_GRAPHQL_ERROR"
        $thrown | Should -Not -Match [regex]::Escape($secret)
    }

    It "throws when reviewThreads nodes is not an array" {
        Mock Invoke-GitHubRequestWithRetry {
            return @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            reviewThreads = @{
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                nodes    = @{ id = "T1" }
                            }
                        }
                    }
                }
            }
        }

        {
            [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_MALFORMED_RESPONSE*reviewThreads.nodes must be an array*"
    }

    It "throws when comments nodes is not an array" {
        Mock Invoke-GitHubRequestWithRetry {
            return @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            reviewThreads = @{
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                nodes    = @(
                                    @{ id = "T1"; isResolved = $false; path = "src/a.ts"; startLine = 1; line = 1; comments = @{ nodes = @{ body = "not-array" } } }
                                )
                            }
                        }
                    }
                }
            }
        }

        {
            [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_MALFORMED_RESPONSE*comments.nodes must be an array*"
    }

    It "throws when pageInfo is missing hasNextPage" {
        Mock Invoke-GitHubRequestWithRetry {
            return @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            reviewThreads = @{
                                pageInfo = @{ endCursor = $null }
                                nodes    = @()
                            }
                        }
                    }
                }
            }
        }

        {
            [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_MALFORMED_RESPONSE*pageInfo.hasNextPage*"
    }

    It "throws when endCursor type is not string or null" {
        Mock Invoke-GitHubRequestWithRetry {
            return @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            reviewThreads = @{
                                pageInfo = @{ hasNextPage = $true; endCursor = 42 }
                                nodes    = @()
                            }
                        }
                    }
                }
            }
        }

        {
            [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_MALFORMED_RESPONSE*endCursor must be a string or null*"
    }

    It "returns full comment bodies by default" {
        $topBody = "x" * 600
        $replyBody = "y" * 400

        Mock Invoke-GitHubRequestWithRetry {
            return @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            reviewThreads = @{
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                nodes    = @(
                                    @{ id = "T1"; isResolved = $false; path = "src/a.ts"; startLine = 1; line = 1; comments = @{ nodes = @(@{ body = $topBody }, @{ body = $replyBody }) } }
                                )
                            }
                        }
                    }
                }
            }
        }

        $records = @(Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        $records.Count | Should -Be 1
        $records[0].topLevelComment.Length | Should -Be 600
        $records[0].latestReplySummary.Length | Should -Be 400
    }

    It "applies truncation when Truncate is set" {
        $topBody = "x" * 600
        $replyBody = "y" * 400

        Mock Invoke-GitHubRequestWithRetry {
            return @{
                data = @{
                    repository = @{
                        pullRequest = @{
                            reviewThreads = @{
                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                nodes    = @(
                                    @{ id = "T1"; isResolved = $false; path = "src/a.ts"; startLine = 1; line = 1; comments = @{ nodes = @(@{ body = $topBody }, @{ body = $replyBody }) } }
                                )
                            }
                        }
                    }
                }
            }
        }

        $records = @(Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -Truncate)
        $records.Count | Should -Be 1
        $records[0].topLevelComment | Should -Match "\[\.\.\.\]$"
        $records[0].latestReplySummary | Should -Match "\[\.\.\.\]$"
    }
}

Describe "Get-PublicPullRequestReviewCommentsFallback" {
    It "skips REST comments with missing or blank ids before building thread ids" {
        $threads = @(Convert-RestReviewCommentsToThreadLikeObjects -Comments @(
                [pscustomobject]@{
                    id         = $null
                    body       = "Missing id"
                    created_at = "2026-01-01T00:00:00Z"
                    html_url   = "https://github.com/org/repo/pull/9#discussion_missing"
                    user       = [pscustomobject]@{ login = "reviewer-a" }
                },
                [pscustomobject]@{
                    id         = " "
                    body       = "Blank id"
                    created_at = "2026-01-01T00:01:00Z"
                    html_url   = "https://github.com/org/repo/pull/9#discussion_blank"
                    user       = [pscustomobject]@{ login = "reviewer-b" }
                },
                [pscustomobject]@{
                    id         = 101
                    path       = "src/a.ts"
                    line       = 6
                    body       = "Top A"
                    created_at = "2026-01-01T00:02:00Z"
                    html_url   = "https://github.com/org/repo/pull/9#discussion_r101"
                    user       = [pscustomobject]@{ login = "reviewer-c" }
                },
                [pscustomobject]@{
                    id             = 102
                    in_reply_to_id = 101
                    body           = "Reply A"
                    created_at     = "2026-01-01T00:03:00Z"
                    html_url       = "https://github.com/org/repo/pull/9#discussion_r102"
                    user           = [pscustomobject]@{ login = "reviewer-d" }
                }
            ))

        $threads.Count | Should -Be 1
        $threads[0].id | Should -Be "rest:101"
        @($threads[0].comments.nodes).Count | Should -Be 2
    }

    It "paginates anonymous REST comments, groups replies, maps line fields, and marks resolution unknown" {
        $script:restUris = @()
        $script:warningMessages = @()
        $script:sawAuthorizationHeader = $false

        Mock Invoke-GitHubRequestWithRetry {
            param(
                [string]$Method,
                [string]$Uri,
                [hashtable]$Headers
            )

            $script:restUris += $Uri
            if ($Headers.ContainsKey("Authorization")) {
                $script:sawAuthorizationHeader = $true
            }

            if ($Uri -match "page=1") {
                return @(
                    [pscustomobject]@{
                        id                  = 101
                        path                = "src/a.ts"
                        start_line          = 4
                        line                = 6
                        original_start_line = 3
                        original_line       = 7
                        body                = "Top A"
                        created_at          = "2026-01-01T00:00:00Z"
                        html_url            = "https://github.com/org/repo/pull/9#discussion_r101"
                        user                = [pscustomobject]@{ login = "reviewer-a" }
                    },
                    [pscustomobject]@{
                        id             = 102
                        in_reply_to_id = 101
                        body           = "Reply A"
                        created_at     = "2026-01-01T00:01:00Z"
                        html_url       = "https://github.com/org/repo/pull/9#discussion_r102"
                        user           = [pscustomobject]@{ login = "reviewer-b" }
                    }
                )
            }

            return @(
                [pscustomobject]@{
                    id         = 201
                    path       = "src/b.ts"
                    start_line = $null
                    line       = 12
                    body       = "Top B"
                    created_at = "2026-01-01T00:02:00Z"
                    html_url   = "https://github.com/org/repo/pull/9#discussion_r201"
                    user       = [pscustomobject]@{ login = "reviewer-c" }
                }
            )
        }

        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        $records = @(Get-PublicPullRequestReviewCommentsFallback -Owner "org" -Repo "repo" -PrNumber 9 -GitHubHost "github.com" -PerPage 2 -MaxPages 5 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))

        $records.Count | Should -Be 2
        $records[0].threadId | Should -Be "rest:101"
        $records[0].path | Should -Be "src/a.ts"
        $records[0].lineStart | Should -Be 3
        $records[0].lineEnd | Should -Be 7
        $records[0].githubLineStart | Should -Be 4
        $records[0].githubLineEnd | Should -Be 6
        $records[0].topLevelComment | Should -Be "Top A"
        $records[0].latestReplySummary | Should -Be "Reply A"
        $records[0].resolutionState | Should -Be "unknown"
        $records[1].threadId | Should -Be "rest:201"
        $records[1].lineStart | Should -Be 12
        $records[1].lineEnd | Should -Be 12
        $records[1].resolutionState | Should -Be "unknown"

        $script:sawAuthorizationHeader | Should -BeFalse
        $script:restUris.Count | Should -Be 2
        $script:restUris[0] | Should -Be "https://api.github.com/repos/org/repo/pulls/9/comments?per_page=2&page=1&sort=created&direction=asc"
        $script:restUris[1] | Should -Be "https://api.github.com/repos/org/repo/pulls/9/comments?per_page=2&page=2&sort=created&direction=asc"
        $script:warningMessages.Count | Should -Be 1
        $script:warningMessages[0] | Should -Match "W_PUBLIC_REST_FALLBACK_RESOLUTION_UNKNOWN"

        $json = Format-UnresolvedThreadsAsJson -Records $records
        $parsed = @($json | ConvertFrom-JsonCompat -Depth 8)
        $parsed[0].resolutionState | Should -Be "unknown"
        @($parsed[0].PSObject.Properties.Name) | Should -Not -Contain "authSource"
    }
}

Describe "Resolve-PullRequestTarget" {
    It "uses host parsed from PullRequestUrl when explicit GitHubHost matching is not requested" {
        $target = Resolve-PullRequestTarget -PullRequestUrl "https://ghes.example.com/octo/demo/pull/99" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))

        $target.Host | Should -Be "ghes.example.com"
        $target.Owner | Should -Be "octo"
        $target.Repo | Should -Be "demo"
        $target.PullRequestNumber | Should -Be 99
    }

    It "requires PullRequestUrl host to match explicit GitHubHost" {
        { Resolve-PullRequestTarget -PullRequestUrl "https://ghes.example.com/octo/demo/pull/99" -GitHubHost "github.com" -GitHubHostProvided -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_INVALID_URL*does not match explicitly provided -GitHubHost*"
    }

    It "accepts PullRequestUrl host that matches explicit GitHubHost" {
        $target = Resolve-PullRequestTarget -PullRequestUrl "https://gHeS.example.com/octo/demo/pull/99" -GitHubHost "GHES.EXAMPLE.COM" -GitHubHostProvided -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))

        $target.Host | Should -Be "ghes.example.com"
    }

    It "resolves direct owner/repo/number values" {
        $target = Resolve-PullRequestTarget -Owner "octo" -Repo "demo" -PullRequestNumber 99 -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $target.Host | Should -Be "github.com"
        $target.Owner | Should -Be "octo"
        $target.Repo | Should -Be "demo"
        $target.PullRequestNumber | Should -Be 99
    }

    It "resolves direct owner/repo/number values for GHES host" {
        $target = Resolve-PullRequestTarget -Owner "octo" -Repo "demo" -GitHubHost "ghes.example.com" -PullRequestNumber 99 -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $target.Host | Should -Be "ghes.example.com"
        $target.Owner | Should -Be "octo"
        $target.Repo | Should -Be "demo"
        $target.PullRequestNumber | Should -Be 99
    }

    It "rejects disallowed interactive host values" {
        Mock Read-Host {
            return "localhost"
        }

        { Resolve-PullRequestTarget -Interactive -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_INVALID_URL*"
    }

    It "requires headers in interactive mode" {
        { Resolve-PullRequestTarget -Interactive -Headers $null -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_CONFIG_ERROR*"
    }

    It "requires a future deadline in interactive mode" {
        { Resolve-PullRequestTarget -Interactive -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(-1)) } | Should -Throw "*E_CONFIG_ERROR*"
    }

    It "rejects invalid direct owner values" {
        $owner40 = "o" + ("a" * 39)
        { Resolve-PullRequestTarget -Owner $owner40 -Repo "demo" -PullRequestNumber 99 -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_INVALID_OWNER_REPO*"
    }

    It "rejects malformed direct host values" {
        { Resolve-PullRequestTarget -Owner "octo" -Repo "demo" -GitHubHost ".github.com" -PullRequestNumber 99 -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_INVALID_URL*"
    }

    It "rejects PullRequestUrl hosts that are not in the configured allowlist" {
        { Resolve-PullRequestTarget -PullRequestUrl "https://github.com/octo/demo/pull/99" -AllowedGitHubHostsNormalized @("ghes.example.com") -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_INVALID_URL*allowed GitHub host list*"
    }

    It "rejects direct hosts that are not in the configured allowlist" {
        { Resolve-PullRequestTarget -Owner "octo" -Repo "demo" -GitHubHost "github.com" -PullRequestNumber 99 -AllowedGitHubHostsNormalized @("ghes.example.com") -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_INVALID_URL*allowed GitHub host list*"
    }

    It "rejects RFC1918 direct hosts even if allowlisted" {
        { Resolve-PullRequestTarget -Owner "octo" -Repo "demo" -GitHubHost "192.168.1.10" -PullRequestNumber 99 -AllowedGitHubHostsNormalized @("192.168.1.10") -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) } | Should -Throw "*E_INVALID_URL*not allowed for safety reasons*"
    }
}

Describe "Invoke-Main" {
    It "runs the non-interactive happy path and writes json output" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = "explicit-token"
        $OutputFormat = "json"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }
        Mock Get-AuthToken { "auth-token" }
        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Assert-IsHashtableLike { }
        Mock Validate-GitHubTokenForRepoAccess { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Get-UnresolvedReviewThreads {
            @(
                [pscustomobject]@{
                    path               = "src/main.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "hello"
                    latestReplySummary = $null
                }
            )
        }
        Mock Format-UnresolvedThreadsAsJson { '[{"path":"src/main.ts"}]' }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Match "src/main.ts"
        Assert-MockCalled Validate-GitHubTokenForRepoAccess -Times 1 -Scope It -ParameterFilter { $RequestTimeoutSeconds -eq 60 }
    }

    It "uses public REST fallback for PR URL mode with no token and does not prompt" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = $null
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }
        Mock Get-AuthToken { $null }
        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Assert-IsHashtableLike { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Test-CanPromptForLogin { throw "Test-CanPromptForLogin should not be called when REST fallback succeeds." }
        Mock Read-Host { throw "Read-Host should not be called when REST fallback succeeds." }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called without an auth token." }
        Mock Get-PublicPullRequestReviewCommentsFallback {
            @(
                [pscustomobject]@{
                    path               = "src/public.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Public"
                    latestReplySummary = $null
                    resolutionState    = "unknown"
                }
            )
        }

        Mock Format-UnresolvedThreadsAsText { "public fallback" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "public fallback"
        Assert-MockCalled Get-PublicPullRequestReviewCommentsFallback -Times 1 -Scope It
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 0 -Scope It
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }

    It "retries after interactive login when unauthenticated request fails" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @("github.com")
        $PullRequestNumber = 0
        $Token = $null
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($true)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        Mock Get-AuthToken {
            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return $null
            }

            return "interactive-token"
        }

        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Test-CanPromptForLogin { $true }
        Mock Assert-IsHashtableLike { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Validate-GitHubTokenForRepoAccess { }

        Mock Get-PublicPullRequestReviewCommentsFallback {
            throw "E_NOT_FOUND: Public REST fallback could not read this PR"
        }

        $script:reviewCallCount = 0
        Mock Get-UnresolvedReviewThreads {
            $script:reviewCallCount++
            return @(
                [pscustomobject]@{
                    path               = "src/recovered.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Recovered"
                    latestReplySummary = $null
                }
            )
        }

        Mock Read-Host { "y" }
        Mock Format-UnresolvedThreadsAsText { "ok" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:authTokenCallCount | Should -Be 2
        $script:reviewCallCount | Should -Be 1
        $script:lastOutput | Should -Be "ok"
        Assert-MockCalled Validate-GitHubTokenForRepoAccess -Times 1 -Scope It -ParameterFilter {
            $AllowedGitHubHostsNormalized.Count -eq 1 -and $AllowedGitHubHostsNormalized[0] -eq "github.com"
        }
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 1 -Scope It -ParameterFilter {
            $AllowedGitHubHostsNormalized.Count -eq 1 -and $AllowedGitHubHostsNormalized[0] -eq "github.com"
        }
    }

    It "offers login fallback in non-interactive mode when PR URL is provided and credentials are missing" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = $null
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        Mock Get-AuthToken {
            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return $null
            }

            return "interactive-token"
        }

        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Test-CanPromptForLogin { $true }
        Mock Assert-IsHashtableLike { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Validate-GitHubTokenForRepoAccess { }

        Mock Get-PublicPullRequestReviewCommentsFallback {
            throw "E_NOT_FOUND: Public REST fallback could not read this PR"
        }

        $script:reviewCallCount = 0
        Mock Get-UnresolvedReviewThreads {
            $script:reviewCallCount++
            return @(
                [pscustomobject]@{
                    path               = "src/recovered.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Recovered"
                    latestReplySummary = $null
                }
            )
        }

        Mock Read-Host { "y" }
        Mock Format-UnresolvedThreadsAsText { "ok" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:authTokenCallCount | Should -Be 2
        $script:reviewCallCount | Should -Be 1
        $script:lastOutput | Should -Be "ok"
        Assert-MockCalled Read-Host -Times 1 -Scope It
    }

    It "tries stored credentials before prompting when provided credentials are invalid" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = "bad-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        Mock Get-AuthToken {
            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return "bad-token"
            }

            return "good-token"
        }

        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Test-CanPromptForLogin { $true }
        Mock Assert-IsHashtableLike { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }

        $script:validateCallCount = 0
        Mock Validate-GitHubTokenForRepoAccess {
            $script:validateCallCount++
            if ($script:validateCallCount -eq 1) {
                throw "E_AUTH_INVALID: Token authentication failed"
            }
        }

        Mock Get-UnresolvedReviewThreads {
            param($Headers)

            if ($null -eq $Headers -or -not $Headers.ContainsKey("Authorization")) {
                throw "E_AUTH_INVALID: Authentication failed"
            }

            @(
                [pscustomobject]@{
                    path               = "src/recovered.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Recovered"
                    latestReplySummary = $null
                }
            )
        }

        Mock Read-Host { "y" }
        Mock Format-UnresolvedThreadsAsText { "ok" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:authTokenCallCount | Should -Be 2
        $script:validateCallCount | Should -Be 2
        $script:lastOutput | Should -Be "ok"
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }

    It "tries stored credentials before public REST fallback when token validation is rate-limited" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = "rate-limited-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        $script:secondCallRejectedTokens = @()
        Mock Get-AuthToken {
            param(
                [string]$ExplicitToken,
                [string]$GitHubHost,
                [switch]$AllowInteractive,
                [switch]$IncludeSourceMetadata,
                [switch]$IgnoreEnvironmentTokens,
                [string[]]$RejectedTokenValues
            )

            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return "rate-limited-token"
            }

            $script:secondCallRejectedTokens = @($RejectedTokenValues)
            return "stored-token"
        }

        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Test-CanPromptForLogin { $true }
        Mock Assert-IsHashtableLike { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }

        $script:validateCallCount = 0
        Mock Validate-GitHubTokenForRepoAccess {
            $script:validateCallCount++
            if ($script:validateCallCount -eq 1) {
                throw "E_AUTH_RATE_LIMITED: Token validation was rate-limited"
            }
        }

        Mock Get-UnresolvedReviewThreads {
            @(
                [pscustomobject]@{
                    path               = "src/recovered.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Recovered"
                    latestReplySummary = $null
                }
            )
        }

        Mock Get-PublicPullRequestReviewCommentsFallback { throw "REST fallback should not be called when stored credentials recover." }
        Mock Read-Host { throw "Read-Host should not be called when stored credentials recover." }
        Mock Format-UnresolvedThreadsAsText { "rate-limit recovered" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "rate-limit recovered"
        $script:authTokenCallCount | Should -Be 2
        $script:validateCallCount | Should -Be 2
        $script:secondCallRejectedTokens | Should -Contain "rate-limited-token"
        Assert-MockCalled Get-PublicPullRequestReviewCommentsFallback -Times 0 -Scope It
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }

    It "passes rejected-token exclusions to stored credential retry" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = $null
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        $script:secondCallRejectedTokens = @()
        $script:secondCallIgnoredEnvironmentTokens = $false
        $script:firstCallAllowInteractive = $null
        Mock Get-AuthToken {
            param(
                [string]$ExplicitToken,
                [string]$GitHubHost,
                [switch]$AllowInteractive,
                [switch]$IncludeSourceMetadata,
                [switch]$IgnoreEnvironmentTokens,
                [string[]]$RejectedTokenValues
            )

            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                $script:firstCallAllowInteractive = $AllowInteractive.IsPresent
                return [pscustomobject]@{
                    Token               = "bad-env-token"
                    Source              = "GH_TOKEN"
                    SourceCategory      = "environment"
                    EnvironmentVariable = "GH_TOKEN"
                }
            }

            $script:secondCallRejectedTokens = @($RejectedTokenValues)
            $script:secondCallIgnoredEnvironmentTokens = $IgnoreEnvironmentTokens.IsPresent

            return [pscustomobject]@{
                Token               = "fresh-token"
                Source              = "gh"
                SourceCategory      = "gh"
                EnvironmentVariable = $null
            }
        }

        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Test-CanPromptForLogin { $true }
        Mock Assert-IsHashtableLike { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }

        $script:validateCallCount = 0
        Mock Validate-GitHubTokenForRepoAccess {
            $script:validateCallCount++
            if ($script:validateCallCount -eq 1) {
                throw "E_AUTH_INVALID: Token authentication failed"
            }
        }

        $script:reviewCallCount = 0
        Mock Get-UnresolvedReviewThreads {
            param($Headers)

            $script:reviewCallCount++
            if ($null -eq $Headers -or -not $Headers.ContainsKey("Authorization")) {
                throw "E_AUTH_INVALID: Missing authorization header after stored credential retry"
            }

            return @(
                [pscustomobject]@{
                    path               = "src/recovered.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Recovered"
                    latestReplySummary = $null
                }
            )
        }

        Mock Read-Host { "y" }
        Mock Format-UnresolvedThreadsAsText { "recovered with fresh token" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "recovered with fresh token"
        $script:authTokenCallCount | Should -Be 2
        $script:firstCallAllowInteractive | Should -BeFalse
        $script:validateCallCount | Should -Be 2
        $script:reviewCallCount | Should -Be 1
        $script:secondCallIgnoredEnvironmentTokens | Should -BeTrue
        $script:secondCallRejectedTokens | Should -Contain "bad-env-token"
        Assert-MockCalled Get-AuthToken -Times 1 -Scope It -ParameterFilter { $IgnoreEnvironmentTokens.IsPresent -and $RejectedTokenValues -contains "bad-env-token" }
    }

    It "uses stored credentials in interactive mode before prompting when provided credentials are invalid" {
        $PullRequestUrl = $null
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = "bad-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($true)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        Mock Get-AuthToken {
            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return "bad-token"
            }

            return "good-token"
        }

        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Test-CanPromptForLogin { $true }
        Mock Assert-IsHashtableLike { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }

        $script:validateCallCount = 0
        Mock Validate-GitHubTokenForRepoAccess {
            $script:validateCallCount++
            if ($script:validateCallCount -eq 1) {
                throw "E_AUTH_INVALID: Token authentication failed"
            }
        }

        Mock Get-UnresolvedReviewThreads {
            param($Headers)

            if ($null -eq $Headers -or -not $Headers.ContainsKey("Authorization")) {
                throw "E_AUTH_INVALID: Authentication failed"
            }

            @(
                [pscustomobject]@{
                    path               = "src/recovered.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Recovered"
                    latestReplySummary = $null
                }
            )
        }

        Mock Read-Host { "y" }
        Mock Format-UnresolvedThreadsAsText { "interactive recovered" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "interactive recovered"
        $script:authTokenCallCount | Should -Be 2
        $script:validateCallCount | Should -Be 2
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }

    It "fails fast in direct owner/repo mode when an explicit token is invalid" {
        $PullRequestUrl = $null
        $Owner = "org"
        $Repo = "repo"
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 5
        $Token = "bad-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        Mock Get-AuthToken { "bad-token" }
        Mock Assert-IsHashtableLike { }
        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Validate-GitHubTokenForRepoAccess { throw "E_AUTH_INVALID: Token authentication failed" }
        Mock Test-CanPromptForLogin { $true }
        Mock Read-Host { throw "Read-Host should not be called in direct mode auth failure." }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called when token validation fails." }
        Mock Get-PublicPullRequestReviewCommentsFallback { throw "Public REST fallback should not be called when an explicit token fails in direct mode." }

        { Invoke-Main } | Should -Throw "*E_AUTH_INVALID*"
        Assert-MockCalled Get-GitHubHeaders -Times 1 -Scope It -ParameterFilter { $AuthToken -eq "bad-token" }
        Assert-MockCalled Get-GitHubHeaders -Times 1 -Scope It -ParameterFilter { [string]::IsNullOrWhiteSpace($AuthToken) }
        Assert-MockCalled Read-Host -Times 0 -Scope It
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 0 -Scope It
        Assert-MockCalled Get-PublicPullRequestReviewCommentsFallback -Times 0 -Scope It
    }

    It "uses public REST fallback in direct owner/repo mode after environment-token auth failure" {
        $PullRequestUrl = $null
        $Owner = "org"
        $Repo = "repo"
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 5
        $Token = $null
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}
        $script:authTokenCallCount = 0
        $script:storedRetryIgnoredEnvironmentTokens = $false
        $script:storedRetryRejectedTokens = @()

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        Mock Get-AuthToken {
            param(
                [string]$ExplicitToken,
                [string]$GitHubHost,
                [switch]$AllowInteractive,
                [switch]$IncludeSourceMetadata,
                [switch]$IgnoreEnvironmentTokens,
                [string[]]$RejectedTokenValues
            )

            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return [pscustomobject]@{
                    Token               = "bad-env-token"
                    Source              = "GH_TOKEN"
                    SourceCategory      = "environment"
                    EnvironmentVariable = "GH_TOKEN"
                }
            }

            $script:storedRetryIgnoredEnvironmentTokens = $IgnoreEnvironmentTokens.IsPresent
            $script:storedRetryRejectedTokens = @($RejectedTokenValues)

            [pscustomobject]@{
                Token               = $null
                Source              = "none"
                SourceCategory      = "none"
                EnvironmentVariable = $null
            }
        }
        Mock Assert-IsHashtableLike { }
        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Validate-GitHubTokenForRepoAccess { throw "E_AUTH_INVALID: Token authentication failed" }
        Mock Test-CanPromptForLogin { $true }
        Mock Read-Host { throw "Read-Host should not be called in direct mode auth failure." }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called when token validation fails." }
        Mock Get-PublicPullRequestReviewCommentsFallback {
            @(
                [pscustomobject]@{
                    path               = "src/public.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Public"
                    latestReplySummary = $null
                    resolutionState    = "unknown"
                }
            )
        }

        Mock Format-UnresolvedThreadsAsText { "direct public fallback" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "direct public fallback"
        $script:authTokenCallCount | Should -Be 2
        $script:storedRetryIgnoredEnvironmentTokens | Should -BeTrue
        $script:storedRetryRejectedTokens | Should -Contain "bad-env-token"
        Assert-MockCalled Get-PublicPullRequestReviewCommentsFallback -Times 1 -Scope It
        Assert-MockCalled Read-Host -Times 0 -Scope It
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 0 -Scope It
    }

    It "uses public REST fallback for direct-mode environment-token auth rate limits without prompting" {
        $PullRequestUrl = $null
        $Owner = "org"
        $Repo = "repo"
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 5
        $Token = $null
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}
        $script:authTokenCallCount = 0

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        Mock Get-AuthToken {
            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return [pscustomobject]@{
                    Token               = "throttled-env-token"
                    Source              = "GH_TOKEN"
                    SourceCategory      = "environment"
                    EnvironmentVariable = "GH_TOKEN"
                }
            }

            [pscustomobject]@{
                Token               = $null
                Source              = "none"
                SourceCategory      = "none"
                EnvironmentVariable = $null
            }
        }
        Mock Assert-IsHashtableLike { }
        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Validate-GitHubTokenForRepoAccess { throw "E_AUTH_RATE_LIMITED: Token temporarily rate limited" }
        Mock Test-CanPromptForLogin { $true }
        Mock Read-Host { throw "Read-Host should not be called in direct mode auth failure." }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called when token validation fails." }
        Mock Get-PublicPullRequestReviewCommentsFallback {
            @(
                [pscustomobject]@{
                    path               = "src/public.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Public"
                    latestReplySummary = $null
                    resolutionState    = "unknown"
                }
            )
        }

        Mock Format-UnresolvedThreadsAsText { "direct rate-limit fallback" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "direct rate-limit fallback"
        $script:authTokenCallCount | Should -Be 2
        Assert-MockCalled Get-PublicPullRequestReviewCommentsFallback -Times 1 -Scope It
        Assert-MockCalled Read-Host -Times 0 -Scope It
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 0 -Scope It
    }

    It "retries anonymously when token validation fails for PR URL mode" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = "expired-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        Mock Get-AuthToken {
            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return "expired-token"
            }

            return $null
        }
        Mock Assert-IsHashtableLike { }
        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Validate-GitHubTokenForRepoAccess { throw "E_AUTH_INVALID: Token authentication failed" }
        Mock Test-CanPromptForLogin { $false }
        Mock Read-Host { throw "Read-Host should not be called when anonymous fallback succeeds." }

        Mock Get-PublicPullRequestReviewCommentsFallback {
            @(
                [pscustomobject]@{
                    path               = "src/public.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Public"
                    latestReplySummary = $null
                    resolutionState    = "unknown"
                }
            )
        }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called when public REST fallback succeeds." }

        Mock Format-UnresolvedThreadsAsText { "anonymous success" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "anonymous success"
        Assert-MockCalled Get-GitHubHeaders -Times 1 -Scope It -ParameterFilter { $AuthToken -eq "expired-token" }
        Assert-MockCalled Get-GitHubHeaders -Times 1 -Scope It -ParameterFilter { [string]::IsNullOrWhiteSpace($AuthToken) }
        Assert-MockCalled Get-PublicPullRequestReviewCommentsFallback -Times 1 -Scope It
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 0 -Scope It
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }

    It "surfaces non-auth public REST fallback errors even when prompt is available" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = "expired-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        Mock Get-AuthToken {
            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return "expired-token"
            }

            return $null
        }

        Mock Assert-IsHashtableLike { }
        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }

        $script:validateCallCount = 0
        Mock Validate-GitHubTokenForRepoAccess {
            $script:validateCallCount++
            if ($script:validateCallCount -eq 1) {
                throw "E_AUTH_INVALID: Token authentication failed"
            }
        }

        Mock Test-CanPromptForLogin { $true }
        Mock Read-Host { throw "Read-Host should not be called for non-auth REST fallback failures." }

        Mock Get-PublicPullRequestReviewCommentsFallback {
            throw "E_NETWORK_TIMEOUT: Public REST fallback timed out"
        }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called for non-auth REST fallback failures." }

        { Invoke-Main } | Should -Throw "*E_NETWORK_TIMEOUT*Public REST fallback timed out*"
        $script:authTokenCallCount | Should -Be 2
        $script:validateCallCount | Should -Be 1
        Assert-MockCalled Read-Host -Times 0 -Scope It
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 0 -Scope It
    }

    It "surfaces non-auth anonymous retry errors when prompt is unavailable" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = "expired-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        Mock Get-AuthToken {
            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return "expired-token"
            }

            return $null
        }
        Mock Assert-IsHashtableLike { }
        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Validate-GitHubTokenForRepoAccess { throw "E_AUTH_INVALID: Token authentication failed" }
        Mock Test-CanPromptForLogin { $false }
        Mock Read-Host { throw "Read-Host should not be called when interactive prompt is unavailable." }
        Mock Get-PublicPullRequestReviewCommentsFallback { throw "E_NETWORK_TIMEOUT: Public REST fallback timed out" }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called for non-auth REST fallback failures." }

        { Invoke-Main } | Should -Throw "*E_NETWORK_TIMEOUT*"
        $script:authTokenCallCount | Should -Be 2
        Assert-MockCalled Read-Host -Times 0 -Scope It
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 0 -Scope It
    }

    It "redacts original token in anonymous retry errors" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $AllowedGitHubHosts = @()
        $PullRequestNumber = 0
        $Token = "secret-token-12345"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        $script:authTokenCallCount = 0
        Mock Get-AuthToken {
            $script:authTokenCallCount++
            if ($script:authTokenCallCount -eq 1) {
                return "secret-token-12345"
            }

            return $null
        }
        Mock Assert-IsHashtableLike { }
        Mock Get-GitHubHeaders {
            param($AuthToken)

            $headers = @{ "Accept" = "application/json" }
            if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
                $headers["Authorization"] = "Bearer $AuthToken"
            }

            return $headers
        }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Validate-GitHubTokenForRepoAccess { throw "E_AUTH_INVALID: Token secret-token-12345 is invalid" }
        Mock Test-CanPromptForLogin { $false }
        Mock Read-Host { throw "Read-Host should not be called when interactive prompt is unavailable." }
        Mock Get-PublicPullRequestReviewCommentsFallback { throw "E_NETWORK_TIMEOUT: leaked secret-token-12345" }

        $thrownMessage = $null
        try {
            Invoke-Main
        }
        catch {
            $thrownMessage = $_.Exception.Message
        }

        $thrownMessage | Should -Match "E_NETWORK_TIMEOUT"
        $thrownMessage | Should -Not -Match [regex]::Escape("secret-token-12345")
        $thrownMessage | Should -Match "\*\*\*REDACTED\*\*\*"
    }

    It "fails with E_AUTH_REQUIRED when fallback prompt is unavailable due redirected IO" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $PullRequestNumber = 0
        $Token = $null
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }

        Mock Get-AuthToken { $null }
        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Assert-IsHashtableLike { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Test-CanPromptForLogin { $false }
        Mock Get-PublicPullRequestReviewCommentsFallback { throw "E_NOT_FOUND: Public REST fallback could not read this PR" }
        Mock Read-Host { "y" }

        { Invoke-Main } | Should -Throw "*E_AUTH_REQUIRED*"
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }

    It "copies output when Copy is set and still writes to stdout" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $PullRequestNumber = 0
        $Token = "explicit-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $Truncate = [System.Management.Automation.SwitchParameter]::new($false)
        $Copy = [System.Management.Automation.SwitchParameter]::new($true)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }
        Mock Get-AuthToken { "auth-token" }
        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Assert-IsHashtableLike { }
        Mock Validate-GitHubTokenForRepoAccess { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Get-UnresolvedReviewThreads {
            @(
                [pscustomobject]@{
                    path               = "src/a.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "x"
                    latestReplySummary = $null
                }
            )
        }
        Mock Format-UnresolvedThreadsAsText { "copied output" }
        Mock Copy-ToClipboard { $true }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "copied output"
        Assert-MockCalled Copy-ToClipboard -Times 1 -Scope It -ParameterFilter { $Text -eq "copied output" }
    }

    It "writes stdout output even when copy fails" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $PullRequestNumber = 0
        $Token = "explicit-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $Truncate = [System.Management.Automation.SwitchParameter]::new($false)
        $Copy = [System.Management.Automation.SwitchParameter]::new($true)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }
        Mock Get-AuthToken { "auth-token" }
        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Assert-IsHashtableLike { }
        Mock Validate-GitHubTokenForRepoAccess { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Get-UnresolvedReviewThreads {
            @(
                [pscustomobject]@{
                    path               = "src/a.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "x"
                    latestReplySummary = $null
                }
            )
        }
        Mock Format-UnresolvedThreadsAsText { "still output" }
        Mock Copy-ToClipboard { $false }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "still output"
        Assert-MockCalled Copy-ToClipboard -Times 1 -Scope It
        Assert-MockCalled Write-Output -Times 1 -Scope It -ParameterFilter { $InputObject -eq "still output" }
    }

    It "writes no-unresolved message when review thread retrieval returns zero objects" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $PullRequestNumber = 0
        $Token = "explicit-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $Truncate = [System.Management.Automation.SwitchParameter]::new($false)
        $Copy = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }
        Mock Get-AuthToken { "auth-token" }
        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Assert-IsHashtableLike { }
        Mock Validate-GitHubTokenForRepoAccess { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Get-UnresolvedReviewThreads { @() }

        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "No unresolved review threads found."
    }

    It "fails fast when CopyStrict is set without Copy" {
        $Copy = [System.Management.Automation.SwitchParameter]::new($false)
        $CopyStrict = [System.Management.Automation.SwitchParameter]::new($true)

        { Invoke-Main } | Should -Throw "*E_CONFIG_ERROR*-CopyStrict requires -Copy*"
    }

    It "throws E_CLIPBOARD_COPY_FAILED when CopyStrict is set and copy fails" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $PullRequestNumber = 0
        $Token = "explicit-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $Truncate = [System.Management.Automation.SwitchParameter]::new($false)
        $Copy = [System.Management.Automation.SwitchParameter]::new($true)
        $CopyStrict = [System.Management.Automation.SwitchParameter]::new($true)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }
        Mock Get-AuthToken { "auth-token" }
        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Assert-IsHashtableLike { }
        Mock Validate-GitHubTokenForRepoAccess { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Get-UnresolvedReviewThreads {
            @(
                [pscustomobject]@{
                    path               = "src/a.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "x"
                    latestReplySummary = $null
                }
            )
        }
        Mock Format-UnresolvedThreadsAsText { "strict output" }
        Mock Copy-ToClipboard { $false }

        { Invoke-Main } | Should -Throw "*E_CLIPBOARD_COPY_FAILED*"
    }

    It "writes output file when OutputPath is provided and still writes stdout" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $PullRequestNumber = 0
        $Token = "explicit-token"
        $OutputFormat = "text"
        $OutputPath = Join-Path -Path $TestDrive -ChildPath "artifacts/out.txt"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $Truncate = [System.Management.Automation.SwitchParameter]::new($false)
        $Copy = [System.Management.Automation.SwitchParameter]::new($false)
        $CopyStrict = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{ "OutputPath" = $OutputPath }

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }
        Mock Get-AuthToken { "auth-token" }
        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Assert-IsHashtableLike { }
        Mock Validate-GitHubTokenForRepoAccess { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Get-UnresolvedReviewThreads {
            @(
                [pscustomobject]@{
                    path               = "src/a.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "x"
                    latestReplySummary = $null
                }
            )
        }
        Mock Format-UnresolvedThreadsAsText { "file output" }
        Mock Write-RenderedOutputToFile { $OutputPath }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        Assert-MockCalled Write-RenderedOutputToFile -Times 1 -Scope It -ParameterFilter { $OutputPath -eq (Join-Path -Path $TestDrive -ChildPath "artifacts/out.txt") -and $Text -eq "file output" }
        $script:lastOutput | Should -Be "file output"
    }

    It "threads Truncate through unresolved thread retrieval" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
        $PullRequestNumber = 0
        $Token = "explicit-token"
        $OutputFormat = "text"
        $Interactive = [System.Management.Automation.SwitchParameter]::new($false)
        $WaitOnRateLimit = [System.Management.Automation.SwitchParameter]::new($false)
        $Truncate = [System.Management.Automation.SwitchParameter]::new($true)
        $Copy = [System.Management.Automation.SwitchParameter]::new($false)
        $PerPage = 100
        $MaxPages = 100
        $RequestTimeoutSeconds = 60
        $OverallTimeoutSeconds = 300
        $script:TopLevelBoundParameters = @{}

        Mock Resolve-PullRequestTarget {
            [pscustomobject]@{
                Host              = "github.com"
                Owner             = "org"
                Repo              = "repo"
                PullRequestNumber = 5
            }
        }
        Mock Get-AuthToken { "auth-token" }
        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Assert-IsHashtableLike { }
        Mock Validate-GitHubTokenForRepoAccess { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Get-UnresolvedReviewThreads {
            @(
                [pscustomobject]@{
                    path               = "src/a.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "x"
                    latestReplySummary = $null
                }
            )
        }
        Mock Format-UnresolvedThreadsAsText { "ok" }
        Mock Write-Output { }

        Invoke-Main

        Assert-MockCalled Get-UnresolvedReviewThreads -Times 1 -Scope It -ParameterFilter { $Truncate.IsPresent }
    }
}

Describe "Strict-mode collection shape safety" {
    It "normalizes analyzer-like output for <CaseLabel>" -ForEach @(
        @{
            CaseLabel     = "null output"
            InputValue    = $null
            ExpectedCount = 0
        },
        @{
            CaseLabel     = "single object output"
            InputValue    = [pscustomobject]@{ RuleName = "RuleA" }
            ExpectedCount = 1
        },
        @{
            CaseLabel     = "multiple object output"
            InputValue    = @(
                [pscustomobject]@{ RuleName = "RuleA" },
                [pscustomobject]@{ RuleName = "RuleB" }
            )
            ExpectedCount = 2
        }
    ) {
        param($CaseLabel, $InputValue, $ExpectedCount)

        $normalized = if ($null -eq $InputValue) { @() } else { @($InputValue) }
        ($normalized | Measure-Object).Count | Should -Be $ExpectedCount
    }

    It "documents the @($null) Count pitfall" {
        (@($null)).Count | Should -Be 1
    }
}
