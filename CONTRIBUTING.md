# Contributing

For humans and for coding agents. If you are an agent working in this repo, read the whole file — the Verification section is not optional, and the Ground rules exist because this tool writes to files people depend on.

## What this repo is

Two shell scripts and some policy templates.

```
agent-guardrails.sh              entry point — rule lists, translation, writers, removers
hooks/git-push-guard.sh          the PreToolUse hook, shared by Claude and Codex
enterprise/                      drop-in policy files for admins (generated, see below)
.guardrails-protected            this repo's own branch exemption (!main)
```

`agent-guardrails.sh` holds the rule lists (`ALLOW`, `ASK`, `DENY`) as bash arrays near the top, a `to_agy` translator, three writers (`write_claude`, `write_codex`, `write_agy`) and three removers (`unwrite_*`) behind `--uninstall`. The guard is a standalone script that reads hook JSON on stdin and writes a decision to stdout.

`enterprise/claude-managed-settings.json` is **generated** — regenerate it with `./agent-guardrails.sh --print --managed | jq '.claude' > enterprise/claude-managed-settings.json` in the same PR as any rule change, or it silently drifts from the script.

The README quotes rule counts in **seven** places (the intro, the sample output block, three section headings, and two rows of the capability table). All of them must move together when you change the lists. `./agent-guardrails.sh --print | jq '{a:(.claude.permissions.allow|length),k:(.claude.permissions.ask|length),d:(.claude.permissions.deny|length),agy:(.agy.permissions.allow|length)}'` gives you the authoritative numbers.

## Ground rules

**This tool edits other people's config files.** Every writer must: back up to `<file>.bak` before touching anything, merge rather than replace, produce identical output on a second run, and never drop keys it doesn't recognize. If you change a writer, re-verify all four properties.

**Never widen the allowlist casually.** A rule earns `allow` only if it is local, reversible, doesn't publish anything outward, and doesn't escalate privilege. When unsure, `ask` is the right answer — prompt fatigue is a worse outcome than a data breach, but only slightly.

**Don't claim a capability you haven't verified in the binary.** The three harnesses differ in ways that are not documented anywhere. See below.

## Rule ordering — the thing that will bite you

Precedence is **deny > ask > allow**, and it does not consider specificity. Two consequences, one fatal and one useful:

**A broader `ask` silently kills a narrower `allow`.** `Bash(npx *)` in `ASK` swallows `Bash(npx playwright *)` in `ALLOW` — the allow rule becomes dead weight and nobody notices. This has been hit twice for real: `npx` vs `npx playwright`, and `ansible-playbook *` vs `ansible-playbook --check *`. The fix is never to rely on precedence: **do not create the overlap**. Leave the broad case unlisted instead — unlisted already prompts, so the safety outcome is identical with none of the shadowing.

**A narrower `ask` over a broader `allow` is the intended pattern**, and it works under any precedence model. This is how every infrastructure toolchain is built: allow `terraform *`, then ask `terraform apply *`. Same for `deny` over `ask` — `pveum *` asks, `pveum user delete *` denies.

Matching is **word-boundary aware**: `Bash(ansible *)` does not match `ansible-lint`, and `Bash(gh release delete *)` does not match `gh release delete-asset`. Both of those are load-bearing. Verify with this, which must print `clean` before you open a PR:

```bash
./agent-guardrails.sh --print > /tmp/p.json
python3 - <<'EOF'
import json,re
d=json.load(open('/tmp/p.json'))['claude']['permissions']
inner=lambda r:(re.match(r'^\w+\((.*)\)$',r) or [None,None])[1]
pfx=lambda r: r[:-1] if r.endswith('*') else r+' '   # keeps the word boundary
A=[inner(r) for r in d['allow'] if r.startswith('Bash(')]
K=[inner(r) for r in d['ask']   if r.startswith('Bash(')]
D=[inner(r) for r in d['deny']  if r.startswith('Bash(')]
bad=[(a,al) for a in K for al in A if al!=a and pfx(al).startswith(pfx(a))]
print("ask-shadows-allow:", bad if bad else "clean")
for x,y,nx,ny in (('allow','ask',A,K),('allow','deny',A,D),('ask','deny',K,D)):
    print(f"  dupes {x}/{y}: {set(nx)&set(ny) or 'none'}")
EOF
```

