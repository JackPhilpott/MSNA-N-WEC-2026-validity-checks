# Module: spare_cluster_integrity (cross-repo) - added 2026-10-04
# Spare (buffer) clusters for the data officer's week (Jack, 4 Oct: the team should "have spare cluster/samples in
# case of any issues" while no resampling is possible). Spares are drawn like any other cluster and merged into
# FULL/WORKING, so an interview at one matches its sampled point. They are listed in a register, and shown to
# partners ONLY on their own "Spare Clusters" sheet and spare_clusters.kml ("SPARE - " placemarks). While unused
# they never count in targets or remaining. A spare is "used" once it has >= 1 achieved interview (derived, no
# manual release); from then on it is an ordinary cluster everywhere and moves to the normal lists at the next
# build. Count-side exclusions are checked by the existing modules; this module checks the listing side.
# Inert until the register exists (no spares drawn yet): one PASS, or a FAIL if spare files exist without it.
# File, sheet and label names are the ones Resampling proposed on 4 Oct; change them here if they change there.
library(dplyr)
library(readr)
library(readxl)
library(stringr)

# Beside the frame (agreed 4 Oct): the daily update's archive/restore and the OneDrive conflict guard then cover the
# register together with the frame, so a blocked run restores both at once.
SPARE_REGISTER_REL <- "output/data/data_collection/buffer_cluster_register.csv"  # under 1_sampling/
SPARE_MIRROR_REL <- "input_data/sampling_frame/buffer_cluster_register.csv"     # under 2_monitoring/
SPARE_KML_FILE <- "spare_clusters.kml"
SPARE_SHEET <- "Spare Clusters"
SPARE_PREFIX <- "SPARE - "
SPARE_REQUIRED_COLS <- c("cluster_id", "strata_id", "pop_type", "partner", "buffer_rank", "drawn_batch", "drawn_at", "source_note")

.spare_strip <- function(x) ifelse(startsWith(x, SPARE_PREFIX), substring(x, nchar(SPARE_PREFIX) + 1), x)

.kml_placemark_ids <- function(path) {
  txt <- paste(tryCatch(readLines(path, warn = FALSE, encoding = "UTF-8"), error = function(e) character(0)), collapse = "\n")
  ids <- trimws(.spare_strip(str_match_all(txt, "<name>([^<]+)</name>")[[1]][, 2]))
  unique(ids[ids != ""])
}

# Pure core (no files), so every branch can be tested with made-up inputs.
#   reg: register rows (cluster_id, strata_id); full_map: FULL rows (survey_id, cluster_id, strata_id)
#   used_clusters: clusters with >= 1 achieved interview
#   *_kml_ids: placemark names, SPARE prefix already stripped (Non-IDP = survey ids, IDP = cluster ids)
#   *_clusters: values of a workbook sheet's "Cluster ID" column
spare_findings <- function(reg, full_map, used_clusters, spare_kml_ids, normal_kml_ids, spare_sheet_clusters, available_clusters) {
  to_cluster <- function(ids) unique(c(full_map$cluster_id[full_map$survey_id %in% ids], intersect(ids, full_map$cluster_id)))
  spare_kml_cl <- to_cluster(spare_kml_ids)
  normal_kml_cl <- to_cluster(normal_kml_ids)
  in_full <- reg$cluster_id %in% full_map$cluster_id
  full_stratum <- full_map$strata_id[match(reg$cluster_id, full_map$cluster_id)]
  unused <- unique(reg$cluster_id[in_full & !(reg$cluster_id %in% used_clusters)])
  used <- unique(reg$cluster_id[in_full & reg$cluster_id %in% used_clusters])
  list(
    duplicate_ids = unique(reg$cluster_id[duplicated(reg$cluster_id)]),
    not_in_full = reg$cluster_id[!in_full],
    wrong_stratum = reg$cluster_id[in_full & !is.na(full_stratum) & full_stratum != reg$strata_id],
    unused_missing_from_spare_sheet = setdiff(unused, spare_sheet_clusters),
    unused_missing_from_spare_kml = setdiff(unused, spare_kml_cl),
    unused_on_available_to_collect = intersect(unused, available_clusters),
    unused_in_normal_kml = intersect(unused, normal_kml_cl),
    unregistered_on_spare_sheet = setdiff(spare_sheet_clusters, reg$cluster_id),
    unregistered_in_spare_kml = setdiff(spare_kml_cl, reg$cluster_id),
    used_still_listed_as_spare = intersect(used, union(spare_sheet_clusters, spare_kml_cl)),
    n_unused = length(unused), n_used = length(used)
  )
}

