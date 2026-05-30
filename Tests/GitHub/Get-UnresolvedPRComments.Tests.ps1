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
            Name                    = "accepts exact-case GraphQL variable payload keys"
            Variables               = @{ owner = "org"; repo = "repo"; prNumber = 10 }
            RejectUnexpected        = $false
            ShouldThrow             = $false
            ExpectedThrowPattern    = ""
        },
        @{
            Name                    = "rejects payload keys that differ by casing"
            Variables               = @{ Owner = "org"; Repo = "repo"; prNumber = 10 }
            RejectUnexpected        = $false
            ShouldThrow             = $true
            ExpectedThrowPattern    = "*E_CONFIG_ERROR*case mismatch*owner*Owner*repo*Repo*"
        },
        @{
            Name                    = "rejects unexpected variables when strict mode is requested"
            Variables               = @{ owner = "org"; repo = "repo"; prNumber = 10; extra = "unexpected" }
            RejectUnexpected        = $true
            ShouldThrow             = $true
            ExpectedThrowPattern    = "*E_CONFIG_ERROR*unexpected variables*extra*"
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
        @{ Case = "multiple values from real HttpHeaders via TryGetValues"; Backing = "HttpHeaders";       Entries = @{ "X-OAuth-Scopes" = @("repo", "read:org") }; LookupKey = "X-OAuth-Scopes"; Expected = @("repo", "read:org") }
        @{ Case = "real HttpHeaders regardless of key casing";              Backing = "HttpHeaders";       Entries = @{ "X-OAuth-Scopes" = @("repo") };             LookupKey = "x-oauth-scopes"; Expected = @("repo") }
        @{ Case = "array-valued hashtable entries";                         Backing = "Hashtable";         Entries = @{ "X-OAuth-Scopes" = @("repo", "read:org") }; LookupKey = "X-OAuth-Scopes"; Expected = @("repo", "read:org") }
        @{ Case = "case-insensitive generic dictionary entries";            Backing = "GenericDictionary"; Entries = @{ "X-OAuth-Scopes" = "repo" };                LookupKey = "x-oauth-scopes"; Expected = @("repo") }
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
            Name              = "redacts generic ghp token"
            CaseInput         = "Detected token: $ghpToken"
            SensitiveTokens   = @()
            ShouldContain     = "***REDACTED***"
            ShouldNotContain  = @($ghpToken)
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
            CaseInput         = '$redacted = $redacted -replace "ghp_[A-Za-z0-9]{36}", "***REDACTED***"'
            SensitiveTokens   = @()
            ShouldContain     = 'ghp_[A-Za-z0-9]{36}'
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

Describe "Get-ClipboardCommand" {
    It "prefers Set-Clipboard when available" {
        Mock Get-Command {
            [pscustomobject]@{ Name = "Set-Clipboard" }
        } -ParameterFilter { $Name -eq "Set-Clipboard" }

        $result = Get-ClipboardCommand
        $result | Should -Be "Set-Clipboard"
    }

    It "falls back to xclip when Set-Clipboard and pbcopy are unavailable" {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq "Set-Clipboard" }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq "pbcopy" }
        Mock Get-Command { [pscustomobject]@{ Name = "xclip" } } -ParameterFilter { $Name -eq "xclip" }

        $result = Get-ClipboardCommand
        $result | Should -Be "xclip"
    }
}

