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

    It "sanitizes bearer authorization tokens before constructing headers" {
        $headers = Get-GitHubHeaders -AuthToken "  token`r`n-123  "
        $headers | Should -BeOfType [hashtable]
        $headers["Authorization"] | Should -Be "Bearer token-123"
    }
}

Describe "ConvertTo-SafeHttpHeaderValue" {
    It "returns null for null, empty, or whitespace input" {
        ConvertTo-SafeHttpHeaderValue -Value $null | Should -BeNullOrEmpty
        ConvertTo-SafeHttpHeaderValue -Value "" | Should -BeNullOrEmpty
        ConvertTo-SafeHttpHeaderValue -Value "   " | Should -BeNullOrEmpty
    }

    It "trims surrounding whitespace while preserving the interior value" {
        ConvertTo-SafeHttpHeaderValue -Value "   user_session=abc123  " | Should -Be "user_session=abc123"
    }

    It "strips embedded CR and LF (the header-injection / response-splitting vector)" {
        # A smuggled CR/LF would let the value inject additional request headers.
        ConvertTo-SafeHttpHeaderValue -Value "abc`r`nX-Injected: evil" | Should -Be "abcX-Injected: evil"
        ConvertTo-SafeHttpHeaderValue -Value "a`rb`nc" | Should -Be "abc"
    }

    It "strips other control characters that are never valid in a header value" {
        # Tab, NUL, vertical tab, form feed, escape, and DEL must not survive into a header. Build the
        # string with [char] casts so the literal stays parseable on Windows PowerShell 5.1 (the `u{}
        # escape is PowerShell 7+ only).
        $value = "a" + [char]0x09 + "b" + [char]0x00 + "c" + [char]0x0B + "d" + [char]0x0C + "e" + [char]0x1B + "f" + [char]0x7F + "g"
        ConvertTo-SafeHttpHeaderValue -Value $value | Should -Be "abcdefg"
    }

    It "preserves ordinary printable token and cookie characters" {
        $value = "gho_AbC123-._~+/=; path=/; SameSite=Lax"
        ConvertTo-SafeHttpHeaderValue -Value $value | Should -Be $value
    }

    It "returns null when the value is only control characters" {
        ConvertTo-SafeHttpHeaderValue -Value "`r`n`t`0" | Should -BeNullOrEmpty
    }
}

