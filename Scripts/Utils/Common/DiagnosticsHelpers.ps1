function Get-OutputPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Alias('Output')]
        [object[]]$OutputLines = @(),

        [Parameter(Mandatory = $false)]
        [Alias('MaxPreviewLines')]
        [ValidateRange(1,200)]
        [int]$MaxLines = 5,

        [Parameter(Mandatory = $false)]
        [Alias('MaxLength')]
        [ValidateRange(32,4096)]
        [int]$MaxCharacters = 640,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0,4096)]
        [int]$PerLineMaxCharacters = 0,

        [Parameter(Mandatory = $false)]
        [switch]$FilterBlankLines,

        [Parameter(Mandatory = $false)]
        [switch]$HeadTailWhenTruncated,

        [Parameter(Mandatory = $false)]
        [switch]$CollapseWhitespace
    )

    $materializedLines = @(
        $OutputLines |
            ForEach-Object {
                if ($null -eq $_) {
                    return ""
                }

                return [string]$_
            }
    )

    if ($FilterBlankLines) {
        $materializedLines = @($materializedLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($materializedLines.Count -eq 0) {
        return "(no output)"
    }

    if ($CollapseWhitespace) {
        $collapsed = (($materializedLines -join " ") -replace "\s+"," ").Trim()
        if ([string]::IsNullOrWhiteSpace($collapsed)) {
            return "(no output)"
        }

        if ($collapsed.Length -le $MaxCharacters) {
            return $collapsed
        }

        return ($collapsed.Substring(0, $MaxCharacters) + " ...")
    }

    $formatPreviewLine = {
        param([string]$Line)

        if ([string]::IsNullOrWhiteSpace($Line)) {
            return "(blank line)"
        }

        $trimmed = $Line.Trim()
        if ($PerLineMaxCharacters -gt 0 -and $trimmed.Length -gt $PerLineMaxCharacters) {
            return ($trimmed.Substring(0, $PerLineMaxCharacters) + "...")
        }

        return $trimmed
    }

    if ($HeadTailWhenTruncated) {
        if ($materializedLines.Count -le $MaxLines) {
            $previewLines = @($materializedLines | ForEach-Object { & $formatPreviewLine $_ })
            return ($previewLines -join " | ")
        }

        $headCount = [int][math]::Ceiling($MaxLines / 2)
        $tailCount = $MaxLines - $headCount
        if ($tailCount -lt 1) {
            $tailCount = 1
            $headCount = [math]::Max($MaxLines - $tailCount, 1)
        }

        $headPreview = @($materializedLines | Select-Object -First $headCount | ForEach-Object { & $formatPreviewLine $_ })
        $tailPreview = @($materializedLines | Select-Object -Last $tailCount | ForEach-Object { & $formatPreviewLine $_ })
        $omittedCount = [math]::Max($materializedLines.Count - ($headCount + $tailCount), 0)

        return (
            "head: {0} | ... ({1} omitted line(s)) ... | tail: {2}" -f
            ($headPreview -join " | "),
            $omittedCount,
            ($tailPreview -join " | ")
        )
    }

    $preview = @(
        $materializedLines |
            Select-Object -First $MaxLines |
            ForEach-Object { & $formatPreviewLine $_ }
    ) -join ' | '

    if ([string]::IsNullOrWhiteSpace($preview)) {
        return "(blank output)"
    }

    if ($preview.Length -gt $MaxCharacters) {
        return ("{0}...(truncated)" -f $preview.Substring(0, $MaxCharacters))
    }

    return $preview
}
