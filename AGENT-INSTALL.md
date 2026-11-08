# Agent Guardrails — agent-guided install

You are an AI coding agent installing **Agent Guardrails**. Follow these steps
exactly. This procedure is merge-aware: it never blindly overwrites files the
user already owns, and it reports every collision before anything changes.

Agent Guardrails is a scoped permission allowlist for exactly five agent CLIs —
**Claude Code**, **Codex**, **agy** (Antigravity CLI), **Gemini CLI**, and
**Cline** — plus a git-push branch guard that asks before any push to a protected branch (`main`,
`develop`, `release/*`, …). It is the middle path between "ask yes on every
command" and the all-or-nothing bypass flag that enterprise admins block:

- **allow** (~495 rules) — safe local work, run unattended (git, gradle, npm,
  pytest, cargo, gcc, go, …).
- **ask** (~272 rules) — allowed but always confirmed (reaches off-machine,
  escalates privileges, or destroys uncommitted work).
- **deny** (~76 rules) — blocked outright (`sudo`, `rm -rf /`, every publish
  path, credential mutation, `git push --all`/`--mirror`, …). Pushes to
  protected branches ask instead — or are blocked on Codex and Cline, which
  cannot ask.

This document is the agent-guided install path. It **complements, and does not
replace**, the installer script `agent-guardrails.sh`. The script owns all the
writes — it is idempotent, additive, de-duplicated, and backs up every file to
`<file>.bak` before touching it. Your job is to survey before writing, choose the
scope correctly, and report afterward. **Do not hand-edit the harness config
files yourself** — a manual edit would diverge from the script's dedup and
uninstall logic and could leave a gate silently inert.

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

## 2. Survey before writing

1. **Confirm which harnesses to support.** Ask the user whether to install for
   Claude Code, Codex, agy, Gemini CLI, Cline (or any subset). Do **not** infer
   consent from detected configuration directories — a present `~/.claude` folder
   means the user has used Claude, not that they want its permissions changed.
   No other harness is supported (pi, Cursor, OpenCode, …); if the user asks for
   one, say so rather than improvising a config for it.

2. **Locate each harness's config and check for collisions.** Read them read-only;
   report anything that would be shadowed, displaced, or duplicated — never delete
   an unrelated or legacy entry:
   - **Claude Code** — `~/.claude/settings.json`: `permissions.allow/ask/deny` and
     `hooks.PreToolUse`.
   - **Codex** — `<proj>/.codex/hooks.json`, the project's `config.toml`, and (for
     project scope) the global `~/.codex/config.toml` `[projects.*]` trust entries.
   - **agy** — `~/.gemini/antigravity-cli/settings.json`: `permissions.allow/ask/deny`
     and `trustedWorkspaces`.
   - **Gemini CLI** — `~/.gemini/settings.json` (or `<proj>/.gemini/settings.json`):
     `hooks.BeforeTool` and `hooksConfig.enabled`; plus `~/.gemini/policies/`, where
     any other `*.toml` the user has may outrank or overlap ours.
   - **Cline** — `~/.cline/hooks/` (or `<proj>/.cline/hooks/`): any existing
     `PreToolUse.<ext>` file. A `PreToolUse.sh` that is not ours blocks the install
     there; other extensions coexist, since Cline runs them all.

3. **Note harness-specific gotchas that affect the outcome:**
   - **Claude ignores project rules in an untrusted workspace.** A `--project`
     install writes to `<proj>/.claude/settings.json`, but Claude discards those
     entries until the user accepts the trust dialog for that workspace. Global
     scope is unaffected. If you are doing a project install on Claude, warn the
     user and tell them to run `claude` once in the project and accept the prompt.
     Do **not** write `hasTrustDialogAccepted` into `~/.claude.json` for them —
     suppressing a security prompt on their behalf is not something an installer
     should do quietly.
   - **agy has no per-project settings file.** A project install adds the path to
     `trustedWorkspaces` in agy's *global* settings instead of creating a local one.
   - **agy may not have a config yet.** If `~/.gemini/antigravity-cli/settings.json`
     does not exist (the user has not run agy once), the installer skips it — note
     this rather than treating it as an error. Gemini CLI and Cline are likewise
     skipped when they are not installed.
   - **Gemini gets no rules at project scope.** Its workspace policy tier is
     documented as non-functional, so `--project` installs only the guard into
     `<proj>/.gemini/settings.json` — and Gemini skips that file in an untrusted
     folder. The rules need `--global`.
   - **On Cline the guard is the only gate.** Cline auto-approves every tool by
     default and has no command allowlist; a guard deny ends the whole run.

