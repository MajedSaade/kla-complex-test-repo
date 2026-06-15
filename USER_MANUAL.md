# User Manual — KLA Cross-Branch Patch Propagation

This manual explains, end to end, **what the system does, how it decides what to
do, and exactly how to run it** — locally and in CI. If you only want a quick
overview, read [`README.md`](README.md); if you want the internal design and
diagrams, read [`ARCHITECTURE.md`](ARCHITECTURE.md). This document is the
hands-on operator's guide.

---

## 1. What this system is for

In a large repository, a single bug is often fixed on **one** branch, but the
same fix needs to reach **many other branches** that are working on related code.
Doing that by hand is error-prone: it's easy to forget a branch, patch a branch
that should not be touched, or push a change that silently conflicts.

This system automates that propagation safely:

1. It **finds one "definitive fix" commit** for a known work item.
2. It **discovers every branch** in the repository (local + remote).
3. It decides, by rule, **which branches should receive the fix**.
4. For each eligible branch it **opens a pull request** that carries the fix
   (it never pushes directly onto a live branch in PR mode).
5. It **verifies** the outcome and can **email a report** of what happened.

Everything is dynamic: branch names are **discovered and compared at runtime**,
never hardcoded.

---

## 2. Key concepts (read this once)

| Term | Meaning |
|------|---------|
| **Work item (WI)** | A ticket ID such as `WI-440219`. Commits that address it carry `[WI-440219]` in their message. |
| **Source branch** | The branch that already holds the fix. Default: `A14-bugfix/payment-patch`. |
| **Fix commit** | The newest commit on the source branch whose message contains the WI tag. That is the fix that gets propagated. |
| **Affected file** | The file the fix changes: `src/payment/transaction_queue.py`. Where a branch already has it, the fix is cherry-picked; where it doesn't, the fixed file is added wholesale. |
| **Eligibility** | The rule that decides whether a branch should receive the fix (see §3). |
| **Propagation mode** | `direct` (cherry-pick onto the branch) or `pr` (open a pull request). |
| **Dry run** | Do all the real selection and cherry-pick work, but **don't push or open PRs**. Used locally and by the CI gate. |

### The letter+number branch naming scheme

Every fixture branch carries a **letter + number prefix**, e.g.
`A11-release/v1.0`, `A14-bugfix/payment-patch`, `B2-feature/payment-hotfix`,
`C1-feature/ledger-audit`, `G6-infra/kubernetes-config`. This prefix exists so
that branch ordering is **explicit and controllable** — see §3.

---

## 3. How a branch is selected (the rules)

A branch **receives a PR** only when **all** of the following are true, and is
**skipped** if **any** fails. The same rules are used by both the propagation
script and the verifier.

1. **Name sorts strictly after the source branch.**
   Comparison is a pure byte-wise string compare (`LC_ALL=C`). Because every
   branch has a letter+number prefix, this gives a deterministic order:
   `A14 < B2 < C1 < G6`, exactly the way `20 < 25` would compare. So the source
   branch itself, its parent (`A13-feature/payment-gateway`), and anything that
   sorts lower (e.g. `A11-release/v1.0`) are **excluded** — regardless of commit
   dates.

2. **History mentions the work item** (default `wi-history` mode).
   The branch's commit history must contain `WI-440219`. (In `affected-file`
   mode the rule is instead "the branch already contains the affected file".)

3. **Not a protected integration branch.**
   `PROTECTED_BRANCHES` (default `main master`) never receive the fix.

4. **Not explicitly blocked.**
   Branches in `BLOCKED_BRANCHES` are skipped even if they otherwise qualify.
   The default blocks `G6-infra/kubernetes-config` (and its pre-rename name
   `infra/kubernetes-config`, a protected branch still on `origin`).

5. **The cherry-pick does not conflict.**
   If a branch qualifies but a competing change makes the cherry-pick conflict
   (e.g. `B2-feature/payment-hotfix`), the conflict is **reported** — it is a
   **non-fatal** outcome, not an applied PR and not a crash.

