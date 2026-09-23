# Module: cross_repo_propagation_freshness (cross-repo)
# Checks 7.1/7.2: every downstream mirror of 1_sampling's frame must not
# be stale relative to the source - found live 2026-09-19, both
# 2_monitoring mirrors were 36+ hours stale relative to 1_sampling's
# refreshed WORKING. Never trust a version-stamp file alone (assert_fresh
# principle) - compare real mtime/size directly.
library(readr)

run_cross_repo_propagation_freshness_checks <- function(log) {
  source_full <- latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL")
  source_working <- latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "WORKING")

  mirrors <- list(
    list(label = "dashboard_app mirror (WORKING)", path = file.path(MONITORING_ROOT, "dashboard_app/input_data/sampling_frame", basename(source_working))),
    list(label = "input_data mirror (WORKING)", path = file.path(MONITORING_ROOT, "input_data/sampling_frame", basename(source_working))),
    list(label = "dashboard_app mirror (FULL)", path = file.path(MONITORING_ROOT, "dashboard_app/input_data/sampling_frame", basename(source_full))),
    list(label = "input_data mirror (FULL)", path = file.path(MONITORING_ROOT, "input_data/sampling_frame", basename(source_full)))
  )
  source_paths <- list(source_working, source_working, source_full, source_full)

  for (i in seq_along(mirrors)) {
    m <- mirrors[[i]]
    src <- source_paths[[i]]
    if (!file.exists(m$path)) {
      log <- check_result(log, "cross_repo_propagation_freshness", paste("Mirror exists:", m$label), "FAIL", sprintf("Expected mirror file not found: %s", m$path))
      next
    }
    src_info <- file.info(src); mirror_info <- file.info(m$path)
    # FIX 2026-09-21: verdict is CONTENT-based (md5), not mtime-based. The
    # old rule ("mirror mtime older than source" => FAIL) fired on the
    # evening WORKING refresh for both FULL mirrors even though FULL was
    # rewritten with byte-identical content - a false positive that the
    # check's own PASS wording ("byte-identical, current") already promised
    # it wouldn't produce. Identical bytes = current, whatever the mtimes;
    # differing bytes = stale, whatever the mtimes. mtime lag is still
    # reported in the detail as information.
    src_md5 <- unname(tools::md5sum(src)); mirror_md5 <- unname(tools::md5sum(m$path))
    same_content <- identical(src_md5, mirror_md5)
    older <- mirror_info$mtime < src_info$mtime
    status <- if (same_content) "PASS" else "FAIL"
    log <- check_result(log, "cross_repo_propagation_freshness", paste("Freshness:", m$label),
                         status,
                         sprintf("source mtime=%s (%d bytes, md5 %s) vs mirror mtime=%s (%d bytes, md5 %s). %s",
                                 format(src_info$mtime), src_info$size, substr(src_md5, 1, 10),
                                 format(mirror_info$mtime), mirror_info$size, substr(mirror_md5, 1, 10),
                                 if (!same_content) "MIRROR CONTENT DIFFERS from source - propagate now (2026-09-19 finding: dashboard mirrors sat 36+ hours behind after a fix)"
                                 else if (older) "byte-identical, current (mirror mtime is older only because the source was rewritten with unchanged content)"
                                 else "byte-identical, current"))
  }

  # _frame_version.txt consistency (not trusted alone, but checked it's at
  # least present and recently touched in both locations)
  v1 <- file.path(dirname(source_full), "_frame_version.txt")
  v2 <- file.path(MONITORING_ROOT, "input_data/sampling_frame/_frame_version.txt")
  if (file.exists(v1) && file.exists(v2)) {
    same <- identical(readLines(v1, warn = FALSE), readLines(v2, warn = FALSE))
    log <- check_result(log, "cross_repo_propagation_freshness", "_frame_version.txt identical between source and 2_monitoring mirror",
                         if (same) "PASS" else "FAIL",
                         sprintf("Source: %s | Mirror: %s", v1, v2))
  } else {
    log <- check_result(log, "cross_repo_propagation_freshness", "_frame_version.txt present in both locations", "WARN",
                         sprintf("Missing at: %s", paste(c(v1, v2)[!c(file.exists(v1), file.exists(v2))], collapse = ", ")))
  }

  # ---- real_submissions.csv: only the canonical 2_monitoring/data/ path
  # should ever be read - not the bundled dashboard_app/data/ mirror, which
  # only refreshes as a side effect of a full dashboard deploy (found stale
  # by coincidence, not by design, in both refresh_working_frame_daily.R
  # and build_partner_dc_packages.py, 2026-09-08). Structural scan for the
  # bad path pattern across live (non-archived, non-dated-one-off) 1_sampling
  # scripts - dated one-off scripts are deliberately left as-written per
  # this project's own convention and don't count as a live regression. -----
  r_py_files2 <- list.files(SAMPLING_ROOT, pattern = "\\.(R|py)$", recursive = TRUE, full.names = TRUE)
  r_py_files2 <- r_py_files2[!grepl("[/\\\\](_archive|_archive_one_off)[/\\\\]", r_py_files2)]
  r_py_files2 <- r_py_files2[!grepl("_[0-9]{4}-[0-9]{2}-[0-9]{2}(_[a-zA-Z0-9]+)?\\.(R|py)$", basename(r_py_files2))]
  bad_path_hits <- character(0)
  for (f in r_py_files2) {
    txt <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    if (any(grepl("dashboard_app[/\\\\]data[/\\\\]real_submissions", txt))) bad_path_hits <- c(bad_path_hits, basename(f))
  }
  log <- check_result(log, "cross_repo_propagation_freshness", "real_submissions.csv: canonical path used, not the bundled dashboard_app mirror, in every live consumer script",
                       if (length(bad_path_hits) == 0) "PASS" else "FAIL",
                       sprintf("%d live (non-archived, non-dated-one-off) 1_sampling script(s) reference the bundled dashboard_app/data/real_submissions.csv mirror instead of the canonical 2_monitoring/data/ path: %s - that mirror only refreshes as a side effect of a full dashboard deploy and can silently drift (found and fixed twice already, 2026-09-08)",
                               length(bad_path_hits), paste(bad_path_hits, collapse = ", ")),
                       length(bad_path_hits))

  # ---- Known duplicate-input directories checked for currency:
  # 2_monitoring's own accessibility mirror pair (dashboard_app/input_data/
  # accessibility/ vs input_data/accessibility/) - found stale once
  # (2026-08-27, harmless by luck) and never given a standing check. -------
  acc_dir_a <- file.path(MONITORING_ROOT, "input_data/accessibility")
  acc_dir_b <- file.path(MONITORING_ROOT, "dashboard_app/input_data/accessibility")
  acc_status <- "FAIL"; acc_detail <- "one or both accessibility directories not found"; acc_count <- NA
  if (dir.exists(acc_dir_a) && dir.exists(acc_dir_b)) {
    files_a <- list.files(acc_dir_a, recursive = FALSE)
    files_a <- files_a[!grepl("^_archive", files_a)]
    mismatches <- character(0)
    for (fn in files_a) {
      pa <- file.path(acc_dir_a, fn); pb <- file.path(acc_dir_b, fn)
      if (!file.exists(pb)) { mismatches <- c(mismatches, sprintf("%s (missing in dashboard_app mirror)", fn)); next }
      if (file.info(pa)$size != file.info(pb)$size) mismatches <- c(mismatches, sprintf("%s (size differs)", fn))
    }
    acc_status <- if (length(mismatches) == 0) "PASS" else "FAIL"
    acc_detail <- sprintf("%d of %d files differ (by size) between input_data/accessibility/ and dashboard_app/input_data/accessibility/: %s",
                           length(mismatches), length(files_a), paste(mismatches, collapse = ", "))
    acc_count <- length(mismatches)
  }
  log <- check_result(log, "cross_repo_propagation_freshness", "2_monitoring's duplicate accessibility-mirror directories are byte-size-identical (input_data/accessibility/ vs dashboard_app/input_data/accessibility/)",
                       acc_status, acc_detail, acc_count)

  # ---- Deletion-basis freshness (2026-09-22, Coordinator's cross-format
  # sweep): real_submissions.csv's deletion_status is a COPY of
  # FLAGGED_DELETIONS_OVERLAY.csv's status, joined in by
  # prep_real_submissions.R. deploy_dashboard.R runs prep FIRST, then
  # independent_deletion_checks.R registers + auto-confirms new tracker
  # issues, then rebuilds the overlays - so each run's new confirmations and
  # flags reach the overlays (read directly by the partner workbooks and
  # resampling) but not the copy the dashboard's is_achieved() reads, until
  # the NEXT run's prep. Found 2026-09-22: 110 completed interviews
  # confirmed as deletions on 2026-09-21 (99 duration_under_20, 11
  # duplicate_point) still counted as Achieved on the dashboard only, across
  # 25 strata. Compares the copy against its source uuid by uuid, with the
  # same first-row-per-uuid rule prep uses (distinct(uuid, .keep_all=TRUE)). -------
  rs_path <- file.path(MONITORING_ROOT, "data/real_submissions.csv")
  fl_path <- file.path(MONITORING_ROOT, "data/FLAGGED_DELETIONS_OVERLAY.csv")
  del_status <- "FAIL"; del_detail <- "real_submissions.csv or FLAGGED_DELETIONS_OVERLAY.csv not found"; del_count <- NA
  if (file.exists(rs_path) && file.exists(fl_path)) {
    rs <- read.csv(rs_path, stringsAsFactors = FALSE, na.strings = c("", "NA"))[, c("submission_uuid", "interview_outcome", "deletion_status")]
    fl <- read.csv(fl_path, stringsAsFactors = FALSE, na.strings = c("", "NA"))
    fl <- fl[!duplicated(fl$uuid), c("uuid", "status")]
    src <- fl$status[match(rs$submission_uuid, fl$uuid)]
    copy <- rs$deletion_status
    differs <- xor(is.na(copy), is.na(src)) | (!is.na(copy) & !is.na(src) & copy != src)
    settled <- c("confirmed", "contested")
    # the subset that moves the dashboard's Achieved: a completed interview
    # the source now calls settled but the copy doesn't (or vice versa)
    moves_achieved <- differs & rs$interview_outcome == "completed" &
      ((!is.na(src) & src %in% settled) != (!is.na(copy) & copy %in% settled))
    del_count <- sum(differs)
    del_status <- if (del_count == 0) "PASS" else "FAIL"
    del_detail <- sprintf(
      "%d of %d real_submissions.csv row(s) carry a deletion_status that differs from FLAGGED_DELETIONS_OVERLAY.csv (overlay mtime %s, real_submissions mtime %s); %d of them are completed interviews whose settled/not-settled state differs, i.e. counted as Achieved on the dashboard but excluded in the partner workbooks/resampling, or the reverse. Nonzero = the copy is a pipeline run behind the tracker (deploy_dashboard.R builds the overlays AFTER prep_real_submissions.R) - rerun prep, or fix the order",
      del_count, nrow(rs), format(file.info(fl_path)$mtime, "%Y-%m-%d %H:%M:%S"), format(file.info(rs_path)$mtime, "%Y-%m-%d %H:%M:%S"), sum(moves_achieved))
  }
  log <- check_result(log, "cross_repo_propagation_freshness", "real_submissions.csv deletion_status matches the current FLAGGED_DELETIONS_OVERLAY.csv, uuid by uuid (dashboard deletion basis not a run behind the tracker)",
                       del_status, del_detail, del_count)

  log
}
