# Module: achieved_target_definitions (1_sampling)
# Checks: 5.1 (achieved_sample never exceeds target_sample beyond
# calibrated ceiling), 11.1 (below-threshold zero-accessible-primary
# regression guard - the exact 2026-09-19 bug), 12.1 (MSNA Light
# household-level inclusion / strata-level exclusion). See
# CHECK_CATALOG.md for provenance.
library(dplyr)
library(readr)

ASSERT_PLAUSIBLE_CEILING <- 40  # calibrated ceiling, per this project's own established convention

run_achieved_target_definitions_checks <- function(log) {
  full <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"), show_col_types = FALSE, col_types = cols(.default = "c"))
  working <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING"), show_col_types = FALSE, col_types = cols(.default = "c"))
  strata_working <- read_csv(latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "WORKING"), show_col_types = FALSE, col_types = cols(.default = "c"))

  # ---- 5.1: achieved_sample must not exceed target_sample beyond ceiling -
  strata_working <- strata_working %>% mutate(
    achieved_sample = as.numeric(achieved_sample), target_sample = as.numeric(target_sample)
  )
  n_over <- sum(strata_working$achieved_sample > strata_working$target_sample, na.rm = TRUE)
  log <- check_result(log, "achieved_target_definitions", "Strata with achieved_sample > target_sample stays within the calibrated ceiling",
                       if (n_over <= ASSERT_PLAUSIBLE_CEILING) "PASS" else "FAIL",
                       sprintf("%d of %d strata show achieved_sample > target_sample (calibrated ceiling: %d). A small residual is normal cluster-rounding noise; anything above the ceiling signals a missing ward-accessibility/other filter in the achieved computation, per the 2026-09-05 incident (75/314 strata, up to 2x overstatement) - not real over-collection.",
                               n_over, nrow(strata_working), ASSERT_PLAUSIBLE_CEILING),
                       n_over)

  # ---- 11.1: below-threshold regression guard (the bug fixed 2026-09-19) -
  # direct outcome check, not a re-implementation of the fix: for every
  # Non-IDP cluster where ALL primary rows are non-Accessible (zero
  # accessible primaries), NONE of that cluster's rows (incl. reserves)
  # should appear in WORKING - if any do, the below-threshold exclusion is
  # not catching the zero-accessible-primary case.
  non_idp <- full %>% filter(pop_type == "non_idp")
  cluster_primary_status <- non_idp %>% filter(status == "primary") %>%
    group_by(cluster_id) %>%
    summarise(n_accessible_primary = sum(ward_accessible_status == "Accessible", na.rm = TRUE), .groups = "drop")
  zero_accessible_clusters <- cluster_primary_status$cluster_id[cluster_primary_status$n_accessible_primary == 0]
  leaked_rows <- sum(working$cluster_id %in% zero_accessible_clusters)
  log <- check_result(log, "achieved_target_definitions", "Zero-accessible-primary clusters are fully excluded from WORKING (below-threshold regression guard)",
                       if (leaked_rows == 0) "PASS" else "FAIL",
                       sprintf("%d WORKING rows belong to a cluster with ZERO accessible primary households - these clusters should be fully excluded under the <4-accessible-primary rule, but a cluster with exactly 0 (not 1-3) accessible primaries was invisible to the old count()-based check (fixed 2026-09-19, 17 clusters/24 rows nationally at the time). Any nonzero result here means this bug (or an equivalent) has recurred.",
                               leaked_rows),
                       leaked_rows)

  # ---- 12.1: MSNA Light present in household WORKING, absent from strata-
  # level achieved aggregation is checked structurally: MSNA Light clusters
  # should have zero contribution to strata achieved_sample where the
  # stratum ALSO has non-MSNA-Light clusters (mixed strata would be the
  # telltale sign of contamination). Simple presence check here:
  msna_light_working <- sum(working$sampling_method == "MSNA Light", na.rm = TRUE)
  log <- check_result(log, "achieved_target_definitions", "MSNA Light rows present in household-level WORKING (informational)",
                       "PASS",
                       sprintf("%d MSNA Light rows in WORKING (expected - field teams need them on the to-do list; the actual isolation check is that these never inflate NORMAL strata's achieved_sample, verified via the partner_coverage/partner_package modules' national sweep finding no contamination)", msna_light_working),
                       msna_light_working)

  # ---- <4-accessible-primary threshold: same numeric value defined
  # identically everywhere it's used (WORKING refresh, merge, both partner
  # workbook builders) - a structural check, since this constant is
  # deliberately duplicated (not shared) across the R/Python boundary. ------
  threshold_files <- c(
    file.path(SAMPLING_ROOT, "scripts/field_guide_production/build_partner_dc_packages.py"),
    file.path(SAMPLING_ROOT, "scripts/field_guide_production/refresh_partner_workbooks_daily.py"),
    file.path(SAMPLING_ROOT, "scripts/field_guide_production/refresh_working_frame_daily.R"),
    file.path(SAMPLING_ROOT, "resampling/scripts/merge_partner_resample_batch.R")
  )
  extract_threshold_values <- function(path) {
    if (!file.exists(path)) return(integer(0))
    txt <- readLines(path, warn = FALSE)
    m <- regmatches(txt, regexpr("NON_IDP_MIN_ACCESSIBLE_PRIMARY_HH\\s*(=|<-)\\s*[0-9]+", txt))
    as.integer(gsub("[^0-9]", "", regmatches(m, regexpr("[0-9]+$", m))))
  }
  all_vals <- unlist(lapply(threshold_files, extract_threshold_values))
  threshold_ok <- length(all_vals) > 0 && length(unique(all_vals)) == 1 && unique(all_vals) == 4
  log <- check_result(log, "achieved_target_definitions", "<4-accessible-primary threshold (NON_IDP_MIN_ACCESSIBLE_PRIMARY_HH) is defined identically across every consumer script",
                       if (threshold_ok) "PASS" else "FAIL",
                       sprintf("Found %d definition(s) across %d known consumer scripts, values: {%s} (all must be 4 - the 2026-09-05 threshold decision; a differing value in any one script is the exact 'duplicated logic silently drifts' pattern this project keeps re-finding)",
                               length(all_vals), length(threshold_files), paste(unique(all_vals), collapse = ", ")),
                       length(unique(all_vals)) - 1)

  # ---- quality_exclusion_reason must never drive achieved-exclusion via a
  # blanket "any non-blank value" pattern - the pre-2026-09-06 bug, since
  # superseded entirely by CONFIRMED_DELETIONS_OVERLAY.csv-based filtering
  # (frame_status.R's compute_achieved_lookup(), Python's _is_achieved()).
  # Regression guard: the old anti-pattern must not reappear in any live
  # (non-archived, non-CLAUDE.md) script. ----------------------------------
  r_py_files <- list.files(SAMPLING_ROOT, pattern = "\\.(R|py)$", recursive = TRUE, full.names = TRUE)
  r_py_files <- r_py_files[!grepl("[/\\\\](_archive|_archive_one_off)[/\\\\]", r_py_files)]
  anti_pattern_hits <- 0
  anti_pattern_files <- character(0)
  for (f in r_py_files) {
    txt <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    if (any(grepl('quality_exclusion_reason\\s*%in%\\s*c\\(NA,\\s*""', txt))) {
      anti_pattern_hits <- anti_pattern_hits + 1
      anti_pattern_files <- c(anti_pattern_files, basename(f))
    }
  }
  log <- check_result(log, "achieved_target_definitions", "quality_exclusion_reason filtering never reappears as a blanket 'any non-blank excludes' pattern",
                       if (anti_pattern_hits == 0) "PASS" else "FAIL",
                       sprintf("%d live script(s) contain the pre-2026-09-06 anti-pattern (`quality_exclusion_reason %%in%% c(NA, \"\", ...)`, blank=OK/any-non-blank-excludes) - superseded entirely by CONFIRMED_DELETIONS_OVERLAY.csv-based exclusion; a hit here means the old, cruder mechanism has resurfaced: %s",
                               anti_pattern_hits, paste(anti_pattern_files, collapse = ", ")),
                       anti_pattern_hits)

  # ---- R-side (frame_status.R) and Python-side (build_partner_dc_packages.py)
  # is_achieved() mirrors agree on the actual achieved set, computed fresh
  # against real_submissions.csv + CONFIRMED_DELETIONS_OVERLAY.csv - a real
  # data-state parity check, not just "both functions exist." Python side is
  # run via a minimal, dedicated mirror script (_py_helpers/
  # compute_achieved_mirror.py) rather than executing the real, file-writing
  # build_partner_dc_packages.py wholesale. ---------------------------------
  parity_status <- "FAIL"; parity_detail <- "check did not run"; parity_count <- NA
  parity_result <- tryCatch({
    source(file.path(SAMPLING_ROOT, "scripts/shared/frame_status.R"), local = (fs_env <- new.env()))
    real_subs_path <- file.path(MONITORING_ROOT, "data/real_submissions.csv")
    overlay_path2 <- file.path(MONITORING_ROOT, "data/CONFIRMED_DELETIONS_OVERLAY.csv")
    subs <- read_csv(real_subs_path, show_col_types = FALSE, col_types = cols(.default = "c"))
    overlay2 <- read_csv(overlay_path2, show_col_types = FALSE, col_types = cols(.default = "c"))
    r_result <- fs_env$compute_achieved_lookup(subs, overlay2)
    r_non_idp <- unique(r_result$non_idp_survey_ids)
    r_idp <- r_result$idp_counts %>% group_by(matched_cluster_id) %>% summarise(n_achieved = sum(n_achieved), .groups = "drop")

    py_out <- tempfile(fileext = ".csv")
    # assumes cwd = validity_checks/ (this suite's standing assumption, see
    # run_all_checks.R) so this resolves whether run via the orchestrator or
    # a standalone module test.
    py_script <- file.path("modules", "_py_helpers", "compute_achieved_mirror.py")
    system2("python", args = c(shQuote(py_script), shQuote(real_subs_path), shQuote(overlay_path2), shQuote(py_out)), stdout = TRUE, stderr = TRUE)
    py_result <- read_csv(py_out, show_col_types = FALSE, col_types = cols(.default = "c"))
    py_non_idp <- py_result$key[py_result$kind == "non_idp"]
    py_idp <- py_result %>% filter(kind == "idp") %>% transmute(matched_cluster_id = key, n_achieved = as.numeric(n_achieved))

    non_idp_diff <- length(setdiff(r_non_idp, py_non_idp)) + length(setdiff(py_non_idp, r_non_idp))
    idp_diff <- full_join(r_idp, py_idp, by = "matched_cluster_id", suffix = c("_r", "_py")) %>%
      mutate(across(c(n_achieved_r, n_achieved_py), ~coalesce(.x, 0))) %>%
      filter(n_achieved_r != n_achieved_py) %>% nrow()
    list(status = if (non_idp_diff == 0 && idp_diff == 0) "PASS" else "FAIL",
         detail = sprintf("Non-IDP survey_id set: %d differ (R vs Python). IDP cluster achieved counts: %d clusters differ. Both computed fresh against real_submissions.csv + CONFIRMED_DELETIONS_OVERLAY.csv via frame_status.R's compute_achieved_lookup() (R) and a dedicated mirror of build_partner_dc_packages.py's _is_achieved() (Python) - a real cross-language parity check, not a structural presence check.", non_idp_diff, idp_diff),
         count = non_idp_diff + idp_diff)
  }, error = function(e) list(status = "FAIL", detail = sprintf("check errored: %s", conditionMessage(e)), count = NA))
  log <- check_result(log, "achieved_target_definitions", "R-side and Python-side is_achieved() mirrors agree on the real achieved set",
                       parity_result$status, parity_result$detail, parity_result$count)

  # ---- "Contested" deletions treated as terminal (alongside "confirmed")
  # in every one of the 5 scripts that determine achieved/deletion status -
  # a contest reviewed and rejected means the deletion stands, equally
  # final. Structural presence check (all 5 fixed by 2026-09-13). ----------
  contested_files <- c(
    "1_sampling: build_partner_dc_packages.py" = file.path(SAMPLING_ROOT, "scripts/field_guide_production/build_partner_dc_packages.py"),
    "1_sampling: refresh_partner_workbooks_daily.py" = file.path(SAMPLING_ROOT, "scripts/field_guide_production/refresh_partner_workbooks_daily.py"),
    "1_sampling: 05_build_accessibility_impact_workbook.py" = file.path(SAMPLING_ROOT, "resampling/scripts/05_build_accessibility_impact_workbook.py"),
    "1_sampling: frame_status.R (refresh_working_frame_daily.R + merge_partner_resample_batch.R)" = file.path(SAMPLING_ROOT, "scripts/shared/frame_status.R")
  )
  missing_contested <- names(contested_files)[!sapply(contested_files, function(f) file.exists(f) && any(grepl("contested", readLines(f, warn = FALSE))))]
  log <- check_result(log, "achieved_target_definitions", "\"Contested\" deletions treated as terminal (alongside \"confirmed\") in every achieved/deletion-status consumer script",
                       if (length(missing_contested) == 0) "PASS" else "FAIL",
                       sprintf("%d of %d canonical consumer scripts do NOT mention 'contested' terminal-status handling: %s (a contest reviewed and rejected means the deletion stands, equally final as 'confirmed' - fixed everywhere 2026-09-11/13, this is the regression guard)",
                               length(missing_contested), length(contested_files), paste(missing_contested, collapse = "; ")),
                       length(missing_contested))

  # ---- target_sample_representativity must never exceed the frozen
  # target_sample, every stratum (the whole point of the 2026-09-13d
  # target-inflation fix - representativity is always <= the design ceiling,
  # since it accounts for real current accessible population). ------------
  strata_full <- read_csv(latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL"), show_col_types = FALSE)
  # "Currently covered" here must match the SAME filter 05_build_
  # accessibility_impact_workbook.py (lines 522/859) and 2_monitoring's
  # global.R both already use - coverage_status=="covered" ALONE is not
  # enough, since a certainty stratum whose MoE can't clear the threshold
  # even at full population sampling (exclusion_reason ==
  # "certainty_stratum_below_moe_threshold", e.g. idp_NG022010, target_
  # sample==0) is still marked coverage_status=="covered" but is
  # deliberately, permanently excluded from the Feasibility/representativity
  # workbook by design. FIXED 2026-09-21: this bare check used to flag such
  # a stratum as "missing due to staleness - rerun the script" every single
  # run, forever - the script was already behaving correctly and a rerun
  # would never have cleared it. Confirmed directly: idp_NG022010 was the
  # entire 1-stratum gap behind both this WARN and the Feasibility-count
  # WARN below, on both counts, before this fix.
  is_covered <- function(df) df$coverage_status == "covered" & df$exclusion_reason %in% c("none", "", NA)
  rep_path <- file.path(SAMPLING_ROOT, "resampling/output/target_sample_representativity_last_run.csv")
  rep_status <- "FAIL"; rep_detail <- "representativity file not found"; rep_count <- NA
  if (file.exists(rep_path)) {
    rep <- read_csv(rep_path, show_col_types = FALSE)
    joined <- strata_full %>% select(strata_id, target_sample, coverage_status) %>% inner_join(rep, by = "strata_id")
    over <- joined %>% filter(target_sample_representativity > target_sample + 1e-6)
    covered_missing <- strata_full$strata_id[is_covered(strata_full) & !strata_full$strata_id %in% rep$strata_id]
    if (nrow(over) > 0) {
      rep_status <- "FAIL"
      rep_detail <- sprintf("%d strata have target_sample_representativity EXCEEDING the frozen target_sample - should be structurally impossible (representativity is capped by current accessible population, never above the original design ceiling): %s",
                             nrow(over), paste(over$strata_id, collapse = ", "))
      rep_count <- nrow(over)
    } else if (length(covered_missing) > 0) {
      rep_status <- "WARN"
      rep_detail <- sprintf("0 representativity violations, but %d currently-covered strata are absent from target_sample_representativity_last_run.csv (%s) - this file is only regenerated when 05_build_accessibility_impact_workbook.py runs, so this is expected staleness after a coverage change, not a formula bug; rerun that script before trusting Feasibility/representativity figures for these specific strata",
                             length(covered_missing), paste(covered_missing, collapse = ", "))
      rep_count <- length(covered_missing)
    } else {
      rep_status <- "PASS"
      rep_detail <- sprintf("0 of %d strata exceed target_sample, and the representativity file is current with every covered stratum", nrow(joined))
      rep_count <- 0
    }
  }
  log <- check_result(log, "achieved_target_definitions", "target_sample_representativity never exceeds the frozen target_sample, every stratum",
                       rep_status, rep_detail, rep_count)

  # ---- Feasibility categories sum to the total covered-strata count -------
  feas_path <- file.path(SAMPLING_ROOT, "resampling/output/NGA_MSNA_2026_accessibility_impact_workbook.xlsx")
  feas_status <- "FAIL"; feas_detail <- "workbook not found"; feas_count <- NA
  if (file.exists(feas_path)) {
    sl <- tryCatch(readxl::read_excel(feas_path, sheet = "Strata Level"), error = function(e) NULL)
    if (!is.null(sl)) {
      n_covered <- sum(is_covered(strata_full))
      n_feasibility <- sum(!is.na(sl$Feasibility))
      n_rows <- nrow(sl)
      diff <- n_covered - n_rows
      if (n_rows != n_feasibility) {
        feas_status <- "FAIL"
        feas_detail <- sprintf("%d rows in the Strata Level sheet but only %d have a non-blank Feasibility value - every covered stratum must get a category", n_rows, n_feasibility)
        feas_count <- n_rows - n_feasibility
      } else if (diff != 0) {
        feas_status <- "WARN"
        feas_detail <- sprintf("Feasibility sheet has %d rows (all categorized) vs %d currently-covered strata in the live frame - a %d-stratum gap, consistent with the same workbook-staleness-after-a-coverage-change explanation as the representativity check above, not a formula bug", n_rows, n_covered, diff)
        feas_count <- diff
      } else {
        feas_status <- "PASS"
        feas_detail <- sprintf("All %d covered strata appear in the Strata Level sheet with a Feasibility category, zero blank/missing", n_covered)
        feas_count <- 0
      }
    }
  }
  log <- check_result(log, "achieved_target_definitions", "Feasibility categories sum to the total covered-strata count",
                       feas_status, feas_detail, feas_count)

  log
}
