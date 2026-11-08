# Agent Guardrails — agent-guided install

You are an AI coding agent installing **Agent Guardrails**. Follow these steps
exactly. This procedure is merge-aware: it never blindly overwrites files the
user already owns, and it reports every collision before anything changes.

Agent Guardrails configures the permission gates of exactly five agent CLIs —
**Claude Code**, **Codex**, **agy** (Antigravity CLI), **Gemini CLI**, and
**Cline**. It offers three install modes, from no gate at all to a scoped
allowlist with a git-push branch guard. **Fully permissive is the default**; the
user picks in step 2.

This document is the agent-guided install path. It **complements, and does not
replace**, the installer script `agent-guardrails.sh`. The script owns all the
writes — it backs up every file to `<file>.bak` before touching it, and it is
idempotent: running it twice changes nothing. Your job is to offer the choices,
survey before writing, run the script, and report afterward. **Do not hand-edit
the harness config files yourself** — a manual edit would diverge from the
script's dedup and uninstall logic and could leave a gate silently inert.

Source repository: `https://github.com/jpbaking/agent-guardrails`. If the user
named a fork or tag, substitute it below.

Requires `bash`, `git`, and `jq` (the guard hook also calls `jq` at runtime).

## 1. Acquire the sources

Obtain the sources in a temporary directory (never inside a project):

- `git clone --depth 1 https://github.com/jpbaking/agent-guardrails <tmp>/agent-guardrails`
  (add `--branch <tag>` for a pinned tag), or
- download and extract `https://github.com/jpbaking/agent-guardrails/archive/refs/heads/main.zip`, or
- `gh repo clone jpbaking/agent-guardrails <tmp>/agent-guardrails`.

Or use the checkout the user already has. From then on, refer to it as
`<guardrails>`. Confirm `jq` is installed first — the script exits with an error
if it is not:

```bash
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
```

## 2. Offer the options

If the user's request already names a mode and scope ("install it permissive,
globally", "just the allowlist for this repo"), use those and skip to step 3.
Otherwise, show them this menu — adapt the wording, keep the content — and wait
for an answer:

```
How should Agent Guardrails be set up?

  Mode
  1. Fully permissive  (default)
     No prompts and no push guard in any CLI — the bypass / YOLO flags,
     written into config so you never pass them. Clears ask/deny rules,
     including any you wrote yourself.
  2. Guarded allowlist
     ~495 everyday commands auto-approved, ~272 risky ones prompt, ~76 blocked,
     plus a push guard that asks before pushing to main, develop, release/*, ….
  3. Allowlist only
     Same rules as 2, no push guard (removes one if already installed).
  4. Preview only
     Print what would be written, change nothing.

  Scope
  a. Global — every project on this machine  (default)
  b. Project — one directory: <path>

Reply with a mode and scope (e.g. "1a"), or just "go" for the defaults: 1a.
```

| choice | command |
|---|---|
| 1a | `<guardrails>/agent-guardrails.sh --global --permissive` |
| 1b | `<guardrails>/agent-guardrails.sh --project <path> --permissive` |
| 2a | `<guardrails>/agent-guardrails.sh --global` |
| 2b | `<guardrails>/agent-guardrails.sh --project <path>` |
| 3a | `<guardrails>/agent-guardrails.sh --global --no-hook` |
| 3b | `<guardrails>/agent-guardrails.sh --project <path> --no-hook` |
| 4 | `<guardrails>/agent-guardrails.sh --print` — add `--permissive` to preview mode 1 |

Things to know when the user asks, or picks something that has a catch:

- **There is no per-CLI selection.** The script configures every supported CLI it
  finds (Gemini CLI and Cline are skipped when not installed; agy when it has no
  settings file yet). If the user wants to leave one out, say so plainly before
  running — do not hand-edit around it.
- **No other harness is supported** (pi, Cursor, OpenCode, …). If the user asks
  for one, say so rather than improvising a config for it.
- **Mode 1 is the opposite of a guardrail**, by design: it is meant for a
  container, a VM, or a machine where the user has decided speed beats a prompt.
  State that once, plainly, and accept the user's choice — do not argue it.
