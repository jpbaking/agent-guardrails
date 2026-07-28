# agent-guardrails

**Your company blocked `--dangerously-skip-permissions`. Good. Here's how to get your speed back anyway.**

Coding agents are fast right up until they aren't. Every `npm test`, every `git diff`, every `pytest -k foo` stops and waits for you to click yes. So people reach for the bypass flag — and enterprise admins, reasonably, turn it off.

`agent-guardrails` is the middle path: a scoped allowlist that auto-approves the ~495 commands you actually run all day, keeps a prompt on the ones that reach off your machine, and hard-blocks the ones nobody should run unattended. Plus a hook that refuses to push to `main`.

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
allow=495 ask=272 deny=76
```

---

## Why not just ask for bypass mode?

Because you won't get it, and you shouldn't. Bypass mode is all-or-nothing: it turns off the check on `npm test` *and* the check on `curl … | sh`. No security team is going to sign that.

An allowlist is a different conversation. It's specific, it's reviewable, and it's the thing managed settings were built for. `--print` gives you a JSON fragment you can attach to a ticket, and `enterprise/` gives your admins drop-in policy files. That request gets approved.

If you *do* want bypass anyway — on a throwaway VM, in a container, on a machine where nothing matters — [`--permissive`](#fully-permissive-mode) writes it into your configs for all three CLIs so you stop typing the flag. It is the opposite of the rest of this tool, and it says so before it runs.

## What you get

**Auto-approved (495 rules)**

| | |
|---|---|
| git | inspection and local mutation — `status`, `diff`, `log`, `add`, `commit`, `stash`, `fetch`, `merge` |
| jvm | `gradle`/`./gradlew`, `mvn`/`./mvnw`/`mvnd`, `java`, `javac`, `jar`, `jshell`, `jcmd`/`jstack`/`jmap`, `spring` |
| kotlin | `kotlin`, `kotlinc`, `ktlint`, `detekt` |
| groovy | `groovy`, `groovyc`, `groovysh`, `grape`, `grails`, `codenarc`, `spotless` — Spock specs run via `gradle test`/`mvn test`, already covered |
| dotnet | `dotnet` (build/test/run/restore/format/publish), `msbuild`, `csharpier` |
| ruby | `ruby`, `gem`, `bundle`, `rake`, `rspec`, `rubocop`, `rails`, `irb`, `puma`, `sidekiq` |
| node | `node`, `deno`, `npm`, `yarn`, `pnpm`, `bun`, `nvm`, `corepack` — including `npm run <script>` |
| javascript/ts | `tsc`, `tsx`, `ts-node`, `eslint`, `prettier`, `biome`, `jest`, `vitest` |
| bundlers | `babel`, `webpack`, `rollup`, `parcel`, `swc`, `esbuild`, `vite`, `rspack`, `tsup`, `turbo` |
| frontend | `next`, `react-scripts`, `storybook`, `cypress`, `astro`, `remix`, `gatsby`, `vue`, `nuxt`, `svelte-kit`, `ng`, `expo`, `nx`, `lerna` |
| python | `python`, `pytest`, `ruff`, `black`, `mypy`, `pip`, `venv`, `poetry`, `uv` |
| rust | `cargo` build/test/check/run/clippy/fmt/doc/add/bench/nextest/audit, `rustc`, `rustfmt`, read-only `rustup` |
| c/c++ | `gcc`, `g++`, `clang`, `ninja`, `ctest`, `meson`, `./configure`, `clang-format`, `clang-tidy`, `cppcheck`, `gdb`, `lldb`, `valgrind`, binutils |
| debugging | `gdb`, `lldb`, `rust-gdb`, `rust-lldb`, `rr`, `strace`, `ltrace`, `perf`, `valgrind`, `heaptrack`, `gcov`/`lcov`, `gprof`, `llvm-cov`, `cargo miri`/`flamegraph`/`bloat`/`tarpaulin` |
| go | `go` (build/test/vet/mod/run/generate), `gofmt`, `goimports`, `golangci-lint`, `staticcheck`, `dlv`, `govulncheck` |
| gh | reads only, across all 23 commands — `pr view`/`diff`/`checks`/`checkout`, `issue view`/`list`, `run view`/`watch`/`download`, `release download`, `repo clone`, `gist view`, `project`/`ruleset`/`org`/`codespace` list-and-view, `config get`, `search` |
| containers | `docker`, `docker compose`, `podman`, `buildah`, `dive`, `hadolint` — build, run, inspect, logs |
| kubernetes | `kubectl`, `helm`, `kustomize`, `k9s`, `stern`, `minikube`, `kind`, `kubeconform` |
| iac | `terraform`, `tofu`, `terragrunt`, `tflint`, `checkov`, `tfsec`, `infracost`, `terraform-docs` |
| ansible | `ansible-lint`, `ansible-doc`, `ansible-inventory`, `ansible-galaxy`, and `ansible-playbook --check`/`--syntax-check` |
| virtualization | `qm`, `pct`, `pvesm`, `pvesh get`, `virsh`, `VBoxManage`, `qemu-system-*`, `qemu-img info`/`create`/`convert` |
| playwright | `playwright`, `npx playwright`, `pnpm exec playwright`, `python -m playwright` |
| shell | `shellcheck`, `shfmt`, and the no-op syntax check `bash -n` |
| office docs | [OfficeCLI](https://github.com/iOfficeAI/OfficeCLI) — `view`, `get`, `query`, `validate`, `create`, `set`, `add`, `move`, `merge`, `batch`, `dump`, `watch` on .docx/.xlsx/.pptx |
| databases | local engines only — `sqlite3`, `duckdb`; plus `sqlfluff`/`sqlfmt` linters and read-only migration verbs (`flyway info`, `alembic current`, `prisma validate`, `dbt compile`) |
| misc | `make`, `cmake`, `just`, and read-only shell (`ls`, `cat`, `grep`, `rg`, `jq`, …) |

The infrastructure toolchains are allowed **broadly**, then the verbs that change reality are pulled back — a narrower `ask` rule always wins over a broader `allow`. So `terraform plan`, `kubectl get`, `helm diff`, and `docker build` run free, while these stop and ask:

**Still prompts (272 rules)**

| | |
|---|---|
| changes infrastructure | `terraform apply`/`destroy`/`import`/`state rm`, `tofu` and `terragrunt` equivalents, `terragrunt run-all` |
| changes a cluster | `kubectl apply`/`delete`/`patch`/`edit`/`scale`/`exec`/`drain`/`cordon`, `helm install`/`upgrade`/`uninstall`/`rollback` |
| changes real hosts | `ansible-playbook` without a dry-run flag |
| destroys local state | `docker system prune`, `docker volume rm`, `minikube delete`, `kind delete` |
| changes or kills a VM | `qm destroy`/`stop`/`set`/`migrate`, `pct destroy`/`stop`, `pvesh create`/`delete`/`set`, `virsh destroy`/`undefine`/`shutdown`/`snapshot-revert`, `VBoxManage unregistervm`/`controlvm`/`modifyvm` |
| writes into a guest disk | `qemu-nbd`, `qemu-img resize`/`snapshot`/`commit`/`rebase`, `guestfish`, `guestmount`, `virt-sysprep`, `virt-resize` |
| arbitrary execution | `bash -c`, `sh -c`, `eval` |
| writes to GitHub | every mutating gh verb — `pr create`/`merge`/`comment`/`review`/`edit`, `issue create`/`comment`/`close`, `repo fork`/`sync`/`edit`/`archive`, `run rerun`/`cancel`, `workflow run`/`enable`, `release edit`/`upload`, `label`/`project` writes, `gh api` |
| costs money / remote shell | `gh codespace create`/`ssh`/`code`/`cp`/`rebuild` |
| third-party code | `gh extension install`/`upgrade`/`exec` |
| changes gh or git state | `gh auth login`/`refresh`/`switch`/`setup-git`, `gh config set`, `gh alias set`, `gh cache delete` |
| fetches and runs code | `cargo install`, `go install`, `rustup install`/`update`, `dotnet tool install`, `sdk install`, `dotnet nuget add source` |
| drops a database | `rails db:drop`/`db:reset`/`destroy`, `rake db:drop`/`db:reset` |
| manages private keys | `keytool` |
| traces the whole system | `bpftrace`, `bpftool`, `sysdig`, `trace-cmd`, `perf trace` — root-level, sees every process |
| reaches other machines | `aws`, `gcloud`, `az`, `ssh`, `scp`, `rsync` |
| destroys uncommitted work | `git reset --hard`, `git clean`, `git rebase` |
| talks to a database | `psql`, `mysql`, `mongosh`, `redis-cli`, `cqlsh`, `influx`, `etcdctl`, `sqlcmd`, `sqlplus` — wholesale, see limitations |
| moves bulk data | `pg_dump`/`pg_restore`, `mysqldump`, `mongodump`/`mongorestore`/`mongoimport` |
| edits documents irreversibly | `officecli remove`, `officecli raw-set`; plus `officecli install`/`mcp` (change your environment or start a server) |
| writes a schema | `flyway migrate`, `liquibase update`, `alembic upgrade`/`downgrade`, `prisma migrate`, `dbt run`/`build`, `knex migrate`, `atlas schema apply`, `goose up` |

Anything not in any list also prompts — that's the default, and it does real work here. `npx` is the clearest case: only `npx playwright` is allowlisted, so every other `npx` invocation prompts without needing a rule. Same for `ansible-playbook` and bare `bash`.

**Blocked outright (76 rules)** — `sudo`, `rm -rf /`, schema wipes (`dropdb`, `flyway clean`, `liquibase dropAll`, `prisma migrate reset`, `redis-cli flushall`/`flushdb`), every publish path (`npm publish`, `mvn deploy`, `gradle publish`, `twine upload`, `cargo publish`, `gem push`/`yank`/`owner`, `dotnet nuget push`, `gh release create`, and `docker push`/`login`, `podman push`, `helm push`), credential mutation (`gem signin`, `nuget setapikey`, `gh secret`, `gh auth token`/`logout`, `gh ssh-key`/`gpg-key add`/`delete`, `cargo login`), `gh repo delete`, `gh release delete`, `gh variable delete`, `gh ruleset delete`, cluster-membership and auth changes on a hypervisor (`pvecm delnode`/`add`, `pveum user`/`role`/`acl delete`, `virsh pool-delete`, `VBoxManage unregistervm --delete`), and reads of `~/.ssh`, `~/.aws/credentials`, `.env.production`.

> **On the infrastructure and hypervisor tools:** allowing `terraform`, `kubectl`, `ansible`, `qm` or `virsh` at all is a bigger step than allowing `pytest`, because the blast radius is production rather than your laptop. The split above is the defensible default, not the only one. If your agents never touch infrastructure, delete those blocks. If you want `terraform apply` to run unattended in a sandboxed CI identity, move it from `ASK` to `ALLOW` — but do that deliberately, and not on a workstation holding production credentials.
>
> Note also that most Proxmox tooling only functions as root, and `sudo` is denied here. On a hypervisor you are relying on already being root; this list grants nothing it could not otherwise do. And `virsh destroy` is a hard power-off, not a delete — `virsh undefine` is the delete. Both stop and ask.

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
./agent-guardrails.sh --global --uninstall  # remove everything it added
./agent-guardrails.sh --global --permissive # turn the guardrails OFF entirely
```

