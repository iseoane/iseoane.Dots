# worktree-mgmt.ps1 -- herdr-independent worktree helpers, plain `git worktree` underneath.
# PowerShell port of worktree-mgmt.sh. Dot-sourced from the PS7 profile (Documents\PowerShell\
# Scripts), same shape as herdr-wt.ps1's deployment. Invoke-WtOpen must run in the interactive
# session -- it's dot-sourced and its wrapper is a plain function call, never a separate process.
#
# Strict mode is set INSIDE each entry function, never at script level: this file is
# dot-sourced by the profile, so a top-level Set-StrictMode would leak into the whole
# interactive session and break third-party snippets that read unset variables
# (e.g. herdr's injected prompt wrapper reading $global:__HerdrOriginalPrompt).

function Write-WtDie {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "wt: $Message" -ForegroundColor Red
    throw $Message
}

function Test-WtCommand {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-WtDie "'$Name' not found on PATH"
    }
}

# Collapse the user's home directory prefix to '~', mirroring bash's ${path/#$HOME/~} trick.
function Format-WtPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $userHome = $env:USERPROFILE
    # git.exe emits toplevel paths with forward slashes; normalize before comparing so the
    # collapse still fires regardless of which separator the caller's path uses.
    $normalized = $Path -replace '/', '\'
    if ($normalized.StartsWith($userHome, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $normalized.Substring($userHome.Length)
    }
    return $Path
}

# Resolve the repo top-level from a path (arg) or $PWD. Works from the main
# checkout or any linked worktree.
function Resolve-WtRepo {
    param([string]$StartPath)
    if ([string]::IsNullOrEmpty($StartPath)) { $StartPath = (Get-Location).Path }
    $top = git -C $StartPath rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($top)) {
        Write-WtDie "not inside a git repo; cd into one or pass a path (e.g. 'wtls C:\myrepo')"
    }
    return $top
}

# The bucket a worktree lands in: the basename of the MAIN repo's directory, resolved via
# the git common-dir so it's stable even when invoked from inside an existing linked
# worktree (git-common-dir always points at the main .git, absolute or relative).
function Get-WtRepoName {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $common = git -C $Repo rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($common)) {
        Write-WtDie "failed to resolve git common dir"
    }
    $common = $common -replace '/', '\'
    if (-not [System.IO.Path]::IsPathRooted($common)) {
        $common = Join-Path $Repo $common
    }
    $common = [System.IO.Path]::GetFullPath($common)
    $parent = Split-Path $common -Parent
    return Split-Path $parent -Leaf
}

# owner/repo from origin, for gh. Empty if it can't be derived.
function Get-WtOriginSlug {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $url = git -C $Repo remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($url)) { return "" }
    return $url -replace '^(git@github\.com:|https://github\.com/)', '' -replace '\.git$', ''
}

# The base a branch was created from: prefer the parent `wtnew` recorded at
# creation time (`branch.<name>.wt-parent`, local-only git config -- see
# Invoke-WtNew), since that's the true parent even when it's another
# feature branch. Falls back to the develop/main/master autodetect heuristic
# below for branches wtnew didn't create (or created before this existed).
# Integration branches themselves return "(base)".
function Get-WtDetectedFrom {
    param(
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$Branch
    )
    if ($Branch -eq 'null') { return '-' }
    if ($Branch -in @('develop', 'main', 'master')) { return '(base)' }

    $recorded = git -C $Worktree config "branch.$Branch.wt-parent" 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($recorded)) { return $recorded }

    $best = $null
    $bestAhead = -1
    foreach ($base in @('develop', 'main', 'master')) {
        $ref = $null
        git -C $Worktree rev-parse --verify --quiet $base *> $null
        if ($LASTEXITCODE -eq 0) {
            $ref = $base
        } else {
            git -C $Worktree rev-parse --verify --quiet "origin/$base" *> $null
            if ($LASTEXITCODE -eq 0) { $ref = "origin/$base" }
        }
        if (-not $ref) { continue }

        $mb = git -C $Worktree merge-base $ref $Branch 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($mb)) { continue }

        $aheadStr = git -C $Worktree rev-list --count "$mb..$Branch" 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $ahead = [int]$aheadStr

        if ($bestAhead -lt 0 -or $ahead -lt $bestAhead) {
            $bestAhead = $ahead
            $best = $base
        }
    }
    if ($best) { return $best } else { return '-' }
}

