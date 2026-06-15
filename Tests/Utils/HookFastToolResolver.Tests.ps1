Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:resolverPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/HookFastToolResolver.sh"
    $script:bashCommand = Get-Command -Name "bash" -ErrorAction SilentlyContinue

    function Invoke-HookFastResolverBash {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Command,

            [Parameter(Mandatory = $false)]
            [hashtable]$Environment = @{}
        )

        if ($null -eq $script:bashCommand) {
            throw "bash is unavailable."
        }

        $previousValues = @{}
        foreach ($key in $Environment.Keys) {
            $previousValues[$key] = [Environment]::GetEnvironmentVariable([string]$key)
            [Environment]::SetEnvironmentVariable([string]$key, [string]$Environment[$key])
        }

        try {
            Push-Location -LiteralPath $script:repoRoot
            try {
                $output = @(& $script:bashCommand.Source --noprofile --norc -c $Command 2>&1)
                $exitCode = $LASTEXITCODE
            }
            finally {
                Pop-Location
            }
        }
        finally {
            foreach ($key in $Environment.Keys) {
                [Environment]::SetEnvironmentVariable([string]$key, $previousValues[$key])
            }
        }

        [pscustomobject]@{
            ExitCode = $exitCode
            Output   = @($output)
        }
    }

    function ConvertTo-HookFastBashPath {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        if ([System.IO.Path]::DirectorySeparatorChar -ne '\') {
            return $Path
        }

        $normalizedPath = ([System.IO.Path]::GetFullPath($Path)) -replace '\\', '/'
        if ($normalizedPath -match '^([A-Za-z]):/(.*)$') {
            return "/$($matches[1].ToLowerInvariant())/$($matches[2])"
        }

        return $normalizedPath
    }

    function Write-Utf8NoBomFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,

            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$Content
        )

        $parent = [System.IO.Path]::GetDirectoryName($Path)
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            [void][System.IO.Directory]::CreateDirectory($parent)
        }

        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    function Get-HookFastFixtureToolMetadata {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ToolPath
        )

        $command = @'
