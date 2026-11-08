#!/usr/bin/env bash
# git-push-guard.sh — shared pre-tool hook for Claude Code, Codex CLI, Gemini CLI
# and Cline. (agy is the fifth supported CLI; its hooks cannot gate a tool call,
# so it gets no guard.)
#
# Auto-approves `git push` to ordinary feature branches, and ASKS before a push
# to (or a delete of) a protected / "parent" branch (main, develop, release/*, ...).
#
# Decision table:
#   push --all / --mirror ................... deny  (sweeps every ref at once)
#   push to / delete of protected branch .... ask   (deny on hosts that cannot ask)
#   force / force-with-lease (any branch) ... ask   (never silent)
#   branch cannot be determined ............. ask
#   anything else ........................... allow
#
# Protected pushes ask rather than deny because a deny cannot be overridden from
# inside the session: when the user explicitly wants the push, a deny just
# blocks them. The ask puts that decision in front of the human instead.
#
# Every push in a compound command is judged and the STRICTEST decision wins
# (deny > ask > allow). Stopping at the first decision would let an ask for one
# push hide a deny for the next: approving `git push origin main && git push
# --all` would otherwise run the --all too.
#
# Not a push at all -> exit 0 with no output, normal permission flow continues.
#
# One flag selects the host's output protocol. Each host understands a different
# subset of the table above. An allow it cannot express collapses to a silent
# exit 0, which hands the call back to the host's own approval flow. An ask it
# cannot express does too — EXCEPT the protected-branch ask, which becomes a
# deny: on Cline the host's own flow auto-approves everything, so passing it
# through would push to main with no prompt at all.
#
#   (none)        Claude Code. hookSpecificOutput.permissionDecision, all three.
#   --deny-only   Codex. Same JSON, deny ONLY — its hook engine rejects "allow"
#                 and "ask" ("PreToolUse hook returned unsupported
#                 permissionDecision:allow"), and a deny needs a non-empty
#                 permissionDecisionReason.
#   --gemini      Gemini CLI BeforeTool. Top-level {"decision","reason"}; deny
#                 and ask are honoured, allow is not (the policy engine decides).
#   --cline       Cline PreToolUse. {"cancel":true,"errorMessage"} — deny only,
#                 and Cline ends the whole run on it rather than skipping the
#                 one call. Its "review" field is parsed but never acted on.
#
# Configure protected branches with either:
#   export CLAUDE_PROTECTED_BRANCHES="main,develop,release/*"
#   ~/.claude/protected-branches.txt   (one glob per line, # for comments)
# The remote's default branch (origin/HEAD) is always protected.

set -uo pipefail

DEFAULT_PROTECTED='main,master,develop,development,trunk,staging,stage,prod,production,release/*,hotfix/*'

MODE=claude
case "${1:-}" in
  --deny-only) MODE=codex ;;
  --gemini)    MODE=gemini ;;
  --cline)     MODE=cline ;;
esac

# The strictest decision seen so far, across every push in the command.
DECISION=""; REASON=""
rank() { case "$1" in deny) echo 3 ;; ask) echo 2 ;; allow) echo 1 ;; *) echo 0 ;; esac; }

decide() { # $1=allow|deny|ask  $2=reason  $3=what an ask becomes where the host cannot ask
  local d=$1 r=$2
  if [ "$d" = "ask" ] && { [ "$MODE" = "codex" ] || [ "$MODE" = "cline" ]; }; then
    d=${3:-pass}
    [ "$d" = "deny" ] && r="$r Confirmation is not possible from this hook, so it is blocked instead — push it yourself from a terminal, or exempt the branch with a '!<branch>' line in .guardrails-protected."
  fi
  if [ "$(rank "$d")" -gt "$(rank "$DECISION")" ]; then DECISION=$d; REASON=$r; fi
}

emit() { # writes the final DECISION in the host's protocol
  case "$MODE" in
    claude) [ -n "$DECISION" ] || exit 0 ;;
    codex)  [ "$DECISION" = "deny" ] || exit 0 ;;
    gemini) case "$DECISION" in deny|ask) ;; *) exit 0 ;; esac
            jq -cn --arg d "$DECISION" --arg r "$REASON" \
              '{decision:$d, reason:$r} + (if $d == "ask" then {systemMessage:$r} else {} end)'
            exit 0 ;;
    cline)  [ "$DECISION" = "deny" ] || exit 0
            jq -cn --arg r "$REASON" '{cancel:true, errorMessage:$r}'
            exit 0 ;;
  esac
  jq -cn --arg d "$DECISION" --arg r "$REASON" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