> **Note on a branch that lacks the file:** an eligible branch that simply
> doesn't have `transaction_queue.py` is **not** skipped — the fixed file is
> added and it still gets a PR. `D1-feature/database-migration` is this case.

> **There is no minimum-PR gate.** The run opens a PR for **every** eligible
> branch and succeeds whatever that count is (including zero). It only fails on a
> genuinely unexpected error. (A conflict is expected and never fails the run.)

---

## 4. Prerequisites

- **Bash** and **git** (any recent version).
- For **opening real PRs** (PR mode against a live repo): the
  [GitHub CLI `gh`](https://cli.github.com/) authenticated with a token that has
  **Contents: Read/Write** and **Pull requests: Read/Write** scope.
- For **email notifications**: reachable SMTP server credentials (optional).

No special setup is needed for local dry-runs — they never touch a remote.

---

## 5. Quick start (safe, local, no remote needed)

From the repository root:

```bash
# Full pipeline into a throwaway fixture: generate → propagate (dry-run) → verify
./scripts/run_pipeline.sh
```

This:

1. Builds a fresh 18-branch fixture in `./complex-test-repo` (or the dir you
   pass).
2. Runs the propagation (in CI/dry-run style: genuine selection + cherry-pick,
   no push, no PR).
3. Verifies that the right branches were selected and the rest were skipped.

It is completely safe to run repeatedly — it never pushes or opens anything.

---

## 6. The scripts, one by one

| Script | What it does |
|--------|--------------|
| `generate_complex_repo.sh [DIR]` | Builds the multi-branch fixture from scratch in `DIR`. |
| `scripts/propagate_patch.sh [REPO_DIR]` | Finds the fix and propagates it (direct or PR mode). The heart of the system. |
| `scripts/verify_propagation.sh [REPO_DIR]` | Re-derives eligibility from git state and asserts the outcome was correct. |
| `scripts/notify_propagation.sh [REPO_DIR]` | Builds a grouped report (opened / skipped / no-action) and optionally emails it. |
| `scripts/run_pipeline.sh [DIR]` | Convenience wrapper: generate → propagate → verify. |
| `scripts/migrate_to_letter_branches.sh` | Re-publishes the live fixture branches under the letter+number scheme (push access required). |

### 6.1 `propagate_patch.sh`

```bash
# Dry-run against any repo dir (genuine selection + cherry-pick, no push/PR):
DRY_RUN=true ./scripts/propagate_patch.sh .

# Direct mode (cherry-pick onto each eligible branch locally):
PROPAGATION_MODE=direct ./scripts/propagate_patch.sh .

# PR mode against the live GitHub repo (requires gh + token):
PROPAGATION_MODE=pr ./scripts/propagate_patch.sh .
```

What it produces under `.propagation-logs/` in the target repo:

| File | Contents |
|------|----------|
| `propagation-summary.txt` | Human-readable log of everything that happened. |
| `wi-target-branches.txt` | Branches whose history mentions the WI. |
| `pull-requests.txt` | `branch\|url` lines for opened/existing PRs. |
| `results.tsv` | Machine-readable `status⇥branch⇥reason⇥url` — the contract used by the verifier and notifier. |

Possible per-branch statuses: `APPLIED`, `PR_OPENED`, `PR_EXISTING`, `SKIPPED`,
`CONFLICT`, `FAILED`.

### 6.2 `verify_propagation.sh`

```bash
./scripts/verify_propagation.sh .
```

It **rediscovers** the real branches and **recomputes** eligibility with the
same rules as the propagator, then asserts:

- every **eligible** branch has a PR (or already carries the fix, or is a
  reported conflict), and
- every **non-eligible** branch has **no** PR, printing the reason for each.

It exits non-zero if any assertion fails. It needs the propagation logs to
exist, so run `propagate_patch.sh` first.

### 6.3 `notify_propagation.sh`

```bash
./scripts/notify_propagation.sh .
```

Reads `results.tsv` and prints a report grouped into **PRs opened**, **skipped**
(with reasons), and **no action / could not apply**. In CI it's also written to
the run summary, and emailed if SMTP secrets are set (see §9).

---

## 7. Configuration reference (environment variables)

All of these have sensible defaults — override only what you need.

| Variable | Used by | Default | Meaning |
|----------|---------|---------|---------|
| `WI_ID` | all | `WI-440219` | Work item ID. |
| `SOURCE_BRANCH` | propagate, verify | `A14-bugfix/payment-patch` | Branch holding the fix. |
| `AFFECTED_FILE` | propagate, verify | `src/payment/transaction_queue.py` | File the fix changes. |
| `FIX_MARKER` | propagate, verify | `threading.RLock()  # WI-440219: definitive thread-safe fix` | Line used to detect a branch that already has the fix. |
| `BRANCH_SELECT_MODE` | propagate, verify | `wi-history` | `wi-history` or `affected-file`. |
| `PROPAGATION_MODE` | propagate | `direct` | `direct` or `pr`. |
| `BLOCKED_BRANCHES` | propagate, verify | `G6-infra/kubernetes-config infra/kubernetes-config` | Branches to skip even if eligible (space- or comma-separated). |
| `PROTECTED_BRANCHES` | propagate, verify | `main master` | Integration branches that never receive the fix. |
| `DRY_RUN` | propagate | `false` | Do everything except push / open PRs. |
| `NOTIFY_EMAIL_TO` / `NOTIFY_EMAIL_FROM`, `SMTP_*` | notify | — | Email delivery (optional, see §9). |

> The previous `MIN_PRS` minimum-PR gate has been **removed**. A run is no longer
> required to open a certain number of PRs; it simply opens one per eligible
> branch and passes.

Example — block extra branches; the run opens a PR for whatever remains:

```bash
BLOCKED_BRANCHES="G6-infra/kubernetes-config C1-feature/ledger-audit" \
./scripts/propagate_patch.sh .
```

---

## 8. Expected results with the default fixture

| Branch | Outcome |
|--------|---------|
| `C1-feature/ledger-audit` | PR opened |
| `C3-feature/compliance-reporting` | PR opened |
| `D1-feature/database-migration` | PR opened (file added) |
| `E1-feature/payment-refunds` | PR opened |
| `E2-feature/payment-reconcile` | PR opened |
| `E3-feature/payment-audit` | PR opened |
| `B2-feature/payment-hotfix` | No PR — conflict reported (non-fatal) |
| `G6-infra/kubernetes-config` | No PR (blocked by policy) |
| `A13-feature/payment-gateway` | Skipped (name sorts on/before the fix branch) |
| `A11-release/v1.0` | Skipped (name sorts on/before the fix branch) |
| `A14-bugfix/payment-patch` | Source (skipped) |
| `main` | Skipped (protected) |
| All other branches | Skipped (no WI history) |

Net result: **6 pull requests**, one per eligible branch, plus one reported
conflict and one policy block. There is no minimum-PR requirement.

---

## 9. Running in CI (GitHub Actions)

The workflow `.github/workflows/patch-propagation.yml` runs on every push/PR to
`main`/`master` (and via manual dispatch) with two jobs:

| Job | Needs a secret? | What it does |
|-----|-----------------|--------------|
| **Full integration** | No | Generates a fresh fixture, runs propagation as a dry-run (selection + cherry-pick, no push), verifies. This is the always-on gate. |
| **Live repo PRs** | Yes (`PROPAGATION_TOKEN`) | Opens a real PR per eligible branch on this repo, verifies, and notifies. |

### Why the PR job needs a token

GitHub's default `GITHUB_TOKEN` **cannot open pull requests** (it returns
*"GitHub Actions is not permitted to create or approve pull requests"*). So the
live job uses a **Personal Access Token**.

