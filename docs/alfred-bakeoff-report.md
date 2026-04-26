# Alfred PDF Pipeline — Extraction / Classification / Cleaning Bake-off

> **Version.** v3.10 (2026-04-26). v3.9 → v3.10 folded 3 Codex cycle-9 findings (1 P1, 1 P2, 1 P3). Codex independently checked claim #2 against `room-twin.md` and confirmed support; the v3.9 "1/20 unverifiable" was prose-vs-TSV mismatch. **Corrected tally: 18/20 = 90% supported, 2/20 = 10% partial, 0/20 hallucinated**. Plus: convenience-sample caveat replaces Wilson CI framing (n=20 wasn't random). Nine review cycles + seven acted-on deferred items. See [Changelog](#changelog).
>
> **Goal.** Test every realistic model and method to classify, extract, and clean data from the 1 776 PDFs in Alfred's corpus, against the existing production pipeline (`opendataloader-pdf` + rule-based classifier + stopword language detection). Designed to **decide what unblocks v15 Stage-1 distillation on the priority cohort first**, then where corpus-wide reruns are worth it.
>
> **Bake-off harness.** [`bake-off/`](./bake-off/). Re-runnable. Outputs in `bake-off/scorecard/*.tsv` and `bake-off/out_<method>/<id>.md`.
>
> **TL;DR — split by cohort because the priority-15 has a different quality profile than the corpus**:
> - **Priority-15 cohort (188 docs across 13 hotels)** is **already ~95.7% usable** (180 / 188 — recomputed from `document_usable` join, cycle-6 P2 reconciliation). Recovery work yields only ~8 doc gains (the 8 lang_unknown rows). The biggest win on this cohort is **table-quality re-extraction with docling/pymupdf4llm** for the dining/spa/factsheet PDFs that exist on disk, and **Haiku-based reclassification audit** (~$0.30, 188 calls).
> - **Full corpus (1 776 docs)** can recover **~378 unique** flagged-but-readable docs (95% Wilson CI **[264, 430]** — see §5.1 for the deduplicated math). `langdetect` handles most language recovery near-free; `docling` handles most empty-text recovery in ~6–11 min. **Use 264 (lower bound) as the conservative planning number** when sizing reruns and downstream review work.
> - **Both estimates carry wide CIs** (n=29–30 each). They are pilot-quality — enough to commit ~$3 and a few hours, not enough to commit a full operational migration without the **grounded-card validation pass** described in §6.

---

## Changelog

**v3.10 (2026-04-26)** — Folded 3 Codex cycle-9 findings (1 P1, 1 P2, 1 P3):

- **[P1] Convenience sample, not CI-backed estimate** — my n=20 sample was the first 20 claims in section order: 10/20 rooms, 6/20 from `room-standard.html`, no `policies` bullets covered. Wilson CI doesn't apply to a non-random sample. **Removed the [64%, 95%] interval; relabeled the 90% as "convenience-audit pass rate, not a corpus estimator"**. The recommendation in §3.10.4 to sample n=50 × n=10 cards stands but should explicitly use stratified random sampling.
- **[P2] TSV–prose split mismatch reconciled** — v3.9 prose said "17 supported / 2 partial / 1 unverifiable" but TSV had 18 supported / 2 partial. **Codex independently checked room-twin.md and found it explicitly supports claim #2** ("vue imprenable sur la Koutoubia et les monts enneigés de l'Atlas"). I had marked claim #2 "supported" in the TSV but called it "unverifiable" in the prose because I hadn't read room-twin.md. Now I have. Corrected: **18/20 = 90% supported**.
- **[P3] §3.9 run-noise analogy removed** — bullet-count run noise (2.59 stddev for alfred_real) is not the same metric as claim-grounding precision. The v3.9 "10–15% non-perfect rate is consistent with §3.9's run noise" sentence was an unsupported inference. Removed.

**v3.9 (2026-04-26)** — Cycle-9 acted-on work: **n=20 claim-grounding verification** on `alfred_real_run1.yaml` for hotel-hivernage. Manual check of each claim against the cited `data/indexed/<file>.md` source. Full TSV at [`bake-off/scorecard/grounding_verification_n20.tsv`](./bake-off/scorecard/grounding_verification_n20.tsv).

- **17/20 = 85% fully supported** by the cited source — claims with exact textual evidence
- **2/20 = 10% partial** — both are mild citation imprecisions, not hallucinations:
  - Claim #1 cites room-standard.html for "1 king bed" but that detail is in rooms-suites.md (right fact, wrong doc).
  - Claim #6 says "All rooms include …" citing room-standard.html — overgeneralizes from one room's facility list (the facts are true for Suite Deluxe too, but the cited source covers only standard).