## Gates vs boundaries

Be honest in the README about which is which. A **boundary** cannot be crossed. A **gate** catches the common invocation and is defeated by a rewrite. Almost everything here is a gate:

- `Bash(curl * | sh)` — prefix matching is not a parser
- `psql`, `mysql`, `mongosh` — the destructive part lives inside the query string, which is why those clients sit in `ask` wholesale rather than being split by verb
- `officecli batch` — carries removals in its stdin payload, around the `remove` gate
- `npm run`, `npm install` postinstall — arbitrary execution from package.json
- `redis-cli flushall` denies are case-sensitive; redis commands are not

When you add a rule whose gate leaks, say so in **Honest limitations** rather than implying containment. An allowlist reduces prompt fatigue for trusted toolchains; it is not a sandbox, and the README must never suggest otherwise.

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

**Codex clamps a forbidden value, it does not reject it.** `/etc/codex/requirements.toml` pins `allowed_approval_policies` / `allowed_sandbox_modes`, and a config asking for something outside the set falls back to the *most restrictive allowed* value with a startup warning — `never` under `[untrusted, on-request, on-failure]` resolves to `UnlessTrusted`. The path is hardcoded; `CODEX_HOME/requirements.toml` is ignored (measured), so testing this needs root. `CODEX_REQUIREMENTS` overrides the path the installer *checks*, for tests only — it does not change what Codex reads.

The consequence shapes the design: writing a value that will be clamped is worse than writing nothing, because the writer comments the user's working value out first. Any future setting that an enterprise policy can pin must be checked before it is written, not after. Codex has no allowlist to fall back on the way Claude does.

**Project-local Codex config only loads for a trusted directory.** A `<project>/.codex/config.toml` is silently ignored unless the global config has `[projects."<path>"] trust_level = "trusted"`. The binary says so in its own trust prompt — *"Trusting the directory allows project-local config, hooks, and exec policies to load"* — and it measures out as a clean 2×2 (see the README). This is why `--project --permissive` writes a trust entry alongside the policy block. **Anything project-scoped you add for Codex inherits this**: a file that parses, applies nothing, and reports no error is the worst failure shape this repo can ship. Note also `Ignored unsupported project-local config keys in …` — project-local config honours only a subset of keys, so verify a new one actually resolves rather than assuming parity with the user-level file.

**agy** — has `permissions.allow` / `.ask` / `.deny` in `~/.gemini/antigravity-cli/settings.json`, with rule syntax `command(…)`, `read_file(…)`, `write_file(…)`, `unsandboxed(…)`. It has no `permissionDecision`, `hookSpecificOutput`, or `hookEventName` anywhere in the binary, so hooks cannot gate permissions. It has no per-project settings file; project scope adds to `trustedWorkspaces`.

**Claude Code** — the permissive one. Full `allow`/`ask`/`deny` from a `PreToolUse` hook via `hookSpecificOutput`, matcher `Bash`, `tool_input.command` is a string.

**Claude discards project-level rules in an untrusted workspace**, printing `Ignoring N permissions.allow entries from .claude/settings.json: this workspace has not been trusted`. Trust does not inherit from a parent directory, and `permissions.defaultMode` is *not* subject to it — only the rules are. Both harnesses therefore gate project-scoped config on trust (see the Codex note above), by different mechanisms and with different escape hatches. `--project` warns and stops there: writing `hasTrustDialogAccepted` into `~/.claude.json` would suppress a security prompt on the user's behalf. Do not "fix" the warning by making it automatic.

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

Strings tell you what a binary *contains*, not what it *does*. For anything about resolved configuration, measure it: `codex doctor --json` reports the policy Codex actually landed on, so point a scratch `CODEX_HOME` at a fixture and read it back.

```bash
export CODEX_HOME=/tmp/cxfix/home     # user-level config with known values
cd /tmp/cxfix/proj && codex doctor --json \
  | jq -r '.checks["sandbox.helpers"].details'
# -> {"approval policy":"Never","filesystem sandbox":"unrestricted", …}
```

Vary one thing at a time against a baseline you can see change — a probe that never fails is a probe that proves nothing. That is how the trust dependency above was found: the project-local file looked like it worked until the untrusted row was run. Note the limit: `doctor` shows what Codex resolves, not what a live authenticated session does with it.