**One-time setup:**

1. Create a PAT — a fine-grained token with **Contents: Read/Write** and
   **Pull requests: Read/Write** on this repo (or a classic token with `repo`
   scope).
2. Add it as a repository secret named **`PROPAGATION_TOKEN`**
   (Settings → Secrets and variables → Actions → New repository secret).

If the secret is absent, the **Live repo PRs** job is **skipped with a notice**
instead of failing — so CI stays green either way.

### Email notification secrets (optional)

Set these to have `notify_propagation.sh` email the report (otherwise it only
writes the run summary):

| Secret | Meaning |
|--------|---------|
| `NOTIFY_EMAIL_TO` | recipient address(es), comma-separated |
| `NOTIFY_EMAIL_FROM` | sender address |
| `SMTP_SERVER` | SMTP host (e.g. `smtp.gmail.com`) |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | SMTP login + password / app-password |
| `SMTP_PORT` *(optional)* | default `587` |
| `SMTP_SECURITY` *(optional)* | `starttls` (default), `ssl`, or `none` |

View open PRs: <https://github.com/MajedSaade/kla-complex-test-repo/pulls>

---

## 10. Migrating the live repo to the letter scheme

Branch names live on `origin`, so renaming them in the generator alone is not
enough — the live fixture branches must be re-published. `main` (which holds the
tooling) is left untouched.

