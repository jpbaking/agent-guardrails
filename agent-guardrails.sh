#!/usr/bin/env bash
# agent-guardrails — one scoped permissions allowlist for every agent CLI on
# this machine (Claude Code, Codex, agy), plus the git-push branch guard.
#
#   ./agent-guardrails.sh --global            # user-level, every harness
#   ./agent-guardrails.sh --project [PATH]    # project/workspace-level (default: cwd)
#   ./agent-guardrails.sh --print             # show what would be written, touch nothing
#   ./agent-guardrails.sh --global --no-hook  # allowlist only, skip the push guard
#   ./agent-guardrails.sh --print --managed   # shape as an enterprise policy proposal
#   ./agent-guardrails.sh --global --uninstall    # remove every rule and hook it added
#   ./agent-guardrails.sh --project --uninstall   # same, for a project
#   ./agent-guardrails.sh --global --permissive   # FULLY PERMISSIVE — no gate at all
#
# --permissive is the opposite of everything else here: it turns the guardrails
# OFF rather than scoping them. Nothing is asked, nothing is denied, the push
# guard is removed, and any deny rules already in your config are cleared. It is
# --dangerously-skip-permissions / --dangerously-bypass-approvals-and-sandbox
# written into the config files so you stop passing the flag. Only use it inside
# a container or VM you can throw away. Add --yes to skip the confirmation.
#
# You pick the scope; the script handles the per-harness differences:
#
#   scope     Claude Code                 Codex                    agy
#   global    ~/.claude/settings.json     ~/.codex/hooks.json      ~/.gemini/antigravity-cli/
#                                                                    settings.json
#   project   <p>/.claude/settings.json   <p>/.codex/hooks.json    trustedWorkspaces += <p>
#
# Capability differences, handled automatically:
#   - Codex has no allowlist at all (approval_policy x sandbox_mode x trust_level
#     instead), and its PreToolUse hooks may only return "deny" — so it gets the
#     guard in --deny-only mode and no rules.
#   - agy has no permissionDecision hook protocol, so it gets rules but no guard.
#     It also has no per-project settings file; project scope adds the path to
#     trustedWorkspaces in its global settings instead.
#   - Under --permissive, Codex is the one that actually needs config.toml
#     rewritten (approval_policy/sandbox_mode), since it has no rules to widen.
#
# Existing entries are preserved and de-duplicated, never replaced. Every file
# is backed up to <file>.bak before any change. Re-running is idempotent.
# (--permissive is the exception: it clears ask/deny outright. See below.)

set -euo pipefail

# The guard ships in this repo but is INSTALLED to a stable path outside it, so
# the absolute path written into your config files keeps working even if you
# move or delete the checkout. Override the destination with AGENT_GUARDRAILS_DIR.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD_SRC="$SELF_DIR/hooks/git-push-guard.sh"
GUARD="${AGENT_GUARDRAILS_DIR:-$HOME/.agents/hooks}/git-push-guard.sh"

install_guard() {
  [ -f "$GUARD_SRC" ] || return 0                 # running standalone, guard already deployed
  mkdir -p "$(dirname "$GUARD")"
  if ! cmp -s "$GUARD_SRC" "$GUARD"; then
    cp "$GUARD_SRC" "$GUARD"
    note "guard   installed -> $GUARD"
  fi
  chmod +x "$GUARD"
}

# ─────────────────────────────────────────────────────────────────── allow rules
# Safe to run unattended: local, reversible, no outbound publish, no privilege
# escalation. Prefix-match — "Bash(git status *)" also matches bare "git status".