run_spare_cluster_integrity_checks <- function(log) {
  mod <- "spare_cluster_integrity"
  partner_dirs <- setdiff(list.dirs(PKG_ROOT, recursive = FALSE, full.names = FALSE), "_communications")
  all_kml <- unlist(lapply(partner_dirs, function(p) list.files(file.path(PKG_ROOT, p), pattern = "\\.kml$", recursive = TRUE, full.names = TRUE)))
  all_kml <- all_kml[!grepl("[/\\\\]_archive[^/\\\\]*[/\\\\]", all_kml)]
  spare_kml <- all_kml[basename(all_kml) == SPARE_KML_FILE]
  wbs <- unlist(lapply(partner_dirs, function(p) list.files(file.path(PKG_ROOT, p), pattern = "sampling_points_summary\\.xlsx$", full.names = TRUE)))
  sheet_clusters <- function(sheet) {
    unique(unlist(lapply(wbs, function(wb) {
      if (!sheet %in% excel_sheets(wb)) return(character(0))
      d <- suppressWarnings(read_excel(wb, sheet = sheet, col_types = "text"))
      if ("Cluster ID" %in% names(d)) d[["Cluster ID"]][!is.na(d[["Cluster ID"]])] else character(0)
    })))
  }
  spare_sheet <- sheet_clusters(SPARE_SHEET)

  reg_path <- file.path(SAMPLING_ROOT, SPARE_REGISTER_REL)
  if (!file.exists(reg_path)) {
    orphan <- length(spare_kml) + length(spare_sheet)
    return(check_result(log, mod, "Spare clusters: none drawn yet (no register), and no spare files in partner packages",
                        if (orphan == 0) "PASS" else "FAIL",
                        if (orphan == 0) sprintf("no register at %s - this module is inert until spares are drawn", reg_path)
                        else sprintf("%d %s file(s) and %d cluster(s) on a '%s' sheet exist, but there is no register at %s - unregistered spares would count as ordinary clusters",
                                     length(spare_kml), SPARE_KML_FILE, length(spare_sheet), SPARE_SHEET, reg_path),
                        orphan))
  }

  reg <- read_csv(reg_path, show_col_types = FALSE, col_types = cols(.default = "c"))
  miss_cols <- setdiff(SPARE_REQUIRED_COLS, names(reg))
  log <- check_result(log, mod, "Spare register has its required columns",
                      if (length(miss_cols) == 0) "PASS" else "FAIL",
                      sprintf("%d spare(s) in %s; missing column(s): %s", nrow(reg), reg_path, if (length(miss_cols)) paste(miss_cols, collapse = ", ") else "none"),
                      length(miss_cols))
  if (!all(c("cluster_id", "strata_id") %in% names(reg))) return(log)

  mirror <- file.path(MONITORING_ROOT, SPARE_MIRROR_REL)
  same <- file.exists(mirror) && unname(tools::md5sum(mirror)) == unname(tools::md5sum(reg_path))
  log <- check_result(log, mod, "2_monitoring's copy of the spare register is identical to 1_sampling's",
                      if (same) "PASS" else "FAIL",
                      if (same) "identical" else sprintf("%s %s - the dashboard would count spares as ordinary clusters", mirror, if (file.exists(mirror)) "differs" else "is missing"),
                      as.integer(!same))

  full <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"), show_col_types = FALSE, col_types = cols(.default = "c"))
  full_map <- distinct(full, survey_id, cluster_id, strata_id)
  subs_c <- read_csv(file.path(MONITORING_ROOT, "data/real_submissions.csv"), show_col_types = FALSE, col_types = cols(.default = "c"))
  overlay_c <- read_csv(file.path(MONITORING_ROOT, "data/CONFIRMED_DELETIONS_OVERLAY.csv"), show_col_types = FALSE, col_types = cols(.default = "c"))
  source(file.path(SAMPLING_ROOT, "scripts/shared/frame_status.R"), local = (fs_env <- new.env()))
  ach <- fs_env$compute_achieved_lookup(subs_c, overlay_c)
  used_clusters <- unique(c(full_map$cluster_id[full_map$survey_id %in% ach$non_idp_survey_ids], ach$idp_counts$matched_cluster_id))

  normal_kml <- all_kml[!basename(all_kml) %in% c(SPARE_KML_FILE, "idp_clusters_tier2_backup.kml")]
  f <- spare_findings(reg, full_map, used_clusters,
                      unique(unlist(lapply(spare_kml, .kml_placemark_ids))),
                      unique(unlist(lapply(normal_kml, .kml_placemark_ids))),
                      spare_sheet, sheet_clusters("Available to Collect"))
  show <- function(x) if (length(x) == 0) "none" else paste(head(x, 12), collapse = ", ")

  bad_reg <- c(f$duplicate_ids, f$not_in_full, f$wrong_stratum)
  log <- check_result(log, mod, "Every registered spare is a FULL-frame cluster in the stated stratum, listed once",
                      if (length(bad_reg) == 0) "PASS" else "FAIL",
                      sprintf("%d registered (%d unused, %d used); duplicates: %s; not in FULL: %s; stratum differs from FULL: %s",
                              nrow(reg), f$n_unused, f$n_used, show(f$duplicate_ids), show(f$not_in_full), show(f$wrong_stratum)),
                      length(bad_reg))
  n_missing <- length(union(f$unused_missing_from_spare_sheet, f$unused_missing_from_spare_kml))
  log <- check_result(log, mod, sprintf("Every unused spare is on its partner's '%s' sheet and in a %s", SPARE_SHEET, SPARE_KML_FILE),
                      if (n_missing == 0) "PASS" else "FAIL",
                      sprintf("not on a spare sheet: %s; not in a spare KML: %s - a spare a partner cannot see is no spare at all",
                              show(f$unused_missing_from_spare_sheet), show(f$unused_missing_from_spare_kml)),
                      n_missing)
  n_leak <- length(union(f$unused_on_available_to_collect, f$unused_in_normal_kml))
  log <- check_result(log, mod, "No unused spare appears on 'Available to Collect' or in a primary/reserve KML",
                      if (n_leak == 0) "PASS" else "FAIL",
                      sprintf("on Available to Collect: %s; in a normal KML: %s - partners would treat it as an ordinary cluster to collect",
                              show(f$unused_on_available_to_collect), show(f$unused_in_normal_kml)),
                      n_leak)
  n_unreg <- length(union(f$unregistered_on_spare_sheet, f$unregistered_in_spare_kml))
  log <- check_result(log, mod, "Every cluster listed as a spare is in the register",
                      if (n_unreg == 0) "PASS" else "FAIL",
                      sprintf("on a spare sheet but not registered: %s; in a spare KML but not registered: %s",
                              show(f$unregistered_on_spare_sheet), show(f$unregistered_in_spare_kml)),
                      n_unreg)
  log <- check_result(log, mod, "Used spares (>= 1 achieved interview) have moved to the normal lists (next build)",
                      if (length(f$used_still_listed_as_spare) == 0) "PASS" else "WARN",
                      sprintf("%d used spare(s) still listed as spares: %s - expected only between a data refresh and the next package build",
                              length(f$used_still_listed_as_spare), show(f$used_still_listed_as_spare)),
                      length(f$used_still_listed_as_spare))
  log
}