. "$WALLSTOP_TEST_RESOLVER_PATH"
tool_path="$WALLSTOP_TEST_TOOL_PATH"
tool_size="$(wallstop_fast_read_file_size "$tool_path")"
tool_mtime="$(wallstop_fast_read_file_mtime "$tool_path")"
tool_fingerprint="$(wallstop_fast_compute_tool_fingerprint "$tool_path" "$tool_size")"
printf '%s\n%s\n%s\n' "$tool_size" "$tool_mtime" "$tool_fingerprint"
'@
        $result = Invoke-HookFastResolverBash -Command $command -Environment @{
            WALLSTOP_TEST_RESOLVER_PATH = ConvertTo-HookFastBashPath -Path $script:resolverPath
            WALLSTOP_TEST_TOOL_PATH     = ConvertTo-HookFastBashPath -Path $ToolPath
        }

        if ($result.ExitCode -ne 0 -or $result.Output.Count -lt 3) {
            throw "E_TEST_HOOK_FAST_METADATA_FAILED: exitCode=$($result.ExitCode); output=$($result.Output -join "`n")"
        }

        [pscustomobject]@{
            Size        = [string]$result.Output[0]
            Mtime       = [string]$result.Output[1]
            Fingerprint = [string]$result.Output[2]
        }
    }

    function Write-HookFastFixtureManifest {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Root,

            [Parameter(Mandatory = $true)]
            [string]$Version,

            [Parameter(Mandatory = $true)]
            [object[]]$Assets
        )

        $assetBlocks = @(
            foreach ($asset in $Assets) {
                @"
        "$($asset.Key)": {
          "assetName": "$($asset.AssetName)",
          "sha256": "$($asset.Sha256)",
          "kind": "zip"
        }
"@
            }
        )

        $manifestContent = @"
{
  "tools": {
    "actionlint": {
      "version": "$Version",
      "assets": {
$($assetBlocks -join ",`n")
      }
    }
  }
}
"@
        Write-Utf8NoBomFile -Path (Join-Path -Path $Root -ChildPath "Scripts/Utils/Quality/native-quality-tools.json") -Content $manifestContent
    }

    function Add-HookFastFixtureAsset {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Root,

            [Parameter(Mandatory = $true)]
            [string]$Version,

            [Parameter(Mandatory = $true)]
            [string]$AssetKey,

            [Parameter(Mandatory = $true)]
            [string]$AssetName,

            [Parameter(Mandatory = $true)]
            [string]$AssetSha256,

            [Parameter(Mandatory = $false)]
            [string]$Content = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n"
        )

        $suffix = if ($AssetKey -like "windows-*") { ".exe" } else { "" }
        $assetRoot = Join-Path -Path $Root -ChildPath (".tools/native-quality/actionlint/{0}/{1}" -f $Version, $AssetKey)
        $toolPath = Join-Path -Path $assetRoot -ChildPath ("bin/actionlint{0}" -f $suffix)
        Write-Utf8NoBomFile -Path $toolPath -Content $Content

        $metadata = Get-HookFastFixtureToolMetadata -ToolPath $toolPath
        $executableHash = (Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $markerContent = @"
{
  "tool": "actionlint",
  "version": "$Version",
  "assetKey": "$AssetKey",
  "assetName": "$AssetName",
  "sha256": "$AssetSha256",
  "executableSha256": "$executableHash",
  "executableSize": "$($metadata.Size)",
  "executableMtime": "$($metadata.Mtime)",
  "executableFastFingerprintVersion": "sampled-sha256-v1-65536",
  "executableFastFingerprint": "$($metadata.Fingerprint)"
}
"@
        Write-Utf8NoBomFile -Path (Join-Path -Path $assetRoot -ChildPath "asset.json") -Content $markerContent

        [pscustomobject]@{
            ToolPath     = $toolPath
            BashToolPath = ConvertTo-HookFastBashPath -Path $toolPath
            Metadata     = $metadata
        }
    }

    function New-HookFastFixture {
        param(
            [Parameter(Mandatory = $true)]
            [object[]]$Assets,

            [Parameter(Mandatory = $false)]
            [string]$Version = "1.0.0"
        )

        $root = Join-Path -Path $TestDrive -ChildPath ("hook-fast-fixture-{0}" -f [guid]::NewGuid().ToString("N"))
        [void][System.IO.Directory]::CreateDirectory($root)
        Write-HookFastFixtureManifest -Root $root -Version $Version -Assets $Assets

        $installedAssets = @{}
        foreach ($asset in $Assets) {
            $installedAssets[$asset.Key] = Add-HookFastFixtureAsset -Root $root -Version $Version -AssetKey $asset.Key -AssetName $asset.AssetName -AssetSha256 $asset.Sha256 -Content $asset.Content
        }

        [pscustomobject]@{
            Root            = $root
            BashRoot        = ConvertTo-HookFastBashPath -Path $root
            Version         = $Version
            InstalledAssets = $installedAssets
        }
    }

    function Invoke-HookFastResolution {
        param(
            [Parameter(Mandatory = $true)]
            [string]$FixtureRoot,

            [Parameter(Mandatory = $false)]
            [hashtable]$Environment = @{},

            [Parameter(Mandatory = $false)]
            [string]$CommandPrefix = ""
        )

        $command = @"
$CommandPrefix
. "`$WALLSTOP_TEST_RESOLVER_PATH"
wallstop_resolve_managed_fast_tool "`$WALLSTOP_TEST_FIXTURE_ROOT" ".tools/native-quality" "actionlint"
"@

        $mergedEnvironment = @{
            WALLSTOP_TEST_RESOLVER_PATH = ConvertTo-HookFastBashPath -Path $script:resolverPath
            WALLSTOP_TEST_FIXTURE_ROOT  = ConvertTo-HookFastBashPath -Path $FixtureRoot
        }
        foreach ($key in $Environment.Keys) {
            $mergedEnvironment[$key] = $Environment[$key]
        }

        Invoke-HookFastResolverBash -Command $command -Environment $mergedEnvironment
    }

    function Get-CurrentHookFastPlatformKey {
        $command = '. "$WALLSTOP_TEST_RESOLVER_PATH"; wallstop_fast_current_platform_key'
        $result = Invoke-HookFastResolverBash -Command $command -Environment @{
            WALLSTOP_TEST_RESOLVER_PATH = ConvertTo-HookFastBashPath -Path $script:resolverPath
        }

        if ($result.ExitCode -ne 0 -or $result.Output.Count -lt 1) {
            throw "E_TEST_HOOK_FAST_PLATFORM_UNAVAILABLE: exitCode=$($result.ExitCode); output=$($result.Output -join "`n")"
        }

        [string]$result.Output[0]
    }

    function New-HookFastAssetDefinition {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Key,

            [Parameter(Mandatory = $false)]
            [string]$Sha256 = ("1" * 64),

            [Parameter(Mandatory = $false)]
            [string]$Content = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n"
        )

        [pscustomobject]@{
            Key       = $Key
            AssetName = "actionlint-$Key.zip"
            Sha256    = $Sha256
            Content   = $Content
        }
    }
}

AfterAll {
    Remove-Item -Path Function:Invoke-HookFastResolverBash -ErrorAction SilentlyContinue
    Remove-Item -Path Function:ConvertTo-HookFastBashPath -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Write-Utf8NoBomFile -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Get-HookFastFixtureToolMetadata -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Write-HookFastFixtureManifest -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Add-HookFastFixtureAsset -ErrorAction SilentlyContinue
    Remove-Item -Path Function:New-HookFastFixture -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Invoke-HookFastResolution -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Get-CurrentHookFastPlatformKey -ErrorAction SilentlyContinue
    Remove-Item -Path Function:New-HookFastAssetDefinition -ErrorAction SilentlyContinue
}

Describe "Hook fast tool resolver" {
    It "parses as Bash" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        & $script:bashCommand.Source --noprofile --norc -n $script:resolverPath
        $LASTEXITCODE | Should -Be 0
    }

    It "prefers native Windows ARM64 assets when an x64 Bash process runs on Windows ARM64" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $command = '. "Scripts/Utils/Common/HookFastToolResolver.sh"; wallstop_fast_candidate_keys windows-x64'
        $result = Invoke-HookFastResolverBash -Command $command -Environment @{ PROCESSOR_ARCHITEW6432 = "ARM64" }

        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Be "windows-arm64 windows-x64"
    }

    It "keeps true Windows x64 candidate selection on x64 hosts" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $command = 'unset PROCESSOR_ARCHITEW6432 PROCESSOR_IDENTIFIER; PROCESSOR_ARCHITECTURE=AMD64; . "Scripts/Utils/Common/HookFastToolResolver.sh"; wallstop_fast_candidate_keys windows-x64'
        $result = Invoke-HookFastResolverBash -Command $command

        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Be "windows-x64"
    }

    It "does not widen Linux or macOS candidate keys across architectures" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $command = '. "Scripts/Utils/Common/HookFastToolResolver.sh"; wallstop_fast_candidate_keys linux-arm64; wallstop_fast_candidate_keys darwin-x64'
        $result = Invoke-HookFastResolverBash -Command $command

        $result.ExitCode | Should -Be 0
        @($result.Output) | Should -Be @("linux-arm64", "darwin-x64")
    }

    It "resolves a manifest-pinned cached tool with a matching marker" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $platformKey = Get-CurrentHookFastPlatformKey
        $asset = New-HookFastAssetDefinition -Key $platformKey
        $fixture = New-HookFastFixture -Assets @($asset)
        $result = Invoke-HookFastResolution -FixtureRoot $fixture.Root

        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Be $fixture.InstalledAssets[$platformKey].BashToolPath
    }

    It "rejects a cached marker when the manifest asset hash changes" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $platformKey = Get-CurrentHookFastPlatformKey
        $asset = New-HookFastAssetDefinition -Key $platformKey -Sha256 ("2" * 64)
        $fixture = New-HookFastFixture -Assets @($asset)
        $assetRoot = Join-Path -Path $fixture.Root -ChildPath (".tools/native-quality/actionlint/{0}/{1}" -f $fixture.Version, $platformKey)
        $markerPath = Join-Path -Path $assetRoot -ChildPath "asset.json"
        $markerContent = [System.IO.File]::ReadAllText($markerPath, [System.Text.Encoding]::UTF8)
        Write-Utf8NoBomFile -Path $markerPath -Content ($markerContent -replace ('"sha256": "{0}"' -f ("2" * 64)), ('"sha256": "{0}"' -f ("3" * 64)))

        $result = Invoke-HookFastResolution -FixtureRoot $fixture.Root

        $result.ExitCode | Should -Be 1
        ($result.Output -join "`n") | Should -Be ""
    }

    It "rejects a cached marker when the executable fingerprint no longer matches" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $platformKey = Get-CurrentHookFastPlatformKey
        $asset = New-HookFastAssetDefinition -Key $platformKey -Content ("a" * 32)
        $fixture = New-HookFastFixture -Assets @($asset)
        $installedAsset = $fixture.InstalledAssets[$platformKey]
        Write-Utf8NoBomFile -Path $installedAsset.ToolPath -Content ("b" * 32)
        [System.IO.File]::SetLastWriteTimeUtc(
            $installedAsset.ToolPath,
            [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$installedAsset.Metadata.Mtime).UtcDateTime
        )

        $result = Invoke-HookFastResolution -FixtureRoot $fixture.Root

        $result.ExitCode | Should -Be 1
        ($result.Output -join "`n") | Should -Be ""
    }

    It "uses Windows ARM64 assets from an x64 Bash process on Windows ARM64" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $arm64Asset = New-HookFastAssetDefinition -Key "windows-arm64" -Sha256 ("4" * 64)
        $x64Asset = New-HookFastAssetDefinition -Key "windows-x64" -Sha256 ("5" * 64)
        $fixture = New-HookFastFixture -Assets @($arm64Asset, $x64Asset)
        $fakeBinPath = Join-Path -Path $TestDrive -ChildPath ("hook-fast-uname-{0}" -f [guid]::NewGuid().ToString("N"))
        $fakeUnamePath = Join-Path -Path $fakeBinPath -ChildPath "uname"
        Write-Utf8NoBomFile -Path $fakeUnamePath -Content @'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf '%s\n' "x86_64" ;;
  *) printf '%s\n' "MINGW64_NT-10.0" ;;