Every write is additive, de-duplicated, idempotent, and backed up to `<file>.bak` first. Your existing rules, hooks, model, and theme survive. Run it twice and nothing changes. (`--permissive` is the one exception — see below.)

### Fully permissive mode

```bash
./agent-guardrails.sh --global --permissive      # every project on this machine
./agent-guardrails.sh --project . --permissive   # one project
./agent-guardrails.sh --print --permissive       # show it, touch nothing
```

The inverse of everything else here: it removes the gate rather than scoping it. This is `--dangerously-skip-permissions` and `--dangerously-bypass-approvals-and-sandbox` written into your config files so you stop passing the flag.

| | permissive mode writes |
|---|---|
| **Claude Code** | `defaultMode: "bypassPermissions"`, plus catch-all `Bash(*)`/`Read(*)`/`Write(*)`/… rules so it still holds if a managed policy strips `defaultMode`. `ask` and `deny` set to `[]`. Guard removed. |
| **Codex** | `approval_policy = "never"`, `sandbox_mode = "danger-full-access"` in `config.toml`; `--project` also adds `[projects."<path>"] trust_level = "trusted"` to the global config. Guard removed. |
| **agy** | `command(*)`, `read_file(*)`, `write_file(*)` in `allow` — the exact inverse of its default, which is to *ask* on `command(*)`. `ask`/`deny` emptied, `allowNonWorkspaceAccess: true`. |

