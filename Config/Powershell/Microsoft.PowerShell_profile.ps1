Import-Module PSReadLine
Set-PSReadLineOption -EditMode Windows

try { $null = gcm pshazz -ea stop; pshazz init } catch { }
# >>> wt-cwd-split (report CWD to Windows Terminal via OSC 9;9; enables duplicate tab/pane dir inheritance) >>>
if ($env:WT_SESSION) {
    # re-run resilient: if something re-executed this profile and replaced the prompt
    # (e.g. a prompt tool re-initialising), re-capture and re-wrap; skip if already ours.
    $isOurs = ($null -ne $global:__WT_CWD_SPLIT_WRAPPER_SB -and $function:prompt -eq $global:__WT_CWD_SPLIT_WRAPPER_SB)
    if (-not $isOurs) {
        $global:__WT_CWD_SPLIT_ORIGINAL_PROMPT = $function:prompt
        function global:prompt {
            $osc99 = ''
            $loc = $executionContext.SessionState.Path.CurrentLocation
            if ($loc.Provider.Name -eq 'FileSystem') {
                # unquoted path: WT's explicit-direction duplicate-pane path does not
                # strip quotes (quoted paths silently fall back to startingDirectory)
                $osc99 = [string][char]27 + ']9;9;' + $loc.ProviderPath + [char]27 + '\'
            }
            $orig = $global:__WT_CWD_SPLIT_ORIGINAL_PROMPT
            if ($null -ne $orig) { $osc99 + (& $orig) }
            else { $osc99 + "PS $loc$('>' * ($nestedPromptLevel + 1)) " }
        }
        $global:__WT_CWD_SPLIT_WRAPPER_SB = $function:prompt
    }
}
# <<< wt-cwd-split <<<