- **Admins can pin policy.** For an enterprise rollout, `--print --managed`
  prints the policy files for their platform team instead (see the README, "For
  your admins"). It cannot be combined with `--permissive`.

## 3. Survey before writing

Read every config read-only and report what the chosen mode will change. Never
delete an unrelated or legacy entry, and do not infer consent from a config
directory existing — a present `~/.claude` means the user has used Claude, not
that they agreed to this.

Where each CLI keeps what the script touches:

- **Claude Code** — `~/.claude/settings.json` (or `<proj>/.claude/settings.json`):
  `permissions.allow/ask/deny`, `permissions.defaultMode`, `hooks.PreToolUse`.
- **Codex** — `~/.codex/hooks.json` and `~/.codex/config.toml` (or the project's
  `.codex/`); for project scope, also the `[projects.*]` trust entries in the
  global `~/.codex/config.toml`.
- **agy** — `~/.gemini/antigravity-cli/settings.json`: `permissions.allow/ask/deny`
  and `trustedWorkspaces`. It has no per-project file, so project scope edits this
  global one.
- **Gemini CLI** — `~/.gemini/settings.json` (or `<proj>/.gemini/settings.json`):
  `hooks.BeforeTool` and `hooksConfig.enabled`; plus `~/.gemini/policies/`, where
  any other `*.toml` the user has may outrank or overlap ours.
- **Cline** — `~/.cline/hooks/` (or `<proj>/.cline/hooks/`): any existing
  `PreToolUse.<ext>`. A `PreToolUse.sh` that is not ours blocks the install there;
  other extensions coexist, since Cline runs them all.

### If mode 1 (fully permissive)

Permissive does **not** merge: it empties `ask` and `deny` outright. So the one
thing to find is rules the user wrote themselves, which are about to be lost.
This lists them — anything printed is theirs, not ours:

```bash
P=$(<guardrails>/agent-guardrails.sh --print)
jq -n --argjson p "$P" --slurpfile c ~/.claude/settings.json \
  '$p.claude.permissions as $o | $c[0].permissions // {} as $m
   | {ask: (($m.ask // []) - $o.ask), deny: (($m.deny // []) - $o.deny)}'
jq -n --argjson p "$P" --slurpfile c ~/.gemini/antigravity-cli/settings.json \
  '$p.agy.permissions as $o | $c[0].permissions // {} as $m
   | {ask: (($m.ask // []) - $o.ask), deny: (($m.deny // []) - $o.deny)}'
```

(For project scope, point the Claude line at `<proj>/.claude/settings.json`.)
If the user has rules of their own there, list them and confirm before going on —
`<file>.bak` is single-level and overwritten on the next run, so offer to copy the
file somewhere safe first. Also report:

- **Codex** — any top-level `approval_policy` / `sandbox_mode` in `config.toml`.
  They are commented out, not deleted, and uninstall restores them. If
  `/etc/codex/requirements.toml` forbids `never` or `danger-full-access`, the
  script **skips Codex** and leaves its guard in place, because Codex would clamp
  the values to something stricter than the user has now.
- **Gemini CLI** — permissive is **global only**. Gemini does not load project
  policies, so at project scope the script only removes the guard; for one
  permissive project the user passes `--yolo` to `gemini` themselves. Even
  globally, Gemini's "ask the user a question" tool still asks, and Gemini still
  asks in a few cases it flags itself.
- **Claude, project scope** — the allow-everything rules are ignored until the
  workspace is trusted, but `defaultMode: bypassPermissions` applies regardless.
- **Codex, project scope** — the script also writes a `trust_level = "trusted"`
  entry for the path into the *global* `~/.codex/config.toml`, because Codex
  ignores a project's `.codex/config.toml` otherwise. Uninstall removes it.

### If mode 2 or 3 (allowlist)

Report anything the rules would shadow, displace, or duplicate, and these:

- **Claude ignores project rules in an untrusted workspace.** A `--project`
  install writes to `<proj>/.claude/settings.json`, but Claude discards those
  rules until the user accepts the trust dialog there. Tell them to run `claude`
  once in the project and accept it. Do **not** write `hasTrustDialogAccepted`
  into `~/.claude.json` for them — suppressing a security prompt on their behalf
  is not something an installer should do quietly.
- **Gemini gets no rules at project scope** — its workspace policy tier does not
  work. `--project` installs only the guard (mode 2) into
  `<proj>/.gemini/settings.json`, and Gemini skips that file in an untrusted
  folder. The rules need `--global`.
- **Codex and Cline get no rules in any mode** — neither has a per-command
  allowlist. In mode 2 they get the guard only; in mode 3, nothing.
- **What the guard does per CLI (mode 2).** A protected-branch push *asks* on
  Claude and Gemini but is *blocked* on Codex and Cline, which cannot ask; on
  Cline a block ends the whole run. agy gets no guard. `git push --all` /
  `--mirror` are blocked everywhere.
- **A previous permissive install is undone automatically.** Installing mode 2 or
  3 over mode 1 strips `bypassPermissions`, the allow-everything rules, the Codex
  policy block and trust entry, and Gemini's allow-everything policy before
  writing the real rules — rules under a bypass switch would do nothing.

Report the findings to the user **before** writing, and let them confirm or
change the mode or scope.

## 4. Install

Run the command for the chosen mode and scope from the table in step 2. If unsure,
run the same command with `--print` in place of `--global`/`--project` first — it
changes nothing.

Mode 1 prints a warning and waits for the user to type `yes`, and it refuses to
run non-interactively without `--yes`. You are usually not on an interactive
terminal, so: show the user the warning summary, get their explicit go-ahead in
the conversation, and only then re-run with `--yes`. Never add `--yes` on your own
initiative.

The push guard (mode 2) is a shared script installed to a stable path outside the
checkout, so the configs keep working after the checkout is deleted:

```
$AGENT_GUARDRAILS_DIR/git-push-guard.sh     # default: ~/.agents/hooks/
```

## 5. Validate and report

1. **Confirm each CLI picked up what was written.** Read the configs back:

   | | mode 1 | mode 2 | mode 3 |
   |---|---|---|---|
   | Claude | `defaultMode: bypassPermissions`, `Bash(*)` etc. in allow, ask/deny `[]`, no `git-push-guard` hook | rules in allow/ask/deny, guard in `hooks.PreToolUse` | rules, no guard |
   | Codex | `config.toml` block with `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`, no guard in `hooks.json` | guard (`--deny-only`) in `hooks.json`, `[features] hooks = true` | no guard |
   | agy | `command(*)`, `read_file(*)`, `write_file(*)` in allow, ask/deny `[]` | rules | rules |
   | Gemini | `policies/agent-guardrails.toml` allows `"*"`, no guard (global) | policy file with rules (global), guard in `hooks.BeforeTool` | policy file, no guard |
   | Cline | no `PreToolUse.sh` of ours | `PreToolUse.sh` present | none of ours |

   Every JSON file must still parse (`jq -e .`), and `config.toml` too
   (`python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' <file>`).
2. **Spot-check, if convenient.** In mode 2 or 3, a routine `git status` should no
   longer prompt. This catches a silent no-op faster than reading JSON.
3. **Report** every file created or changed and where its `<file>.bak` is, plus
   any CLI that was skipped and any warning from step 3 — especially Claude's
   workspace trust on a project install, and Codex being skipped under an admin
   policy in mode 1.
4. **Tell the user:**
   - **Restart running sessions.** Claude Code does not reload hooks mid-session
     (opening `/hooks` reloads them); the other CLIs read config at startup.
   - **How to undo or switch.** `<guardrails>/agent-guardrails.sh --global
     --uninstall` (or `--project <path> --uninstall`) subtracts exactly what the
     script added, in any mode — including restoring Codex keys that permissive
     mode commented out. To switch modes, just run the other mode's command; no
     uninstall needed in between. The guard script itself is left in place, with
     the `rm` command printed.
   - In modes 2 and 3: rules are prefix globs, and an allowlist is **not** a
     sandbox — containment still needs a devcontainer or the CLI's sandbox mode.