Describe "Get-ClipboardCommandPriority" {
    It "adds OSC52 strategy before Set-Clipboard when terminal supports it" {
        Mock Get-Command {
            [pscustomobject]@{
                Name       = "Set-Clipboard"
                Parameters = @{ AsOSC52 = $true }
            }
        } -ParameterFilter { $Name -eq "Set-Clipboard" }
        Mock Get-Command { $null } -ParameterFilter { $Name -ne "Set-Clipboard" }
        Mock Test-ShouldUseClipboardOsc52 { $true }

        $commands = @(Get-ClipboardCommandPriority)
        $commands[0] | Should -Be "Set-Clipboard-AsOSC52"
        $commands[1] | Should -Be "Set-Clipboard"
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

    It "falls back to Set-Clipboard when OSC52 attempt fails" {
        $script:clipboardAttemptOrder = @()
        Mock Get-ClipboardCommandPriority { @("Set-Clipboard-AsOSC52", "Set-Clipboard") }
        Mock Set-ClipboardValue {
            param(
                [string]$Value,
                [switch]$AsOSC52
            )

            if ($AsOSC52.IsPresent) {
                $script:clipboardAttemptOrder += "Set-Clipboard-AsOSC52"
                throw "Set-Clipboard -AsOSC52 failed"
            }

            $script:clipboardAttemptOrder += "Set-Clipboard"
        }

        $copied = Copy-ToClipboard -Text "copy me"

        $copied | Should -BeTrue
        (($script:clipboardAttemptOrder) -join ",") | Should -Be "Set-Clipboard-AsOSC52,Set-Clipboard" -Because "clipboard fallback should preserve OSC52-first attempt order and then recover with plain Set-Clipboard"
        Assert-MockCalled Set-ClipboardValue -Times 2 -Scope It
        Assert-MockCalled Set-ClipboardValue -Times 1 -Scope It -ParameterFilter { $AsOSC52.IsPresent }
        Assert-MockCalled Set-ClipboardValue -Times 1 -Scope It -ParameterFilter { -not $AsOSC52.IsPresent }
    }

    It "uses Set-Clipboard -AsOSC52 when OSC52 strategy is selected" {
        Mock Get-ClipboardCommandPriority { @("Set-Clipboard-AsOSC52") }
        Mock Set-ClipboardValue { }

        $copied = Copy-ToClipboard -Text "copy me"

        $copied | Should -BeTrue
        Assert-MockCalled Set-ClipboardValue -Times 1 -Scope It -ParameterFilter { $AsOSC52.IsPresent -and $Value -eq "copy me" }
    }

    It "falls back across native clipboard tools in priority order" {
        $script:nativeClipboardAttemptOrder = @()
        Mock Get-ClipboardCommandPriority { @("pbcopy", "xclip", "xsel") }
        try {
            function pbcopy {
                param(
                    [Parameter(ValueFromPipeline = $true)]
                    [AllowNull()]
                    [string]$InputObject
                )

                process {
                    $script:nativeClipboardAttemptOrder += "pbcopy"
                    $global:LASTEXITCODE = 17
                }
            }

            function xclip {
                param(
                    [string]$selection,
                    [Parameter(ValueFromPipeline = $true)]
                    [AllowNull()]
                    [string]$InputObject
                )

                process {
                    $script:nativeClipboardAttemptOrder += "xclip"
                    $global:LASTEXITCODE = 42
                }
            }

            function xsel {
                param(
                    [string]$clipboard,
                    [string]$input,
                    [Parameter(ValueFromPipeline = $true)]
                    [AllowNull()]
                    [string]$InputObject
                )

                process {
                    $script:nativeClipboardAttemptOrder += "xsel"
                    $global:LASTEXITCODE = 0
                }
            }

            $copied = Copy-ToClipboard -Text "copy me"

            $copied | Should -BeTrue
            (($script:nativeClipboardAttemptOrder) -join ",") | Should -Be "pbcopy,xclip,xsel" -Because "native fallback should continue through failed tools and stop after the first success"
        }
        finally {
            Remove-Item -Path Function:pbcopy -ErrorAction SilentlyContinue
            Remove-Item -Path Function:xclip -ErrorAction SilentlyContinue
            Remove-Item -Path Function:xsel -ErrorAction SilentlyContinue
        }
    }
}

Describe "Set-ClipboardValue" {
    # The seam exists so Copy-ToClipboard's clipboard tests can mock a command with an
    # edition-stable parameter set; these tests assert the seam itself routes to Set-Clipboard
    # correctly (the branch selection that Copy-ToClipboard's mocks otherwise stub out).
    It "calls Set-Clipboard without -AsOSC52 by default" {
        Mock Set-Clipboard { }

        Set-ClipboardValue -Value "plain copy"

        Assert-MockCalled Set-Clipboard -Times 1 -Scope It -ParameterFilter { -not $AsOSC52.IsPresent -and $Value -eq "plain copy" }
    }

    It "routes -AsOSC52 through to Set-Clipboard when the parameter exists on this edition" {
        $setClipboard = Get-Command Set-Clipboard -ErrorAction SilentlyContinue
        if ($null -eq $setClipboard -or -not $setClipboard.Parameters.ContainsKey('AsOSC52')) {
            # On Windows PowerShell 5.1 Set-Clipboard has no -AsOSC52, and production never
            # selects the OSC52 strategy there (Get-ClipboardCommandPriority gates on the same
            # capability check), so the branch is unreachable and not worth a brittle shim.
            Set-ItResult -Skipped -Because "Set-Clipboard -AsOSC52 is unavailable on this edition (Windows PowerShell 5.1)."
            return
        }

        Mock Set-Clipboard { }

        Set-ClipboardValue -Value "osc52 copy" -AsOSC52

        Assert-MockCalled Set-Clipboard -Times 1 -Scope It -ParameterFilter { $AsOSC52.IsPresent -and $Value -eq "osc52 copy" }
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

Describe "Format-UnresolvedThreadsAsJson" {
    It "always emits an array and preserves lower-camel schema keys" {
        $records = @(
            [pscustomobject]@{
                path               = "src/main.ts"
                lineStart          = 10
                lineEnd            = 12
                topLevelComment    = "Top"
                latestReplySummary = "Reply"
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
        ($propertyNames -ccontains "owner") | Should -BeTrue
        ($propertyNames -ccontains "repo") | Should -BeTrue
        ($propertyNames -ccontains "Path") | Should -BeFalse
        ($propertyNames -ccontains "Owner") | Should -BeFalse
        ($propertyNames -ccontains "Repo") | Should -BeFalse

        $parsed[0].path | Should -Be "src/main.ts"
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
        $secret = "ghp_verysecrettoken1234567890"
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

        $script:reviewCallCount = 0
        Mock Get-UnresolvedReviewThreads {
            $script:reviewCallCount++
            if ($script:reviewCallCount -eq 1) {
                throw "E_AUTH_INVALID: Authentication failed"
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

        $script:reviewCallCount = 0
        Mock Get-UnresolvedReviewThreads {
            $script:reviewCallCount++
            if ($script:reviewCallCount -eq 1) {
                throw "E_AUTH_INVALID: Authentication failed"
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
        Assert-MockCalled Read-Host -Times 1 -Scope It
    }

    It "offers login fallback in interactive mode when provided credentials are invalid" {
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
        Assert-MockCalled Read-Host -Times 1 -Scope It
    }

    It "does not offer fallback in direct owner/repo mode when credentials are invalid" {
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

        { Invoke-Main } | Should -Throw "*E_AUTH_INVALID*"
        Assert-MockCalled Get-GitHubHeaders -Times 1 -Scope It -ParameterFilter { $AuthToken -eq "bad-token" }
        Assert-MockCalled Get-GitHubHeaders -Times 1 -Scope It -ParameterFilter { [string]::IsNullOrWhiteSpace($AuthToken) }
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

        Mock Get-AuthToken { "expired-token" }
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

        Mock Get-UnresolvedReviewThreads {
            @(
                [pscustomobject]@{
                    path               = "src/public.ts"
                    lineStart          = 1
                    lineEnd            = 1
                    topLevelComment    = "Public"
                    latestReplySummary = $null
                }
            )
        }

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
        Assert-MockCalled Get-UnresolvedReviewThreads -Times 1 -Scope It -ParameterFilter { -not $Headers.ContainsKey("Authorization") }
        Assert-MockCalled Read-Host -Times 0 -Scope It
    }

    It "offers login fallback when anonymous retry fails with a non-auth error" {
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

            return "fresh-token"
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
        Mock Read-Host { "y" }

        $script:reviewCallCount = 0
        Mock Get-UnresolvedReviewThreads {
            param($Headers)

            $script:reviewCallCount++
            if ($null -eq $Headers -or -not $Headers.ContainsKey("Authorization")) {
                throw "E_NETWORK_TIMEOUT: Anonymous request timed out"
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

        Mock Format-UnresolvedThreadsAsText { "recovered after prompt" }
        $script:lastOutput = $null
        Mock Write-Output {
            param($InputObject)
            $script:lastOutput = $InputObject
        }

        Invoke-Main

        $script:lastOutput | Should -Be "recovered after prompt"
        $script:authTokenCallCount | Should -Be 2
        $script:validateCallCount | Should -Be 2
        $script:reviewCallCount | Should -Be 2
        Assert-MockCalled Read-Host -Times 1 -Scope It
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

        Mock Get-AuthToken { "expired-token" }
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
        Mock Get-UnresolvedReviewThreads { throw "E_NETWORK_TIMEOUT: Anonymous request timed out" }

        { Invoke-Main } | Should -Throw "*E_NETWORK_TIMEOUT*"
        Assert-MockCalled Read-Host -Times 0 -Scope It
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

        Mock Get-AuthToken { "secret-token-12345" }
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
        Mock Get-UnresolvedReviewThreads { throw "E_NETWORK_TIMEOUT: leaked secret-token-12345" }

        $thrownMessage = $null
        try {
            Invoke-Main
        }
        catch {
            $thrownMessage = $_.Exception.Message
        }

        $thrownMessage | Should -Match "E_NETWORK_TIMEOUT"
        $thrownMessage | Should -Not -Match [regex]::Escape("secret-token-12345")
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
        Mock Get-UnresolvedReviewThreads { throw "E_AUTH_INVALID: Authentication failed" }
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