# ahead/behind vs upstream -> "ahead N", "behind N", "ahead N, behind M", "synced" or "local-only".
function Get-WtSyncState {
    param([Parameter(Mandatory = $true)][string]$Worktree)
    $up = git -C $Worktree rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($up)) { return 'local-only' }

    $counts = git -C $Worktree rev-list --left-right --count "$up...HEAD" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($counts)) { return 'local-only' }

    $parts = $counts -split '\s+' | Where-Object { $_ -ne '' }
    $b = $parts[0]
    $a = $parts[1]
    if ($a -eq '0' -and $b -eq '0') { return 'synced' }
    elseif ($b -eq '0') { return "ahead $a" }
    elseif ($a -eq '0') { return "behind $b" }
    else { return "ahead $a, behind $b" }
}

# Read this OS's root from the deployed config, prompting and persisting on first run.
function Get-WtRoot {
    $configPath = Join-Path $env:USERPROFILE ".config\worktree-management\config"
    $key = "windows_root"
    $root = $null
    if (Test-Path $configPath) {
        $line = Get-Content $configPath | Where-Object { $_ -match "^$key=" } | Select-Object -Last 1
        if ($line) { $root = ($line -split '=', 2)[1] }
    }
    if (-not $root) {
        $root = Read-Host "wt: no worktree root configured for windows -- enter the root (worktrees go under {root}\worktrees\{repo}\{branch})"
        if (-not $root) { Write-WtDie "no root provided" }
        $configDir = Split-Path $configPath -Parent
        if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
        if (Test-Path $configPath) {
            $content = @(Get-Content $configPath)
            if ($content -match "^$key=") {
                $content = $content -replace "^$key=.*", "$key=$root"
                Set-Content -Path $configPath -Value $content
            } else {
                Add-Content -Path $configPath -Value "$key=$root"
            }
        } else {
            Set-Content -Path $configPath -Value "$key=$root"
        }
    }
    return $root
}

# Parse `git worktree list --porcelain` into Path/Branch pairs.
function Get-WtWorktreeList {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $lines = git -C $Repo worktree list --porcelain 2>$null
    $result = New-Object System.Collections.Generic.List[object]
    $path = $null; $branch = $null
    foreach ($line in $lines) {
        if ($line -match '^worktree (.+)$') {
            if ($path) { $result.Add([pscustomobject]@{ Path = $path; Branch = $(if ($branch) { $branch } else { 'null' }) }) }
            $path = $matches[1]; $branch = $null
        } elseif ($line -match '^branch (.+)$') {
            $branch = $matches[1] -replace '^refs/heads/', ''
        } elseif ($line -match '^detached$') {
            $branch = 'null'
        }
    }
    if ($path) { $result.Add([pscustomobject]@{ Path = $path; Branch = $(if ($branch) { $branch } else { 'null' }) }) }
    return $result
}

