# Enforcement plan — branch protection, PR gates, agent conventions

Status as of 2026-04-30. Single-author public repo (`laurentfabre/pdf.zig`), Zig 0.15.2.

Adapted from the zlsx companion repo's enforcement plan (`/Users/lf/Projects/Pro/zlsx/docs/enforcement-plan.md`). Same five-phase shape; pdf.zig-specific paths and CI matrix.

## Status table

| Phase | Description | Status |
|---|---|---|
| 1 | Free wins: branch protection, repo merge settings, CODEOWNERS, PR template | **Local files done; gh-api side pending** |
| 2 | TDD CI gates: test-presence, C-ABI 3-file-transaction, monotonic test count | **Done (advisory; promote to required after a few green runs)** |
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

- [x] `.github/workflows/pr-gates.yml` created — wires three jobs on `pull_request` events (`opened`, `synchronize`, `reopened`, `labeled`, `unlabeled`). Labeled events re-run the gates so escape labels take effect without an empty commit.
- [x] `scripts/ci/test-presence-check.sh` (Gate 5) — `src/*.zig` non-trivial change must come with a `test "..."` block, `python/tests/` change, or a `src/integration_test.zig` / `src/alloc_failure_test.zig` change. Escape: `no-test-needed`.
- [x] `scripts/ci/abi-3file-check.sh` (Gate 6) — `src/capi.zig` changes must come with both `python/zpdf/_cdef.h` AND `python/zpdf/_ffi.py`. Escape: `abi-no-3file`.
- [x] `scripts/ci/monotonic-test-count.sh` (Gate 7) — total `^test "` count under `src/` must not net-decrease. Escape: `delete-tests-ok`.
- [ ] **Pending (gh api, applied after PR merge)** — escape labels created on GitHub:
  ```sh
  gh label create no-test-needed   --description 'PR is intentionally test-neutral (refactor, comments-only, formatting)' --color BFD4F2 -R laurentfabre/pdf.zig
  gh label create abi-no-3file     --description 'src/capi.zig change is internal; does not alter the public ABI surface' --color BFD4F2 -R laurentfabre/pdf.zig
  gh label create delete-tests-ok  --description 'Net test deletion is intentional (deprecation)' --color BFD4F2 -R laurentfabre/pdf.zig
  ```
- [x] Local smoke-tested against historical commits (Phase 2 PR description has the full command transcript):
  - **ABI gate** correctly fails on `15c62829` ("v1.5 RC: capi exports + Python binding wired into release"), which touched `src/capi.zig` + `python/zpdf/_cdef.h` but not `python/zpdf/_ffi.py`. Would have caught the real historical ABI lockstep gap.
  - **Test-presence gate** correctly fails on `2f073f6` (PR-W6.4) — the AcroForm fixture migration. Expected behavior: the gate doesn't know `testpdf.zig` is itself a test fixture file. The right answer for a refactor PR is the `no-test-needed` label; the escape label was verified to skip the gate cleanly.
  - **Monotonic gate** correctly fires on a synthetic `337 → 314` regression (HEAD compared against pre-W6 history); the `delete-tests-ok` escape skips cleanly.
- [ ] **Pending** — promote gates to `required_status_checks` after a few green PR runs. Three contexts to add: `Test-presence check`, `C ABI 3-file transaction`, `Monotonic test count`. Keep them advisory until at least one PR exercises each escape label so we know the escape actually works in CI (not only locally).

### Local invocation (debugging a gate)

```sh
BASE_SHA=$(git merge-base origin/main HEAD) HEAD_SHA=HEAD LABELS='[]' \
  bash scripts/ci/test-presence-check.sh

BASE_SHA=$(git merge-base origin/main HEAD) HEAD_SHA=HEAD LABELS='["abi-no-3file"]' \
  bash scripts/ci/abi-3file-check.sh

BASE_SHA=$(git merge-base origin/main HEAD) HEAD_SHA=HEAD LABELS='[]' \
  bash scripts/ci/monotonic-test-count.sh
```

### Known limitations

- **Test-presence**: heuristic "non-trivial change" filter strips blank lines and `// ...` comments only. Multi-line `///` doc-comments still count as significant; tolerable since the escape label exists. Also: `src/testpdf.zig` is a fixture-generator file but the gate sees it as `src/*.zig` — refactor PRs that only change fixtures need the `no-test-needed` label even though they're "test-adjacent".
- **ABI gate**: only triggers when `src/capi.zig` is in the changed-file list. An ABI-affecting change made elsewhere (e.g., changing an extern struct's layout via a `pub const` in another file imported by `capi.zig`) won't be caught.
- **Monotonic**: counts `^test "` exactly — moving a test from `test "foo"` to `test "renamed"` is a no-op (count preserved), but reformatting a test header onto a multi-line form would silently drop it.

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
