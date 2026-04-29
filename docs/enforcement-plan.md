# Enforcement plan — branch protection, PR gates, agent conventions

Status as of 2026-04-30. Single-author public repo (`laurentfabre/pdf.zig`), Zig 0.15.2.

Adapted from the zlsx companion repo's enforcement plan (`/Users/lf/Projects/Pro/zlsx/docs/enforcement-plan.md`). Same five-phase shape; pdf.zig-specific paths and CI matrix.

## Status table

| Phase | Description | Status |
|---|---|---|
| 1 | Free wins: branch protection, repo merge settings, CODEOWNERS, PR template | **Local files done; gh-api side pending** |
| 2 | TDD CI gates: test-presence, C-ABI 3-file-transaction, monotonic test count | Not started |
| 3 | Worktree + subagent conventions: helper script, commit-msg trailer, PR template fields | Not started |
| 4 | Agent-as-reviewer CI job (codex-review-on-PR) | Not started |
| 5 | Optional: coverage gate, TDAD map, mutation testing | Deferred |

---

## Baseline (what exists today)

| Layer | State |
|---|---|
| `main` branch protection | None. Direct push allowed. |
| Required status checks | None. CI runs but does not gate merges. |
| Required reviews | None. |
| CODEOWNERS / PR template / Dependabot | Absent (this PR adds the first two). |
| Pre-commit hook | None on this repo. |
| Pre-push hook | None. |
| CI workflow | `ci.yml`: single `Build + test (Linux x86_64)` job — `zig build`, `zig build test`, streaming-layer module tests, smoke fuzz (50k iters), alloc-failure shape, binary smoke, cross-compile sanity to 5 targets. Plus a weekly `Full fuzz` job (1M iters, schedule + workflow_dispatch). No per-OS matrix; Linux only. |
| Worktree convention | None. Single worktree on `main`. |
| Subagent attribution | None. |
| Merge styles | Whatever GitHub repo settings default to. `delete_branch_on_merge` not enforced. |

**Net**: a careful solo dev can push directly to `main` and merge a red PR. Only client-side discipline catches mistakes.

---

## Five gates — mechanism + recommendation

### 1. Worktree per PR

Solves: parallel agent sessions stomping each other; cache thrash from branch-switching.

| Layer | Enforceable? |
|---|---|
| Server-side | **No.** GitHub has no concept of which checkout you used. |
| Client-side | A `scripts/wt-new <branch>` helper that creates `../pdf.zig-<branch>` with isolated cache. |
| Convention | Document in AGENTS.md so agents and humans default to it. |

**Recommendation**: convention + helper, not a hard gate. Cost of dropped enforcement is "cache rebuild," not data loss.

### 2. Subagent per PR

Solves: attribution, reproducibility, writer/reviewer hygiene.

| Mechanism | Enforceability |
|---|---|
| Commit-msg trailer (`Agent: <name>`) | Soft — forgeable, but useful as a default. |
| PR template field (Author agent / Reviewer agent) | Soft — relies on filling the template. |
| Writer/reviewer split | Workflow discipline; not enforceable in git/CI. |

**Recommendation**: PR template field + soft commit trailer. Don't gate.

### 3. TDD

| Mechanism | What it catches | Cost | Verdict |
|---|---|---|---|
| Test-file-changed-when-source-changed CI rule | Adding `src/foo.zig` without touching tests | Trivial — diff parse | Worth doing. ~10% false-positive rate on refactors; escape via PR label. |
| Coverage gate (`zig test --test-coverage` + kcov, Linux only) | Untested code paths | Tooling is rough | Skip for now. |
| Mutation testing | Tests that exist but don't test anything | No Zig tooling | Skip. |
| Monotonic test count | Stealth test deletion | One-line CI check | Worth doing. |
| TDAD (code-to-test dependency map) | Per AGENT-PRACTICES research: 70% regression reduction vs procedural TDD prompts | Map-gen script + agent integration | One-time experiment, not a hard gate. |
| C ABI 3-file-transaction check | The `capi.zig` ↔ `_cdef.h` ↔ `_ffi.py` rule | CI diff check | Worth doing — highest ROI for keeping the Python binding coherent. |
| Writer 3-file-transaction check | `pdf_writer.zig` / `pdf_document.zig` / `markdown_to_pdf.zig` correlation | CI diff check | Defer; the writer surface is small and currently single-author. |

**Recommendation**: build the C-ABI 3-file-transaction check first, then test-presence + monotonic count. Skip coverage and mutation tooling.

### 4. Merge guards

GitHub branch protection on `main`:

| Setting | Recommended | Why |
|---|---|---|
| Require pull request | Yes | Forces CI on the diff |
| Required approvals | 0 (solo) → 1 when collaborators land | Can't approve own PR; gating self blocks all work |
| Dismiss stale approvals on new commits | Yes | Approvals follow code, not time |
| Required status checks | Yes — `Build + test (Linux x86_64)`. Skip `Full fuzz` (workflow_dispatch / schedule only, doesn't run on PR). | |
| Require branches up-to-date before merging | Yes | Catches semantic conflicts |
| Require conversation resolution | Yes | PR-review hygiene |
| Signed commits | Optional | Worth it across multiple machines |
| Linear history | Yes | Forces squash or rebase; no merge commits |
| Block force pushes | Yes | |
| Block deletions | Yes | |
| Restrict who can push | Owner + admins | |
| Allow bypass | No, even for admins | Or "yes but log it" if you need an emergency lever |

Plus repo-level: disable merge-commit style, enable auto-delete on merge.

**Recommendation**: do this first. Highest ROI of the entire plan. Solo-author still benefits.

### 5. Review

| Mechanism | Cost | Verdict |
|---|---|---|
| Required approvals = 1 | Free, but blocks solo work | Skip while solo. Enable when second contributor lands. |
| `CODEOWNERS` for paths | One file | Worth adding even solo: `* @laurentfabre` for now. |
| Agent-as-reviewer (auto-run codex review on PRs) | Hook + CI artifact upload | The interesting option. Real value. Phase 4. |
| `dangerjs`-style PR linter | One config | Low-value at this scale. Skip. |
| PR template | One file | Worth it. Forces scope/test/ABI thinking. |

**Recommendation**: PR template + agent-as-reviewer CI job (Phase 4).

---

## Layered plan, in priority order

### Phase 1 — Free wins (~10 minutes)

1. Branch protection on `main`: required PR + required status check (`Build + test (Linux x86_64)`) + linear history + block force/delete + dismiss stale approvals + 0 required approvals.
2. Repo merge settings: disable merge-commit, enable auto-delete on merge.
3. `.github/CODEOWNERS` with `* @laurentfabre`.
4. `.github/pull_request_template.md` with: summary, scope, test plan, C ABI impact, writer impact, roadmap link, agent attribution.

### Phase 2 — TDD CI gates (~1-2 hours)

5. **Test-presence check**: CI fails if a `src/*.zig` non-import-only change ships with no test change. Escape via PR label `no-test-needed`.
6. **C-ABI 3-file-transaction check**: CI fails if `src/capi.zig` changes without `python/zpdf/_cdef.h` AND `python/zpdf/_ffi.py` changing.
7. **Monotonic test count**: PR cannot net-decrease `^test "` blocks under `src/` without label `delete-tests-ok`.

### Phase 3 — Worktree + subagent conventions (~30 minutes)

8. **`scripts/wt-new <branch>`**: helper that creates `../pdf.zig-<branch>` with isolated cache.
9. **Commit-msg hook**: require `Agent: <name>` trailer (soft warn, not error).
10. **PR template fields**: "Author agent" / "Reviewer agent" (already in this PR's template).

### Phase 4 — Agent-as-reviewer (~half a day)

11. **GitHub Actions job: codex-review-on-PR**. Runs a constrained codex review on the diff, posts findings as a PR comment. Required to pass (or to post) before merge.

### Phase 5 — Optional, gate by pain

12. Coverage gate via `zig test --test-coverage` + kcov on Linux only.
13. TDAD code-to-test map generator.
14. Mutation testing (defer indefinitely; no Zig tooling).

---

## What NOT to do

- Require human review approval while solo — blocks all work.
- Gate merges on the weekly `Full fuzz` job — it doesn't run on PRs.
- Gate merges on coverage thresholds — Zig tooling is rough; false-fails will exceed signal.
- Enforce "subagent per PR" via CI — trailers are forgeable; the value is in *how* you invoke agents.
- Add husky / Node-based hook framework — bash hooks already work.
- Enforce TDD via "test ratio" metrics — Goodhart's law; people pad with trivial tests.

---

## Phase 1 — implementation log

- [x] `.github/CODEOWNERS` created — `* @laurentfabre`
- [x] `.github/pull_request_template.md` created — summary, scope, test plan, C ABI 3-file checklist, writer impact, roadmap link, agent attribution
- [ ] **Pending (gh api, applied after PR merge)** — branch protection on `main`:
  ```sh
  gh api -X PUT repos/laurentfabre/pdf.zig/branches/main/protection \
    -F required_pull_request_reviews.required_approving_review_count=0 \
    -F required_pull_request_reviews.dismiss_stale_reviews=true \
    -F required_status_checks.strict=true \
    -F 'required_status_checks.contexts[]=Build + test (Linux x86_64)' \
    -F enforce_admins=true \
    -F required_linear_history=true \
    -F allow_force_pushes=false \
    -F allow_deletions=false \
    -F required_conversation_resolution=true \
    -F restrictions= \
    -F lock_branch=false
  ```
- [ ] **Pending (gh api)** — repo merge settings:
  ```sh
  gh api -X PATCH repos/laurentfabre/pdf.zig \
    -F allow_merge_commit=false \
    -F allow_squash_merge=true \
    -F allow_rebase_merge=true \
    -F delete_branch_on_merge=true
  ```

> **Note**: branch protection and repo settings are applied via `gh api` after this PR merges (otherwise the PR enabling protection would itself be blocked). The commands above are committed here so the repo-state changes are auditable from git history. Restore-current-settings probe: `gh api repos/laurentfabre/pdf.zig/branches/main/protection`.

## Phase 2 — implementation log

(To be filled by the Phase 2 PR.)

---

## Phase 1 — operational note

After branch protection lands, `main` becomes PR-only. To land changes:

```sh
git switch -c <branch>
# ... commits ...
git push -u origin <branch>
gh pr create --fill
# wait for CI green, then:
gh pr merge --squash --delete-branch    # or --rebase
```

Direct `git push origin main` will be rejected. If `enforce_admins` proves too strict during emergencies, soften with:

```sh
gh api -X PATCH repos/laurentfabre/pdf.zig/branches/main/protection/enforce_admins -F enabled=false
```