# Claude and Gemini pass tool_input.command as a string; Codex's `shell` tool
# passes an argv array (["bash","-lc","git push ..."]), joined into one line.
# Cline has no tool_input: it sends tool_call {name, input}, and its
# run_commands input is a LIST of separate commands — strings, or
# {command, args} objects — so those become one line each. Cline fires the hook
# for every tool, and its editor tool has a "command" field too, so anything but
# run_commands is ignored.
cmd=$(printf '%s' "$input" | jq -r '
  def one: if type == "string" then .
           elif type == "object" then ([.command // empty] + ((.args // []) | map(tostring)) | join(" "))
           else empty end;
  if .tool_input then
    (.tool_input.command // .tool_input.cmd // empty)
    | if type == "array" then join(" ") else . end
  elif .tool_call.name == "run_commands" then
    .tool_call.input
    | (if type == "object" then
         (if has("commands") then .commands
          elif has("command") and has("args") then [.]
          else (.command // .cmd // empty) end)
       else . end)
    | if type == "array" then map(one) | join("\n") else one end
  else empty end
' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Cheap bail-out: the vast majority of Bash calls are not pushes.
case "$cmd" in
  *push*) ;;
  *) exit 0 ;;
esac

# Gemini may run the command in tool_input.dir_path; Cline sends workspaceRoots
# instead of cwd.
cwd=$(printf '%s' "$input" | jq -r '
  (.tool_input.dir_path | select(type == "string" and startswith("/")))
  // .cwd // (.workspaceRoots // [])[0] // empty' 2>/dev/null)
{ [ -n "$cwd" ] && [ -d "$cwd" ]; } || cwd=$PWD

# ---------------------------------------------------------------- protected set
# Sources, in order. A line beginning with "!" EXEMPTS a pattern, which is the
# only way to subtract from the defaults — needed for solo repos where main
# genuinely is the working branch.
#
#   1. $CLAUDE_PROTECTED_BRANCHES        replaces the defaults entirely
#   2. ~/.claude/protected-branches.txt  adds (or exempts with !)
#   3. <repo>/.guardrails-protected      adds (or exempts with !), per-repo
#   4. origin/HEAD                       always added
#
# NOTE: the env var must be set in the environment of the *agent process*, not
# inline on the command — the hook is spawned separately and never sees an
# inline `VAR=x git push` prefix. Use the per-repo file for one-off overrides.
PROTECTED=()
EXEMPT=()
IFS=',' read -r -a PROTECTED <<< "${CLAUDE_PROTECTED_BRANCHES:-$DEFAULT_PROTECTED}"

read_cfg() {
  [ -r "$1" ] || return 0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line// /}"
    [ -n "$line" ] || continue
    case "$line" in
      !*) EXEMPT+=("${line#!}") ;;
      *)  PROTECTED+=("$line") ;;
    esac
  done < "$1"
}

read_cfg "${HOME}/.claude/protected-branches.txt"
repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
[ -n "$repo_root" ] && read_cfg "$repo_root/.guardrails-protected"

# The remote's own default branch, whatever it is called.
origin_head=$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
[ -n "$origin_head" ] && PROTECTED+=("${origin_head#origin/}")

is_protected() {
  local b="$1" p
  # An explicit exemption wins over every protection rule.
  for p in "${EXEMPT[@]}"; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2053  # unquoted $p is deliberate: glob match
    [[ $b == $p ]] && return 1
  done
  for p in "${PROTECTED[@]}"; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2053
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

  if [ "$sweep" -eq 1 ]; then
    decide deny "git push --all/--mirror pushes every ref, including protected branches. Push one branch explicitly instead."
    return 0
  fi

  local -a targets=() r dst
  if [ ${#refspecs[@]} -eq 0 ]; then
    dst=$(current_branch)
    [ -n "$dst" ] || { decide ask "Detached HEAD — cannot tell which branch this push targets."; return 0; }
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
      [ -n "$dst" ] || { decide ask "Could not resolve the target ref in '$r'."; return 0; }
      targets+=("$dst")
    done
  fi

  local b how
  for b in "${targets[@]}"; do
    if is_protected "$b"; then
      if [ "$delete" -eq 1 ]; then how="DELETE it on the remote"
      elif [ "$force" -eq 1 ]; then how="FORCE-push to it"
      else how="push to it"; fi
      decide ask "'$b' is a protected/parent branch — confirm you really mean to $how. (Protected: ${PROTECTED[*]})" deny
      return 0
    fi
  done

  if [ "$force" -eq 1 ]; then
    decide ask "Force-push to '${targets[*]}' rewrites remote history — confirm this is your own branch."
  elif [ "$delete" -eq 1 ]; then
    decide ask "Deleting remote branch '${targets[*]}'."
  else
    decide allow "'${targets[*]}' is not a protected branch."
  fi
}

# Split on shell operators so `git add -A && git commit -m x && git push` is caught.
while IFS= read -r seg; do
  [ -n "${seg// /}" ] || continue
  analyze "$seg"
done < <(printf '%s\n' "$cmd" | sed -E 's/(\&\&|\|\||;|\||\n)/\n/g')

emit