ALLOW=(
  # ---- git: inspection ----
  "Bash(git status *)" "Bash(git diff *)" "Bash(git log *)" "Bash(git show *)"
  "Bash(git branch *)" "Bash(git remote *)" "Bash(git rev-parse *)"
  "Bash(git describe *)" "Bash(git blame *)" "Bash(git shortlog *)"
  "Bash(git ls-files *)" "Bash(git symbolic-ref *)" "Bash(git config --get *)"
  # ---- git: local mutation (recoverable via reflog) ----
  "Bash(git add *)" "Bash(git commit *)" "Bash(git restore *)"
  "Bash(git switch *)" "Bash(git checkout *)" "Bash(git stash *)"
  "Bash(git fetch *)" "Bash(git pull *)" "Bash(git merge *)"
  "Bash(git cherry-pick *)" "Bash(git tag *)" "Bash(git worktree *)"
  # NOTE: `git push` is deliberately absent — the guard decides it per-branch.
  # Allowlisting it here would defeat the protected-branch check.

  # ---- jvm: build tools ----
  "Bash(./gradlew *)" "Bash(gradle *)" "Bash(gradlew *)" "Bash(gradle-profiler *)"
  "Bash(mvn *)" "Bash(./mvnw *)" "Bash(mvnw *)" "Bash(mvnd *)"

  # ---- java ----
  # `java -jar x.jar` is arbitrary execution, same as `python x.py` — allowed on
  # the same reasoning. keytool is NOT here: it manages keystores and private
  # keys, so it sits with the credential tools in ASK.
  "Bash(java *)" "Bash(javac *)" "Bash(jar *)" "Bash(javap *)" "Bash(jshell *)"
  "Bash(jdeps *)" "Bash(jlink *)" "Bash(jpackage *)" "Bash(javadoc *)"
  "Bash(jcmd *)" "Bash(jstack *)" "Bash(jmap *)" "Bash(jps *)" "Bash(jstat *)"
  "Bash(jfr *)" "Bash(jhsdb *)" "Bash(sdk list *)" "Bash(sdk current *)"

  # ---- spring ----
  "Bash(spring *)" "Bash(./gradlew bootRun *)" "Bash(./gradlew bootJar *)"

  # ---- kotlin ----
  "Bash(kotlin *)" "Bash(kotlinc *)" "Bash(kotlinc-jvm *)" "Bash(ktlint *)"
  "Bash(detekt *)" "Bash(kapt *)"

  # ---- groovy ----
  # Spock is deliberately absent: it ships no CLI. Spock specs run through
  # `gradle test` / `mvn test`, which the build-tool rules above already cover
  # (including `./gradlew test --tests "*Spec"`). Nothing to add for it.
  # `grape` resolves and downloads jars — allowed on the same footing as
  # `pip install` and `npm install`.
  "Bash(groovy *)" "Bash(groovyc *)" "Bash(groovysh *)" "Bash(groovyConsole *)"
  "Bash(grape *)" "Bash(grails *)" "Bash(codenarc *)" "Bash(spotless *)"

  # ---- dotnet ----
  # `dotnet publish` builds a deployable folder locally — it does NOT publish to
  # a registry. That is `dotnet nuget push`, which is denied.
  "Bash(dotnet *)" "Bash(msbuild *)" "Bash(nuget list *)" "Bash(nuget locals *)"
  "Bash(csharpier *)" "Bash(dotnet-format *)"

  # ---- ruby ----
  "Bash(ruby *)" "Bash(gem *)" "Bash(bundle *)" "Bash(bundler *)"
  "Bash(rake *)" "Bash(rspec *)" "Bash(rubocop *)" "Bash(rails *)"
  "Bash(irb *)" "Bash(erb *)" "Bash(pry *)" "Bash(foreman *)"
  "Bash(puma *)" "Bash(sidekiq *)" "Bash(rackup *)" "Bash(standardrb *)"
  "Bash(rbenv version *)" "Bash(rbenv versions *)" "Bash(rbenv local *)"

  # ---- node / js ----
  "Bash(node *)" "Bash(npm *)" "Bash(yarn *)" "Bash(pnpm *)" "Bash(bun *)"
  "Bash(nvm *)" "Bash(corepack *)"

  # ---- typescript & js tooling ----
  "Bash(tsc *)" "Bash(tsx *)" "Bash(ts-node *)" "Bash(eslint *)"
  "Bash(prettier *)" "Bash(jest *)" "Bash(vitest *)"   # playwright: see below
  "Bash(biome *)" "Bash(esbuild *)" "Bash(vite *)" "Bash(turbo *)"
  "Bash(deno *)"

  # ---- bundlers & compilers ----
  "Bash(babel *)" "Bash(babel-node *)" "Bash(webpack *)" "Bash(webpack-cli *)"
  "Bash(rollup *)" "Bash(parcel *)" "Bash(swc *)" "Bash(rspack *)" "Bash(tsup *)"
  "Bash(rolldown *)" "Bash(microbundle *)"

  # ---- frontend frameworks ----
  # React itself has no CLI — this is the tooling around it. Most React work
  # already runs via `npm run <script>`, which the package managers cover.
  "Bash(next *)" "Bash(react-scripts *)" "Bash(craco *)" "Bash(remix *)"
  "Bash(astro *)" "Bash(gatsby *)" "Bash(vue *)" "Bash(vue-cli-service *)"
  "Bash(nuxt *)" "Bash(nuxi *)" "Bash(svelte-kit *)" "Bash(ng *)"
  "Bash(storybook *)" "Bash(cypress *)" "Bash(expo *)"

  # ---- monorepo tooling ----
  "Bash(nx *)" "Bash(lerna *)" "Bash(changeset *)" "Bash(rush *)"

  # ---- npx carve-outs ----
  # Bare `npx` is not allowlisted (it executes arbitrary remote packages), so
  # the common local-binary invocations are named explicitly instead.
  "Bash(npx next *)" "Bash(npx storybook *)" "Bash(npx cypress *)"
  "Bash(npx tsc *)" "Bash(npx eslint *)" "Bash(npx prettier *)"
  "Bash(npx vitest *)" "Bash(npx jest *)" "Bash(npx vite *)"
  "Bash(npx webpack *)" "Bash(npx babel *)" "Bash(npx tsx *)"

  # ---- python ----
  "Bash(python *)" "Bash(python3 *)" "Bash(pytest *)" "Bash(tox *)"
  "Bash(ruff *)" "Bash(black *)" "Bash(mypy *)" "Bash(flake8 *)" "Bash(isort *)"
  "Bash(poetry *)" "Bash(uv *)" "Bash(uvx *)" "Bash(pipx *)" "Bash(hatch *)"

  # ---- pip & venv ----
  "Bash(pip *)" "Bash(pip3 *)"
  "Bash(python -m pip *)" "Bash(python3 -m pip *)"
  "Bash(python -m venv *)" "Bash(python3 -m venv *)"
  "Bash(virtualenv *)" "Bash(source *bin/activate)"
  "Bash(.venv/bin/*)" "Bash(venv/bin/*)" "Bash(./.venv/bin/*)"

  # ---- databases: local engines, linters, and read-only verbs ----
  # The networked clients (psql, mysql, mongosh, redis-cli, ...) are NOT here.
  # With terraform or kubectl the dangerous verb is the first token, so a
  # narrow ask can catch it. With a database client the destructive part lives
  # inside the query string — `psql -c 'DROP TABLE users'` is indistinguishable
  # from a SELECT to prefix matching. Those clients stay unlisted and prompt.
  # sqlite3 and duckdb are allowed because their blast radius is a local file.
  "Bash(sqlite3 *)" "Bash(duckdb *)" "Bash(litecli *)"
  "Bash(sqlfluff *)" "Bash(sqlfmt *)" "Bash(sqlint *)" "Bash(pg_isready *)"
  "Bash(flyway info *)" "Bash(flyway validate *)"
  "Bash(liquibase status *)" "Bash(liquibase validate *)" "Bash(liquibase diff *)"
  "Bash(alembic current *)" "Bash(alembic history *)" "Bash(alembic heads *)"
  "Bash(alembic show *)" "Bash(alembic check *)"
  "Bash(prisma validate *)" "Bash(prisma format *)" "Bash(prisma generate *)"
  "Bash(atlas schema inspect *)" "Bash(migrate version *)" "Bash(goose status *)"
  "Bash(dbt compile *)" "Bash(dbt parse *)" "Bash(dbt ls *)" "Bash(dbt debug *)"
  "Bash(dbt deps *)" "Bash(dbt docs generate *)"

  # ---- office documents (OfficeCLI) ----
  # github.com/iOfficeAI/OfficeCLI — reads and edits .docx/.xlsx/.pptx.
  # The editing verbs ARE the point of the tool, and their blast radius is a
  # local file, so they are allowed. Held back below: `remove` and `raw-set`
  # (irreversible content/XML surgery), `install` and `mcp` (they change your
  # environment or start a server), and `config set`.
  "Bash(officecli view *)" "Bash(officecli get *)" "Bash(officecli query *)"
  "Bash(officecli raw *)" "Bash(officecli validate *)" "Bash(officecli help *)"
  "Bash(officecli load_skill *)" "Bash(officecli create *)"
  "Bash(officecli set *)" "Bash(officecli add *)" "Bash(officecli move *)"
  "Bash(officecli swap *)" "Bash(officecli merge *)" "Bash(officecli refresh *)"
  "Bash(officecli dump *)" "Bash(officecli batch *)" "Bash(officecli add-part *)"
  "Bash(officecli open *)" "Bash(officecli close *)" "Bash(officecli watch *)"
  "Bash(officecli config get *)" "Bash(officecli plugins list *)"

  # ---- build / test misc ----
  "Bash(make *)" "Bash(cmake *)" "Bash(just *)" "Bash(task *)"

  # ---- go ----
  "Bash(go *)" "Bash(gofmt *)" "Bash(goimports *)" "Bash(golangci-lint *)"
  "Bash(staticcheck *)" "Bash(gotestsum *)" "Bash(gopls *)" "Bash(dlv *)"
  "Bash(mockgen *)" "Bash(govulncheck *)" "Bash(goreleaser check *)"

  # ---- containers ----
  # Broad allow, with the outward-publishing and destructive verbs pulled back
  # into ASK/DENY below. A narrower ask always wins over a broader allow.
  "Bash(docker *)" "Bash(docker-compose *)" "Bash(docker compose *)"
  "Bash(podman *)" "Bash(podman-compose *)" "Bash(buildah *)" "Bash(skopeo inspect *)"
  "Bash(dive *)" "Bash(hadolint *)"

  # ---- kubernetes ----
  "Bash(kubectl *)" "Bash(helm *)" "Bash(kustomize *)" "Bash(k9s *)"
  "Bash(kubectx *)" "Bash(kubens *)" "Bash(minikube *)" "Bash(kind *)"
  "Bash(stern *)" "Bash(kubeconform *)" "Bash(kubeval *)" "Bash(helmfile diff *)"

  # ---- infrastructure as code ----
  "Bash(terraform *)" "Bash(tofu *)" "Bash(terragrunt *)" "Bash(tflint *)"
  "Bash(terraform-docs *)" "Bash(infracost *)" "Bash(checkov *)" "Bash(tfsec *)"
  "Bash(packer validate *)" "Bash(packer fmt *)"

  # ---- virtualization / hypervisors ----
  # Broad allow for inspection, provisioning and boot; the destroy/undefine/
  # power verbs are pulled back into ASK below. Note that most Proxmox tools
  # only work as root, and `sudo` is denied — so on a hypervisor you are
  # relying on already being root, not on this list granting anything.
  "Bash(qm *)" "Bash(pct *)" "Bash(pvesm *)" "Bash(pvesh get *)"
  "Bash(pveversion *)" "Bash(pvecm status *)" "Bash(pvecm nodes *)" "Bash(pveperf *)"
  "Bash(virsh *)" "Bash(virt-what *)" "Bash(virt-df *)" "Bash(virt-inspector *)"
  "Bash(virt-viewer *)" "Bash(virt-top *)" "Bash(virt-xml *)"
  "Bash(VBoxManage *)" "Bash(vboxmanage *)" "Bash(VBoxHeadless *)"
  "Bash(qemu-img info *)" "Bash(qemu-img check *)" "Bash(qemu-img create *)"
  "Bash(qemu-img convert *)" "Bash(qemu-img map *)"
  "Bash(qemu-system-x86_64 *)" "Bash(qemu-system-aarch64 *)"
  "Bash(qemu-system-arm *)" "Bash(qemu-system-riscv64 *)" "Bash(qemu-ga *)"

  # ---- ansible ----
  # ansible-playbook itself is in ASK: it executes against real inventory.
  # The dry-run and read-only entry points are safe.
  "Bash(ansible-lint *)" "Bash(ansible-doc *)" "Bash(ansible-inventory *)"
  "Bash(ansible-config *)" "Bash(ansible-galaxy *)" "Bash(ansible-vault view *)"
  "Bash(ansible-playbook --check *)" "Bash(ansible-playbook --syntax-check *)"
  "Bash(ansible-playbook --list-tasks *)" "Bash(ansible-playbook --list-hosts *)"

  # ---- rust ----
  "Bash(cargo build *)" "Bash(cargo test *)" "Bash(cargo clippy *)" "Bash(cargo fmt *)"
  "Bash(cargo check *)" "Bash(cargo run *)" "Bash(cargo doc *)" "Bash(cargo tree *)"
  "Bash(cargo add *)" "Bash(cargo remove *)" "Bash(cargo update *)" "Bash(cargo bench *)"
  "Bash(cargo metadata *)" "Bash(cargo nextest *)" "Bash(cargo expand *)"
  "Bash(cargo audit *)" "Bash(cargo deny *)" "Bash(cargo machete *)"
  "Bash(rustc *)" "Bash(rustfmt *)" "Bash(rust-analyzer *)"
  # rustup can install toolchains over the network; only the read-only
  # subcommands are listed, the rest fall through to a prompt.
  "Bash(rustup show *)" "Bash(rustup which *)" "Bash(rustup toolchain list *)"
  "Bash(rustup component list *)" "Bash(rustup target list *)"

  # ---- c / c++ ----
  "Bash(gcc *)" "Bash(g++ *)" "Bash(cc *)" "Bash(c++ *)"
  "Bash(clang *)" "Bash(clang++ *)" "Bash(ninja *)" "Bash(ctest *)"
  "Bash(meson *)" "Bash(pkg-config *)" "Bash(./configure *)"
  "Bash(autoconf *)" "Bash(automake *)" "Bash(autoreconf *)" "Bash(libtool *)"
  "Bash(clang-format *)" "Bash(clang-tidy *)" "Bash(cppcheck *)" "Bash(iwyu *)"
  "Bash(gdb *)" "Bash(lldb *)" "Bash(valgrind *)" "Bash(bear *)"
  "Bash(objdump *)" "Bash(nm *)" "Bash(readelf *)" "Bash(ldd *)"
  "Bash(ar *)" "Bash(ranlib *)" "Bash(strip *)" "Bash(size *)" "Bash(addr2line *)"

  # ---- debugging & profiling (native: C, C++, Rust) ----
  # These inspect and instrument processes rather than change the world, so
  # they are allowed on the same footing as gdb, which was already here. Note
  # gdb and strace can attach to a running process with -p, so this is not a
  # narrower grant than what already existed. The kernel-wide tracers that
  # need root — bpftrace, bpftool, sysdig — are in ASK instead.
  "Bash(rust-gdb *)" "Bash(rust-lldb *)" "Bash(gdbserver *)" "Bash(cgdb *)"
  "Bash(rr *)" "Bash(strace *)" "Bash(ltrace *)" "Bash(perf *)"
  "Bash(heaptrack *)" "Bash(hotspot *)" "Bash(flamegraph *)"
  "Bash(coredumpctl *)" "Bash(catchsegv *)" "Bash(c++filt *)" "Bash(objcopy *)"
  "Bash(eu-readelf *)" "Bash(eu-stack *)" "Bash(pahole *)"
  # valgrind's companion report tools
  "Bash(ms_print *)" "Bash(callgrind_annotate *)" "Bash(cg_annotate *)"
  # coverage and profile reporting
  "Bash(gcov *)" "Bash(lcov *)" "Bash(genhtml *)" "Bash(gprof *)"
  "Bash(llvm-cov *)" "Bash(llvm-profdata *)" "Bash(llvm-symbolizer *)"
  # cargo has no broad allow, so debug subcommands are named individually
  "Bash(cargo miri *)" "Bash(cargo flamegraph *)" "Bash(cargo bloat *)"
  "Bash(cargo asm *)" "Bash(cargo llvm-cov *)" "Bash(cargo tarpaulin *)"
  "Bash(cargo careful *)" "Bash(cargo valgrind *)" "Bash(cargo instruments *)"
  "Bash(cargo profdata *)" "Bash(miri *)"

  # ---- gh (read-only subcommands only) ----
  # Every verb that writes to GitHub is in ASK; the irreversible and
  # credential-touching ones are in DENY. `gh api` is treated as a write tool
  # because -X POST/DELETE makes it one. Downloads and clones are reads: they
  # pull data onto this machine and change nothing on the remote.
  "Bash(gh pr view *)" "Bash(gh pr list *)" "Bash(gh pr diff *)"
  "Bash(gh pr checks *)" "Bash(gh pr status *)" "Bash(gh pr checkout *)"
  "Bash(gh issue view *)" "Bash(gh issue list *)" "Bash(gh issue status *)"
  "Bash(gh repo view *)" "Bash(gh repo list *)" "Bash(gh repo clone *)"
  "Bash(gh run view *)" "Bash(gh run list *)" "Bash(gh run watch *)"
  "Bash(gh run download *)"
  "Bash(gh workflow list *)" "Bash(gh workflow view *)"
  "Bash(gh release view *)" "Bash(gh release list *)" "Bash(gh release download *)"
  "Bash(gh label list *)" "Bash(gh search *)" "Bash(gh browse *)"
  "Bash(gh auth status *)" "Bash(gh status *)" "Bash(gh cache list *)"
  "Bash(gh gist list *)" "Bash(gh gist view *)" "Bash(gh gist clone *)"
  "Bash(gh alias list *)" "Bash(gh extension list *)" "Bash(gh completion *)"
  "Bash(gh config get *)" "Bash(gh config list *)" "Bash(gh org list *)"
  "Bash(gh variable list *)" "Bash(gh ruleset list *)" "Bash(gh ruleset view *)"
  "Bash(gh ruleset check *)" "Bash(gh project list *)" "Bash(gh project view *)"
  "Bash(gh project item-list *)" "Bash(gh project field-list *)"
  "Bash(gh codespace list *)" "Bash(gh codespace view *)"

  # ---- shell scripting ----
  # NOTE: bare `bash`/`sh` are NOT allowlisted on purpose — `bash -c '<anything>'`
  # would make every other rule in this file meaningless. Only the linters and
  # the no-op syntax check are listed. See README, "Honest limitations".
  "Bash(shellcheck *)" "Bash(shfmt *)" "Bash(bashate *)"
  "Bash(bash -n *)" "Bash(sh -n *)" "Bash(zsh -n *)"

  # ---- playwright ----
  # npx/bunx are NOT blanket-asked (see ASK below) so these specific forms can
  # be allowed; every other npx invocation still falls through to a prompt.
  "Bash(playwright *)" "Bash(npx playwright *)" "Bash(bunx playwright *)"
  "Bash(pnpm playwright *)" "Bash(pnpm exec playwright *)" "Bash(yarn playwright *)"
  "Bash(pytest --browser *)" "Bash(python -m playwright *)"

  # ---- read-only shell ----
  "Bash(ls *)" "Bash(pwd)" "Bash(cat *)" "Bash(head *)" "Bash(tail *)"
  "Bash(wc *)" "Bash(grep *)" "Bash(rg *)" "Bash(fd *)" "Bash(find *)"
  "Bash(which *)" "Bash(file *)" "Bash(stat *)" "Bash(du *)" "Bash(df *)"
  "Bash(env)" "Bash(date *)" "Bash(jq *)" "Bash(yq *)" "Bash(tree *)"
  "Bash(diff *)" "Bash(sort *)" "Bash(uniq *)" "Bash(echo *)"
)

