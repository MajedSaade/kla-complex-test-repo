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
| `scripts/notify_propagation.sh` | Emails / summarizes the propagation outcome |
| `scripts/run_pipeline.sh` | Local end-to-end run: generate → propagate → verify |
| `.github/workflows/patch-propagation.yml` | CI: integration test + live PR opening |
| `ARCHITECTURE.md` | Detailed walkthrough of how everything works (with diagrams) |

> New here? Read **[ARCHITECTURE.md](ARCHITECTURE.md)** for a full, diagrammed
> explanation of every file, function, and how the pieces connect.

### Live vs. fixture, and the "no hardcoding" guarantee

`propagate_patch.sh` always **discovers branches dynamically** (local + `origin/*`),
checks each one's WI history, and genuinely attempts the cherry-pick to test
whether the fix applies. In **PR mode** (the live GitHub path) `verify_propagation.sh`
is also fully dynamic: it rediscovers the real branches and recomputes
eligibility from git state — no branch names are hardcoded. The hardcoded lists
in `verify_propagation.sh` apply **only to direct mode**, which runs against the
synthetic fixture in `.generated-fixture/` and acts as a generator regression test.

## Work item & fix commit

- **Work item:** `[WI-440219]`
- **Source branch:** `bugfix/payment-patch`
- **Fix commit selection:** the newest commit on the source branch whose message contains `[WI-440219]` — that is the whole rule (no marker check)
- **Affected file:** `src/payment/transaction_queue.py` (taken from the fix commit; cherry-picked where the file exists, added wholesale where it does not)
- **Target branches (default `wi-history` mode):** any branch whose history mentions `WI-440219`, whether or not it already has the affected file

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

A branch is **skipped / gets no PR** when any of these hold:

- it is a **protected integration branch** (`PROTECTED_BRANCHES`, default
  `main master`) — these never receive the fix, even if they qualify, or
- its history has no `WI-440219` mention (not a target), or
- it has the affected file but a **competing change** makes the cherry-pick
  conflict (e.g. `feature/payment-hotfix`) — reported, not applied, or
- it is listed in `BLOCKED_BRANCHES` (default `infra/kubernetes-config`) — an
  explicit policy block that wins even if the branch otherwise qualifies.

A WI branch that simply **lacks** the affected file (e.g. `release/v1.0`) is
**not** skipped: the fix introduces the file (the full fixed version is added),
so the branch still gets a PR.

```bash
# Block more branches (space- or comma-separated); remember to lower MIN_PRS.
BLOCKED_BRANCHES="infra/kubernetes-config feature/ledger-audit" \
MIN_PRS=3 PROPAGATION_MODE=pr ./scripts/propagate_patch.sh .
```

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

### Email notification

After the live PR run, `scripts/notify_propagation.sh` builds a report grouped into
**PRs opened** (and onto which branches), **skipped** (with reasons), and
**no action / could not apply**. The report is always written to the GitHub
Actions run summary. It is additionally emailed when these repository secrets are
set (Settings → Secrets and variables → Actions):

| Secret | Meaning |
|--------|---------|
| `NOTIFY_EMAIL_TO` | recipient address(es), comma-separated |
| `NOTIFY_EMAIL_FROM` | sender address |
| `SMTP_SERVER` | SMTP host (e.g. `smtp.gmail.com`) |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | SMTP login + password/app-password |
| `SMTP_PORT` *(optional)* | default `587` |
| `SMTP_SECURITY` *(optional)* | `starttls` (default), `ssl`, or `none` |

If the SMTP secrets are absent the email is skipped (the run-summary report still
appears). Run it locally too: `PROPAGATION_MODE=pr ./scripts/notify_propagation.sh .`

## Expected results

| Branch | Direct mode | PR mode |
|--------|-------------|---------|
| `feature/payment-gateway` | Fix cherry-picked | PR opened |
| `feature/ledger-audit` | Fix cherry-picked | PR opened |
| `feature/compliance-reporting` | Fix cherry-picked | PR opened |
| `feature/database-migration` | Fix cherry-picked | PR opened |
| `release/v1.0` | Fix added (file created) | PR opened |
| `feature/payment-hotfix` | Conflict (not applied) | No PR — conflict reported |
| `infra/kubernetes-config` | Skipped (blocked) | No PR (blocked) |
| `bugfix/payment-patch` | Source (skipped) | Source (skipped) |
| All other branches | Skipped (no WI history) | Skipped |

PR mode opens **5 pull requests**. Two branches are intentional negative cases:

- `infra/kubernetes-config` fully qualifies (WI history + affected file) but is in
  `BLOCKED_BRANCHES`, so it is skipped — the block overrides eligibility.
- `feature/payment-hotfix` has WI history and the affected file, but its competing
  change makes the cherry-pick **conflict**. The conflict is **reported** (in the
  summary, `results.tsv`, and the notification email) and the run **keeps going**
  — a conflict never crashes the workflow.

`release/v1.0` has WI history but no `transaction_queue.py`; rather than being
skipped, the fix **adds** the file (the full fixed version), so it gets a PR.
