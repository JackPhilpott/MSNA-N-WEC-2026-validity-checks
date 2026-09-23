# Module: resample_round_landing (1_sampling)
# Acceptance test for Jack's 2026-09-21 decision "make each round land the
# first time". Diagnosis that night: 05 sizes a top-up as N full clusters of
# 6 households, but the draw judged hex accessibility by CENTROID only, so
# drawn clusters routinely under-deliver once households are stamped per
# ward - of 262 Non-IDP clusters drawn that day, 57 came in under 6
# accessible primaries and 31 fell below the 4-primary floor (contributing
# nothing), 2/3 of them from ward straddle. The stratum then lands short and
# needs another round the next night, burning a day of partners' fieldwork.
#
# Evaluates the LATEST ROUND: every partner's batch folder sharing the folder
# label (e.g. "2026-09-21_second_round") of the newest new_clusters*.csv. A
# round spans several partners' folders under one label; time can't define
# it - on 2026-09-21 one round's staging spanned ~4 h while the next two
# rounds were 48 min apart. duplicate_and_id_integrity looks only at the
# single newest folder, which is right for its own row-set check, not this.
library(dplyr)
library(readr)

NON_IDP_MIN_ACCESSIBLE_PRIMARY_HH_CHECK <- 4  # the 2026-09-05 threshold; its cross-script consistency is asserted in achieved_target_definitions