# ─────────────────────────────────────────────────────────────────── ask rules
# Allowed, but always confirmed: reaches off-machine, escalates, or destroys
# work git cannot recover.
#
# An ask rule shadows a more specific allow rule when both match, so npx/bunx
# are NOT blanket-listed here — that would swallow "npx playwright test". Any
# npx invocation not explicitly allowed is unlisted, and unlisted already means
# "prompt", so the safety outcome is identical with none of the shadowing.
ASK=(
  "Bash(bash -c *)" "Bash(sh -c *)" "Bash(zsh -c *)"   # arbitrary execution
  "Bash(eval *)"   # NB: no bare "source *" here — it would shadow the
                   # venv-activation allow above and re-prompt every activate.
  # ---- gh: everything that writes to GitHub ----
  "Bash(gh api *)"
  "Bash(gh pr create *)" "Bash(gh pr merge *)" "Bash(gh pr close *)"
  "Bash(gh pr comment *)" "Bash(gh pr review *)" "Bash(gh pr edit *)"
  "Bash(gh pr ready *)" "Bash(gh pr reopen *)" "Bash(gh pr lock *)"
  "Bash(gh pr unlock *)" "Bash(gh pr update-branch *)"
  "Bash(gh issue create *)" "Bash(gh issue comment *)" "Bash(gh issue edit *)"
  "Bash(gh issue close *)" "Bash(gh issue reopen *)" "Bash(gh issue pin *)"
  "Bash(gh issue unpin *)" "Bash(gh issue transfer *)" "Bash(gh issue develop *)"
  "Bash(gh issue lock *)" "Bash(gh issue unlock *)"
  "Bash(gh repo create *)" "Bash(gh repo fork *)" "Bash(gh repo sync *)"
  "Bash(gh repo edit *)" "Bash(gh repo rename *)" "Bash(gh repo archive *)"
  "Bash(gh repo unarchive *)" "Bash(gh repo set-default *)" "Bash(gh repo deploy-key *)"
  "Bash(gh workflow run *)" "Bash(gh workflow enable *)" "Bash(gh workflow disable *)"
  "Bash(gh run rerun *)" "Bash(gh run cancel *)" "Bash(gh run delete *)"
  "Bash(gh release edit *)" "Bash(gh release upload *)" "Bash(gh release delete-asset *)"
  "Bash(gh gist create *)" "Bash(gh gist edit *)" "Bash(gh gist delete *)"
  "Bash(gh gist rename *)"
  "Bash(gh label create *)" "Bash(gh label edit *)" "Bash(gh label delete *)"
  "Bash(gh label clone *)"
  "Bash(gh project create *)" "Bash(gh project edit *)" "Bash(gh project copy *)"
  "Bash(gh project close *)" "Bash(gh project delete *)" "Bash(gh project link *)"
  "Bash(gh project unlink *)" "Bash(gh project item-add *)"
  "Bash(gh project item-edit *)" "Bash(gh project item-delete *)"
  "Bash(gh project item-archive *)" "Bash(gh project field-create *)"
  "Bash(gh project field-delete *)" "Bash(gh project mark-template *)"
  # Creates billable cloud resources and opens remote shells.
  "Bash(gh codespace create *)" "Bash(gh codespace ssh *)" "Bash(gh codespace code *)"
  "Bash(gh codespace cp *)" "Bash(gh codespace delete *)" "Bash(gh codespace stop *)"
  "Bash(gh codespace rebuild *)" "Bash(gh codespace ports *)" "Bash(gh codespace edit *)"
  "Bash(gh codespace logs *)" "Bash(gh codespace jupyter *)"
  # Installs and runs third-party code from GitHub — supply chain.
  "Bash(gh extension install *)" "Bash(gh extension upgrade *)"
  "Bash(gh extension remove *)" "Bash(gh extension create *)"
  "Bash(gh extension exec *)" "Bash(gh extension browse *)"
  # Changes local gh/git state or credentials.
  "Bash(gh auth login *)" "Bash(gh auth refresh *)" "Bash(gh auth switch *)"
  "Bash(gh auth setup-git *)" "Bash(gh config set *)"
  "Bash(gh alias set *)" "Bash(gh alias delete *)" "Bash(gh alias import *)"
  "Bash(gh cache delete *)"
  "Bash(cargo install *)" "Bash(rustup install *)" "Bash(rustup update *)"
  "Bash(go install *)" "Bash(dotnet tool install *)" "Bash(sdk install *)"
  "Bash(keytool *)"   # manages keystores and private keys
  # Kernel-wide tracing. Needs root, and observes every process on the box —
  # not just the one you are debugging. Unlike gdb/strace, the scope is the
  # whole system, so it gets a look before it runs.
  "Bash(bpftrace *)" "Bash(bpftool *)" "Bash(sysdig *)" "Bash(trace-cmd *)"
  "Bash(perf trace *)"
  # Drops a database. Overrides the broad rails/rake allows above.
  "Bash(rails db:drop *)" "Bash(rails db:reset *)" "Bash(rails destroy *)"
  "Bash(rake db:drop *)" "Bash(rake db:reset *)"
  "Bash(dotnet nuget add source *)"   # adds a package feed — supply chain
  # The npx-equivalents. These fetch and execute arbitrary remote packages
  # exactly as npx does, and would otherwise slip through the broad
  # npm/pnpm/yarn/bun allows above. Narrower ask beats broader allow.
  "Bash(npm exec *)" "Bash(pnpm dlx *)" "Bash(yarn dlx *)" "Bash(bun x *)"
  # Reaches Expo's build servers (and can cost money).
  "Bash(eas build *)" "Bash(expo login *)"

  # ---- officecli: irreversible edits and environment changes ----
  # `install` places a binary, skills and an MCP server into your environment;
  # `mcp` starts a server that exposes this capability to other tools. Neither
  # is document editing, and both deserve a look before they run.
  "Bash(officecli remove *)" "Bash(officecli raw-set *)"
  "Bash(officecli install *)" "Bash(officecli mcp *)"
  "Bash(officecli config set *)"

  # ---- database clients and migrations ----
  # Listed explicitly rather than left unlisted so the intent is documented:
  # these connect to a server that may be production, and the allowlist cannot
  # inspect the SQL they carry.
  "Bash(psql *)" "Bash(pgcli *)" "Bash(mysql *)" "Bash(mycli *)"
  "Bash(mysqladmin *)" "Bash(sqlcmd *)" "Bash(sqlplus *)" "Bash(bcp *)"
  "Bash(clickhouse-client *)" "Bash(cockroach sql *)" "Bash(usql *)"
  "Bash(mongosh *)" "Bash(mongo *)" "Bash(redis-cli *)" "Bash(valkey-cli *)"
  "Bash(cqlsh *)" "Bash(influx *)" "Bash(etcdctl *)" "Bash(cypher-shell *)"
  "Bash(elasticdump *)" "Bash(createdb *)"
  # Bulk data in or out.
  "Bash(pg_dump *)" "Bash(pg_restore *)" "Bash(mysqldump *)"
  "Bash(mongodump *)" "Bash(mongorestore *)" "Bash(mongoimport *)"
  "Bash(mongoexport *)"
  # Migrations that write to a schema.
  "Bash(flyway migrate *)" "Bash(flyway undo *)" "Bash(flyway repair *)"
  "Bash(liquibase update *)" "Bash(liquibase rollback *)"
  "Bash(alembic upgrade *)" "Bash(alembic downgrade *)" "Bash(alembic stamp *)"
  "Bash(prisma migrate *)" "Bash(prisma db push *)" "Bash(prisma db pull *)"
  "Bash(dbt run *)" "Bash(dbt build *)" "Bash(dbt seed *)" "Bash(dbt snapshot *)"
  "Bash(knex migrate *)" "Bash(sequelize db:migrate *)"
  "Bash(typeorm migration:run *)" "Bash(typeorm migration:revert *)"
  "Bash(atlas schema apply *)" "Bash(migrate up *)" "Bash(migrate down *)"
  "Bash(goose up *)" "Bash(goose down *)" "Bash(dbmate up *)"
  "Bash(sqitch deploy *)" "Bash(sqitch revert *)"
  "Bash(git reset --hard *)" "Bash(git clean *)"
  "Bash(git rebase *)" "Bash(git filter-branch *)"
  "Bash(aws *)" "Bash(gcloud *)" "Bash(az *)"
  "Bash(ssh *)" "Bash(scp *)" "Bash(rsync *)"
  "Bash(chmod *)" "Bash(chown *)"

  # ---- the verbs that change reality ----
  # These override the broad container/k8s/IaC allows above. Everything else in
  # those toolchains — plan, diff, get, describe, logs, build, lint — runs free.
  "Bash(terraform apply *)" "Bash(terraform destroy *)" "Bash(terraform import *)"
  "Bash(terraform state rm *)" "Bash(terraform state mv *)" "Bash(terraform taint *)"
  "Bash(tofu apply *)" "Bash(tofu destroy *)"
  "Bash(terragrunt apply *)" "Bash(terragrunt destroy *)" "Bash(terragrunt run-all *)"
  "Bash(kubectl apply *)" "Bash(kubectl delete *)" "Bash(kubectl patch *)"
  "Bash(kubectl edit *)" "Bash(kubectl replace *)" "Bash(kubectl scale *)"
  "Bash(kubectl exec *)" "Bash(kubectl drain *)" "Bash(kubectl cordon *)"
  "Bash(kubectl rollout undo *)" "Bash(kubectl rollout restart *)"
  "Bash(helm install *)" "Bash(helm upgrade *)" "Bash(helm uninstall *)"
  "Bash(helm rollback *)" "Bash(helm delete *)"
  # NB: no bare "ansible-playbook *" here — it would shadow the --check and
  # --syntax-check allows above. Unlisted already prompts, so a real playbook
  # run still stops for confirmation without killing the dry-run allowlist.
  "Bash(docker system prune *)" "Bash(docker volume rm *)" "Bash(docker rm -f *)"
  "Bash(podman system prune *)" "Bash(podman volume rm *)"
  "Bash(minikube delete *)" "Bash(kind delete *)"

  # ---- virtualization: the destructive verbs ----
  # `virsh destroy` is a hard power-off, not a delete; `undefine` is the delete.
  # Both stop here. So does anything that writes to a guest disk image out from
  # under a running VM, and qemu-nbd, which maps an image onto a host device.
  "Bash(qm destroy *)" "Bash(qm stop *)" "Bash(qm reset *)" "Bash(qm rollback *)"
  "Bash(qm set *)" "Bash(qm migrate *)" "Bash(qm resize *)" "Bash(qm template *)"
  "Bash(pct destroy *)" "Bash(pct stop *)" "Bash(pct set *)" "Bash(pct migrate *)"
  "Bash(pvesh create *)" "Bash(pvesh delete *)" "Bash(pvesh set *)"
  "Bash(pvesm remove *)" "Bash(pveum *)"
  "Bash(virsh destroy *)" "Bash(virsh undefine *)" "Bash(virsh shutdown *)"
  "Bash(virsh reset *)" "Bash(virsh reboot *)" "Bash(virsh vol-delete *)"
  "Bash(virsh pool-destroy *)" "Bash(virsh pool-undefine *)"
  "Bash(virsh snapshot-delete *)" "Bash(virsh snapshot-revert *)"
  "Bash(virsh blockcommit *)" "Bash(virsh detach-disk *)"
  "Bash(virsh net-destroy *)" "Bash(virsh net-undefine *)"
  "Bash(VBoxManage unregistervm *)" "Bash(VBoxManage controlvm *)"
  "Bash(VBoxManage modifyvm *)" "Bash(VBoxManage snapshot *)"
  "Bash(VBoxManage closemedium *)" "Bash(VBoxManage storagectl *)"
  "Bash(qemu-nbd *)" "Bash(qemu-img resize *)" "Bash(qemu-img snapshot *)"
  "Bash(qemu-img commit *)" "Bash(qemu-img rebase *)" "Bash(qemu-img amend *)"
  "Bash(guestfish *)" "Bash(guestmount *)" "Bash(virt-install *)"
  "Bash(virt-sysprep *)" "Bash(virt-resize *)" "Bash(virt-sparsify *)"
)

