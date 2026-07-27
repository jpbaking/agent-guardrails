# agent-guardrails

**Your company blocked `--dangerously-skip-permissions`. Good. Here's how to get your speed back anyway.**

Coding agents are fast right up until they aren't. Every `npm test`, every `git diff`, every `pytest -k foo` stops and waits for you to click yes. So people reach for the bypass flag — and enterprise admins, reasonably, turn it off.

`agent-guardrails` is the middle path: a scoped allowlist that auto-approves the ~200 commands you actually run all day, keeps a prompt on the ones that reach off your machine, and hard-blocks the ones nobody should run unattended. Plus a hook that refuses to push to `main`.

One command, all three agent CLIs:

```bash
./agent-guardrails.sh --global
```

```
scope: global (user-level)
  guard   installed -> ~/.agents/hooks/git-push-guard.sh
  claude  ~/.claude/settings.json  (+guard)
  codex   ~/.codex/hooks.json  (guard only, deny-only mode)
  agy     ~/.gemini/antigravity-cli/settings.json
allow=203 ask=32 deny=37
```

---

## Why not just ask for bypass mode?

Because you won't get it, and you shouldn't. Bypass mode is all-or-nothing: it turns off the check on `npm test` *and* the check on `curl … | sh`. No security team is going to sign that.

An allowlist is a different conversation. It's specific, it's reviewable, and it's the thing managed settings were built for. `--print` gives you a JSON fragment you can attach to a ticket, and `enterprise/` gives your admins drop-in policy files. That request gets approved.

## What you get

**Auto-approved (203 rules)**

| | |
|---|---|
| git | inspection and local mutation — `status`, `diff`, `log`, `add`, `commit`, `stash`, `fetch`, `merge` |
| jvm | `gradle`/`./gradlew`, `mvn`/`./mvnw` |
| node | `npm`, `yarn`, `pnpm`, `bun`, `tsc`, `eslint`, `prettier`, `jest`, `vitest` |
| python | `python`, `pytest`, `ruff`, `black`, `mypy`, `pip`, `venv`, `poetry`, `uv` |
| rust | `cargo` build/test/check/run/clippy/fmt/doc/add/bench/nextest/audit, `rustc`, `rustfmt`, read-only `rustup` |
| c/c++ | `gcc`, `g++`, `clang`, `ninja`, `ctest`, `meson`, `./configure`, `clang-format`, `clang-tidy`, `cppcheck`, `gdb`, `lldb`, `valgrind`, binutils |
| gh | read-only only — `pr view`/`list`/`diff`/`checks`, `issue view`/`list`, `run view`/`watch`, `repo view`, `search` |
| playwright | `playwright`, `npx playwright`, `pnpm exec playwright`, `python -m playwright` |
| shell | `shellcheck`, `shfmt`, and the no-op syntax check `bash -n` |
| misc | `make`, `cmake`, `just`, `go`, and read-only shell (`ls`, `cat`, `grep`, `rg`, `jq`, …) |

**Still prompts (32 rules)** — `bash -c` / `sh -c` / `eval`, because they are arbitrary execution. Everything in `gh` that writes to GitHub (`pr create`, `pr merge`, `issue create`, `gh api`, `workflow run`). `cargo install` and `rustup install`/`update`, which fetch and run code. `docker`/`kubectl`/`terraform`/cloud CLIs, `ssh`/`scp`/`rsync`, and the git commands that destroy work git can't recover (`reset --hard`, `clean`, `rebase`).

Anything not in any list also prompts — that's the default. `npx` is the notable one: only `npx playwright` is allowlisted, so every other `npx` invocation prompts without needing an explicit rule.

**Blocked outright (37 rules)** — `sudo`, `rm -rf /`, every publish path (`npm publish`, `mvn deploy`, `twine upload`, `cargo publish`/`login`/`owner`/`yank`, `gh release create`), credential mutation (`gh secret`, `gh auth token`, `gh ssh-key add`), `gh repo delete`, and reads of `~/.ssh`, `~/.aws/credentials`, `.env.production`.

**A push guard** that reads the branch you're actually on:

| you run | it does |
|---|---|
| `git push` on `feature/login` | **allow** |
| `git push origin main` | **deny** |
| `git push origin HEAD:release/2.1` | **deny** — glob `release/*` |
| `git push --force origin feature/login` | **ask** |
| `git push --all origin` | **deny** — sweeps protected refs |
| `git push origin :main` | **deny** — remote branch delete |
| `git add -A && git commit -m wip && git push` | **allow** — splits on `&&` |

Protected by default: `main`, `master`, `develop`, `development`, `trunk`, `staging`, `stage`, `prod`, `production`, `release/*`, `hotfix/*`, plus whatever `origin/HEAD` actually points at. Override with `CLAUDE_PROTECTED_BRANCHES` or `~/.claude/protected-branches.txt`.

This is why `git push` is deliberately **not** in the allowlist. Permission rules are prefix globs — they can't see which branch you're on. Only a hook can.

## Install

Requires `bash`, `git`, and `jq`.

```bash
git clone https://github.com/jpbaking/agent-guardrails
cd agent-guardrails
./agent-guardrails.sh --global
```

The guard is copied to `~/.agents/hooks/` so the absolute path written into your configs survives deleting the checkout. Set `AGENT_GUARDRAILS_DIR` to put it elsewhere.