run_resample_round_landing_checks <- function(log) {
  mod <- "resample_round_landing"
  runs_root <- file.path(SAMPLING_ROOT, "resampling/output/resample_runs")
  partner_dirs <- list.dirs(runs_root, recursive = FALSE)
  partner_dirs <- partner_dirs[!grepl("^_", basename(partner_dirs))]
  batch_dirs <- unlist(lapply(partner_dirs, function(pd) list.dirs(pd, recursive = FALSE)))
  # basename prefix match - same rule as the partner level above; a path-
  # segment regex like "[/\\]_archive[/\\]" never matches a direct child
  batch_dirs <- batch_dirs[!grepl("^_", basename(batch_dirs)) & !grepl("TAINTED|reverted", basename(batch_dirs), ignore.case = TRUE)]
  nc_files <- unlist(lapply(batch_dirs, function(b) list.files(b, pattern = "^new_clusters.*\\.csv$", full.names = TRUE)))
  if (length(nc_files) == 0) {
    return(check_result(log, mod, "Latest resample round identified", "WARN", "no new_clusters*.csv under resample_runs/ - nothing to assess"))
  }
  mt <- file.info(nc_files)$mtime
  t_latest <- max(mt, na.rm = TRUE)
  latest_label <- basename(dirname(nc_files[which.max(mt)]))
  round_files <- nc_files[basename(dirname(nc_files)) == latest_label]
  round_label <- paste(sort(unique(sprintf("%s/%s", basename(dirname(dirname(round_files))), basename(dirname(round_files))))), collapse = ", ")

  round <- bind_rows(lapply(round_files, function(f) {
    d <- tryCatch(read_csv(f, show_col_types = FALSE, col_types = cols(.default = "c")), error = function(e) NULL)
    if (is.null(d) || !all(c("cluster_id", "strata_id") %in% names(d))) return(NULL)
    tibble(cluster_id = trimws(d$cluster_id), strata_id = d$strata_id,
           pop_type = if ("pop_type" %in% names(d)) d$pop_type else NA_character_)
  })) %>% distinct(cluster_id, .keep_all = TRUE)

  full <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"), show_col_types = FALSE,
                   col_types = cols_only(cluster_id = "c", strata_id = "c", pop_type = "c", status = "c", ward_accessible_status = "c"))
  merged <- round %>% filter(cluster_id %in% full$cluster_id)
  if (nrow(merged) == 0) {
    return(check_result(log, mod, "Latest resample round identified", "WARN",
                        sprintf("latest round (%s, %s) is staged but none of its %d cluster(s) are in FULL yet - assess after the merge",
                                round_label, format(t_latest), nrow(round))))
  }

  # ---- 1. no stratum drawn into is left "RECOVERABLE" after the post-merge
  # 05 rebuild (the round didn't close it although the pool had room) ------
  rep_path <- file.path(SAMPLING_ROOT, "resampling/output/strata_representativity_status.csv")
  rep <- read_csv(rep_path, show_col_types = FALSE, col_types = cols(.default = "c"))
  verdict_col <- "Representativity (10% MoE threshold)"
  if (file.info(rep_path)$mtime < t_latest) {
    log <- check_result(log, mod, "Every stratum drawn into by the latest round is closed or pool-exhausted after the post-merge 05 rebuild",
                         "WARN", sprintf("strata_representativity_status.csv (%s) predates the latest round (%s) - 05 hasn't been rebuilt since the merge, can't assess landing yet",
                                         format(file.info(rep_path)$mtime), format(t_latest)))
  } else {
    drawn_strata <- unique(merged$strata_id)
    v <- rep %>% filter(`Strata ID` %in% drawn_strata) %>% select(strata_id = `Strata ID`, verdict = all_of(verdict_col))
    still_open <- v %>% filter(grepl("RECOVERABLE", verdict))
    exhausted <- v %>% filter(grepl("NOT recoverable", verdict))
    log <- check_result(log, mod, "Every stratum drawn into by the latest round is closed or pool-exhausted after the post-merge 05 rebuild",
                         if (nrow(still_open) == 0) "PASS" else "FAIL",
                         sprintf("Round %s: %d strata drawn into; %d now closed/negligible, %d honestly pool-exhausted, %d still 'RECOVERABLE via supplementary draw' (%s)%s",
                                 round_label, length(drawn_strata), length(drawn_strata) - nrow(still_open) - nrow(exhausted), nrow(exhausted), nrow(still_open),
                                 if (nrow(still_open) == 0) "none" else paste(still_open$strata_id, collapse = ", "),
                                 if (nrow(still_open) == 0) "" else " - either the round under-delivered, or 05's 'Remaining eligible pool' (an unvalidated hex count) overstates what can actually be drawn: check the round's run log for strata the draw itself reported unresolved (validated pool exhausted). Either way the RECOVERABLE label is wrong until one of the two is fixed, and it is donor-facing - a stratum labelled recoverable stays off the 'justify to donors' list"),
                         nrow(still_open))
  }

  # ---- 2. no Non-IDP cluster in the round falls below the 4-primary floor
  # (it's excluded from the ceiling and contributes nothing) --------------
  nid <- merged %>% filter(is.na(pop_type) | pop_type == "non_idp", grepl("^non_idp_", cluster_id))
  per <- full %>% filter(cluster_id %in% nid$cluster_id, status == "primary") %>%
    group_by(cluster_id) %>%
    summarise(n_prim = n(), n_acc = sum(ward_accessible_status == "Accessible", na.rm = TRUE), .groups = "drop")
  per <- nid %>% select(cluster_id) %>% left_join(per, by = "cluster_id") %>%
    mutate(n_prim = coalesce(n_prim, 0L), n_acc = coalesce(n_acc, 0L))
  below <- per %>% filter(n_acc < NON_IDP_MIN_ACCESSIBLE_PRIMARY_HH_CHECK)
  n_straddle <- sum(below$n_prim >= NON_IDP_MIN_ACCESSIBLE_PRIMARY_HH_CHECK)
  log <- check_result(log, mod, "No Non-IDP cluster in the latest round lands below the 4-accessible-primary floor",
                       if (nrow(below) == 0) "PASS" else "FAIL",
                       sprintf("%d of %d Non-IDP clusters in round %s land below the floor and contribute nothing (%d ward straddle - enough households drawn but some in a non-Accessible ward; %d thin hex - too few buildings to draw from) - the draw should judge a candidate hex on its households' wards, not its centroid, and skip hexes that can't yield the floor",
                               nrow(below), nrow(per), round_label, n_straddle, nrow(below) - n_straddle),
                       nrow(below))
  n_partial <- sum(per$n_acc >= NON_IDP_MIN_ACCESSIBLE_PRIMARY_HH_CHECK & per$n_acc < 6)
  log <- check_result(log, mod, "Non-IDP clusters in the latest round delivering 4-5 accessible primaries instead of 6 (informational)",
                       "PASS", sprintf("%d of %d - counted, but each under-delivers against the 6 the sizing assumed", n_partial, nrow(per)), n_partial)
  log
}