# ─────────────────────────────────────────────────────────────────── deny rules
DENY=(
  "Bash(sudo *)" "Bash(su *)" "Bash(doas *)"
  "Bash(rm -rf /*)" "Bash(rm -rf ~*)" "Bash(mkfs*)" "Bash(dd if=*)"
  "Bash(npm publish *)" "Bash(yarn publish *)" "Bash(pnpm publish *)"
  "Bash(mvn deploy *)" "Bash(mvn release:*)"
  "Bash(gradle publish*)" "Bash(./gradlew publish*)"
  "Bash(twine upload *)" "Bash(poetry publish *)" "Bash(cargo publish *)"
  "Bash(git push --mirror *)" "Bash(git push --all *)"
  "Bash(gh release create *)" "Bash(gh secret *)" "Bash(gh variable set *)"
  "Bash(gh repo delete *)" "Bash(gh auth token *)" "Bash(gh auth logout *)"
  "Bash(gh ssh-key add *)" "Bash(gh gpg-key add *)"
  "Bash(gh ssh-key delete *)" "Bash(gh gpg-key delete *)"
  "Bash(gh release delete *)" "Bash(gh variable delete *)"
  "Bash(gh ruleset delete *)"
  "Bash(cargo login *)" "Bash(cargo owner *)" "Bash(cargo yank *)"
  # Publishing images / logging in to registries — outward, same class as
  # npm publish. Denied rather than asked so an agent cannot push an image.
  "Bash(docker push *)" "Bash(docker login *)" "Bash(podman push *)"
  "Bash(podman login *)" "Bash(buildah push *)" "Bash(skopeo copy *)"
  "Bash(helm push *)" "Bash(helm repo add *)"
  # Cluster membership and auth changes on a hypervisor — effectively
  # unrecoverable, and never something an agent should reach for.
  "Bash(pvecm delnode *)" "Bash(pvecm add *)" "Bash(pveum user delete *)"
  "Bash(pveum role delete *)" "Bash(pveum acl delete *)"
  "Bash(virsh pool-delete *)" "Bash(VBoxManage unregistervm --delete *)"
  # Package registries and their credentials — same class as npm publish.
  "Bash(gem push *)" "Bash(gem signin *)" "Bash(gem owner *)" "Bash(gem yank *)"
  "Bash(dotnet nuget push *)" "Bash(nuget push *)" "Bash(nuget setapikey *)"
  "Bash(expo publish *)" "Bash(eas submit *)" "Bash(npm adduser *)"
  # Wipes a schema or database outright. `flyway clean` drops every object in
  # the schema and is the classic way to lose a production database.
  # NOTE: redis-cli command names are case-insensitive but these rules are not,
  # so both spellings are listed. This is a best-effort catch, not a boundary —
  # see "Honest limitations" in the README.
  "Bash(dropdb *)" "Bash(flyway clean *)" "Bash(liquibase dropAll *)"
  "Bash(prisma migrate reset *)" "Bash(prisma db execute *)"
  "Bash(redis-cli flushall *)" "Bash(redis-cli FLUSHALL *)"
  "Bash(redis-cli flushdb *)" "Bash(redis-cli FLUSHDB *)"
  "Bash(curl * | sh)" "Bash(curl * | bash)" "Bash(wget * | sh)"
  "Read(//home/**/.ssh/**)" "Read(//home/**/.aws/credentials)"
  "Read(//home/**/.config/gcloud/**)" "Read(//**/.env.production)"
)