function Invoke-WtLs {
    param([string]$RepoPath)
    Set-StrictMode -Version Latest
    Test-WtCommand git

    $repo = Resolve-WtRepo -StartPath $RepoPath
    $curTop = git -C (Get-Location).Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { $curTop = "" }

    # Build a PR lookup (branch -> "#N STATE"), single gh call. Optional.
    $prMap = @{}
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $slug = Get-WtOriginSlug -Repo $repo
        if ($slug) {
            $prJson = gh pr list --repo $slug --state all --limit 200 --json number,state,headRefName 2>$null
            if ($LASTEXITCODE -eq 0 -and $prJson) {
                try {
                    $prs = $prJson | ConvertFrom-Json
                    foreach ($pr in $prs) {
                        if ($pr.headRefName) { $prMap[$pr.headRefName] = "#$($pr.number) $($pr.state)" }
                    }
                } catch { }
            }
        }
    }

    $worktrees = Get-WtWorktreeList -Repo $repo

    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add([pscustomobject]@{ Mark=""; Branch="BRANCH"; From="FROM"; Head="HEAD"; State="STATE"; Sync="SYNC"; Pr="PR"; Path="PATH"; IsHeader=$true })

    foreach ($w in $worktrees) {
        $branch = $w.Branch
        $path = $w.Path
        $dispBranch = if ($branch -eq 'null') { '(detached)' } else { $branch }

        $from = Get-WtDetectedFrom -Worktree $path -Branch $branch
        $head = git -C $path rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $head) { $head = '-' }

        $status = git -C $path status --porcelain 2>$null
        $state = if ($status) { 'dirty' } else { 'clean' }

        $sync = Get-WtSyncState -Worktree $path
        $pr = if ($prMap.ContainsKey($branch)) { $prMap[$branch] } else { 'none' }
        $mark = if ($curTop -and $path -eq $curTop) { '*' } else { '' }
        $displayPath = Format-WtPath -Path $path

        $rows.Add([pscustomobject]@{ Mark=$mark; Branch=$dispBranch; From=$from; Head=$head; State=$state; Sync=$sync; Pr=$pr; Path=$displayPath; IsHeader=$false })
    }

    # Column widths, computed across header + data rows (mirrors the bash awk alignment pass).
    $cols = @('Mark','Branch','From','Head','State','Sync','Pr','Path')
    $widths = @{}
    foreach ($c in $cols) { $widths[$c] = ($rows | ForEach-Object { $_.$c.Length } | Measure-Object -Maximum).Maximum }

    # PS 5.1/7 can't color individual substrings inside one aligned Write-Host line as cleanly
    # as bash's awk pass, so each row is emitted cell-by-cell with -NoNewline, coloring only the
    # cell that needs attention (dirty/ahead-behind/OPEN) -- same visual result, no text-layout lib.
    foreach ($row in $rows) {
        $bold = (-not $row.IsHeader) -and ($row.Mark -eq '*')
        foreach ($c in $cols) {
            $val = $row.$c
            $padded = $val.PadRight($widths[$c])
            $attn = $false
            if (-not $row.IsHeader) {
                if ($c -eq 'State' -and $val -match 'dirty') { $attn = $true }
                elseif ($c -eq 'Sync' -and $val -match '^(ahead|behind)') { $attn = $true }
                elseif ($c -eq 'Pr' -and $val -match 'OPEN') { $attn = $true }
            }
            $color = $null
            if ($attn -and $bold) { $color = 'Red' }        # bold+red collapses to bright red in a console
            elseif ($attn) { $color = 'DarkRed' }
            elseif ($bold) { $color = 'White' }
            if ($color) { Write-Host $padded -ForegroundColor $color -NoNewline }
            else { Write-Host $padded -NoNewline }
            Write-Host "  " -NoNewline
        }
        Write-Host ""
    }

    Write-Host ""
    Write-Host "Legend:"
    Write-Host "  *          the worktree you are currently in"
    Write-Host "  FROM       branch it was created from   ((base) = integration branch, e.g. develop/main)"
    Write-Host "  STATE      clean = no local changes  |  dirty = uncommitted changes"
    Write-Host "  SYNC       vs its remote upstream: synced | ahead N | behind N | ahead N, behind M"
    Write-Host "             local-only = branch never pushed (no upstream to compare against)"
    Write-Host "  PR         GitHub pull request state (none = no PR for this branch)"
}

# Interactive picker: list local branches, mark the current one, return the choice.
function Select-WtBranch {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $current = git -C (Get-Location).Path branch --show-current 2>$null
    if ($LASTEXITCODE -ne 0) { $current = "" }

    $branches = @(git -C $Repo for-each-ref --format='%(refname:short)' refs/heads/ | Sort-Object)
    if ($branches.Count -eq 0) { return $null }

    $def = 1
    [Console]::Error.WriteLine("From which branch?")
    for ($i = 0; $i -lt $branches.Count; $i++) {
        $mark = ""
        if ($branches[$i] -eq $current) { $mark = "  (current) *"; $def = $i + 1 }
        [Console]::Error.WriteLine("  $($i + 1)) $($branches[$i])$mark")
    }

    $sel = Read-Host "#? [$def]"
    if ([string]::IsNullOrEmpty($sel)) { $sel = $def }
    if ($sel -notmatch '^[0-9]+$') { return $null }
    $idx = [int]$sel
    if ($idx -lt 1 -or $idx -gt $branches.Count) { return $null }
    return $branches[$idx - 1]
}

