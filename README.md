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

## GitHub Actions

Open **Actions → Patch Propagation CI** on this repo.

| Job | When | What it does |
|-----|------|--------------|
| **Full integration** | Every push/PR to `main` | Generates fresh fixture → propagates → verifies |
| **Live repo test** | Manual only (`Run workflow` + enable live propagation) | Propagates on this repo and pushes branches back |

### Trigger live propagation on GitHub

1. **Actions → Patch Propagation CI → Run workflow**
2. Set **run_live_propagation** to `true`
3. Run — watch branches update on GitHub

## Expected propagation results

| Branch | Result |
|--------|--------|
| `feature/payment-gateway` | Fix applied |
| `feature/ledger-audit` | Fix applied |
| `feature/compliance-reporting` | Fix applied |
| `bugfix/payment-patch` | Source (already fixed) |
| `release/v1.0`, `feature/database-migration`, `infra/kubernetes-config` | WI match, cherry-pick fails (no payment file) |
| Other branches | Skipped (no WI in history) |
