# herdr-wt.ps1 -- worktree helpers for herdr (PowerShell port of the bash herdr-wt script).
# Functions are invoked via the thin lswt/crwt/openwt/rmwt wrappers defined in the profile.
# Requires: herdr.exe, git.exe. Optional: gh.exe (for PR column).

Set-StrictMode -Version Latest

# herdr/gh emit JSON that omits null/absent fields entirely rather than emitting `null`,
# so a plain $obj.prop access throws PropertyNotFoundStrict under Set-StrictMode. This
# mirrors jq's `// default` fallback for a property that may not exist on the object at all.
function Get-JsonProp {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -and ($Object.PSObject.Properties.Name -contains $Name) -and $null -ne $Object.$Name) {
        return $Object.$Name
    }
    return $Default
}

function Write-HerdrDie {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "herdr-wt: $Message" -ForegroundColor Red
    throw $Message
}

function Test-HerdrCommand {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-HerdrDie "'$Name' not found on PATH"
    }
}

# Collapse the user's home directory prefix to '~', mirroring the bash ${path/#$HOME/~} trick.
function Format-HerdrPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    # Can't name this $home -- it shadows PowerShell's own read-only $HOME automatic variable.
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
function Resolve-HerdrRepo {
    param([string]$StartPath)
    if ([string]::IsNullOrEmpty($StartPath)) { $StartPath = (Get-Location).Path }
    $top = git -C $StartPath rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($top)) {
        Write-HerdrDie "not inside a git repo; cd into one or pass a path (e.g. 'lswt C:\myrepo')"
    }
    return $top
}

# owner/repo from origin, for gh. Empty if it can't be derived.
function Get-OriginSlug {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $url = git -C $Repo remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($url)) { return "" }
    $slug = $url -replace '^(git@github\.com:|https://github\.com/)', '' -replace '\.git$', ''
    return $slug
}