function Invoke-WtNew {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    Set-StrictMode -Version Latest
    Test-WtCommand git

    if (-not $Args) { $Args = @() }
    $name = if ($Args.Count -ge 1) { $Args[0] } else { "" }
    $from = if ($Args.Count -ge 2) { $Args[1] } else { "" }
    if (-not $name) { Write-WtDie "usage: wtnew <name> [base]" }

    $repo = Resolve-WtRepo

    git -C $repo show-ref --verify --quiet "refs/heads/$name" *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-WtDie "branch '$name' already exists -- use 'wtopen $name' to open its worktree"
    }

    if (-not $from) {
        $from = Select-WtBranch -Repo $repo
        if (-not $from) { Write-WtDie "no source branch selected; aborted" }
    }

    git -C $repo show-ref --verify --quiet "refs/heads/$from" *> $null
    $localOk = ($LASTEXITCODE -eq 0)
    if (-not $localOk) {
        git -C $repo show-ref --verify --quiet "refs/remotes/origin/$from" *> $null
        if ($LASTEXITCODE -ne 0) { Write-WtDie "source branch '$from' not found (local or origin/)" }
    }

    $baseref = $from
    git -C $repo fetch origin $from *> $null
    if ($LASTEXITCODE -eq 0) {
        $baseref = "origin/$from"
        Write-Host "Fetched latest origin/$from."
    } else {
        [Console]::Error.WriteLine("note: could not fetch origin/$from; starting from local '$from'.")
    }

    $root = Get-WtRoot
    $repoName = Get-WtRepoName -Repo $repo
    # Branch may contain '/' (e.g. feature/foo) -- that just nests directories, which is fine.
    $path = Join-Path (Join-Path (Join-Path $root "worktrees") $repoName) $name

    $parent = Split-Path $path -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    git -C $repo worktree add $path -b $name $baseref
    if ($LASTEXITCODE -ne 0) { Write-WtDie "git worktree add failed" }

    # Record the real parent (local-only git config, never pushed -- see
    # Get-WtDetectedFrom) so `wtls`'s FROM column shows it even when it's
    # another feature branch, not just one of develop/main/master.
    git -C $repo config "branch.$name.wt-parent" $from | Out-Null

    # First push: publish the branch to origin right away so it exists remotely
    # before any commit, and set the upstream so `wtls`'s SYNC column shows
    # "synced" instead of "local-only". The worktree is already created, so a
    # failed push (no origin, no network) is a note, not a failure.
    git -C $repo remote get-url origin *> $null
    if ($LASTEXITCODE -eq 0) {
        $pushOut = git -C $repo push -u origin $name 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Pushed '$name' to origin."
        } else {
            [Console]::Error.WriteLine("note: could not push '$name' to origin (worktree created anyway): $pushOut")
        }
    } else {
        [Console]::Error.WriteLine("note: no 'origin' remote; skipped initial push.")
    }

    Write-Host "Created worktree '$name' from '$from'  ->  $(Format-WtPath $path)"
}

function Invoke-WtOpen {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    Set-StrictMode -Version Latest
    Test-WtCommand git

    if (-not $Args) { $Args = @() }
    $branch = if ($Args.Count -ge 1) { $Args[0] } else { "" }
    if (-not $branch) { Write-WtDie "usage: wtopen <branch>" }

    $repo = Resolve-WtRepo
    $wt = Get-WtWorktreeList -Repo $repo | Where-Object { $_.Branch -eq $branch } | Select-Object -First 1
    if (-not $wt) { Write-WtDie "no worktree for branch '$branch' -- create it with 'wtnew $branch'" }

    # Runs in the caller's session (dot-sourced, invoked as a plain function call --
    # never as a separate process), so Set-Location actually moves the interactive shell.
    Set-Location $wt.Path
    Write-Host "Opened worktree '$branch'  ->  $(Format-WtPath $wt.Path)"
}

