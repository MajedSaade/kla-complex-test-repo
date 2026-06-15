# KLA Complex Test Repository

A self-contained fixture + tooling for **cross-branch patch propagation**. It
builds a realistic 18-branch enterprise repository, finds a single "definitive
fix" commit, and opens a pull request to propagate it to every branch that
should receive it. Two rules decide who is eligible: the branch's **name must
sort lexicographically after the branch that holds the fix**, and (by default)
its history must mention the work item. Branches carry a **letter + number
prefix** (e.g. `A14-bugfix/payment-patch`, `C1-feature/ledger-audit`,
`G6-infra/kubernetes-config`) so this ordering is explicit and controllable —
the byte-wise comparison works the same for letters as for digits, so a branch
whose prefix sorts after the fix branch's prefix is "after" it. The
fix is **always** proposed via a pull request — it is never cherry-picked
directly onto a live branch.

## Layout

| Path | Purpose |
|------|---------|
| `generate_complex_repo.sh` | Builds the 18-branch fixture from scratch |
| `scripts/propagate_patch.sh` | Finds the fix and opens a propagation PR per eligible branch |
| `scripts/verify_propagation.sh` | Asserts the expected PR outcome |
| `scripts/notify_propagation.sh` | Emails / summarizes the propagation outcome |
| `scripts/run_pipeline.sh` | Local end-to-end run (dry-run): generate → propagate → verify |
| `scripts/migrate_to_letter_branches.sh` | Re-point the live repo's fixture branches at the letter scheme (push access required) |
| `.github/workflows/patch-propagation.yml` | CI: integration test + live PR opening |
| `ARCHITECTURE.md` | Detailed walkthrough of how everything works (with diagrams) |

> New here? Read **[ARCHITECTURE.md](ARCHITECTURE.md)** for a full, diagrammed
> explanation of every file, function, and how the pieces connect.

### Dynamic, with the "no hardcoding" guarantee

`propagate_patch.sh` **discovers branches dynamically** (local + `origin/*`),
compares each name against the fix branch and checks its WI history, and
genuinely attempts the cherry-pick to test whether the fix applies.
`verify_propagation.sh` is equally dynamic: it rediscovers the real branches and
recomputes eligibility from git state — **no branch names are hardcoded**.
Locally there is no remote to push
to, so both scripts run with `DRY_RUN=true` (genuine selection + cherry-pick, no
push or PR); this is also how the CI integration gate works.

## Work item & fix commit

- **Work item:** `[WI-440219]`
- **Source branch:** `A14-bugfix/payment-patch`
- **Fix commit selection:** the newest commit on the source branch whose message contains `[WI-440219]` — that is the whole rule (no marker check)
- **Affected file:** `src/payment/transaction_queue.py` (taken from the fix commit; cherry-picked where the file exists, added wholesale where it does not)
- **Eligibility (default `wi-history` mode):** a branch's **name must sort lexicographically after `A14-bugfix/payment-patch`** *and* its history must mention `WI-440219` (whether or not it already has the affected file)

### How "lexicographically after the fix branch" is determined

Every branch carries a **letter + number prefix** (`A11-`, `A12-`, `A13-`,
`A14-`, `B2-`, `B3-`, `C1-`, … `G6-`) so branch names sort in a deterministic,
controllable order. Eligibility is a pure **byte-wise name comparison**
(`LC_ALL=C`): a branch qualifies only when its name sorts strictly after the fix
branch's name. The comparison is byte-wise, so it behaves identically whether
the prefix starts with a digit or a letter — `A14` < `B2` < `C1` < `G6` the same
way `20` < `25` would. (Within a letter group the digit widths are kept
consistent — e.g. `A11`…`A14` are all two digits — so there is no `A9`-vs-`A14`
surprise.) So the fix branch (`A14-bugfix/payment-patch`), its own parent
(`A13-feature/payment-gateway`) and anything that sorts lower (e.g.
`A11-release/v1.0`) are excluded, regardless of commit dates; everything in the
`B*`/`C*`/`D*`/`E*`/`G*` groups sorts after it.

## Local usage

```bash
# Full pipeline into a throwaway fixture (safe — dry-run, never pushes or opens PRs)
./scripts/run_pipeline.sh

# Or run the steps against any repo dir individually (dry-run: no push / no PR)
DRY_RUN=true ./scripts/propagate_patch.sh .
./scripts/verify_propagation.sh .
```

## How propagation works

Propagation is **always via a pull request** — the fix is never cherry-picked
directly onto a live branch. For each eligible branch `propagate_patch.sh`
cherry-picks the fix onto `propagate/WI-440219/<branch>`, pushes it, and opens a
PR into the original branch.