# ─────────────────────────────────────────────────────────────────── retired
# Rules this project shipped once and no longer does — usually because a
# narrow rule was replaced by a broader one. Uninstall subtracts these too.
#
# Without this list they become permanent orphans: an install from an older
# version writes them, a later --uninstall does not know about them, and they
# sit in the user's config forever. Whenever you REMOVE or REPLACE an entry in
# ALLOW/ASK/DENY, move the old text here. Never delete from this list.
# It is also subtracted on INSTALL, before the current rules are merged in.
# That matters for RECLASSIFIED rules: "Bash(docker *)" used to be in ASK and
# is now in ALLOW. Without the purge, an older install leaves it in ask, the
# new install adds it to allow, and it ends up in BOTH — where ask wins and the
# allow rule silently does nothing. Purge-then-merge lands it in allow alone.
RETIRED=(
  # No longer shipped in any list.
  # v1 had these three; superseded by "Bash(go *)" when Go was filled out.
  "Bash(go build *)" "Bash(go test *)" "Bash(go vet *)"
  # Replaced by explicit carve-outs ("Bash(npx playwright *)" etc.) so that a
  # broad ask would stop shadowing them.
  "Bash(npx *)" "Bash(bunx *)"

  # Reclassified ASK -> ALLOW when the container/k8s/IaC toolchains were built
  # out with narrow asks on the destructive verbs instead.
  "Bash(docker *)" "Bash(podman *)" "Bash(kubectl *)" "Bash(helm *)"
  "Bash(terraform *)"
)

# ──────────────────────────────────────────────────────── fully permissive mode
# --permissive writes these INSTEAD of ALLOW/ASK/DENY, and clears ask and deny
# to empty. Not "allow a lot" — allow everything, gate nothing.
#
# Claude's real switch is permissions.defaultMode = "bypassPermissions", which
# skips rule evaluation wholesale. The catch-all rules below are belt and braces
# for the case where an enterprise managed-settings policy refuses defaultMode:
# the rules still stand on their own if the mode is stripped.
PERMIT_ALLOW=(
  "Bash(*)" "Read(*)" "Edit(*)" "Write(*)" "Glob(*)" "Grep(*)"
  "WebFetch(*)" "WebSearch(*)" "NotebookEdit(*)" "Task(*)"
)

# agy's own syntax. Its documented default is to ASK on command(*) — every shell
# command — so the same pattern in allow is the exact inverse of that default.
# Written out rather than run through to_agy(), which strips the bare "*".
PERMIT_AGY=( "command(*)" "read_file(*)" "write_file(*)" )

# Codex has no rules to widen, so permissive means its two policy knobs. These
# are the config.toml equivalent of --dangerously-bypass-approvals-and-sandbox.
PERMIT_CODEX_TOML=(
  'approval_policy = "never"'
  'sandbox_mode = "danger-full-access"'
)