It prints what it is about to do and waits for you to type `yes`; `--yes` skips that, and it refuses to run non-interactively without it. `--managed` and `--permissive` together are an error — one pins policy centrally, the other removes it.

**It clears `ask` and `deny` outright, including rules you added yourself.** That is the mode, not an oversight — a deny rule you wrote is still a gate. `<file>.bak` is your only way back, and it is single-level. Codex's `config.toml` is the exception: keys it displaces are commented out with a `#agent-guardrails-disabled#` tag rather than deleted, so uninstall restores them exactly.

Use it in a container or a VM you can throw away. If your reason for wanting it is prompt fatigue, the allowlist is the answer to that and this is not.

Both `--uninstall` and a plain re-install undo it: installing normally over a permissive install strips `defaultMode`, the catch-all rules, the `config.toml` block and the trust entry before writing the real rules back, so you never end up with rules that a bypass switch is quietly ignoring.

#### Why the Codex side writes a trust entry

Because without it, project-scope permissive is a silent no-op. Codex only reads a project-local `.codex/config.toml` **when the directory is trusted** — its own trust prompt says so: *"Trusting the directory allows project-local config, hooks, and exec policies to load."*

Measured with `codex doctor --json`, which reports the resolved policy, against a scratch `CODEX_HOME` whose user-level config said `on-request` / `workspace-write`:

