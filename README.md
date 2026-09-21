# MSNA N-WEC 2026 — Standing Validity/Sanity Check Suite

Built 2026-09-19/20, per Jack's request: a standardised, modular, on-demand
check suite consolidating every real lesson learned across this project's
history (both `1_sampling` and `2_monitoring`), so "is everything currently
aligned" can be answered mechanically instead of re-derived from memory
each time.

**Source of this suite's scope**: mined exhaustively from `1_sampling/CLAUDE.md`
and `2_monitoring/CLAUDE.md` (the project's own running incident logs) —
~184 distinct checkable invariants identified, each traced to a specific
dated incident. Not all 184 are standing/automatable (some are one-off
historical facts, documentation-consistency notes, or process discipline
rather than live data checks) — this suite implements the re-checkable
subset, organized into modules. See `CHECK_CATALOG.md` for the full curated
list, including which items are implemented vs. flagged for a later pass.

## How to run

- **Everything**: `Rscript run_all_checks.R` — runs every module in both
  repos, produces one unified pass/fail report.
- **One module**: `Rscript run_all_checks.R --module partner_coverage_alignment`
  (or any module name below) — for a targeted check after a specific kind
  of change (e.g. just ran a partner reassignment → run
  `partner_coverage_alignment` + `partner_package_alignment`, not everything).
- Ask Claude in chat: "run a full sweep" (everything) or "check
  [specific thing]" (Claude picks the relevant module(s)) — this is the
  intended day-to-day interface, the script itself is what actually executes.

## Structure

- `run_all_checks.R` — master orchestrator (this folder, repo-neutral).
- `CHECK_CATALOG.md` — the full curated list of invariants, one row per
  check, with status (implemented / not yet / not applicable-as-a-standing-check).
- `modules/` — one file per category, each independently runnable AND
  sourced by the orchestrator. Cross-cutting modules (touching both repos)
  live here directly. Repo-specific modules live inside their own repo
  (`1_sampling/scripts/shared/validity_checks/`,
  `2_monitoring/scripts/validity_checks/`) so they stay maintained
  alongside the code they check, and this orchestrator sources them from
  there — never a second, disconnected copy.

## Design principles (per Jack's brief)

- **Modular + unified**: every module runs standalone; `run_all_checks.R`
  runs all of them and merges results into one report.
- **Mechanical, not discretionary**: every check is a deterministic
  pass/fail (or a specific count) against a documented threshold — no
  silent judgment calls. A borderline/ambiguous result is reported as its
  own category, never quietly resolved one way.
- **No silent caps**: if a check's scope is bounded (e.g. "checked the 19
  live partner packages" not "checked all historical batches"), the report
  says so explicitly.
- **Built to be added to**: this is a living suite. New incidents this
  project produces should get a new check here, not just a one-off fix
  and a memory note.