Describe "Get-GitHubWebCookie sanitization" {
    It "sanitizes an explicitly provided cookie (strips CR/LF and trims)" {
        Get-GitHubWebCookie -ExplicitCookie "  user_session=abc`r`n  " | Should -Be "user_session=abc"
    }

    It "falls back to environment variables and sanitizes them" {
        $previousWallstop = $env:WALLSTOP_GITHUB_WEB_COOKIE
        $previousGeneric = $env:GITHUB_WEB_COOKIE
        try {
            $env:WALLSTOP_GITHUB_WEB_COOKIE = "session=fromenv`r`ninjected"
            $env:GITHUB_WEB_COOKIE = $null
            Get-GitHubWebCookie | Should -Be "session=fromenvinjected"
        }
        finally {
            $env:WALLSTOP_GITHUB_WEB_COOKIE = $previousWallstop
            $env:GITHUB_WEB_COOKIE = $previousGeneric
        }
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

Describe "FastExit process termination (end-to-end)" {
    BeforeAll {
        $script:feIsUnix = -not (Test-IsWindowsPlatform)
        $script:feScript = Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
    }

    BeforeEach {
        $script:feDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("fastexit-" + [Guid]::NewGuid().ToString("N"))
        [void][System.IO.Directory]::CreateDirectory($script:feDir)
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:feDir) {
            Remove-Item -LiteralPath $script:feDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "skips the slow managed teardown while preserving exit code and full output" {
        if (-not $script:feIsUnix) { Set-ItResult -Skipped -Because "the libc fast-exit path is Unix-only; Windows uses [Environment]::Exit."; return }

        $pwshExe = $null
        try {
            $candidate = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) { $pwshExe = $candidate }
        }
        catch { $pwshExe = $null }
        if ($null -eq $pwshExe) {
            $homeCandidate = Join-Path -Path $PSHOME -ChildPath "pwsh"
            if (Test-Path -LiteralPath $homeCandidate) { $pwshExe = $homeCandidate }
        }
        if ($null -eq $pwshExe) { Set-ItResult -Skipped -Because "could not resolve a launchable pwsh host."; return }

        # Inner script: dot-source the real script, then drive the fast-exit path the way the run
        # guard does (large output, marker as the last managed write, then Invoke-FastProcessExit).
        $marker = Join-Path -Path $script:feDir -ChildPath "marker.txt"
        $inner = @"
. '$($script:feScript)' -NoRun
1..2000 | ForEach-Object { Write-Output "line-`$_" }
[System.IO.File]::WriteAllText('$marker', [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString())
Invoke-FastProcessExit -ExitCode 7
"@
        $innerFile = Join-Path -Path $script:feDir -ChildPath "inner.ps1"
        [System.IO.File]::WriteAllText($innerFile, $inner, [System.Text.UTF8Encoding]::new($false))

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = [string]$pwshExe
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("-NoProfile", "-NoLogo", "-File", $innerFile)

        $proc = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        [void]$proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit(60000)
        [void]$stdoutTask.Wait(5000)

        try {
            $exited | Should -BeTrue -Because "the fast-exit must terminate the process promptly"
            $proc.ExitCode | Should -Be 7 -Because "the requested exit code must be preserved by the fast exit"
            $stdout = [string]$stdoutTask.Result
            ($stdout -split "`n" | Where-Object { $_ -match '^line-\d+' }).Count | Should -Be 2000 -Because "all buffered output must be flushed before the fast exit (no truncation)"
            $stdout | Should -Not -Match "Killed" -Because "a clean libc _exit must not raise a SIGKILL 'Killed' message"
        }
        finally {
            if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
            $proc.Dispose()
        }
    }

    It "does not truncate a large payload before the fast exit" {
        if (-not $script:feIsUnix) { Set-ItResult -Skipped -Because "the libc fast-exit path is Unix-only; Windows uses [Environment]::Exit."; return }

        $pwshExe = $null
        try {
            $candidate = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) { $pwshExe = $candidate }
        }
        catch { $pwshExe = $null }
        if ($null -eq $pwshExe) {
            $homeCandidate = Join-Path -Path $PSHOME -ChildPath "pwsh"
            if (Test-Path -LiteralPath $homeCandidate) { $pwshExe = $homeCandidate }
        }
        if ($null -eq $pwshExe) { Set-ItResult -Skipped -Because "could not resolve a launchable pwsh host."; return }

        # A ~2.5 MB payload (25000 lines) far exceeds any OS pipe / console buffer, so this proves
        # the run-guard flush commits all rendered output before the immediate termination. This is
        # the permanent regression guard against fast-exit truncating large output.
        $lineCount = 25000
        $inner = @"
. '$($script:feScript)' -NoRun
`$sb = [System.Text.StringBuilder]::new()
for (`$i = 1; `$i -le $lineCount; `$i++) { [void]`$sb.AppendLine(('{0:D6}:' -f `$i) + ('x' * 80)) }
Write-Output `$sb.ToString().TrimEnd("``n", "``r")
Invoke-FastProcessExit -ExitCode 0
"@
        $innerFile = Join-Path -Path $script:feDir -ChildPath "big.ps1"
        [System.IO.File]::WriteAllText($innerFile, $inner, [System.Text.UTF8Encoding]::new($false))

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = [string]$pwshExe
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("-NoProfile", "-NoLogo", "-File", $innerFile)

        $proc = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        [void]$proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit(60000)
        [void]$stdoutTask.Wait(10000)

        try {
            $exited | Should -BeTrue
            $proc.ExitCode | Should -Be 0
            $stdout = [string]$stdoutTask.Result
            $matched = [regex]::Matches($stdout, '(?m)^\d{6}:')
            $matched.Count | Should -Be $lineCount -Because "every rendered line must survive the fast exit even for a multi-megabyte payload"
            $stdout | Should -Match ("(?m)^{0:D6}:" -f $lineCount) -Because "the final line must be present (no tail truncation)"
        }
        finally {
            if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
            $proc.Dispose()
        }
    }
}

Describe "Terminal restoration across exit (end-to-end PTY)" {
    BeforeAll {
        $script:ptyIsUnix = -not (Test-IsWindowsPlatform)
        $script:ptyScript = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1")).Path
        $script:ptyPython = $null
        foreach ($candidate in @("python3", "python")) {
            $resolved = Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $resolved -and -not [string]::IsNullOrWhiteSpace([string]$resolved.Source)) {
                $script:ptyPython = [string]$resolved.Source
                break
            }
        }
        $script:ptyPwsh = $null
        try {
            $candidate = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) { $script:ptyPwsh = $candidate }
        }
        catch { $script:ptyPwsh = $null }
        if ($null -eq $script:ptyPwsh) {
            $homeCandidate = Join-Path -Path $PSHOME -ChildPath "pwsh"
            if (Test-Path -LiteralPath $homeCandidate) { $script:ptyPwsh = $homeCandidate }
        }

        # Drives `pwsh -File <inner>` attached to a real pseudo-terminal, feeds it a line, lets it exit,
        # and reports the slave TTY's ECHO/ICANON flags afterward. This is the only test that proves the
        # actual user-visible contract end to end: after the script reads a prompt and the process exits,
        # the parent terminal must NOT be left with echo/line-editing disabled ("input stops on shell").
        # Defined in BeforeAll so it is in scope for the run-phase It bodies (Pester v5 scoping).
        function Invoke-PtyTerminalProbe {
            param([string]$InnerScriptBody, [string]$Feed)

            $innerFile = Join-Path -Path $script:ptyDir -ChildPath ("inner-" + [Guid]::NewGuid().ToString("N") + ".ps1")
            [System.IO.File]::WriteAllText($innerFile, $InnerScriptBody, [System.Text.UTF8Encoding]::new($false))

            $driver = @"
import os, pty, subprocess, select, time, termios, sys
pwsh = sys.argv[1]; inner = sys.argv[2]; feed = sys.argv[3]
m, s = pty.openpty()
proc = subprocess.Popen([pwsh, "-NoProfile", "-NoLogo", "-File", inner], stdin=s, stdout=s, stderr=s, close_fds=True)
time.sleep(0.8)
if feed:
    os.write(m, feed.encode())
end = time.time() + 25
while time.time() < end:
    if proc.poll() is not None:
        break
    r, _, _ = select.select([m], [], [], 0.1)
    if r:
        try: os.read(m, 65536)
        except OSError: break
try: proc.wait(timeout=5)
except subprocess.TimeoutExpired: proc.kill()
attrs = termios.tcgetattr(s)
echo = 1 if (attrs[3] & termios.ECHO) else 0
icanon = 1 if (attrs[3] & termios.ICANON) else 0
os.close(m); os.close(s)
print("ECHO=%d ICANON=%d RC=%s" % (echo, icanon, proc.returncode))
"@
            $driverFile = Join-Path -Path $script:ptyDir -ChildPath ("driver-" + [Guid]::NewGuid().ToString("N") + ".py")
            [System.IO.File]::WriteAllText($driverFile, $driver, [System.Text.UTF8Encoding]::new($false))

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:ptyPython
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @($driverFile, $script:ptyPwsh, $innerFile, $Feed)
            $proc = [System.Diagnostics.Process]::Start($startInfo)
            $out = $proc.StandardOutput.ReadToEndAsync()
            [void]$proc.StandardError.ReadToEndAsync()
            [void]$proc.WaitForExit(40000)
            [void]$out.Wait(5000)
            return [string]$out.Result
        }
    }

    BeforeEach {
        $script:ptyDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("pty-" + [Guid]::NewGuid().ToString("N"))
        [void][System.IO.Directory]::CreateDirectory($script:ptyDir)
    }

    AfterEach {
        if ($script:ptyDir -and (Test-Path -LiteralPath $script:ptyDir)) {
            Remove-Item -LiteralPath $script:ptyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "restores the parent terminal after a run that reads a prompt then takes the gated exit" {
        if (-not $script:ptyIsUnix) { Set-ItResult -Skipped -Because "PTY/termios terminal restoration is a Unix concern"; return }
        if ($null -eq $script:ptyPython) { Set-ItResult -Skipped -Because "python3 (for PTY/termios probing) is unavailable"; return }
        if ($null -eq $script:ptyPwsh) { Set-ItResult -Skipped -Because "could not resolve a launchable pwsh host"; return }

        # Mirror the run guard exactly: read a prompt through the seam (sets the flag), then take the
        # gated exit. Because a read occurred, Test-ShouldUseFastExit must force the managed exit, which
        # restores the terminal. If the gating regressed and libc _exit ran, the TTY would stay raw.
        $inner = @"
. '$($script:ptyScript)' -NoRun
[void](Read-TerminalResponse -Prompt 'GitHub owner')
if (-not `$NoFastExit.IsPresent -and (Test-ShouldUseFastExit)) { Invoke-FastProcessExit -ExitCode 0 } else { exit 0 }
"@
        $result = Invoke-PtyTerminalProbe -InnerScriptBody $inner -Feed "octocat`n"
        $result | Should -Match "ECHO=1 ICANON=1" -Because "a run that read the terminal must restore echo/line-editing on exit (got: $result)"
    }

    It "keeps the terminal sane when a no-read run takes the fast exit" {
        if (-not $script:ptyIsUnix) { Set-ItResult -Skipped -Because "PTY/termios terminal restoration is a Unix concern"; return }
        if ($null -eq $script:ptyPython) { Set-ItResult -Skipped -Because "python3 (for PTY/termios probing) is unavailable"; return }
        if ($null -eq $script:ptyPwsh) { Set-ItResult -Skipped -Because "could not resolve a launchable pwsh host"; return }

        # A run that never reads the console never switches the terminal out of canonical mode, so the
        # fast libc _exit is safe and must leave the TTY untouched.
        $inner = @"
. '$($script:ptyScript)' -NoRun
Write-Output 'no-read'
if (-not `$NoFastExit.IsPresent -and (Test-ShouldUseFastExit)) { Invoke-FastProcessExit -ExitCode 0 } else { exit 0 }
"@
        $result = Invoke-PtyTerminalProbe -InnerScriptBody $inner -Feed ""
        $result | Should -Match "ECHO=1 ICANON=1" -Because "a no-read run must leave the terminal in its default mode (got: $result)"
    }
}

Describe "Terminal-safe interactive read and fast-exit gating" {
    BeforeEach {
        $script:savedTerminalInputInitialized = $script:TerminalInputInitialized
        $script:TerminalInputInitialized = $false
    }

    AfterEach {
        $script:TerminalInputInitialized = $script:savedTerminalInputInitialized
    }

    It "Read-TerminalResponse reads through the canonical [Console]::In seam, never Read-Host" {
        # The whole point of the seam is to avoid Read-Host, which switches the terminal into a raw
        # mode that a non-interactive host never restores, stranding the parent shell's input.
        Mock Read-ConsoleInputLine { "octocat" }
        Mock Read-Host { throw "Read-Host must never be used; it corrupts the parent terminal." }

        $result = Read-TerminalResponse -Prompt "GitHub owner"
        $result | Should -Be "octocat"
        Assert-MockCalled Read-ConsoleInputLine -Times 1 -Scope It
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }

    It "Read-TerminalResponse records that the console input subsystem was initialized" {
        Mock Read-ConsoleInputLine { "value" }
        $script:TerminalInputInitialized | Should -BeFalse

        [void](Read-TerminalResponse -Prompt "Repository")
        $script:TerminalInputInitialized | Should -BeTrue -Because "a terminal read must force the safe managed exit so the terminal is restored"
    }

    It "Test-ShouldUseFastExit returns false after the terminal was read (managed exit restores the tty)" {
        Mock Test-IsInteractiveHostSession { $false }
        $script:TerminalInputInitialized = $true

        Test-ShouldUseFastExit | Should -BeFalse
    }

    It "Test-ShouldUseFastExit returns false in an interactive host even with no terminal read" {
        Mock Test-IsInteractiveHostSession { $true }
        $script:TerminalInputInitialized = $false

        Test-ShouldUseFastExit | Should -BeFalse
    }

    It "Test-ShouldUseFastExit returns true only for a non-interactive run that never read the terminal" {
        Mock Test-IsInteractiveHostSession { $false }
        $script:TerminalInputInitialized = $false

        Test-ShouldUseFastExit | Should -BeTrue
    }

    It "Test-CommandLineIndicatesInteractiveHost treats batch invocations (and their abbreviations) as non-interactive" {
        # PowerShell accepts unambiguous parameter prefixes; every batch form must be recognized so the
        # fast exit is not needlessly suppressed for a real `pwsh -File`/`-Command` automation run.
        foreach ($form in @(
                @("/usr/bin/pwsh.dll", "-NoProfile", "-File", "script.ps1"),
                @("pwsh.dll", "-File", "script.ps1"),
                @("pwsh.dll", "-fi", "script.ps1"),
                @("pwsh.dll", "-f", "script.ps1"),
                @("pwsh.dll", "-Command", "x"),
                @("pwsh.dll", "-com", "x"),
                @("pwsh.dll", "-c", "x"),
                @("pwsh.dll", "-EncodedCommand", "abc"),
                @("pwsh.dll", "-enc", "abc"),
                @("pwsh.dll", "-e", "abc"),
                @("pwsh.dll", "-ec", "abc")
            )) {
            Test-CommandLineIndicatesInteractiveHost -CommandLineArgs $form | Should -BeFalse -Because "batch form [$($form -join ' ')] must be non-interactive"
        }
    }

    It "Test-CommandLineIndicatesInteractiveHost treats a pure REPL or -NoExit as interactive" {
        Test-CommandLineIndicatesInteractiveHost -CommandLineArgs @("pwsh.dll") | Should -BeTrue -Because "a bare REPL has no batch entry"
        Test-CommandLineIndicatesInteractiveHost -CommandLineArgs @("pwsh.dll", "-NoProfile", "-NoLogo") | Should -BeTrue -Because "switches that are not batch entries leave it a REPL"
        Test-CommandLineIndicatesInteractiveHost -CommandLineArgs @("pwsh.dll", "-NoExit", "-File", "script.ps1") | Should -BeTrue -Because "-NoExit keeps the host open after the script"
        Test-CommandLineIndicatesInteractiveHost -CommandLineArgs @("pwsh.dll", "-noe", "-File", "script.ps1") | Should -BeTrue -Because "-noe is an unambiguous -NoExit abbreviation"
        Test-CommandLineIndicatesInteractiveHost -CommandLineArgs @() | Should -BeTrue
    }

    It "Test-CommandLineIndicatesInteractiveHost does not confuse -NoProfile/-NoLogo with -NoExit" {
        # "no"/"n" prefixes are ambiguous; only "noe"+ may mean -NoExit. -NoProfile must NOT force interactive.
        Test-CommandLineIndicatesInteractiveHost -CommandLineArgs @("pwsh.dll", "-NoProfile", "-File", "script.ps1") | Should -BeFalse
        Test-CommandLineIndicatesInteractiveHost -CommandLineArgs @("pwsh.dll", "-nop", "-c", "x") | Should -BeFalse
    }

    It "Test-IsInteractiveHostSession treats a loaded PSReadLine as interactive" {
        # PSReadLine is auto-imported only by interactive hosts and puts the terminal in raw mode, so
        # its presence means a fast exit would strand the user's live session.
        Mock Get-Module { [pscustomobject]@{ Name = "PSReadLine" } } -ParameterFilter { $Name -eq "PSReadLine" }

        Test-IsInteractiveHostSession | Should -BeTrue
    }

    It "Test-IsInteractiveHostSession fails safe (interactive) when host inspection throws" {
        Mock Get-Module { throw "module subsystem unavailable" }

        Test-IsInteractiveHostSession | Should -BeTrue -Because "an undeterminable host must never be fast-exited"
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

Describe "Invoke-FastProcessExit" {
    It "flushes output then terminates with the requested exit code" {
        $script:fastExitCode = $null
        Mock Stop-CurrentProcessImmediately { param($ExitCode) $script:fastExitCode = $ExitCode }

        Invoke-FastProcessExit -ExitCode 0

        Assert-MockCalled Stop-CurrentProcessImmediately -Times 1 -Scope It -ParameterFilter { $ExitCode -eq 0 }
        $script:fastExitCode | Should -Be 0
    }

    It "passes a non-zero exit code through to the terminator" {
        $script:fastExitCode = $null
        Mock Stop-CurrentProcessImmediately { param($ExitCode) $script:fastExitCode = $ExitCode }

        Invoke-FastProcessExit -ExitCode 1

        Assert-MockCalled Stop-CurrentProcessImmediately -Times 1 -Scope It -ParameterFilter { $ExitCode -eq 1 }
        $script:fastExitCode | Should -Be 1
    }

    It "still terminates even if flushing the console throws" {
        $script:fastExitCode = $null
        Mock Stop-CurrentProcessImmediately { param($ExitCode) $script:fastExitCode = $ExitCode }
        Mock Invoke-ConsoleFlush { throw "no console" }

        { Invoke-FastProcessExit -ExitCode 0 } | Should -Not -Throw
        Assert-MockCalled Stop-CurrentProcessImmediately -Times 1 -Scope It
        $script:fastExitCode | Should -Be 0
    }

    It "flushes the console before terminating" {
        $script:order = @()
        Mock Invoke-ConsoleFlush { $script:order += "flush" }
        Mock Stop-CurrentProcessImmediately { param($ExitCode) $script:order += "exit" }

        Invoke-FastProcessExit -ExitCode 0

        ($script:order -join ",") | Should -Be "flush,exit" -Because "buffered output must be committed before the process is terminated"
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

    It "preserves bot comment authors internally and emits plain prose in public JSON" {
        $body = "ToastItem conditionally renders a ReactNode with a truthy check. Use an explicit null/undefined check."
        $thread = [pscustomobject]@{
            id         = "THREAD_BOT_PROSE_RECOMMENDATION"
            isResolved = $false
            path       = "web/src/components/ui/toast.tsx"
            startLine  = 100
            line       = 103
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{
                        body   = $body
                        url    = "https://github.example.test/org/repo/pull/9#discussion_r1"
                        author = [pscustomobject]@{
                            login = "Copilot"
                        }
                    }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"

        $record.topLevelAuthor | Should -Be "Copilot"
        $record.latestReplyAuthor | Should -BeNullOrEmpty
        @($record.suggestions).Count | Should -Be 0
        @($record.recommendations).Count | Should -Be 1
        $record.recommendations[0].kind | Should -Be "comment"
        $record.recommendations[0].authorLogin | Should -Be "Copilot"
        $record.recommendations[0].text | Should -Be $body
        ($null -eq $record.recommendations[0].code) | Should -BeTrue
        $record.recommendations[0].commentIndex | Should -Be 0
        $record.recommendations[0].url | Should -Be "https://github.example.test/org/repo/pull/9#discussion_r1"

        $json = Format-UnresolvedThreadsAsJson -Records @($record)
        $parsed = $json | ConvertFrom-Json
        @($parsed[0].PSObject.Properties.Name) | Should -Not -Contain "recommendations"
        @($parsed[0].PSObject.Properties.Name) | Should -Not -Contain "topLevelAuthor"
        $parsed[0].comments[0].suggestion | Should -Be $body
        @($parsed[0].comments[0].suggestedChanges).Count | Should -Be 0

        $text = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"
        $text | Should -Match "Suggestion:"
        $text | Should -Match ([regex]::Escape($body))
    }

    It "annotates fenced suggestions with their source comment author" {
        $body = @'
Please use the helper here.

```suggestion
return value ?? fallback
```
'@
        $thread = [pscustomobject]@{
            id         = "THREAD_AUTHOR_SUGGESTION"
            isResolved = $false
            path       = "src/value.ts"
            startLine  = 8
            line       = 8
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{
                        body   = $body
                        url    = "https://github.example.test/org/repo/pull/9#discussion_r2"
                        author = [pscustomobject]@{
                            login = "cursor[bot]"
                        }
                    }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"

        @($record.suggestions).Count | Should -Be 1
        $record.suggestions[0].kind | Should -Be "suggestion"
        $record.suggestions[0].code | Should -BeExactly "return value ?? fallback"
        $record.suggestions[0].authorLogin | Should -Be "cursor[bot]"
        $record.suggestions[0].commentIndex | Should -Be 0
        $record.suggestions[0].url | Should -Be "https://github.example.test/org/repo/pull/9#discussion_r2"
        @($record.comments).Count | Should -Be 1
        @($record.comments[0].suggestedChanges).Count | Should -Be 1
        $record.comments[0].suggestedChanges[0].code | Should -BeExactly "return value ?? fallback"
        @($record.recommendations).Count | Should -Be 2
        $record.recommendations[0].kind | Should -Be "comment"
        $record.recommendations[0].authorLogin | Should -Be "cursor[bot]"
        $record.recommendations[1].kind | Should -Be "suggestion"
        $record.recommendations[1].authorLogin | Should -Be "cursor[bot]"
        ($null -eq $record.recommendations[1].text) | Should -BeTrue
        $record.recommendations[1].code | Should -BeExactly "return value ?? fallback"

        $json = Format-UnresolvedThreadsAsJson -Records @($record)
        $parsed = $json | ConvertFrom-Json
        @($parsed[0].PSObject.Properties.Name) | Should -Not -Contain "recommendations"
        @($parsed[0].comments[0].suggestedChanges).Count | Should -Be 1
        $parsed[0].comments[0].suggestedChanges[0].kind | Should -Be "suggestion"
        $parsed[0].comments[0].suggestedChanges[0].value | Should -BeExactly "return value ?? fallback"
    }

    It "renders captured suggestions verbatim without latest-reply chrome" {
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
        $suggestionIndex | Should -BeGreaterThan -1
        $normalized | Should -Not -Match "Latest reply summary:"
    }

    It "does not render placeholder prose for suggestion-only comments" {
        $body = @'
```suggestion
return 1
```
'@
        $thread = [pscustomobject]@{
            id         = "THREAD_SUGGESTION_ONLY"
            isResolved = $false
            path       = "src/value.ts"
            startLine  = 3
            line       = 3
            comments   = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = $body })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"
        $text = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"

        $text | Should -Match "Suggested change:"
        $text | Should -Match "return 1"
        $text | Should -Not -Match "Suggestion:\n\\(none\\)"

        $json = Format-UnresolvedThreadsAsJson -Records @($record)
        $parsed = @($json | ConvertFrom-JsonCompat -Depth 8)
        $parsed[0].comments[0].suggestion | Should -BeNullOrEmpty
        @($parsed[0].comments[0].suggestedChanges).Count | Should -Be 1
        $parsed[0].comments[0].suggestedChanges[0].value | Should -BeExactly "return 1"
    }

    It "captures a suggestion that appears in a reply, not only the top comment" {
        # Reviewers and bots frequently attach the suggested change as a follow-up reply rather
        # than on the first comment, so suggestion extraction must scan every comment in the thread.
        $topBody = "This value should be validated before use."
        $replyBody = @'
Here is the fix:

```suggestion
MUST_READ_METADATA = True
```
'@
        $thread = [pscustomobject]@{
            id         = "THREAD_REPLY_SUGGESTION"
            isResolved = $false
            path       = "src/driver.py"
            startLine  = 32
            line       = 39
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{ body = $topBody },
                    [pscustomobject]@{ body = $replyBody }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"

        @($record.suggestions).Count | Should -Be 1
        $record.suggestions[0].code | Should -BeExactly 'MUST_READ_METADATA = True'
        # The reply prose is kept (minus the stripped fence); the top comment prose is unchanged.
        $record.topLevelComment | Should -Be "This value should be validated before use."
        $record.latestReplySummary | Should -Not -Match 'suggestion'
        $record.latestReplySummary | Should -Not -Match 'MUST_READ_METADATA'
    }

    It "captures suggestions from multiple comments in thread order" {
        $topBody = @'
First pass.

```suggestion
first = 1
```
'@
        $replyBody = @'
Refined.

```suggestion
second = 2
```
'@
        $thread = [pscustomobject]@{
            id         = "THREAD_MULTI_SUGGESTION"
            isResolved = $false
            path       = "src/multi.py"
            startLine  = 1
            line       = 2
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{ body = $topBody },
                    [pscustomobject]@{ body = $replyBody }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"

        @($record.suggestions).Count | Should -Be 2
        $record.suggestions[0].code | Should -BeExactly 'first = 1'
        $record.suggestions[1].code | Should -BeExactly 'second = 2'
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

Describe "Test-ThreadCommentHasRenderableContent" {
    It "is true for non-empty prose" {
        Test-ThreadCommentHasRenderableContent -Body "Consider trimming the value." | Should -BeTrue
    }

    It "is false for empty, whitespace, null, or the (none) sentinel" {
        Test-ThreadCommentHasRenderableContent -Body $null | Should -BeFalse
        Test-ThreadCommentHasRenderableContent -Body "" | Should -BeFalse
        Test-ThreadCommentHasRenderableContent -Body "   " | Should -BeFalse
        Test-ThreadCommentHasRenderableContent -Body "(none)" | Should -BeFalse
    }

    It "is true when there are extracted suggested changes or attached suggested diffs" {
        Test-ThreadCommentHasRenderableContent -Body $null -SuggestedChangeCount 1 | Should -BeTrue
        Test-ThreadCommentHasRenderableContent -Body "(none)" -SuggestedDiffCount 2 | Should -BeTrue
    }

    It "is false when the only signal is a diffHunk or an unavailable-reason (neither renders publicly)" {
        # diffHunk is review context (internal only) and suggestedDiffsUnavailableReason is an internal
        # web-enrichment routing note; neither is ever rendered, so neither makes a comment renderable.
        Test-ThreadCommentHasRenderableContent -Body "(none)" -SuggestedChangeCount 0 -SuggestedDiffCount 0 | Should -BeFalse
    }
}

Describe "Convert-ReviewThreadToOutputRecord diffHunk-only inclusion" {
    It "does not create a comments[] record for a comment whose only content is a diffHunk" {
        # A review comment with empty prose, no extracted suggestion, and no web-enrichment candidacy,
        # carrying only an internal diffHunk, must NOT become a comments[] entry: diffHunk is never
        # rendered publicly, so the record would be an empty block that also suppresses the
        # topLevelComment/suggestions fallback. (Copilot review feedback, 2026-06.)
        $thread = [pscustomobject]@{
            id         = "THREAD_DIFFHUNK_ONLY"
            isResolved = $false
            path       = "src/main.ts"
            startLine  = 10
            line       = 12
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{
                        body     = "   "
                        diffHunk = "@@ -1,2 +1,3 @@`n old`n+new"
                    }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"
        @($record.comments).Count | Should -Be 0 -Because "a diffHunk-only comment carries no publicly renderable content"
    }

    It "does not emit an empty thread block in text output for a diffHunk-only comment" {
        $thread = [pscustomobject]@{
            id         = "THREAD_DIFFHUNK_ONLY_TEXT"
            isResolved = $false
            path       = "src/main.ts"
            startLine  = 10
            line       = 12
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{
                        body     = "   "
                        diffHunk = "@@ -1,2 +1,3 @@`n old`n+new"
                    }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"
        $text = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"
        $text | Should -Not -Match "(?m)^Suggestion:\s*$" -Because "a skipped diffHunk-only comment must not leave a dangling empty Suggestion header"
        $text | Should -Not -Match "old" -Because "the internal diffHunk must never appear in public text output"
        $text | Should -Not -Match "\+new"
    }

    It "keeps a web-enrichment placeholder record but renders the fallback, never an empty block" {
        # A Copilot comment with empty prose and no inline suggestion still gets a suggestedDiffsUnavailableReason
        # so the record survives for best-effort web suggested-diff enrichment (attached later by id).
        # Until/unless diffs attach, the record is non-renderable: it must NOT emit an empty thread block
        # and must NOT suppress the topLevelComment/suggestions fallback.
        $thread = [pscustomobject]@{
            id         = "THREAD_ENRICH_PLACEHOLDER"
            isResolved = $false
            path       = "src/main.ts"
            startLine  = 10
            line       = 12
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{
                        body       = "   "
                        databaseId = "2468"
                        author     = [pscustomobject]@{ login = "copilot-pull-request-reviewer" }
                    }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"
        @($record.comments).Count | Should -Be 1 -Because "the placeholder must survive for web suggested-diff enrichment by databaseId"
        $record.comments[0].suggestedDiffsUnavailableReason | Should -Be "copilot_suggested_diff_may_be_web_only_or_unavailable"

        $text = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"
        $text | Should -Not -Match "(?m)^Suggestion:\s*$" -Because "a non-renderable placeholder must not leave a dangling empty Suggestion header"

        # POSITIVE assertion that the fallback path actually runs: because the only comment is
        # non-renderable, Format-UnresolvedThreadsAsText must branch on the RENDERABLE count (0) and
        # render the topLevelComment fallback. This line is absent if the branch regresses to the raw
        # comments[] count (which would render nothing and suppress the fallback) -- it is the test that
        # makes the renderableCommentCount change red-green protected.
        $text | Should -Match "(?m)^\(none\)$" -Because "the topLevelComment fallback must render when no comment is renderable"
        @($text -split "`n" | Where-Object { -not [string]::IsNullOrEmpty($_) }).Count | Should -BeGreaterThan 2 -Because "the block must carry fallback content, not just the header and trailer delimiters"

        # Text and JSON must agree: the non-renderable placeholder is omitted from the public JSON comments[].
        $json = Format-UnresolvedThreadsAsJson -Records @($record)
        $parsed = $json | ConvertFrom-Json
        @($parsed[0].comments).Count | Should -Be 0 -Because "JSON must omit the non-renderable placeholder, matching the text fallback"
    }

    It "treats a suggestedDiff with no actual change lines as non-renderable (text and JSON agree)" {
        # Defense in depth: if a change-less diff ever reaches a record, it renders nothing in text, so it
        # must NOT count as renderable (which would emit an empty block) and must be omitted from JSON.
        $record = [pscustomobject]@{
            path            = "src/main.ts"
            lineStart       = 10
            lineEnd         = 12
            comments        = @(
                [pscustomobject]@{
                    commentIndex     = 0
                    body             = $null
                    suggestedChanges = @()
                    suggestedDiffs   = @([pscustomobject]@{ path = "src/main.ts"; diff = "@@ -1,1 +1,1 @@`n unchanged context only" })
                }
            )
            suggestions     = @()
            recommendations = @()
            topLevelComment = "(none)"
        }

        Test-ThreadCommentRecordIsRenderable -Comment $record.comments[0] | Should -BeFalse -Because "a diff with no +/- change lines renders nothing"

        $text = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"
        $text | Should -Not -Match "(?m)^Suggested change:\s*$"
        $text | Should -Not -Match "unchanged context only" -Because "context-only diff lines are never public output"

        $json = Format-UnresolvedThreadsAsJson -Records @($record)
        $parsed = $json | ConvertFrom-Json
        @($parsed[0].comments).Count | Should -Be 0 -Because "JSON omits a comment whose only diff has no change lines"
    }

    It "drops raw unified-diff no-newline metadata while preserving marker-prefixed real source lines" {
        $diff = "@@ -1,2 +1,2 @@`n-old();`n\ No newline at end of file`n+\ No newline at end of file"

        Convert-SuggestedDiffTextToPublicChangeOnlyDiff -Diff $diff |
            Should -BeExactly "-old();`n+\ No newline at end of file"
    }

    It "still creates a record (and keeps the internal diffHunk) when the comment has prose" {
        $thread = [pscustomobject]@{
            id         = "THREAD_PROSE_PLUS_DIFFHUNK"
            isResolved = $false
            path       = "src/main.ts"
            startLine  = 10
            line       = 12
            comments   = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{
                        body     = "Consider trimming the value."
                        diffHunk = "@@ -1,2 +1,3 @@`n old`n+new"
                    }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"
        @($record.comments).Count | Should -Be 1
        $record.comments[0].body | Should -Be "Consider trimming the value."
        $record.comments[0].diffHunk | Should -BeExactly "@@ -1,2 +1,3 @@`n old`n+new"
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
                    [pscustomobject]@{
                        body     = "Top level comment"
                        url      = "https://github.example.test/org/repo/pull/77#discussion_r1"
                        diffHunk = "@@ -1,2 +1,3 @@`n old`n+new"
                    },
                    [pscustomobject]@{
                        body     = "Reply summary"
                        url      = "https://github.example.test/org/repo/pull/77#discussion_r2"
                        diffHunk = "@@ -8,2 +8,3 @@`n context`n+reply"
                    }
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
        ($propertyNames -ccontains "comments") | Should -BeTrue
        ($propertyNames -ccontains "suggestions") | Should -BeTrue
        ($propertyNames -ccontains "recommendations") | Should -BeTrue
        ($propertyNames -ccontains "topLevelAuthor") | Should -BeTrue
        ($propertyNames -ccontains "latestReplyAuthor") | Should -BeTrue
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
        @($record.comments).Count | Should -Be 2
        $record.comments[0].commentIndex | Should -Be 0
        $record.comments[0].body | Should -Be "Top level comment"
        $record.comments[0].diffHunk | Should -BeExactly "@@ -1,2 +1,3 @@`n old`n+new"
        @($record.comments[0].suggestedChanges).Count | Should -Be 0
        $record.comments[0].url | Should -Be "https://github.example.test/org/repo/pull/77#discussion_r1"
        $record.comments[1].commentIndex | Should -Be 1
        $record.comments[1].body | Should -Be "Reply summary"
        $record.comments[1].diffHunk | Should -BeExactly "@@ -8,2 +8,3 @@`n context`n+reply"
        @($record.comments[1].suggestedChanges).Count | Should -Be 0
        @($record.recommendations).Count | Should -Be 2
        $record.recommendations[0].kind | Should -Be "comment"
        $record.recommendations[1].text | Should -Be "Reply summary"
        $record.topLevelAuthor | Should -BeNullOrEmpty
        $record.latestReplyAuthor | Should -BeNullOrEmpty
        $record.topLevelComment | Should -Be "Top level comment"
        $record.latestReplySummary | Should -Be "Reply summary"
        $record.resolutionState | Should -Be "unresolved"
        $record.threadId | Should -Be "THREAD_1"
        $record.owner | Should -Be "org"
        $record.repo | Should -Be "repo"
        $record.url | Should -Be "https://github.com/org/repo/pull/77"
    }

    It "uses original lines for outdated Copilot suggested changeset threads" {
        $thread = [pscustomobject]@{
            id                = "THREAD_OUTDATED_COPILOT_CHANGESET"
            isResolved        = $false
            isOutdated        = $true
            path              = "web/src/test/dom-assertions.ts"
            startLine         = 34
            line              = 45
            originalStartLine = 34
            originalLine      = 37
            comments          = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{
                        body     = "`expectAriaReferencesToExist` accepts a `root` parameter but resolves referenced ids via the global `document`. Use the element's `ownerDocument` for the lookup."
                        diffHunk = "@@ -10,3 +10,38 @@ export function requireElement<T extends Element>(`n+        expect(`n+          document.getElementById(id),`n+        ).not.toBeNull();"
                        author   = [pscustomobject]@{ login = "copilot-pull-request-reviewer" }
                    }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 86 -GitHubHost "github.com"

        $record.lineStart | Should -Be 34
        $record.lineEnd | Should -Be 37
        $record.githubLineStart | Should -Be 34
        $record.githubLineEnd | Should -Be 45
        $record.comments[0].suggestedDiffsUnavailable | Should -BeTrue
        $record.comments[0].suggestedDiffsUnavailableReason | Should -Be "copilot_suggested_diff_may_be_web_only_or_unavailable"

        $text = Format-UnresolvedThreadsAsText -Records @($record)
        $text | Should -Match "\(web/src/test/dom-assertions\.ts\) 34-37"
        $text | Should -Not -Match "Suggested change:"
        $text | Should -Not -Match "copilot_suggested_diff_may_be_web_only_or_unavailable"
        $text | Should -Not -Match "ownerDocument\.getElementById"
        $text | Should -Not -Match "Review context diff hunk:"
        $text | Should -Not -Match "document\.getElementById\(id\),"
    }

    It "extracts GitHub web automated suggestions without review context lines" {
        $html = @'
<script type="application/json" data-target="react-partial.embeddedData">{"props":{"comment":{"databaseId":3424230049,"automatedComment":{"suggestion":{"diffEntries":[{"path":"web/src/test/dom-assertions.ts","diffLines":[{"type":"HUNK","text":"@@ -34,7 +34,7 @@"},{"type":"CONTEXT","text":"        expect("},{"type":"DELETION","text":"          document.getElementById(id),"},{"type":"ADDITION","text":"          element.ownerDocument.getElementById(id),"},{"type":"CONTEXT","text":"        ).not.toBeNull();"}]}]}}}}}</script>
'@

        $suggestionsByCommentId = Get-GitHubWebAutomatedSuggestedDiffsByCommentIdFromHtml -Html $html

        $suggestionsByCommentId.ContainsKey("3424230049") | Should -BeTrue
        @($suggestionsByCommentId["3424230049"]).Count | Should -Be 1
        $suggestionsByCommentId["3424230049"][0].kind | Should -Be "changedLines"
        $suggestionsByCommentId["3424230049"][0].path | Should -Be "web/src/test/dom-assertions.ts"
        $suggestionsByCommentId["3424230049"][0].diff | Should -BeExactly "-          document.getElementById(id),`n+          element.ownerDocument.getElementById(id),"
        $suggestionsByCommentId["3424230049"][0].diff | Should -Not -Match "@@|expect\(|not\.toBeNull"
    }

    It "drops unified-diff no-newline metadata from GitHub web automated changed lines" {
        $html = @'
<script type="application/json" data-target="react-partial.embeddedData">{"props":{"comment":{"databaseId":42,"automatedComment":{"suggestion":{"diffEntries":[{"path":"src/file.ts","diffLines":[{"type":"DELETION","text":"old();\n\\ No newline at end of file"},{"type":"ADDITION","text":"new();\n\\ No newline at end of file"}]}]}}}}}</script>
'@

        $suggestionsByCommentId = Get-GitHubWebAutomatedSuggestedDiffsByCommentIdFromHtml -Html $html

        $suggestionsByCommentId.ContainsKey("42") | Should -BeTrue
        $suggestionsByCommentId["42"][0].diff | Should -BeExactly "-old();`n+new();"
        $suggestionsByCommentId["42"][0].diff | Should -Not -Match "No newline at end of file"
    }

    It "prefers explicit GitHub web cookie over environment fallback" {
        $previousWallstopCookie = $env:WALLSTOP_GITHUB_WEB_COOKIE
        $previousGitHubCookie = $env:GITHUB_WEB_COOKIE
        try {
            $env:WALLSTOP_GITHUB_WEB_COOKIE = "wallstop-cookie"
            $env:GITHUB_WEB_COOKIE = "github-cookie"

            Get-GitHubWebCookie -ExplicitCookie "explicit-cookie" | Should -Be "explicit-cookie"
            Get-GitHubWebCookie | Should -Be "wallstop-cookie"
            $env:WALLSTOP_GITHUB_WEB_COOKIE = $null
            Get-GitHubWebCookie | Should -Be "github-cookie"
        }
        finally {
            $env:WALLSTOP_GITHUB_WEB_COOKIE = $previousWallstopCookie
            $env:GITHUB_WEB_COOKIE = $previousGitHubCookie
        }
    }

    It "sanitizes GitHub web cookies before they are used as header values" {
        $previousWallstopCookie = $env:WALLSTOP_GITHUB_WEB_COOKIE
        $previousGitHubCookie = $env:GITHUB_WEB_COOKIE
        try {
            $env:WALLSTOP_GITHUB_WEB_COOKIE = "  wallstop`r`n-cookie  "
            $env:GITHUB_WEB_COOKIE = "github-cookie"

            Get-GitHubWebCookie -ExplicitCookie "  explicit`r`n-cookie  " | Should -Be "explicit-cookie"
            Get-GitHubWebCookie | Should -Be "wallstop-cookie"

            $env:WALLSTOP_GITHUB_WEB_COOKIE = " `r`n "
            $env:GITHUB_WEB_COOKIE = "  github`n-cookie  "
            Get-GitHubWebCookie | Should -Be "github-cookie"
        }
        finally {
            $env:WALLSTOP_GITHUB_WEB_COOKIE = $previousWallstopCookie
            $env:GITHUB_WEB_COOKIE = $previousGitHubCookie
        }
    }

    It "sends optional GitHub web cookie only to the web changeset request" {
        $script:capturedWebHeaders = $null
        $script:webSessionParameterWasBound = $null
        Mock Invoke-WebRequest {
            param(
                [string]$Method,
                [string]$Uri,
                [hashtable]$Headers,
                [int]$TimeoutSec,
                [switch]$UseBasicParsing,
                $WebSession
            )

            $script:capturedWebHeaders = $Headers
            $script:webSessionParameterWasBound = $PSBoundParameters.ContainsKey("WebSession")
            return [pscustomobject]@{
                Content = '<script type="application/json" data-target="react-partial.embeddedData">{"props":{}}</script>'
            }
        }

        $result = Get-GitHubWebAutomatedSuggestedDiffsByCommentId -Owner "org" -Repo "repo" -PrNumber 86 -GitHubHost "github.com" -RequestTimeoutSeconds 5 -GitHubWebCookie "  logged-in`r`n-cookie  " -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -AllowedGitHubHostsNormalized @("github.com") -SensitiveTokens @("logged-in-cookie")

        $result.Count | Should -Be 0
        $script:capturedWebHeaders["Cookie"] | Should -Be "logged-in-cookie"
        $script:webSessionParameterWasBound | Should -BeFalse
        Assert-MockCalled Invoke-WebRequest -Times 1 -Scope It
    }

    It "throws a redacted error when provided GitHub web cookie cannot fetch changesets" {
        Mock Invoke-WebRequest {
            throw "web auth failed for logged-in-cookie"
        }

        {
            Get-GitHubWebAutomatedSuggestedDiffsByCommentId -Owner "org" -Repo "repo" -PrNumber 86 -GitHubHost "github.com" -RequestTimeoutSeconds 5 -GitHubWebCookie "logged-in-cookie" -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -AllowedGitHubHostsNormalized @("github.com") -SensitiveTokens @("logged-in-cookie")
        } | Should -Throw "*E_GITHUB_WEB_SUGGESTIONS_UNAVAILABLE*"

        try {
            Get-GitHubWebAutomatedSuggestedDiffsByCommentId -Owner "org" -Repo "repo" -PrNumber 86 -GitHubHost "github.com" -RequestTimeoutSeconds 5 -GitHubWebCookie "logged-in-cookie" -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -AllowedGitHubHostsNormalized @("github.com") -SensitiveTokens @("logged-in-cookie")
        }
        catch {
            $_.Exception.Message | Should -Not -Match "logged-in-cookie"
            $_.Exception.Message | Should -Match "\*\*\*REDACTED\*\*\*"
        }
    }

    It "merges GitHub web automated suggestions into matching comment records" {
        $thread = [pscustomobject]@{
            id                = "THREAD_WEB_AUTOMATED_CHANGESET"
            isResolved        = $false
            isOutdated        = $true
            path              = "web/src/test/dom-assertions.ts"
            startLine         = 34
            line              = 45
            originalStartLine = 34
            originalLine      = 37
            comments          = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{
                        databaseId = 3424230049
                        body       = "`expectAriaReferencesToExist` accepts a `root` parameter but resolves referenced ids via the global `document`."
                        diffHunk   = "@@ -10,3 +10,38 @@ export function requireElement<T extends Element>(`n+        expect(`n+          document.getElementById(id),`n+        ).not.toBeNull();"
                        author     = [pscustomobject]@{ login = "copilot-pull-request-reviewer" }
                    }
                )
            }
        }
        $suggestionsByCommentId = @{
            "3424230049" = @(
                [pscustomobject]@{
                    kind = "changedLines"
                    path = "web/src/test/dom-assertions.ts"
                    diff = "-          document.getElementById(id),`n+          element.ownerDocument.getElementById(id),"
                }
            )
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 86 -GitHubHost "github.com"
        $record.comments[0].databaseId | Should -Be "3424230049"

        Add-GitHubWebAutomatedSuggestedDiffsToRecords -Records @($record) -SuggestedDiffsByCommentId $suggestionsByCommentId

        @($record.comments[0].suggestedDiffs).Count | Should -Be 1
        $record.comments[0].suggestedDiffsUnavailable | Should -BeFalse
        $record.comments[0].suggestedDiffsUnavailableReason | Should -BeNullOrEmpty

        $text = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"
        $text | Should -Match "Suggested change:"
        $text | Should -Match "\+          element\.ownerDocument\.getElementById\(id\),"
        $text | Should -Match "-          document\.getElementById\(id\),"
        $text | Should -Not -Match "\+        expect\("
        $text | Should -Not -Match "\+        \)\.not\.toBeNull"

        $json = Format-UnresolvedThreadsAsJson -Records @($record)
        $parsed = @($json | ConvertFrom-JsonCompat -Depth 8)
        @($parsed[0].comments[0].suggestedChanges).Count | Should -Be 1
        $parsed[0].comments[0].suggestedChanges[0].kind | Should -Be "changedLines"
        $parsed[0].comments[0].suggestedChanges[0].value | Should -BeExactly "-          document.getElementById(id),`n+          element.ownerDocument.getElementById(id),"
    }

    It "uses current GitHub anchors for non-outdated display ranges" {
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
        $record.lineStart | Should -Be 20
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
        $record.lineEnd | Should -Be 47

        $text = Format-UnresolvedThreadsAsText -Records @($record)
        $text | Should -Match "\(src/range\.ts\) 37-47"

        $json = Format-UnresolvedThreadsAsJson -Records @($record)
        $parsed = @($json | ConvertFrom-JsonCompat -Depth 8)
        $parsed[0].lineStart | Should -Be 37
        $parsed[0].lineEnd | Should -Be 47
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

        $record.lineStart | Should -Be 15
        $record.lineEnd | Should -BeNullOrEmpty

        $text = Format-UnresolvedThreadsAsText -Records @($record)
        $text | Should -Match "\(src/start-only\.ts\) 15-\?"
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
---
(src/b.ts) 12-20
Comment B
---
"@

        $actualNormalized = $text -replace "`r`n", "`n"
        $expectedNormalized = $expected.TrimEnd("`r", "`n") -replace "`r`n", "`n"

        $actualNormalized | Should -BeExactly $expectedNormalized
    }

    It "labels web suggested diffs that target a different file" {
        $records = @(
            [pscustomobject]@{
                path      = "src/commented.ts"
                lineStart = 10
                lineEnd   = 10
                comments  = @(
                    [pscustomobject]@{
                        body           = ""
                        suggestedChanges = @()
                        suggestedDiffs = @(
                            [pscustomobject]@{
                                kind = "changedLines"
                                path = "src/changed.ts"
                                diff = "-old();`n+new();"
                            }
                        )
                    }
                )
            }
        )

        $text = Format-UnresolvedThreadsAsText -Records $records
        $expected = @'
---
(src/commented.ts) 10-10
Suggested change (src/changed.ts):
```diff
-old();
+new();
```
---
'@

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
---
"@

        ($text -replace "`r`n", "`n") | Should -BeExactly (($expected.TrimEnd("`r", "`n")) -replace "`r`n", "`n")
    }

    It "renders per-comment suggestion without the referenced diff hunk" {
        $records = @(
            [pscustomobject]@{
                path               = "src/diff.ts"
                lineStart          = 2
                lineEnd            = 4
                topLevelComment    = "Fallback comment"
                comments           = @(
                    [pscustomobject]@{
                        commentIndex = 0
                        body         = "Please fix the branch."
                        diffHunk     = "@@ -1,2 +1,4 @@`n context`n-old`n+new"
                        url          = "https://github.example.test/org/repo/pull/1#discussion_r1"
                    }
                )
                latestReplySummary = $null
            }
        )

        $text = Format-UnresolvedThreadsAsText -Records $records
        $expected = @'
---
(src/diff.ts) 2-4
Suggestion:
Please fix the branch.
---
'@

        ($text -replace "`r`n", "`n") | Should -BeExactly (($expected.TrimEnd("`r", "`n")) -replace "`r`n", "`n")
        $text | Should -Not -Match "Review context diff hunk:"
        $text | Should -Not -Match "@@ -1,2 \+1,4 @@"
        $text | Should -Not -Match "\+new"
    }

    It "renders per-comment suggested changes even when body and diff hunk are empty" {
        $records = @(
            [pscustomobject]@{
                path               = "src/suggestion-only.ts"
                lineStart          = 9
                lineEnd            = 9
                topLevelComment    = ""
                comments           = @(
                    [pscustomobject]@{
                        commentIndex     = 0
                        body             = $null
                        diffHunk         = $null
                        suggestedChanges = @(
                            [pscustomobject]@{
                                kind = "suggestion"
                                code = "return value"
                            }
                        )
                    }
                )
                latestReplySummary = $null
            }
        )

        $text = Format-UnresolvedThreadsAsText -Records $records

        $text | Should -Match "Suggested change:"
        $text | Should -Match "return value"
        $text | Should -Not -Match "Suggestion:\s*\(none\)"
    }

    It "numbers only visible per-comment suggestions when empty entries are skipped" {
        $records = @(
            [pscustomobject]@{
                path               = "src/numbered.ts"
                lineStart          = 4
                lineEnd            = 4
                topLevelComment    = ""
                comments           = @(
                    [pscustomobject]@{
                        commentIndex     = 0
                        body             = $null
                        diffHunk         = $null
                        suggestedChanges = @()
                    },
                    [pscustomobject]@{
                        commentIndex     = 1
                        body             = "First visible"
                        diffHunk         = $null
                        suggestedChanges = @()
                    },
                    [pscustomobject]@{
                        commentIndex     = 2
                        body             = "Second visible"
                        diffHunk         = $null
                        suggestedChanges = @()
                    }
                )
                latestReplySummary = $null
            }
        )

        $text = Format-UnresolvedThreadsAsText -Records $records
        $normalized = $text -replace "`r`n", "`n"

        $normalized | Should -Match "Suggestion 1:`nFirst visible"
        $normalized | Should -Match "Suggestion 2:`nSecond visible"
        $normalized | Should -Not -Match "Suggestion 3:"
    }
}

Describe "Format-UnresolvedThreadsAsJson" {
    It "always emits an array with only file, range, suggestions, and suggested changes" {
        $records = @(
            [pscustomobject]@{
                path               = "src/main.ts"
                lineStart          = 10
                lineEnd            = 12
                comments           = @(
                    [pscustomobject]@{
                        commentIndex = 0
                        body         = "Top"
                        diffHunk     = "@@ -1,2 +1,3 @@`n-old`n+new"
                        suggestedChanges = @(
                            [pscustomobject]@{
                                kind        = "suggestion"
                                code        = "return value"
                                authorLogin = "cursor[bot]"
                                url         = "https://github.com/org/repo/pull/77#discussion_r1"
                            }
                        )
                        suggestedDiffs = @(
                            [pscustomobject]@{
                                kind = "changedLines"
                                diff = "@@ -1 +1 @@`n-old`n+new"
                            }
                        )
                        suggestedDiffsUnavailable = $true
                        suggestedDiffsUnavailableReason = "copilot_suggested_diff_may_be_web_only_or_unavailable"
                        url          = "https://github.com/org/repo/pull/77#discussion_r1"
                    }
                )
                suggestions        = @(
                    [pscustomobject]@{
                        kind         = "suggestion"
                        code         = "return value"
                        authorLogin  = "cursor[bot]"
                        commentIndex = 0
                        url          = "https://github.com/org/repo/pull/77#discussion_r1"
                    }
                )
                recommendations    = @(
                    [pscustomobject]@{
                        kind         = "comment"
                        authorLogin  = "cursor[bot]"
                        text         = "Top"
                        code         = $null
                        commentIndex = 0
                        url          = "https://github.com/org/repo/pull/77#discussion_r1"
                    },
                    [pscustomobject]@{
                        kind         = "suggestion"
                        authorLogin  = "cursor[bot]"
                        text         = $null
                        code         = "return value"
                        commentIndex = 0
                        url          = "https://github.com/org/repo/pull/77#discussion_r1"
                    }
                )
                topLevelAuthor     = "cursor[bot]"
                topLevelComment    = "Top"
                latestReplyAuthor  = "copilot-pull-request-reviewer"
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
        ($propertyNames -ccontains "lineStart") | Should -BeTrue
        ($propertyNames -ccontains "lineEnd") | Should -BeTrue
        ($propertyNames -ccontains "comments") | Should -BeTrue
        ($propertyNames -ccontains "suggestions") | Should -BeFalse
        ($propertyNames -ccontains "recommendations") | Should -BeFalse
        ($propertyNames -ccontains "topLevelAuthor") | Should -BeFalse
        ($propertyNames -ccontains "latestReplyAuthor") | Should -BeFalse
        ($propertyNames -ccontains "resolutionState") | Should -BeFalse
        ($propertyNames -ccontains "authSource") | Should -BeFalse
        ($propertyNames -ccontains "owner") | Should -BeFalse
        ($propertyNames -ccontains "repo") | Should -BeFalse
        ($propertyNames -ccontains "Path") | Should -BeFalse
        ($propertyNames -ccontains "LineStart") | Should -BeFalse
        ($propertyNames -ccontains "LineEnd") | Should -BeFalse
        ($propertyNames -ccontains "Owner") | Should -BeFalse
        ($propertyNames -ccontains "Repo") | Should -BeFalse

        $parsed[0].path | Should -Be "src/main.ts"
        $parsed[0].lineStart | Should -Be 10
        $parsed[0].lineEnd | Should -Be 12
        @($parsed[0].comments).Count | Should -Be 1
        $commentPropertyNames = @($parsed[0].comments[0].PSObject.Properties.Name)
        ($commentPropertyNames -ccontains "suggestion") | Should -BeTrue
        ($commentPropertyNames -ccontains "suggestedChanges") | Should -BeTrue
        ($commentPropertyNames -ccontains "body") | Should -BeFalse
        ($commentPropertyNames -ccontains "diffHunk") | Should -BeFalse
        ($commentPropertyNames -ccontains "commentIndex") | Should -BeFalse
        ($commentPropertyNames -ccontains "url") | Should -BeFalse
        ($commentPropertyNames -ccontains "suggestedDiffs") | Should -BeFalse
        ($commentPropertyNames -ccontains "suggestedDiffsUnavailable") | Should -BeFalse
        ($commentPropertyNames -ccontains "suggestedDiffsUnavailableReason") | Should -BeFalse

        $parsed[0].comments[0].suggestion | Should -Be "Top"
        @($parsed[0].comments[0].suggestedChanges).Count | Should -Be 2
        $parsed[0].comments[0].suggestedChanges[0].kind | Should -Be "suggestion"
        $parsed[0].comments[0].suggestedChanges[0].value | Should -Be "return value"
        $parsed[0].comments[0].suggestedChanges[1].kind | Should -Be "changedLines"
        $parsed[0].comments[0].suggestedChanges[1].value | Should -BeExactly "-old`n+new"
        $parsed[0].comments[0].suggestedChanges[1].value | Should -Not -Match "@@"
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

    It "passes the shared web session to the transport when one is set" {
        $sessionType = Resolve-WebRequestSessionType
        if ($null -eq $sessionType) {
            Set-ItResult -Skipped -Because "This PowerShell host does not expose Microsoft.PowerShell.Commands.WebRequestSession."
            return
        }

        $script:capturedSession = "<unset>"
        Mock Invoke-RestMethod {
            $script:capturedSession = $WebSession
            return @{ ok = $true }
        }

        $previousSession = $script:GitHubWebSession
        try {
            $script:GitHubWebSession = New-GitHubWebSession
            $result = Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
            $result.ok | Should -BeTrue
            $script:capturedSession.GetType().FullName | Should -Be $sessionType.FullName
            [object]::ReferenceEquals($script:capturedSession, $script:GitHubWebSession) | Should -BeTrue
        }
        finally {
            $script:GitHubWebSession = $previousSession
        }
    }

    It "returns null instead of throwing when the shared web session type is unavailable" {
        Mock Resolve-WebRequestSessionType { $null }

        $session = $null
        { $session = New-GitHubWebSession } | Should -Not -Throw
        $session | Should -BeNullOrEmpty
    }

    It "omits the web session when none is set (dot-sourced default)" {
        $script:sessionWasBound = "<unset>"
        Mock Invoke-RestMethod {
            $script:sessionWasBound = $PSBoundParameters.ContainsKey("WebSession")
            return @{ ok = $true }
        }

        $previousSession = $script:GitHubWebSession
        try {
            $script:GitHubWebSession = $null
            $result = Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
            $result.ok | Should -BeTrue
            $script:sessionWasBound | Should -BeFalse
        }
        finally {
            $script:GitHubWebSession = $previousSession
        }
    }

    It "suppresses the progress UI for the GET transport so it cannot probe/corrupt the terminal" {
        # PowerShell's web cmdlets render a progress bar on a terminal that hides the cursor and
        # emits DSR cursor-position queries (ESC[6n); the terminal's responses queue into stdin and
        # corrupt the parent shell's input after the process exits. Progress must be suppressed.
        $script:capturedProgress = "<unset>"
        Mock Invoke-RestMethod {
            $script:capturedProgress = $ProgressPreference
            return @{ ok = $true }
        }

        $ProgressPreference = "Continue"
        $result = Invoke-GitHubRequestWithRetry -Method GET -Uri "https://api.github.com/ping" -Headers @{} -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $result.ok | Should -BeTrue
        $script:capturedProgress | Should -Be "SilentlyContinue"
    }

    It "suppresses the progress UI for the POST transport so it cannot probe/corrupt the terminal" {
        $script:capturedProgress = "<unset>"
        Mock Invoke-RestMethod {
            $script:capturedProgress = $ProgressPreference
            return @{ ok = $true }
        }

        $ProgressPreference = "Continue"
        $result = Invoke-GitHubRequestWithRetry -Method POST -Uri "https://api.github.com/graphql" -Headers @{} -Body @{ query = "x" } -RequestTimeoutSeconds 10 -MaxRetries 0 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $result.ok | Should -BeTrue
        $script:capturedProgress | Should -Be "SilentlyContinue"
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

    It "suppresses the progress UI for the token-validation transport so it cannot probe/corrupt the terminal" {
        # The Invoke-WebRequest progress bar manipulates the terminal (cursor hide + DSR probes)
        # exactly like the other web cmdlets, so it must run with progress suppressed too.
        $script:capturedProgress = "<unset>"
        Mock Invoke-WebRequest {
            $script:capturedProgress = $ProgressPreference
            return [pscustomobject]@{
                Headers = @{ "X-OAuth-Scopes" = "repo" }
                Content = '{"private": true}'
            }
        }

        $ProgressPreference = "Continue"
        Validate-GitHubTokenForRepoAccess -Owner "org" -Repo "repo" -GitHubHost "github.com" -Headers @{} -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))
        $script:capturedProgress | Should -Be "SilentlyContinue"
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

        Mock Read-TerminalResponse {
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

        Mock Read-TerminalResponse {
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

        Mock Read-TerminalResponse {
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

    It "preserves earlier GraphQL pages and warns when a later review-thread page fails" {
        $secret = "secret-token-12345"
        $script:pageCall = 0
        $script:warningMessages = @()
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
                                        @{ id = "T1"; isResolved = $false; path = "src/a.ts"; startLine = 1; line = 1; comments = @{ nodes = @(@{ body = "A" }) } }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            throw "E_NETWORK_ERROR: failed with $secret"
        }
        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        $records = @(Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 100 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -SensitiveTokens @($secret))

        $records.Count | Should -Be 1
        $records[0].threadId | Should -Be "T1"
        $script:warningMessages.Count | Should -Be 1
        $script:warningMessages[0] | Should -Match "W_PARTIAL_GITHUB_REVIEW_THREAD_PAGINATION"
        $script:warningMessages[0] | Should -Match "results may be incomplete"
        $script:warningMessages[0] | Should -Not -Match [regex]::Escape($secret)
    }

    It "preserves earlier GraphQL pages and warns when a later review-thread page is malformed" {
        $script:pageCall = 0
        $script:warningMessages = @()
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
                                        @{ id = "T1"; isResolved = $false; path = "src/a.ts"; startLine = 1; line = 1; comments = @{ nodes = @(@{ body = "A" }) } }
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
                        pullRequest = @{}
                    }
                }
            }
        }
        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        $records = @(Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 100 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))

        $records.Count | Should -Be 1
        $records[0].threadId | Should -Be "T1"
        $script:warningMessages.Count | Should -Be 1
        $script:warningMessages[0] | Should -Match "W_PARTIAL_GITHUB_REVIEW_THREAD_PAGINATION"
        $script:warningMessages[0] | Should -Match "E_MALFORMED_RESPONSE"
    }

    It "propagates a first-page GraphQL request failure instead of returning partial results" {
        $script:warningMessages = @()
        Mock Invoke-GitHubRequestWithRetry {
            throw "E_NETWORK_ERROR: first page failed"
        }
        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        {
            [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_NETWORK_ERROR*first page failed*"

        $script:warningMessages.Count | Should -Be 0
    }

    It "propagates a first-page malformed GraphQL response instead of returning empty results" {
        $script:warningMessages = @()
        Mock Invoke-GitHubRequestWithRetry {
            return @{
                data = @{
                    repository = @{
                        pullRequest = @{}
                    }
                }
            }
        }
        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        {
            [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_MALFORMED_RESPONSE*reviewThreads*"

        $script:warningMessages.Count | Should -Be 0
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
                        outdated            = $true
                        body                = "Top A"
                        diff_hunk           = "@@ -3,5 +4,5 @@`n context`n-old`n+new"
                        created_at          = "2026-01-01T00:00:00Z"
                        html_url            = "https://github.com/org/repo/pull/9#discussion_r101"
                        user                = [pscustomobject]@{ login = "reviewer-a" }
                    },
                    [pscustomobject]@{
                        id             = 102
                        in_reply_to_id = 101
                        body           = "Reply A"
                        diff_hunk      = "@@ -6,2 +6,3 @@`n reply context`n+reply new"
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
                    body       = "Top B from Copilot"
                    created_at = "2026-01-01T00:02:00Z"
                    html_url   = "https://github.com/org/repo/pull/9#discussion_r201"
                    user       = [pscustomobject]@{ login = "copilot-pull-request-reviewer[bot]" }
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
        $records[0].comments[0].diffHunk | Should -BeExactly "@@ -3,5 +4,5 @@`n context`n-old`n+new"
        $records[0].comments[1].diffHunk | Should -BeExactly "@@ -6,2 +6,3 @@`n reply context`n+reply new"
        $records[0].resolutionState | Should -Be "unknown"
        $records[1].threadId | Should -Be "rest:201"
        $records[1].lineStart | Should -Be 12
        $records[1].lineEnd | Should -Be 12
        $records[1].comments[0].suggestedDiffsUnavailable | Should -BeTrue
        $records[1].comments[0].suggestedDiffsUnavailableReason | Should -Be "copilot_suggested_diff_may_be_web_only_or_unavailable"
        $records[1].resolutionState | Should -Be "unknown"

        $script:sawAuthorizationHeader | Should -BeFalse
        $script:restUris.Count | Should -Be 2
        $script:restUris[0] | Should -Be "https://api.github.com/repos/org/repo/pulls/9/comments?per_page=2&page=1&sort=created&direction=asc"
        $script:restUris[1] | Should -Be "https://api.github.com/repos/org/repo/pulls/9/comments?per_page=2&page=2&sort=created&direction=asc"
        $script:warningMessages.Count | Should -Be 1
        $script:warningMessages[0] | Should -Match "W_PUBLIC_REST_FALLBACK_RESOLUTION_UNKNOWN"

        $json = Format-UnresolvedThreadsAsJson -Records $records
        $parsed = @($json | ConvertFrom-JsonCompat -Depth 8)
        @($parsed[0].PSObject.Properties.Name) | Should -Not -Contain "resolutionState"
        @($parsed[0].PSObject.Properties.Name) | Should -Not -Contain "authSource"
    }

    It "preserves earlier REST pages and warns when a later public review-comment page fails" {
        $secret = "secret-token-12345"
        $script:restUris = @()
        $script:warningMessages = @()

        Mock Invoke-GitHubRequestWithRetry {
            param(
                [string]$Uri
            )

            $script:restUris += $Uri
            if ($Uri -match "page=1") {
                return @(
                    [pscustomobject]@{
                        id         = 101
                        path       = "src/a.ts"
                        line       = 6
                        body       = "Top A"
                        created_at = "2026-01-01T00:00:00Z"
                        html_url   = "https://github.com/org/repo/pull/9#discussion_r101"
                        user       = [pscustomobject]@{ login = "reviewer-a" }
                    },
                    [pscustomobject]@{
                        id         = 201
                        path       = "src/b.ts"
                        line       = 12
                        body       = "Top B"
                        created_at = "2026-01-01T00:02:00Z"
                        html_url   = "https://github.com/org/repo/pull/9#discussion_r201"
                        user       = [pscustomobject]@{ login = "reviewer-b" }
                    }
                )
            }

            throw "E_NETWORK_ERROR: failed with $secret"
        }

        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        $records = @(Get-PublicPullRequestReviewCommentsFallback -Owner "org" -Repo "repo" -PrNumber 9 -GitHubHost "github.com" -PerPage 2 -MaxPages 5 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -SensitiveTokens @($secret))

        $records.Count | Should -Be 2
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "rest:101"
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "rest:201"
        $script:restUris.Count | Should -Be 2
        $script:warningMessages.Count | Should -Be 2
        $script:warningMessages[0] | Should -Match "W_PARTIAL_GITHUB_REST_REVIEW_COMMENT_PAGINATION"
        $script:warningMessages[0] | Should -Match "results may be incomplete"
        $script:warningMessages[0] | Should -Not -Match [regex]::Escape($secret)
        $script:warningMessages[1] | Should -Match "W_PUBLIC_REST_FALLBACK_RESOLUTION_UNKNOWN"
    }

    It "preserves earlier REST pages and warns when a later public review-comment page is malformed" {
        $script:restUris = @()
        $script:warningMessages = @()

        Mock Invoke-GitHubRequestWithRetry {
            param(
                [string]$Uri
            )

            $script:restUris += $Uri
            if ($Uri -match "page=1") {
                return @(
                    [pscustomobject]@{
                        id         = 101
                        path       = "src/a.ts"
                        line       = 6
                        body       = "Top A"
                        created_at = "2026-01-01T00:00:00Z"
                        html_url   = "https://github.com/org/repo/pull/9#discussion_r101"
                        user       = [pscustomobject]@{ login = "reviewer-a" }
                    },
                    [pscustomobject]@{
                        id         = 201
                        path       = "src/b.ts"
                        line       = 12
                        body       = "Top B"
                        created_at = "2026-01-01T00:02:00Z"
                        html_url   = "https://github.com/org/repo/pull/9#discussion_r201"
                        user       = [pscustomobject]@{ login = "reviewer-b" }
                    }
                )
            }

            return [pscustomobject]@{ message = "not a review-comment array" }
        }

        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        $records = @(Get-PublicPullRequestReviewCommentsFallback -Owner "org" -Repo "repo" -PrNumber 9 -GitHubHost "github.com" -PerPage 2 -MaxPages 5 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))

        $records.Count | Should -Be 2
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "rest:101"
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "rest:201"
        $script:restUris.Count | Should -Be 2
        $script:warningMessages.Count | Should -Be 2
        $script:warningMessages[0] | Should -Match "W_PARTIAL_GITHUB_REST_REVIEW_COMMENT_PAGINATION"
        $script:warningMessages[0] | Should -Match "E_MALFORMED_RESPONSE"
        $script:warningMessages[1] | Should -Match "W_PUBLIC_REST_FALLBACK_RESOLUTION_UNKNOWN"
    }

    It "preserves earlier REST pages and warns when a later public review-comment page is null" {
        $script:restUris = @()
        $script:warningMessages = @()

        Mock Invoke-GitHubRequestWithRetry {
            param(
                [string]$Uri
            )

            $script:restUris += $Uri
            if ($Uri -match "page=1") {
                return @(
                    [pscustomobject]@{
                        id         = 101
                        path       = "src/a.ts"
                        line       = 6
                        body       = "Top A"
                        created_at = "2026-01-01T00:00:00Z"
                        html_url   = "https://github.com/org/repo/pull/9#discussion_r101"
                        user       = [pscustomobject]@{ login = "reviewer-a" }
                    },
                    [pscustomobject]@{
                        id         = 201
                        path       = "src/b.ts"
                        line       = 12
                        body       = "Top B"
                        created_at = "2026-01-01T00:02:00Z"
                        html_url   = "https://github.com/org/repo/pull/9#discussion_r201"
                        user       = [pscustomobject]@{ login = "reviewer-b" }
                    }
                )
            }

            return $null
        }

        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        $records = @(Get-PublicPullRequestReviewCommentsFallback -Owner "org" -Repo "repo" -PrNumber 9 -GitHubHost "github.com" -PerPage 2 -MaxPages 5 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))

        $records.Count | Should -Be 2
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "rest:101"
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "rest:201"
        $script:restUris.Count | Should -Be 2
        $script:warningMessages.Count | Should -Be 2
        $script:warningMessages[0] | Should -Match "W_PARTIAL_GITHUB_REST_REVIEW_COMMENT_PAGINATION"
        $script:warningMessages[0] | Should -Match "returned null"
        $script:warningMessages[1] | Should -Match "W_PUBLIC_REST_FALLBACK_RESOLUTION_UNKNOWN"
    }

    It "propagates a first-page public REST request failure instead of returning empty fallback results" {
        $script:warningMessages = @()
        Mock Invoke-GitHubRequestWithRetry {
            throw "E_NETWORK_ERROR: first page failed"
        }
        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        {
            [void](Get-PublicPullRequestReviewCommentsFallback -Owner "org" -Repo "repo" -PrNumber 9 -GitHubHost "github.com" -PerPage 2 -MaxPages 5 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_NETWORK_ERROR*first page failed*"

        $script:warningMessages.Count | Should -Be 0
    }

    It "propagates a first-page null public REST page instead of returning empty fallback results" {
        $script:warningMessages = @()
        Mock Invoke-GitHubRequestWithRetry {
            return $null
        }
        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        {
            [void](Get-PublicPullRequestReviewCommentsFallback -Owner "org" -Repo "repo" -PrNumber 9 -GitHubHost "github.com" -PerPage 2 -MaxPages 5 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_MALFORMED_RESPONSE*returned null*"

        $script:warningMessages.Count | Should -Be 0
    }

    It "propagates a first-page malformed public REST page instead of returning empty fallback results" {
        $script:warningMessages = @()
        Mock Invoke-GitHubRequestWithRetry {
            return [pscustomobject]@{ message = "not a review-comment array" }
        }
        Mock Write-Warning {
            param($Message)
            $script:warningMessages += $Message
        }

        {
            [void](Get-PublicPullRequestReviewCommentsFallback -Owner "org" -Repo "repo" -PrNumber 9 -GitHubHost "github.com" -PerPage 2 -MaxPages 5 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)))
        } | Should -Throw "*E_MALFORMED_RESPONSE*without an id*"

        $script:warningMessages.Count | Should -Be 0
    }

    It "uses current anchors for REST comments without an outdated flag" {
        $threads = @(Convert-RestReviewCommentsToThreadLikeObjects -Comments @(
                [pscustomobject]@{
                    id                  = 301
                    path                = "src/current-rest.ts"
                    start_line          = 40
                    line                = 42
                    original_start_line = 3
                    original_line       = 7
                    body                = "Current REST range"
                    created_at          = "2026-01-01T00:03:00Z"
                    html_url            = "https://github.com/org/repo/pull/9#discussion_r301"
                    user                = [pscustomobject]@{ login = "reviewer-c" }
                }
            ))

        $threads.Count | Should -Be 1
        $threads[0].isOutdated | Should -BeFalse

        $record = Convert-ReviewThreadToOutputRecord -Thread $threads[0] -Owner "org" -Repo "repo" -PrNumber 9 -GitHubHost "github.com"

        $record.threadId | Should -Be "rest:301"
        $record.lineStart | Should -Be 40
        $record.lineEnd | Should -Be 42
        $record.githubLineStart | Should -Be 40
        $record.githubLineEnd | Should -Be 42
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
        Mock Read-TerminalResponse {
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
    BeforeEach {
        Mock Get-GitHubWebAutomatedSuggestedDiffsByCommentId { @{} }
    }

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
        Mock Read-TerminalResponse { throw "Read-TerminalResponse should not be called when REST fallback succeeds." }
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
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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

        Mock Read-TerminalResponse { "y" }
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

        Mock Read-TerminalResponse { "y" }
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
        Assert-MockCalled Read-TerminalResponse -Times 1 -Scope It
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

        Mock Read-TerminalResponse { "y" }
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
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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
        Mock Read-TerminalResponse { throw "Read-TerminalResponse should not be called when stored credentials recover." }
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
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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

        Mock Read-TerminalResponse { "y" }
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

        Mock Read-TerminalResponse { "y" }
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
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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
        Mock Read-TerminalResponse { throw "Read-TerminalResponse should not be called in direct mode auth failure." }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called when token validation fails." }
        Mock Get-PublicPullRequestReviewCommentsFallback { throw "Public REST fallback should not be called when an explicit token fails in direct mode." }

        { Invoke-Main } | Should -Throw "*E_AUTH_INVALID*"
        Assert-MockCalled Get-GitHubHeaders -Times 1 -Scope It -ParameterFilter { $AuthToken -eq "bad-token" }
        Assert-MockCalled Get-GitHubHeaders -Times 1 -Scope It -ParameterFilter { [string]::IsNullOrWhiteSpace($AuthToken) }
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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
        Mock Read-TerminalResponse { throw "Read-TerminalResponse should not be called in direct mode auth failure." }
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
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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
        Mock Read-TerminalResponse { throw "Read-TerminalResponse should not be called in direct mode auth failure." }
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
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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
        Mock Read-TerminalResponse { throw "Read-TerminalResponse should not be called when anonymous fallback succeeds." }

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
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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
        Mock Read-TerminalResponse { throw "Read-TerminalResponse should not be called for non-auth REST fallback failures." }

        Mock Get-PublicPullRequestReviewCommentsFallback {
            throw "E_NETWORK_TIMEOUT: Public REST fallback timed out"
        }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called for non-auth REST fallback failures." }

        { Invoke-Main } | Should -Throw "*E_NETWORK_TIMEOUT*Public REST fallback timed out*"
        $script:authTokenCallCount | Should -Be 2
        $script:validateCallCount | Should -Be 1
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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
        Mock Read-TerminalResponse { throw "Read-TerminalResponse should not be called when interactive prompt is unavailable." }
        Mock Get-PublicPullRequestReviewCommentsFallback { throw "E_NETWORK_TIMEOUT: Public REST fallback timed out" }
        Mock Get-UnresolvedReviewThreads { throw "Get-UnresolvedReviewThreads should not be called for non-auth REST fallback failures." }

        { Invoke-Main } | Should -Throw "*E_NETWORK_TIMEOUT*"
        $script:authTokenCallCount | Should -Be 2
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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
        Mock Read-TerminalResponse { throw "Read-TerminalResponse should not be called when interactive prompt is unavailable." }
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
        Mock Read-TerminalResponse { "y" }

        { Invoke-Main } | Should -Throw "*E_AUTH_REQUIRED*"
        Assert-MockCalled Read-TerminalResponse -Times 0 -Scope It
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

Describe "Suggestion diff reconstruction (end-anchored before-context)" {
    Context "Get-NewSideLinesInRange" {
        It "end-anchors when a truncated header understates the commented line" {
            # Header claims the new side starts at 10, but the comment anchors at 142:
            # GitHub truncated the hunk to its tail and kept the original @@ header.
            $hunk = "@@ -8,6 +10,6 @@ function run() {`n ctx();`n-oldCall();`n+commentedCall();"
            Get-NewSideLinesInRange -DiffHunk $hunk -Start 142 -End 142 | Should -BeExactly "commentedCall();"
        }

        It "returns the last N new-side lines for a multi-line anchor" {
            $hunk = "@@ -1,5 +1,5 @@`n a();`n b();`n c();"
            Get-NewSideLinesInRange -DiffHunk $hunk -Start 200 -End 201 | Should -BeExactly "b();`nc();"
        }

        It "clamps the span to the available new-side lines" {
            $hunk = "@@ -1,2 +1,2 @@`n+a`n+b"
            Get-NewSideLinesInRange -DiffHunk $hunk -Start 5 -End 12 | Should -BeExactly "a`nb"
        }

        It "anchors on the last real new-side line past a trailing deletion" {
            $hunk = "@@ -10,3 +10,2 @@`n keep();`n anchor();`n-removed();"
            Get-NewSideLinesInRange -DiffHunk $hunk -Start 11 -End 11 | Should -BeExactly "anchor();"
        }

        It "ignores unified-diff no-newline sentinel rows" {
            $hunk = "@@ -10,3 +10,2 @@`n keep();`n anchor();`n\ No newline at end of file"
            Get-NewSideLinesInRange -DiffHunk $hunk -Start 11 -End 11 | Should -BeExactly "anchor();"
        }

        It "returns empty for a pure-deletion hunk with no new-side line" {
            $hunk = "@@ -10,2 +10,0 @@`n-x();`n-y();"
            Get-NewSideLinesInRange -DiffHunk $hunk -Start 10 -End 10 | Should -BeExactly ""
        }

        It "returns empty for a missing hunk or absent anchor" {
            Get-NewSideLinesInRange -DiffHunk $null -Start 5 -End 5 | Should -BeExactly ""
            Get-NewSideLinesInRange -DiffHunk "@@ -1,1 +1,1 @@`n+a" -Start $null -End $null | Should -BeExactly ""
        }
    }

    Context "ConvertTo-ReconstructedSuggestionDiff" {
        It "emits removed lines then added lines" {
            ConvertTo-ReconstructedSuggestionDiff -Before "document.getElementById(id)," -After "element.ownerDocument.getElementById(id)," |
                Should -BeExactly "-document.getElementById(id),`n+element.ownerDocument.getElementById(id),"
        }

        It "renders an empty suggestion as a pure deletion and renders no before as empty" {
            ConvertTo-ReconstructedSuggestionDiff -Before "drop();" -After "" | Should -BeExactly "-drop();"
            ConvertTo-ReconstructedSuggestionDiff -Before "" -After "added();" | Should -BeExactly ""
        }

        It "keeps an unchanged line as context instead of a spurious -/+ pair" {
            # `a();` is unchanged, so a real line diff keeps it as a single " " context row
            # rather than re-emitting it as both a deletion and an addition.
            ConvertTo-ReconstructedSuggestionDiff -Before "a();`nb();" -After "a();`nb2();" |
                Should -BeExactly " a();`n-b();`n+b2();"
        }

        It "renders a middle-line removal as a single deletion surrounded by context" {
            # The bug this fixes: a suggestion that REMOVES the middle line of a block must read
            # as one "-" between two " " context rows, not a wall of "+" re-adding the kept lines.
            ConvertTo-ReconstructedSuggestionDiff -Before "parse(input);`nvalidate(input);`nstore(input);" -After "parse(input);`nstore(input);" |
                Should -BeExactly " parse(input);`n-validate(input);`n store(input);"
        }

        It "renders an added line within a block as a single addition surrounded by context" {
            ConvertTo-ReconstructedSuggestionDiff -Before "a();`nc();" -After "a();`nb();`nc();" |
                Should -BeExactly " a();`n+b();`n c();"
        }

        It "returns empty when the suggestion is identical to the before context" {
            # A no-op suggestion produces only context rows; emitting a changeless block adds no
            # value, so the caller falls back to rendering the suggestion verbatim.
            ConvertTo-ReconstructedSuggestionDiff -Before "a();" -After "a();" | Should -BeExactly ""
        }
    }

    Context "Convert-ReviewThreadToOutputRecord end-to-end" {
        It "reconstructs a -/+ suggestion diff from a truncated hunk" {
            $body = @'
Rename it.

```suggestion
renamedCall();
```
'@
            $thread = [pscustomobject]@{
                id         = "THREAD_TRUNC"
                isResolved = $false
                isOutdated = $false
                path       = "src/big.ts"
                startLine  = 142
                line       = 142
                comments   = [pscustomobject]@{
                    nodes = @([pscustomobject]@{
                            body      = $body
                            diff_hunk = "@@ -8,6 +10,6 @@ function run() {`n ctx();`n-oldCall();`n+commentedCall();"
                        })
                }
            }

            $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"
            $text = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"

            $text | Should -Match "Suggested change:"
            $text | Should -Match ([regex]::Escape("-commentedCall();"))
            $text | Should -Match ([regex]::Escape("+renamedCall();"))
        }

        It "reconstructs both removed lines for a multi-line suggestion" {
            $body = @'
Fix both.

```suggestion
first2();
second2();
```
'@
            $thread = [pscustomobject]@{
                id         = "THREAD_MULTI"
                isResolved = $false
                isOutdated = $false
                path       = "src/multi.ts"
                startLine  = 20
                line       = 21
                comments   = [pscustomobject]@{
                    nodes = @([pscustomobject]@{
                            body      = $body
                            diff_hunk = "@@ -5,4 +5,4 @@`n head();`n-first();`n-second();`n+first();`n+second();"
                        })
                }
            }

            $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"
            $text = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"

            $text | Should -Match ([regex]::Escape("-first();"))
            $text | Should -Match ([regex]::Escape("-second();"))
            $text | Should -Match ([regex]::Escape("+first2();"))
            $text | Should -Match ([regex]::Escape("+second2();"))
        }

        It "keeps JSON suggestedChanges verbatim (added-only value), not the reconstructed diff" {
            $body = @'
Rename it.

```suggestion
renamedCall();
```
'@
            $thread = [pscustomobject]@{
                id         = "THREAD_JSON"
                isResolved = $false
                isOutdated = $false
                path       = "src/big.ts"
                startLine  = 142
                line       = 142
                comments   = [pscustomobject]@{
                    nodes = @([pscustomobject]@{
                            body      = $body
                            diff_hunk = "@@ -8,6 +10,6 @@ function run() {`n ctx();`n-oldCall();`n+commentedCall();"
                        })
                }
            }

            $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"
            $parsed = (Format-UnresolvedThreadsAsJson -Records @($record)) | ConvertFrom-Json

            $parsed[0].comments[0].suggestedChanges[0].kind | Should -Be "suggestion"
            $parsed[0].comments[0].suggestedChanges[0].value | Should -BeExactly "renamedCall();"
        }

        It "does not fabricate a deletion when the comment has no diff hunk" {
            $body = @'
Tweak it.

```suggestion
tweaked();
```
'@
            $thread = [pscustomobject]@{
                id         = "THREAD_NOHUNK"
                isResolved = $false
                isOutdated = $false
                path       = "src/main.ts"
                startLine  = 5
                line       = 5
                comments   = [pscustomobject]@{
                    nodes = @([pscustomobject]@{ body = $body })
                }
            }

            $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 9 -GitHubHost "github.com"
            $text = (Format-UnresolvedThreadsAsText -Records @($record)) -replace "`r`n", "`n"

            $text | Should -Match "Suggested change:"
            $text | Should -Match "(?m)^tweaked\(\);$"
            $text | Should -Not -Match "(?m)^\+tweaked"
        }
    }
}