| directory trust | project-local `.codex/config.toml` | resolved policy |
|---|---|---|
| trusted | present | **approval=Never, fs=unrestricted** |
| trusted | absent | approval=OnRequest, fs=restricted |
| untrusted | **present** | approval=OnRequest, fs=restricted — **file ignored** |
| untrusted | absent | approval=OnRequest, fs=restricted |

Row three is the trap: the file is there, it parses, and nothing happens. So `--project --permissive` writes `[projects."<path>"] trust_level = "trusted"` into the *global* config alongside it, and `--uninstall` takes that entry back out.

Global scope has no such dependency — user-level `config.toml` resolves to `approval=Never, fs=unrestricted` in an untrusted directory too.

Two limits on that evidence. `doctor` proves Codex **resolves** the settings, not that a live authenticated session then runs without prompting. And the binary carries the string `Ignored unsupported project-local config keys in …`, so project-local config honours only a subset of keys — `approval_policy` and `sandbox_mode` are demonstrably in it, anything added there later may not be.

#### Does permissive mode actually change what runs?

Yes — measured on Claude Code and agy by side effect rather than by reading the agent's prose. Each CLI was given a baseline config that **explicitly denies** a marker command, asked to run it, and the filesystem checked afterwards. Marker present means the tool call executed. Neither run passed a bypass flag, which would have made every condition pass.

| CLI | baseline | after `--permissive` |
|---|---|---|
| **Claude Code** | `deny: ["Bash(touch *)"]` → not created | **created** |
| **agy** | `deny: ["command(touch)"]` → not created | **created** |

agy names the mechanism itself in the denied case: *"The command was denied by a user-configured deny rule."* That confirms both that agy enforces `deny` — its rule semantics are otherwise inferred — and that clearing it is what lets the command through.

Codex is covered by the resolved-policy probe above instead; its gate is `approval_policy`, not a rule list, so there is no deny rule to override.

This exercises permissive mode overriding a deny, not the 495-rule normal install, which is a separate question.

#### If your admins disabled bypass mode

Permissive mode still works — **as long as the workspace is trusted.** Managed settings can forbid `defaultMode: bypassPermissions`, which is why the catch-all rules are written alongside it; separating the two halves shows each authorises on its own.

| project settings | `defaultMode` | command ran? |
|---|---|---|
| no rules | — | no (control) |
| `Bash(*)`, `Read(*)`, `Edit(*)`, `Write(*)` | **absent** | **yes** — catch-alls alone suffice |
| `Bash(touch:*)` | absent | yes (positive control, documented syntax) |
| no rules | `bypassPermissions` | yes |