esac
'@
        $chmodResult = Invoke-HookFastResolverBash -Command 'chmod +x "$WALLSTOP_TEST_FAKE_UNAME"' -Environment @{
            WALLSTOP_TEST_FAKE_UNAME = ConvertTo-HookFastBashPath -Path $fakeUnamePath
        }
        $chmodResult.ExitCode | Should -Be 0

        $result = Invoke-HookFastResolution -FixtureRoot $fixture.Root -CommandPrefix 'PATH="$WALLSTOP_TEST_FAKE_BIN:$PATH"; export PATH' -Environment @{
            PROCESSOR_ARCHITECTURE  = "AMD64"
            PROCESSOR_ARCHITEW6432  = "ARM64"
            WALLSTOP_TEST_FAKE_BIN  = ConvertTo-HookFastBashPath -Path $fakeBinPath
        }

        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Be $fixture.InstalledAssets["windows-arm64"].BashToolPath
    }

    It "falls back to Windows x64 assets on Windows ARM64 when no ARM64 asset is pinned" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $x64Asset = New-HookFastAssetDefinition -Key "windows-x64" -Sha256 ("6" * 64)
        $fixture = New-HookFastFixture -Assets @($x64Asset)
        $fakeBinPath = Join-Path -Path $TestDrive -ChildPath ("hook-fast-uname-{0}" -f [guid]::NewGuid().ToString("N"))
        $fakeUnamePath = Join-Path -Path $fakeBinPath -ChildPath "uname"
        Write-Utf8NoBomFile -Path $fakeUnamePath -Content @'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf '%s\n' "x86_64" ;;
  *) printf '%s\n' "MINGW64_NT-10.0" ;;