# Autodetect the base a branch most likely forked from, among develop/main/master:
# the candidate with the fewest commits since its merge-base wins.
# Integration branches themselves return "(base)".
function Get-DetectedFrom {
    param(
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$Branch
    )
    if ($Branch -eq 'null') { return '-' }
    if ($Branch -in @('develop', 'main', 'master')) { return '(base)' }

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
function Get-SyncState {
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

function Invoke-HerdrWtLs {
    param([string]$RepoPath)
    Test-HerdrCommand herdr
    Test-HerdrCommand git

    $repo = Resolve-HerdrRepo -StartPath $RepoPath
    $curTop = git -C (Get-Location).Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { $curTop = "" }

    # Build a PR lookup (branch -> "#N STATE"), single gh call. Optional.
    $prMap = @{}
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $slug = Get-OriginSlug -Repo $repo
        if ($slug) {
            $prJson = gh pr list --repo $slug --state all --limit 200 --json number,state,headRefName 2>$null
            if ($LASTEXITCODE -eq 0 -and $prJson) {
                try {
                    $prs = $prJson | ConvertFrom-Json
                    foreach ($pr in $prs) {
                        $headRef = Get-JsonProp $pr 'headRefName'
                        if ($headRef) { $prMap[$headRef] = "#$(Get-JsonProp $pr 'number') $(Get-JsonProp $pr 'state')" }
                    }
                } catch { }
            }
        }
    }

    $jsonRaw = herdr worktree list --cwd $repo --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $jsonRaw) {
        Write-HerdrDie "herdr worktree list failed (is the server running?)"
    }
    $data = $jsonRaw | ConvertFrom-Json

    $herdrWtRoot = Join-Path $env:USERPROFILE '.herdr\worktrees\'
    $worktrees = @($data.result.worktrees | Where-Object {
        # Normalize forward slashes -- herdr's JSON path separator isn't guaranteed, so compare
        # against the backslash form Join-Path produced above.
        $isLinked = Get-JsonProp $_ 'is_linked_worktree' $false
        $wtPath = Get-JsonProp $_ 'path'
        $_ -and ((-not $isLinked) -or ($wtPath -and ($wtPath -replace '/', '\').StartsWith($herdrWtRoot, [System.StringComparison]::OrdinalIgnoreCase)))
    })

    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add([pscustomobject]@{ Mark=""; Branch="BRANCH"; From="FROM"; Head="HEAD"; State="STATE"; Sync="SYNC"; Pr="PR"; Ws="WS"; Path="PATH"; IsHeader=$true })

    foreach ($w in $worktrees) {
        $branch = Get-JsonProp $w 'branch' 'null'
        $path = Get-JsonProp $w 'path'
        $ws = Get-JsonProp $w 'open_workspace_id' 'none'
        $dispBranch = if ($branch -eq 'null') { '(detached)' } else { $branch }

        $from = Get-DetectedFrom -Worktree $path -Branch $branch
        $head = git -C $path rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $head) { $head = '-' }

        $status = git -C $path status --porcelain 2>$null
        $state = if ($status) { 'dirty' } else { 'clean' }

        $sync = Get-SyncState -Worktree $path
        $pr = if ($prMap.ContainsKey($branch)) { $prMap[$branch] } else { 'none' }
        $mark = if ($curTop -and $path -eq $curTop) { '*' } else { '' }
        $displayPath = Format-HerdrPath -Path $path

        $rows.Add([pscustomobject]@{ Mark=$mark; Branch=$dispBranch; From=$from; Head=$head; State=$state; Sync=$sync; Pr=$pr; Ws=$ws; Path=$displayPath; IsHeader=$false })
    }

    # Column widths, computed across header + data rows (mirrors the bash awk alignment pass).
    $cols = @('Mark','Branch','From','Head','State','Sync','Pr','Ws','Path')
    $widths = @{}
    foreach ($c in $cols) { $widths[$c] = ($rows | ForEach-Object { $_.$c.Length } | Measure-Object -Maximum).Maximum }

    # PS 5.1 can't color individual substrings inside one aligned Write-Host line as cleanly as
    # bash's awk pass, so each row is emitted cell-by-cell with -NoNewline, coloring only the
    # cell that needs attention (dirty/ahead-behind/OPEN) -- this reproduces the same visual
    # result without a helper text-rendering library.
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
    Write-Host "  WS         open herdr workspace id (none = no workspace open for it)"
}

# Interactive picker: list local branches, mark the current one, return the choice.
function Select-HerdrBranch {
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

# Parses the shared "[flags] name [from]" positional/flag argument shape used by
# cr/open/rm. Returns a hashtable with Focus/Force and the positional args.
function Get-HerdrFocusArgs {
    param([string[]]$Args)
    $focus = '--focus'
    $pos = @()
    foreach ($a in $Args) {
        switch ($a) {
            '--no-focus' { $focus = '--no-focus' }
            '--focus' { $focus = '--focus' }
            default {
                if ($a.StartsWith('-')) { Write-HerdrDie "unknown flag '$a'" }
                $pos += $a
            }
        }
    }
    return @{ Focus = $focus; Positional = $pos }
}

function Invoke-HerdrWtCr {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    Test-HerdrCommand herdr
    Test-HerdrCommand git

    if (-not $Args) { $Args = @() }
    $parsed = Get-HerdrFocusArgs -Args $Args
    $focus = $parsed.Focus
    $pos = $parsed.Positional
    $name = if ($pos.Count -ge 1) { $pos[0] } else { "" }
    $from = if ($pos.Count -ge 2) { $pos[1] } else { "" }
    if (-not $name) { Write-HerdrDie "usage: crwt <name> [branch]   (name is required)" }

    $repo = Resolve-HerdrRepo

    git -C $repo show-ref --verify --quiet "refs/heads/$name" *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-HerdrDie "branch '$name' already exists -- use 'openwt $name' to open its worktree"
    }

    if (-not $from) {
        $from = Select-HerdrBranch -Repo $repo
        if (-not $from) { Write-HerdrDie "no source branch selected; aborted" }
    }

    git -C $repo show-ref --verify --quiet "refs/heads/$from" *> $null
    $localOk = ($LASTEXITCODE -eq 0)
    if (-not $localOk) {
        git -C $repo show-ref --verify --quiet "refs/remotes/origin/$from" *> $null
        if ($LASTEXITCODE -ne 0) { Write-HerdrDie "source branch '$from' not found (local or origin/)" }
    }

    $baseref = $from
    git -C $repo fetch origin $from *> $null
    if ($LASTEXITCODE -eq 0) {
        $baseref = "origin/$from"
        Write-Host "Fetched latest origin/$from."
    } else {
        [Console]::Error.WriteLine("note: could not fetch origin/$from; starting from local '$from'.")
    }

    $out = herdr worktree create --cwd $repo --branch $name --base $baseref $focus --json 2>&1
    if ($LASTEXITCODE -ne 0) { Write-HerdrDie "worktree create failed: $out" }

    $path = "?"
    try {
        $result = ($out | Out-String) | ConvertFrom-Json
        $wt = Get-JsonProp $result 'result'
        $wt = Get-JsonProp $wt 'worktree'
        $p = Get-JsonProp $wt 'path'
        if ($p) { $path = $p }
    } catch { }
    Write-Host "Created worktree '$name' from '$from'  ->  $(Format-HerdrPath $path)"
}

function Invoke-HerdrWtOpen {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    Test-HerdrCommand herdr
    Test-HerdrCommand git

    if (-not $Args) { $Args = @() }
    $parsed = Get-HerdrFocusArgs -Args $Args
    $focus = $parsed.Focus
    $pos = $parsed.Positional
    $branch = if ($pos.Count -ge 1) { $pos[0] } else { "" }
    if (-not $branch) { Write-HerdrDie "usage: openwt <branch>" }

    $repo = Resolve-HerdrRepo

    $out = herdr worktree open --cwd $repo --branch $branch $focus --json 2>&1
    $outStr = $out | Out-String
    if ($outStr -match 'worktree_not_found') {
        Write-HerdrDie "no worktree for branch '$branch' -- create it with 'crwt $branch'"
    }

    $result = $null
    try { $result = $outStr | ConvertFrom-Json } catch { }
    $resResult = Get-JsonProp $result 'result'
    if (-not $result -or -not $resResult) { Write-HerdrDie "open failed: $outStr" }

    $ws = "?"
    $workspace = Get-JsonProp $resResult 'workspace'
    $wsId = Get-JsonProp $workspace 'workspace_id'
    $resWt = Get-JsonProp $resResult 'worktree'
    if ($wsId) {
        $ws = $wsId
    } elseif (Get-JsonProp $resWt 'open_workspace_id') {
        $ws = Get-JsonProp $resWt 'open_workspace_id'
    }
    $path = Get-JsonProp $resWt 'path' '?'
    Write-Host "Opened worktree '$branch' (workspace $ws)  ->  $(Format-HerdrPath $path)"
}

function Invoke-HerdrWtRm {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    Test-HerdrCommand herdr
    Test-HerdrCommand git

    if (-not $Args) { $Args = @() }
    $force = $false
    $pos = @()
    foreach ($a in $Args) {
        switch ($a) {
            { $_ -in @('--force', '-f') } { $force = $true }
            default {
                if ($a.StartsWith('-')) { Write-HerdrDie "unknown flag '$a'" }
                $pos += $a
            }
        }
    }
    $branch = if ($pos.Count -ge 1) { $pos[0] } else { "" }
    if (-not $branch) { Write-HerdrDie "usage: rmwt <branch> [--force]" }

    $repo = Resolve-HerdrRepo

    if ($branch -in @('develop', 'main', 'master')) {
        Write-HerdrDie "refusing to remove integration branch '$branch'"
    }
    $current = git -C (Get-Location).Path branch --show-current 2>$null
    if ($LASTEXITCODE -ne 0) { $current = "" }
    if ($branch -eq $current) { Write-HerdrDie "you're currently on '$branch'; switch away first" }

    $jsonRaw = herdr worktree list --cwd $repo --json 2>$null
    if ($LASTEXITCODE -ne 0) { Write-HerdrDie "worktree list failed" }
    $data = $jsonRaw | ConvertFrom-Json
    $wt = $data.result.worktrees | Where-Object { (Get-JsonProp $_ 'branch') -eq $branch } | Select-Object -First 1
    if (-not $wt) { Write-HerdrDie "no worktree for branch '$branch'" }

    $path = Get-JsonProp $wt 'path'
    $ws = Get-JsonProp $wt 'open_workspace_id' '-'
    if (-not (Get-JsonProp $wt 'is_linked_worktree' $false)) {
        Write-HerdrDie "'$branch' is the main checkout, not a removable worktree"
    }

    $base = Get-DetectedFrom -Worktree $path -Branch $branch
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
        $slug = Get-OriginSlug -Repo $repo
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

    Write-Host "Worktree:  $branch  ->  $(Format-HerdrPath $path)"
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
        Write-HerdrDie "refusing to remove ($($blocked -join '; ')) -- pass --force to override"
    }

    if (-not $force) {
        $ans = Read-Host "Remove this worktree? [y/N]"
        if ($ans -notmatch '^(y|yes)$') { Write-HerdrDie "aborted" }
    }

    if ($ws -ne '-') { herdr worktree remove --workspace $ws --force *> $null }
    $gitWtList = git -C $repo worktree list --porcelain 2>$null
    if ($gitWtList -match [regex]::Escape("worktree $path")) {
        if ($force) { git -C $repo worktree remove --force $path 2>$null }
        else { git -C $repo worktree remove $path 2>$null }
    }
    git -C $repo worktree prune 2>$null
    Write-Host "Removed worktree '$branch'."

    if ($merged -eq 'yes') {
        if ($force) {
            git -C $repo branch -d $branch 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Host "Deleted merged branch '$branch'." }
        } else {
            $ans2 = Read-Host "Also delete local branch '$branch' (merged)? [y/N]"
            if ($ans2 -match '^(y|yes)$') {
                git -C $repo branch -d $branch
                if ($LASTEXITCODE -eq 0) { Write-Host "Deleted branch '$branch'." }
            }
        }
    } elseif ($force) {
        git -C $repo branch -D $branch 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "Force-deleted unmerged branch '$branch'." }
    } else {
        Write-Host "Kept local branch '$branch'."
    }
}
