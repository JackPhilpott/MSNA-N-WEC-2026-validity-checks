# Module: frame_integrity (1_sampling)
# Checks: 2.1 (zero duplicate survey_ids), 1.16 (literal "NA" string in
# ward_accessible_status). See CHECK_CATALOG.md for full provenance.
# Requires paths_config.R and check_helpers.R already sourced (the
# orchestrator does this; sourced standalone for direct module testing).
library(dplyr)
library(readr)

run_frame_integrity_checks <- function(log) {
  full <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"), show_col_types = FALSE, col_types = cols(.default = "c"))
  working <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING"), show_col_types = FALSE, col_types = cols(.default = "c"))

  # ---- 2.1: zero duplicate survey_ids -------------------------------------
  dup_full <- sum(duplicated(full$survey_id))
  dup_working <- sum(duplicated(working$survey_id))
  log <- check_result(log, "frame_integrity", "Zero duplicate survey_ids (FULL)",
                       if (dup_full == 0) "PASS" else "FAIL",
                       sprintf("%d duplicate survey_id rows in FULL (%s)", dup_full, basename(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"))),
                       dup_full)
  log <- check_result(log, "frame_integrity", "Zero duplicate survey_ids (WORKING)",
                       if (dup_working == 0) "PASS" else "FAIL",
                       sprintf("%d duplicate survey_id rows in WORKING (%s)", dup_working, basename(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING"))),
                       dup_working)

  # ---- 1.16: literal string "NA" (not real blank) in ward_accessible_status
  literal_na <- sum(full$ward_accessible_status == "NA", na.rm = TRUE)
  log <- check_result(log, "frame_integrity", "No literal 'NA' string in ward_accessible_status (FULL)",
                       if (literal_na == 0) "PASS" else "FAIL",
                       sprintf("%d rows with the literal text \"NA\" instead of a real value or true blank - signature of a skipped stamping step (2026-09-08h incident)", literal_na),
                       literal_na)

  # ---- WORKING is a subset of FULL, re-derivable (basic sanity) -----------
  not_in_full <- sum(!working$survey_id %in% full$survey_id)
  log <- check_result(log, "frame_integrity", "Every WORKING survey_id exists in FULL",
                       if (not_in_full == 0) "PASS" else "FAIL",
                       sprintf("%d WORKING rows have a survey_id absent from FULL entirely (WORKING should always be a filtered subset of FULL)", not_in_full),
                       not_in_full)

  strata <- read_csv(latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL"), show_col_types = FALSE)

  # ---- target_sample formula: clusters_target_stage1*m_used (PPS) or
  # achieved_clusters*m_used (certainty), NEVER sum(target_households) -
  # the 2026-07-15 bug this guards against double-counted supplementary
  # clusters' own nominal targets when summed directly. ---------------------
  strata_f <- strata %>% mutate(
    expected_target = if_else(certainty_stratum %in% TRUE, achieved_clusters * m_used, clusters_target_stage1 * m_used),
    formula_diff = target_sample - expected_target
  )
  formula_bad <- sum(strata_f$formula_diff != 0, na.rm = TRUE)
  log <- check_result(log, "frame_integrity", "target_sample = clusters_target_stage1*m_used (PPS) or achieved_clusters*m_used (certainty)",
                       if (formula_bad == 0) "PASS" else "FAIL",
                       sprintf("%d of %d strata have target_sample not matching this formula (never sum(target_households) directly - the 2026-07-15 double-counting bug this guards against)", formula_bad, nrow(strata_f)),
                       formula_bad)

  # ---- household-row-count vs strata achieved_sample cross-check ---------
  # strata-level FULL's achieved_sample is the complete, unfiltered
  # historical row count (never accessibility-filtered - see the 2026-09-05
  # "IMPORTANT TERMINOLOGY" note) - so it must equal the actual primary-row
  # count in household-level FULL for that stratum, exactly.
  hh_counts <- full %>% filter(status == "primary") %>% count(strata_id, name = "row_count")
  row_check <- strata %>% select(strata_id, achieved_sample) %>%
    left_join(hh_counts, by = "strata_id") %>%
    mutate(row_count = coalesce(row_count, 0L), diff = achieved_sample - row_count)
  row_bad <- sum(row_check$diff != 0, na.rm = TRUE)
  log <- check_result(log, "frame_integrity", "Strata-level FULL achieved_sample equals the real primary-row count in household-level FULL",
                       if (row_bad == 0) "PASS" else "FAIL",
                       sprintf("%d of %d strata have achieved_sample disagreeing with a direct count of primary rows for that strata_id in household-level FULL", row_bad, nrow(row_check)),
                       row_bad)

  # ---- m_used never outside the current boost mechanism (currently: 6
  # everywhere - the 10-LGA m=6->7 blanket boost was superseded 2026-07-22
  # by the minimal-supplementary-cluster approach; m_used==7 appearing
  # anywhere would mean that superseded mechanism has resurfaced) ----------
  m_vals <- sort(unique(strata$m_used[!is.na(strata$m_used)]))
  m_ok <- identical(m_vals, 6)
  log <- check_result(log, "frame_integrity", "m_used never shows a value outside the current boost mechanism (currently: always 6)",
                       if (m_ok) "PASS" else "FAIL",
                       sprintf("distinct m_used values found: %s (only 6 is expected under the current, post-2026-07-22 design - any other value means a superseded or new boost mechanism is active and needs explaining)",
                               paste(m_vals, collapse = ", ")),
                       length(m_vals[m_vals != 6]))

  # ---- reserve/target columns present and non-null, all 3 Stage-2 paths --
  target_na <- sum(is.na(full$target_households) | full$target_households %in% c("", "NA"))
  reserve_na <- sum(is.na(full$reserve_households) | full$reserve_households %in% c("", "NA"))
  reserve_bad <- target_na + reserve_na
  log <- check_result(log, "frame_integrity", "target_households/reserve_households present and non-null across all rows (Non-IDP draw, reallocation, IDP)",
                       if (reserve_bad == 0) "PASS" else "FAIL",
                       sprintf("%d rows with a null/blank target_households, %d with null/blank reserve_households, across household-level FULL (should never happen post-2026-08-04 reserve-scaling fix, any pop_type/status/path)", target_na, reserve_na),
                       reserve_bad)

  log
}