Trust is the catch, and it cuts differently for each half:

| workspace | bypass mode | permissive works? |
|---|---|---|
| trusted | disabled | **yes** |
| trusted | available | yes |
| untrusted | disabled | **no — rules discarded** |
| untrusted | available | yes, on `defaultMode` alone |

`defaultMode` is honoured in an untrusted workspace; **allow rules are not.** So an environment that disables bypass mode is exactly the one that depends on trust.

#### Claude ignores project rules in an untrusted workspace

This is not specific to permissive mode — **it applies to the ordinary 495-rule `--project` install too**, and it is the most likely reason a project install appears to do nothing:

```
Ignoring 10 permissions.allow entries from .claude/settings.json:
this workspace has not been trusted.
```

Trust does not inherit: a subdirectory of a trusted parent is still untrusted. Install into a freshly cloned repo and the rules sit inert until you run Claude there once and accept the dialog — you get prompted for `npm test` and conclude the tool failed.

`--project` prints a warning about this. It does **not** write `hasTrustDialogAccepted` into `~/.claude.json` for you: that suppresses a security prompt on your behalf, which an install script has no business doing quietly. Accept the dialog once, or set it yourself knowing what it means.

Global scope is unaffected — `~/.claude/settings.json` is not workspace-scoped. (Asserted from the mechanism, not measured; the failure mode above was only ever observed on project files.)

#### If your admins disabled Codex full access, permissive skips Codex entirely

Claude survives bypass being disabled because the catch-all rules are a second, independent mechanism. **Codex has no second mechanism.** It has no allowlist; `approval_policy` and `sandbox_mode` are its only levers, and those are exactly the two keys `/etc/codex/requirements.toml` pins. There is nothing to fall back to.

Worse, Codex does not reject a forbidden value — it **falls back to the most restrictive allowed one**. Measured against the policy this repo ships in `enterprise/`:

| config.toml asks for | Codex resolves to |
|---|---|
| `approval_policy = "never"` | `UnlessTrusted` — *stricter than the `on-request` you had* |
| `sandbox_mode = "danger-full-access"` | restricted filesystem, restricted network |

```
Configured value for `approval_policy` is disallowed by requirements;
falling back to required value UnlessTrusted. Details: invalid value for
`approval_policy`: `Never` is not in the allowed set [UnlessTrusted,
OnRequest, OnRequest] (set by /etc/codex/requirements.toml)
```

Since permissive mode comments your existing value out on the way past, running it under such a policy would leave you **more** gated than before — the one outcome worse than doing nothing. So it doesn't: when `/etc/codex/requirements.toml` forbids either value, `--permissive` skips Codex, leaves the config untouched, and leaves the push guard in place. It says so rather than reporting a success it didn't achieve.

Claude and agy are still made permissive in that case — the policy constrains Codex only. Set `CODEX_REQUIREMENTS` to point the check at a different file if you need to test it.

"Skips" means nothing is written for Codex: no policy block, your existing `approval_policy` and `sandbox_mode` not displaced, no `trust_level` entry, and the push guard left in `hooks.json` rather than removed. It skips because writing would leave you worse off — not because the settings are unwanted.

#### What you *can* have under that policy

Most of what you wanted, as it turns out. Measured with `codex exec` under `approval_policy = "untrusted"` + `sandbox_mode = "workspace-write"` — the strictest pair such a policy still permits — using `-c` overrides only, no bypass flag:

| command writes to | project trusted | result |
|---|---|---|
| inside the workspace | no | **runs, no prompt** |
| inside the workspace | yes | **runs, no prompt** |
| outside the workspace | no | blocked — *"target path is on a read-only filesystem"* |
| outside the workspace | yes | blocked — trust does not lift it |

So the strictest allowed setting **already runs your ordinary work unprompted**. Everything inside the project — and `/tmp` — executes with no approval at all. What you give up is writes outside the workspace and network escalation.

Two things worth knowing:

