# agent-guardrails

**Your company blocked `--dangerously-skip-permissions`. Good. Here's how to get your speed back anyway.**

Coding agents are fast right up until they aren't. Every `npm test`, every `git diff`, every `pytest -k foo` stops and waits for you to click yes. So people reach for the bypass flag — and enterprise admins, reasonably, turn it off.

`agent-guardrails` is the middle path: a scoped allowlist that auto-approves the ~435 commands you actually run all day, keeps a prompt on the ones that reach off your machine, and hard-blocks the ones nobody should run unattended. Plus a hook that refuses to push to `main`.

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
allow=435 ask=186 deny=71
```

---

## Why not just ask for bypass mode?

Because you won't get it, and you shouldn't. Bypass mode is all-or-nothing: it turns off the check on `npm test` *and* the check on `curl … | sh`. No security team is going to sign that.

An allowlist is a different conversation. It's specific, it's reviewable, and it's the thing managed settings were built for. `--print` gives you a JSON fragment you can attach to a ticket, and `enterprise/` gives your admins drop-in policy files. That request gets approved.

## What you get

**Auto-approved (435 rules)**

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
| go | `go` (build/test/vet/mod/run/generate), `gofmt`, `goimports`, `golangci-lint`, `staticcheck`, `dlv`, `govulncheck` |
| gh | read-only only — `pr view`/`list`/`diff`/`checks`, `issue view`/`list`, `run view`/`watch`, `repo view`, `search` |
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

**Still prompts (186 rules)**

| | |
|---|---|
| changes infrastructure | `terraform apply`/`destroy`/`import`/`state rm`, `tofu` and `terragrunt` equivalents, `terragrunt run-all` |
| changes a cluster | `kubectl apply`/`delete`/`patch`/`edit`/`scale`/`exec`/`drain`/`cordon`, `helm install`/`upgrade`/`uninstall`/`rollback` |
| changes real hosts | `ansible-playbook` without a dry-run flag |
| destroys local state | `docker system prune`, `docker volume rm`, `minikube delete`, `kind delete` |
| changes or kills a VM | `qm destroy`/`stop`/`set`/`migrate`, `pct destroy`/`stop`, `pvesh create`/`delete`/`set`, `virsh destroy`/`undefine`/`shutdown`/`snapshot-revert`, `VBoxManage unregistervm`/`controlvm`/`modifyvm` |
| writes into a guest disk | `qemu-nbd`, `qemu-img resize`/`snapshot`/`commit`/`rebase`, `guestfish`, `guestmount`, `virt-sysprep`, `virt-resize` |
| arbitrary execution | `bash -c`, `sh -c`, `eval` |
| writes to GitHub | `gh pr create`/`merge`, `gh issue create`, `gh api`, `gh workflow run` |
| fetches and runs code | `cargo install`, `go install`, `rustup install`/`update`, `dotnet tool install`, `sdk install`, `dotnet nuget add source` |
| drops a database | `rails db:drop`/`db:reset`/`destroy`, `rake db:drop`/`db:reset` |
| manages private keys | `keytool` |
| reaches other machines | `aws`, `gcloud`, `az`, `ssh`, `scp`, `rsync` |
| destroys uncommitted work | `git reset --hard`, `git clean`, `git rebase` |
| talks to a database | `psql`, `mysql`, `mongosh`, `redis-cli`, `cqlsh`, `influx`, `etcdctl`, `sqlcmd`, `sqlplus` — wholesale, see limitations |
| moves bulk data | `pg_dump`/`pg_restore`, `mysqldump`, `mongodump`/`mongorestore`/`mongoimport` |
| edits documents irreversibly | `officecli remove`, `officecli raw-set`; plus `officecli install`/`mcp` (change your environment or start a server) |
| writes a schema | `flyway migrate`, `liquibase update`, `alembic upgrade`/`downgrade`, `prisma migrate`, `dbt run`/`build`, `knex migrate`, `atlas schema apply`, `goose up` |

Anything not in any list also prompts — that's the default, and it does real work here. `npx` is the clearest case: only `npx playwright` is allowlisted, so every other `npx` invocation prompts without needing a rule. Same for `ansible-playbook` and bare `bash`.

**Blocked outright (71 rules)** — `sudo`, `rm -rf /`, schema wipes (`dropdb`, `flyway clean`, `liquibase dropAll`, `prisma migrate reset`, `redis-cli flushall`/`flushdb`), every publish path (`npm publish`, `mvn deploy`, `gradle publish`, `twine upload`, `cargo publish`, `gem push`/`yank`/`owner`, `dotnet nuget push`, `gh release create`, and `docker push`/`login`, `podman push`, `helm push`), credential mutation (`gem signin`, `nuget setapikey`, `gh secret`, `gh auth token`, `gh ssh-key add`, `cargo login`), `gh repo delete`, cluster-membership and auth changes on a hypervisor (`pvecm delnode`/`add`, `pveum user`/`role`/`acl delete`, `virsh pool-delete`, `VBoxManage unregistervm --delete`), and reads of `~/.ssh`, `~/.aws/credentials`, `.env.production`.

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
```

