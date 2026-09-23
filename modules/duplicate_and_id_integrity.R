# Module: duplicate_and_id_integrity (1_sampling)
# Check 10.8: new_clusters/new_households row-set equality for the MOST
# RECENT resample batch - a standing regression guard for
# draw_supplementary_clusters_batch.R's own pre-merge equality assertion
# (2026-09-07's empty-cluster-orphan bugs), run against whatever the latest
# real batch happens to be, not a specific historical one. Zero-duplicate-
# survey_id is intentionally NOT reimplemented here - already covered by
# frame_integrity's shared implementation (see CHECK_CATALOG.md). See that
# file for full provenance.
library(dplyr)

run_duplicate_and_id_integrity_checks <- function(log) {
  runs_root <- file.path(SAMPLING_ROOT, "resampling/output/resample_runs")
  if (!dir.exists(runs_root)) {
    log <- check_result(log, "duplicate_and_id_integrity", "New-cluster new_clusters/new_households row-set equality (most recent batch)",
                         "WARN", sprintf("resample_runs/ directory not found at %s - nothing to check", runs_root))
    return(log)
  }

  partner_dirs <- list.dirs(runs_root, recursive = FALSE)
  partner_dirs <- partner_dirs[!grepl("^_", basename(partner_dirs))]
  batch_dirs <- unlist(lapply(partner_dirs, function(pd) list.dirs(pd, recursive = FALSE)))
  # basename prefix match, same as partner_dirs above (FIXED 2026-09-21: was
  # "[/\\]_archive[/\\]", which can never match a direct child's path - no
  # trailing separator - so it excluded nothing; latent, no "_" batch
  # folder existed when found)
  batch_dirs <- batch_dirs[!grepl("^_", basename(batch_dirs))]

  if (length(batch_dirs) == 0) {
    log <- check_result(log, "duplicate_and_id_integrity", "New-cluster new_clusters/new_households row-set equality (most recent batch)",
                         "WARN", "No resample batch directories found under resample_runs/ - nothing to check (this check is only meaningful after a real draw)")
    return(log)
  }

  mtimes <- file.info(batch_dirs)$mtime
  latest <- batch_dirs[order(mtimes, decreasing = TRUE)][1]
  nc_files <- list.files(latest, pattern = "^new_clusters.*\\.csv$", full.names = TRUE)
  nh_files <- list.files(latest, pattern = "^new_households.*\\.csv$", full.names = TRUE)

  if (length(nc_files) == 0 || length(nh_files) == 0) {
    log <- check_result(log, "duplicate_and_id_integrity", "New-cluster new_clusters/new_households row-set equality (most recent batch)",
                         "WARN", sprintf("Most recent batch (%s, %s) doesn't have both a new_clusters*.csv and new_households*.csv - can't check row-set equality here (may be a merge-staging or split folder, not a raw draw output)",
                                          basename(dirname(latest)), basename(latest)))
    return(log)
  }

  nc <- read.csv(nc_files[1])
  nh <- read.csv(nh_files[1])
  if (!("cluster_id" %in% names(nc)) || !("cluster_id" %in% names(nh))) {
    log <- check_result(log, "duplicate_and_id_integrity", "New-cluster new_clusters/new_households row-set equality (most recent batch)",
                         "WARN", sprintf("Most recent batch (%s) files are missing a cluster_id column - can't check", basename(latest)))
    return(log)
  }

  nc_ids <- unique(nc$cluster_id); nh_ids <- unique(nh$cluster_id)
  only_in_nc <- setdiff(nc_ids, nh_ids); only_in_nh <- setdiff(nh_ids, nc_ids)
  n_diff <- length(only_in_nc) + length(only_in_nh)
  log <- check_result(log, "duplicate_and_id_integrity", "New-cluster new_clusters/new_households row-set equality (most recent batch)",
                       if (n_diff == 0) "PASS" else "FAIL",
                       sprintf("Most recent batch: %s/%s (mtime %s). %d cluster_id(s) only in new_clusters.csv, %d only in new_households.csv - a mismatch here is the exact 2026-09-07 empty-cluster-orphan bug class (a Tier 2 candidate kept as a cluster-level row after its households were dropped for having zero eligible buildings)",
                               basename(dirname(latest)), basename(latest), format(max(mtimes, na.rm = TRUE)), length(only_in_nc), length(only_in_nh)),
                       n_diff)

  log
}