4. Report the collisions and gotchas above to the user **before** writing, and let
   them confirm or adjust the scope.

## 3. Install

Preview first without touching anything:

```bash
<guardrails>/agent-guardrails.sh --print          # show the JSON, change nothing
```

Then run the installer with the chosen scope. Every write is additive and
idempotent — running it twice changes nothing — and each file is backed up to
`<file>.bak` first:

```bash
<guardrails>/agent-guardrails.sh --global          # user-level, every harness present
<guardrails>/agent-guardrails.sh --project [PATH]  # this repo/workspace only
```

Pick the scope with the user. `--global` targets every harness whose config
exists; `--project` scopes to one workspace (subject to the Claude trust caveat
above). The installer handles the per-harness differences automatically:

- **Claude Code** gets the full allowlist plus the push guard in
  `hooks.PreToolUse`.
- **Codex** has no per-command allowlist, so it gets **only the guard**, installed
  in `--deny-only` mode (its hook engine rejects any non-deny decision), and the
  installer adds `[features] hooks = true` to its `config.toml` if missing.
- **agy** gets the rules translated into its own syntax but **no guard** (its
  hooks have no permission-decision protocol).
- **Gemini CLI** gets the rules as `~/.gemini/policies/agent-guardrails.toml`
  (global only) and the guard as a `BeforeTool` hook that can deny and ask.
- **Cline** gets **only the guard**, deny-only, as `PreToolUse.sh` in its hooks
  directory.

The push guard is a shared script installed to a stable path outside the repo so
the absolute path written into the configs keeps working even after the checkout
is deleted:

```
$AGENT_GUARDRAILS_DIR/git-push-guard.sh     # default: ~/.agents/hooks/
```

Override the destination with `AGENT_GUARDRAILS_DIR` if you want it elsewhere. If
the user wants only the allowlist and no branch guard, pass `--no-hook`.

## 4. Validate and report

1. **Confirm each harness picked up what was written.** Re-run `--print` and check
   the JSON: Claude's `permissions.allow/ask/deny` and `hooks.PreToolUse` carry the
   guard; Codex's `hooks.json` carries the deny-only guard and its `config.toml` has
   `[features] hooks = true`; agy's `permissions.allow/ask/deny` are populated;
   Gemini's `settings.json` has the guard under `hooks.BeforeTool` and (global)
   its policy file exists; Cline's hooks directory has `PreToolUse.sh`.
2. **Spot-check a routine command** (e.g. `git status`) actually no longer prompts,
   if convenient — this is optional but catches a silent no-op faster than reading
   JSON.
3. **Report** every file created or changed and the location of its `<file>.bak`
   (the `.bak` files show exactly what was displaced). Repeat any collisions or
   warnings from step 2, especially:
   - the Claude workspace-trust warning on a project install, and
   - any harness that was skipped because it had no config yet.
4. **Tell the user:**
   - how to uninstall cleanly — `<guardrails>/agent-guardrails.sh --global --uninstall`
     (it subtracts exactly what it added; the guard script itself is left in place,
     with the `rm` command printed for them);
   - that rules are prefix globs and an allowlist is **not** a sandbox — containment
     still needs a devcontainer or the harness's sandbox mode.

## Optional: fully permissive mode (opt-in only)

On explicit user request, and only in a container or VM you can throw away.
`--permissive` is the inverse of everything else here — it **removes** the gate
rather than scoping it (`allow = *`, `ask`/`deny` cleared, guard removed, Codex set
to `approval_policy = never` + `sandbox_mode = danger-full-access`). It prints what
it will do and waits for the user to type `yes`; `-y/--yes` skips that, and it
refuses to run non-interactively without it.

```bash
<guardrails>/agent-guardrails.sh --global --permissive      # every harness on the machine
<guardrails>/agent-guardrails.sh --project . --permissive   # one workspace
```

Do not combine `--permissive` with `--managed` — they are contradictory (one pins
policy centrally, the other strips it). If your admins have already disabled Codex's
full access via `/etc/codex/requirements.toml`, the installer skips Codex rather than
writing a value that would be clamped back. For the full behaviour and uninstall-over-
permissive path, see the README — do not restate it here.