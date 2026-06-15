# KLA Complex Test Repository

A self-contained fixture + tooling for **cross-branch patch propagation**. It
builds a realistic 14-branch enterprise repository, finds a single "definitive
fix" commit, and propagates it to every branch that should receive it — either
directly (cherry-pick) or by opening a pull request.

## Layout

| Path | Purpose |
|------|---------|
| `generate_complex_repo.sh` | Builds the 14-branch fixture from scratch |
| `scripts/propagate_patch.sh` | Finds the fix and applies it (direct or PR mode) |
| `scripts/verify_propagation.sh` | Asserts the expected outcome (direct or PR mode) |
| `scripts/run_pipeline.sh` | Local end-to-end run: generate → propagate → verify |
| `.github/workflows/patch-propagation.yml` | CI: integration test + live PR opening |

## Work item & fix commit

- **Work item:** `[WI-440219]`
- **Source branch:** `bugfix/payment-patch`
- **Fix commit must contain:** `Apply definitive thread-safe fix` and `[WI-440219]`
- **Affected file:** `src/payment/transaction_queue.py`
- **Target branches (default `wi-history` mode):** any branch whose history mentions `WI-440219`

## Local usage

```bash
# Full pipeline into a throwaway fixture (safe — never touches live branches)
./scripts/run_pipeline.sh

# Or run the steps against any repo dir individually
./scripts/propagate_patch.sh .          # direct cherry-pick (mutates local branches)
./scripts/verify_propagation.sh .
```

## Propagation modes

`propagate_patch.sh` and `verify_propagation.sh` share the same `PROPAGATION_MODE`:

| Mode | Behaviour |
|------|-----------|
| `direct` (default) | Cherry-pick the fix directly onto each eligible branch |
| `pr` | Cherry-pick onto `propagate/WI-440219/<branch>`, push it, and open a PR into the original branch |

```bash
PROPAGATION_MODE=pr ./scripts/propagate_patch.sh .
PROPAGATION_MODE=pr ./scripts/verify_propagation.sh .
```

Branches with WI history but no affected file (e.g. `release/v1.0`) fail the
cherry-pick on purpose, so **no PR is opened** for them.

## GitHub Actions

The workflow runs on every push to `main` and has two jobs:

| Job | Needs a secret? | What it does |
|-----|-----------------|--------------|
| **Full integration** | No | Generates a fresh fixture, cherry-picks the fix, verifies. Always the gate. |
| **Live repo PRs** | Yes (`PROPAGATION_TOKEN`) | Opens a real PR per eligible WI branch on this repo. |

### Why the PR job needs a token

GitHub's default `GITHUB_TOKEN` **cannot open pull requests** (it returns
*"GitHub Actions is not permitted to create or approve pull requests"*), even
with `pull-requests: write`. The PR job therefore uses a Personal Access Token.

**One-time setup:**

1. Create a PAT — a fine-grained token with **Contents: Read/Write** and
   **Pull requests: Read/Write** on this repo, or a classic token with the
   `repo` scope.
2. Add it as a repository secret named **`PROPAGATION_TOKEN`**
   (Settings → Secrets and variables → Actions → New repository secret).

If the secret is absent the **Live repo PRs** job is **skipped with a notice**
instead of failing — so CI stays green either way.

View open PRs: https://github.com/MajedSaade/kla-complex-test-repo/pulls

## Expected results

| Branch | Direct mode | PR mode |
|--------|-------------|---------|
| `feature/payment-gateway` | Fix cherry-picked | PR opened |
| `feature/ledger-audit` | Fix cherry-picked | PR opened |
| `feature/compliance-reporting` | Fix cherry-picked | PR opened |
| `feature/database-migration` | Fix cherry-picked | PR opened |
| `infra/kubernetes-config` | Fix cherry-picked | PR opened |
| `bugfix/payment-patch` | Source (skipped) | Source (skipped) |
| `release/v1.0` | Fail (no affected file) | No PR |
| All other branches | Skipped (no WI history) | Skipped |

PR mode opens **5 pull requests** (one per eligible branch above).
