# Contributing

For humans and for coding agents. If you are an agent working in this repo, read the whole file — the Verification section is not optional, and the Ground rules exist because this tool writes to files people depend on.

## What this repo is

Two shell scripts and some policy templates.

```
agent-guardrails.sh              entry point — rule lists, translation, writers
hooks/git-push-guard.sh          the PreToolUse hook, shared by Claude and Codex
enterprise/                      drop-in policy files for admins
```

`agent-guardrails.sh` holds the rule lists (`ALLOW`, `ASK`, `DENY`) as bash arrays near the top, a `to_agy` translator, and three writer functions (`write_claude`, `write_codex`, `write_agy`). The guard is a standalone script that reads hook JSON on stdin and writes a decision to stdout.

## Ground rules

**This tool edits other people's config files.** Every writer must: back up to `<file>.bak` before touching anything, merge rather than replace, produce identical output on a second run, and never drop keys it doesn't recognize. If you change a writer, re-verify all four properties.

**Never widen the allowlist casually.** A rule earns `allow` only if it is local, reversible, doesn't publish anything outward, and doesn't escalate privilege. When unsure, `ask` is the right answer — prompt fatigue is a worse outcome than a data breach, but only slightly.

**Don't claim a capability you haven't verified in the binary.** The three harnesses differ in ways that are not documented anywhere. See below.

## Harness constraints you must respect

These were established by reading the shipped binaries. Violating them produces hooks that silently fail or error.

**Codex** — `PreToolUse` accepts `permissionDecision: "deny"` and nothing else. The binary carries these validator strings:

```
PreToolUse hook returned unsupported permissionDecision:allow
PreToolUse hook returned unsupported permissionDecision:ask
PreToolUse hook returned unsupported decision:approve
PreToolUse hook returned permissionDecision:deny without a non-empty permissionDecisionReason
```

A deny **must** carry a non-empty reason. The shell tool's matcher is `shell`, not `Bash`, and its `tool_input.command` is an argv array (`["bash","-lc","…"]`), not a string. Hooks require `[features] hooks = true` in `config.toml`. Codex has no allowlist mechanism — don't add one.

**agy** — has `permissions.allow` / `.ask` / `.deny` in `~/.gemini/antigravity-cli/settings.json`, with rule syntax `command(…)`, `read_file(…)`, `write_file(…)`, `unsandboxed(…)`. It has no `permissionDecision`, `hookSpecificOutput`, or `hookEventName` anywhere in the binary, so hooks cannot gate permissions. It has no per-project settings file; project scope adds to `trustedWorkspaces`.

**Claude Code** — the permissive one. Full `allow`/`ask`/`deny` from a `PreToolUse` hook via `hookSpecificOutput`, matcher `Bash`, `tool_input.command` is a string.

### Re-verifying after a CLI update

Constraints change between versions. To re-check:

```bash
CX=~/.codex/packages/standalone/current/bin/codex
strings "$CX" | grep -oE 'PreToolUse hook returned[^"]*' | sort -u
strings "$CX" | grep -oE '(hookSpecificOutput|permissionDecision|hookEventName)' | sort -u

A=$(command -v agy)
strings "$A" | grep -oE '(command|read_file|write_file|unsandboxed)\([^)]{0,30}\)' | sort -u
strings "$A" | grep -oE '"(allow|deny|ask|permissions|hooks)"' | sort -u
```

If a constraint changed, update the code **and** the capability table in `README.md` — including its `verified against` column and the **Last verified** date beneath it. A stale date is a warning to readers; a fresh date on unverified claims is a lie to them. Only bump the date for versions you actually ran the commands against.

## Verification

There is no CI and no test suite by design — this tool's blast radius is config files, so verification is manual and adversarial. Do all of it before opening a PR.

**1. Syntax.**

```bash
bash -n agent-guardrails.sh && bash -n hooks/git-push-guard.sh
shellcheck agent-guardrails.sh hooks/git-push-guard.sh   # if you have it
```

**2. The guard's decision table.** Build a throwaway repo and drive the hook with synthetic payloads:

```bash
mkdir /tmp/gg && cd /tmp/gg
git init -q -b main . && git commit -q --allow-empty -m init
git checkout -q -b feature/x
H=hooks/git-push-guard.sh; R=$PWD

t() { echo "{\"tool_name\":\"Bash\",\"cwd\":\"$R\",\"tool_input\":{\"command\":$(jq -Rn --arg c "$1" '$c')}}" \
      | bash "$H" | jq -rc '.hookSpecificOutput.permissionDecision // "pass"'; }

t "git push origin main"                        # deny
t "git push origin develop"                     # deny
t "git push origin HEAD:release/2.1"            # deny
t "git push --all origin"                       # deny
t "git push origin :main"                       # deny
t "git push -u origin feature/x"                # allow
t "git push"                                    # allow
t "git add -A && git commit -m wip && git push" # allow
t "git push --force origin feature/x"           # ask
t "npm test"                                    # pass (no output)
t "git status"                                  # pass (no output)
```

Then the Codex path — argv array, `--deny-only`, and confirm allow/ask collapse to a silent pass:

```bash
ct() { echo "{\"tool_name\":\"shell\",\"cwd\":\"$R\",\"tool_input\":{\"command\":[\"bash\",\"-lc\",$(jq -Rn --arg c "$1" '$c')]}}" \
       | bash "$H" --deny-only | jq -rc '.hookSpecificOutput.permissionDecision // "pass"'; }
ct "git push origin main"          # deny, with a non-empty reason
ct "git push -u origin feature/x"  # pass
```

**3. The writers, against copies — never your live config.**

```bash
mkdir -p /tmp/sb/.claude /tmp/sb/.codex /tmp/sb/gemini/antigravity-cli
cp ~/.claude/settings.json /tmp/sb/.claude/
# … then sed the HOME-derived paths in a scratch copy of the script to point at /tmp/sb
```

Confirm, on the result: existing keys survive (`model`, `theme`, other hooks), counts are what you expect, a second run changes nothing, and the file still parses (`jq -e .`, or `python3 -c 'import tomllib…'` for TOML).

**4. Stale-path self-healing.** Pre-seed a config with a guard entry pointing at an old path and confirm the writer replaces it rather than appending a second one. This was a real bug; keep it fixed.

## Adding rules

Edit the `ALLOW` / `ASK` / `DENY` arrays. Keep them grouped by toolchain with the existing comment headers, and keep entries alphabetical within a group where it doesn't fight the grouping.

Claude syntax is the source of truth; `to_agy` translates. If you add a rule form `to_agy` doesn't handle (anything that isn't `Bash(…)` or `Read(…)`), extend the translator in the same PR — a silently-dropped rule is worse than a missing one.

Do not add `Bash(git push *)` to `ALLOW`. That defeats the guard, which is the entire point of the project.

## Style

POSIX-ish bash, `set -euo pipefail`, 2-space indent. Quote every expansion — an unquoted `$(…)` word-split multi-word rules into garbage once already. Prefer `jq` for all JSON manipulation; never hand-roll JSON with string concatenation. Comments explain *why* a rule is where it is, not what the line does.

## For agents specifically

- Read `agent-guardrails.sh` end to end before editing it. The writers look similar and are not interchangeable.
- Run the full verification above and paste real output in the PR. Do not assert that tests pass without showing them.
- If you find a genuine limitation, write it into README's **Honest limitations** section rather than quietly working around it.
- Do not install to the user's live config to test. Use copies. The one time that rule was broken in this project's history, it left a broken hook pointing at a moved file.