- **The sandbox is the binding constraint, not the approval policy.** `trust_level` looked like a loophole, since it is the one relevant key a requirements file cannot pin — `allowed_*` covers approval policies, sandbox modes, reviewers, permission profiles and web-search modes, but not trust. It isn't one: trust governs project-local config loading and approval prompting, not what the sandbox permits.
- **Check `sandbox_mode` is `workspace-write` and not `read-only`.** That one setting is your ceiling, it is within policy, and it is the whole difference between a Codex that works and one that cannot write at all.

Limit on the evidence: `exec` is non-interactive, so it cannot distinguish "would have prompted you" from "refused" — there is nobody to approve. In an interactive session `approval_policy` decides whether an escalation prompts; the table above establishes where the sandbox boundary sits, not what the prompt would have said.

### Uninstalling

```bash
./agent-guardrails.sh --global --uninstall
./agent-guardrails.sh --project --uninstall
```

This **subtracts exactly the rules it added** and strips the guard hook — it does not restore `<file>.bak`. That matters: `.bak` is single-level and overwritten on every run, so after two installs it holds your previous *installed* state, not your original config. Subtraction gets you back to a genuinely clean file however many times you have run it, and it is idempotent and safe on a config that never had it installed.

Two things it deliberately leaves behind: the guard script itself (it prints the path and the `rm` for you, in case a project-scope install still references it), and `[features] hooks = true` in Codex's `config.toml`, since your other hooks may need it. On agy it leaves `trustedWorkspaces` and `allowNonWorkspaceAccess` alone.

It also undoes a `--permissive` install: the `config.toml` block goes, the keys that block displaced are un-commented back to their original values, the `[projects."<path>"]` trust entry added for a project is removed, and `defaultMode: bypassPermissions` is deleted. Uninstalling gets you to *no rules*, not back to the permissive state.

Rules the project shipped in earlier versions and has since retired are subtracted too, so an uninstall is clean even if you installed an old version. One caveat remains: if a rule of your own is byte-identical to one of ours, uninstall removes it too — after the fact there is no way to tell them apart.

**Claude Code won't pick the hook up mid-session** — open `/hooks` once to reload, or start a new session.

## The three harnesses are not equal

This is the part other tools gloss over. Each CLI's capabilities were determined by reading its binary, not by guessing:

| | allowlist | push guard | verified against |
|---|---|---|---|
| **Claude Code** | 495 rules, `Bash(git commit *)` | full — allow, ask, and deny | `2.1.220` |
| **Codex** | **none** — no allowlist mechanism exists | **deny only** | `0.145.0` |
| **agy** | 490 rules, `command(git commit)` | **none** | `1.1.7` |

> **Last verified: 2026-07-29.** These CLIs ship fast — agy moved from `1.1.6` to `1.1.7` during a single afternoon of writing this. If the date above is old, treat the table as a starting point rather than fact.

**Codex** has no per-command allowlist at all. Its gating is `approval_policy` × `sandbox_mode` × `[projects.*] trust_level`. And its hook engine rejects anything but a denial — the binary literally carries the string `PreToolUse hook returned unsupported permissionDecision:allow`. So Codex gets the guard in `--deny-only` mode and no rules. That composes well: if your Codex is already on a trusted project with full access, the guard carves protected branches back out.

