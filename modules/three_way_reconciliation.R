# Module: three_way_reconciliation (cross-repo) - added 2026-10-02 (Coordinator, the night before
# the first Round 1 submission). Jack: "ensure the numbers correspond between dashboard, main frames
# and partner folders". Every other module checks one source's INTERNAL consistency (the dashboard's
# identities, the partner workbooks' headline arithmetic, frame-vs-mirror bytes). None compared the
# SAME stratum's numbers ACROSS sources. This does, stratum by stratum:
#   (1) canonical recompute: data/real_submissions.csv + data/CONFIRMED_DELETIONS_OVERLAY.csv
#       (05's is_achieved: completed & matched & not a confirmed/contested deletion)
#   (2) the dashboard's own compute_progress_by_stratum(subs, "original") from dashboard_app/global.R
#   (3) every partner workbook's Strata Summary sheet (Target (design) / Achieved / Still Needed)
# plus the Round 1 membership guard on real_submissions and the deployed-bundle copy of it.
library(dplyr)
library(readxl)

run_three_way_reconciliation_checks <- function(log) {
  mod <- "three_way_reconciliation"
  data_dir <- file.path(MONITORING_ROOT, "data")

  # ---- (1) canonical recompute ----
  subs_c <- read.csv(file.path(data_dir, "real_submissions.csv"), stringsAsFactors = FALSE, na.strings = "", colClasses = "character")
  ov <- read.csv(file.path(data_dir, "CONFIRMED_DELETIONS_OVERLAY.csv"), stringsAsFactors = FALSE, colClasses = "character")
  del_uuids <- ov$uuid[ov$status %in% c("confirmed", "contested")]
  canon <- subs_c %>%
    filter(interview_outcome %in% "completed", !is.na(matched_survey_id), matched_survey_id != "NA",
           !(submission_uuid %in% del_uuids)) %>%
    count(strata_id = matched_strata_id, name = "achieved_canon")

  # ---- (2) dashboard ----
  old_wd <- getwd(); on.exit(setwd(old_wd), add = TRUE)
  setwd(file.path(MONITORING_ROOT, "dashboard_app"))
  env <- new.env()
  suppressMessages(suppressWarnings(source("global.R", local = env)))
  setwd(old_wd)
  pbs <- env$compute_progress_by_stratum(env$submissions_raw, "original")
  need <- c("strata_id", "achieved_n", "target_active", "remaining_n")
  if (!all(need %in% names(pbs))) {
    return(check_result(log, mod, "Dashboard progress table exposes strata_id/achieved_n/target_active/remaining_n", "FAIL",
                        sprintf("missing: %s", paste(setdiff(need, names(pbs)), collapse = ", ")), 1))
  }
  dash <- pbs %>% transmute(strata_id, achieved_dash = achieved_n, target_dash = target_active, remaining_dash = remaining_n)

  # every interview the dashboard counts as Achieved nationally must land in some stratum's row -
  # an achieved interview outside every stratum is invisible to representativity and partner totals
  subs_d <- env$submissions_raw
  ach_flag <- env$is_achieved(subs_d)
  nat <- sum(ach_flag, na.rm = TRUE)
  orphan <- subs_d[which(ach_flag), , drop = FALSE]
  orphan <- orphan[!(orphan$matched_strata_id %in% pbs$strata_id), , drop = FALSE]
  log <- check_result(log, mod, "Every interview the dashboard counts as Achieved nationally sits in a stratum row of compute_progress_by_stratum()",
                      if (nrow(orphan) == 0) "PASS" else "FAIL",
                      sprintf("national is_achieved %d vs per-stratum sum %d; %d achieved interview(s) outside every stratum row%s", nat, sum(pbs$achieved_n), nrow(orphan),
                              if (nrow(orphan) == 0) "" else paste0(" - by matched_strata_id: ", paste(sprintf("%s x%d", names(table(orphan$matched_strata_id, useNA = "ifany")),
                                                                                                         as.integer(table(orphan$matched_strata_id, useNA = "ifany"))), collapse = ", "),
                                                                    "; by org: ", paste(sprintf("%s x%d", names(table(orphan$org_id)), as.integer(table(orphan$org_id))), collapse = ", "))),
                      nrow(orphan))

  # bundled copy the deployed app reads must equal the canonical file
  bundle <- file.path(MONITORING_ROOT, "dashboard_app", "data", "real_submissions.csv")
  same_bundle <- file.exists(bundle) && unname(tools::md5sum(bundle)) == unname(tools::md5sum(file.path(data_dir, "real_submissions.csv")))
  log <- check_result(log, mod, "dashboard_app/data/real_submissions.csv (what the deployed app reads) is byte-identical to data/real_submissions.csv",
                      if (same_bundle) "PASS" else "FAIL",
                      if (same_bundle) "identical" else "DIFFERENT - the deployed app is reading other submissions than every other consumer", as.integer(!same_bundle))

  # ---- Round 1 membership guard ----
  # 2026-10-04 (Jack: the dashboard shows all data collected; Round 1 is an internal mechanism): submissions
  # after Round 1 are expected from now on and are reported, not failed. What must hold is that no Round 1
  # submission ever disappears, because the frozen Round 1 outputs (weights, representativity) are built on them.
  r1_path <- file.path(data_dir, "ROUND1_MEMBERSHIP.csv")
  if (file.exists(r1_path)) {
    r1 <- read.csv(r1_path, stringsAsFactors = FALSE, colClasses = "character")[[1]]
    extra <- setdiff(subs_c$submission_uuid, r1); missing <- setdiff(r1, subs_c$submission_uuid)
    log <- check_result(log, mod, "Every Round 1 submission is still in real_submissions.csv (later submissions are expected)",
                        if (length(missing) == 0) "PASS" else "FAIL",
                        sprintf("%d rows: %d of %d Round 1 uuids present, %d missing; %d later (post-Round 1) submission(s)",
                                nrow(subs_c), length(r1) - length(missing), length(r1), length(missing), length(extra)),
                        length(missing))
  }

  # ---- (1) vs (2): achieved per stratum ----
  a <- full_join(canon, dash, by = "strata_id") %>%
    mutate(achieved_canon = coalesce(achieved_canon, 0L), achieved_dash = coalesce(as.integer(achieved_dash), 0L))
  bad_a <- a %>% filter(achieved_canon != achieved_dash)
  log <- check_result(log, mod, "Achieved per stratum: dashboard == canonical recompute (submissions + CONFIRMED overlay)",
                      if (nrow(bad_a) == 0) "PASS" else "FAIL",
                      sprintf("%d strata compared; national canonical %d vs dashboard %d; %d strata differ%s", nrow(a), sum(a$achieved_canon), sum(a$achieved_dash), nrow(bad_a),
                              if (nrow(bad_a) == 0) "" else paste0(": ", paste(head(sprintf("%s %d vs %d", bad_a$strata_id, bad_a$achieved_canon, bad_a$achieved_dash), 15), collapse = "; "))),
                      nrow(bad_a))

  # ---- (3) partner workbooks vs dashboard ----
  strata <- read.csv(latest_frame_file("NGA_MSNA_2026_strata_level_sampling_frame", "FULL"), stringsAsFactors = FALSE, colClasses = "character") %>%
    transmute(strata_id, State = adm1_name, LGA = adm2_name, pop = ifelse(pop_type == "idp", "IDP", "Non-IDP"))
  partner_dirs <- setdiff(list.dirs(PKG_ROOT, recursive = FALSE, full.names = FALSE), "_communications")
  rows <- list(); stale <- character(0); unmapped <- character(0)
  newest_subs <- file.mtime(file.path(data_dir, "real_submissions.csv"))
  # 2026-10-04: a workbook's own save time (docProps/core.xml), not its file date - OneDrive can leave a rewritten
  # file's old date in place (seen 2 Oct). Still only a WARN: the per-row content checks below are the real test.
  saved_at <- function(x) {
    core <- tryCatch(paste(readLines(unz(x, "docProps/core.xml"), warn = FALSE), collapse = ""), error = function(e) "")
    v <- regmatches(core, regexpr("(?<=<dcterms:modified)[^>]*>[^<]+", core, perl = TRUE))
    t <- if (length(v)) as.POSIXct(sub("^[^>]*>", "", v), format = "%Y-%m-%dT%H:%M:%S", tz = "") else NA
    if (is.na(t)) file.mtime(x) else t
  }
  for (p in partner_dirs) {
    wb <- list.files(file.path(PKG_ROOT, p), pattern = "sampling_points_summary\\.xlsx$", full.names = TRUE)
    if (length(wb) == 0) next
    wb_saved <- saved_at(wb[1])
    if (wb_saved < newest_subs - 60) stale <- c(stale, sprintf("%s (saved %s)", p, format(wb_saved, "%d %b %H:%M")))
    ss <- tryCatch(read_excel(wb[1], sheet = "Strata Summary"), error = function(e) NULL)
    if (is.null(ss)) next
    ss <- ss %>% transmute(partner = p, State = as.character(State), LGA = as.character(LGA), pop = as.character(`Population Type`),
                           target_wb = suppressWarnings(as.numeric(`Target (design)`)), achieved_wb = suppressWarnings(as.numeric(Achieved)),
                           remaining_wb = suppressWarnings(as.numeric(`Still Needed`)))
    m <- left_join(ss, strata, by = c("State", "LGA", "pop"))
    unmapped <- c(unmapped, sprintf("%s: %s %s %s", p, m$State, m$LGA, m$pop)[is.na(m$strata_id)])
    rows[[p]] <- m
  }
  wbt <- bind_rows(rows)
  log <- check_result(log, mod, "Every partner workbook was saved after the current real_submissions.csv (internal save time; informational)",
                      if (length(stale) == 0) "PASS" else "WARN",
                      sprintf("%d workbook(s) saved before the submissions file was last written: %s%s", length(stale), if (length(stale) == 0) "none" else paste(stale, collapse = ", "),
                              if (length(stale) == 0) "" else " - fine if every per-row check below passes (same figures); otherwise refresh the workbooks"),
                      length(stale))
  log <- check_result(log, mod, "Every partner Strata Summary row maps to a frame stratum (State/LGA/pop type)",
                      if (length(unmapped) == 0) "PASS" else "FAIL",
                      sprintf("%d unmapped: %s", length(unmapped), if (length(unmapped) == 0) "none" else paste(head(unmapped, 15), collapse = "; ")), length(unmapped))
  cmp <- wbt %>% filter(!is.na(strata_id)) %>% left_join(dash, by = "strata_id")
  for (f in list(c("achieved_wb", "achieved_dash", "Achieved"), c("target_wb", "target_dash", "Target (design) vs dashboard original target"),
                 c("remaining_wb", "remaining_dash", "Still Needed vs dashboard remaining"))) {
    bad <- cmp %>% filter(is.na(.data[[f[2]]]) | abs(coalesce(.data[[f[1]]], -1) - .data[[f[2]]]) > 0.5)
    log <- check_result(log, mod, sprintf("Partner workbooks == dashboard, every stratum row: %s", f[3]),
                        if (nrow(bad) == 0) "PASS" else "FAIL",
                        sprintf("%d rows across %d workbooks; %d differ%s", nrow(cmp), length(unique(cmp$partner)), nrow(bad),
                                if (nrow(bad) == 0) "" else paste0(": ", paste(head(sprintf("%s %s %s %s wb %s vs dash %s", bad$partner, bad$LGA, bad$pop, f[3],
                                                                                             bad[[f[1]]], bad[[f[2]]]), 12), collapse = "; "))),
                        nrow(bad))
  }
  dup <- cmp %>% count(strata_id) %>% filter(n > 1)
  log <- check_result(log, mod, "Each stratum appears in exactly one partner workbook (informational)", "PASS",
                      sprintf("%d strata appear in more than one workbook: %s", nrow(dup), if (nrow(dup) == 0) "none" else paste(dup$strata_id, collapse = ", ")), nrow(dup))
  log
}