Set `DRY_RUN=true` to exercise branch selection and the cherry-pick locally
without pushing or opening anything. This is what `run_pipeline.sh` and the CI
integration gate use, and it is the only way to run without a GitHub remote.

```bash
# Against the live GitHub repo (requires gh / a token with repo + PR scope):
./scripts/propagate_patch.sh .
./scripts/verify_propagation.sh .
```

A branch is **skipped / gets no PR** when any of these hold:

- its **name sorts on or before the fix branch** (`A14-bugfix/payment-patch`) —
  including the fix branch's own parent (`A13-feature/payment-gateway`); only
  branches whose name sorts *after* the fix branch are eligible, or
- it is a **protected integration branch** (`PROTECTED_BRANCHES`, default
  `main master`) — these never receive the fix, even if they qualify, or
- its history has no `WI-440219` mention (not a target), or
- it has the affected file but a **competing change** makes the cherry-pick
  conflict (e.g. `B2-feature/payment-hotfix`) — reported, not applied, or
- it is listed in `BLOCKED_BRANCHES` — an explicit policy block that wins even
  if the branch otherwise qualifies. The default blocks both
  `G6-infra/kubernetes-config` and its pre-rename name `infra/kubernetes-config`
  (the latter is a GitHub **protected** branch that survived the letter-prefix
  rename and still exists on `origin`; remove that branch and its protection
  rule to drop the second entry).

An eligible branch that simply **lacks** the affected file is **not** skipped:
the fix introduces the file (the full fixed version is added), so it still gets
a PR. `D1-feature/database-migration` is exactly this case — it mentions the WI
and sorts after the fix branch but never had `transaction_queue.py`, so the file
is added and it still gets a PR. (The WI-but-no-file branch `A11-release/v1.0`
sorts before the fix branch, so it is excluded by the name-order rule instead.)

```bash
# Block more branches (space- or comma-separated); remember to lower MIN_PRS.
BLOCKED_BRANCHES="G6-infra/kubernetes-config C1-feature/ledger-audit" \
MIN_PRS=2 ./scripts/propagate_patch.sh .
```

## GitHub Actions

The workflow runs on every push to `main` and has two jobs:

| Job | Needs a secret? | What it does |
|-----|-----------------|--------------|
| **Full integration** | No | Generates a fresh fixture, runs the PR flow as a dry-run (selection + cherry-pick, no push), verifies. Always the gate. |
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

### Migrating the live repo to the letter scheme

The branch names live on `origin`, so renaming them in the generator is not
enough — the live fixture branches must be re-published. `main` (which holds the
tooling) is left untouched. From a checkout with push access:

```bash
# Preview the plan (changes nothing):
./scripts/migrate_to_letter_branches.sh

# Publish the new letter-named branches and delete the legacy numeric ones:
APPLY=true ./scripts/migrate_to_letter_branches.sh
```

This force-pushes the freshly generated `A*/B*/C*/D*/E*/G*` fixture branches and
removes the old `05-`…`70-` ones, after which the **Live repo PRs** job opens
6 PRs and clears the `MIN_PRS=5` gate.

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
appears). Run it locally too: `./scripts/notify_propagation.sh .`

## Expected results

| Branch | Outcome |
|--------|---------|
| `C1-feature/ledger-audit` | PR opened |
| `C3-feature/compliance-reporting` | PR opened |
| `D1-feature/database-migration` | PR opened (file added) |
| `E1-feature/payment-refunds` | PR opened |
| `E2-feature/payment-reconcile` | PR opened |
| `E3-feature/payment-audit` | PR opened |
| `B2-feature/payment-hotfix` | No PR — conflict reported |
| `G6-infra/kubernetes-config` | No PR (blocked) |
| `A13-feature/payment-gateway` | Skipped (name sorts before the fix branch) |
| `A11-release/v1.0` | Skipped (name sorts before the fix branch) |
| `A14-bugfix/payment-patch` | Source (skipped) |
| `main` | Skipped (protected) |
| All other branches | Skipped (no WI history) |

The run opens **6 pull requests** (so it clears the `MIN_PRS=5` gate). The
interesting cases:

- `A13-feature/payment-gateway` and `A11-release/v1.0` mention the WI but their
  names sort **on/before the fix branch** (`A14-…`), so the name-order rule
  excludes them — even though under a "WI history only" rule they would qualify.
- `G6-infra/kubernetes-config` qualifies (name sorts after, WI history, affected
  file) but is in `BLOCKED_BRANCHES`, so it is skipped — the block overrides
  eligibility.
- `B2-feature/payment-hotfix` qualifies, but its competing change makes the
  cherry-pick **conflict**. The conflict is **reported** (in the summary,
  `results.tsv`, and the notification email) and the run **keeps going** — a
  conflict never crashes the workflow.