The third term in that product is not decoration. A project-local `.codex/config.toml` is read **only when the directory is trusted**, which is why `--project --permissive` writes a `trust_level` entry as well — [measured, with the 2×2](#why-the-codex-side-writes-a-trust-entry). Anything project-scoped you add for Codex later inherits that dependency.

**agy** has the allowlist (its own syntax: `command(…)`, `read_file(…)`, `write_file(…)`) but no `permissionDecision` protocol in its hooks, so the guard can't run there. Worth knowing: agy asks on `command(*)` by default — *every* shell command — so the allowlist is the whole win there.

These are reverse-engineered constraints, not documented API. [CONTRIBUTING.md](CONTRIBUTING.md) has the exact commands to re-verify them against a new release — please update the table and its date in the same PR.

## For your admins

`enterprise/` holds policy files your platform team can deploy, so the rules are pinned centrally and users can't loosen them:

- `claude-managed-settings.json` → `/etc/claude-code/managed-settings.json`, with `allowManagedPermissionRulesOnly: true` so policy is the only source of permission rules
- `codex-managed-config.toml` → `/etc/codex/managed_config.toml`
- `codex-requirements.toml` → `/etc/codex/requirements.toml`, pinning `allowed_approval_policies` and `allowed_sandbox_modes`

`./agent-guardrails.sh --print --managed` prints the same content for pasting into a ticket.

These hold against this tool, not just against users: deploy `codex-requirements.toml` and `--permissive` [refuses to touch Codex](#if-your-admins-disabled-codex-full-access-permissive-skips-codex-entirely) rather than writing settings that would be clamped. A policy that says no should not be answerable by the thing it is saying no to.

## Honest limitations

- **`deny` rules on pipes are decorative.** `Bash(curl * | sh)` cannot reliably catch pipe-to-shell — prefix matching isn't a parser, and a rewritten command sidesteps it. Those entries document intent; they are not enforcement.
- **`officecli batch` is an escape hatch around its own gates.** `remove` and `raw-set` sit in `ask`, but `batch` reads a list of operations from stdin or `--input` and those operations can include removals. `batch` is allowed because it is the efficient path an agent should take, and the blast radius is a local document file — but the `remove` gate is best-effort, not a boundary. The same is true of `dump`, which round-trips a document to replayable JSON.
- **The allowlist cannot see inside a query string.** This is why database clients are treated differently from every other toolchain here. With `terraform` or `kubectl` the dangerous verb is the first token, so a narrow `ask` catches `apply` and `destroy` while `plan` and `get` run free. With `psql`, the destructive part is *inside the argument* — `psql -c 'DROP TABLE users'` is indistinguishable from a `SELECT` to prefix matching. So `psql`, `mysql`, `mongosh`, `redis-cli` and friends sit in `ask` wholesale rather than being split by verb. The `redis-cli flushall` deny rules are best-effort for the same reason, and are case-sensitive while redis commands are not.
- **`npm run` executes whatever the project defines.** It is allowed, via the broad `npm`/`yarn`/`pnpm` rules, and it is the workhorse — most JS and React work is `npm run dev`, `npm run build`, `npm test`. That is the right call *for repositories you trust*, because the scripts are curated by the project. It is exactly the wrong call for a repo the agent just cloned: `npm run` and `npm install` (via `postinstall` hooks) are the widest arbitrary-execution paths on the JS side. If your agents clone untrusted code, that is a sandbox problem, not an allowlist one.
- **An allowlist is not a sandbox.** `Bash(python *)` allows `python -c 'anything'`, and `Bash(gcc *)` will happily compile and link whatever it is pointed at. This tool reduces prompt fatigue for trusted toolchains; it is not a containment boundary. If you need containment, use a devcontainer or your harness's sandbox mode.
- **Bare `bash` and `sh` are deliberately not allowlisted.** `bash -c '<anything>'` would make every other rule here meaningless, so only `shellcheck`, `shfmt`, and the no-op `bash -n` are allowed; `bash -c` is in the ask list. If you allowlist `Bash(bash *)` yourself, understand that you have effectively turned the allowlist off.
- **A `--project` install on Claude is inert until the workspace is trusted.** Project-level `permissions.allow` entries are discarded wholesale in an untrusted workspace, and trust does not inherit from a parent directory. [Details above.](#claude-ignores-project-rules-in-an-untrusted-workspace) The installer warns; it will not accept the trust dialog for you.
- **An `ask` rule shadows a more specific `allow` rule.** `Bash(npx *)` in ask would swallow `Bash(npx playwright *)` in allow. The rule lists are written to avoid overlaps entirely rather than depend on precedence; keep it that way when adding rules.
- **agy's prefix semantics are inferred**, from built-ins like `command(npm test)` and `command(tail -F)`. If agy turns out to match exactly rather than by prefix, most of its 490 rules are inert. Verify before relying on it.
- **A denied push rejects the whole command.** The guard scans every segment of a compound command, so `make test && git push origin main` is denied in its entirety — the build does not run first. This is deliberate (a guard should fail closed), but it surprises people who expect only the push to be blocked. Run the work and the push as separate commands.
- **Bypass mode skips the rules.** If you run with `--dangerously-skip-permissions` anyway, allow/ask/deny are ignored wholesale — only the hook still fires. `--permissive` is that state made persistent, and it removes the hook too, so nothing fires at all.

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