```bash
./agent-guardrails.sh --global          # user-level, every harness
./agent-guardrails.sh --project         # this repo only
./agent-guardrails.sh --project ~/work/api
./agent-guardrails.sh --print           # show the JSON, touch nothing
./agent-guardrails.sh --global --no-hook  # rules only, skip the guard
```

Every write is additive, de-duplicated, idempotent, and backed up to `<file>.bak` first. Your existing rules, hooks, model, and theme survive. Run it twice and nothing changes.

**Claude Code won't pick the hook up mid-session** — open `/hooks` once to reload, or start a new session.

## The three harnesses are not equal

This is the part other tools gloss over. Each CLI's capabilities were determined by reading its binary, not by guessing:

| | allowlist | push guard | verified against |
|---|---|---|---|
| **Claude Code** | 203 rules, `Bash(git commit *)` | full — allow, ask, and deny | `2.1.220` |
| **Codex** | **none** — no allowlist mechanism exists | **deny only** | `0.145.0` |
| **agy** | 198 rules, `command(git commit)` | **none** | `1.1.7` |

> **Last verified: 2026-07-28.** These CLIs ship fast — agy moved from `1.1.6` to `1.1.7` during a single afternoon of writing this. If the date above is old, treat the table as a starting point rather than fact.

**Codex** has no per-command allowlist at all. Its gating is `approval_policy` × `sandbox_mode` × `[projects.*] trust_level`. And its hook engine rejects anything but a denial — the binary literally carries the string `PreToolUse hook returned unsupported permissionDecision:allow`. So Codex gets the guard in `--deny-only` mode and no rules. That composes well: if your Codex is already on a trusted project with full access, the guard carves protected branches back out.

**agy** has the allowlist (its own syntax: `command(…)`, `read_file(…)`, `write_file(…)`) but no `permissionDecision` protocol in its hooks, so the guard can't run there. Worth knowing: agy asks on `command(*)` by default — *every* shell command — so the allowlist is the whole win there.

These are reverse-engineered constraints, not documented API. [CONTRIBUTING.md](CONTRIBUTING.md) has the exact commands to re-verify them against a new release — please update the table and its date in the same PR.

## For your admins

`enterprise/` holds policy files your platform team can deploy, so the rules are pinned centrally and users can't loosen them:

- `claude-managed-settings.json` → `/etc/claude-code/managed-settings.json`, with `allowManagedPermissionRulesOnly: true` so policy is the only source of permission rules
- `codex-managed-config.toml` → `/etc/codex/managed_config.toml`
- `codex-requirements.toml` → `/etc/codex/requirements.toml`, pinning `allowed_approval_policies` and `allowed_sandbox_modes`

`./agent-guardrails.sh --print --managed` prints the same content for pasting into a ticket.

## Honest limitations

- **`deny` rules on pipes are decorative.** `Bash(curl * | sh)` cannot reliably catch pipe-to-shell — prefix matching isn't a parser, and a rewritten command sidesteps it. Those entries document intent; they are not enforcement.
- **An allowlist is not a sandbox.** `Bash(python *)` allows `python -c 'anything'`, and `Bash(gcc *)` will happily compile and link whatever it is pointed at. This tool reduces prompt fatigue for trusted toolchains; it is not a containment boundary. If you need containment, use a devcontainer or your harness's sandbox mode.
- **Bare `bash` and `sh` are deliberately not allowlisted.** `bash -c '<anything>'` would make every other rule here meaningless, so only `shellcheck`, `shfmt`, and the no-op `bash -n` are allowed; `bash -c` is in the ask list. If you allowlist `Bash(bash *)` yourself, understand that you have effectively turned the allowlist off.
- **An `ask` rule shadows a more specific `allow` rule.** `Bash(npx *)` in ask would swallow `Bash(npx playwright *)` in allow. The rule lists are written to avoid overlaps entirely rather than depend on precedence; keep it that way when adding rules.
- **agy's prefix semantics are inferred**, from built-ins like `command(npm test)` and `command(tail -F)`. If agy turns out to match exactly rather than by prefix, most of its 198 rules are inert. Verify before relying on it.
- **A denied push rejects the whole command.** The guard scans every segment of a compound command, so `make test && git push origin main` is denied in its entirety — the build does not run first. This is deliberate (a guard should fail closed), but it surprises people who expect only the push to be blocked. Run the work and the push as separate commands.
- **Bypass mode skips the rules.** If you run with `--dangerously-skip-permissions` anyway, allow/ask/deny are ignored wholesale — only the hook still fires.

### Overriding the guard

It is a guard, not a wall — you own it. For a repo where `main` genuinely *is* the working branch (a solo project, say), drop a `.guardrails-protected` file in the repo root:

```
# exempt this repo's main — solo project, no PR flow
!main
```

A leading `!` exempts a pattern; anything else adds one. The same syntax works globally in `~/.claude/protected-branches.txt`. One glob per line, `#` for comments.

**`CLAUDE_PROTECTED_BRANCHES` replaces the default list**, but it must be set in the environment of the agent process — exported before you launch the CLI, or via the `env` block in `settings.json`. An inline `CLAUDE_PROTECTED_BRANCHES=… git push` does **not** work: the hook is spawned as a separate process by the harness and never sees a prefix that applies only to the command it is inspecting. Use the per-repo file for one-off overrides.

## License

[0BSD](LICENSE). Public domain in practice: use it, ship it, sell it, no attribution required.