```bash
# Preview the plan (changes nothing):
./scripts/migrate_to_letter_branches.sh

# Publish the new letter-named branches and delete the legacy numeric ones:
APPLY=true ./scripts/migrate_to_letter_branches.sh
```

After this, the **Live repo PRs** job opens 6 PRs (one per eligible branch).

---

## 11. Typical workflows

**A. "Just show me it works" (local, safe):**

```bash
./scripts/run_pipeline.sh
```

**B. "Dry-run against my own repo checkout":**

```bash
DRY_RUN=true ./scripts/propagate_patch.sh /path/to/repo
./scripts/verify_propagation.sh /path/to/repo
```

**C. "Open real PRs on the live GitHub repo":**

```bash
# Authenticate gh first (e.g. gh auth login), then:
PROPAGATION_MODE=pr ./scripts/propagate_patch.sh .
PROPAGATION_MODE=pr ./scripts/verify_propagation.sh .
./scripts/notify_propagation.sh .
```

**D. "Use a different work item / source branch":**

```bash
WI_ID=WI-999000 SOURCE_BRANCH=B2-feature/payment-hotfix \
DRY_RUN=true ./scripts/propagate_patch.sh .
```

---

## 12. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `Error: <dir> is not a Git repository.` | You pointed a script at a non-git directory. Pass a valid repo path. |
| `Missing propagation logs — run propagate_patch.sh first` (verify) | Run `propagate_patch.sh` before `verify_propagation.sh`; the verifier reads `.propagation-logs/`. |
| Live PR job is skipped in CI | `PROPAGATION_TOKEN` secret is not set. Add it (see §9) to enable real PRs. |
| "GitHub Actions is not permitted to create or approve pull requests" | You're using the default `GITHUB_TOKEN`. Use a PAT in `PROPAGATION_TOKEN`. |
| A branch you expected got no PR | Check the rules in §3 — most often its name sorts on/before the source branch, it lacks the WI in history, it's blocked/protected, or its cherry-pick conflicts. The summary/`results.tsv` states the reason. |
| Email not sent | One or more SMTP secrets are missing. The run summary report is still written. |
| `B2-feature/payment-hotfix` shows a conflict | Expected — it has a competing change. Conflicts are reported, non-fatal, and need manual resolution. |
| No PRs opened at all | That is allowed (no minimum-PR gate). Confirm eligibility with §3; if you expected eligible branches, check that they exist on `origin` and mention the WI. |

---

## 13. Where to go next

- [`README.md`](README.md) — short overview and command cheatsheet.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — full internal design, function-by-function
  walkthrough, and diagrams.
- `.github/workflows/patch-propagation.yml` — the CI definition described in §9.
