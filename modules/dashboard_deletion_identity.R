# Module: dashboard_deletion_identity (2_monitoring)
# Checks: #4 (Collected = Achieved + Confirmed + Pending identity holds
# exactly), #17 (NO_APPEAL_DELETION_REASONS is exactly {duration_under_20,
# no_consent}), #21 (fcs_zero has zero exclusion effect anywhere). See
# CHECK_CATALOG.md for provenance. This module is the heaviest to run
# (sources the whole dashboard global.R) - kept separate so it can be
# skipped on a quick 1_sampling-only sweep.
library(dplyr)

run_dashboard_deletion_identity_checks <- function(log) {
  old_wd <- getwd()
  on.exit(setwd(old_wd))
  setwd(file.path(MONITORING_ROOT, "dashboard_app"))
  source("global.R", local = (env <- new.env()))

  subs <- env$submissions_raw
  collected <- sum(env$is_collected(subs), na.rm = TRUE)
  achieved <- sum(env$is_achieved(subs), na.rm = TRUE)
  confirmed_del <- sum(env$is_confirmed_deletion(subs), na.rm = TRUE)
  pending_del <- collected - achieved - confirmed_del

  identity_ok <- (achieved + confirmed_del + pending_del) == collected
  log <- check_result(log, "dashboard_deletion_identity", "Collected = Achieved + Confirmed Deletion + Pending Deletion holds exactly (national)",
                       if (identity_ok) "PASS" else "FAIL",
                       sprintf("Collected=%d, Achieved=%d, Confirmed=%d, Pending(residual)=%d. This identity must hold by construction - Pending is deliberately a residual (collected-achieved-confirmed), never an independently-summed count, precisely so it can never drift via double-counting.",
                               collected, achieved, confirmed_del, pending_del))

  # NO_APPEAL_DELETION_REASONS must be exactly {duration_under_20, no_consent}
  no_appeal <- tryCatch(env$NO_APPEAL_DELETION_REASONS, error = function(e) NULL)
  if (is.null(no_appeal)) {
    # try reading from issue_tracker.R directly if not in global.R's env
    tracker_path <- "../reports/partner_data_recovery/scripts/issue_tracker.R"
    if (file.exists(tracker_path)) {
      txt <- paste(readLines(tracker_path, warn = FALSE), collapse = "\n")
      m <- regmatches(txt, regexpr("NO_APPEAL_DELETION_REASONS\\s*<-\\s*c\\([^)]+\\)", txt))
      log <- check_result(log, "dashboard_deletion_identity", "NO_APPEAL_DELETION_REASONS is exactly {duration_under_20, no_consent}",
                           if (length(m) > 0 && grepl("duration_under_20", m) && grepl("no_consent", m) && !grepl("fcs_zero", m)) "PASS" else "WARN",
                           sprintf("Found definition: %s", ifelse(length(m) > 0, m, "not found - check issue_tracker.R location")))
    }
  } else {
    expected <- c("duration_under_20", "no_consent")
    match_ok <- setequal(no_appeal, expected)
    log <- check_result(log, "dashboard_deletion_identity", "NO_APPEAL_DELETION_REASONS is exactly {duration_under_20, no_consent}",
                         if (match_ok) "PASS" else "FAIL",
                         sprintf("Actual: {%s}. fcs_zero must never appear here (downgraded 2026-09-10 to a no-op flag); duplicate_point/pct_missing_flagged must stay appeal-eligible, i.e. absent from this set.", paste(no_appeal, collapse = ", ")))
  }

  # fcs_zero must have zero exclusion effect - check no completed row is
  # excluded from Achieved solely for fcs_zero
  fcs_zero_rows <- subs %>% filter(interview_outcome == "completed", !is.na(deletion_status))
  # a completed row flagged fcs_zero-only (heuristic: check flagged_deletion_reason column if present)
  if ("flagged_deletion_reason" %in% names(subs)) {
    fcs_only_excluded <- sum(subs$interview_outcome == "completed" & !env$is_achieved(subs) &
                                grepl("fcs_zero", subs$flagged_deletion_reason, ignore.case = TRUE) &
                                !grepl("duration_under_20|no_consent|duplicate_point", subs$flagged_deletion_reason, ignore.case = TRUE), na.rm = TRUE)
    log <- check_result(log, "dashboard_deletion_identity", "fcs_zero has zero exclusion effect on Achieved",
                         if (fcs_only_excluded == 0) "PASS" else "FAIL",
                         sprintf("%d completed rows are excluded from Achieved with fcs_zero as the only apparent reason - fcs_zero was downgraded 2026-09-10 to a plain logical-error flag with no deletion effect", fcs_only_excluded),
                         fcs_only_excluded)
  }

  # ---- is_confirmed_deletion() double-gates on interview_outcome=="completed"
  # AND settled deletion_status - checked directly against the real function
  # (env$is_confirmed_deletion), not a re-implementation: zero TRUE results
  # should ever have a non-completed outcome or an unsettled status. Guards
  # against exactly the drift this function's own header comment describes -
  # a tracker row keyed purely on uuid, with nothing structurally stopping
  # one existing for a non-collected interview. ----------------------------
  confirmed_flags <- env$is_confirmed_deletion(subs)
  bad_outcome <- sum(confirmed_flags & subs$interview_outcome != "completed", na.rm = TRUE)
  bad_status <- sum(confirmed_flags & !(subs$deletion_status %in% c("confirmed", "contested")), na.rm = TRUE)
  gate_bad <- bad_outcome + bad_status
  log <- check_result(log, "dashboard_deletion_identity", "is_confirmed_deletion() double-gates on interview_outcome==\"completed\" AND settled deletion_status",
                       if (gate_bad == 0) "PASS" else "FAIL",
                       sprintf("%d confirmed-deletion row(s) have interview_outcome != \"completed\", %d have a deletion_status outside {confirmed, contested} - either would silently inflate confirmed_deletion_n with no matching presence in collected_n, breaking the Collected identity for that row's stratum/cluster",
                               bad_outcome, bad_status),
                       gate_bad)

  # ---- Oversampling cap excluded from the Collected/Achieved/Confirmed
  # identity, and deliberately checked at CLUSTER grain (not just summed
  # nationally, which could mask a per-cluster violation via cancellation):
  # compute_cluster_progress()'s own identity, per 2_monitoring/CLAUDE.md -
  # "Collected = Achieved + Confirmed Deletion + Oversampling Surplus,
  # exactly, by construction" - must hold row-by-row, every cluster. -------
  cluster_progress <- env$compute_cluster_progress(subs)
  cluster_identity_bad <- sum((cluster_progress$achieved_n + cluster_progress$confirmed_deletion_n + cluster_progress$oversampling_surplus_n) != cluster_progress$collected_n)
  log <- check_result(log, "dashboard_deletion_identity", "Collected = Achieved + Confirmed Deletion + Oversampling Surplus holds exactly at CLUSTER grain (not just nationally)",
                       if (cluster_identity_bad == 0) "PASS" else "FAIL",
                       sprintf("%d of %d clusters (compute_cluster_progress()) violate the identity - checked per-cluster specifically because a national-level check alone could mask a per-cluster violation via cancellation across clusters",
                               cluster_identity_bad, nrow(cluster_progress)),
                       cluster_identity_bad)

  # ---- 2026-09-21 oversampling-rollup regression guards (dashboard side;
  # the partner-workbook side is modules/oversampling_rollup_integrity.R).
  # Once achieved_n went uncapped per stratum, every multi-stratum rollup
  # had to switch to cap/floor-per-stratum-then-sum, or an oversampled
  # stratum's surplus silently cancels another stratum's shortfall. -------
  pbs <- env$progress_by_stratum
  has_cols <- all(c("credited_achieved_n", "remaining_n") %in% names(pbs))
  log <- check_result(log, "dashboard_deletion_identity", "compute_progress_by_stratum() exposes credited_achieved_n and remaining_n (per-stratum capped/floored)",
                       if (has_cols) "PASS" else "FAIL",
                       if (has_cols) "both columns present - every downstream LGA/partner/national rollup must sum THESE, never raw achieved_n vs target"
                       else "columns missing - the 2026-09-21 rollup fix has been lost from global.R; every partner/LGA/national % and still-needed figure is exposed to cross-stratum masking again")
  if (has_cols) {
    id_bad <- sum(abs((pbs$credited_achieved_n + pbs$remaining_n) - pmax(pbs$target_active, 0)) > 1e-6, na.rm = TRUE)
    log <- check_result(log, "dashboard_deletion_identity", "credited_achieved_n + remaining_n == target_active at every stratum",
                         if (id_bad == 0) "PASS" else "FAIL",
                         sprintf("%d of %d strata violate the identity - must hold by construction (pmin/pmax against the same target_active)", id_bad, nrow(pbs)),
                         id_bad)

    pps <- env$partner_progress_summary
    recomputed <- vapply(pps$org_id, function(org) {
      my <- env$partner_adm2[[org]]
      if (is.null(my)) my <- character(0)
      rows <- pbs[pbs$adm2_pcode %in% my & pbs$status != "Dropped", ]
      sum(pmax(rows$target_active - rows$achieved_n, 0), na.rm = TRUE)
    }, numeric(1))
    partner_bad <- sum(abs(recomputed - pps$remaining_n) > 1e-6, na.rm = TRUE)
    log <- check_result(log, "dashboard_deletion_identity", "partner_progress_summary$remaining_n equals an independent per-stratum floor-then-sum, every partner",
                         if (partner_bad == 0) "PASS" else "FAIL",
                         sprintf("%d of %d partners disagree with an independent recompute from progress_by_stratum (floor at stratum grain, then sum, Dropped strata excluded) - a disagreement means build_partner_progress_summary() has reverted to subtracting after summing raw achieved_n",
                                 partner_bad, nrow(pps)),
                         partner_bad)
    n_masked <- sum(pps$achieved_n >= pps$target_active & pps$remaining_n > 0, na.rm = TRUE)
    log <- check_result(log, "dashboard_deletion_identity", "Partners whose raw Achieved >= target while strata are still short (informational - the exact case the pre-2026-09-21 rollup hid)",
                         "PASS",
                         sprintf("%d partner(s): %s", n_masked,
                                 if (n_masked == 0) "none" else paste(pps$partner_label[pps$achieved_n >= pps$target_active & pps$remaining_n > 0], collapse = ", ")),
                         n_masked)

    # ---- LGA grain, same question (added after Dashboard's review found
    # mod_map.R's lga_map_data() status still on the raw comparison, 8 live
    # LGAs affected): informational count of LGAs where the raw LGA sum
    # reads complete but a constituent pop-type stratum is still short. ----
    lga_roll <- pbs[pbs$status != "Dropped", ] %>%
      group_by(adm2_pcode, adm2_name) %>%
      summarise(target_active = sum(target_active, na.rm = TRUE), achieved_n = sum(achieved_n, na.rm = TRUE),
                remaining_n = sum(remaining_n, na.rm = TRUE), .groups = "drop")
    lga_masked <- lga_roll[lga_roll$target_active > 0 & lga_roll$achieved_n >= lga_roll$target_active & lga_roll$remaining_n > 0, ]
    log <- check_result(log, "dashboard_deletion_identity", "LGAs whose raw Achieved >= target while a pop-type stratum is still short (informational - any LGA-grain status must key off remaining_n, never this raw comparison)",
                         "PASS",
                         sprintf("%d LGA(s): %s", nrow(lga_masked),
                                 if (nrow(lga_masked) == 0) "none" else paste(sprintf("%s (%s short)", lga_masked$adm2_name, lga_masked$remaining_n), collapse = ", ")),
                         nrow(lga_masked))
  }

  # ---- Structural guard: the pre-2026-09-21 rollup-grain "Complete" test
  # (`achieved_n >= target_active`) must not exist anywhere in the dashboard
  # code. Every rollup-grain status now keys off remaining_n <= 0. The
  # cluster-grain test (`achieved_n >= target_households`) is a different
  # pattern and stays raw by design, so it is deliberately not matched. ----
  dash_files <- c(list.files("R", pattern = "\\.R$", full.names = TRUE), "global.R")
  old_pattern_hits <- character(0)
  for (f in dash_files) {
    txt <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    code_only <- sub("#.*$", "", txt)  # a comment DESCRIBING the old pattern is not a hit (first run flagged its own fix's comment)
    hits <- grep("achieved_n\\s*>=\\s*target_active", code_only)
    if (length(hits) > 0) old_pattern_hits <- c(old_pattern_hits, sprintf("%s:%s", basename(f), paste(hits, collapse = ",")))
  }
  log <- check_result(log, "dashboard_deletion_identity", "No rollup-grain status/Complete test on raw `achieved_n >= target_active` remains anywhere in dashboard_app (structural guard, 2026-09-21)",
                       if (length(old_pattern_hits) == 0) "PASS" else "FAIL",
                       sprintf("%d hit(s): %s - a rollup-grain 'Complete' on the raw comparison lets one stratum's surplus mask another's shortfall (the exact miss Dashboard's review caught in mod_map.R's lga_map_data() the night this fix landed); use remaining_n <= 0",
                               length(old_pattern_hits), if (length(old_pattern_hits) == 0) "none" else paste(old_pattern_hits, collapse = "; ")),
                       length(old_pattern_hits))

  log
}
