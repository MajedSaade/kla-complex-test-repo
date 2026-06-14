# KLA Complex Test Repository

Single repo containing the **14-branch enterprise fixture** and the **patch propagation tooling**. Use this repo to browse branches on GitHub and run CI against the same codebase.

## Repository layout

| Path | Purpose |
|------|---------|
| `generate_complex_repo.sh` | Builds the 14-branch fixture from scratch |
| `scripts/propagate_patch.sh` | Finds the definitive fix and cherry-picks it |
| `scripts/verify_propagation.sh` | Asserts expected propagation outcomes |
| `scripts/run_pipeline.sh` | Full integration test in `.generated-fixture/` |
| `scripts/push_all_branches.sh` | Push all branches to GitHub |
| `config/`, `src/`, `infra/` | Domain files across feature branches |

## Work item & fix commit

- **Work item:** `[WI-440219]`
- **Source branch:** `bugfix/payment-patch`
- **Fix commit message must contain:** `Apply definitive thread-safe fix` and `[WI-440219]`
- **Target branches (default):** any branch whose history mentions `WI-440219`

## Local commands

```bash
# Full integration (safe — writes to .generated-fixture/, not live branches)
./scripts/run_pipeline.sh

# Propagate on this repo directly (mutates local branches)
./scripts/propagate_patch.sh .
./scripts/verify_propagation.sh .

# Push all branches
./scripts/push_all_branches.sh MajedSaade/kla-complex-test-repo
```

## Propagation modes

| Mode | Command | Behaviour |
|------|---------|-----------|
| `direct` (default) | `PROPAGATION_MODE=direct ./scripts/propagate_patch.sh .` | Cherry-pick fix directly onto each branch |
| `pr` | `PROPAGATION_MODE=pr ./scripts/propagate_patch.sh .` | Cherry-pick onto `propagate/WI-440219/<branch>` and **open a PR** |

PR mode creates one pull request per eligible branch:

```
propagate/WI-440219/feature-payment-gateway  →  PR into  feature/payment-gateway
propagate/WI-440219/feature-ledger-audit     →  PR into  feature/ledger-audit
...
```

Branches with WI history but no affected file (e.g. `release/v1.0`) fail cherry-pick and **no PR is opened**.

## GitHub Actions

**Important:** Only push fixture branches from `.generated-fixture/`.  
Do **not** `git push --all --force` from `.generated-fixture` without restoring `main` — it removes the workflow from GitHub.

After a fixture force-push, restore CI on `main`:

```bash
./scripts/restore_github_main.sh
git push origin main --force   # puts workflow back; triggers CI automatically
```

| Job | What it does |
|-----|--------------|
| **Full integration** | Generates fresh fixture, direct cherry-pick, verify |
| **Live repo PRs** | Opens a PR on GitHub for each eligible WI branch |

View open PRs: https://github.com/MajedSaade/kla-complex-test-repo/pulls

## Expected propagation results

| Branch | Direct mode | PR mode |
|--------|-------------|---------|
| `feature/payment-gateway` | Fix cherry-picked | PR opened |
| `feature/ledger-audit` | Fix cherry-picked | PR opened |
| `feature/compliance-reporting` | Fix cherry-picked | PR opened |
| `bugfix/payment-patch` | Source (skip) | Source (skip) |
| `release/v1.0`, `feature/database-migration`, `infra/kubernetes-config` | FAIL (no file) | No PR (cherry-pick fails) |
| Other branches | Skipped | Skipped |
