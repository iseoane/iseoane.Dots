# worktree-mgmt.sh -- herdr-independent worktree helpers, plain `git worktree` underneath.
# Meant to be SOURCED from an interactive shell (see ~/.zshrc), never executed directly:
# wtopen must `cd` the CALLING shell into a worktree, which only works if it runs as a
# function in the current shell process rather than an external script/subprocess.
#
# Commands (defined at the bottom of this file):
#   wtls   [repo-path]        list worktrees of the current repo (or given path)
#   wtnew  <name> [base]      create a worktree under the configured root
#   wtopen <branch>           cd into an existing worktree
#   wtrm   <branch> [--force] remove a worktree, with safety checks
#
# Requires: git. Optional: gh (for the PR column).
#
# No `set -euo pipefail` at file scope: this is dot-sourced into an interactive shell,
# so a top-level `set -e` would change the behavior of every command typed afterwards.
# Each function checks exit codes explicitly instead.

WT_CONFIG_FILE="$HOME/.config/worktree-management/config"

# zsh arrays are 1-indexed, bash arrays 0-indexed, and reading `${a[0]}` in zsh
# yields the EMPTY STRING rather than the first element. Every literal index
# below adds this offset instead of hardcoding 0.
if [ -n "${ZSH_VERSION:-}" ]; then WT_ARRAY_BASE=1; else WT_ARRAY_BASE=0; fi

wt_die() { echo "wt: $*" >&2; return 1; }

wt_need() { command -v "$1" >/dev/null 2>&1 || { wt_die "'$1' not found on PATH"; return 1; }; }

# Prompt on the terminal, read one line from the terminal, echo the answer on stdout.
# NOT `read -rp "..."`: in zsh `-p` means "read from the COPROCESS", so that form dies
# outright with `read: -p: no coprocess`. Printing the prompt separately works in both
# shells, and sending it to /dev/tty (not stdout) keeps it out of the captured value --
# which matters because callers use `x=$(wt_prompt ...)`. No tty -> non-zero, so callers
# abort instead of silently reading EOF.
wt_prompt() {
  local msg="$1" ans=""
  # `2>/dev/null` FIRST: redirections are applied left to right, so with
  # `>/dev/tty 2>/dev/null` the tty open fails while stderr is still the real
  # stderr and the shell leaks "/dev/tty: No such device" before the caller
  # gets a chance to print its own message.
  printf '%s' "$msg" 2>/dev/null >/dev/tty || return 1
  # Default IFS on purpose, NOT `IFS=`: it makes `read` trim leading/trailing
  # whitespace, which every `read -rp` call site replaced here relied on. A pasted
  # " y " must still match the `case ... in y|Y|yes|YES)` patterns instead of
  # silently falling through to "no", and a root path must not be persisted to the
  # config with stray spaces around it.
  read -r ans 2>/dev/null </dev/tty || return 1
  printf '%s\n' "$ans"
}

# Resolve the repo top-level from a path (arg) or $PWD. Works from inside the
# main checkout or any linked worktree.
wt_resolve_repo() {
  local start="${1:-$PWD}"
  git -C "$start" rev-parse --show-toplevel 2>/dev/null \
    || { wt_die "not inside a git repo; cd into one or pass a path (e.g. 'wtls ~/myrepo')"; return 1; }
}

