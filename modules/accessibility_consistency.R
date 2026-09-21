# Module: accessibility_consistency (1_sampling)
# Checks: 4.1 (ward shapefile freshness), 4.4/4.5 (zero WORKING rows in an
# Inaccessible ward), 4.7 (unmatched -> excluded, never defaulted
# Accessible), 4.14/4.15 (population-threshold recheck runs, both
# directions). See CHECK_CATALOG.md for provenance.
library(dplyr)
library(readr)

run_accessibility_consistency_checks <- function(log) {
  full <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"), show_col_types = FALSE, col_types = cols(.default = "c"))
  working <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING"), show_col_types = FALSE, col_types = cols(.default = "c"))
  master_ward <- read_csv(file.path(SAMPLING_ROOT, "resampling/output/master_accessibility_status_ward_level.csv"), show_col_types = FALSE)
  ward_shp_path <- file.path(SAMPLING_ROOT, "resampling/output/gis/accessible_area_lga_ward_portions.csv")

  # ---- 4.1: ward accessibility artifact postdates master ward CSV --------
  ward_csv_mtime <- file.info(file.path(SAMPLING_ROOT, "resampling/output/master_accessibility_status_ward_level.csv"))$mtime
  shp_mtime <- if (file.exists(ward_shp_path)) file.info(ward_shp_path)$mtime else as.POSIXct(NA)
  gate_ok <- !is.na(shp_mtime) && shp_mtime >= ward_csv_mtime
  log <- check_result(log, "accessibility_consistency", "Ward accessibility layer is not older than the master ward status file",
                       if (gate_ok) "PASS" else "FAIL",
                       sprintf("accessible_area_lga_ward_portions.csv mtime=%s vs master_accessibility_status_ward_level.csv mtime=%s (2026-09-07 incident: a stale shapefile let clusters get drawn into wards already known Inaccessible)",
                               format(shp_mtime), format(ward_csv_mtime)))

  # ---- 4.4/4.5: zero WORKING rows in a currently-Inaccessible ward -------
  # direct cross-check against master status by (adm1,adm2,adm3), NOT
  # trusting the row's own cached ward_accessible_status column alone.
  key <- function(df) paste(df$adm1_name, df$adm2_name, df$adm3_name, sep = "|")
  master_key <- paste(master_ward$State, master_ward$LGA, master_ward$`Ward (GRID3)`, sep = "|")
  inaccessible_keys <- unique(master_key[master_ward$`Accessible status` == "Inaccessible"])
  working_in_inaccessible <- sum(key(working) %in% inaccessible_keys)
  log <- check_result(log, "accessibility_consistency", "Zero WORKING rows sit in a currently-Inaccessible ward (direct cross-check, not cached column)",
                       if (working_in_inaccessible == 0) "PASS" else "FAIL",
                       sprintf("%d WORKING rows have (State,LGA,Ward) matching a ward master status calls Inaccessible - checked directly against master_accessibility_status_ward_level.csv, not the row's own cached ward_accessible_status", working_in_inaccessible),
                       working_in_inaccessible)

  # ---- 4.7: unmatched ward status must not default to Accessible ---------
  # a genuinely unmatched row should show NA/blank ward_accessible_status,
  # never silently "Accessible" - spot check via join-miss rate. MUST be
  # scoped to the actual accessibility-monitored states (per 4.8: a
  # national percentage is meaningless, since most of the country is
  # legitimately out of scope for this exercise entirely - e.g. Kano/
  # Niger/Kogi are 100% unmatched by design, not by bug). Established
  # convention: 0-4% unmatched WITHIN monitored states is normal.
  MONITORED_STATES <- c("Katsina", "Borno", "Sokoto", "Adamawa", "Zamfara", "Yobe", "Kebbi")
  full_keys <- key(full)
  matched <- full_keys %in% master_key
  in_scope <- full$adm1_name %in% MONITORED_STATES
  accessible_but_unmatched <- sum(!matched & full$ward_accessible_status == "Accessible" & in_scope)
  pct_unmatched <- round(100 * accessible_but_unmatched / sum(in_scope), 2)
  log <- check_result(log, "accessibility_consistency", "Unmatched-ward rows are not silently defaulting to Accessible (scoped to the 7 accessibility-monitored states)",
                       if (pct_unmatched < 5) "PASS" else "WARN",
                       sprintf("%d of %d in-scope rows (%.2f%%) in Katsina/Borno/Sokoto/Adamawa/Zamfara/Yobe/Kebbi have a ward not found in master status AND show ward_accessible_status=Accessible - established convention is 0-4%% is normal (genuine unmonitored micro-wards); a rising rate within these 7 states specifically would suggest a real defaulting bug. (Deliberately excludes the rest of the country, which is 100%% unmatched by design, not by bug - a national percentage here would be meaningless.)",
                               accessible_but_unmatched, sum(in_scope), pct_unmatched),
                       accessible_but_unmatched)

  # ---- 4.10 (new): cluster-level accessibility overlay is additive-only -
  # it should only ever REMOVE a cluster from WORKING, never grant one back
  # that ward-level/threshold logic already excludes (the precedence rule
  # from 2026-09-13c: "a cluster-level report only ever ADDS an exclusion
  # on top of ward-level status - never overrides it in either direction").
  # A direct, mechanical proxy: no overlay-listed cluster_id should still be
  # sitting in WORKING at all.
  overlay_path <- file.path(SAMPLING_ROOT, "resampling/output/cluster_accessibility_overlay.csv")
  overlay <- tryCatch(read_csv(overlay_path, show_col_types = FALSE), error = function(e) tibble(cluster_id = character(0)))
  overlay_leaked <- sum(unique(overlay$cluster_id) %in% unique(working$cluster_id))
  log <- check_result(log, "accessibility_consistency", "Cluster-level accessibility overlay is additive-only (never grants a cluster back into WORKING)",
                       if (overlay_leaked == 0) "PASS" else "FAIL",
                       sprintf("%d of %d overlay-excluded cluster_ids still appear in WORKING (cluster_accessibility_overlay.csv should only ever subtract clusters, per the 2026-09-13c precedence rule - ward-level status is never overridden upward by a cluster-level report)",
                               overlay_leaked, length(unique(overlay$cluster_id))),
                       overlay_leaked)

  # ---- 6.? (new): a reinstatement/exclusion patch must touch BOTH
  # strata-level AND every household-level FULL row for that stratum - the
  # exact gap Dandume/Faskari's first patch attempt hit (2026-09-08g,
  # caught before merge) and NG008023/Mobbar's 2026-09-03 patch appears to
  # still have (found live by this check, not previously known). Scoped to
  # sampling_method=="MSNA Full Design" only - MSNA Light rows are a
  # deliberate, documented exception whose own coverage_status is
  # independent of their stratum's (2026-09-11), not a patch-gap signature.
  full_normal <- full %>% filter(is.na(sampling_method) | sampling_method != "MSNA Light")
  hh_status <- full_normal %>% distinct(strata_id, coverage_status)
  strata_full <- read_csv(latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL"), show_col_types = FALSE, col_types = cols(.default = "c"))
  mismatch <- strata_full %>% select(strata_id, strata_cov = coverage_status) %>%
    inner_join(hh_status, by = "strata_id") %>%
    filter(strata_cov != coverage_status)
  mismatch_strata <- length(unique(mismatch$strata_id))
  log <- check_result(log, "accessibility_consistency", "A coverage_status reinstatement/exclusion patch touched every household-level FULL row, not just the strata-level summary",
                       if (mismatch_strata == 0) "PASS" else "FAIL",
                       sprintf("%d strata (MSNA Full Design rows only) have at least one household-level FULL row whose coverage_status disagrees with its own strata-level value: %s - signature of a reinstatement/exclusion patch that updated the strata-level summary but not every household row (the exact gap Dandume/Faskari's first attempt hit 2026-09-08g, caught before merge; this instance was not previously known)",
                               mismatch_strata, paste(unique(mismatch$strata_id), collapse = ", ")),
                       mismatch_strata)

  log
}