### Testing what an agent will actually execute

Claude Code and agy have no `doctor`, so the only honest probe is a live session — measured by **side effect, not by prose**. Give the CLI a baseline config that explicitly denies a marker command, ask it to run that command in print mode, then test for the file. Present means the tool call executed; there is nothing to interpret and no dependence on the model's phrasing.

**Do not pass a bypass flag.** `--dangerously-skip-permissions` makes every condition pass and the test worthless. If something on your machine adds one behind your back — a shell alias, a wrapper script, a launcher config — call the binary by absolute path so it cannot apply.

> **agy has no per-project settings, so a live agy test *always* mutates the global file.** There is no scope you can point it at to stay clear. Snapshot `~/.gemini/antigravity-cli/settings.json` somewhere outside the test tree first and restore it in a `trap`. Do not rely on `<file>.bak` — the writers overwrite it, so two runs destroy the original. Setting `HOME` does not save you either: agy's OAuth token lives in that same directory, so an isolated `HOME` is an unauthenticated one.
>
> The failure this prevents is not a crash. Run the conditions in one batch and an earlier permissive install silently rewrites the global file *before* the later "baseline" runs, so the baseline is not a baseline — both conditions pass and the result looks like success. Hold workspace trust constant across conditions for the same reason.

Three confounds cost three runs when this was first done. All produce a plausible-looking "blocked", and none of them is a permission decision — so **always read what the agent actually said** before believing the marker:

- **Untrusted workspace.** Claude discarded every allow rule and said so. Trust the test directory explicitly (`projects["<path>"].hasTrustDialogAccepted` in `~/.claude.json`) — surgically, add-key/delete-key, because that file is live and your own session writes to it. A wholesale snapshot restore can clobber concurrent changes.
- **A `*` in the test directory name.** The Bash tool flagged it as a glob and refused before permissions were consulted. Keep fixture paths inert; do not name a directory after the rule it is testing.
- **A metadata preamble on the prompt.** If your harness prefixes prompts with anything that looks like role or system metadata, the agent may correctly refuse it as injected control content in a user turn — and then no tool call is attempted at all. Keep instrument-test prompts bare.

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

**5. Branch exemptions.** The guard reads `<repo>/.guardrails-protected` and `~/.claude/protected-branches.txt`; a leading `!` exempts a pattern and beats every protection rule. Confirm `!main` in a repo-local file flips `git push origin main` from deny to allow while `develop` and `release/*` stay denied, and that deleting the file restores the default.

Note that `CLAUDE_PROTECTED_BRANCHES` only works when set in the **agent process's own environment** — exported before launching the CLI, or via `env` in `settings.json`. An inline `CLAUDE_PROTECTED_BRANCHES=… git push` does nothing, because the harness spawns the hook separately and it never sees a prefix that applies only to the command being inspected. The README documented the inline form as working for one commit before this was caught. Do not reintroduce it.

**6. Uninstall round-trip.** Take a pristine config, install **twice**, then `--uninstall`, and diff against the pristine copy — it must come back set-identical, with hooks, model and theme intact. Array order will differ because install sorts via `unique`; compare with `jq -S '.permissions.allow|sort'`.

Uninstall subtracts from the same `ALLOW`/`ASK`/`DENY` arrays the writers use, so a rule you add is removed automatically with no extra work — but only if you add it to those arrays rather than hard-coding it in a writer. Do not hard-code rules in writers. Also confirm `--uninstall` is a clean no-op on a config that never had it installed.

**7. Permissive round-trips.** `--permissive` is the one path that does not merge, so it needs its own passes. Against a seeded config that has a top-level `approval_policy`, a `[projects."…"]` table with an `approval_policy` **inside** it, a foreign `PreToolUse` hook, and rules of the user's own:

```bash
./agent-guardrails.sh --project /tmp/sb --permissive --yes   # x3, must be idempotent
./agent-guardrails.sh --project /tmp/sb --uninstall          # back to pristine
./agent-guardrails.sh --project /tmp/sb --permissive --yes
./agent-guardrails.sh --project /tmp/sb                      # normal install over permissive
```

