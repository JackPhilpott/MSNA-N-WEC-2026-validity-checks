# Module: coverage_assignment_complete (cross-repo) - added 2026-09-25
# Jack's rule: ANY LGA (or point) without a partner is flagged for immediate
# resolution - never a quiet "Other" / "Not partner-assigned" label. Two flagged
# states, both defined in 2_monitoring/scripts/shared/coverage_state.R (this module
# sources that file, so the definition lives in exactly one place):
#   UNASSIGNED - the frame says an LGA is COVERED but it has no partner
#                (no partner_lga_assignment.csv row, or blank partners_covering).
#   UNRESOLVED - the frame says an LGA is NOT covered (partner_coverage_declined)
#                and config/coverage_decisions.csv holds no valid decision for it.
# LGAs whose every stratum is `excluded` are NOT flagged: the frame's own
# exclusion_reason already documents that decision.
#
# Deliberately recomputed HERE from the canonical sources (1_sampling's FULL frame,
# 2_monitoring's assignment + decision record), independent of the
# coverage_state_by_lga.csv the dashboard reads, so a stale or hand-edited state
# file cannot make the flag pass by itself (check 4 compares them).
library(dplyr)
library(readr)

run_coverage_assignment_complete_checks <- function(log) {
  mod <- "coverage_assignment_complete"
  source(file.path(MONITORING_ROOT, "scripts/shared/coverage_state.R"), local = TRUE)

  strata_full <- read_csv(latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL"),
                          show_col_types = FALSE, col_types = cols(.default = "c"))
  assignment <- read_csv(file.path(MONITORING_ROOT, "input_data/partner_coverage/partner_lga_assignment.csv"),
                         show_col_types = FALSE, col_types = cols(.default = "c"))
  dec <- read_coverage_decisions(file.path(MONITORING_ROOT, "config/coverage_decisions.csv"))
  st <- compute_coverage_state(strata_full, assignment, dec$valid)

  lga_label <- function(df, max_n = 15) {
    lab <- paste0(df$adm1_name, "/", df$adm2_name)
    if (length(lab) > max_n) paste0(paste(lab[seq_len(max_n)], collapse = "; "), "; +", length(lab) - max_n, " more") else paste(lab, collapse = "; ")
  }

  # 1. covered LGAs all have a partner
  un <- st[st$coverage_flag == "UNASSIGNED", ]
  log <- check_result(log, mod, "Every LGA the frame calls covered has a partner (none UNASSIGNED)",
    if (nrow(un) == 0) "PASS" else "FAIL",
    if (nrow(un) == 0) sprintf("all %d covered LGAs have a row in partner_lga_assignment.csv and a partners_covering value on every covered stratum",
                               sum(st$frame_state == "covered"))
    else sprintf("%d covered LGA(s) have NO partner - the dashboard shows them as UNASSIGNED and their target is owned by nobody: %s. Fix Partnerscoverage.xlsx / the frame, then re-run cleaning/prep/prep_partner_lga_assignment.R.",
                 nrow(un), lga_label(un)),
    nrow(un))

  # 2. not-covered LGAs all have a documented decision
  ur <- st[st$coverage_flag == "UNRESOLVED", ]
  log <- check_result(log, mod, "Every LGA the frame calls not-covered has a recorded decision (none UNRESOLVED)",
    if (nrow(ur) == 0) "PASS" else "FAIL",
    if (nrow(ur) == 0) sprintf("%d not-covered LGA(s), all documented in config/coverage_decisions.csv (%d valid decision row(s))",
                               sum(st$frame_state == "not_covered"), nrow(dec$valid))
    else sprintf("%d not-covered LGA(s) have no partner and no valid decision%s: %s. Assign a partner, or add a row (decision = accepted_not_covered) to 2_monitoring/config/coverage_decisions.csv.",
                 nrow(ur), if (nrow(dec$valid) == 0) " - the decision record is EMPTY (not yet seeded), so this lists every not-covered LGA" else "", lga_label(ur)),
    nrow(ur))

  # 3. decision record well-formed; no orphans / superseded rows
  frame_lga <- unique(st$adm2_pcode); frame_state <- unique(st$adm1_pcode)
  nc_lga <- st$adm2_pcode[st$frame_state == "not_covered"]; nc_state <- unique(st$adm1_pcode[st$frame_state == "not_covered"])
  orphan <- dec$valid[(dec$valid$scope == "lga" & !dec$valid$pcode %in% frame_lga) | (dec$valid$scope == "state" & !dec$valid$pcode %in% frame_state), ]
  superseded <- dec$valid[(dec$valid$scope == "lga" & dec$valid$pcode %in% frame_lga & !dec$valid$pcode %in% nc_lga) |
                            (dec$valid$scope == "state" & dec$valid$pcode %in% frame_state & !dec$valid$pcode %in% nc_state), ]
  n_bad <- nrow(dec$invalid)
  log <- check_result(log, mod, "Decision record is well-formed, and every row still refers to a not-covered LGA/state",
    if (!dec$file_found || n_bad > 0) "FAIL" else if (nrow(orphan) + nrow(superseded) > 0) "WARN" else "PASS",
    if (!dec$file_found) "config/coverage_decisions.csv does not exist - no decision can clear any not-covered LGA"
    else if (n_bad > 0) sprintf("%d invalid row(s) clear nothing: %s", n_bad, paste0(dec$invalid$pcode, " (", dec$invalid$problem, ")", collapse = "; "))
    else if (nrow(orphan) + nrow(superseded) > 0) sprintf("%d row(s) name a pcode absent from the frame (%s) and %d row(s) decide something that is no longer not-covered (%s) - housekeeping, not an error: the LGA/state was reassigned or the frame changed",
                                                          nrow(orphan), paste(orphan$pcode, collapse = ", "), nrow(superseded), paste(superseded$pcode, collapse = ", "))
    else sprintf("%d decision row(s), all valid and all still current", nrow(dec$valid)),
    n_bad + nrow(orphan) + nrow(superseded))

  # 4. the state file the dashboard reads matches an independent recompute
  compare_state <- function(path, label, missing_status) {
    if (!file.exists(path)) return(check_result(log, mod, label, missing_status, sprintf("%s not found - run refresh_coverage_state() (scripts/shared/coverage_state.R)", path), NA))
    f <- read_csv(path, show_col_types = FALSE, col_types = cols(.default = "c"))
    m <- st %>% select(adm2_pcode, expect = coverage_flag) %>% left_join(f %>% select(adm2_pcode, got = coverage_flag), by = "adm2_pcode")
    diff <- m %>% filter(is.na(got) | got != expect)
    check_result(log, mod, label, if (nrow(diff) == 0 && nrow(f) == nrow(st)) "PASS" else if (missing_status == "FAIL") "FAIL" else "WARN",
      if (nrow(diff) == 0 && nrow(f) == nrow(st)) sprintf("%d LGAs, flags identical to an independent recompute", nrow(st))
      else sprintf("%d of %d LGAs differ from an independent recompute (%d rows in the file): stale - re-run refresh_coverage_state() (%s)",
                   nrow(diff), nrow(st), nrow(f), if (missing_status == "FAIL") "the dashboard reads this file" else "this mirror is refreshed at the next bundle_dashboard_mirrors()"),
      nrow(diff))
  }
  log <- compare_state(file.path(MONITORING_ROOT, "input_data/partner_coverage/coverage_state_by_lga.csv"),
                       "coverage_state_by_lga.csv (input_data) matches an independent recompute", "FAIL")
  log <- compare_state(file.path(MONITORING_ROOT, "dashboard_app/input_data/partner_coverage/coverage_state_by_lga.csv"),
                       "coverage_state_by_lga.csv (dashboard_app mirror) matches an independent recompute", "WARN")
  run_partner_registry_checks(log)
}

