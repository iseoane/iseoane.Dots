# PowerShell 7 profile — deployed to $PROFILE (Documents\PowerShell).
# Source of truth lives in the dots repo (powershell/); copy it over after edits.

# -----------------------------------------------------------------
# 1. Prompt (Starship — same prompt as zsh on Debian)
# -----------------------------------------------------------------
# oh-my-posh kept as fallback: comment the Starship line and uncomment
# one of these to restore it.
# oh-my-posh init pwsh --config 'catppuccin_mocha' | Invoke-Expression
# oh-my-posh init pwsh --config "$env:USERPROFILE\.config\ohmyposh\kushal-catppuccin.omp.json" | Invoke-Expression
# Guarded: an unresolved &starship throws a terminating error, which would
# abort the rest of this profile (modules, shims, herdr wrappers). Fall back
# to the default prompt instead.
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (&starship init powershell)
} else {
    Write-Warning "starship not found on PATH; using the default prompt"
}

# -----------------------------------------------------------------
# 2. Modules (icons, predictions, docker completion)
# -----------------------------------------------------------------
# Colored icons for ls / dir
Import-Module Terminal-Icons

# PSReadLine mirrors the zsh setup: inline gray suggestions from history
# (zsh-autosuggestions), Ctrl+Space to accept, prefix history search on
# Up/Down. Syntax highlighting is built into PSReadLine.
Import-Module PSReadLine
Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle InlineView
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineKeyHandler -Key Ctrl+Spacebar -Function AcceptSuggestion
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

# Smart completion for docker commands and containers
Import-Module DockerCompletion

# -----------------------------------------------------------------
# 3. Unix muscle-memory shims
# -----------------------------------------------------------------
# Let unix-style `ls -ltr` / `ls -la` work instead of erroring. Flags handled:
# a (hidden files), t (sort by mtime, newest first), r (reverse). l/h are no-ops
# since Get-ChildItem's table view is already long/human-readable. Emits real
# FileInfo objects, so Terminal-Icons still decorates the output.
# The built-in alias must go first: aliases outrank functions in PowerShell.
Remove-Alias ls -Force -ErrorAction SilentlyContinue
function ls {
    $paths = @(); $all = $false; $byTime = $false; $reverse = $false
    foreach ($a in $args) {
        if ($a -is [string] -and $a -cmatch '^-[lahtr]+$') {
            $flags = $a.TrimStart('-').ToCharArray()
            if ($flags -ccontains 'a') { $all = $true }
            if ($flags -ccontains 't') { $byTime = $true }
            if ($flags -ccontains 'r') { $reverse = $true }
        } else {
            $paths += $a
        }
    }
    # Splat via hashtable: splatting the array positionally would bind a second
    # path to Get-ChildItem's -Filter (position 1) and silently list wrong output.
    $gci = @{ Force = $all }
    if ($paths.Count) { $gci.Path = $paths }
    $items = Get-ChildItem @gci
    if ($byTime) { $items = $items | Sort-Object LastWriteTime -Descending:(-not $reverse) }
    elseif ($reverse) { $items = $items | Sort-Object Name -Descending }
    $items
}

# -----------------------------------------------------------------
# 4. herdr worktree helpers (same wrappers as the PS 5.1 profile)
# -----------------------------------------------------------------
# herdr-wt.ps1 is deployed next to this profile (Documents\PowerShell\Scripts);
# source of truth is herdr/scripts/herdr-wt.ps1 in the dots repo.
$herdrWtScript = Join-Path $PSScriptRoot "Scripts\herdr-wt.ps1"
if (Test-Path $herdrWtScript) {
    . $herdrWtScript
}

# PowerShell aliases can't carry arguments like bash's `alias x='cmd --flag'`, so these thin
# wrapper functions stand in for the bash aliases (lswt/crwt/openwt/rmwt).
function lswt { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-HerdrWtLs @rest }
function crwt { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-HerdrWtCr @rest }
function openwt { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-HerdrWtOpen @rest }
function rmwt { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-HerdrWtRm @rest }

# -----------------------------------------------------------------
# 5. TortoiseSVN shortcuts
# -----------------------------------------------------------------
# Opens the Tortoise update window in the current folder
function svn-up {
    Start-Process "TortoiseProc.exe" -ArgumentList "/command:update /path:`".`" /closeonend:0"
}

# Opens the Tortoise commit window in the current folder
function svn-commit {
    Start-Process "TortoiseProc.exe" -ArgumentList "/command:commit /path:`".`" /closeonend:0"
}

# Shows the Tortoise history/log in the current folder
function svn-log {
    Start-Process "TortoiseProc.exe" -ArgumentList "/command:log /path:`".`" /closeonend:0"
}