esac
'@
        $chmodResult = Invoke-HookFastResolverBash -Command 'chmod +x "$WALLSTOP_TEST_FAKE_UNAME"' -Environment @{
            WALLSTOP_TEST_FAKE_UNAME = ConvertTo-HookFastBashPath -Path $fakeUnamePath
        }
        $chmodResult.ExitCode | Should -Be 0

        $result = Invoke-HookFastResolution -FixtureRoot $fixture.Root -CommandPrefix 'PATH="$WALLSTOP_TEST_FAKE_BIN:$PATH"; export PATH' -Environment @{
            PROCESSOR_ARCHITECTURE  = "AMD64"
            PROCESSOR_ARCHITEW6432  = "ARM64"
            WALLSTOP_TEST_FAKE_BIN  = ConvertTo-HookFastBashPath -Path $fakeBinPath
        }

        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Be $fixture.InstalledAssets["windows-x64"].BashToolPath
    }

    It "does not fall back to Windows x64 when a pinned Windows ARM64 asset is stale" {
        if ($null -eq $script:bashCommand) {
            Set-ItResult -Skipped -Because "bash is unavailable."
            return
        }

        $arm64Asset = New-HookFastAssetDefinition -Key "windows-arm64" -Sha256 ("7" * 64)
        $x64Asset = New-HookFastAssetDefinition -Key "windows-x64" -Sha256 ("8" * 64)
        $fixture = New-HookFastFixture -Assets @($arm64Asset, $x64Asset)
        $arm64ToolPath = $fixture.InstalledAssets["windows-arm64"].ToolPath
        Write-Utf8NoBomFile -Path $arm64ToolPath -Content "stale-arm64-tool`n"

        $fakeBinPath = Join-Path -Path $TestDrive -ChildPath ("hook-fast-uname-{0}" -f [guid]::NewGuid().ToString("N"))
        $fakeUnamePath = Join-Path -Path $fakeBinPath -ChildPath "uname"
        Write-Utf8NoBomFile -Path $fakeUnamePath -Content @'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf '%s\n' "x86_64" ;;
  *) printf '%s\n' "MINGW64_NT-10.0" ;;
esac
'@
        $chmodResult = Invoke-HookFastResolverBash -Command 'chmod +x "$WALLSTOP_TEST_FAKE_UNAME"' -Environment @{
            WALLSTOP_TEST_FAKE_UNAME = ConvertTo-HookFastBashPath -Path $fakeUnamePath
        }
        $chmodResult.ExitCode | Should -Be 0

        $result = Invoke-HookFastResolution -FixtureRoot $fixture.Root -CommandPrefix 'PATH="$WALLSTOP_TEST_FAKE_BIN:$PATH"; export PATH' -Environment @{
            PROCESSOR_ARCHITECTURE = "AMD64"
            PROCESSOR_ARCHITEW6432 = "ARM64"
            WALLSTOP_TEST_FAKE_BIN = ConvertTo-HookFastBashPath -Path $fakeBinPath
        }

        $result.ExitCode | Should -Be 1
        ($result.Output -join "`n") | Should -Be ""
    }
}
