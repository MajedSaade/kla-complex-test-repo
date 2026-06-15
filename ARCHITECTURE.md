# Architecture & Code Walkthrough

A complete, detailed explanation of how this project works — what every file
does, how the functions fit together, and how the pieces connect end to end.
Diagrams are written in [Mermaid](https://mermaid.js.org/) and render on GitHub.

> **TL;DR** — This repo is a *self-contained test harness* for **cross-branch
> patch propagation**. One script **builds** a fake 15-branch enterprise repo,
> a second **finds a bug-fix commit and copies it** onto every branch that
> should get it, a third **checks** the result, a fourth **reports/emails** it,
> and a GitHub Actions workflow **runs the whole thing in CI**.

---

## 1. The big picture

Imagine a large company with one Git repository and many active branches
(payments, auth, analytics, infra…). A critical bug is fixed on one branch.
**Which other branches need that same fix, and how do we apply it safely?**

This project answers that question with plain Bash + Git. It has two halves:

| Half | What it is | Files |
|------|-----------|-------|
| **The fixture** | A synthetic repo that *looks like* a messy enterprise repo | `generate_complex_repo.sh` |
| **The tooling** | Scripts that find, apply, verify, and report the fix | `scripts/*.sh` |

Everything is driven by one **work item**, `WI-440219`, and one **affected
file**, `src/payment/transaction_queue.py`.

---

## 2. Repository layout

```
complex-test-repo/
├── generate_complex_repo.sh        # Builds the 15-branch fixture from scratch
├── scripts/
│   ├── propagate_patch.sh          # Finds the fix and applies it (direct or PR)
│   ├── verify_propagation.sh       # Asserts the expected outcome
│   ├── notify_propagation.sh       # Builds a report + optional email
│   └── run_pipeline.sh             # Local: generate → propagate → verify
├── .github/workflows/
│   └── patch-propagation.yml       # CI: integration test + live PR opening
├── README.md                       # User-facing usage guide
├── ARCHITECTURE.md                 # This document
└── .gitignore                      # Ignores generated fixtures & logs
```

Everything else you might see on disk (`.generated-fixture*/`,
`.propagation-logs/`, a nested `complex-test-repo/`) is **generated output** and
is git-ignored. It is safe to delete at any time — the scripts recreate it.

---

## 3. Core concepts (the vocabulary)

| Term | Meaning | Default |
|------|---------|---------|
| **Work item (`WI_ID`)** | The ticket ID that tags related commits | `WI-440219` |
| **Source branch** | Branch that contains the *definitive* fix | `20-bugfix/payment-patch` |
| **Affected file** | The file the fix changes | `src/payment/transaction_queue.py` |
| **Fix marker** | Exact line that proves the definitive fix is present | `threading.RLock()  # WI-440219: definitive thread-safe fix` |
| **Fix commit** | Newest commit on the source branch that mentions the WI in its message | selected at runtime |
| **Target / eligible branch** | A branch that *should* receive the fix | computed dynamically |
| **Propagation mode** | How the fix is applied: `direct` (cherry-pick) or `pr` (open a PR) | `direct` |
| **Branch select mode** | How targets are chosen: `wi-history` or `affected-file` | `wi-history` |

The key trick: the bug fix is *one commit*. "Propagating" it means
**cherry-picking that commit** onto other branches — either straight onto the
branch (direct) or onto a throw-away branch that then becomes a Pull Request.

---

## 4. The fixture: what `generate_complex_repo.sh` builds

This script throws away any existing target directory and builds a brand-new Git
repo with **15 branches** designed to exercise every interesting case.

### 4.1 Branch tree (who forks from whom)

```mermaid
gitGraph
    commit id: "cfg scaffold"
    commit id: "logging"
    branch "05-release/v1.0"
    checkout "05-release/v1.0"
    commit id: "smoke-tests [WI]"
    commit id: "release docs"
    checkout main
    commit id: "main pipeline"
    commit id: "Dockerfile"
    commit id: "terraform"
    branch "15-feature/payment-gateway"
    checkout "15-feature/payment-gateway"
    commit id: "stripe [WI]"
    commit id: "txn_queue partial-lock [WI]"
    branch "20-bugfix/payment-patch"
    checkout "20-bugfix/payment-patch"
    commit id: "DEFINITIVE FIX [WI]" type: HIGHLIGHT
    checkout "15-feature/payment-gateway"
    branch "25-feature/payment-hotfix"
    checkout "25-feature/payment-hotfix"
    commit id: "competing lock [WI]"
    checkout "15-feature/payment-gateway"
    branch "40-feature/ledger-audit"
    checkout "40-feature/ledger-audit"
    commit id: "reconciliation [WI]"
    branch "50-feature/compliance-reporting"
    checkout "50-feature/compliance-reporting"
    commit id: "quarterly report [WI]"
    checkout main
    branch "60-feature/database-migration"
    checkout "60-feature/database-migration"
    commit id: "payment locks SQL [WI]"
    commit id: "vendor txn_queue [WI]"
    checkout main
    branch "70-infra/kubernetes-config"
    checkout "70-infra/kubernetes-config"
    commit id: "deploy env [WI]"
    commit id: "bundle txn_queue [WI]"
```

The numeric prefix encodes order: the fix branch is `20-`, so only branches
numbered **higher than 20** (`25-`, `40-`, `50-`, `60-`, `70-`) can be eligible;
`05-` and `15-` sort *before* the fix and are excluded by name.

*(The other branches — `10-feature/user-auth`, `30-feature/ui-ux`,
`35-feature/analytics-pipeline`, `45-feature/notifications`,
`55-feature/mobile-api`, `65-feature/admin-dashboard` — all fork from `main` and
contain **no** WI commits. They exist as "noise" that must be correctly
ignored.)*

### 4.2 The three states of `transaction_queue.py`

The whole test hinges on what each branch's copy of the affected file looks like:

| State | Lock line | Branches | Propagation result |
|-------|-----------|----------|--------------------|
| **Pre-fix** | `threading.Lock()  # ... partial lock — race remains` | `15-feature/payment-gateway`, `40-feature/ledger-audit`, `50-feature/compliance-reporting`, `60-feature/database-migration`, `70-infra/kubernetes-config` | cherry-pick applies cleanly ✅ (when also eligible by name) |
| **Definitive fix** | `threading.RLock()  # ... definitive thread-safe fix` | `20-bugfix/payment-patch` (source) | already fixed |
| **Competing** | local `enqueue` workaround that diverges | `25-feature/payment-hotfix` | cherry-pick conflict ⚠️ |
| **Absent** | file does not exist | `05-release/v1.0` + all no-WI branches | file added with the fix ➕ (when eligible) |

### 4.3 Why each "interesting" branch exists

| Branch | Name after `20-`? | WI in history? | Has the file? | Purpose in the test |
|--------|:---:|:---:|:---:|---------------------|
| `20-bugfix/payment-patch` | — | ✅ | ✅ (fixed) | **Source** of the fix — skipped |
| `05-release/v1.0` | ❌ | ✅ | ❌ | **Name sorts before fix** — excluded by name order |
| `15-feature/payment-gateway` | ❌ | ✅ | ✅ pre-fix | **Name sorts before fix** (the fix's own parent) — excluded |
| `40-feature/ledger-audit` | ✅ | ✅ | ✅ pre-fix | Happy path — gets the fix |
| `50-feature/compliance-reporting` | ✅ | ✅ | ✅ pre-fix | Happy path — gets the fix |
| `60-feature/database-migration` | ✅ | ✅ | ✅ pre-fix | Happy path — gets the fix |
| `25-feature/payment-hotfix` | ✅ | ✅ | ✅ competing | **Conflict** case — reported, non-fatal |
| `70-infra/kubernetes-config` | ✅ | ✅ | ✅ pre-fix | **Policy block** case — skipped on purpose |
| 6 other branches | mixed | ❌ | ❌ | **Noise** — must be ignored |

This gives a known-good fixture: **8 branches mention the WI**, but only those
whose **name sorts after `20-`** *and* mention the WI are eligible — so **3
receive the fix** (`40-feature/ledger-audit`, `50-feature/compliance-reporting`,
`60-feature/database-migration`), `25-feature/payment-hotfix` conflicts,
`70-infra/kubernetes-config` is blocked, and `05-release/v1.0` /
`15-feature/payment-gateway` are excluded because their names sort on/before the
fix branch.

### 4.4 Functions inside `generate_complex_repo.sh`

| Function | Job |
|----------|-----|
| `verify_nested_git_dir` | Safety check: confirms commits land in the fixture's own `.git`, not a parent checkout (critical when CI sets `GIT_*` env vars) |
| `init_repo` | Deletes any old target, `git init -b main`, sets identity, seeds the directory tree |
| `append_to_file <path> <lines…>` | Appends content (with a timestamp header) to a file, creating parent dirs |
| `commit_change <msg> <file> <lines…>` | The workhorse: append → `git add` → `git commit` |
| `new_branch <name> [parent]` | `git switch` to parent (if given) then create the new branch |
| `list_wi_commits` | Lists all commits mentioning the WI across branches (final report) |
| `print_branch_graph` | `git log --graph` over all branches (final report) |
| `section <title>` | Pretty banner printed between phases |

The bottom ~800 lines are just **data**: many `commit_change` calls that give
each branch realistic content. The logic is the handful of helpers above.

---

## 5. The heart: `propagate_patch.sh`

This is where the actual propagation happens. It runs in one of two modes.

### 5.1 Setup & configuration (top of file)

Everything is overridable via environment variables (with sensible defaults):
`WI_ID`, `SOURCE_BRANCH`, `AFFECTED_FILE`, `FIX_MARKER`, `BRANCH_SELECT_MODE`,
`PROPAGATION_MODE`, `BLOCKED_BRANCHES`, `MIN_PRS`, `DRY_RUN`. It then creates a
`.propagation-logs/` directory and four output files:

| File | Contents |
|------|----------|
| `propagation-summary.txt` | Human-readable log (everything the `log()` helper prints) |
| `wi-target-branches.txt` | Branches whose history mentions the WI |
| `pull-requests.txt` | `branch|url` lines for opened/existing PRs |
| `results.tsv` | **Machine-readable** `status⇥branch⇥reason⇥url` — the contract between scripts |

`results.tsv` is the key integration point: `verify_propagation.sh` and
`notify_propagation.sh` both read it.

### 5.2 Finding the fix commit

```mermaid
flowchart TD
    A[Resolve SOURCE_BRANCH ref<br/>local or origin/*] --> B["git log --grep=WI_ID -1<br/>newest WI commit"]
    B --> C{commit found?}
    C -- no --> X[Error: no WI commit]
    C -- yes --> D["git cat-file -e commit:AFFECTED_FILE<br/>does the commit carry the file?"]
    D --> E{file present?}
    E -- no --> Y[Error: fix commit lacks the file]
    E -- yes --> F[SOURCE_COMMIT is locked in]
```

The selection rule is simply **"the newest commit on the source branch whose
message mentions the WI."** There is no marker check — the latest WI-tagged
commit *is* the fix. The only extra requirement is that this commit actually
contains the affected file, because its content is what gets propagated.

### 5.3 Eligibility: should a branch get the fix?

For every discovered branch (`list_branches` returns local heads + `origin/*`),
the script decides what to do. The decision order is what makes the negative
cases work:

```mermaid
flowchart TD
    S([branch]) --> P{propagate/* branch?}
    P -- yes --> SKIP1[skip silently]
    P -- no --> PR0{protected branch?<br/>main / master}
    PR0 -- yes --> SKP[SKIP: protected branch]
    PR0 -- no --> SRC{== source branch?}
    SRC -- yes --> SK2[SKIP: source already has fix]
    SRC -- no --> BL{in BLOCKED_BRANCHES?}
    BL -- yes --> SK3[SKIP: blocked by policy]
    BL -- no --> HF{already has fix marker?}
    HF -- yes --> SK4[SKIP: fix already present]
    HF -- no --> NA{name sorts after<br/>source branch?<br/>LC_ALL=C byte compare}
    NA -- no --> SK6[SKIP: name on/before fix branch]
    NA -- yes --> SEL{selected by mode?<br/>wi-history: WI in history<br/>affected-file: file present}
    SEL -- no --> SK5[SKIP: not a target]
    SEL -- yes --> HASF{branch has<br/>the file?}
    HASF -- yes --> CP[[cherry-pick the fix<br/>competing change → CONFLICT]]
    HASF -- no --> ADD[[add the file with<br/>the fixed content]]
```

Helper predicates that drive this (all small one-liners near the middle):

| Function | Returns true when… |
|----------|--------------------|
| `branch_mentions_wi` | the branch's commit history has ≥1 commit mentioning the WI |
| `name_after_source` | the branch name sorts strictly **after** `SOURCE_BRANCH` (byte-wise, `LC_ALL=C`) — the numeric-prefix ordering rule |
| `branch_has_file` | the affected file exists on the branch |
| `branch_has_fix` | the affected file already contains the fix marker |
| `is_blocked` | branch is in `BLOCKED_BRANCHES` |
| `is_protected` | branch is in `PROTECTED_BRANCHES` (e.g. `main`) — never gets the fix |
| `is_propagation_branch` | branch name starts with `propagate/` |
| `should_target_branch` | combines all of the above for the chosen select mode |
| `add_fixed_file` | writes the file's full fixed content (from the fix commit) and commits it — used when the branch lacks the file |

### 5.4 Applying the fix — two modes

**Direct mode (`apply_direct`)** — checkout the branch, then either:
- if the branch **has** the file → `git cherry-pick` the fix (a competing change
  makes this conflict, logged as `FAIL`/`CONFLICT`), or
- if the branch **lacks** the file → `add_fixed_file` writes the full fixed
  content and commits it (logged as `ADD`).

On success it logs `APPLY`/`ADD`; on cherry-pick conflict it aborts and reports.

**PR mode (`apply_via_pr`)** — never touches the real branch. Instead:

```mermaid
sequenceDiagram
    participant P as propagate_patch.sh
    participant G as git
    participant H as GitHub (gh / API)
    P->>G: worktree add -B propagate/WI/<branch> (from origin/<branch>)
    alt branch has the file
        P->>G: cherry-pick SOURCE_COMMIT (in the worktree)
        alt cherry-pick conflicts
            P->>G: cherry-pick --abort, remove worktree
            P-->>P: log CONFLICT (non-fatal), continue
        end
    else branch lacks the file
        P->>G: write fixed file content + commit (add_fixed_file)
    end
    P->>G: push -u origin propagate/WI/<branch>
    P->>H: open_pull_request(base=<branch>, head=propagate/WI/<branch>)
    H-->>P: PR url (or "already exists")
    P->>G: remove worktree
```

Supporting functions for PR mode:

| Function | Job |
|----------|-----|
| `github_repo_slug` | Derive `owner/repo` from `GITHUB_REPOSITORY` or the `origin` URL |
| `propagation_branch_name` | Build `propagate/<WI>/<branch-with-slashes-as-dashes>` |
| `branch_to_prop_slug` | Turn `feature/x` into `feature-x` for branch names |
| `pr_title` / `pr_body` | Compose the PR title and Markdown body |
| `open_pull_request` | Use `gh` CLI if present, else the GitHub REST API via `curl`; detects an existing open PR to stay idempotent; honors `DRY_RUN` |
| `branch_ref` / `branch_check_ref` | Resolve a name to a local or `origin/*` ref (PR mode prefers `origin/*` so stale locals can't hide a missing fix) |

### 5.5 Outcome classification & exit code

Each branch's result is recorded to `results.tsv` with one of these statuses:

`APPLIED` · `PR_OPENED` · `PR_EXISTING` · `SKIPPED` · `CONFLICT` · `FAILED`

`classify_failure` decides between a **conflict** (branch has the file but the
cherry-pick clashed — non-fatal, needs a human) and an **unexpected failure**
(anything else — fatal). A branch missing the file no longer fails: it gets the
file added instead.

The script's exit code policy:

- Conflicts are **reported but never fail** the run.
- In PR mode, fewer than `MIN_PRS` pull requests **is** a failure.
- Any *unexpected* failure **is** a failure.

---

## 6. The checker: `verify_propagation.sh`

This asserts the propagation produced exactly the right outcome. It has two
independent code paths matching the two modes.

```mermaid
flowchart TD
    START([verify]) --> D[Rediscover branches<br/>local heads + origin/*]
    D --> C[For each: classify_branch<br/>recompute eligibility from git state<br/>incl. name_after_source]
    C --> A[Assert: eligible → PR / fix / conflict<br/>everyone else → no PR]
    A --> R[print PASS/FAIL tally,<br/>exit non-zero if any FAIL]
```

Verification is **fully dynamic in both modes** — it re-derives eligibility from
live Git state with `classify_branch`
(`eligible | source | propagation | protected | blocked | skip-before |
skip-no-wi | skip-no-file`), then asserts: every eligible branch has a PR (or
already carries the fix, or is a reported conflict), and every other branch has
*no* PR. **No branch names are hardcoded** — the `skip-before` class is computed
with the same `name_after_source` rule as `propagate_patch.sh`, so a branch
whose name sorts on/before the fix branch is expected to have no PR. It reads PR
urls from `pull-requests.txt` / `propagation-summary.txt` and real conflict
status from `results.tsv` (so a `DRY_RUN` run that only records intent still
verifies cleanly).

Helper functions mirror `propagate_patch.sh` (`branch_ref`, `branch_has_file`,
`branch_has_fix`, `branch_mentions_wi`, `name_after_source`, `is_blocked`,
`is_protected`, `list_branches`) plus `pr_for_branch` and `recorded_status` for
reading the logs.

---

## 7. The reporter: `notify_propagation.sh`

Reads `results.tsv` and groups every branch into four buckets:

```mermaid
flowchart LR
    T[results.tsv] --> N[notify_propagation.sh]
    N --> O1[Opened / applied<br/>PR_OPENED, PR_EXISTING, APPLIED]
    N --> O2[Skipped<br/>SKIPPED + why]
    N --> O3[Conflicts<br/>CONFLICT + why]
    N --> O4[No action<br/>FAILED + why]
    O1 & O2 & O3 & O4 --> RPT[plain-text report]
    RPT --> STDOUT[stdout]
    RPT --> GHA[GitHub Actions run summary]
    RPT --> EMAIL{SMTP env set?}
    EMAIL -- yes --> SEND[send email via python3 smtplib]
    EMAIL -- no --> SKIP[skip email cleanly]
```

It always prints the report and writes it to `$GITHUB_STEP_SUMMARY` when in CI.
Email is sent only when all SMTP variables are present; otherwise it is skipped
without error. The email itself is sent by a small inline Python snippet
(`smtplib` + `EmailMessage`) supporting `starttls`, `ssl`, or `none`.

---

## 8. Orchestration

### 8.1 Local: `run_pipeline.sh`

A 3-line pipeline for local runs — generate into a throw-away dir, propagate
(direct mode), verify. This is the safe way to try everything without touching
real branches:

```bash
./scripts/run_pipeline.sh            # uses ./complex-test-repo as the fixture
./scripts/run_pipeline.sh /tmp/demo  # or any throwaway dir
```

### 8.2 CI: `.github/workflows/patch-propagation.yml`

```mermaid
flowchart TD
    PUSH[push / PR to main] --> J1
    subgraph J1 [Job 1: full-integration  — no secrets, always the gate]
        G1[generate fixture] --> P1[propagate direct] --> V1[verify] --> U1[upload logs artifact]
    end
    J1 --> J2
    subgraph J2 [Job 2: live-repo-prs  — needs PROPAGATION_TOKEN]
        TK{token present?} -- no --> NT[skip with notice]
        TK -- yes --> P2[propagate PR mode] --> V2[verify PR mode] --> NF[notify/email] --> U2[upload logs]
    end
```

- **Job 1 (`full-integration`)** builds a fresh fixture and runs the whole
  direct-mode flow in one checkout. It needs no secrets and is the gate that
  must always pass.
- **Job 2 (`live-repo-prs`)** opens *real* PRs on this repo. Because GitHub's
  default `GITHUB_TOKEN` is not allowed to open PRs, it needs a Personal Access
  Token stored as the `PROPAGATION_TOKEN` secret. If that secret is missing the
  job **skips with a notice** instead of failing.

---

## 9. How a single run flows (end to end, direct mode)

```mermaid
sequenceDiagram
    autonumber
    participant U as run_pipeline.sh
    participant Gen as generate_complex_repo.sh
    participant Prop as propagate_patch.sh
    participant Git as git
    participant Ver as verify_propagation.sh

    U->>Gen: build fixture (15 branches)
    Gen->>Git: init + many commits + branches
    U->>Prop: propagate into fixture
    Prop->>Git: find definitive fix commit
    loop each discovered branch
        Prop->>Prop: eligibility decision
        alt eligible & clean
            Prop->>Git: cherry-pick fix → APPLIED
        else conflict
            Prop->>Prop: record CONFLICT (non-fatal)
        else blocked/source/no-WI/no-file
            Prop->>Prop: record SKIPPED/FAILED
        end
    end
    Prop->>Prop: write results.tsv + summary
    U->>Ver: verify fixture
    Ver->>Git: recompute eligibility dynamically (incl. name order)
    Ver-->>U: PASS/FAIL tally
```

---

## 10. Configuration reference (environment variables)

| Variable | Used by | Default | Meaning |
|----------|---------|---------|---------|
| `WI_ID` | all | `WI-440219` | Work item ID |
| `SOURCE_BRANCH` | propagate, verify | `20-bugfix/payment-patch` | Branch holding the fix |
| `AFFECTED_FILE` | propagate, verify | `src/payment/transaction_queue.py` | File the fix changes |
| `FIX_MARKER` | propagate, verify | `threading.RLock()  # WI-440219: definitive thread-safe fix` | Line used to detect a branch that already has the fix |
| `BRANCH_SELECT_MODE` | propagate, verify | `wi-history` | `wi-history` or `affected-file` |
| `PROPAGATION_MODE` | propagate, verify | `direct` | `direct` or `pr` |
| `BLOCKED_BRANCHES` | propagate, verify | `70-infra/kubernetes-config infra/kubernetes-config` | Branches to skip even if eligible (second entry is the protected pre-rename name still on origin) |
| `PROTECTED_BRANCHES` | propagate, verify | `main master` | Integration branches that never receive the fix |
| `MIN_PRS` | propagate | `5` | PR-mode minimum to pass |
| `DRY_RUN` | propagate | `false` | Don't push/open PRs |
| `NOTIFY_EMAIL_TO/FROM`, `SMTP_*` | notify | — | Email delivery (optional) |

---

## 11. Expected results (the contract)

| Branch | Direct mode | PR mode |
|--------|-------------|---------|
| `40-feature/ledger-audit` | fix cherry-picked | PR opened |
| `50-feature/compliance-reporting` | fix cherry-picked | PR opened |
| `60-feature/database-migration` | fix cherry-picked | PR opened |
| `25-feature/payment-hotfix` | conflict (reported) | no PR — conflict reported |
| `70-infra/kubernetes-config` | skipped (blocked) | no PR (blocked) |
| `15-feature/payment-gateway` | skipped (name on/before fix) | skipped (name on/before fix) |
| `05-release/v1.0` | skipped (name on/before fix) | skipped (name on/before fix) |
| `20-bugfix/payment-patch` | source (skipped) | source (skipped) |
| `main` | skipped (protected) | skipped (protected) |
| 6 other branches | skipped (no WI) | skipped |

Net result: **3 applications / 3 PRs** (`40-feature/ledger-audit`,
`50-feature/compliance-reporting`, `60-feature/database-migration`), with one
conflict (`25-feature/payment-hotfix`), one policy block
(`70-infra/kubernetes-config`), and two branches excluded purely by the
name-order rule (`15-feature/payment-gateway`, `05-release/v1.0`) even though
they mention the WI.

---

## 12. Glossary of every source file

| File | One-line role |
|------|---------------|
| `generate_complex_repo.sh` | Builds the deterministic 15-branch test fixture |
| `scripts/propagate_patch.sh` | Finds the fix commit and applies it (direct cherry-pick or PR) |
| `scripts/verify_propagation.sh` | Asserts the propagation outcome is exactly right |
| `scripts/notify_propagation.sh` | Turns `results.tsv` into a grouped report + optional email |
| `scripts/run_pipeline.sh` | Local one-shot: generate → propagate → verify |
| `.github/workflows/patch-propagation.yml` | CI runner for both the integration gate and live PRs |
| `README.md` | Usage-focused quick start |
| `ARCHITECTURE.md` | This deep-dive |
| `.gitignore` | Keeps generated fixtures and logs out of version control |
