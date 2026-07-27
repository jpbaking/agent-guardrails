#!/usr/bin/env bash
# git-push-guard.sh — shared PreToolUse hook for Claude Code and Codex CLI.
#
# Auto-approves `git push` to ordinary feature branches, and DENIES pushes that
# target a protected / "parent" branch (main, develop, release/*, ...).
#
# Decision table:
#   push to protected branch ................ deny
#   push --all / --mirror ................... deny  (sweeps protected refs too)
#   force / force-with-lease (any branch) ... ask   (never silent)
#   branch cannot be determined ............. ask
#   anything else ........................... allow
#
# Not a push at all -> exit 0 with no output, normal permission flow continues.
#
# --deny-only   Emit ONLY deny decisions; allow/ask collapse to a silent exit 0.
#               Required for Codex, whose hook engine rejects PreToolUse
#               permissionDecision "allow" and "ask" (it errors with
#               "PreToolUse hook returned unsupported permissionDecision:allow").
#               Codex denies still require a non-empty permissionDecisionReason.
#               Under --deny-only a force-push to a non-protected branch falls
#               through to the host's own approval flow instead of prompting.
#
# Configure protected branches with either:
#   export CLAUDE_PROTECTED_BRANCHES="main,develop,release/*"
#   ~/.claude/protected-branches.txt   (one glob per line, # for comments)
# The remote's default branch (origin/HEAD) is always protected.

set -uo pipefail

DEFAULT_PROTECTED='main,master,develop,development,trunk,staging,stage,prod,production,release/*,hotfix/*'

DENY_ONLY=0
[ "${1:-}" = "--deny-only" ] && DENY_ONLY=1

emit() { # $1=allow|deny|ask  $2=reason
  # Codex accepts deny only; anything else must be a silent pass-through.
  if [ "$DENY_ONLY" -eq 1 ] && [ "$1" != "deny" ]; then
    exit 0
  fi
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

# Claude passes tool_input.command as a string; Codex's `shell` tool passes an
# argv array (["bash","-lc","git push ..."]). Normalize both to one line.
cmd=$(printf '%s' "$input" | jq -r '
  (.tool_input.command // .tool_input.cmd // empty)
  | if type == "array" then join(" ") else . end
' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Cheap bail-out: the vast majority of Bash calls are not pushes.
case "$cmd" in
  *push*) ;;
  *) exit 0 ;;
esac

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
{ [ -n "$cwd" ] && [ -d "$cwd" ]; } || cwd=$PWD

# ---------------------------------------------------------------- protected set
PROTECTED=()
IFS=',' read -r -a PROTECTED <<< "${CLAUDE_PROTECTED_BRANCHES:-$DEFAULT_PROTECTED}"

cfg="${HOME}/.claude/protected-branches.txt"
if [ -r "$cfg" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line// /}"
    [ -n "$line" ] && PROTECTED+=("$line")
  done < "$cfg"
fi

# The remote's own default branch, whatever it is called.
origin_head=$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
[ -n "$origin_head" ] && PROTECTED+=("${origin_head#origin/}")

is_protected() {
  local b="$1" p
  for p in "${PROTECTED[@]}"; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2053  # unquoted $p is deliberate: glob match
    [[ $b == $p ]] && return 0
  done
  return 1
}

current_branch() {
  local b
  b=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ "$b" = "HEAD" ] && b=""   # detached
  printf '%s' "$b"
}

# ---------------------------------------------------------------- push analysis
analyze() { # $1 = one shell segment
  local seg="$1"
  local -a toks=()
  read -r -a toks <<< "$seg"

  local n=${#toks[@]} i pi=-1 hasgit=0
  for ((i = 0; i < n; i++)); do
    [ "${toks[i]}" = "push" ] && { pi=$i; break; }
  done
  [ "$pi" -ge 0 ] || return 0
  for ((i = 0; i < pi; i++)); do
    case "${toks[i]}" in git|*/git) hasgit=1 ;; esac
  done
  [ "$hasgit" -eq 1 ] || return 0

  local force=0 delete=0 sweep=0 remote="" skipnext=0 t
  local -a refspecs=()
  for ((i = pi + 1; i < n; i++)); do
    t="${toks[i]}"
    [ "$skipnext" -eq 1 ] && { skipnext=0; continue; }
    case "$t" in
      -f|--force|--force-with-lease|--force-with-lease=*|--force-if-includes) force=1 ;;
      -d|--delete)                                                            delete=1 ;;
      --all|--mirror)                                                         sweep=1 ;;
      -o|--push-option|--repo|--receive-pack|--exec)                          skipnext=1 ;;
      --) ;;
      -*) ;;
      *)  if [ -z "$remote" ]; then remote="$t"; else refspecs+=("$t"); fi ;;
    esac
  done

  [ "$sweep" -eq 1 ] && emit deny \
    "git push --all/--mirror pushes every ref, including protected branches. Push one branch explicitly instead."

  local -a targets=() r dst
  if [ ${#refspecs[@]} -eq 0 ]; then
    dst=$(current_branch)
    [ -n "$dst" ] || emit ask "Detached HEAD — cannot tell which branch this push targets."
    targets+=("$dst")
  else
    for r in "${refspecs[@]}"; do
      case "$r" in
        +*) force=1; r="${r#+}" ;;
      esac
      if [ "${r:0:1}" = ":" ]; then
        delete=1; dst="${r#:}"
      elif [[ $r == *:* ]]; then
        dst="${r##*:}"
      else
        dst="$r"
      fi
      dst="${dst#refs/heads/}"
      [ "$dst" = "HEAD" ] && dst=$(current_branch)
      [ -n "$dst" ] || emit ask "Could not resolve the target ref in '$r'."
      targets+=("$dst")
    done
  fi

  local b
  for b in "${targets[@]}"; do
    if is_protected "$b"; then
      if [ "$delete" -eq 1 ]; then
        emit deny "'$b' is a protected/parent branch — refusing to delete it on the remote."
      fi
      emit deny "'$b' is a protected/parent branch. Push to a feature branch and open a PR instead. (Protected: ${PROTECTED[*]})"
    fi
  done

  [ "$force" -eq 1 ] && emit ask \
    "Force-push to '${targets[*]}' rewrites remote history — confirm this is your own branch."
  [ "$delete" -eq 1 ] && emit ask \
    "Deleting remote branch '${targets[*]}'."

  emit allow "'${targets[*]}' is not a protected branch."
}

# Split on shell operators so `git add -A && git commit -m x && git push` is caught.
while IFS= read -r seg; do
  [ -n "${seg// /}" ] || continue
  analyze "$seg"
done < <(printf '%s\n' "$cmd" | sed -E 's/(\&\&|\|\||;|\||\n)/\n/g')

exit 0