Every write is additive, de-duplicated, idempotent, and backed up to `<file>.bak` first. Your existing rules, hooks, model, and theme survive. Run it twice and nothing changes.

**Claude Code won't pick the hook up mid-session** — open `/hooks` once to reload, or start a new session.

## The three harnesses are not equal

This is the part other tools gloss over. Each CLI's capabilities were determined by reading its binary, not by guessing:

| | allowlist | push guard | verified against |
|---|---|---|---|
| **Claude Code** | 435 rules, `Bash(git commit *)` | full — allow, ask, and deny | `2.1.220` |
| **Codex** | **none** — no allowlist mechanism exists | **deny only** | `0.145.0` |
| **agy** | 429 rules, `command(git commit)` | **none** | `1.1.7` |

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
- **`officecli batch` is an escape hatch around its own gates.** `remove` and `raw-set` sit in `ask`, but `batch` reads a list of operations from stdin or `--input` and those operations can include removals. `batch` is allowed because it is the efficient path an agent should take, and the blast radius is a local document file — but the `remove` gate is best-effort, not a boundary. The same is true of `dump`, which round-trips a document to replayable JSON.
- **The allowlist cannot see inside a query string.** This is why database clients are treated differently from every other toolchain here. With `terraform` or `kubectl` the dangerous verb is the first token, so a narrow `ask` catches `apply` and `destroy` while `plan` and `get` run free. With `psql`, the destructive part is *inside the argument* — `psql -c 'DROP TABLE users'` is indistinguishable from a `SELECT` to prefix matching. So `psql`, `mysql`, `mongosh`, `redis-cli` and friends sit in `ask` wholesale rather than being split by verb. The `redis-cli flushall` deny rules are best-effort for the same reason, and are case-sensitive while redis commands are not.
- **`npm run` executes whatever the project defines.** It is allowed, via the broad `npm`/`yarn`/`pnpm` rules, and it is the workhorse — most JS and React work is `npm run dev`, `npm run build`, `npm test`. That is the right call *for repositories you trust*, because the scripts are curated by the project. It is exactly the wrong call for a repo the agent just cloned: `npm run` and `npm install` (via `postinstall` hooks) are the widest arbitrary-execution paths on the JS side. If your agents clone untrusted code, that is a sandbox problem, not an allowlist one.
- **An allowlist is not a sandbox.** `Bash(python *)` allows `python -c 'anything'`, and `Bash(gcc *)` will happily compile and link whatever it is pointed at. This tool reduces prompt fatigue for trusted toolchains; it is not a containment boundary. If you need containment, use a devcontainer or your harness's sandbox mode.
- **Bare `bash` and `sh` are deliberately not allowlisted.** `bash -c '<anything>'` would make every other rule here meaningless, so only `shellcheck`, `shfmt`, and the no-op `bash -n` are allowed; `bash -c` is in the ask list. If you allowlist `Bash(bash *)` yourself, understand that you have effectively turned the allowlist off.
- **An `ask` rule shadows a more specific `allow` rule.** `Bash(npx *)` in ask would swallow `Bash(npx playwright *)` in allow. The rule lists are written to avoid overlaps entirely rather than depend on precedence; keep it that way when adding rules.
- **agy's prefix semantics are inferred**, from built-ins like `command(npm test)` and `command(tail -F)`. If agy turns out to match exactly rather than by prefix, most of its 429 rules are inert. Verify before relying on it.
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