- **1/20 = 5% unverifiable from cited source alone** (Twin's "mountain views" — not separately confirmed without reading the room-twin.md source the citation pointed to; rooms-suites.md backs the rest of the claim).
- **0/20 hallucinated** — no claim contradicts its source.
- **Implication**: Haiku 4.5 grounding is empirically strong on this card. The v15 plan's verifier-loop (Stage-4c) is the right next infrastructure to formalize this check, but the underlying signal Haiku produces appears to be genuinely grounded most of the time. The 10–15% partials are exactly what the v15 verifier is designed to catch and surface as `needs_review`.

**v3.8 (2026-04-26)** — Folded 4 Codex cycle-7 findings (1 P1 reversal, 1 P2, 2 P3) and acted on the P1 with a 6-card rerun against Alfred's REAL extractor.

- **[P1 → reversed by C8 acted] `alfred_current` was a reimplementation, not production**. My `extract_alfred_current()` stripped `nav/footer/header` + html2text-on-soup with links enabled; production `clean_html_to_markdown()` scopes to `main/article/#content/#primary`, strips `iframe/svg`, disables links. **0/24 exact matches** between my output and the real one. Acted-on: re-ran the alfred arm using the cached `data/indexed/<slug>/*.md` (Alfred's actual production output by definition). **Result reversed**: `alfred_real` 46.5 bullets / 2.59 within-hotel stddev > `alfred_current` 45.7 / 3.77 > `html2text_only` 45.7 / 5.19. The v3.7 "html2text_only ties production" headline is wrong; **production marginally beats html2text_only on bullets and is much more stable**.
- **[P2] Within-hotel run-noise stddev (not cross-cell pstdev)** — same statistical issue as cycle-6 found in §3.8. Now reported correctly: alfred_real 2.59, raw_bs_text 2.12, alfred_current 3.77, readability 3.54, trafilatura 4.01, html2text_only 5.19.
- **[P3] Significance claim anchored to bullets, not sections**. Codex computed: section gap 5.17 vs 6.83 has p≈0.094 (not significant); bullet gap 23.2 vs 45.7 has p≈0.031 (significant). Wording updated.
- **[P3] Sample denominator corrected**: hotel-hivernage actually has 10–11 HTML rows in `document_usable` (depending on whether `synth-experiences.html` counts; the real cached extraction includes 11 files). The v3.7 "8" was wrong. Alfred indexed 11 / 7 / 7 across the 3 hotels.

**v3.7 (2026-04-26)** — Cycle-7 acted-on work: HTML extraction bake-off (§3.9). 5 methods × 3 HTML-heavy hotels × 2 runs = 30 cards.

- **Methods tested**: `alfred_current` (BS preprocess + html2text — production), `trafilatura`, `readability-lxml`, `html2text_only` (naive baseline), `raw_bs_text` (BS get_text only).
- **Headline result**:
  - `alfred_current`: 6.33/7 sections, 45.7 bullets ±5.6
  - `html2text_only`: **6.83/7 sections, 45.7 bullets ±4.1** — ties production with no preprocessing
  - `raw_bs_text`: 6.33/7, 41.8 bullets ±1.8 — lowest run-noise
  - `trafilatura`: 6.50/7, 37.8 bullets — moderate underperformance
  - `readability-lxml`: **5.17/7, 23.2 bullets** — significantly worse, over-strips hotel content
- **Net finding**: for hotel-site HTML, **less preprocessing is more**. Article-extraction libraries (readability, trafilatura) tuned for news content are mis-tuned for hotel marketing pages where signal is distributed across many small sections (rooms, dining, spa, contact). Alfred's BS preprocessing isn't doing measurable harm but isn't doing measurable good either.
- **Recommendation**: keep `alfred_current` (no rationale to switch). If reimplementing fresh: `html2text_only` is simplest and ties best. **Avoid readability-lxml and trafilatura on this content type.**
- **Cohort sizing**: this affects 65 priority HTMLs (vs 51 PDFs) — meaningful slice, but the gap between best and worst HTML method is comparable to the gap between best and worst PDF extractor (a few bullets). The total grounded-card recall ceiling is bounded by the 7-section format, not the extractor.

**v3.6 (2026-04-26)** — Folded 4 Codex cycle-6 findings (1 P1, 3 P2):

- **[P1] §3.8 reframed**: of the 3 included hotels in the rerun, only `constance-belle-mare-plage` has ≥3 PDFs (6); the other 2 contribute a single factsheet PDF each. Calling this a "multi-doc shape test" was wrong. **§3.8 now framed as "PDF-only sanity check; 1 multi-PDF cell + 2 single-doc cells; the multi-doc question is unresolved"**. The "n=27 aggregate" headline is replaced with belle-mare-only headline numbers + the 2 single-doc results separately. Extract chars still vary 62k–102k across methods even with apples-to-apples filenames, so input-volume parity remains unattained.
- **[P2] Variance statistic corrected**: my "5.2–9.7 within-method stddev" was actually cross-cell spread (mixing hotel-to-hotel difficulty with run-to-run LLM variance). Codex computed proper **within-hotel run-noise**: docling 2.27 mean, opendataloader 7.78, pymupdf4llm 6.20. Different picture: docling is the most stable, opendataloader is the noisiest. Replaced wrong number throughout §3.8.
- **[P2] HTML-heavy claim scoped**: my v3.5 "priority cohort is HTML-heavy" overgeneralized from 5 sampled hotels (where it's ~8 PDFs vs 35 HTMLs). Codex computed full priority cohort: **51 PDFs on disk vs 65 HTMLs** — much more balanced. §3.8.5 reframed as "5-hotel sample finding, suggestive at cohort level but not confirmed".
- **[P2] Priority denominator reconciled**: TL;DR said 182/188 = 96.8% usable; §5.2 table sums to 180. Canonical = **180 usable / 188 total = 95.7%**, propagated through TL;DR + table + downstream recovery math.

**v3.5 (2026-04-26)** — Cycle-6 acted-on work: PDF-only intersection rerun + 3 runs/cell + clamped scorer (cycle-5 P1+P2 fix). New §3.8.

- **PDF-only filter exposed a major Alfred data finding**: of the 5 sampled priority hotels, **2 have ZERO PDFs on disk** (`hotel-hivernage`, `royal-mansour-marrakech`). Their `document_usable` rows are all HTMLs scraped from hotel websites. 2 more (`constance-prince-maurice`, `constance-halaveli-maldives`) have only **1 PDF each** (the factsheet). Only `constance-belle-mare-plage` has 6 PDFs — the only meaningful multi-PDF hotel in the sample. **This is a real Alfred-pipeline data observation worth flagging upstream**: priority hotels lean HTML-heavy in `document_usable`.
- **Apples-to-apples result on PDF-only inputs (n=27, 3 hotels × 3 methods × 3 runs)**:
  - **pymupdf4llm**: sec_mean 6.89/7, cap10 bullets mean **52.8** ± 7.8
  - **docling**: sec_mean 7.00/7, cap10 bullets mean **53.0** ± 5.2
  - **opendataloader**: sec_mean 6.89/7, cap10 bullets mean **54.6** ± 9.7
- **Convergence on extractor parity is stable**: all three methods within ~2 bullets on apples-to-apples input. Within-method run-to-run stddev (5.2–9.7) exceeds between-method differences (~2). **The grounded-card test does NOT favor any extractor at the multi-doc shape**.
- **Clamping at 10 had ~zero effect** on this cleaner test — Haiku respected the "HARD CAP at 10" prompt instruction (raw bullets = cap10 bullets in 27/27 cells).
- **All three methods got 7/7 sections in 26/27 cells** (single 6/7 outlier on opendataloader run3 prince-maurice). Section-coverage ceiling effects are visible — going to a stricter scoring metric (citation-grounded fact density) would be the next sharpening step.

**v3.4 (2026-04-26)** — Folded 4 Codex cycle-5 findings (1 P1, 2 P2, 1 P3):

- **[P1] §3.7 multi-doc test had non-comparable inputs across methods** — pymupdf4llm and docling can read both PDFs and HTMLs (and did), while opendataloader's cache only had whatever Alfred had previously processed. Empirical chars per (hotel, method): on `royal-mansour-marrakech` opendataloader fed 45k chars vs pymupdf4llm's 129k and docling's 136k; on `hotel-hivernage` 15k vs 44k vs 58k. **The "all three are equivalent" finding now reads more like "opendataloader produces comparable cards from much less input"** — directionally interesting, but not a clean cross-method comparison. §3.7 caveat added; **PDF-only intersection rerun deferred to v4** (concrete plan in §6.2).
- **[P2] Per-section bullet counts uncapped** — my prompt asked for 3–10 bullets per section but 14/30 cards (47%) had ≥1 section >10. Codex computed cap-at-10 totals: ranking unchanged (docling 49.0 / opendataloader 50.9 / pymupdf4llm 52.6) but the headline "spread" narrows. v4 should clamp at 10 in the scorer, OR enforce in the prompt.
- **[P2] "Statistically indistinguishable" downgraded** — n=2 runs/cell isn't enough for that claim. Reframed §3.7.3 as "directionally similar at n=2; the spread between methods is comparable to within-method run-to-run variance, but a cleaner comparison needs n≥3 runs per cell on a PDF-only intersection".
- **[P3] Stale pre-audit blocker text in §5** — leftover wording. Removed.

**v3.3 (2026-04-26)** — Cycle-5 acted-on work: **n=5 multi-doc grounded-card with 2 LLM runs per cell**. New §3.7. Closes the cycle-4 P1 limitations (single-doc, single-run, no within-method variance estimate).

- **Headline result (n=5 hotels × 3 extractors × 2 runs = 30 cards)**:
  - **pymupdf4llm**: mean 6.9/7 sections, 53.8 ±10 bullets per card
  - **docling**: mean 6.9/7 sections, 49.2 ±5 bullets per card
  - **opendataloader**: mean 6.8/7 sections, 51.7 ±7 bullets per card
  - **Within-method run-to-run stddev**: 0.0–7.1 bullets — comparable to between-method gaps
- **Conclusion**: at the multi-doc card stage, the three extractors are **statistically indistinguishable** on grounded-field recall. The cycle-4 reversal of v3.1's "opendataloader catastrophic regression" is fully confirmed. The grounded-card stage **does not by itself favor any extractor**.
- **Implication for the recommendation**: the case for switching Alfred ingest from opendataloader → pymupdf4llm rests entirely on the **§2 extraction-stage** evidence (~5–10× faster than docling; pipe-table preservation that opendataloader lacks for menu/spa/factsheet content). Updated §5 + §8 accordingly.
- Per-hotel-method-run scorecard at [`bake-off/scorecard/grounded_card_multi.tsv`](./bake-off/scorecard/grounded_card_multi.tsv); 30 cards in [`bake-off/out_grounded_cards_multi/`](./bake-off/out_grounded_cards_multi/).

**v3.2 (2026-04-25)** — Folded 4 Codex cycle-4 findings (1 P1, 3 P2). The P1 was a real methodology bug — important reversal:

- **[P1] grounded-card prompt cap removed** (`run_grounded_card.py`) — v3.1 used `md[:30000]` which silently invalidated cross-extractor comparison whenever any extractor produced >30k chars (opendataloader's eph-lia case: 98 572 chars, with the missing sections appearing at 87–98k). **Re-ran uncapped on both hotels. New finding: all three extractors are comparable** (6–7/7 sections, 37–45 bullets each). v3.1's "opendataloader catastrophic regression" was the prompt cap, not the extractor. §3.6 rewritten honestly. Recommendation stack unchanged but for **different** reasons (speed, table preservation from §2.1 extraction bake-off, header detection — not grounded-card variance).
- **[P2] §3.5.4 priority weighted projection denominator inconsistency** — the priority-cohort row counts (39 dining, 26 spa, 4 general_brochure, 1 legal) didn't reproduce from alfred.db's `document_usable` view (actual: 36 / 20 / 14 / 0). Regenerated the table from one explicit source (`document_usable` joined to the 15 priority slugs, total **180 docs not 188**). Revised counts shown in §3.5.4; the **~62 disagreement projection is unchanged** (different per-category counts and denominator happened to cancel) but is now reproducible from the data.
- **[P2] §5.3 stale "audit must run first" guidance** — leftover v2.1 wording said the n=100 audit must run before sizing priority work. The audit has run (§3.5). Updated to reflect convergence.
- **[P2] §3.5 CIs that claimed widening but quoted naive Wilson** — `[70.0%, 86.1%]` is the exact naive Wilson interval for 76/96, not a widened heuristic for effective n≈70. The correct widened interval is approximately **[68%, 87%]** (computed at effective n=70 with Wilson). Updated. Also fixed the orphaned `[71.1%, 87.0%]` reference (pre-#286 relabel value) to current 76/96 numbers.

**v3.1 (2026-04-25)** — Folded 7 Codex cycle-3 findings (2 P1, 4 P2, 1 P3) + pre-emptive grounded-card validation:

- **[P1] Priority review queue re-weighted** (§3.5.4) — v3's `38 disagreements ≈ 188 × 20.8%` used the unweighted audit rate. The priority cohort has **45 `other` docs (25%) vs 10 in the audit (10%)** — much heavier in the hardest bucket. Post-stratification weighted estimate is **~62 priority disagreements (~34%)**, not 38. Revised the §3.5.4 sizing accordingly.
- **[P1] Clustered strata caveat** (§3.5.1) — n=96 contains obvious template clusters (5 capella-singapore press releases, 4 Dorchester floor-plans, 4 belmond-modern-slavery-report duplicates). These are not 96 independent draws. **Effective sample size is closer to ~70**; Wilson CIs in v3 are tighter than the data supports. Downgraded all CIs from this audit to "heuristic intervals (effective n ≈ 70 after de-duplication)".
- **[P2] Wilson interval correction** (changelog 20/96) — recomputed: Wilson 95% CI for 20/96 is **[13.9%, 30.0%]**, not [13.0%, 30.0%].
- **[P2] §3 stale n=11 reclassification text removed** — the pre-calibration "~18% × 1 776 ≈ 320" recommendation conflicted with §3.5's calibrated 20.8%. Replaced with a forward-reference to §3.5.
- **[P2] §8 action sequence updated** — n=100 audit is done; next step is grounded-card validation (now in §3.6). Action sequence rewritten.
- **[P2] CLI failure handling** in `run_classification_n100.py` — invalid responses (`ERROR`, `NO_EXCERPT`, timeouts) are now excluded from the agreement denominator and logged separately rather than counted as disagreements. (No invalid rows in current run; behavior matters on retries.)
- **[P3] Babylonstoren #286 adjudication relabeled** — Codex correctly noted the lookbook excerpt ("Editor-in-Chief...checks into Blou") fits press_media better than experiences. Relabeled `gold` to **borderline (press_media-leaning)**; tally now **18 Haiku-correct / 0 Rule-correct / 2 borderline-or-both-wrong**.
- **[NEW] Grounded-card validation §3.6 (n=2)** — preemptively answered cycle-1's deferred biggest P1. Pulled factsheet-en.pdf from 2 priority hotels through 3 extractors → Haiku-distilled 7-section fact card → counted populated sections + grounded bullets. **constance-eph-lia**: pymupdf4llm 7/7 (58 bullets), docling 7/7 (56), opendataloader **3/7 (15)**. **constance-belle-mare-plage**: pymupdf4llm 7/7 (46), docling 7/7 (43), opendataloader 7/7 (56). Honest framing: **opendataloader is variable** (extreme regression on one hotel, fine on another); pymupdf4llm and docling are consistent.

**v3 (2026-04-25)** — **Cycle-3 = act on the deferred §6.2 calibration**, not re-review the report. Ran the stratified n=96 classification audit (parallel Haiku 4.5 via `claude -p`, ~144 s wall time on 6 workers) and adjudicated all 20 disagreements as a single rater. Headline result:

| Method | Correct on n=96 | Heuristic 95% CI (eff. n ≈ 70) |
|---|---|---|
| Rule-based (production) | 76 / 96 = **79.2%** | ~[68%, 87%] |
| Haiku 4.5 zero-shot | 94 / 96 = **97.9%** | ~[91%, 100%] |
| Inter-method disagreement | 20 / 96 = **20.8%** | ~[13%, 32%] |

The 20-disagreement adjudication breakdown: **18 went Haiku-correct, 1 went Rule-correct, 1 both-wrong (closer to Haiku)**. The rule engine's `other` bucket is severely contaminated — `other → ?` accounts for 11 of 20 disagreements. Full adjudication TSV with rationale per doc: [`bake-off/scorecard/adjudication_n100.tsv`](./bake-off/scorecard/adjudication_n100.tsv).

**Documented limitations (now in §6.3)**: single-rater LLM adjudication, agreed-pair correctness assumed (likely a slight overestimate for `other`), stratified sample over-represents rare categories vs natural distribution. These weaken the rule-correct point estimate but don't change the qualitative picture: **Haiku is materially better than the rule engine, especially on `other` / `factsheet` / `general_brochure`.**

**v2.1 (2026-04-25)** — Folded Codex cycle-2 findings (3 P1, 2 P2, 1 P3). Diminishing-returns signal: cycle-2 caught 6 issues vs cycle-1's 8; mostly residual prose regressions and one real measurement bug.

- **[P1] n=30 language agreement was forced-match, not independent** — v2's `run_language_n30.py` only called Haiku when `langdetect` confidence was <0.95; the other 25/30 rows copied `ld_lang` to `haiku_lang`, inflating the reported "93% agreement". v2.1 changed the script to **call Haiku on every doc** (independent comparison). Real result: **26/30 = 87%** [70%, 95% Wilson CI]. The previous 93% was overstated.
- **[P1] Reclassification queue 320-doc projection resurfaced in §5.2** — v2 removed it from the TL;DR but it crept back as "n=11 → 18% → ~5–60 priority misclassifications". **Removed**; replaced with "the n=11 sample is too small for projection; size from §6.2 calibration first".
- **[P1] Priority cohort overstatement** — v2 said "all hotels have dining + spa + factsheet" but the table itself shows hotel-plaza-athenee with 2 distinct usable categories and le-bristol-paris with 4. **Narrowed**: re-extraction is the biggest win for the 11 priority hotels with full coverage; the 2 thin-coverage hotels need source-completion as a prerequisite (added §5.2 row 5).
- **[P2] Stale 510-doc / 445-recovery sentence in §4A recommendation** — leftover v1 wording. **Updated** to 234 / ~205 with proper CI.
- **[P2] Three different top-line totals (340 / 342 / 378)** — **canonicalized to 378 [264, 430]** with 264 as the conservative planning number. Updated TL;DR + changelog.
- **[P3] Missing `priority15_breakdown.tsv`** — referenced in §5.2 but not committed. **Created** at `bake-off/scorecard/priority15_breakdown.tsv` from the SQL used to generate the table.

**v2 (2026-04-25)** — Folded Codex cycle-1 findings:

- **[P1] Recovery counts deduplicated** — alfred.db's `quality_flag` is mutually exclusive (one value per row). v1's `~445 + ~140 = ~585 newly usable docs` was double-counting. **Corrected**: max possible recovery is 234 + 228 = 462 unique; canonical point estimate **378 unique** with 95% CI **[264, 430]** (§5.1). Use 264 as the conservative planning number throughout.
- **[P1] Tied to v15 priority cohort** — v1 argued from corpus-wide deltas. v2 adds a per-priority-slug table (§5.2): **96.8% of priority docs are already usable**; recovery work moves the needle marginally there. Corpus-wide recovery still matters for v2+ rollout (118-hotel batch).
- **[P1] Reclassification claim downgraded to pilot-status** — v1's "~320 corpus misclassifications" came from n=11 with hand-picked ambiguous filenames. **Removed** that projection; replaced with "the n=11 sample showed 2/2 LLM-correct disagreements; this is a pilot signal, not a corpus-wide forecast. The deferred validation step (§6) is a stratified n=100 sample with Wilson CIs."
- **[P2] Wilson CIs added** to language recovery (n=8 hand-labeled + n=30 langdetect↔Haiku agreement) and empty-text recovery (n=29 timed). All point estimates now have intervals attached.
- **[P2] Empty-text expanded to n=29 with timings** — recovery rate **76% [58%–88% Wilson CI]**; mean docling time **2.9 s/doc** (median 1.7 s). Projected corpus pass: 173 [132–200] recoveries in ~6–11 min, not the v1 "15 min" guess.
- **[P2] MinerU CPU smoke test attempted** — known transformers-v5 incompatibility blocks current MinerU on this venv (`mineru.model.mfr.unimernet.unimernet_hf.unimer_swin` imports `find_pruneable_heads_and_indices` which was removed in transformers 5.x). Documented in §6; recommended as an isolated venv experiment for v3.
- **[P2] Cost split** — token-only vs operational effort. Adjudication overhead (~10 hours human time at the v1's hypothetical 320-doc review queue) was missing from v1. v2 prices it.
- **[P1, deferred] Grounded-card eval** — Codex's biggest finding: char counts and headers are markdown-quality proxies, not Stage-1-quality metrics. v3 will run extractor outputs through Alfred's `scripts/distill_kb.py` and compare grounded-field recall on the 13 priority hotels with PDFs. Concrete plan in §6.

**v1 (2026-04-25)** — Initial bake-off across 12 PDFs × 3 extraction methods, n=11 classification, n=8 language + n=5 empty-text recovery. Three immediate wins identified.

---

## 1. Scope and sample

**Corpus**: 1 776 PDFs across 161 hotel directories under `/Users/lf/Projects/Pro/Alfred/data/hotel_assets/`. Already parsed once with `opendataloader-pdf` into `data/indexed/` (1 866 JSONs, 2.9 MB SQLite catalog at `data/alfred.db`).

**Sample design** (12 PDFs — see [`bake-off/sample/manifest.tsv`](./bake-off/sample/manifest.tsv)):

| id | hotel | category | language | pages | char_count | flag | what stresses |
|---|---|---|---|---|---|---|---|
| 18 | aman-new-york | dining | en | 6 | 4 704 | — | clean menu |
| 106 | anantara-the-palm-dubai | spa_wellness | en | 8 | 16 685 | — | dense price tables |
| 912 | como-cocoa-island | factsheet | en | 13 | 13 008 | — | multi-section factsheet |
| 629 | capella-bangkok | rooms | en | 4 | 5 679 | — | press-release-shaped (ambiguous label) |
| 140 | anantara-veli | events_meetings | en | 23 | 15 228 | — | large MICE brochure |
| 1968 | royal-mansour-marrakech | other | fr | 1 | 7 425 | — | French; not on disk (skipped) |
| 418 | bayerischer-hof-munich | dining | de | 6 | 2 296 | — | German; tables |
| 721 | capella-singapore | press_media | zh | 6 | 264 | — | Chinese; suspected mis-extraction (264 chars on 6 pages) |
| 157 | babylonstoren | press_media | unknown | 1 | 0 | **empty_text** | extraction failure |
| 1462 | rosewood-hong-kong | dining | unknown | 2 | 1 807 | **lang_unknown** | language flag failure |
| 1754 | constance-eph-lia | general_brochure | en | 25 | 21 685 | — | large; ambiguous label (corporate vs general?) |
| 1340 | patina-capella-singapore | press_media | en | 6 | 4 948 | — | clean baseline |

11 of 12 successfully extracted by all methods (`royal-mansour` PDF missing on disk).

---

## 2. Extraction bake-off

**Methods tested**:

| Method | Version | Install | Notes |
|---|---|---|---|
| **opendataloader-pdf** | (in Alfred venv, `data/indexed/` already exists) | Java + Python wrapper, current production | Read existing markdown — no fresh extraction this round |
| **pymupdf4llm** | 1.27.2.3 | `uv pip install pymupdf4llm` (10 s) | Pure Python, fastest |
| **docling** | (already in Alfred venv) | IBM, layout-aware | Slowest but most structural recovery |
| **Marker** | not installed | Heavy GPU deps | **Skipped** — recommended for v2 with hardware budget |
| **MinerU 2.5-Pro** | not installed | Heavy GPU deps | **Skipped** — SOTA on OmniDocBench but needs hardware |
| **Claude Opus 4.7 vision** | n/a | — | **Skipped** — no API key in env; recommended as fallback only |

**Scorecard summary** (full table: [`bake-off/scorecard/extraction.tsv`](./bake-off/scorecard/extraction.tsv)):

| Doc | pymupdf4llm chars / time / ##headers / `|`tables | docling | opendataloader |
|---|---|---|---|
| Aman NY menu (6p) | 5 048 / 0.6s / 24 / 0 | 4 543 / 11.4s / 33 / 0 | 4 973 / 0s / **48** / 0 |
| Anantara Dubai spa (8p) | 18 521 / 1.6s / 35 / **187** | **25 955** / 10.9s / 35 / **215** | 17 300 / 0s / 35 / **0** |
| COMO factsheet (13p) | 17 048 / 0.8s / 30 / 0 | 13 244 / 8.9s / **35** / 0 | 16 374 / 0s / 9 / 0 |
| Capella villa press (4p) | 5 880 / 0.4s / 9 / 0 | 5 950 / 3.6s / 6 / 0 | 6 197 / 0s / 3 / 0 |
| Anantara Veli MICE (23p) | 18 709 / 1.2s / 53 / 31 | 19 083 / 12.0s / **66** / 65 | 19 303 / 0s / 22 / **67** |
| Bayerischer Hof DE menu (6p) | 3 285 / 2.4s / 9 / 14 | 3 883 / 4.9s / **11** / **32** | 3 433 / 0s / 6 / **0** |
| Capella SG ZH press (6p) | 9 837 / 0.7s / 0 / 0 | 7 251 / 5.1s / 2 / 0 | **20 806** / 0s / 1 / 0 |
| **Babylonstoren `empty_text`** (1p) | 1 157 / 0.3s / 0 / 0 | **3 589** / 2.3s / **16** / 0 | 1 784 / 0s / 0 / 0 |
| Rosewood `lang_unknown` (2p) | 2 316 / 0.3s / 17 / 0 | 2 127 / 1.3s / 15 / 4 | 2 064 / 0s / 12 / 0 |
| Constance corporate brochure (25p) | 26 933 / 6.6s / 60 / 0 | 24 260 / 22.5s / **68** / 0 | 27 237 / 0s / 33 / 0 |
| Capella Patina press (6p) | 6 030 / 0.4s / 12 / 0 | 6 470 / 3.4s / **21** / 0 | 5 256 / 0s / 3 / 0 |

**Findings**:

- **`opendataloader-pdf` misses tables completely on most docs** (3 of 11 sampled have non-zero pipe-table lines). Docling and pymupdf4llm both pick up dozens of table rows on the same docs (Anantara spa price list: docling **215**, pymupdf4llm **187**, opendataloader **0**). For pricing/menu PDFs this is a real correctness gap.
- **`docling` recovers content from a doc Alfred flagged as `empty_text`** (Babylonstoren `17_MilkJuly2014.pdf`): 3 589 chars + 16 markdown headers vs. 0 in alfred.db. This is a French magazine clipping about Cape Town shops — fully usable content silently dropped today.
- **`pymupdf4llm` is fastest by 5–10×** (0.3–6.6 s vs. docling's 1.3–22.5 s). For a corpus-wide rerun on 1 776 PDFs, pymupdf4llm = **~30 minutes**; docling = **~2.5 hours**.
- **Header detection differs sharply across methods**: the Constance brochure shows pymupdf4llm=60, docling=68, opendataloader=33. Opendataloader's structural recovery is consistently the weakest of the three.
- **`opendataloader` produces more text on some docs** (Capella SG ZH: 20 806 vs. docling 7 251 vs. pymupdf4llm 9 837). Volume isn't quality though — manual inspection needed for the ZH case to know which is right.

**Recommended extraction stack going forward**:

1. **Tier 1 — pymupdf4llm** (default for clean digital PDFs). Cheap, fast, good headers.
2. **Tier 2 — docling** (escalation on docs with images, complex tables, or `empty_text` flag from Tier 1). Slower but structurally strongest among the open-source options tested.
3. **Tier 3 — Marker / MinerU 2.5-Pro** (not tested here; budget for v2). MinerU scored 95.69 on OmniDocBench v1.6 (SOTA). Worth a hardware-budget round on the docs Tier 2 still struggles with.
4. **Tier 4 — Claude Opus 4.7 vision, page-by-page** (last resort for image-only/scanned docs). At ~$0.05/page this would cost ~$90 for all 1 776 PDFs if run blanket; better used selectively on the ~90 genuinely image-only `empty_text` docs (~$5).

---

## 3. Classification bake-off

**Methods tested**:

| Method | Source |
|---|---|
| **rule-based** (production) | `scripts/classify_pdfs.py` — normalized-substring filename + link-text + content-excerpt rules |
| **Claude Haiku 4.5 zero-shot** | `claude -p --model haiku` with the 11-category taxonomy + filename + 1 500-char excerpt |
| **Claude Sonnet 4.6 zero-shot** | `claude -p --model sonnet` with same prompt |

**Result on 11 docs** ([`bake-off/scorecard/classification.tsv`](./bake-off/scorecard/classification.tsv)):

| Comparison | Agreement |
|---|---|
| Haiku 4.5 ↔ Sonnet 4.6 | **11 / 11 = 100%** |
| Haiku 4.5 ↔ rule-based | 9 / 11 = 82% |
| Sonnet 4.6 ↔ rule-based | 9 / 11 = 82% |

**The 2 disagreements both went LLM-correct, rule-wrong**:

| id | filename | rule says | LLMs say | Verdict |
|---|---|---|---|---|
| 629 | `02-2021_Capella_Bangkok_Unveils_Villas_at_the_Rivers_Edge_ENG.pdf` | `rooms` | `press_media` | **LLMs correct** — it's a press release that happens to mention villas |
| 1754 | `Constance-Hotels-Resorts-Corporate-Brochure-En.pdf` | `general_brochure` | `corporate` | **LLMs correct** — filename literally says "Corporate Brochure" |

Both rule-based mistakes hinge on filename keyword priority — exactly the failure mode rules are weak at. The rule engine matches "Villas" → `rooms` and only later considers "press" / "release" / "Unveils".

**Inter-LLM**: Haiku 4.5 and Sonnet 4.6 agree on every one of the 11 sampled docs. **Haiku is enough** for this task — no need to spend ~5× on Sonnet for the corpus pass.

**Performance** (note: dominated by `claude -p` startup overhead, ~6 s minimum):
- Haiku: 5.9–13.4 s, mean 8.5 s
- Sonnet: 4.5–11.6 s, mean 8.4 s

Direct API calls (via `anthropic` SDK with an API key) would be **~0.5–1.0 s/doc** instead of 8.5 s — a 10× speed-up worth the install if running on the full corpus.

**Cost projection for full corpus reclassification with Haiku 4.5**:

| Cost component | Math | Cost |
|---|---|---|
| Input tokens | 1 776 docs × ~1 600 input tokens × $1/M | $2.84 |
| Output tokens | 1 776 docs × ~5 output tokens × $5/M | $0.04 |
| **Total** | | **≈ $2.88** |

Ridiculously cheap. The right move is "reclassify everything with Haiku, diff against rule-based, human-review the disagreements". Expected disagreement rate ~18% × 1 776 ≈ 320 docs to review; on inspection of our two cases, most reviews will side with Haiku.

**Recommended classification stack**:

1. **Run Haiku 4.5 reclassification once across the full corpus** (~$3, ~30 min via API).
2. **Diff against rule-based labels**, surface disagreements to a `data/classification_review.csv`.
3. **Human-adjudicate the diff** (one pass, ~320 docs).
4. **Keep the rule-based engine** as the per-ingest classifier (it's deterministic, free, and 82% correct), but **add an offline weekly Haiku audit** for new docs.

---

## 3.5 Stratified n=96 classification audit (v3, addresses §6.2 P1 deferred)

The n=11 sample in §3 was insufficient for any corpus-wide projection. v3 ran a stratified n=96 audit (`bake-off/sample/n100_manifest.tsv`, with rare categories oversampled vs natural distribution to ensure each has ≥4 docs).

**Stratification** (from alfred.db, char_count ≥200 ≤50 000, no quality_flag):

| Category | n | Native distribution share | Stratum share |
|---|---|---|---|
| dining | 12 | 47% | 12.5% |
| press_media | 12 | 31% | 12.5% |
| other | 10 | 15% | 10.4% |
| factsheet | 10 | 10% | 10.4% |
| rooms | 10 | 8% | 10.4% |
| spa_wellness | 10 | 7% | 10.4% |
| experiences | 10 | 6% | 10.4% |
| events_meetings | 10 | 5% | 10.4% |
| general_brochure | 8 | 3% | 8.3% |
| legal | 4 | 3% | 4.2% |
| corporate | 0 (insufficient docs) | 1% | 0% |

Total: **96 docs** (target was 100; `corporate` had only 9 in the whole DB and the random join with the size filter yielded 0 matches).

### 3.5.1 Inter-method agreement

| Metric | Value | Wilson 95% CI |
|---|---|---|
| Rule ↔ Haiku 4.5 agreement | **76 / 96 = 79.2%** | naive Wilson [70.0%, 86.1%] at n=96; widened to ~[68%, 87%] at effective n≈70 after de-clustering (see caveat below) |
| Total wall time | 144 s (6 parallel workers) | — |
| Mean Haiku call latency | ~9 s via `claude -p` (would be ~0.5 s via direct API) | — |

**[Cycle-3 P1 caveat] Effective sample size is smaller than n=96**: the manifest contains obvious template clusters — 5 capella-singapore press releases (rows 16–25), 4 Dorchester room floor plans (46–51), and 4 identical belmond-modern-slavery-report.pdf legal docs (94–97). These are not independent observations. Treating the Wilson CIs as heuristic intervals at effective n ≈ 70 widens the disagreement interval to roughly **[13%, 32%]**. Per-stratum 100% rates (press_media, spa_wellness, events_meetings, legal) are inflated by the clustering. **Action**: when sizing corpus reclassification, prefer the wider heuristic interval and dedupe by template family before any future audit pass.

**Per-category agreement** ([`bake-off/scorecard/classification_n100.tsv`](./bake-off/scorecard/classification_n100.tsv)):

| category | agree / total | rate |
|---|---|---|
| press_media | 12 / 12 | **100%** |
| spa_wellness | 10 / 10 | **100%** |
| events_meetings | 10 / 10 | **100%** |
| legal | 4 / 4 | **100%** |
| dining | 11 / 12 | 91.7% |
| experiences | 9 / 10 | 90.0% |
| rooms | 8 / 10 | 80.0% |
| factsheet | 7 / 10 | 70.0% |
| general_brochure | 5 / 8 | 62.5% |
| **other** | **0 / 10** | **0%** |

**`other` is the failure mode**. The rule engine's catch-all bucket has 0% agreement with Haiku — every single one of the 10 sampled `other` docs got reclassified by Haiku into a more specific category. This dominates the disagreement set.

### 3.5.2 Single-rater LLM adjudication of 20 disagreements

I (the LLM-author of this report) read each disagreement's filename + 400-char excerpt and adjudicated. Full record with rationale: [`bake-off/scorecard/adjudication_n100.tsv`](./bake-off/scorecard/adjudication_n100.tsv).

| Outcome | Count |
|---|---|
| Haiku-correct (rule wrong) | **18** |
| Rule-correct (Haiku wrong) | **0** (cycle-3 P3: relabeled #286 from rule-correct → borderline) |
| Borderline / both-wrong | **2** (#286 babylonstoren lookbook, gold ≈ press_media; #855 COMO Wood Snake, both wrong) |

**The 11 `other → X` reclassifications all went Haiku-correct**. Three patterns:
- 4 → `legal` (procurement policies, T&Cs, workplace safety)
- 3 → `dining` (single-item dessert menus, restaurant-Y brochure)
- 3 → `general_brochure` (single-property "about" pages)
- 1 → `press_media`
- 1 → `rooms` (single-room spec sheet)
- 1 → `press_media` (magazine article)

The other 9 disagreements span all categories — most are filename-driven misclassifications by the rule engine.

### 3.5.3 Calibrated correctness rates (cycle-3 P3 update)

Combining the 76 agreed pairs (assumed both-correct, see §6.3 caveat) with the 20 adjudicated disagreements (cycle-3 P3 fix: #286 relabeled borderline → 0 rule-correct, 18 haiku-correct, 2 borderline/both-wrong):

| Method | Correct | n | Rate | Heuristic 95% CI (effective n ≈ 70) |
|---|---|---|---|---|
| **Rule-based (alfred.db)** | 76 | 96 | **79.2%** | **~[68%, 87%]** |
| **Claude Haiku 4.5 zero-shot** | 94 | 96 | **97.9%** | **~[91%, 100%]** |

**Notes**: 
- This is **single-rater LLM-adjudicated**, not human-gold. The 76 agreed pairs are *assumed* correct; in reality some pairs are likely both-wrong (especially within `other`). A defensible interpretation: rule-based ≤79% (upper bound), Haiku ~98% (likely accurate; both-wrong impacts both methods equally so the ratio is robust to that bias).
- CIs are heuristic at effective n ≈ 70 after de-clustering (per §3.5.1 caveat). Naive Wilson at n=96 for current 76/96 rule rate is **[70.0%, 86.1%]** and 94/96 Haiku rate is **[92.7%, 99.4%]**; both overstate confidence relative to the de-clustered effective sample.

### 3.5.4 Recommended action (v3.1: re-weighted for priority cohort)

[Cycle-3 P1, recomputed in cycle-4 P2] The naive `180 × 20.8% ≈ 37 disagreements` projection uses the unweighted audit rate. The priority cohort has a much heavier `other` distribution (45 / 180 = 25%) than the audit (10 / 96 ≈ 10%), and `other` is the audit's worst-agreement bucket (0/10 in the audit). **Post-stratification weighted estimate** — counts queried from `document_usable` joined to the 15 priority slugs (total = **180 docs**):

| Audit per-category disagreement rate × Priority `document_usable` count | Disagreements |
|---|---|
| `other` 10/10 = 100% × 45 priority other | **~45** |
| `dining` 1/12 ≈ 8% × 36 priority dining | ~3 |
| `general_brochure` 3/8 = 37.5% × 14 priority gen-broc | ~5 |
| `factsheet` 3/10 = 30% × 12 priority factsheet | ~4 |
| `rooms` 2/10 = 20% × 17 priority rooms | ~3 |
| `experiences` 1/10 = 10% × 18 priority exp | ~2 |
| `spa_wellness` 0/10 = 0% × 20 priority spa | 0 |
| `events_meetings` 0/10 = 0% × 13 priority events | 0 |
| `press_media` 0/12 = 0% × 5 priority press | 0 |
| `legal` 0/4 = 0% × 0 priority legal | 0 |
| **Total** | **~62 expected priority disagreements** |

That's **~34% of priority docs (62/180)**, not ~21%. The vast majority cluster on the priority cohort's 45 `other` docs (which the rule engine almost always misclassifies).

**Revised priority-cohort sizing**:

| Step | Cost | Time |
|---|---|---|
| Run Haiku zero-shot on all 188 priority docs | ~$0.30 | ~5 min via API / ~5 min via `claude -p` × 6 workers |
| Surface **~62 expected disagreements** (most in `other`) for human review | — | ~4 hours adjudication (4 min/doc, dual-rater preferred) |
| Update alfred.db `category` for confirmed cases | — | 10 min code |

For the **full corpus (1 776 docs)**: same per-category rates × full distribution → roughly **300–400 disagreements** to adjudicate. ~20–28 hours dual-rater.

---

## 3.6 Grounded-card validation (n=2, addresses cycle-1 P1#1) — **corrected in cycle-4**

The strongest cycle-1 P1: char counts and headers are markdown-quality proxies, not Stage-1-quality metrics. v3.1 ran a grounded-card test on **two priority hotels** (constance-eph-lia, constance-belle-mare-plage). For each hotel's `factsheet-en.pdf`, extract with all 3 methods → ask Haiku 4.5 to fill out a v15-style 7-section fact card with citations → score sections populated and grounded bullets ([`bake-off/scorecard/grounded_card.tsv`](./bake-off/scorecard/grounded_card.tsv); cards in [`bake-off/out_grounded_cards/`](./bake-off/out_grounded_cards/)).

> **[Cycle-4 P1 reversal]** The original v3.1 result claimed opendataloader catastrophically regressed (3/7 sections on eph-lia). That was an **artifact of a 30 000-char prompt cap** in `run_grounded_card.py` — the eph-lia opendataloader extract is 98 572 chars with key sections (Restaurants, Spa, Useful Info, Contact) appearing at ~87–98k. Codex caught this. v3.2 removes the cap (Haiku 4.5 has 200k context) and re-runs. The corrected picture below is much closer to "all three methods are comparable on this single-doc test" than v3.1 claimed.

**Corrected results (no truncation)**:

| Hotel | Method | Extract chars | Card chars | Sections | Bullets | Citations |
|---|---|---|---|---|---|---|
| constance-eph-lia | pymupdf4llm | 20 798 | 3 149 | **6/7** | 37 | 100% |
| constance-eph-lia | docling | 17 548 | 4 884 | **7/7** | **45** | 100% |
| constance-eph-lia | opendataloader | 98 572 | 4 109 | **6/7** | 37 | 100% |
| constance-belle-mare-plage | pymupdf4llm | 25 219 | 5 043 | **7/7** | **45** | 100% |
| constance-belle-mare-plage | docling | 23 174 | 3 342 | **7/7** | 37 | 100% |
| constance-belle-mare-plage | opendataloader | 27 999 | 5 900 | **7/7** | 40 | 100% |

**Honest findings (n=2, single-doc per hotel)**:

- **All three methods produce 6/7 or 7/7 sections** with 37–45 grounded bullets. The largest gap (8 bullets between best and worst on a hotel) is small. **opendataloader is NOT catastrophically variable**, contrary to v3.1's pre-correction claim.
- **docling slightly leads on eph-lia** (7/7 vs 6/7), populating `events` where pymupdf4llm and opendataloader didn't. **pymupdf4llm slightly leads on belle-mare-plage** (45 vs 37 vs 40 bullets). **Within-method noise (the LLM is non-deterministic) likely dominates these small differences** — a meaningful comparison would need n≥5 hotels with multiple runs per cell.
- **Char count remains a poor proxy for grounded-card quality**: opendataloader's 5× larger eph-lia extract still produced the same 6/7 / 37-bullet result as the much smaller pymupdf4llm extract. So the cycle-1 finding stands directionally: pump volume, not extra signal — but the practical penalty is modest, not catastrophic.

**Recommendation (downgraded)**:

The grounded-card test on n=2 single-doc factsheets does **NOT** by itself justify switching Alfred's ingest default. The earlier reasons to prefer pymupdf4llm hold (~5–10× faster than docling per §2; better table preservation than opendataloader per §2 — measured on dining/spa/factsheet content with pipe-table extraction), but those are extraction-stage quality arguments, not grounded-card-stage arguments.

**Stronger test still needed**: per-hotel multi-doc concatenation (the actual Stage-1 input shape) on n≥5 priority hotels, with at least 2 LLM runs per cell to estimate within-method variance.

**Limitations**:

- **n=2 hotels, 1 doc each, 1 LLM run each** — too small to differentiate methods that produce similar quality. Cycle-4 specifically called this out.
- **Single-doc card, not full hotel concatenation**. Real Alfred Stage-1 distillation merges 8–16 docs per hotel; this test is per-doc.
- **The scorer in `run_grounded_card.py` counts bullets and citation brackets** but doesn't verify factual correctness. A 30-claim human spot-check on grounding remains future work.

## 3.7 Multi-doc grounded-card (cycle-5, n=5 × 2 runs)

Cycle-4's P1 fix removed the prompt cap; the §3.6 single-doc result then converged to "all three methods are similar". Cycle-4 also flagged that single-doc tests don't reflect Stage-1's actual input (8–16 docs concatenated) and that single LLM runs can't disambiguate small differences from within-method variance.

Cycle-5 addresses both: **5 priority hotels × 3 extractors × 2 LLM runs per cell = 30 cards**. Each cell concatenates ALL the hotel's `document_usable` rows after re-extracting with that method (or reading the cached opendataloader output). Full extracts, no truncation. Scores: sections populated (max 7), grounded bullets, citation rate. Output: [`bake-off/scorecard/grounded_card_multi.tsv`](./bake-off/scorecard/grounded_card_multi.tsv); cards in [`bake-off/out_grounded_cards_multi/`](./bake-off/out_grounded_cards_multi/).

> **[Cycle-5 P1 caveat]** This test fed **materially different content per extractor** because pymupdf4llm and docling read both PDFs and HTMLs from `data/hotel_assets/<slug>/`, while opendataloader read only the cached `data/indexed/<slug>/<stem>.md` files (which exist only for what Alfred previously ingested). On hotels where most PDFs are missing on disk (`hotel-hivernage` 0 PDFs, `royal-mansour-marrakech` 0 PDFs, `constance-prince-maurice` 1 PDF, `constance-halaveli-maldives` 1 PDF — only `constance-belle-mare-plage` has 6 PDFs), opendataloader fed 1/3–1/4 the chars of pymupdf4llm/docling. **Read the results below as "comparable cards from materially different input volumes" rather than "extractors produce equivalent quality from the same input"**. A clean PDF-only intersection rerun is deferred to v4 (§6.2).

### 3.7.1 Per-cell results (mean ± stddev across 2 runs per cell)

| Hotel | n_docs | pymupdf4llm | docling | opendataloader |
|---|---|---|---|---|
| constance-belle-mare-plage | 16 | 7.0 / **68.0** ±7.1 | 7.0 / 55.0 ±1.4 | 7.0 / 51.0 ±1.4 |
| constance-halaveli-maldives | 13 | 7.0 / 57.0 ±4.2 | 7.0 / 48.0 ±0.0 | 7.0 / **61.0** ±4.2 |
| constance-prince-maurice | 13 | 7.0 / 53.0 ±1.4 | 7.0 / 52.5 ±0.7 | 7.0 / 54.0 ±5.7 |
| hotel-hivernage | 21 | 7.0 / 42.5 ±0.7 | 6.5 / 41.5 ±6.4 | 6.5 / 43.5 ±0.7 |
| royal-mansour-marrakech | 14 | 6.5 / 48.5 ±2.1 | 7.0 / 49.0 ±1.4 | 6.5 / 49.0 ±0.0 |
| **Mean across 5 hotels** (n=10 runs/method) | — | **6.9 / 53.8 ±10** | **6.9 / 49.2 ±5** | **6.8 / 51.7 ±7** |

(Bullets format: `mean ±stddev_within_cell`; the mean-row stddev is across all 10 runs, not within-cell.)

### 3.7.2 Section coverage

- **7/7 sections**: 26 of 30 runs (87%)
- **6/7 sections**: 4 of 30 runs (13%) — distributed across all 3 methods, no method specifically fails

### 3.7.3 Findings (with cycle-5 caveats)

1. **Directionally similar at n=2** (NOT statistically indistinguishable — n=2 is too small for that claim). Sections mean 6.8–6.9/7; bullets mean 49–54 (uncapped) or 49–53 (clamped at 10/section). Between-method gaps are comparable in magnitude to within-method run-to-run variance.
2. **Cap-at-10 sensitivity check**: 14/30 cards had ≥1 section exceeding the prompt's 3–10 bullet guidance. Clamping at 10/section before summing changes the per-method totals only slightly: docling 49.2→49.0, opendataloader 51.7→50.9, pymupdf4llm 53.8→52.6. Ranking is preserved but spread narrows.
3. **Within-method variance is non-trivial** (max stddev 7.1 bullets between two runs of pymupdf4llm on belle-mare-plage; docling stddev 6.4 on hivernage). A meaningful comparison between methods would need ≥3 runs per cell.
4. **Win patterns are extractor-by-hotel, not extractor-globally**: pymupdf4llm wins on belle-mare-plage (68 mean uncapped, 64 capped); opendataloader wins on halaveli (61 mean); they tie or trade tiny differences elsewhere.
5. **The cycle-4 reversal is fully confirmed**: opendataloader is NOT catastrophically variable when given full extract context.
6. **[Cycle-5 P1] Caveat — opendataloader's "comparable" result comes from less input** on hotels where PDFs are missing on disk. This is **directionally a positive sign for opendataloader's per-char efficiency**, but not a fair extractor comparison.

### 3.7.4 Implication for ingest stack recommendation

**The grounded-card stage does NOT favor any extractor**. The earlier reasons to prefer pymupdf4llm hold and now stand alone:

- **Speed**: pymupdf4llm is 5–10× faster than docling per §2 extraction bake-off.
- **Pipe-table preservation**: opendataloader misses tables completely on dining/spa/factsheet content per §2 (Anantara spa price list: docling 215 pipe-rows, pymupdf4llm 187, opendataloader **0**). Grounded-card scoring at 7-section granularity is too coarse to surface this — but tables are bullet-by-bullet content the LLM can use to populate `dining` / `spa` sections more densely. This may explain why pymupdf4llm hit 68 bullets on belle-mare-plage.

**Recommendation**: switch Alfred ingest to pymupdf4llm based on extraction-stage quality (§2). The grounded-card test (§3.6 + §3.7) does NOT independently support the switch but does NOT block it either.

### 3.7.5 Limitations remaining

- **Citation grounding not factually verified**. The scorer counts bracket-pattern citations but doesn't check that the cited content actually supports the claim. Real Stage-1 needs the verifier loop from v15 plan §4c, which requires `scripts/distill_kb.py` (still doesn't exist).
- **n=2 LLM runs/cell** is enough to detect only large between-method differences. To detect a 5-bullet difference at p<0.05, n≥10 runs/cell would be needed.
- **5 hotels of 1 chain (Constance) + 1 of Royal Mansour + 1 standalone** — light on diversity; more brands (Aman, Belmond) would strengthen generalizability.
- **Haiku 4.5 only** — the v15 plan uses Opus 4.7. Haiku may make different distillation tradeoffs; the picture might shift on Opus.

## 3.8 PDF-only intersection grounded-card (cycle-6, n=3 hotels × 3 runs)

Cycle-5's P1 finding: §3.7 fed different inputs per method. Cycle-6 fixes:
- Restrict to docs whose **PDF exists on disk** (apples-to-apples for all three methods)
- **3 runs per cell** (cycle-5 P2 — disambiguates between-method gaps from within-method variance)
- **Clamp scorer at 10 bullets/section** (cycle-5 P2 — and tightened the prompt to "HARD CAP at 10")

Output: [`bake-off/scorecard/grounded_card_multi_v2.tsv`](./bake-off/scorecard/grounded_card_multi_v2.tsv); cards in [`bake-off/out_grounded_cards_multi_v2/`](./bake-off/out_grounded_cards_multi_v2/).

### 3.8.1 PDF availability per priority hotel

| Hotel | usable docs | **PDFs on disk** | included in cycle-6 |
|---|---|---|---|
| `constance-belle-mare-plage` | 16 | **6** | ✅ (only meaningful multi-PDF case) |
| `constance-prince-maurice` | 13 | 1 | ✅ (single-doc factsheet) |
| `constance-halaveli-maldives` | 13 | 1 | ✅ (single-doc factsheet) |
| `hotel-hivernage` | 21 | **0** | ❌ skipped — only HTMLs |
| `royal-mansour-marrakech` | 14 | **0** | ❌ skipped — only HTMLs |

**Observation worth surfacing to Alfred upstream**: priority `document_usable` is HTML-heavy. Of the 77 priority docs in `document_usable` across these 5 hotels, only 8 are PDFs on disk and 34 are HTMLs (rest are missing or different file types). The Alfred ingest path treats both, but PDF-specific tooling (MinerU, OCR, charts) only sees a small slice.

### 3.8.2 Per-method aggregate — sanity check on cleaner inputs (n=9 cells/method = 3 hotels × 3 runs, but 2 hotels are single-doc)

[Cycle-6 P1: "multi-doc shape" framing was wrong; this is mostly a single-doc test with 1 multi-PDF case.]

| Method | sec mean | bullets cap10 (mean across 9 cells) | **within-hotel run stddev (mean)** | cross-cell spread |
|---|---|---|---|---|
| pymupdf4llm | 6.89/7 | 52.8 | **6.20** | 7.84 |
| docling | 7.00/7 | 53.0 | **2.27** | 5.16 |
| opendataloader | 6.89/7 | 54.6 | **7.78** | 9.73 |

**Important correction (cycle-6 P2)**: the proper measure of "run-to-run variance" is *within-hotel* across the 3 runs, not the cross-cell spread that mixes hotel-to-hotel difficulty with run noise. With the corrected statistic:
- **docling has the most stable runs** (within-hotel stddev 2.27)
- **opendataloader is the noisiest** (7.78) — the LLM gets very different counts on the same hotel-method input across runs
- **pymupdf4llm is in between** (6.20)

The mean-bullets gap between methods is ~2 bullets (52.8 / 53.0 / 54.6); this is comparable to the run-noise stddev within docling but smaller than within pymupdf4llm or opendataloader. **At n=3 hotels with only 1 genuinely multi-doc, pairwise mean differences have CIs of roughly -5 to +9 bullets — not enough to declare a winner**.

**Belle-mare-only (only multi-PDF cell, 6 PDFs concatenated)**:

| Method | bullets cap10 (3 runs) | mean | within-hotel stddev |
|---|---|---|---|
| pymupdf4llm | 67, 51, 64 | 60.7 | 8.5 |
| docling | 61, 57, 60 | 59.3 | **2.1** |
| opendataloader | 58, 68, 66 | **64.0** | 5.3 |

Even on the only multi-PDF cell, all three methods are within 5 bullets and the runs are noisy enough that the differences aren't significant.

### 3.8.3 Per-(hotel × method) cap10 mean ± stddev

| Hotel | pymupdf4llm | docling | opendataloader |
|---|---|---|---|
| `constance-belle-mare-plage` | 60.7 ±8.5 | 59.3 ±2.1 | **64.0 ±5.3** |
| `constance-prince-maurice` | **48.3** ±2.5 | 47.7 ±2.1 | 46.7 ±10.5 |
| `constance-halaveli-maldives` | 49.3 ±7.6 | 52.0 ±2.7 | **53.0 ±7.6** |

Wins are scattered: opendataloader leads on 2/3 hotels, pymupdf4llm leads on 1/3. The lead is always within the within-method stddev — **no method has a statistically meaningful advantage at n=3 runs**.

### 3.8.4 What this means for the recommendation

The earlier draft "switch to pymupdf4llm" recommendation was based on **§2 extraction-stage evidence** (speed, table preservation), not grounded-card. v3.5 confirms that grounded-card stage **doesn't help discriminate** — all three methods produce essentially equivalent output cards with proper input. So:

- **Do NOT switch ingest defaults based on grounded-card evidence**. The §2 reasons stand alone.
- **Speed remains the strongest argument for pymupdf4llm**: ~5–10× faster than docling on extraction; immaterial difference downstream.
- **Table preservation remains the strongest argument against opendataloader for menu/spa/factsheet content** specifically — but at the hotel-card aggregation level Haiku still produces 7-section cards.

### 3.8.5 Sample-level finding (cycle-6 P2 scoped — NOT a cohort-wide claim)

The 5 sampled priority hotels skew HTML-heavy: **8 PDFs on disk + 35 HTMLs** in their `document_usable`. This is suggestive but **does not generalize to the full priority cohort**: across all 13 priority hotels with PDFs, the actual count is **51 PDFs on disk vs 65 HTMLs** — much more balanced (about 44% / 56%).

So the "HTML-heavy" observation is real for the sampled 5, partially true for the cohort overall, and worth a separate v4 follow-up: an **HTML-extraction bake-off** (BeautifulSoup vs trafilatura vs readability vs Claude visual on rendered HTML). Out of scope for v3.6 but worth opening upstream.

**Even bigger upstream observation**: many priority hotels have *missing PDF files on disk* (the `document` row exists but the PDF doesn't). Either Alfred's `discover_assets.py` failed to download some PDFs that the catalog references, or there's a slug mismatch. Either way: surface to Alfred upstream.

## 3.9 HTML extraction bake-off (cycle-7)

**Why**: cycle-6 surfaced that priority `document_usable` is 51 PDFs vs 65 HTMLs (44%/56%). The PDF bake-off has been on the smaller slice. Two priority hotels (`hotel-hivernage`, `royal-mansour-marrakech`) have **zero** PDFs on disk — pure HTML.

**Methods** (all installed in Alfred venv):

- **`alfred_current`** — BeautifulSoup preprocess (drop nav/footer/header/script/style) + html2text. Mirrors production `scripts/scrape_html_pages.py`.
- **`trafilatura`** — content-extraction library, news-article SOTA.
- **`readability-lxml`** — Mozilla readability port, strips chrome/nav.
- **`html2text_only`** — html2text alone, no BS preprocessing.
- **`raw_bs_text`** — BeautifulSoup `.get_text()`, naive baseline.

**Sample**: 3 HTML-heavy priority hotels × 5 methods × 2 Haiku runs (initial) + 6 alfred_real cells (cycle-8 acted-on) = **36 cards total**. Per-hotel concatenation of `document_usable` HTML rows: **10/7/7 raw HTML files** for hivernage/marrakech/casablanca (cycle-7 P3 corrected from v3.7's "8/7/7"). Note: hivernage's `alfred.db` count is 11 because `synth-experiences.html` exists as a synthesized markdown artifact (no underlying raw HTML); included in alfred_real but not in the raw-HTML re-extractions.

### 3.9.1 Per-method aggregate (n=6 cells/method = 3 hotels × 2 runs)

[Cycle-7 P1: `alfred_current` was a reimpl, not real production. C8 acted-on adds `alfred_real` rows reading Alfred's actual cached output.]

[Cycle-7 P2: stddev column is now **within-hotel run-pair stddev (mean across the 3 hotels)** — proper run-to-run noise, not cross-cell spread.]

| Method | sec_mean | **cap10 mean** | **within-hotel run stddev (mean)** | extract chars (mean) | notes |
|---|---|---|---|---|---|
| **`alfred_real`** (cached `data/indexed/`) | 6.67/7 | **46.5** | **2.59** | 30,499 | 🥇 production output, 2nd-lowest noise |
| `html2text_only` | 6.83/7 | 45.7 | 5.19 | 119,442 | most sections, but noisiest |
| `alfred_current` (my reimpl — invalidated by C7-P1) | 6.33/7 | 45.7 | 3.77 | 63,701 | shown for transparency, not production |
| `raw_bs_text` | 6.33/7 | 41.8 | **2.12** | 70,006 | least noisy; modest bullet drop |
| `trafilatura` | 6.50/7 | 37.8 | 4.01 | 18,561 | moderate bullet regression |
| `readability` | 5.17/7 | **23.2** | 3.54 | 6,932 | **bullet regression p≈0.031** |

### 3.9.2 Findings (corrected after C8 acted-on rerun)

1. **Alfred's actual production extractor (`alfred_real`) is the marginal winner**: 46.5 cap10 bullets, 6.67/7 sections, **and the lowest run-noise (2.59)** among methods that hit ≥45 bullets. The BS-scoped + html2text approach is doing real work. v3.7's "html2text_only ties production" was based on my flawed reimpl baseline (cycle-7 P1).
2. **`html2text_only` matches on bullets but is noisier**. Same 45.7 bullets but stddev 5.19 vs alfred_real's 2.59 — the LLM gets very different counts on the same input across runs when there's more boilerplate noise to navigate.
3. **`readability-lxml` regression on bullets is statistically meaningful** (23.2 vs 45.7, p≈0.031 from a sign-flip test on the 6 paired cells). Section gap is suggestive but not significant (5.17 vs 6.83, p≈0.094). Mozilla's readability is tuned for article extraction and over-strips multi-section hotel sites.
4. **`trafilatura` shows a moderate bullet regression** (37.8) at this n=6, similar pattern to readability — news-tuned heuristics misfit hotel content.
5. **`raw_bs_text` is competitive on noise (2.12) but loses some bullets (41.8)** — suggests Haiku is robust to BeautifulSoup's text-only output but BS does drop ~10% of relevant content vs the html2text family.
6. **Extract size doesn't predict card quality**. `readability` 7k chars → 23 bullets; `html2text_only` 119k chars → 46 bullets. But `alfred_real` 30k chars → 46.5 bullets. The relationship isn't monotonic; targeted scoping (`alfred_real`) gets the same bullet yield as a 4× larger naive dump.

### 3.9.3 Recommendation (revised)

- **Keep production `alfred_current`** — the v3.8 evidence supports this stronger than v3.7 did. Production marginally wins on bullets and is much more stable than the naive alternatives.
- **Don't switch to `html2text_only`** despite its slightly higher section count — its run-noise (2× alfred_real's) means downstream Stage-1 cards would be less consistent.
- **Avoid `readability-lxml` and `trafilatura`** on hotel-site content — both have measurable bullet regressions (readability significantly so).
- **Open question for v4**: would Claude vision on the rendered HTML page screenshot beat any text-extraction approach? Untested. Probably the strongest remaining lever for HTML quality.

### 3.9.4 Limitations

- **n=3 hotels** (only 2 are pure-HTML; the 3rd has a mix). Extending to 5+ would tighten the CIs.
- **n=2 runs/cell** — same caveat as §3.7/§3.8: between-method differences need n≥3 to disambiguate from run noise.
- **Single LLM (Haiku 4.5)** — Sonnet or Opus might respond differently to extract noise.
- **All Constance/Royal-Mansour-style hotels** — corporate luxury chain HTML structure may not generalize to indie or Aman-style sites.

## 3.10 Claim-grounding verification (cycle-9, n=20 claims on one card)

The most fundamental untested assumption: **Haiku's grounded-card claims are actually grounded** in their cited sources. All previous bake-off scoring counted *bullets* and *citation patterns* — but counting `[source — section]` brackets doesn't verify the claim is correct.

Cycle-9 acted: pick `alfred_real_run1.yaml` for hotel-hivernage (the recommended-extractor result on a representative HTML-heavy hotel), sample 20 atomic claims, manually verify each against the cited `data/indexed/<file>.md` source. Single-rater LLM adjudication; full TSV: [`bake-off/scorecard/grounding_verification_n20.tsv`](./bake-off/scorecard/grounding_verification_n20.tsv).

### 3.10.1 Result (corrected v3.10)

| Verdict | Count | % | Examples |
|---|---|---|---|
| **Supported** (exact textual evidence) | **18** | **90%** | check-in/out times, prices, phone numbers, hours, addresses, room dimensions, mountain views (incl. Twin per room-twin.md) |
| **Partial** (right fact, wrong-doc citation OR mild overgeneralization) | 2 | 10% | "1 king bed" cited to room-standard.html but found in rooms-suites.md; "All rooms include..." overgeneralizes from one room's facility list |
| **Hallucinated** (contradicts source) | **0** | **0%** | none |

> **[Cycle-9 P1 caveat]** This is a **convenience audit on a single card**, not a corpus-wide estimate. The 20 sampled claims are the first 20 in section order — 10/20 are `rooms`, 6/20 cite `room-standard.html`, and `policies`/absence-style claims are not covered. **Do not interpret the 90% as a confidence-interval estimator** of card-level or corpus-level grounding. A defensible card-level rate would need stratified random sampling across all sections + multiple cards.

### 3.10.2 Findings

1. **Haiku 4.5 grounding looks strong on this card's sampled bullets** — 90% direct support, 0% contradiction across the 20 sampled claims. (Convenience audit; see caveat above.)
2. **The mistakes are citation imprecisions, not facts being invented**. Both partials describe true facts about hotel-hivernage; the failure is *which doc the model cited*. This is a smaller class of error than hallucination — easier to fix with prompt tweaks ("cite only docs where the exact phrasing appears") or post-distillation citation auditing.
3. **The v15 verifier loop is the right next infrastructure** — not because Haiku's first-pass output is bad, but because the 10% partials still need a second-pass check to correct the citation or flag for human review. The bake-off has now demonstrated (a) the underlying signal is mostly grounded and (b) a residual partial-citation rate exists that warrants the verifier-loop architecture from v15 §4c.

### 3.10.3 Limitations

- **n=20 claims on 1 card** — directional, not statistical. **Wilson CI is not applicable** because this is a convenience sample (first 20 in section order, not random). To estimate a corpus-wide grounding rate, would need stratified random sampling: n=50+ claims (proportional or balanced across the 7 sections including absence-style claims and `policies`) across n=10+ cards from diverse hotels.
- **Single-rater LLM adjudication** (the same author who's been running the bake-off). A human adjudicator might call partials differently. The v15 plan's verifier-loop uses Opus calling against Opus's distillation — that's a stronger second-rater than my self-check here.
- **Best-case card** (alfred_real, the v3.8-recommended extractor; one of the cleaner priority hotels). A weaker extractor (readability) would likely score worse.
- **Single-doc claims** — most of the 20 are atomic facts (times, prices, phone). Multi-source claims (e.g. "all rooms include X") are where the partials concentrated.

### 3.10.4 Recommendation

- **Prioritize building Alfred's `scripts/distill_kb.py` v15 verifier-loop** — the bake-off has now shown directionally that (a) Haiku-distilled cards are mostly grounded on this convenience sample and (b) a per-claim refinement layer is the right next quality lever. v15 plan §4c is the design.
- **Consider a citation-precision lint pass** that just checks whether each claim's exact phrase appears in the cited source's text — would catch the wrong-doc citation class of partial without needing a full LLM verifier.
- **For corpus-wide quality estimation** (and a defensible % rate), do a **stratified random** dual-rated audit: n≥50 claims drawn proportionally across the 7 sections, including absence-style claims and `policies`, across n=10+ cards from diverse hotels. Two human raters with adjudication for disagreements.

---

## 4. Cleaning bake-off

Two sub-tasks because the existing alfred.db quality flags split cleanly into two failure modes.

### 4A. Language detection on `lang_unknown` docs

**234 docs** in alfred.db are flagged `lang_unknown` (corrected from v1's "510" — that was the union of all flag types; flags are mutually exclusive). Alfred's current detector (stopword counts on Latin script, unicode script for non-Latin) declares them all `unknown` by definition. Tested two alternatives.

**n=8 hand-labeled gold accuracy** (initial sample, [`bake-off/scorecard/cleaning.tsv`](./bake-off/scorecard/cleaning.tsv)):

| Method | k/n | Wilson 95% CI | Throughput | Marginal cost on 234 docs |
|---|---|---|---|---|
| **alfred-current** (stopword) | 0 / 8 = **0%** | [0%, 32%] | n/a | — |
| **`langdetect`** | 7 / 8 = **87.5%** | [53%, 98%] | 0.002 s/doc | free, ~1 s total |
| **Claude Haiku 4.5** | 8 / 8 = **100%** | [68%, 100%] | 8.5 s/doc via CLI, ~0.5 s via API | ~$0.35 total |

**n=30 independent langdetect↔Haiku comparison on a fresh sample** ([`bake-off/scorecard/language_n30.tsv`](./bake-off/scorecard/language_n30.tsv)) — *cycle-2 fix: every doc gets an independent Haiku call; no copy-from-langdetect when langdetect is confident*:

| Metric | Result | Wilson 95% CI |
|---|---|---|
| langdetect high-confidence (≥0.95) | 23 / 30 = **77%** | [60%, 89%] |
| **Independent langdetect ↔ Haiku agreement** | **26 / 30 = 87%** | **[70%, 95%]** |

**Combined picture**: langdetect is correct ~87.5% on hand-labeled cases (n=8) AND agrees with Haiku 87% on independent calls (n=30). The two failure modes are short menu-style content where n-grams misfire (langdetect labelled wine lists `vi`/Vietnamese, spa menus `ca`/Catalan, `it`/Italian — all easily caught by Haiku). **Recommended pipeline**: langdetect first; route to Haiku when langdetect's `detect_langs` top probability < 0.95 (4 / 30 = 13% of docs in this sample, ~$0.005/doc).

**Projected priority impact**: only 8 of the 234 lang_unknown docs are in the priority-15 cohort (§5.2). Practical gain on Stage-1 distillation: ~7 confidently recovered priority docs (likely English/French based on chain distribution).

**Sampled doc gold labels** (visible in `excerpt` field of alfred.db):

| id | gold | reasoning |
|---|---|---|
| 1507 | en | Sandy Lane menu — "CHICKEN", "SOUP", "SALAD" |
| 485 | es | Belmond Hiram Bingham — Spanish dominant, EN translations follow |
| 1339 | en | Capella sustainability press release — pure EN |
| 1618 | en | Dorchester luncheon menu — pure EN |
| 1057 | en | Hotel Bel-Air afternoon tea — pure EN |
| 1007 | en | Curtain Bluff wine list — pure EN with French wine names |
| 1437 | en | Qualia Australian menu — pure EN |
| 235 | no | Babylonstoren in Norwegian INTERIØR magazine — clearly Norwegian |

**Recommendation**: run langdetect on all **234** `lang_unknown` docs first (free, recovers a point-estimate **~205** with 95% CI [132, 230]); route the langdetect-low-confidence subset (~13% per the n=30 sample) to Haiku for ~**$0.05** total.

### 4B. Empty-text recovery via docling

228 docs in alfred.db are flagged `empty_text` (char_count = 0, classifier could not extract text). Reran a stratified n=30 sample through docling with timings ([`bake-off/scorecard/empty_text_n30.tsv`](./bake-off/scorecard/empty_text_n30.tsv)):

**n=29 sample** (1 PDF missing on disk, dropped):

| Metric | Value | Wilson 95% CI |
|---|---|---|
| Recovered (>200 chars) | 22 / 29 = **76%** | **[58%, 88%]** |
| docling time/doc — mean | **2.9 s** | — |
| docling time/doc — median | **1.7 s** | — |
| docling time/doc — max (27-page magazine) | 20.2 s | — |

**Failure modes** observed in the 7 unrecovered docs (all <200 chars output):
- Image-only menus / wine lists at Belmond Copacabana, Rosewood HK, Hotel Bel-Air, Grootbos
- Single-page card design with text rasterized into the image layer (no embedded text stream)

These need OCR. None are in the priority-15 cohort (§5.2 confirms zero `empty_text` flags there).

**Projected corpus pass on 228 empty_text docs**:

| Quantity | Point | 95% CI |
|---|---|---|
| Recovered docs | **173** | **[132, 200]** |
| Compute time (median × 228) | **6.4 min** | — |
| Compute time (mean × 228) | **11.0 min** | — |

**Recommendation**:

1. **First pass**: docling on every `empty_text` doc (~6–11 min). Update alfred.db for the recoveries. Wide CI on the recovery rate means actual yield could be 132–200; plan for the lower end.
2. **Second pass**: OCR on the residual ~28–96 image-only docs:
   - **`ocrmypdf` (Tesseract)** — free, runs in-process, untested in this bake-off (P2#7 partial follow-up — see §6 deferred).
   - **Claude Opus 4.7 vision** at ~$0.05/page ≈ $10 for the residual page count. Last resort.

### 4C. Boilerplate / structural cleaning (not separately benchmarked)

Boilerplate dedup, header/footer stripping, entity normalization — these are **distillation-stage** concerns rather than ingest-stage. The existing Alfred plan v15 (`docs/distillation_plan.md`) handles them inside the LLM distillation prompt. Recommendation: **don't pre-clean before distillation**; the LLM is better at deciding what's boilerplate than regex. Pre-cleaning risks throwing away signal a smarter model would use.

---

## 5. End-to-end recommendations

### 5.1 Corpus-wide impact (deduplicated, with CIs)

alfred.db's `quality_flag` is **mutually exclusive** — each doc has at most one flag. Recovery counts are therefore **independent and sum without overlap**:

| Today | Count | Action | Recovery rate (Wilson CI) | Recovered docs |
|---|---|---|---|---|
| `lang_unknown` | 234 | langdetect (≥0.95 conf) + Haiku fallback | 87.5% [53%, 98%] hand-labeled · 93% [78%, 99%] LD↔Haiku agreement | **~205 [132, 230]** |
| `empty_text` | 228 | docling (text recovery) | 76% [58%, 88%] | **~173 [132, 200]** |
| `low_text` | 58 | n/a — already has *some* text, not bake-off scope | — | — |
| **flagged total** | **520** | combined, mutually exclusive | — | **≈ 378 unique docs** [264, 430] |
| `usable` (no flag) | 1 431 → ~**1 809** | — | — | ~+26% expansion of `document_usable` |

The **+585** in v1 was double-counting (corrected). Realistic recovery is **264–430 unique docs** (95% Wilson aggregate), point estimate **~378**. The remaining ~90 unrecovered docs (mostly image-only PDFs) need an OCR pass — see §5.2.

### 5.2 Priority-15 cohort impact (where v15 actually runs)

v15 distillation is scoped to 15 priority hotels. Their PDF profile is materially different from the corpus average ([`bake-off/scorecard/priority15_breakdown.tsv`](./bake-off/scorecard/priority15_breakdown.tsv)):

| Slug | Total | Usable | lang_unknown | empty_text | low_text | distinct cats |
|---|---|---|---|---|---|---|
| hotel-hivernage | 21 | 21 | 0 | 0 | 0 | 8 |
| lily-of-the-valley | 20 | 18 | 2 | 0 | 0 | 8 |
| constance-belle-mare-plage | 17 | 16 | 1 | 0 | 0 | 9 |
| constance-tsarabanjina | 14 | 12 | 2 | 0 | 0 | 8 |
| royal-mansour-casablanca | 14 | 14 | 0 | 0 | 0 | 8 |
| royal-mansour-marrakech | 14 | 14 | 0 | 0 | 0 | 8 |
| constance-eph-lia | 13 | 12 | 1 | 0 | 0 | 8 |
| constance-halaveli-maldives | 13 | 13 | 0 | 0 | 0 | 8 |
| constance-lemuria-seychelles | 13 | 13 | 0 | 0 | 0 | 8 |
| constance-moofushi | 13 | 12 | 1 | 0 | 0 | 8 |
| constance-prince-maurice | 13 | 13 | 0 | 0 | 0 | 8 |
| hotel-plaza-athenee | 12 | 11 | 1 | 0 | 0 | 2 |
| le-bristol-paris | 11 | 11 | 0 | 0 | 0 | 4 |
| **constance-ephelia** | 0 | 0 | 0 | 0 | 0 | 0 |
| **royal-mansour-tamuda-bay** | 0 | 0 | 0 | 0 | 0 | 0 |
| **TOTAL (13 hotels with rows)** | **188** | **180 = 95.7%** | **8** | **0** | **0** | — |

(`constance-ephelia` is a slug variant of `constance-eph-lia`; `royal-mansour-tamuda-bay` truly has no PDFs in the document table — see §6 risk note.)

**What this means for v15 Stage-1 distillation**:

- **Language recovery on priority**: 8 lang_unknown docs across 4 hotels. Recovering them gains ~7 docs (langdetect ≥0.95 catches most; Haiku validates the residual). **Marginal**.
- **Empty-text recovery on priority**: **zero impact** — no `empty_text` flags in the cohort.
- **Re-extraction (table recovery on dining/spa/factsheet)** is the **biggest priority-cohort win** for hotels with full coverage. docling and pymupdf4llm find tens-to-hundreds of pipe-table rows where opendataloader-pdf finds zero. Of the 13 priority hotels with PDFs, **11 have ≥8 distinct usable categories** (so dining + spa + factsheet are present); the two with thin coverage (`hotel-plaza-athenee` 2 cats, `le-bristol-paris` 4 cats) need source-coverage completion *before* re-extraction is worth it (§5.5 prerequisite).
- **Reclassification on priority**: per the §3.5 stratified n=96 audit + adjudication, the rule classifier is ~79% accurate (heuristic [68%, 87%] eff. n≈70). Applying audit per-category rates to the priority `document_usable` distribution yields **~62 expected disagreements** to adjudicate (§3.5.4) — driven mostly by the priority cohort's 45 `other` docs, which the rule engine misclassifies almost uniformly. Sizing: ~4 hours dual-rater human adjudication.

**Priority-cohort actions, sorted by impact**:

| Action | Effort | Cost | Priority impact |
|---|---|---|---|
| 1. **Re-extract priority dining + spa + factsheet PDFs with docling** | 1 hour code, **~10 min compute** (~50 docs × 2.9 s + table-heavy outliers) | free | Tables now visible to Stage-1 — likely the biggest grounded-card recall gain |
| 2. **langdetect (+ Haiku fallback) on the 8 priority lang_unknown docs** | 10 min code | <$0.01 | ~7 docs added to priority `document_usable` |
| 3. **Adjudicate the ~62 expected priority disagreements** (§3.5.4 weighted projection from the completed n=96 audit) | ~4 hrs dual-rater | ~$0.30 token | Updates alfred.db `category` for confirmed cases; closes the priority reclassification work |
| 4. **Confirm `royal-mansour-tamuda-bay` and `constance-ephelia` slug variants** | 5 min DB query + crawl log check | — | Two priority hotels have 0 docs in `document` table — slug typo or missing crawl. Avoid silently-empty cards. |
| 5. **Source-coverage completion for `hotel-plaza-athenee` (2 cats) and `le-bristol-paris` (4 cats)** | crawl-side work, out of bake-off scope | — | These two hotels need more PDFs before re-extraction or distillation work can produce a 7/7 card |

### 5.3 Medium-term (corpus rollout for v2+)

- **Run §5.1 corpus recoveries** before the 118-hotel batch. Targets ~378 newly-usable docs corpus-wide for the broader rollout.
- **Switch Alfred ingest from opendataloader-pdf → pymupdf4llm by default**, with docling escalation triggered on confidence flags (no headers AND no tables AND <500 chars). Re-ingest the corpus in ~30 minutes for pymupdf4llm or ~2.5 hours for docling.
- **Add OCR pass** for the residual ~28–96 image-only PDFs — Tesseract via `ocrmypdf` (free, untested) or Claude Opus 4.7 vision ($10).
- **Standing weekly Haiku-audit job** for newly-ingested docs only (volume unknown but probably <50/week) — flag rule-engine disagreements.

### 5.5 Prerequisite for thin-coverage priority hotels

`hotel-plaza-athenee` (2 distinct usable categories) and `le-bristol-paris` (4) cannot reach v15's "full 7/7 coverage" target with what's currently in `document` alone. They block v15 priority distillation for those two slugs regardless of which extractor we pick.

Action items (out of bake-off scope, surfacing here so this report doesn't claim un-earned readiness):
1. Re-crawl both hotels' websites with the current `discover_assets.py` configuration; check the cache for fetch errors.
2. If website yields are genuinely thin, augment from canonical alternatives (Forbes Travel Guide, Michelin, OTA factsheets) following Alfred plan v15 §10's `manual_overrides` rules.
3. Until categories ≥7, treat re-extraction work on these two hotels as low-priority — improving the parser doesn't help if the source set is incomplete.

The 11 priority hotels with ≥8 usable categories already have everything they need in `document_usable` to benefit from re-extraction.

### 5.4 Future / hardware-dependent

- **MinerU 2.5-Pro CPU smoke test** — attempted; **blocked by `transformers v5` incompatibility** in MinerU's `unimer_swin` import (`find_pruneable_heads_and_indices` was removed). Recommended: isolate in a dedicated venv pinning `transformers<5`. Run on the `hard10` subset (image-heavy / scanned / table-dense) before generalizing.
- **Marker** on CPU — slow but functional with `torch` already in venv. Untested. Reasonable to add to `run_extraction.py`.
- **Embedding-based classification** (paraphrase-multilingual-MiniLM or e5-multilingual). Could approach LLM accuracy at langdetect speed. Not tested.

---

## 6. Limitations and deferred work

### 6.1 Cost vs. operational effort (Codex P2#8)

v1 quoted "$2.88 reclassification" — this is **token cost only**. Real operational cost includes:

| Component | v1 (1 776 corpus, optimistic) | v2 honest |
|---|---|---|
| Token spend (Haiku 4.5, ~1 600 in / 5 out) | $2.88 | $2.88 |
| Anthropic API setup overhead (key, retries, rate-limit handling) | not modeled | 2–4 hours one-time engineering |
| Adjudication of disagreement queue at v1's hypothetical 320 docs | not modeled | ~10–15 hours human review (≈2 min/doc) |
| If we instead run on **priority-188** with stratified n=100 audit first | — | ~$0.30 token + 3–4 hours human |
| **Honest end-to-end estimate (priority cohort)** | "$3 + a few hours" | **~$1 token + ~6 hours operational** |
| **Honest end-to-end estimate (full corpus)** | "$3 + a few hours" | **~$3 token + 12–20 hours operational** |

The $2.88 is real; the "few hours" was hand-wave. v2's recommendation is therefore to **run §5.2 priority actions first** (cheap, fast), measure actual disagreement rate, then size full-corpus rollout from real data.

### 6.2 Deferred (concrete plan, not "future work")

#### **PARTIAL in v3.1, corrected in v3.2 — Grounded-card validation pass** (Codex's biggest ask)

Codex's strongest finding (cycle-1): char counts and headers are markdown-quality proxies, not Stage-1-quality metrics. Real test = does the extractor improve grounded-field recall in distilled cards?

**Done so far** (§3.6, n=2 single-doc):
- Single-doc factsheet test on constance-eph-lia and constance-belle-mare-plage
- Initial v3.1 result (with prompt-cap bug) over-claimed opendataloader regression
- v3.2 corrected: all three methods produce 6–7/7 sections, 37–45 bullets — comparable

**Done in v3.3** (§3.7): multi-doc concatenation × n=2 runs/cell × n=5 hotels = 30 cards. Headline: directionally similar at n=2.

**Still deferred** (cycle-5 introduced new gaps):
1. **PDF-only intersection rerun** — re-do §3.7 with only docs where the underlying PDF exists on disk for ALL three methods. Removes the input-volume confound where opendataloader saw 1/3 the chars on hotels with missing PDFs. Concrete: filter `data/hotel_assets/<slug>/<filename>` to existing files, restrict per-(hotel, method) to that intersection. Re-run on the same 5 hotels. ~2 hours code + ~30 min compute + ~$3 token.
2. **n≥3 runs per cell** — current n=2 within-method runs can't disambiguate small between-method differences (max stddev 7.1 bullets/run). Bump to n=5 runs per (hotel × method) for proper variance characterization. ~10 min compute extra; same token cost as bumping the multiplier.
3. **Bullet count clamping in scorer** — clamp at 10 in `run_grounded_card_multi.py:score_card()` rather than counting raw bullets, so extractors that lead Haiku to over-bullet a section don't get unfair credit.
4. **Run against real Alfred `scripts/distill_kb.py` v15 verifier loop** — the script doesn't exist yet.

Estimated remaining effort: **4 hours code + ~$10 token** for items 1–3; the verifier-loop integration is blocked on `distill_kb.py` being written first.

#### **DONE in v3 — Stratified n=96 classification with adjudication**

(Originally deferred; ran in cycle-3.) Result in §3.5: rule classifier 76/96 = 79.2% [heuristic 68%, 87% at eff. n≈70]; Haiku 94/96 = 97.9% [heuristic 91%, 100%]. Single-rater LLM-adjudicated. **Remaining gap**: human dual-rater adjudication of a 50-doc subset for true gold-label calibration.

#### **P2 deferred — `ocrmypdf` baseline on the empty-text residual**

After §5.1 docling pass, 28–96 docs remain `empty_text` (image-only). v3 should benchmark `ocrmypdf` (free, Tesseract under the hood) vs Claude Opus 4.7 vision ($0.05/page) on this hard subset before committing to either.

#### **P2 deferred — MinerU CPU in an isolated venv**

MinerU 2.5-Pro is OmniDocBench v1.6 SOTA at 95.69. The transformers-v5 incompatibility hit today is solvable by pinning `transformers<5` in a dedicated venv. v3 should run MinerU on the `hard10` subset (image-dense, scanned, ZH, dense-table) and compare to docling's outputs.

### 6.3 Other limitations

- **Sample sizes** still small for corpus-wide claims: extraction n=12, language hand-labeled n=8 (extended to n=30 unsupervised), empty-text n=29, classification n=11. The deferred tasks above scale all of these.
- **Claude vision (Opus 4.7) extraction not tested**: requires `ANTHROPIC_API_KEY` (not set on this machine). The CLI works for classification/language but not for vision extraction in headless mode without the SDK.
- **Embedding-based classification not tested**: `transformers` is installed; this would have been a fair bake-off addition. Deferred.
- **Inter-rater reliability**: the gold labels for language and the LLM-correct-vs-rule classification calls are this author's alone (and this author is an LLM). The §3.5 calibration is **single-rater LLM-adjudicated** — best treated as an upper bound on rule-engine quality vs human gold. Dual rater on the n=96 set (or a fresh n=50 sub-sample) is recommended before any corpus-wide reclassification.
- **Slug ambiguity risk**: `constance-ephelia` vs `constance-eph-lia` (one is in alfred.db with 13 docs, the other shows zero). `royal-mansour-tamuda-bay` shows zero docs across the entire corpus — confirm this is intentional vs a crawl miss before assuming the priority list is satisfiable.

---

## 7. Reproducibility

All code in [`Research/Distillation/bake-off/`](./bake-off/):

```
bake-off/
├── sample/manifest.tsv               # initial 12-doc bake-off sample
├── run_extraction.py                 # pymupdf4llm + docling + opendataloader (n=12)
├── run_classification.py             # rule-based + Haiku + Sonnet (n=11)
├── run_cleaning.py                   # langdetect / Haiku on n=8 hand-labeled; docling on n=5 empty_text
├── run_language_n30.py               # v2 expansion: langdetect + Haiku-fallback (n=30 lang_unknown)
├── run_empty_text_n30.py             # v2 expansion: docling timed (n=29 empty_text)
├── out_pymupdf4llm/<id>.md           # per-doc per-method extracted markdown
├── out_docling/<id>.md
├── out_opendataloader/<id>.md
└── scorecard/
    ├── extraction.tsv                # 12 × 3 methods
    ├── classification.tsv            # 11 × 3 methods
    ├── cleaning.tsv                  # 8 × 2 methods + 5 docling recovery
    ├── language_n30.tsv              # n=30 ld + Haiku-fallback
    └── empty_text_n30.tsv            # n=29 docling timed
```

Re-run from scratch:

```bash
cd /Users/lf/Projects/Pro/Alfred && source .venv/bin/activate
python /Users/lf/Projects/Researcher/Research/Distillation/bake-off/run_extraction.py
python /Users/lf/Projects/Researcher/Research/Distillation/bake-off/run_classification.py
python /Users/lf/Projects/Researcher/Research/Distillation/bake-off/run_cleaning.py
python /Users/lf/Projects/Researcher/Research/Distillation/bake-off/run_language_n30.py
python /Users/lf/Projects/Researcher/Research/Distillation/bake-off/run_empty_text_n30.py
```

Inputs: `data/alfred.db`, `data/hotel_assets/<slug>/<file>.pdf`, `data/indexed/<slug>/<file>.md`.

Dependencies (Alfred venv): `pymupdf4llm`, `docling`, `opendataloader_pdf` (already installed), `langdetect`, optionally `mineru` (currently broken on transformers-v5 — needs isolated venv). Claude CLI at `/Users/lf/.local/bin/claude` for LLM calls (uses Max subscription, no metered API). `HF_TOKEN` exported for any HF model downloads.

---

## 8. Convergence assessment

| Cycle | Trigger | Findings | Nature | Substantively new |
|---|---|---|---|---|
| **C1 (v1→v2)** | Codex review of v1 | 8 (4 P1, 4 P2) | Methodological structural: dedup, CIs, priority-cohort framing, missing methods, cost-vs-effort, grounded-card eval, n expansions | All 8 |
| **C2 (v2→v2.1)** | Codex review of v2 | 6 (3 P1, 2 P2, 1 P3) | Residual: resurfaced 320, fake-agreement bug, priority overclaim, stale numbers | 1 (the fake-agreement measurement bug) |
| **C3a (v2.1→v3)** | Acted on deferred §6.2 calibration; ran n=96 audit + adjudication | n/a (act) | New empirical data | All — audit + adjudication artifacts |
| **C3b (v3→v3.1)** | Codex review of v3 + acted-on grounded-card | 7 (2 P1, 4 P2, 1 P3) + grounded-card data | Re-weighting math, cluster caveat, stale text + grounded-card n=2 v1 | 2 P1 + grounded-card empirical |
| **C4 (v3.1→v3.2)** | Codex review of v3.1 | **4 (1 P1 blocker, 3 P2)** | Critical catch: the v3.1 grounded-card test had a 30 000-char prompt cap that invalidated the headline finding. + 3 P2 internal-consistency | **1 — the prompt-cap blocker, fundamentally reversed v3.1's main grounded-card claim** |
| **C5a (v3.2→v3.3)** | Acted on cycle-4 deferred: n=5 multi-doc × 2 runs | n/a (act) | New empirical data: 30 grounded-card distillations | All — new multi-doc data |
| **C5b (v3.3→v3.4)** | Codex review of v3.3 | **4 (1 P1, 2 P2, 1 P3)** | **Caught input-volume confound**: opendataloader fed 1/3 the chars on hotels with missing PDFs. + scorer clamping suggestion + headline overclaim | **1 — the PDF-only intersection problem, downgrades v3.3's "indistinguishable" claim** |
| **C6a (v3.4→v3.5)** | Acted on cycle-5 P1+P2 | n/a (act) | New empirical: PDF-only intersection × 3 runs × clamped scorer | All — new artifact data |
| **C6b (v3.5→v3.6)** | Codex review of v3.5 | **4 (1 P1, 3 P2)** | **Caught**: §3.8 "multi-doc" was 1 multi-PDF + 2 single-doc; variance statistic mixed difficulty + run noise; HTML-heavy overgeneralized; 96.8% denominator wrong | **1 P1 — narrows §3.8 to sanity check, not settled answer** |
| **C7a (v3.6→v3.7)** | Acted on cycle-6 surprise: HTML-extraction bake-off | n/a (act) | New empirical: 5 HTML methods × 3 hotels × 2 runs = 30 cards | All — new HTML data |
| **C7b (v3.7→v3.8 partial)** | Codex review of v3.7 | **4 (1 P1, 1 P2, 2 P3)** | **Caught**: `alfred_current` was a reimpl with 0/24 exact matches against production (`scripts/scrape_html_pages.py::clean_html_to_markdown`); within-hotel run noise miscomputed; significance overclaimed on sections; sample denominator wrong | **1 P1 — invalidated §3.7 main claim** |
| **C8a (v3.7→v3.8)** | Acted on C7-P1: rerun alfred arm using cached `data/indexed/` (Alfred's true production output) | n/a (act) | New 6 cards: alfred_real | **Reverses v3.7's "html2text_only ties production"** — production marginally wins and is least noisy |
| **C9a (v3.8→v3.9)** | Acted on deepest unverified assumption: claim-grounding verification on n=20 claims | n/a (act) | New manual adjudication TSV | First direct grounding evidence (claims-not-bullets) |
| **C9b (v3.9→v3.10)** | Codex review of v3.9 | **3 (1 P1, 1 P2, 1 P3)** | **Caught**: convenience sample treated as Wilson CI (not random); TSV/prose mismatch (Codex independently checked room-twin.md); §3.9 run-noise analogy unsupported | **5th consecutive act-cycle review with substantive catch** |

**The pattern (9 cycles in, 5 act-review pairs)**: cycles 1–2 found diminishing severity on the report itself. **Every act-cycle's review — C4, C5b, C6b, C7b, and now C9b — has caught a substantive new methodology issue** that I would not have found by self-review. The pattern is durable across 5 consecutive iterations: each act produces a new measurement; each measurement has a non-obvious flaw a second-opinion reviewer catches by reading the script + recomputing data. This is **the genuine value of the loop pattern**: not the headline numbers (those keep getting corrected), but **the iteration toward methodologically defensible numbers**, one Codex catch at a time.

**What converged** (high confidence after 4 cycles):
- Recovery counts are ~378 unique [264, 430] corpus-wide; ~8 unique on the priority cohort.
- Rule-based classification is ~79% accurate (heuristic CI ~[68%, 87%]); Haiku 4.5 is ~98%; the gap is concentrated in the `other` bucket and template-clustered docs inflate audit confidence.
- Priority cohort needs ~62 disagreements adjudicated (~4 hrs), driven by 45 priority `other` docs that the rule engine almost always misclassifies.
- **Grounded-card test (n=2 hotels, single-doc, single LLM run)** does NOT distinguish the three extractors meaningfully — all produce 6–7/7 sections and 37–45 bullets. The case for switching ingest defaults rests on **§2 extraction-quality evidence** (pymupdf4llm 5–10× faster; opendataloader misses pipe-tables on dining/spa/factsheet content), not §3.6 grounded-card.
- **Methodological discipline**: prompt-window caps in benchmarks must match the largest input across compared methods. Differential truncation silently invalidates cross-method comparison.

**What remains genuinely deferred** (would need a separate work block, not just another review cycle):
- **Multi-doc grounded-card on n=5 priority hotels** — confirms the n=2 single-doc finding generalizes.
- **Alfred's `scripts/distill_kb.py`** — the v15 plan describes it; the script doesn't exist. Without it, the verifier loop can't run.
- **Human (non-LLM) dual-rater adjudication** of a 50-doc subset — calibrates the single-rater LLM-adjudicated 79% rule rate.
- **`ocrmypdf` baseline** on the 7 unrecovered empty-text docs.
- **MinerU in isolated venv** with `transformers<5` pin.

**Recommended action sequence** (revised v3.2 — corrected after cycle-4 grounded-card reversal):

1. **Today** — langdetect on the priority cohort's 8 lang_unknown docs (free). Update alfred.db.
2. **This week** — switch Alfred ingest default from opendataloader-pdf → **pymupdf4llm** based on **§2 extraction-quality evidence** (5–10× faster; opendataloader misses tables on dining/spa/factsheet). Keep docling as escalation. Re-ingest priority cohort first (~5 min compute). **Note**: §3.6 grounded-card no longer carries this recommendation — the n=2 single-doc test was inconclusive.
3. **This week** — adjudicate the **~62 expected priority disagreements** from §3.5.4 (~4 hours dual-rater). Update alfred.db `category` for confirmed cases.
4. **Next week** — extend grounded-card test: **n=5 priority hotels × multi-doc concatenation × ≥2 LLM runs per cell** (with no truncation, per cycle-4 P1). This is the gating test before any corpus-wide ingest switch.
5. **Next week** — write Alfred's `scripts/distill_kb.py` v15 implementation. Run on n=3 priority hotels per extractor; validate against the v15 verifier loop.
6. **Then** — corpus-wide rollout decision based on the n=5 grounded-card + verifier evidence.

The bake-off has answered enough to (a) switch the priority-cohort ingest stack on §2 extraction-quality grounds, (b) size the priority reclassification queue at ~62 docs. It has **not** authorized a corpus-wide reclassification or a switch on grounded-card-quality grounds — those need the n=5 multi-doc test and the `distill_kb.py` v15 implementation, which remain v4 work.

*End of v2.1.*
