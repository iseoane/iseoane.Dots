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
# `starship init powershell` costs ~700ms on every shell start. Cache the
# generated script and dot-source it instead; measured 737ms -> 227ms.
#
# Note it must be `--print-full-init`. Plain `starship init powershell` returns
# only a 198-byte BOOTSTRAP that re-invokes starship with --print-full-init at
# runtime, so caching that still spawns the process on every start and saves
# almost nothing. --print-full-init returns the real ~10.8KB init script.
#
# The cache keys off the starship BINARY's timestamp, not starship.toml: the
# generated script only wires up a prompt function that shells out to
# `starship prompt` each time, so it embeds no config. Editing starship.toml
# therefore takes effect immediately with no regeneration needed -- only
# upgrading starship itself invalidates this.
if (Get-Command starship -ErrorAction SilentlyContinue) {
    $starshipCache = Join-Path $env:LOCALAPPDATA 'starship\init.ps1'
    $starshipExe = (Get-Command starship).Source
    if (-not (Test-Path $starshipCache) -or
        (Get-Item $starshipExe).LastWriteTime -gt (Get-Item $starshipCache).LastWriteTime) {
        New-Item -ItemType Directory -Force -Path (Split-Path $starshipCache) | Out-Null
        (&starship init powershell --print-full-init) | Set-Content -LiteralPath $starshipCache -Encoding utf8
    }
    . $starshipCache
} else {
    Write-Warning "starship not found on PATH; using the default prompt"
}

# -----------------------------------------------------------------
# 1b. GitHub API token (raises unauthenticated 60/hr rate limit)
# -----------------------------------------------------------------
# engram's own update-check (and other tools) hits api.github.com on every
# run; without auth that 60/hr limit gets exhausted fast by the
# engram-sync hooks. Reused from gh's own stored credentials so the token
# itself never lands in this versioned file.
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $env:GH_TOKEN = gh auth token 2>$null
}

# -----------------------------------------------------------------
# 2. Modules (icons, predictions, docker completion)
# -----------------------------------------------------------------
# Colored icons for ls / dir. NOT imported here: it was the single most
# expensive thing in this profile (~950ms of a ~3.2s start). It only decorates
# directory listings, so the `ls` function below imports it on first use.
# Trade-off: calling `dir`/`Get-ChildItem` directly before the first `ls` gives
# an undecorated listing, and that first `ls` pays the load.

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

# System syntax colours, aligned with zsh and the Windows Terminal palette.
# xeoTheme semantic roles. PSReadLine 2.4.5 accepts #RRGGBB directly and emits truecolor.
Set-PSReadLineOption -Colors @{
    Command          = '#E28CA9'
    String           = '#A3BE8C'
    Parameter        = '#81A1C1'
    Keyword          = '#B48EAD'
    Operator         = '#88C0D0'
    Error            = '#F2A4BC'
    Comment          = '#8F93A5'
    InlinePrediction = '#8F93A5'
    Default          = '#D8DEE9'
    Selection        = '#2E3440'
    Variable         = '#C69AC3'
    Type             = '#9BB7D3'
    Number           = '#EED49F'
    Member           = '#9AD5DF'
    Emphasis         = '#E28CA9'
}

# DockerCompletion (docker tab-completion) is deliberately NOT imported: it cost
# ~430ms of a ~2.8s profile start and docker is driven from WSL/zsh on this
# machine, not from PowerShell, so nothing here was using it.
#
# There is no cheaper way to keep it. Deferring is not possible: an argument
# completer has to be registered before Tab is pressed, and the two tricks that
# look like they would work do not.
#   - Register-EngineEvent PowerShell.OnIdle -Action runs its scriptblock in a
#     SEPARATE runspace, so the module loads there and never reaches this
#     session (verified: handler ran, Get-Module in-session still False).
#   - Pre-warming it in a Start-ThreadJob only absorbs the disk cost; importing
#     into the session afterwards still took 427ms, because the parse and
#     registration must happen synchronously in the main runspace.
# If you start using docker from PowerShell, just add the import back.

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
    # Load the icon formatter on first use (see the note where the eager
    # Import-Module used to be). Importing before the objects reach the
    # formatter is enough for them to be decorated.
    if (-not (Get-Module Terminal-Icons)) { Import-Module Terminal-Icons }
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
function oc { param([Parameter(ValueFromRemainingArguments = $true)]$rest) & opencode --auto @rest }

# -----------------------------------------------------------------
# 5. worktree management (herdr-independent, plain git worktree)
# -----------------------------------------------------------------
$wtMgmtScript = Join-Path $PSScriptRoot "Scripts\worktree-mgmt.ps1"
if (Test-Path $wtMgmtScript) {
    . $wtMgmtScript
}
function wtls { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-WtLs @rest }
function wtnew { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-WtNew @rest }
function wtopen { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-WtOpen @rest }
function wtrm { param([Parameter(ValueFromRemainingArguments = $true)]$rest) Invoke-WtRm @rest }

# -----------------------------------------------------------------
# 6. TortoiseSVN shortcuts
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