Confirm: the `config.toml` block does not stack and no blank line accumulates per run; the displaced top-level key comes back with its original value on uninstall while the one **inside the table** was never touched; the foreign hook survives all of it; and after the normal install there is no `defaultMode`, no `Bash(*)`, no policy block, and no `[projects."<path>"]` trust entry left. That last one matters most — rules under a bypass switch are rules that do nothing.

Two invariants the permissive path depends on. `TRUST_BEGIN` must **not** start with `TOML_BEGIN`, or reinstalling the policy block sweeps away trust blocks other projects put in the same global config. And `toml_filter`'s restore flag must be `0` whenever the policy block is staying put — un-commenting a displaced `approval_policy` while ours is still in the file produces a duplicate key, which is a TOML parse error, which is a Codex that will not start.

## Adding rules

Edit the `ALLOW` / `ASK` / `DENY` arrays. Keep them grouped by toolchain with the existing comment headers, and keep entries alphabetical within a group where it doesn't fight the grouping.

Claude syntax is the source of truth; `to_agy` translates. If you add a rule form `to_agy` doesn't handle (anything that isn't `Bash(…)` or `Read(…)`), extend the translator in the same PR — a silently-dropped rule is worse than a missing one.

### Removing or replacing a rule — move it to `RETIRED`

`--uninstall` subtracts the rules the *current* version knows about. So if you delete an entry from `ALLOW`/`ASK`/`DENY` — most often by replacing several narrow rules with one broad one — anyone who installed the older version keeps those rules **forever**: their config has them, and no future uninstall knows to look for them.

This is not hypothetical. `Bash(go build *)`, `Bash(go test *)` and `Bash(go vet *)` shipped in v1, were superseded by `Bash(go *)`, and survived a full uninstall on a real machine.

So: **when you remove or replace an entry, move its exact old text into the `RETIRED` array.** Both removers subtract `RETIRED` in addition to the live lists. Never delete anything from `RETIRED` — it only grows, and it is the only record that a rule was ever shipped.

The same reasoning covers `PERMIT_ALLOW` / `PERMIT_AGY`: if you change a catch-all, the old text has to go into `RETIRED` too, or a config that went permissive under the old version keeps a `Bash(…)` wildcard through every future install.

### Classifying a new toolchain

Ask where the damage lands, then pick the shape:

| the tool | shape |
|---|---|
| local, reversible, no network (`pytest`, `gcc`, `sqlite3`) | allow broadly |
| dangerous verb is the **first token** (`terraform`, `kubectl`, `qm`) | allow broadly, then `ask` the specific verbs |
| dangerous part is **inside an argument** (`psql`, `mongosh`) | `ask` wholesale — a verb split is not possible |
| publishes an artifact or mutates credentials (`npm publish`, `gh secret`, `docker push`) | `deny` — an agent should not be able to do this at all |
| fetches and executes remote code (`npx`, `gh extension install`, `cargo install`) | `ask` |

Two hard rules. **Do not add `Bash(git push *)` to `ALLOW`** — that defeats the guard, which is the entire point of the project. And **do not add a bare shell** (`Bash(bash *)`, `Bash(sh *)`): `bash -c '<anything>'` makes every other rule in the file meaningless. Both of those live in `PERMIT_ALLOW` by way of `Bash(*)`, which is exactly why `--permissive` is a separate mode with a confirmation rather than a looser default.

When you add a toolchain, update the README's allow/ask/deny tables and all seven rule counts, regenerate `enterprise/claude-managed-settings.json`, and run the shadow checker.

## Style

POSIX-ish bash, `set -euo pipefail`, 2-space indent. Quote every expansion — an unquoted `$(…)` word-split multi-word rules into garbage once already. Prefer `jq` for all JSON manipulation; never hand-roll JSON with string concatenation. Comments explain *why* a rule is where it is, not what the line does.

## For agents specifically

- Read `agent-guardrails.sh` end to end before editing it. The writers look similar and are not interchangeable.
- Run the full verification above and paste real output in the PR. Do not assert that tests pass without showing them.
- If you find a genuine limitation, write it into README's **Honest limitations** section rather than quietly working around it.
- Do not install to the user's live config to test. Use copies. The one time that rule was broken in this project's history, it left a broken hook pointing at a moved file.