# config.toml is TOML, not JSON, so it is edited by line with markers instead of
# jq. Anything between these two lines belongs to this script and is replaced on
# reinstall / removed on uninstall. Top-level keys we displace are commented out
# with DISABLED_TAG rather than deleted, so uninstall can put them back.
TOML_BEGIN="# >>> agent-guardrails permissive >>>"
TOML_END="# <<< agent-guardrails permissive <<<"
DISABLED_TAG="#agent-guardrails-disabled# "
# Project trust gets its own marker, one block per path. Deliberately NOT
# prefixed by TOML_BEGIN: reinstalling the policy block must not sweep away the
# trust blocks that earlier --project runs left in the same global config.
TRUST_BEGIN="# >>> agent-guardrails permissive trust: "
# Prefix that matches every block this script writes, for uninstall.
ANY_BEGIN="# >>> agent-guardrails"

# ───────────────────────────────────────────────────────────────────── plumbing

arr() { printf '%s\n' "$@" | jq -R . | jq -s .; }

# Translate Claude rule syntax into agy's.
#   Bash(git status *) -> command(git status)      Read(//p/**) -> read_file(p/*)
# agy's built-ins (command(npm test), command(tail -F)) are bare command
# prefixes, so the trailing " *" is dropped rather than carried over.
to_agy() {
  local r out
  for r in "$@"; do
    case "$r" in
      Bash\(*\)) out="${r#Bash(}"; out="${out%)}"; out="${out% \*}"; out="${out%\*}"
                 out="${out%% }"; [ -n "$out" ] && printf 'command(%s)\n' "$out" ;;
      Read\(*\)) out="${r#Read(}"; out="${out%)}"; out="${out#/}"
                 printf 'read_file(%s)\n' "${out//\*\*/\*}" ;;
    esac
  done | sort -u
}

note() { printf '  %s\n' "$*"; }
backup() { cp "$1" "$1.bak"; }
ensure_json() {
  mkdir -p "$(dirname "$1")"
  [ -f "$1" ] || printf '%s\n' "${2:-\{\}}" > "$1"
  jq -e . "$1" >/dev/null || { echo "$1 is not valid JSON — fix it first" >&2; exit 1; }
}

# ── config.toml editing (Codex only) ─────────────────────────────────────────
# TOML, so no jq. Everything this script writes lives between marker comments
# and every key it displaces is commented out with DISABLED_TAG, which makes
# both re-install and uninstall exact line operations rather than guesswork.

# Drop the blank lines left where a block used to be, at the top and bottom of
# the file, so repeated install/uninstall cycles do not drift the file downward.
trim_blanks() {
  awk 'NF == 0 { if (seen) blanks++; next }
       { while (blanks-- > 0) print ""; blanks = 0; seen = 1; print }'
}

# Print $1 with every guardrails block whose opening marker starts with $2
# removed. Blocks never nest, so any closing marker ends the block that is open.
# $3=1 also un-comments the keys we displaced; pass 0 when the policy block is
# staying put, or the restored key becomes a duplicate of the one inside it.
toml_filter() { # $1 = file, $2 = opening-marker prefix, $3 = restore displaced keys
  awk -v b="$2" -v tag="$DISABLED_TAG" -v restore="$3" '
    index($0, b) == 1 { skip = 1; next }
    skip && index($0, "# <<< agent-guardrails") == 1 { skip = 0; next }
    skip { next }
    restore == 1 && index($0, tag) == 1 { print substr($0, length(tag) + 1); next }
    { print }
  ' "$1"
}

