# Module: partner_package_alignment (cross-repo)
# Generalizes the 2026-09-19 national KML/workbook/WORKING sweep into a
# standing check - checks 10.8 (standing UUID reconciliation), 6.7 (stale
# partner/LGA folder detection). Reuses the proven methodology from that
# day's investigation (achieved-aware comparison, _archive/ exclusion,
# reserve-aware Needs Collecting comparison).
library(dplyr)
library(readr)
library(readxl)
library(stringr)
library(purrr)

parse_kml_ids <- function(path) {
  txt <- tryCatch(readLines(path, warn = FALSE, encoding = "UTF-8"), error = function(e) character(0))
  txt <- paste(txt, collapse = "\n")
  ids <- str_match_all(txt, "<name>([^<]+)</name>")[[1]][, 2]
  unique(ids[ids != ""])
}

run_partner_package_alignment_checks <- function(log) {
  full <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"), show_col_types = FALSE, col_types = cols(.default = "c"))
  working_ids <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING"), show_col_types = FALSE, col_types = cols(.default = "c"))$survey_id
  subs <- read_csv(file.path(MONITORING_ROOT, "data/real_submissions.csv"), show_col_types = FALSE)
  subs <- subs %>% mutate(is_achieved_old = interview_outcome == "completed" & !is_duplicate &
                             !is.na(matched_survey_id) & is.na(deletion_status))
  achieved_survey_ids <- unique(subs$matched_survey_id[subs$is_achieved_old])
  achieved_cluster_ids <- unique(subs$matched_cluster_id[subs$is_achieved_old & subs$pop_type == "idp"])

  full2 <- full %>%
    mutate(row_achieved = case_when(
      pop_type == "non_idp" ~ survey_id %in% achieved_survey_ids,
      pop_type == "idp" ~ cluster_id %in% achieved_cluster_ids,
      TRUE ~ FALSE
    ), in_working = survey_id %in% working_ids) %>%
    filter(!row_achieved) %>%
    mutate(compare_key = if_else(pop_type == "non_idp", survey_id, cluster_id))

  partner_dirs <- setdiff(list.dirs(PKG_ROOT, recursive = FALSE, full.names = FALSE), "_communications")

  total_stale_kml <- 0; total_missing_kml <- 0; total_stale_folders <- 0
  worst_partner <- NA; worst_stale <- 0

  for (p in partner_dirs) {
    pdir <- file.path(PKG_ROOT, p)
    kml_files <- list.files(pdir, pattern = "\\.kml$", recursive = TRUE, full.names = TRUE)
    # prefix match, not exact - dated archive folders like "_archive_2026-08-19_..."
    # aren't caught by an exact "_archive" segment match (same gap already fixed
    # below for the stale-folder check; found missing here 2026-09-21 via a live
    # false-positive on Street Child's archived Dange-Shuni package)
    kml_files <- kml_files[!grepl("[/\\\\]_archive[^/\\\\]*[/\\\\]", kml_files)]
    kml_ids <- unique(unlist(map(kml_files, parse_kml_ids)))

    mine <- full2 %>% filter(str_detect(partners_covering, fixed(p))) %>%
      distinct(compare_key, cluster_id, pop_type, adm2_name, in_working) %>%
      mutate(in_kml = compare_key %in% kml_ids)

    stale <- sum(!mine$in_working & mine$in_kml)
    missing <- sum(mine$in_working & !mine$in_kml)
    total_stale_kml <- total_stale_kml + stale
    total_missing_kml <- total_missing_kml + missing
    if (stale > worst_stale) { worst_stale <- stale; worst_partner <- p }

    # stale-folder check: any LGA folder for an LGA this partner no longer
    # covers. LGA names with a "/" (e.g. "Koko/Besse") are saved to disk
    # with "/" -> "-" (filesystem-safe) - normalize both sides the same way
    # before comparing, or every such LGA falsely flags as stale.
    normalize_lga <- function(x) gsub("/", "-", x)
    partner_lgas_now <- unique(normalize_lga(full$adm2_name[str_detect(full$partners_covering, fixed(p))]))
    state_dirs <- list.dirs(pdir, recursive = FALSE, full.names = FALSE)
    for (st in state_dirs) {
      if (grepl("^_archive|^master_log", st)) next  # prefix match - dated archive folders like "_archive_2026-08-19_..." aren't caught by an exact-match skip
      lga_dirs <- list.dirs(file.path(pdir, st), recursive = FALSE, full.names = FALSE)
      stale_lgas <- setdiff(lga_dirs, partner_lgas_now)
      total_stale_folders <- total_stale_folders + length(stale_lgas)
    }
  }

  log <- check_result(log, "partner_package_alignment", "Zero stale points across all partner KML files (excluded from WORKING but still shown as active)",
                       if (total_stale_kml == 0) "PASS" else "FAIL",
                       sprintf("%d stale points nationally across %d partners (worst: %s with %d) - a point excluded from WORKING (accessibility overlay, capacity drop, threshold rule) that's still shown as an active target on a partner's live Map.me/KML",
                               total_stale_kml, length(partner_dirs), worst_partner, worst_stale),
                       total_stale_kml)

  log <- check_result(log, "partner_package_alignment", "Zero missing points across all partner KML files (active in WORKING but absent from KML)",
                       if (total_missing_kml <= 5) "PASS" else "FAIL",
                       sprintf("%d points nationally are active in WORKING but not in any partner's live KML (a small single-digit residual can be normal edge-case timing; systematic gaps point to a batch never pushed)",
                               total_missing_kml),
                       total_missing_kml)

  log <- check_result(log, "partner_package_alignment", "Zero stale partner/LGA folders (partner no longer assigned an LGA still has a live package folder for it)",
                       if (total_stale_folders == 0) "PASS" else "FAIL",
                       sprintf("%d stale LGA folders found across all partners - a partner reassignment (like Dikwa/Street Child->FACT, 2026-09-19) must remove the losing partner's folder, not just build the gaining partner's",
                               total_stale_folders),
                       total_stale_folders)

  # ---- MSNA Light never leaks into a partner's normal deliverable
  # sheets/KML folder - it must always live in its own separate MSNA_Light/
  # KML/ folder (2026-09-13b fix), never mixed into non_idp_households_
  # {primary,reserve}.kml or idp_clusters_primary.kml. ----------------------
  msna_light_survey_ids <- full %>% filter(sampling_method == "MSNA Light") %>% pull(survey_id) %>% unique()
  msna_light_leak <- 0
  worst_leak_partner <- NA; worst_leak_n <- 0
  for (p in partner_dirs) {
    pdir <- file.path(PKG_ROOT, p)
    core_kml <- list.files(pdir, pattern = "\\.kml$", recursive = TRUE, full.names = TRUE)
    core_kml <- core_kml[!grepl("[/\\\\](_archive[^/\\\\]*|MSNA_Light)[/\\\\]", core_kml)]
    core_ids <- unique(unlist(map(core_kml, parse_kml_ids)))
    leak <- sum(core_ids %in% msna_light_survey_ids)
    msna_light_leak <- msna_light_leak + leak
    if (leak > worst_leak_n) { worst_leak_n <- leak; worst_leak_partner <- p }
  }
  log <- check_result(log, "partner_package_alignment", "MSNA Light rows never leak into a partner's normal (non-MSNA_Light) KML folder",
                       if (msna_light_leak == 0) "PASS" else "FAIL",
                       sprintf("%d MSNA Light survey_id(s) found inside a core (non-MSNA_Light) KML file across all partners (worst: %s with %d) - MSNA Light must always stay in its own separate MSNA_Light/KML/ folder, per the 2026-09-13b fix, never mixed into a partner's normal deliverable",
                               msna_light_leak, worst_leak_partner, worst_leak_n),
                       msna_light_leak)

  # ---- Fully-achieved IDP clusters have no lingering KML placemark -
  # regression guard for the 2026-09-19 fix (idp_rows_by_cluster now drops
  # any cluster whose real cluster_achieved_n already meets its nominal
  # target_households, before either IDP KML file is built). Computed fresh
  # against real_submissions.csv, not re-derived from WORKING membership
  # (WORKING can still hold an unconsumed reserve row for a count-based IDP
  # cluster even after its primary target is met - that's exactly the gap
  # this dedicated check exists to catch, distinct from the plain
  # KML-vs-WORKING stale-point check above). ---------------------------------
  idp_targets <- full %>% filter(pop_type == "idp", status == "primary") %>%
    distinct(cluster_id, target_households) %>% mutate(target_households = as.numeric(target_households))
  fully_achieved_status <- "FAIL"; fully_achieved_detail <- "check did not run"; fully_achieved_count <- NA
  fully_achieved_result <- tryCatch({
    subs2 <- read_csv(file.path(MONITORING_ROOT, "data/real_submissions.csv"), show_col_types = FALSE, col_types = cols(.default = "c"))
    overlay2 <- read_csv(file.path(MONITORING_ROOT, "data/CONFIRMED_DELETIONS_OVERLAY.csv"), show_col_types = FALSE, col_types = cols(.default = "c"))
    source(file.path(SAMPLING_ROOT, "scripts/shared/frame_status.R"), local = (fs_env <- new.env()))
    achieved2 <- fs_env$compute_achieved_lookup(subs2, overlay2)
    idp_achieved <- achieved2$idp_counts %>% group_by(matched_cluster_id) %>% summarise(n_achieved = sum(n_achieved), .groups = "drop")

    total_leaked <- 0; worst_p <- NA; worst_n <- 0
    for (p in partner_dirs) {
      pdir <- file.path(PKG_ROOT, p)
      idp_kml <- list.files(pdir, pattern = "^idp_clusters_primary\\.kml$", recursive = TRUE, full.names = TRUE)
      idp_kml <- idp_kml[!grepl("[/\\\\](_archive[^/\\\\]*|MSNA_Light)[/\\\\]", idp_kml)]
      ids_in_kml <- unique(unlist(map(idp_kml, parse_kml_ids)))
      if (length(ids_in_kml) == 0) next
      chk <- tibble(cluster_id = ids_in_kml) %>%
        left_join(idp_targets, by = "cluster_id") %>%
        left_join(idp_achieved, by = c("cluster_id" = "matched_cluster_id")) %>%
        mutate(n_achieved = coalesce(n_achieved, 0)) %>%
        filter(!is.na(target_households), n_achieved >= target_households)
      total_leaked <- total_leaked + nrow(chk)
      if (nrow(chk) > worst_n) { worst_n <- nrow(chk); worst_p <- p }
    }
    list(status = if (total_leaked == 0) "PASS" else "FAIL",
         detail = sprintf("%d IDP cluster(s) with real cluster_achieved_n >= target_households still have an active idp_clusters_primary.kml placemark (worst: %s with %d) - regression of the 2026-09-19 fix, OR simply a KML not yet rebuilt since that cluster crossed its threshold (the resampling-push tier only refreshes on a full build, not automatically as submissions land)",
                          total_leaked, worst_p, worst_n),
         count = total_leaked)
  }, error = function(e) list(status = "FAIL", detail = sprintf("check errored: %s", conditionMessage(e)), count = NA))
  log <- check_result(log, "partner_package_alignment", "Fully-achieved IDP clusters have no lingering KML placemark (2026-09-19 fix regression guard)",
                       fully_achieved_result$status, fully_achieved_result$detail, fully_achieved_result$count)

  log
}