# The bucket a worktree lands in: the basename of the MAIN repo's directory,
# resolved via the git common-dir so it's stable even when invoked from inside
# an existing linked worktree (git-common-dir always points at the main .git).
wt_repo_name() {
  local repo="$1" common
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || { wt_die "failed to resolve git common dir"; return 1; }
  case "$common" in
    /*) ;;
    *) common="$repo/$common" ;;
  esac
  basename "$(dirname "$common")"
}

# owner/repo from origin, for `gh`. Empty if it can't be derived.
wt_origin_slug() {
  local repo="$1" url
  url=$(git -C "$repo" remote get-url origin 2>/dev/null) || { echo ""; return; }
  echo "$url" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
}

# The base a branch was created from: prefer the parent `wtnew` recorded at
# creation time (`branch.<name>.wt-parent`, local-only git config -- see
# wt_new), since that's the true parent even when it's another feature
# branch. Falls back to the nearest-ancestor autodetect heuristic below for
# branches wtnew didn't create (or created before this existed).
# Integration branches themselves return "(base)".
wt_detect_from() {
  local wt="$1" branch="$2"
  case "$branch" in
    null) echo "-"; return;;
    develop|main|master) echo "(base)"; return;;
  esac
  local recorded; recorded=$(git -C "$wt" config "branch.$branch.wt-parent" 2>/dev/null)
  [ -n "$recorded" ] && { echo "$recorded"; return; }

  # Fallback heuristic: the nearest ANCESTOR branch among ALL local branches,
  # not just develop/main/master. The true fork parent is the ancestor with
  # the fewest commits between it and HEAD -- the same rule the push-pr skill
  # uses. Ties (sibling branches forked from the same parent) break toward the
  # branch whose merge-base is more recent, i.e. the one closest to HEAD.
  # Without this, a stacked branch with a lost wt-parent used to report
  # FROM=main, hiding the real chain.
  local best="" best_ahead=-1 best_time=0 b mb ahead mb_time line
  while IFS= read -r line; do
    b="${line%%	*}"
    [ -n "$b" ] || continue
    [ "$b" = "$branch" ] && continue
    if ! git -C "$wt" merge-base --is-ancestor "$b" "$branch" >/dev/null 2>&1; then continue; fi
    mb=$(git -C "$wt" merge-base "$b" "$branch" 2>/dev/null) || continue
    ahead=$(git -C "$wt" rev-list --count "$mb".."$branch" 2>/dev/null) || continue
    mb_time=$(git -C "$wt" log -1 --format=%ct "$mb" 2>/dev/null) || mb_time=0
    if [ "$best_ahead" -lt 0 ] || [ "$ahead" -lt "$best_ahead" ] \
       || { [ "$ahead" -eq "$best_ahead" ] && [ "$mb_time" -gt "$best_time" ]; }; then
      best_ahead="$ahead"; best="$b"; best_time="$mb_time"
    fi
  done < <(git -C "$wt" for-each-ref --format='%(refname:short)' refs/heads/)
  echo "${best:--}"
}

# ahead/behind vs upstream -> "+A/-B", or "-" when no upstream.
wt_sync_state() {
  local wt="$1"
  local up; up=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || { echo "local-only"; return; }
  [ -n "$up" ] || { echo "local-only"; return; }
  local counts a b
  counts=$(git -C "$wt" rev-list --left-right --count "${up}...HEAD" 2>/dev/null) || { echo "local-only"; return; }
  b=$(echo "$counts" | awk '{print $1}'); a=$(echo "$counts" | awk '{print $2}')
  if   [ "$a" = "0" ] && [ "$b" = "0" ]; then echo "synced"
  elif [ "$b" = "0" ];                    then echo "ahead $a"
  elif [ "$a" = "0" ];                    then echo "behind $b"
  else                                         echo "ahead $a, behind $b"; fi
}

# Validate and normalize a worktree root, printing the clean value on stdout.
# $2 names where the value came from and $3 says how to fix it, because the two
# callers need different advice: you retype a prompt answer, but you edit a
# stored one.
#
# Every worktree path is built from this value, so a bad one is not a one-off
# typo -- it misplaces every worktree created afterwards. Two failure modes have
# actually happened: a pasted bracketed-paste marker plus prompt glyph
# ("^[[200~❯ pwd"), and a relative path, which `git worktree add` resolves
# against $PWD and so buries the worktree inside whatever repo you were in.
wt_validate_root() {
  local root="$1" origin="$2" fix="$3"
  # Expand ~ before the absolute check below, which would otherwise reject it.
  case "$root" in
    "~") root="$HOME" ;;
    "~/"*) root="$HOME/${root#\~/}" ;;
  esac
  # Control characters mean it was pasted, not typed: terminals wrap pasted text
  # in ESC[200~ / ESC[201~ and that ESC ends up in the value.
  case "$root" in
    *[[:cntrl:]]*)
      wt_die "worktree root from $origin contains control characters (paste artifact?) — $fix"
      return 1 ;;
  esac
  case "$root" in
    /*) ;;
    *) wt_die "worktree root from $origin must be an absolute path, got '$root' — $fix"; return 1 ;;
  esac
  # Drop trailing slashes so built paths don't come out as "/home/me//worktrees/..."
  while [ "$root" != "/" ] && [ "${root%/}" != "$root" ]; do root="${root%/}"; done
  printf '%s\n' "$root"
}

# Set key=value in the config, treating the value as pure data, and publish it
# with a single atomic rename.
#
# NOT `sed -i "s#^${key}=.*#${key}=${value}#"`: sed reads its own metacharacters
# out of the interpolated value. Verified -- a root of "/tmp/a&b" persisted as
# "linux_root=/tmp/alinux_root=/oldb" (& expands to the whole match), and
# "/tmp/a#b" closed the s/// early and made sed exit non-zero while the caller
# never checked the status.
wt_write_config_key() {
  local key="$1" value="$2" file="$3" dir tmp line out="" found=0
  dir=$(dirname "$file")
  mkdir -p "$dir" || return 1
  # mktemp, NOT "$file.tmp.$$": a predictable name in a writable directory is a
  # symlink target, and the redirection below would follow it and clobber
  # whatever it points at.
  tmp=$(mktemp "$dir/.wt-config.XXXXXX") || return 1
  # Carry the original's mode over. This replaces the file wholesale, whereas
  # `sed -i` edited in place and kept the mode; a fresh mktemp file is 0600, so
  # without this a deliberately-relaxed (or tightened) config would silently
  # change permissions on every update.
  [ -f "$file" ] && chmod --reference="$file" "$tmp" 2>/dev/null
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*) out="${out}${key}=${value}"$'\n'; found=1 ;;
        *)        out="${out}${line}"$'\n' ;;
      esac
    done < "$file"
  fi
  [ "$found" -eq 1 ] || out="${out}${key}=${value}"$'\n'
  # Build the whole file in memory and write ONCE, so there is a single status to
  # check. Appending per line left no way to notice a mid-loop failure (a full
  # disk), and `mv` needs no free space -- it would have cheerfully published a
  # truncated config over a good one.
  printf '%s' "$out" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Read this OS's root from the deployed config, prompting and persisting on first run.
wt_get_root() {
  local key="linux_root" raw="" root=""
  if [ -f "$WT_CONFIG_FILE" ]; then
    raw=$(grep -E "^${key}=" "$WT_CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
  fi
  if [ -n "$raw" ]; then
    # Validate on READ as well as on write. A stored root may predate this
    # check, have been hand-edited, or have arrived via sync-from-system.sh --
    # and an unvalidated stored root is exactly what put a worktree inside the
    # repo instead of under the root. The message names the file to edit.
    root=$(wt_validate_root "$raw" "$WT_CONFIG_FILE" "edit or delete that ${key}= line") || return 1
    printf '%s\n' "$root"
    return 0
  fi
  raw=$(wt_prompt "wt: no worktree root configured for linux — enter the root (worktrees go under {root}/worktrees/{repo}/{branch}): ") \
    || { wt_die "aborted"; return 1; }
  [ -n "$raw" ] || { wt_die "no root provided"; return 1; }
  root=$(wt_validate_root "$raw" "your answer" "type it by hand instead of pasting") || return 1
  wt_write_config_key "$key" "$root" "$WT_CONFIG_FILE" \
    || { wt_die "failed to persist root to '$WT_CONFIG_FILE'"; return 1; }
  printf '%s\n' "$root"
}

# Locate a branch's worktree path via `git worktree list --porcelain`. Empty
# output with a zero exit means the branch genuinely has no worktree -- the
# normal case every caller already checks for. A non-zero exit means the
# LISTING failed, which is a different problem: capture git's output first and
# propagate a real failure, the same fix wt_stale_paths needed for the same
# `git ... | awk ...`-hides-git's-status trap (see its comment). Without this,
# a failing `git worktree list` looked identical to "no worktree for this
# branch" to every one of this function's callers.
wt_find_path() {
  local repo="$1" branch="$2" porcelain
  porcelain=$(git -C "$repo" worktree list --porcelain) \
    || { wt_die "could not list worktrees in '$repo'"; return 1; }
  printf '%s\n' "$porcelain" | awk -v b="$branch" '
    # substr, NOT $2: a worktree path may contain SPACES, and $2 would silently
    # truncate it at the first one, handing the caller a path that does not exist.
    # "worktree " is 9 characters, so the path starts at column 10. Branch names
    # cannot contain spaces (git check-ref-format forbids them), so $2 is safe there.
    /^worktree /{ p=substr($0, 10) }
    /^branch /{ br=$2; sub("refs/heads/","",br); if (br==b) { print p; exit } }
  '
}

# Paths of registrations git reports as prunable (their directory is gone), one
# per line. Exists so wt_new can name what a repo-wide `git worktree prune` is
# about to reclaim, instead of pruning silently.
# Capture git's output BEFORE awk sees it. In `git ... | awk ...` the exit status
# is awk's, and awk happily exits 0 on empty input -- so a failed `worktree list`
# would look exactly like "nothing is stale" and the caller would prune blind,
# which is the very mistake this helper exists to prevent.
wt_stale_paths() {
  local porcelain
  porcelain=$(git -C "$1" worktree list --porcelain) || return 1
  printf '%s\n' "$porcelain" | awk '
    /^worktree /{ if (p!="" && st) print p; p=substr($0, 10); st=0 }
    /^prunable/{ st=1 }
    END{ if (p!="" && st) print p }
  '
}

wt_ls() {
  wt_need git || return 1
  local repo; repo=$(wt_resolve_repo "${1:-}") || return 1
  local cur_top; cur_top=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "")

  # Capture BEFORE the awk pipeline below, and before the (possibly slow) PR
  # lookup: `git ... | awk ...` hands the pipeline awk's exit status, and awk
  # exits 0 on empty input, so a genuinely failed listing would render as an
  # empty table instead of an error -- the same trap wt_stale_paths' comment
  # describes, one call site over.
  local porcelain
  porcelain=$(git -C "$repo" worktree list --porcelain) \
    || { wt_die "could not list worktrees in '$repo'"; return 1; }

  # commit -> branch map (short hashes) to flag duplicate branches (two
  # branches pointing at the same HEAD, e.g. a checkpoint branch).
  declare -A COMMITMAP=()
  local sha cb
  # No quotes around the subscript: zsh (unlike bash) takes `MAP["$h"]`
  # literally -- it stores the quote characters as PART of the key, so a
  # later unquoted lookup like `${COMMITMAP[$head]}` never matches.
  while IFS=' ' read -r sha cb; do
    [ -n "$sha" ] && [ -n "$cb" ] && COMMITMAP[$sha]="$cb"
  done < <(git -C "$repo" for-each-ref --format='%(objectname:short) %(refname:short)' refs/heads/)

  # Build the PR lookup (branch -> "#N STATE→base") plus the PR's own diff
  # (additions/deletions against ITS base). Single gh call. The base powers
  # the "PR opens against the wrong base" warning: when it differs from the
  # branch's parent (FROM), the PR is replaying the parent's commits.
  # NOTE: `commits` is deliberately NOT requested from gh -- that field makes
  # gh traverse the full commit/author connection and GraphQL blows up past
  # the 500k-node cap on busy repos. The commit count is computed locally per
  # row with rev-list instead (see below).
  declare -A PRMAP=() PRBASEMAP=() PRDIFFMAP=()
  if command -v gh >/dev/null 2>&1; then
    local slug; slug=$(wt_origin_slug "$repo")
    if [ -n "$slug" ]; then
      while IFS=$'\t' read -r h n s base add del; do
        [ -n "$h" ] || continue
        PRMAP[$h]="#$n $s→$base"
        PRBASEMAP[$h]="$base"
        PRDIFFMAP[$h]="${add:-0}+/${del:-0}-"
      done < <(gh pr list --repo "$slug" --state all --limit 200 \
                 --json number,state,headRefName,baseRefName,additions,deletions \
                 --jq 'sort_by(.number)[] | [.headRefName,.number,.state,.baseRefName,.additions,.deletions] | @tsv' 2>/dev/null)
    fi
  fi

  # Colors only when writing to an interactive terminal (never in pipes/files).
  local BOLD="" RED="" BRED="" RST=""
  if [ -t 1 ]; then BOLD=$'\033[1m'; RED=$'\033[31m'; BRED=$'\033[1;31m'; RST=$'\033[0m'; fi

  # Declared ONCE, outside the loop below: re-running `local <bare names>`
  # on each iteration of a while loop (same function scope, no new subshell
  # boundary per iteration) makes zsh dump `name=value` for every one of
  # them to stdout on the second and later iterations -- it does not
  # re-initialize them the way bash does, it just echoes them. Declaring
  # once and only assigning inside the loop avoids the dump entirely.
  local disp_branch from head state sync pr pr_diff prbase prbase_ref prc dup warn own mark display_path prunable
  {
    printf '\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "BRANCH" "FROM" "HEAD" "STATE" "SYNC" "PR" "PR DIFF" "PATH"
    printf '%s\n' "$porcelain" | awk '
      # substr, NOT $2: worktree paths may contain spaces (see wt_find_path).
      # `prunable` is carried through too: git emits it for a registration whose
      # gitdir points nowhere, and without it such a row used to render as an
      # ordinary "clean" worktree -- so a broken entry stayed invisible until
      # some command that touched it failed. Named `st`, not `pr`: this function
      # already has a shell variable `pr` holding the GitHub PR state, and two
      # unrelated `pr`s in one function is a trap for whoever edits next.
      /^worktree /{ if (p!="") print p"\t"b"\t"st; p=substr($0, 10); b=""; st="" }
      /^branch /{ b=$2; sub("refs/heads/","",b) }
      /^detached$/{ b="null" }
      /^prunable/{ st="stale" }
      END{ if (p!="") print p"\t"b"\t"st }
    ' | while IFS=$'\t' read -r wtpath branch prunable; do
        [ -n "$branch" ] || branch="null"
        # NEVER name a local var `path` here: zsh ties the lowercase `path`
        # array to `$PATH`, so assigning it silently rewrites PATH for the
        # rest of this loop and breaks every later `git`/`gh` call.
        disp_branch="$branch"
        [ "$branch" = "null" ] && disp_branch="(detached)"
        from=$(wt_detect_from "$wtpath" "$branch")
        head=$(git -C "$wtpath" rev-parse --short HEAD 2>/dev/null || echo "-")
        # "stale" must win: for a prunable entry the directory is gone, so the
        # status call below fails, the substitution comes back empty, and the row
        # would otherwise claim "clean" -- the most misleading answer possible.
        if [ -n "$prunable" ]; then state="stale"
        elif [ -n "$(git -C "$wtpath" status --porcelain 2>/dev/null)" ]; then state="dirty"
        else state="clean"; fi
        sync=$(wt_sync_state "$wtpath")
        warn=""
        pr="${PRMAP[$branch]:-}"
        [ -n "$pr" ] || pr="none"
        pr_diff="—"
        # A branch whose HEAD matches another branch is a duplicate checkpoint,
        # not a line of work of its own -- nothing to review or merge separately.
        dup=""
        if [ "$branch" != "null" ] && [ -n "$head" ] && [ "$head" != "-" ] \
           && [ -n "${COMMITMAP[$head]:-}" ] && [ "${COMMITMAP[$head]}" != "$branch" ]; then
          dup="=${COMMITMAP[$head]}"
        fi
        if [ "$pr" != "none" ]; then
          # Commit count of the PR = commits in this branch not in its base
          # (computed locally; gh's own field blows up GraphQL, see above).
          pr_diff="${PRDIFFMAP[$branch]:-—}"
          prbase="${PRBASEMAP[$branch]:-}"
          prbase_ref=""
          if [ -n "$prbase" ]; then
            if git -C "$wtpath" rev-parse --verify --quiet "origin/$prbase" >/dev/null 2>&1; then prbase_ref="origin/$prbase"
            elif git -C "$wtpath" rev-parse --verify --quiet "$prbase" >/dev/null 2>&1; then prbase_ref="$prbase"; fi
          fi
          if [ -n "$prbase_ref" ]; then
            prc=$(git -C "$wtpath" rev-list --count "$prbase_ref".."$branch" 2>/dev/null || echo "?")
          else
            prc="?"
          fi
          pr_diff="${prc:-?}c/$pr_diff"
          if [ -n "$from" ] && [ "$from" != "-" ] && [ "$prbase" != "$from" ]; then
            # PR opens against a different base than the fork parent: GitHub is
            # replaying the parent's commits on top of this branch's own. Show
            # what the PR carries vs what is actually this branch's work.
            own=$(git -C "$wtpath" rev-list --count "$from".."$branch" 2>/dev/null || echo "?")
            pr_diff="$pr_diff (propios $own) ⚠"
            pr="$pr ⚠"
          fi
        else
          [ -n "$dup" ] && pr="none $dup ⚠"
          if [ -z "$dup" ] && [ -n "$from" ] && [ "$from" != "-" ]; then
            own=$(git -C "$wtpath" rev-list --count "$from".."$branch" 2>/dev/null || echo "0")
            [ "$own" -gt 0 ] 2>/dev/null && { pr="no PR ⚠"; pr_diff="$own commits sueltos"; }
          fi
        fi
        mark=""; [ -n "$cur_top" ] && [ "$wtpath" = "$cur_top" ] && mark="*"
        display_path="${wtpath/#$HOME/\~}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$mark" "$disp_branch" "$from" "$head" "$state" "$sync" "$pr" "$pr_diff" "$display_path"
      done
  } | awk -F'\t' -v BOLD="$BOLD" -v RED="$RED" -v BRED="$BRED" -v RST="$RST" -v WARN='⚠' '
      # Pass 1: store cells, track max width per column (plain text, no color).
      { for (i=1;i<=NF;i++){ cell[NR,i]=$i; if (length($i)>w[i]) w[i]=length($i) }
        if (NF>maxnf) maxnf=NF; nr=NR }
      END {
        for (r=1;r<=nr;r++){
          isrow = (r>1)                             # r==1 is the header
          bold  = (isrow && cell[r,1]=="*") ? 1 : 0 # current worktree row
          line=""
          for (i=1;i<=maxnf;i++){
            val = cell[r,i]
            attn = 0
            if (isrow){
              if      (i==5 && val ~ /dirty|stale/)      attn=1   # STATE
              else if (i==6 && val ~ /^(ahead|behind)/)  attn=1   # SYNC
              else if (i==7 && (val ~ /OPEN/ || index(val, WARN))) attn=1  # PR
              else if (i==8 && index(val, WARN))         attn=1   # PR DIFF
            }
            pad = sprintf("%-*s", w[i], val)          # padding on plain text -> stays aligned
            col = ""
            if      (attn && bold) col=BRED
            else if (attn)         col=RED
            else if (bold)         col=BOLD
            line = line (col=="" ? pad : col pad RST) "  "
          }
          sub(/ +$/,"",line); print line
        }
      }'

  echo
  echo "Legend:"
  echo "  *          the worktree you are currently in"
  echo "  FROM       branch it was created from   ((base) = integration branch, e.g. develop/main)"
  echo "  STATE      clean = no local changes  |  dirty = uncommitted changes"
  echo "             stale = registered but its directory is gone; clean up with 'git worktree prune'"
  echo "  SYNC       vs its remote upstream: synced | ahead N | behind N | ahead N, behind M"
  echo "             local-only = branch never pushed (no upstream to compare against)"
  echo "  PR         GitHub PR state and the base it opens against (#50 OPEN→phase3);"
  echo "             'none =branch' = duplicate branch (same commit as another);"
  echo "             'no PR' = work exists but no PR has been opened"
  echo "  PR DIFF    the PR's own diff vs its base (commits/additions/deletions);"
  echo "             '(propios N)' = commits that are actually this branch's own work"
  echo "  ⚠          PR opens against a different base than the branch's parent, a duplicate"
  echo "             branch, or a branch with unmerged work and no PR"
}

# Interactive picker: list local branches, mark the current one, return choice on stdout.
wt_choose_branch() {
  local repo="$1"
  local current; current=$(git -C "$PWD" branch --show-current 2>/dev/null || echo "")
  local -a branches=()
  while IFS= read -r b; do branches+=("$b"); done \
    < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ | sort)
  [ "${#branches[@]}" -gt 0 ] || return 1
  local i=1 def=1 b mark
  echo "From which branch?" >&2
  for b in "${branches[@]}"; do
    mark=""; [ "$b" = "$current" ] && { mark="  (current) *"; def=$i; }
    printf "  %d) %s%s\n" "$i" "$b" "$mark" >&2
    i=$((i+1))
  done
  local sel
  sel=$(wt_prompt "#? [$def] ") || return 1
  [ -z "$sel" ] && sel="$def"
  [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#branches[@]}" ] || return 1
  echo "${branches[$((sel - 1 + WT_ARRAY_BASE))]}"
}

# Decide what wtnew should do about an existing branch: print "new" on stdout
# if it has none (wtnew should create one), or "reattach" if it exists and can
# safely get a worktree (clearing any stale registration for it first). A
# non-zero return means the decision itself already failed and its own wt_die
# explains why -- either a LIVE worktree already exists (use wtopen instead),
# or a git step here failed. Extracted out of wt_new: this block grew across
# three consecutive rounds of fixes (existence check, refuse-vs-reattach,
# stale-collateral disclosure, prune) until it no longer read as one step.
wt_new_resolve_existing() {
  local repo="$1" name="$2" existing
  git -C "$repo" show-ref --verify --quiet "refs/heads/$name" || { echo "new"; return 0; }

  existing=$(wt_find_path "$repo" "$name") || return 1
  if [ -n "$existing" ] && [ -d "$existing" ]; then
    wt_die "branch '$name' already has a worktree — use 'wtopen $name'"; return 1
  fi
  if [ -n "$existing" ]; then
    # Registered but the directory is gone -- what wtls shows as STATE stale.
    # Sending the user to wtopen here would just fail at the cd, so drop the
    # dead registration; git otherwise still thinks the branch is checked out
    # there and refuses to attach it anywhere else.
    #
    # `git worktree prune` has NO per-entry scope: it reclaims every stale
    # registration in the repo. So list the collateral instead of naming only
    # this branch and quietly taking the rest along.
    echo "note: clearing stale worktree registration for '$name' (${existing/#$HOME/\~})." >&2
    local stale_list
    stale_list=$(wt_stale_paths "$repo") \
      || { wt_die "could not list stale worktree registrations; refusing to prune blindly"; return 1; }
    local -a also_stale=()
    local sp
    while IFS= read -r sp; do
      [ -n "$sp" ] && [ "$sp" != "$existing" ] && also_stale+=("$sp")
    done <<< "$stale_list"
    if [ "${#also_stale[@]}" -gt 0 ]; then
      echo "note: 'git worktree prune' is repo-wide, so these stale registrations go too:" >&2
      for sp in "${also_stale[@]}"; do echo "        ${sp/#$HOME/\~}" >&2; done
    fi
    git -C "$repo" worktree prune \
      || { wt_die "git worktree prune failed, so '$name' cannot be re-attached"; return 1; }
  fi
  echo "reattach"
}

# Walk the wt-parent chain upward from a branch, printing "main → a → b → c".
# Pure bookkeeping read; guards against cycles with a seen-set and a depth cap.
wt_chain() {
  local repo="$1" branch="$2" acc="" seen="" n=0
  while [ -n "$branch" ]; do
    case " $seen " in *" $branch "*) break;; esac
    seen="$seen $branch"
    case "$branch" in
      develop|main|master)
        acc="$branch${acc:+ → $acc}"; branch="";;
      *)
        acc="${branch}${acc:+ → $acc}"
        branch=$(git -C "$repo" config "branch.$branch.wt-parent" 2>/dev/null) || branch=""
        n=$((n+1)); [ "$n" -gt 10 ] && branch="";;
    esac
  done
  echo "$acc"
}

wt_new() {
  wt_need git || return 1
  local name="${1:-}" from="${2:-}"
  [ -n "$name" ] || { wt_die "usage: wtnew <name> [base]"; return 1; }

  local repo; repo=$(wt_resolve_repo) || return 1

  # An existing branch is two very different situations, and conflating them used
  # to dead-end the user: wtopen said "create it with wtnew" while wtnew said
  # "already exists -- use wtopen", so a branch whose worktree had been removed
  # could never get one back. wt_new_resolve_existing tells the two apart.
  local resolution; resolution=$(wt_new_resolve_existing "$repo" "$name") || return 1
  local reattach=0; [ "$resolution" = "reattach" ] && reattach=1

  local baseref="$from"
  if [ "$reattach" -eq 1 ]; then
    # Re-attaching: the branch already carries its history, so there is nothing
    # to fork from and nothing to fetch. Ignore any base argument rather than
    # pretend it was used.
    [ -n "$from" ] && echo "note: branch '$name' already exists; re-attaching a worktree and ignoring base '$from'." >&2
    from=""
  else
    # Pick the source branch interactively when not given.
    if [ -z "$from" ]; then
      from=$(wt_choose_branch "$repo") || { wt_die "no source branch selected; aborted"; return 1; }
    fi
    git -C "$repo" show-ref --verify --quiet "refs/heads/$from" \
      || git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$from" \
      || { wt_die "source branch '$from' not found (local or origin/)"; return 1; }

    # Always start from the latest: fetch the source branch and fork from origin/<from>.
    # Fall back to the local ref if there is no remote branch or the network is down.
    baseref="$from"
    if git -C "$repo" fetch origin "$from" >/dev/null 2>&1; then
      baseref="origin/$from"
      echo "Fetched latest origin/$from."
    else
      echo "note: could not fetch origin/$from; starting from local '$from'." >&2
    fi
  fi

  local root; root=$(wt_get_root) || return 1
  local reponame; reponame=$(wt_repo_name "$repo") || return 1
  # Branch may contain '/' (e.g. feature/foo) -- that just nests directories, which is fine.
  # Named `wtpath`, never `path`: zsh ties lowercase `path` to `$PATH`.
  local wtpath="$root/worktrees/$reponame/$name"

  mkdir -p "$(dirname "$wtpath")" || { wt_die "failed to create parent directory for '$wtpath'"; return 1; }

  if [ "$reattach" -eq 1 ]; then
    # No -b: check the existing branch out instead of creating it.
    git -C "$repo" worktree add "$wtpath" "$name" || { wt_die "git worktree add failed"; return 1; }
    echo "Re-attached worktree for existing branch '$name'  ->  ${wtpath/#$HOME/\~}"
    return 0
  fi

  git -C "$repo" worktree add "$wtpath" -b "$name" "$baseref" || { wt_die "git worktree add failed"; return 1; }
  # Record the real parent (local-only git config, never pushed -- see
  # wt_detect_from) so `wtls`'s FROM column shows it even when it's another
  # feature branch, not just one of develop/main/master.
  git -C "$repo" config "branch.$name.wt-parent" "$from"

  # First push: publish the branch to origin right away so it exists remotely
  # before any commit, and set the upstream so `wtls`'s SYNC column shows
  # "synced" instead of "local-only". The worktree is already created, so a
  # failed push (no origin, no network) is a note, not a failure.
  local push_out=""
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    if push_out=$(git -C "$repo" push -u origin "$name" 2>&1); then
      echo "Pushed '$name' to origin."
    else
      echo "note: could not push '$name' to origin (worktree created anyway):" >&2
      echo "      ${push_out:-unknown error}" >&2
    fi
  else
    echo "note: no 'origin' remote; skipped initial push." >&2
  fi
  echo "Created worktree '$name' from '$from'  ->  ${wtpath/#$HOME/\~}"

  # Stack context: when the base is another feature branch, show the chain and
  # warn that the PR for this branch will be stacked on the base's PR (it must
  # merge bottom-up) rather than opened against main -- the decision that used
  # to be taken silently.
  case "$from" in
    develop|main|master) ;;
    *)
      local integ=""
      for base in main origin/main; do
        if git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then integ="$base"; break; fi
      done
      if [ -n "$integ" ] && ! git -C "$repo" merge-base --is-ancestor "$from" "$integ" >/dev/null 2>&1; then
        echo "note: base '$from' is NOT merged into $integ — the PR for '$name' will be stacked on '$from''s PR and must merge after it (bottom-up)." >&2
      fi
      local chain; chain=$(wt_chain "$repo" "$name")
      [ -n "$chain" ] && echo "Stack: $chain"
      ;;
  esac
}

wt_open() {
  wt_need git || return 1
  local branch="${1:-}"
  [ -n "$branch" ] || { wt_die "usage: wtopen <branch>"; return 1; }
  local repo; repo=$(wt_resolve_repo) || return 1

  # `wtpath`, never `path`: zsh ties lowercase `path` to `$PATH`.
  local wtpath; wtpath=$(wt_find_path "$repo" "$branch") || return 1
  [ -n "$wtpath" ] || { wt_die "no worktree for branch '$branch' — create it with 'wtnew $branch'"; return 1; }

  # Plain `cd`, no subshell: this must run in the calling interactive shell.
  cd "$wtpath" || { wt_die "failed to cd into '$wtpath'"; return 1; }
  echo "Opened worktree '$branch'  ->  ${wtpath/#$HOME/\~}"
}

wt_rm() {
  wt_need git || return 1
  local force=0
  local -a pos=()
  local a
  for a in "$@"; do
    case "$a" in
      --force|-f) force=1;;
      -*) wt_die "unknown flag '$a'"; return 1;;
      *)  pos+=("$a");;
    esac
  done
  local branch="${pos[$WT_ARRAY_BASE]:-}"
  [ -n "$branch" ] || { wt_die "usage: wtrm <branch> [--force]"; return 1; }
  local repo; repo=$(wt_resolve_repo) || return 1

  case "$branch" in
    develop|main|master) wt_die "refusing to remove integration branch '$branch'"; return 1;;
  esac
  local current; current=$(git -C "$PWD" branch --show-current 2>/dev/null || echo "")
  [ "$branch" = "$current" ] && { wt_die "you're currently on '$branch'; switch away first"; return 1; }

  # `wtpath`, never `path`: zsh ties lowercase `path` to `$PATH`.
  local wtpath; wtpath=$(wt_find_path "$repo" "$branch") || return 1
  [ -n "$wtpath" ] || { wt_die "no worktree for branch '$branch'"; return 1; }

  # State: merged into detected base? open PR? dirty?
  local base baseref="" merged="unknown"
  base=$(wt_detect_from "$wtpath" "$branch")
  if [ "$base" != "-" ]; then
    if git -C "$wtpath" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then baseref="$base"
    elif git -C "$wtpath" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then baseref="origin/$base"; fi
    if [ -n "$baseref" ] && git -C "$wtpath" merge-base --is-ancestor "$branch" "$baseref" 2>/dev/null; then
      merged="yes"; else merged="no"; fi
  fi
  local pr="-"
  if command -v gh >/dev/null 2>&1; then
    local slug; slug=$(wt_origin_slug "$repo")
    [ -n "$slug" ] && pr=$(gh pr list --repo "$slug" --head "$branch" --state all --limit 1 \
      --json number,state --jq 'if length>0 then "#\(.[0].number) \(.[0].state)" else "-" end' 2>/dev/null || echo "-")
    [ -z "$pr" ] && pr="-"
  fi
  local dirty="no"; [ -n "$(git -C "$wtpath" status --porcelain 2>/dev/null)" ] && dirty="yes"

  echo "Worktree:  $branch  ->  ${wtpath/#$HOME/\~}"
  echo "Merged:    $merged${baseref:+ (into $baseref)}"
  echo "PR:        $pr"
  echo "Dirty:     $dirty"

  # Blocking conditions unless --force.
  local blocked=""
  [ "$merged" = "no" ] && blocked+="not merged; "
  echo "$pr" | grep -q "OPEN" && blocked+="open PR; "
  [ "$dirty" = "yes" ] && blocked+="uncommitted changes; "
  if [ -n "$blocked" ] && [ "$force" -ne 1 ]; then
    wt_die "refusing to remove (${blocked%; }) — pass --force to override"; return 1
  fi

  if [ "$force" -ne 1 ]; then
    local ans; ans=$(wt_prompt "Remove this worktree? [y/N] ") || { wt_die "aborted"; return 1; }
    case "$ans" in y|Y|yes|YES) ;; *) wt_die "aborted"; return 1;; esac
  fi

  # Check that the removal actually worked before claiming it did -- and, more
  # importantly, before the branch deletion below. These calls used to be
  # `2>/dev/null || true` with the status discarded, so a locked worktree or a
  # permission error still printed "Removed" and then deleted the branch,
  # leaving the directory on disk with nothing pointing at it.
  local rm_out rm_rc
  if [ "$force" -eq 1 ]; then
    rm_out=$(git -C "$repo" worktree remove --force "$wtpath" 2>&1); rm_rc=$?
  else
    rm_out=$(git -C "$repo" worktree remove "$wtpath" 2>&1); rm_rc=$?
  fi
  if [ "$rm_rc" -ne 0 ]; then
    wt_die "git worktree remove failed, so branch '$branch' was kept: ${rm_out:-unknown error}"
    return 1
  fi
  git -C "$repo" worktree prune 2>/dev/null || true
  echo "Removed worktree '$branch'."

  # Local branch: safe -d when merged; -D only with --force when not merged.
  local branch_deleted=0
  if [ "$merged" = "yes" ]; then
    if [ "$force" -eq 1 ]; then
      git -C "$repo" branch -d "$branch" 2>/dev/null && { echo "Deleted merged branch '$branch'."; branch_deleted=1; }
    else
      local ans2; ans2=$(wt_prompt "Also delete local branch '$branch' (merged)? [y/N] ") || ans2=n
      case "$ans2" in
        y|Y|yes|YES) git -C "$repo" branch -d "$branch" && { echo "Deleted branch '$branch'."; branch_deleted=1; };;
      esac
    fi
  elif [ "$force" -eq 1 ]; then
    git -C "$repo" branch -D "$branch" 2>/dev/null && { echo "Force-deleted unmerged branch '$branch'."; branch_deleted=1; }
  else
    echo "Kept local branch '$branch'."
  fi

  # The local branch is gone but it may still live on origin (this script never
  # touches the remote). Offer to delete it there too -- only when it's merged,
  # so no history is lost, and only if the local branch was actually deleted.
  if [ "$branch_deleted" -eq 1 ] && [ "$merged" = "yes" ] \
     && git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    local ans3=yes
    if [ "$force" -ne 1 ]; then
      ans3=$(wt_prompt "Delete '$branch' on origin too? This removes the branch from the shared copy of the project on the server, so it stops existing for the whole team. [y/N] ") || ans3=n
    fi
    case "$ans3" in
      y|Y|yes|YES)
        if git -C "$repo" push origin --delete "$branch" >/dev/null 2>&1; then
          echo "Deleted remote branch 'origin/$branch'."
        else
          echo "note: could not delete 'origin/$branch' (no network, or already gone)." >&2
        fi ;;
    esac
  fi

  # Offer to prune stale remote-tracking refs: local copies of branches that no
  # longer exist on origin keep showing up in `wtls` and `git branch -r` until a
  # fetch --prune forgets them. Non-destructive to your work -- it only drops the
  # outdated bookkeeping, never your commits.
  if [ "$branch_deleted" -eq 1 ]; then
    local ans4=yes
    if [ "$force" -ne 1 ]; then
      ans4=$(wt_prompt "Also clean up stale remote branch references? This removes the outdated local copies of branches that no longer exist on the server (deleted by you or anyone else), so your branch list only shows what is really there. [y/N] ") || ans4=n
    fi
    case "$ans4" in
      y|Y|yes|YES)
        if git -C "$repo" fetch --prune origin >/dev/null 2>&1; then
          echo "Pruned stale remote-tracking branches."
        else
          echo "note: could not prune remote-tracking branches (no network?)." >&2
        fi ;;
    esac
  fi
}

# Thin entry points -- these are what the user types.
wtls()   { wt_ls "$@"; }
wtnew()  { wt_new "$@"; }
wtopen() { wt_open "$@"; }
wtrm()   { wt_rm "$@"; }