# Write the permissive policy block into a config.toml.
toml_permit() { # $1 = config.toml
  local f=$1 body
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || : > "$f"
  backup "$f"
  # Displace any top-level approval_policy / sandbox_mode: TOML rejects a
  # duplicate key and ours has to win. Only above the first [table] — the same
  # key under [projects."x"] is a different key and is left alone.
  body=$(toml_filter "$f.bak" "$TOML_BEGIN" 1 | awk -v tag="$DISABLED_TAG" '
    /^[[:space:]]*\[/ { intable = 1 }
    !intable && /^[[:space:]]*(approval_policy|sandbox_mode)[[:space:]]*=/ { print tag $0; next }
    { print }' | trim_blanks)
  # Prepend, because a top-level key must come before the first table.
  { printf '%s\n' "$TOML_BEGIN" "${PERMIT_CODEX_TOML[@]}" "$TOML_END" ""
    printf '%s\n' "$body"; } > "$f"
}

# Trust a project path in the GLOBAL codex config — trust_level lives in the
# [projects.*] table there, and there is nowhere project-local to put it.
toml_trust_project() { # $1 = ~/.codex/config.toml, $2 = project path
  local f=$1 p=$2
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || : > "$f"
  if grep -qF "[projects.\"$p\"]" "$f"; then
    note "        [projects.\"$p\"] already in $f — left as is"
    return
  fi
  backup "$f"
  printf '\n%s\n[projects."%s"]\ntrust_level = "trusted"\n%s\n' \
    "$TRUST_BEGIN$p" "$p" "$TOML_END" >> "$f"
  note "        + [projects.\"$p\"] trust_level = trusted -> $f"
}

# Undo whatever toml_permit / toml_trust_project put in $1. Returns 1 (and
# touches nothing) when the file holds nothing of ours.
toml_unpermit() { # $1 = config.toml, $2 = opening-marker prefix, $3 = restore displaced keys
  local f=$1 pre=$2 restore=${3:-1}
  [ -f "$f" ] || return 1
  grep -qF "$pre" "$f" || { [ "$restore" -eq 1 ] && grep -qF "$DISABLED_TAG" "$f"; } || return 1
  backup "$f"
  toml_filter "$f.bak" "$pre" "$restore" | trim_blanks > "$f"
}

# ── removers ──────────────────────────────────────────────────────────────────
# Uninstall works by SUBTRACTING exactly the rules this script knows it adds,
# not by restoring <file>.bak. The .bak is single-level and is overwritten on
# every run, so after two installs it no longer holds your original state.
# Subtraction is idempotent and leaves rules you added yourself untouched.
#
# Caveat: if one of your own rules is byte-identical to one of ours, it goes
# too. There is no way to tell them apart after the fact.

unwrite_claude() { # $1 = settings.json path
  local f=$1
  [ -f "$f" ] || { note "claude  skipped ($f not found)"; return; }
  jq -e . "$f" >/dev/null || { echo "$f is not valid JSON" >&2; exit 1; }
  backup "$f"
  jq \
    --argjson allow "$(arr "${ALLOW[@]}" "${PERMIT_ALLOW[@]}")" \
    --argjson ask   "$(arr "${ASK[@]}")" \
    --argjson deny  "$(arr "${DENY[@]}")" \
    --argjson retired "$(arr "${RETIRED[@]}")" '
    if .permissions then
      .permissions.allow = ((.permissions.allow // []) - $allow - $retired)
      | .permissions.ask = ((.permissions.ask // []) - $ask - $retired)
      | .permissions.deny = ((.permissions.deny // []) - $deny - $retired)
      | (if .permissions.defaultMode == "bypassPermissions"
         then del(.permissions.defaultMode) else . end)
      | .permissions |= with_entries(select(.value != []))
      | if (.permissions | length) == 0 then del(.permissions) else . end
    else . end
    | if .hooks.PreToolUse then
        .hooks.PreToolUse |= (
          map(.hooks //= [] | .hooks |= map(select(.command | test("git-push-guard\\.sh") | not)))
          | map(select(.hooks | length > 0)))
        | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
        | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end
  ' "$f.bak" > "$f"
  note "claude  cleaned $f"
}

unwrite_codex() { # $1 = .codex dir
  local f="$1/hooks.json"
  # Permissive artifacts live in config.toml, which may exist even when
  # hooks.json does not — clean it first and independently.
  if toml_unpermit "$1/config.toml" "$ANY_BEGIN" 1; then
    note "codex   cleaned $1/config.toml (permissive policy + trust blocks)"
  fi
  [ -f "$f" ] || { note "codex   skipped ($f not found)"; return; }
  jq -e . "$f" >/dev/null || { echo "$f is not valid JSON" >&2; exit 1; }
  backup "$f"
  jq '
    if .hooks.PreToolUse then
      .hooks.PreToolUse |= (
        map(.hooks //= [] | .hooks |= map(select(.command | test("git-push-guard\\.sh") | not)))
        | map(select(.hooks | length > 0)))
      | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
    else . end
  ' "$f.bak" > "$f"
  note "codex   cleaned $f"
  note "        [features] hooks = true left in config.toml — other hooks may need it"
}

unwrite_agy() { # $1 = settings.json path
  local f=$1
  [ -f "$f" ] || { note "agy     skipped ($f not found)"; return; }
  jq -e . "$f" >/dev/null || { echo "$f is not valid JSON" >&2; exit 1; }
  backup "$f"
  jq \
    --argjson allow "$( { to_agy "${ALLOW[@]}"; printf '%s\n' "${PERMIT_AGY[@]}"; } | jq -R . | jq -s .)" \
    --argjson ask   "$(to_agy "${ASK[@]}"   | jq -R . | jq -s .)" \
    --argjson deny  "$(to_agy "${DENY[@]}"  | jq -R . | jq -s .)" \
    --argjson retired "$(to_agy "${RETIRED[@]}" | jq -R . | jq -s .)" '
    if .permissions then
      .permissions.allow = ((.permissions.allow // []) - $allow - $retired)
      | .permissions.ask = ((.permissions.ask // []) - $ask - $retired)
      | .permissions.deny = ((.permissions.deny // []) - $deny - $retired)
      | .permissions |= with_entries(select(.value != []))
      | if (.permissions | length) == 0 then del(.permissions) else . end
    else . end
  ' "$f.bak" > "$f"
  note "agy     cleaned $f"
  note "        trustedWorkspaces left alone — remove paths yourself if you want"
}

# ── permissive writers ────────────────────────────────────────────────────────
# These do NOT merge. Merging is what the normal path does; here the whole point
# is that nothing survives to gate a command, so ask and deny are set to empty
# and the push guard is stripped out. Rules of your own in those lists go too —
# that is the mode, not an accident. <file>.bak is your one way back.

permit_claude() { # $1 = settings.json path
  local f=$1
  ensure_json "$f" '{}'
  backup "$f"
  jq --argjson allow "$(arr "${PERMIT_ALLOW[@]}")" '
    .permissions //= {}
    | .permissions.allow = $allow
    | .permissions.ask = []
    | .permissions.deny = []
    | .permissions.defaultMode = "bypassPermissions"
    | if .hooks.PreToolUse then
        .hooks.PreToolUse |= (
          map(.hooks //= [] | .hooks |= map(select(.command | test("git-push-guard\\.sh") | not)))
          | map(select(.hooks | length > 0)))
        | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
        | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end
  ' "$f.bak" > "$f"
  note "claude  $f  (bypassPermissions, ask/deny cleared, guard removed)"
}

permit_codex() { # $1 = .codex dir, $2 = optional project path to trust
  local d=$1 p=${2:-} f="$1/hooks.json"
  toml_permit "$d/config.toml"
  note "codex   $d/config.toml  (approval_policy=never, sandbox_mode=danger-full-access)"
  [ -n "$p" ] && toml_trust_project "${HOME}/.codex/config.toml" "$p"
  # The guard is the only gate Codex has, so permissive means taking it out.
  if [ -f "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
    backup "$f"
    jq '
      if .hooks.PreToolUse then
        .hooks.PreToolUse |= (
          map(.hooks //= [] | .hooks |= map(select(.command | test("git-push-guard\\.sh") | not)))
          | map(select(.hooks | length > 0)))
        | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
      else . end
    ' "$f.bak" > "$f"
    note "        guard removed from $f"
  fi
}

permit_agy() { # $1 = settings.json path, $2 = optional workspace to trust
  local f=$1 ws=${2:-}
  [ -f "$f" ] || { note "agy     skipped ($f not found — run agy once first)"; return; }
  jq -e . "$f" >/dev/null || { echo "$f is not valid JSON" >&2; exit 1; }
  backup "$f"
  jq --argjson allow "$(printf '%s\n' "${PERMIT_AGY[@]}" | jq -R . | jq -s .)" \
     --arg ws "$ws" '
    .permissions //= {}
    | .permissions.allow = $allow
    | .permissions.ask = []
    | .permissions.deny = []
    | .allowNonWorkspaceAccess = true
    | if $ws != "" then .trustedWorkspaces = ((.trustedWorkspaces // []) + [$ws] | unique)
      else . end
  ' "$f.bak" > "$f"
  note "agy     $f  (command(*) allowed, ask/deny cleared, allowNonWorkspaceAccess)"
  [ -n "$ws" ] && note "        + trustedWorkspaces += $ws"
  return 0
}

# ── writers ───────────────────────────────────────────────────────────────────

write_claude() { # $1 = settings.json path
  local f=$1
  ensure_json "$f" '{}'
  backup "$f"
  # $permit is subtracted for the same reason as $retired: installing over a
  # previous --permissive run has to take the catch-alls and bypassPermissions
  # back out, or the rules below are written into a config that ignores them.
  jq \
    --argjson allow "$(arr "${ALLOW[@]}")" \
    --argjson ask   "$(arr "${ASK[@]}")" \
    --argjson deny  "$(arr "${DENY[@]}")" \
    --argjson retired "$(arr "${RETIRED[@]}" "${PERMIT_ALLOW[@]}")" \
    --arg cmd "bash '$GUARD'" --argjson hook "$DO_HOOK" '
    .permissions //= {}
    | (if .permissions.defaultMode == "bypassPermissions"
       then del(.permissions.defaultMode) else . end)
    | .permissions.allow = (((.permissions.allow // []) - $retired) + $allow | unique)
    | .permissions.ask   = (((.permissions.ask   // []) - $retired) + $ask   | unique)
    | .permissions.deny  = (((.permissions.deny  // []) - $retired) + $deny  | unique)
    | if $hook == 1 then
        .hooks //= {} | .hooks.PreToolUse //= []
        | .hooks.PreToolUse |= (
            map(.hooks //= [] | .hooks |= map(select(.command | test("git-push-guard\\.sh") | not)))
            | map(select(.hooks | length > 0))
            + [{matcher: "Bash",
                hooks: [{type: "command", command: $cmd, timeout: 10,
                         statusMessage: "Checking push target..."}]}])
      else . end
  ' "$f.bak" > "$f"
  note "claude  $f  (+guard)"
}

write_codex() { # $1 = .codex dir
  local d=$1 f="$1/hooks.json" toml="$1/config.toml"
  # Installing over a previous --permissive run: put approval_policy and
  # sandbox_mode back before adding the guard, or the guard is the only thing
  # standing between the agent and full access.
  if toml_unpermit "$toml" "$TOML_BEGIN" 1; then
    note "codex   reverted permissive policy in $toml"
  fi
  [ "$DO_HOOK" -eq 1 ] || { note "codex   skipped (--no-hook; Codex gets no rules, only the guard)"; return; }
  ensure_json "$f" '{"hooks":{}}'
  backup "$f"
  # Codex PreToolUse accepts permissionDecision "deny" and nothing else.
  jq --arg cmd "bash '$GUARD' --deny-only" '
    .hooks //= {} | .hooks.PreToolUse //= []
    | .hooks.PreToolUse |= (
        map(select((.hooks // []) | any(.command == $cmd) | not))
        + [{matcher: "shell",
            hooks: [{type: "command", command: $cmd, timeout: 10,
                     statusMessage: "Checking push target..."}]}])
  ' "$f.bak" > "$f"
  note "codex   $f  (guard only, deny-only mode)"

  if [ -f "$toml" ] && grep -qE '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true' "$toml"; then
    :
  elif [ -f "$toml" ] && grep -qE '^\[features\]' "$toml"; then
    note "        ! add 'hooks = true' under the existing [features] in $toml"
  else
    printf '\n[features]\nhooks = true\n' >> "$toml"
    note "        + [features] hooks = true -> $toml"
  fi
}

write_agy() { # $1 = settings.json path, $2 = optional workspace to trust
  local f=$1 ws=${2:-}
  [ -f "$f" ] || { note "agy     skipped ($f not found — run agy once first)"; return; }
  jq -e . "$f" >/dev/null || { echo "$f is not valid JSON" >&2; exit 1; }
  backup "$f"
  jq \
    --argjson allow "$(to_agy "${ALLOW[@]}" | jq -R . | jq -s .)" \
    --argjson ask   "$(to_agy "${ASK[@]}"   | jq -R . | jq -s .)" \
    --argjson deny  "$(to_agy "${DENY[@]}"  | jq -R . | jq -s .)" \
    --argjson retired "$( { to_agy "${RETIRED[@]}"; printf '%s\n' "${PERMIT_AGY[@]}"; } | jq -R . | jq -s .)" \
    --arg ws "$ws" '
    .permissions //= {}
    | .permissions.allow = (((.permissions.allow // []) - $retired) + $allow | unique)
    | .permissions.ask   = (((.permissions.ask   // []) - $retired) + $ask   | unique)
    | .permissions.deny  = (((.permissions.deny  // []) - $retired) + $deny  | unique)
    | if $ws != "" then .trustedWorkspaces = ((.trustedWorkspaces // []) + [$ws] | unique)
      else . end
  ' "$f.bak" > "$f"
  note "agy     $f"
  [ -n "$ws" ] && note "        + trustedWorkspaces += $ws  (agy has no per-project settings file)"
  note "        no guard — agy hooks have no permissionDecision protocol"
}

# ───────────────────────────────────────────────────────────────────── dispatch

# The whole header block is the help text, so print it up to the first line
# that is not a comment rather than a hardcoded line count.
usage() { awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"; exit "${1:-0}"; }

SCOPE=""; PROJ=""; DO_HOOK=1; MANAGED=0; UNINSTALL=0; PERMISSIVE=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --global|--user)      SCOPE="global" ;;
    --project|--workspace) SCOPE="project"
                          case "${2:-}" in -*|"") ;; *) PROJ="$2"; shift ;; esac ;;
    --print)              SCOPE="print" ;;
    --managed)            MANAGED=1 ;;
    --no-hook)            DO_HOOK=0 ;;
    --uninstall)          UNINSTALL=1 ;;
    --permissive)         PERMISSIVE=1 ;;
    -y|--yes)             ASSUME_YES=1 ;;
    -h|--help)            usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[ -n "$SCOPE" ] || usage 1

if [ "$PERMISSIVE" -eq 1 ]; then
  # --managed pins policy centrally so users cannot loosen it; --permissive is
  # loosening it as far as it goes. Nothing sensible to emit for both.
  [ "$MANAGED" -eq 1 ] && { echo "--managed and --permissive are contradictory" >&2; exit 1; }
  # There is no guard in permissive mode, so --no-hook is already implied.
  DO_HOOK=0
fi

if [ "$SCOPE" = "print" ] && [ "$PERMISSIVE" -eq 1 ]; then
  jq -n \
    --argjson allow "$(arr "${PERMIT_ALLOW[@]}")" \
    --argjson agy_allow "$(printf '%s\n' "${PERMIT_AGY[@]}" | jq -R . | jq -s .)" \
    --arg toml "$(printf '%s\n' "${PERMIT_CODEX_TOML[@]}")" '
    {claude: {permissions: {allow: $allow, ask: [], deny: [],
                            defaultMode: "bypassPermissions"}},
     agy: {permissions: {allow: $agy_allow, ask: [], deny: []},
           allowNonWorkspaceAccess: true},
     codex: ("config.toml: " + ($toml | gsub("\n"; "; "))
             + " (+ [projects.\"<path>\"] trust_level = trusted for --project)"),
     guard: "removed — permissive mode installs no push guard"}'
  exit 0
fi

if [ "$SCOPE" = "print" ]; then
  jq -n \
    --argjson allow "$(arr "${ALLOW[@]}")" --argjson ask "$(arr "${ASK[@]}")" \
    --argjson deny "$(arr "${DENY[@]}")" --argjson managed "$MANAGED" \
    --argjson agy_allow "$(to_agy "${ALLOW[@]}" | jq -R . | jq -s .)" \
    --argjson agy_ask "$(to_agy "${ASK[@]}" | jq -R . | jq -s .)" \
    --argjson agy_deny "$(to_agy "${DENY[@]}" | jq -R . | jq -s .)" '
    {claude: ({permissions: {allow: $allow, ask: $ask, deny: $deny}}
              + (if $managed == 1 then {allowManagedPermissionRulesOnly: true} else {} end)),
     agy: {permissions: {allow: $agy_allow, ask: $agy_ask, deny: $agy_deny}},
     codex: "no allowlist — approval_policy x sandbox_mode x trust_level; enterprise: /etc/codex/managed_config.toml"}'
  exit 0
fi

if [ "$UNINSTALL" -eq 1 ]; then
  if [ "$SCOPE" = "global" ]; then
    echo "uninstall: global (user-level)"
    unwrite_claude "${HOME}/.claude/settings.json"
    unwrite_codex  "${HOME}/.codex"
    unwrite_agy    "${HOME}/.gemini/antigravity-cli/settings.json"
  else
    PROJ=$(cd "${PROJ:-$PWD}" && pwd)
    echo "uninstall: project ($PROJ)"
    unwrite_claude "$PROJ/.claude/settings.json"
    unwrite_codex  "$PROJ/.codex"
    unwrite_agy    "${HOME}/.gemini/antigravity-cli/settings.json"
    # A --project --permissive run trusts the path in the GLOBAL codex config,
    # because that is the only place [projects.*] exists. Take just that block
    # back out; leave the rest of the global config alone.
    if toml_unpermit "${HOME}/.codex/config.toml" "$TRUST_BEGIN$PROJ" 0; then
      note "codex   removed [projects.\"$PROJ\"] trust block from ${HOME}/.codex/config.toml"
    fi
  fi
  echo "guard script left at $GUARD"
  echo "  remove it yourself if nothing else uses it:  rm '$GUARD'"
  echo "backups written alongside each file as <file>.bak"
  exit 0
fi

if [ "$PERMISSIVE" -eq 1 ]; then
  [ "$SCOPE" = "project" ] && PROJ=$(cd "${PROJ:-$PWD}" && pwd)
  cat >&2 <<EOF

  ⚠  FULLY PERMISSIVE — this REMOVES the guardrails, it does not scope them.

     target        $([ "$SCOPE" = "global" ] && echo "every project on this machine (global)" || echo "$PROJ")
     allow         everything: Bash(*), Read(*), Write(*), Edit(*), …
     ask / deny    cleared to empty, including any rules you added yourself
     push guard    removed — force-pushing to main is no longer stopped
     codex         approval_policy=never, sandbox_mode=danger-full-access

     Backups go to <file>.bak, which is single-level and is overwritten on the
     next run. Only do this in a container or VM you can throw away.

EOF
  if [ "$ASSUME_YES" -eq 0 ]; then
    [ -t 0 ] || { echo "refusing to go permissive non-interactively without --yes" >&2; exit 1; }
    printf '  type "yes" to continue: ' >&2
    read -r reply
    [ "$reply" = "yes" ] || { echo "  aborted — nothing was changed" >&2; exit 1; }
    echo >&2
  fi

  if [ "$SCOPE" = "global" ]; then
    echo "scope: global (user-level), FULLY PERMISSIVE"
    permit_claude "${HOME}/.claude/settings.json"
    permit_codex  "${HOME}/.codex"
    permit_agy    "${HOME}/.gemini/antigravity-cli/settings.json"
  else
    echo "scope: project ($PROJ), FULLY PERMISSIVE"
    permit_claude "$PROJ/.claude/settings.json"
    permit_codex  "$PROJ/.codex" "$PROJ"
    permit_agy    "${HOME}/.gemini/antigravity-cli/settings.json" "$PROJ"
  fi

  echo "allow=everything ask=0 deny=0  guard=none"
  echo "backups written alongside each file as <file>.bak"
  echo "undo:  $0 --${SCOPE} $([ "$SCOPE" = "project" ] && echo "'$PROJ' ")--uninstall   then re-run without --permissive"
  exit 0
fi

if [ "$DO_HOOK" -eq 1 ]; then
  install_guard
  [ -x "$GUARD" ] || { echo "guard not found at $GUARD (expected it at $GUARD_SRC)" >&2; exit 1; }
fi

if [ "$SCOPE" = "global" ]; then
  echo "scope: global (user-level)"
  write_claude "${HOME}/.claude/settings.json"
  write_codex  "${HOME}/.codex"
  write_agy    "${HOME}/.gemini/antigravity-cli/settings.json"
else
  PROJ=$(cd "${PROJ:-$PWD}" && pwd)
  echo "scope: project ($PROJ)"
  write_claude "$PROJ/.claude/settings.json"
  write_codex  "$PROJ/.codex"
  # Drop the trust block a previous --permissive run put in the global codex
  # config for this path; trusting it there would outrank what we just wrote.
  if toml_unpermit "${HOME}/.codex/config.toml" "$TRUST_BEGIN$PROJ" 0; then
    note "        removed permissive trust block for $PROJ from ${HOME}/.codex/config.toml"
  fi
  write_agy    "${HOME}/.gemini/antigravity-cli/settings.json" "$PROJ"
fi

echo "allow=${#ALLOW[@]} ask=${#ASK[@]} deny=${#DENY[@]}  guard=$([ "$DO_HOOK" -eq 1 ] && echo "$GUARD" || echo none)"
echo "backups written alongside each file as <file>.bak"
