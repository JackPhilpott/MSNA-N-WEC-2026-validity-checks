# Check Catalog — curated from ~184 mined invariants

Source: full exhaustive read of `1_sampling/CLAUDE.md` (140 invariants) and
`2_monitoring/CLAUDE.md` (44 invariants), 2026-09-19/20. Every item below
traces to a specific dated incident in one of those files — see that file
for the full story if the one-line rationale here isn't enough.

Status key: **[LIVE]** implemented and runnable now · **[PLANNED]** real
standing check, not yet built · **[HISTORICAL]** a one-off fact/decision
that can't recur in this form, kept here only so the lesson isn't lost ·
**[PROCESS]** a discipline/habit check, not a data-state check — not
automatable the same way, listed for completeness.

## Module: `frame_integrity` (1_sampling)
| Check | Status |
|---|---|
| Zero duplicate `survey_id` in FULL and WORKING | **[LIVE]** |
| `target_sample` = `clusters_target_stage1*m_used` (PPS) or `achieved_clusters*m_used` (certainty), never `sum(target_households)` | **[LIVE]** |
| WORKING is exactly FULL filtered by the documented rule set, re-derivable | **[LIVE]** (via achieved/target module's WORKING-state check) |
| Household-row-count vs strata `achieved_sample` cross-check | **[LIVE]** |
| No literal string `"NA"` (vs real blank) in `ward_accessible_status` | **[LIVE]** |
| `m_used` never shows a value outside the current boost mechanism (currently: always 6) | **[LIVE]** |
| Reserve/target columns present and non-null across all 3 Stage-2 paths (Non-IDP draw, reallocation, IDP) | **[LIVE]** |

## Module: `accessibility_consistency` (1_sampling)
| Check | Status |
|---|---|
| Ward accessibility shapefile postdates master ward CSV (assert_fresh gate) | **[LIVE]** |
| Zero WORKING rows sit in a currently-Inaccessible ward | **[LIVE]** |
| Unmatched ward status rows are excluded+logged, never defaulted Accessible | **[LIVE]** |
| Cluster-level accessibility overlay never *increases* any stratum's accessible capacity (additive-only) | **[LIVE]** |
| Population-threshold exclusion check runs bidirectionally (catches newly-excluded AND newly-reinstatable strata) | **[LIVE]** |
| A reinstatement/exclusion patch touched BOTH strata-level and all household-level FULL rows (tell-tale: WORKING row count actually changed) | **[LIVE]** — found a real, previously-unknown gap live on first run (non_idp_NG008023/Mobbar, 2026-09-20), see run log |
| IDP site-frame accessibility uses spatial join, not raw-text ward name join | **[HISTORICAL]** (fixed once, structural — worth a regression check if `refresh_idp_site_frame_accessibility.R` is ever touched again) |

## Module: `achieved_target_definitions` (1_sampling + shared logic)
| Check | Status |
|---|---|
| `achieved_sample` never exceeds `target_sample` beyond the calibrated ceiling | **[LIVE]**, currently silenced (see `check_helpers.R`'s `SILENCED_CHECKS`, per Jack 2026-09-19/20) |
| Below-threshold check catches zero-accessible-primary clusters (the 2026-09-19 bug — regression guard) | **[LIVE]** |
| `<4`-accessible-primary threshold applied identically in WORKING, workbook, and merge scripts | **[LIVE]** |
| `quality_exclusion_reason` filtering uses an explicit whitelist, not "any non-blank" | **[LIVE]** — as a regression guard for the pre-2026-09-06 anti-pattern (the mechanism itself has since moved entirely to `CONFIRMED_DELETIONS_OVERLAY.csv`-based filtering, so this checks the old pattern never resurfaces, not a live whitelist) |
| R-side and Python-side `is_achieved()`/`_is_achieved()` mirrors agree | **[LIVE]** — real cross-language data parity check via a dedicated Python mirror script (`modules/_py_helpers/compute_achieved_mirror.py`), not just a structural presence check |
| "Contested" deletions treated as terminal in all 5 consumer scripts | **[LIVE]** |
| `target_sample_representativity` ≤ frozen `target_sample`, every stratum | **[LIVE]** |
| `target_sample_representativity` never increases run-over-run without flagging | **[LIVE]** (already an assert_plausible gate; this suite calls it) |
| Feasibility categories sum to total covered-strata count | **[LIVE]** |
| MSNA Light rows excluded from strata-level achieved_sample/achieved_clusters aggregation | **[LIVE]** |
| MSNA Light rows still present in household-level WORKING | **[LIVE]** |

## Module: `partner_coverage_alignment` (cross-repo) — generalizes the Dikwa sweep nationally
| Check | Status |
|---|---|
| Frame's `partners_covering`, 1_sampling's `Partnerscoverage.xlsx`, 2_monitoring's OWN copy of `Partnerscoverage.xlsx`, and `partner_lga_assignment.csv` (both 2_monitoring mirrors) all agree, for EVERY LGA×pop_type pair | **[LIVE]** |
| `coverage_summary_v2.csv` matches the current `Partnerscoverage.xlsx` | **[LIVE]** — was mislabeled LIVE before actually being built; built 2026-09-20 |
| Partner-name consistency scan (encoding, hardcoded lookup tables e.g. `ACCESSIBILITY_PARTNER_TO_ORG`) across both repos | **[LIVE]** |

## Module: `partner_package_alignment` (cross-repo) — generalizes today's KML/workbook/WORKING sweep
| Check | Status |
|---|---|
| Every partner's live KML + Needs Collecting sheet vs WORKING: zero stale, zero missing (national, all 19 partners) | **[LIVE]** |
| Stale partner/LGA folder detection (partner no longer assigned still has a live folder) | **[LIVE]** |
| MSNA Light never leaks into a partner's normal deliverable sheets/KML folder | **[LIVE]** |
| Fully-achieved IDP clusters have no lingering KML placemark | **[LIVE]** (regression guard for the 2026-09-19 fix) — found 7 live instances on first run (2026-09-20), see run log; resolves automatically on the next full partner-package rebuild |
| No live cluster field guide (factsheet) exists for a cluster the frame no longer contains — the KML checks never covered the printed `Cluster_guide/*.docx` guides at all; found 8 live guides for retired Nganzai clusters the night MSNA Light was resolved, i.e. a field team working from print would still have been sent to all 8. Completion doesn't trip it (a Complete cluster stays in FULL); already-archived guides are ignored, since archiving is the existing retirement convention | **[LIVE]** (2026-09-23) |

## Module: `cross_repo_propagation_freshness`
| Check | Status |
|---|---|
| 1_sampling's WORKING/FULL (household) content (md5) matches both 2_monitoring mirrors — verdict is content-based since 2026-09-21; mtime is reported but never decides (a source rewritten with unchanged bytes is still current) | **[LIVE]** |
| `_frame_version.txt` is current in both locations (not just self-reported) | **[LIVE]** |
| `real_submissions.csv`: canonical path used, not the bundled dashboard mirror, in every consumer script | **[LIVE]** |
| Known duplicate-input directories checked for currency (`dashboard_app/input_data/accessibility/` vs `input_data/accessibility/`, etc.) | **[LIVE]** |
| `real_submissions.csv` `deletion_status` matches the current `FLAGGED_DELETIONS_OVERLAY.csv` uuid by uuid — the dashboard's deletion basis is a copy joined in by `prep_real_submissions.R`, which `deploy_dashboard.R` runs BEFORE the independent checks and the overlay rebuild, so every run's new confirmations reach the partner workbooks/resampling (overlay readers) but not the dashboard until the next run (found 2026-09-22: 110 confirmed deletions still counted as Achieved on the dashboard only) | **[LIVE]** (2026-09-22) — FAILS until the order is fixed or prep is rerun |

## Module: `dashboard_deletion_identity` (2_monitoring)
| Check | Status |
|---|---|
| `Collected = Achieved + Confirmed Deletion + Pending Deletion` holds exactly, every stratum and cluster | **[LIVE]** |
| `is_confirmed_deletion()` double-gates on `interview_outcome=="completed"` AND settled status | **[LIVE]** |
| `pending_deletion_n` is a residual, never an independent sum (no double-counting) | **[LIVE]** (implied by the identity check above) |
| `NO_APPEAL_DELETION_REASONS` is exactly `{duration_under_20, no_consent}` | **[LIVE]** |
| `fcs_zero` has zero exclusion effect anywhere in the pipeline | **[LIVE]** |
| Oversampling cap excluded from the identity computation, cluster-grain deliberately uncapped | **[LIVE]** — checked as the Collected=Achieved+Confirmed+Oversampling-Surplus identity at CLUSTER grain via `compute_cluster_progress()`, not just nationally |
| `compute_progress_by_stratum()` exposes `credited_achieved_n`/`remaining_n`; `credited + remaining == target_active` every stratum (2026-09-21 rollup fix) | **[LIVE]** |
| `partner_progress_summary$remaining_n` equals an independent per-stratum floor-then-sum recompute, every partner | **[LIVE]** |
| Informational: partners / LGAs whose raw Achieved ≥ target while a stratum is still short (the case the pre-fix rollup hid) | **[LIVE]** — LGA-grain count added after Dashboard's review found `mod_map.R`'s status still on the raw comparison (8 live LGAs) |
| Structural: no rollup-grain `achieved_n >= target_active` "Complete" test remains anywhere in `dashboard_app/` (cluster-grain `target_households` pattern deliberately exempt) | **[LIVE]** |

## Module: `duplicate_and_id_integrity` (1_sampling)
| Check | Status |
|---|---|
| Zero duplicate survey_ids (also checked in `frame_integrity`, kept here for the draw-time-specific framing) | **[LIVE]** (shared implementation) |
| New-cluster `new_clusters`/`new_households` row-set equality (post-draw only) | **[LIVE]** — runs against whichever resample batch is most recently modified; reports WARN (not FAIL) if no batch exists yet to check |
| IDP "already used" matching is 30m-proximity-based, not exact site_id string match | **[HISTORICAL]** (fixed, structural regression risk if touched again) |

## Module: `oversampling_rollup_integrity` (cross-repo) — added 2026-09-21

Regression guard for the rollup bug Jack caught 2026-09-21: after Achieved went uncapped per cluster/stratum (2026-09-20), every LGA/partner/national rollup that summed raw achieved and raw target then subtracted/divided once let an oversampled stratum's surplus cancel a different stratum's shortfall. Fix everywhere: cap/floor per stratum first, then sum (`credited = Σ min(achieved_i, target_i)`, `remaining = Σ max(target_i − achieved_i, 0)`; `credited + remaining == target` by construction). Last night's partner status emails read the affected workbook headline verbatim and had to be re-sent.

- Every partner workbook README carries the post-fix headline (Credited / Still needed rows) — catches a regenerating script that lost the fix.
- README `Credited + Still needed == Total target`, every partner.
- README `Still needed` == sum of the Strata Summary sheet's per-row Still Needed; README `Credited` == sum of per-row min(Achieved, Target).
- Informational: partners whose raw Achieved ≥ target while strata are still short — the exact case the old headline hid.
- Dashboard twin (in `dashboard_deletion_identity`, which already sources global.R): `compute_progress_by_stratum()` exposes `credited_achieved_n`/`remaining_n`; per-stratum identity holds; `partner_progress_summary$remaining_n` matches an independent floor-then-sum recompute; same informational masked-partner count.

## Module: `resample_round_landing` (1_sampling) — added 2026-09-21

Acceptance test for Jack's decision to "make each round land the first time". Nightly redraws kept recurring because 05 sizes a top-up as N full clusters of 6 households while the draw judged hex accessibility by centroid only: on 2026-09-21, 57 of 262 Non-IDP clusters drawn came in under 6 accessible primaries and 31 fell below the 4-primary floor (2/3 ward straddle, 1/3 thin hexes), so strata landed short and needed another round. Evaluates the latest round: every partner's batch folder sharing the newest batch's folder label (time windows can't separate rounds — on 2026-09-21 one round's staging spanned ~4 h while the next two were 48 min apart).

- Every stratum drawn into is closed/negligible or honestly pool-exhausted on the post-merge 05 rebuild — none left "RECOVERABLE" (WARN, not FAIL, if 05 hasn't been rebuilt since the merge).
- No Non-IDP cluster in the round lands below the 4-accessible-primary floor (split ward straddle vs thin hex in the detail).
- Informational: clusters delivering 4–5 accessible primaries instead of 6.

Expected to FAIL until BOTH halves land: (1) the draw judges hexes on their households' wards with a 6-building floor — built and dry-run tested by Resampling 2026-09-21 (19/19 full vs 11/21 on HEAD), not yet used in a live round; (2) `analysis_remaining_eligible_pool.R` building-validates the pool 05 labels against — follow-up, not built. Until (2), strata whose validated pool is empty (on 2026-09-21: Kala/Balge, Ngala, Nganzai) stay labelled "RECOVERABLE" and this check keeps failing on them; that is a true, donor-facing defect in the label, not noise.

## Not yet covered by any module (flagged, not silently dropped)
- Draw-pipeline code robustness (empty-building-result handling, etc.) — these are code-path unit tests, not data-state checks; better suited to the pipeline's own test suite than a data sanity sweep.
- Methodology-doc-vs-data narrative consistency (state lists, boosted-strata tables) — low recurrence risk, manual spot-check territory.
- Most `[PROCESS]`-tagged items from the raw mining pass (e.g. "verify a claimed fact's provenance before trusting it," "confirm an approved plan was actually executed") — these are working-discipline habits for whoever's doing the work, not something a script checks.

**Total**: 45 standing checks curated from the raw catalog. **44 LIVE, 1 silenced (achieved>target ceiling, per Jack 2026-09-19/20), 0 PLANNED** as of the 2026-09-20 build-out — every check originally scoped in this catalog has now been implemented. 3 HISTORICAL items remain deliberately unbuilt (regression risks only, not standing checks). First full run after completion: 38 PASS / 3 WARN / 3 FAIL (of 44 live checks) — see `run_history/run_2026-09-20_002221.csv` and the Coordinator's own findings summary for detail on each non-PASS result.

## Module: `gis_layer_currency` (cross-repo)
Added 2026-09-22 at Jack's request: the dashboard's map layers are frame-DERIVED, so nothing about them self-corrects when the frame moves (2026-09-02: ~375 newly-drawn clusters completely absent from the PSU geometry; 2026-09-07: a stale accessibility shapefile let clusters be drawn into known-inaccessible wards). Content-based first, mtime only as a secondary ordering signal.
| Check | Status |
|---|---|
| Every active (WORKING) cluster the map should draw has geometry in psu_hexagons/psu_sites — MSNA Light clusters explicitly exempted (LGA-level, no georeferencing) and counted separately, never silently filtered | **[LIVE]** |
| MSNA Light clusters carry no geometry (informational; nonzero would mean Light became georeferenced or an id collided) | **[LIVE]** |
| No geometry for a cluster the FULL frame no longer contains — the "dropped cluster still drawn as a live target" direction | **[LIVE]** |
| Geometry for clusters in a no-longer-covered stratum (informational — legitimately still drawn per the 2026-09-14 rule, but must never count toward a rollup) | **[LIVE]** |
| Frame-derived layers (PSU geometry, accessibility portions) not older than the frame they describe | **[LIVE]** (WARN, not FAIL — content checks above are authoritative) |
| Every GIS layer mirrored into `dashboard_app/` at the same size — that bundle is all the deployed app can see | **[LIVE]** |
