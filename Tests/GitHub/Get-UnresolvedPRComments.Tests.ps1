Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
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
        $headers = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $headers["X-OAuth-Scopes"] = "repo"

        (Get-HeaderValue -Headers $headers -Key "X-OAuth-Scopes") | Should -Be "repo"
    }

    It "ignores enumerable entries without Key property" {
        $headers = @("a", "b")
        (Get-HeaderValue -Headers $headers -Key "X-RateLimit-Reset") | Should -BeNullOrEmpty
    }

    It "returns all values from HttpHeaders via TryGetValues" {
        $response = [System.Net.Http.HttpResponseMessage]::new()
        try {
            $response.Headers.Add("X-OAuth-Scopes", "repo")
            $response.Headers.Add("X-OAuth-Scopes", "read:org")

            $values = @(Get-HeaderValues -Headers $response.Headers -Key "X-OAuth-Scopes")
            $values.Count | Should -Be 2
            $values[0] | Should -Be "repo"
            $values[1] | Should -Be "read:org"
        } finally {
            $response.Dispose()
        }
    }

    It "reads HttpHeaders values regardless of key casing" {
        $response = [System.Net.Http.HttpResponseMessage]::new()
        try {
            $response.Headers.Add("X-OAuth-Scopes", "repo")

            $values = @(Get-HeaderValues -Headers $response.Headers -Key "x-oauth-scopes")
            $values.Count | Should -Be 1
            $values[0] | Should -Be "repo"
        } finally {
            $response.Dispose()
        }
    }

    It "normalizes array-valued hashtable entries to first scalar for Get-HeaderValue" {
        $headers = @{ "X-RateLimit-Reset" = @("123", "456") }
        (Get-HeaderValue -Headers $headers -Key "X-RateLimit-Reset") | Should -Be "123"
    }

    It "returns all array-valued hashtable entries for Get-HeaderValues" {
        $headers = @{ "X-OAuth-Scopes" = @("repo", "read:org") }
        $values = @(Get-HeaderValues -Headers $headers -Key "X-OAuth-Scopes")

        $values.Count | Should -Be 2
        $values[0] | Should -Be "repo"
        $values[1] | Should -Be "read:org"
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
        $token = "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
        $input = "Authorization Bearer $token failed"

        $redacted = Redact-SensitiveText -Text $input -SensitiveTokens @($token)
        $redacted | Should -Not -Match [regex]::Escape($token)
        $redacted | Should -Match "\*\*\*REDACTED\*\*\*"
    }

    $ghpToken = "ghp_" + ("a" * 36)
    $patToken = "github_pat_" + ("b" * 80)
    $headerToken = "abcdefghijklmnopqrstuvwx123456"

    $cases = @(
        @{
            Name = "redacts generic ghp token"
            CaseInput = "Detected token: $ghpToken"
            SensitiveTokens = @()
            ShouldContain = "***REDACTED***"
            ShouldNotContain = @($ghpToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name = "redacts generic github_pat token"
            CaseInput = "Detected token: $patToken"
            SensitiveTokens = @()
            ShouldContain = "***REDACTED***"
            ShouldNotContain = @($patToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name = "redacts authorization bearer scheme"
            CaseInput = "Authorization: Bearer $headerToken"
            SensitiveTokens = @()
            ShouldContain = "Authorization: Bearer ***REDACTED***"
            ShouldNotContain = @($headerToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name = "redacts authorization token scheme"
            CaseInput = "Authorization: token $headerToken"
            SensitiveTokens = @()
            ShouldContain = "Authorization: token ***REDACTED***"
            ShouldNotContain = @($headerToken)
            ShouldBeUnchanged = $false
        },
        @{
            Name = "does not redact too short ghp token"
            CaseInput = "Detected token: ghp_abc123"
            SensitiveTokens = @()
            ShouldContain = "Detected token: ghp_abc123"
            ShouldNotContain = @()
            ShouldBeUnchanged = $true
        },
        @{
            Name = "does not redact regex literal documentation string"
            CaseInput = '$redacted = $redacted -replace "ghp_[A-Za-z0-9]{36}", "***REDACTED***"'
            SensitiveTokens = @()
            ShouldContain = 'ghp_[A-Za-z0-9]{36}'
            ShouldNotContain = @()
            ShouldBeUnchanged = $true
        }
    )

    It "enforces redaction behavior for <Name>" -TestCases $cases {
        param($Name, $CaseInput, $SensitiveTokens, $ShouldContain, $ShouldNotContain, $ShouldBeUnchanged)

        $redacted = Redact-SensitiveText -Text $CaseInput -SensitiveTokens $SensitiveTokens

        if ($ShouldBeUnchanged) {
            $redacted | Should -BeExactly $CaseInput
        } else {
            $redacted | Should -Not -BeExactly $CaseInput
        }

        $redacted | Should -Match ([regex]::Escape($ShouldContain))
        foreach ($value in $ShouldNotContain) {
            $redacted | Should -Not -Match ([regex]::Escape($value))
        }
    }
}

Describe "Convert-ReviewThreadToOutputRecord" {
    It "returns null for resolved threads" {
        $thread = [pscustomobject]@{
            id = "T_x"
            isResolved = $true
            path = "src/file.ps1"
            startLine = 10
            line = 11
            comments = [pscustomobject]@{
                nodes = @([pscustomobject]@{ body = "hello" })
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "o" -Repo "r" -PrNumber 1 -GitHubHost "github.com"
        $record | Should -BeNullOrEmpty
    }

    It "maps unresolved thread fields" {
        $thread = [pscustomobject]@{
            id = "THREAD_1"
            isResolved = $false
            path = "src/main.ts"
            startLine = 10
            line = 12
            comments = [pscustomobject]@{
                nodes = @(
                    [pscustomobject]@{ body = "Top level comment" },
                    [pscustomobject]@{ body = "Reply summary" }
                )
            }
        }

        $record = Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 77 -GitHubHost "github.com"
        $record.path | Should -Be "src/main.ts"
        $record.lineStart | Should -Be 10
        $record.lineEnd | Should -Be 12
        $record.topLevelComment | Should -Be "Top level comment"
        $record.latestReplySummary | Should -Be "Reply summary"
        $record.threadId | Should -Be "THREAD_1"
    }

    It "throws when comments nodes is not array-wrapped" {
        $thread = [pscustomobject]@{
            id = "THREAD_SINGLE"
            isResolved = $false
            path = "src/single.ts"
            startLine = 21
            line = 21
            comments = [pscustomobject]@{
                nodes = [pscustomobject]@{ body = "Single comment only" }
            }
        }

        {
            [void](Convert-ReviewThreadToOutputRecord -Thread $thread -Owner "org" -Repo "repo" -PrNumber 7 -GitHubHost "github.com")
        } | Should -Throw "*E_MALFORMED_RESPONSE*comments.nodes must be an array*"
    }
}

Describe "Format-UnresolvedThreadsAsText" {
    It "renders exact delimiter contract" {
        $records = @(
            [pscustomobject]@{
                path = "src/a.ts"
                lineStart = 8
                lineEnd = 8
                topLevelComment = "Comment A"
                latestReplySummary = $null
                threadId = "1"
                prNumber = 1
                owner = "o"
                repo = "r"
                url = "https://github.com/o/r/pull/1"
            },
            [pscustomobject]@{
                path = "src/b.ts"
                lineStart = 12
                lineEnd = 20
                topLevelComment = "Comment B"
                latestReplySummary = "Reply B"
                threadId = "2"
                prNumber = 1
                owner = "o"
                repo = "r"
                url = "https://github.com/o/r/pull/1"
            }
        )

        $text = Format-UnresolvedThreadsAsText -Records $records
        $expected = @"
---
(src/a.ts) 8-8
Comment A
Latest reply summary: (none)
---
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

    It "falls back to GITHUB_TOKEN" {
        $env:GITHUB_TOKEN = "env-token"
        $value = Get-AuthToken -GitHubHost "github.com"
        $value | Should -Be "env-token"
    }

    It "falls back to GH_TOKEN if GITHUB_TOKEN is missing" {
        $env:GH_TOKEN = "gh-token"
        $value = Get-AuthToken -GitHubHost "github.com"
        $value | Should -Be "gh-token"
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
                                    nodes = @(
                                        @{ id = "T1"; isResolved = $false; path = "src/a.ts"; startLine = 1; line = 1; comments = @{ nodes = @(@{ body = "A" }, @{ body = "A reply" }) } },
                                        @{ id = "T2"; isResolved = $true;  path = "src/b.ts"; startLine = 2; line = 2; comments = @{ nodes = @(@{ body = "B" }) } }
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
                                nodes = @(
                                    @{ id = "T3"; isResolved = $false; path = "src/c.ts"; startLine = 3; line = 4; comments = @{ nodes = @(@{ body = "C" }) } }
                                )
                            }
                        }
                    }
                }
            }
        }

        $records = Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 100 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30))

        $records.Count | Should -Be 2
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "T1"
        ($records | Select-Object -ExpandProperty threadId) | Should -Contain "T3"
        ($records | Select-Object -ExpandProperty threadId) | Should -Not -Contain "T2"
    }

    It "redacts sensitive text in GraphQL errors" {
        $secret = "ghp_verysecrettoken1234567890"
        Mock Invoke-GitHubRequestWithRetry {
            return @{ errors = @(@{ message = "failure token=$secret" }) }
        }

        $thrown = $null
        try {
            [void](Get-UnresolvedReviewThreads -Owner "org" -Repo "repo" -PrNumber 10 -Endpoint "https://api.github.com/graphql" -Headers @{} -GitHubHost "github.com" -PerPage 100 -MaxPages 1 -OverallDeadlineUtc ([datetime]::UtcNow.AddSeconds(30)) -SensitiveTokens @($secret))
        } catch {
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
                                nodes = @{ id = "T1" }
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
                                nodes = @(
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
                                nodes = @()
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
                                nodes = @()
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
                Host = "github.com"
                Owner = "org"
                Repo = "repo"
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
                    path = "src/main.ts"
                    lineStart = 1
                    lineEnd = 1
                    topLevelComment = "hello"
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
                Host = "github.com"
                Owner = "org"
                Repo = "repo"
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

        $script:reviewCallCount = 0
        Mock Get-UnresolvedReviewThreads {
            $script:reviewCallCount++
            if ($script:reviewCallCount -eq 1) {
                throw "E_AUTH_INVALID: Authentication failed"
            }

            return @(
                [pscustomobject]@{
                    path = "src/recovered.ts"
                    lineStart = 1
                    lineEnd = 1
                    topLevelComment = "Recovered"
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
        $script:reviewCallCount | Should -Be 2
        $script:lastOutput | Should -Be "ok"
        Assert-MockCalled Validate-GitHubTokenForRepoAccess -Times 1 -Scope It -ParameterFilter {
            $AllowedGitHubHostsNormalized.Count -eq 1 -and $AllowedGitHubHostsNormalized[0] -eq "github.com"
        }
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 2 -Scope It -ParameterFilter {
            $AllowedGitHubHostsNormalized.Count -eq 1 -and $AllowedGitHubHostsNormalized[0] -eq "github.com"
        }
    }

    It "offers login fallback in non-interactive mode when PR URL is provided and credentials are missing" {
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
                Host = "github.com"
                Owner = "org"
                Repo = "repo"
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

        $script:reviewCallCount = 0
        Mock Get-UnresolvedReviewThreads {
            $script:reviewCallCount++
            if ($script:reviewCallCount -eq 1) {
                throw "E_AUTH_INVALID: Authentication failed"
            }

            return @(
                [pscustomobject]@{
                    path = "src/recovered.ts"
                    lineStart = 1
                    lineEnd = 1
                    topLevelComment = "Recovered"
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
        $script:reviewCallCount | Should -Be 2
        $script:lastOutput | Should -Be "ok"
        Assert-MockCalled Read-Host -Times 1 -Scope It
    }

    It "offers login fallback in non-interactive mode when provided credentials are invalid" {
        $PullRequestUrl = "https://github.com/org/repo/pull/5"
        $Owner = $null
        $Repo = $null
        $GitHubHost = "github.com"
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
                Host = "github.com"
                Owner = "org"
                Repo = "repo"
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

        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
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
            @(
                [pscustomobject]@{
                    path = "src/recovered.ts"
                    lineStart = 1
                    lineEnd = 1
                    topLevelComment = "Recovered"
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
        Assert-MockCalled Read-Host -Times 1 -Scope It
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
                Host = "github.com"
                Owner = "org"
                Repo = "repo"
                PullRequestNumber = 5
            }
        }

        Mock Get-AuthToken { $null }
        Mock Get-GitHubHeaders { @{ "Accept" = "application/json" } }
        Mock Assert-IsHashtableLike { }
        Mock Resolve-GitHubGraphQLEndpoint { "https://api.github.com/graphql" }
        Mock Test-CanPromptForLogin { $false }
        Mock Get-UnresolvedReviewThreads { throw "E_AUTH_INVALID: Authentication failed" }
        Mock Read-Host { "y" }

        { Invoke-Main } | Should -Throw "*E_AUTH_REQUIRED*"
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }
}

Describe "Strict-mode collection shape safety" {
    It "normalizes analyzer-like output for <CaseLabel>" -ForEach @(
        @{
            CaseLabel = "null output"
            InputValue = $null
            ExpectedCount = 0
        },
        @{
            CaseLabel = "single object output"
            InputValue = [pscustomobject]@{ RuleName = "RuleA" }
            ExpectedCount = 1
        },
        @{
            CaseLabel = "multiple object output"
            InputValue = @(
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