function Invoke-WtRm {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    Set-StrictMode -Version Latest
    Test-WtCommand git

    if (-not $Args) { $Args = @() }
    $force = $false
    $pos = @()
    foreach ($a in $Args) {
        switch ($a) {
            { $_ -in @('--force', '-f') } { $force = $true }
            default {
                if ($a.StartsWith('-')) { Write-WtDie "unknown flag '$a'" }
                $pos += $a
            }
        }
    }
    $branch = if ($pos.Count -ge 1) { $pos[0] } else { "" }
    if (-not $branch) { Write-WtDie "usage: wtrm <branch> [--force]" }

    $repo = Resolve-WtRepo

    if ($branch -in @('develop', 'main', 'master')) {
        Write-WtDie "refusing to remove integration branch '$branch'"
    }
    $current = git -C (Get-Location).Path branch --show-current 2>$null
    if ($LASTEXITCODE -ne 0) { $current = "" }
    if ($branch -eq $current) { Write-WtDie "you're currently on '$branch'; switch away first" }

    $wt = Get-WtWorktreeList -Repo $repo | Where-Object { $_.Branch -eq $branch } | Select-Object -First 1
    if (-not $wt) { Write-WtDie "no worktree for branch '$branch'" }
    $path = $wt.Path

    $base = Get-WtDetectedFrom -Worktree $path -Branch $branch
    $baseref = ""
    $merged = "unknown"
    if ($base -ne '-') {
        git -C $path rev-parse --verify --quiet $base *> $null
        if ($LASTEXITCODE -eq 0) {
            $baseref = $base
        } else {
            git -C $path rev-parse --verify --quiet "origin/$base" *> $null
            if ($LASTEXITCODE -eq 0) { $baseref = "origin/$base" }
        }
        if ($baseref) {
            git -C $path merge-base --is-ancestor $branch $baseref 2>$null
            $merged = if ($LASTEXITCODE -eq 0) { "yes" } else { "no" }
        }
    }

    $pr = "-"
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $slug = Get-WtOriginSlug -Repo $repo
        if ($slug) {
            $prJson = gh pr list --repo $slug --head $branch --state all --limit 1 --json number,state 2>$null
            if ($LASTEXITCODE -eq 0 -and $prJson) {
                try {
                    $prs = @($prJson | ConvertFrom-Json)
                    if ($prs.Count -gt 0) { $pr = "#$($prs[0].number) $($prs[0].state)" }
                } catch { }
            }
        }
    }

    $status = git -C $path status --porcelain 2>$null
    $dirty = if ($status) { "yes" } else { "no" }

    Write-Host "Worktree:  $branch  ->  $(Format-WtPath $path)"
    $mergedLine = "Merged:    $merged"
    if ($baseref) { $mergedLine += " (into $baseref)" }
    Write-Host $mergedLine
    Write-Host "PR:        $pr"
    Write-Host "Dirty:     $dirty"

    $blocked = @()
    if ($merged -eq 'no') { $blocked += 'not merged' }
    if ($pr -match 'OPEN') { $blocked += 'open PR' }
    if ($dirty -eq 'yes') { $blocked += 'uncommitted changes' }
    if ($blocked.Count -gt 0 -and -not $force) {
        Write-WtDie "refusing to remove ($($blocked -join '; ')) -- pass --force to override"
    }

    if (-not $force) {
        $ans = Read-Host "Remove this worktree? [y/N]"
        if ($ans -notmatch '^(y|yes)$') { Write-WtDie "aborted" }
    }

    $gitWtList = git -C $repo worktree list --porcelain 2>$null
    if ($gitWtList -match [regex]::Escape("worktree $path")) {
        if ($force) { git -C $repo worktree remove --force $path 2>$null }
        else { git -C $repo worktree remove $path 2>$null }
    }
    git -C $repo worktree prune 2>$null
    Write-Host "Removed worktree '$branch'."

    $branchDeleted = $false
    if ($merged -eq 'yes') {
        if ($force) {
            git -C $repo branch -d $branch 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Host "Deleted merged branch '$branch'."; $branchDeleted = $true }
        } else {
            $ans2 = Read-Host "Also delete local branch '$branch' (merged)? [y/N]"
            if ($ans2 -match '^(y|yes)$') {
                git -C $repo branch -d $branch
                if ($LASTEXITCODE -eq 0) { Write-Host "Deleted branch '$branch'."; $branchDeleted = $true }
            }
        }
    } elseif ($force) {
        git -C $repo branch -D $branch 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "Force-deleted unmerged branch '$branch'."; $branchDeleted = $true }
    } else {
        Write-Host "Kept local branch '$branch'."
    }

    # The local branch is gone but it may still live on origin (this script never
    # touches the remote). Offer to delete it there too -- only when it's merged,
    # so no history is lost, and only if the local branch was actually deleted.
    if ($branchDeleted -and $merged -eq 'yes') {
        git -C $repo show-ref --verify --quiet "refs/remotes/origin/$branch" *> $null
        if ($LASTEXITCODE -eq 0) {
            $ans3 = 'yes'
            if (-not $force) {
                $ans3 = Read-Host "Delete '$branch' on origin too? This removes the branch from the shared copy of the project on the server, so it stops existing for the whole team. [y/N]"
            }
            if ($ans3 -match '^(y|yes)$') {
                git -C $repo push origin --delete $branch *> $null
                if ($LASTEXITCODE -eq 0) { Write-Host "Deleted remote branch 'origin/$branch'." }
                else { [Console]::Error.WriteLine("note: could not delete 'origin/$branch' (no network, or already gone).") }
            }
        }
    }

    # Offer to prune stale remote-tracking refs: local copies of branches that no
    # longer exist on origin keep showing up in `wtls` and `git branch -r` until a
    # fetch --prune forgets them. Non-destructive to your work -- it only drops the
    # outdated bookkeeping, never your commits.
    if ($branchDeleted) {
        $ans4 = 'yes'
        if (-not $force) {
            $ans4 = Read-Host "Also clean up stale remote branch references? This removes the outdated local copies of branches that no longer exist on the server (deleted by you or anyone else), so your branch list only shows what is really there. [y/N]"
        }
        if ($ans4 -match '^(y|yes)$') {
            git -C $repo fetch --prune origin *> $null
            if ($LASTEXITCODE -eq 0) { Write-Host "Pruned stale remote-tracking branches." }
            else { [Console]::Error.WriteLine("note: could not prune remote-tracking branches (no network?).") }
        }
    }
}