# ---- partner registry (added 2026-09-25, same module: it is the other half of "no partner-less data") ----
# A partner whose LGAs are all reassigned (ACF -> ZOA) holds no assignment row, so partner lists derived
# from the assignment lose it - and with it its interviews' "known collector" status. The registry is the
# assignment's partners + 2_monitoring/config/partner_registry.csv (scripts/shared/partner_registry.R).
run_partner_registry_checks <- function(log) {
  mod <- "coverage_assignment_complete"
  source(file.path(MONITORING_ROOT, "scripts/shared/partner_registry.R"), local = TRUE)
  reg <- read_partner_registry(MONITORING_ROOT)

  # 5. every collector in the submissions is a registered partner
  subs_path <- file.path(MONITORING_ROOT, "data/real_submissions.csv")
  if (!file.exists(subs_path)) {
    log <- check_result(log, mod, "Every submission's collector is a registered partner", "FAIL", sprintf("%s not found", subs_path), NA)
  } else {
    subs <- read_csv(subs_path, show_col_types = FALSE, col_types = cols_only(org_id = "c"))
    tab <- table(subs$org_id[!is.na(subs$org_id) & nzchar(subs$org_id)])
    unknown <- setdiff(names(tab), reg$org_id)
    log <- check_result(log, mod, "Every submission's collector is a registered partner",
      if (length(unknown) == 0) "PASS" else "FAIL",
      if (length(unknown) == 0) sprintf("all %d collector org_ids in real_submissions.csv are registered (%d with LGAs, %d with none)", length(tab), sum(reg$n_lgas > 0), sum(reg$n_lgas == 0))
      else sprintf("%d collector org_id(s) are in no assignment row and not in config/partner_registry.csv: %s (%d interviews). Either a typo in the KoBo org_id, or a partner that lost its LGAs - add it to 2_monitoring/config/partner_registry.csv.",
                   length(unknown), paste(unknown, collapse = ", "), sum(tab[unknown])),
      length(unknown))
  }

  # 6. the derived registry files the dashboard reads equal a recompute
  compare_reg <- function(path, label, stale_status) {
    if (!file.exists(path)) return(check_result(log, mod, label, stale_status, sprintf("%s not found - run refresh_partner_registry()", path), NA))
    f <- read_csv(path, show_col_types = FALSE, col_types = cols(.default = "c"))
    a <- paste(reg$org_id, reg$n_lgas); b <- paste(f$org_id, f$n_lgas)
    ok <- setequal(a, b)
    check_result(log, mod, label, if (ok) "PASS" else stale_status,
      if (ok) sprintf("%d partners, identical to a recompute", nrow(reg))
      else sprintf("differs from a recompute (%d vs %d partners): stale - re-run refresh_partner_registry()", nrow(f), nrow(reg)),
      if (ok) 0 else length(setdiff(a, b)) + length(setdiff(b, a)))
  }
  log <- compare_reg(file.path(MONITORING_ROOT, "input_data/partner_coverage/partner_registry.csv"), "partner_registry.csv (input_data) matches a recompute", "FAIL")
  log <- compare_reg(file.path(MONITORING_ROOT, "dashboard_app/input_data/partner_coverage/partner_registry.csv"), "partner_registry.csv (dashboard_app mirror) matches a recompute", "WARN")
  log
}
