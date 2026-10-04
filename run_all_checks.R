# Master orchestrator for the MSNA N-WEC 2026 standing validity check suite.
# Usage (run from this folder, validity_checks/):
#   Rscript run_all_checks.R                          # everything
#   Rscript run_all_checks.R --module frame_integrity  # one module
#   Rscript run_all_checks.R --module frame_integrity --module accessibility_consistency
#   Rscript run_all_checks.R --gate                   # the 3 partner-package modules (the go-live gate for a staged
#                                                     # build: set MSNA_PKG_ROOT to the staging folder)
#   Rscript run_all_checks.R --out <file.csv>         # also write the result table to <file.csv>
# Exit status (2026-10-04, for the one-command launcher and the daily frame/partner update):
#   0 = no FAIL (WARNs allowed) | 1 = at least one FAIL | 2 = the suite itself could not run
# The workspace is found from env var MSNA_WORKSPACE, or as this folder's parent (paths_config.R).
# See README.md for the intended day-to-day usage pattern, CHECK_CATALOG.md
# for what each module actually checks and why.

GATE_MODULES <- c("partner_package_alignment", "oversampling_rollup_integrity", "three_way_reconciliation")

run_suite <- function(args) {
  if (!file.exists("check_helpers.R")) {
    stop("Run this script with its own folder as the working directory (cd into validity_checks/ first).")
  }
  source("paths_config.R")
  source("check_helpers.R")

  ALL_MODULES <- list(
    frame_integrity = list(file = "modules/frame_integrity.R", fn = "run_frame_integrity_checks", repo = "1_sampling"),
    accessibility_consistency = list(file = "modules/accessibility_consistency.R", fn = "run_accessibility_consistency_checks", repo = "1_sampling"),
    achieved_target_definitions = list(file = "modules/achieved_target_definitions.R", fn = "run_achieved_target_definitions_checks", repo = "1_sampling"),
    partner_coverage_alignment = list(file = "modules/partner_coverage_alignment.R", fn = "run_partner_coverage_alignment_checks", repo = "cross-repo"),
    partner_package_alignment = list(file = "modules/partner_package_alignment.R", fn = "run_partner_package_alignment_checks", repo = "cross-repo, SLOW (~2-3 min, parses ~700 KML files)"),
    cross_repo_propagation_freshness = list(file = "modules/cross_repo_propagation_freshness.R", fn = "run_cross_repo_propagation_freshness_checks", repo = "cross-repo"),
    dashboard_deletion_identity = list(file = "modules/dashboard_deletion_identity.R", fn = "run_dashboard_deletion_identity_checks", repo = "2_monitoring, SLOW (~1 min, sources the whole dashboard)"),
    duplicate_and_id_integrity = list(file = "modules/duplicate_and_id_integrity.R", fn = "run_duplicate_and_id_integrity_checks", repo = "1_sampling"),
    oversampling_rollup_integrity = list(file = "modules/oversampling_rollup_integrity.R", fn = "run_oversampling_rollup_integrity_checks", repo = "cross-repo (partner workbooks; dashboard twin lives in dashboard_deletion_identity)"),
    resample_round_landing = list(file = "modules/resample_round_landing.R", fn = "run_resample_round_landing_checks", repo = "1_sampling"),
    gis_layer_currency = list(file = "modules/gis_layer_currency.R", fn = "run_gis_layer_currency_checks", repo = "cross-repo (map layers vs frame)"),
    coverage_assignment_complete = list(file = "modules/coverage_assignment_complete.R", fn = "run_coverage_assignment_complete_checks", repo = "cross-repo (frame vs 2_monitoring assignment + decision record)"),
    three_way_reconciliation = list(file = "modules/three_way_reconciliation.R", fn = "run_three_way_reconciliation_checks", repo = "cross-repo, SLOW (~1 min, sources the whole dashboard): dashboard vs canonical vs partner workbooks, per stratum")
  )

  requested <- character(0); out_file <- NULL
  i <- 1
  while (i <= length(args)) {
    if (args[i] == "--module" && i < length(args)) { requested <- c(requested, args[i + 1]); i <- i + 2 }
    else if (args[i] == "--gate") { requested <- c(requested, GATE_MODULES); i <- i + 1 }
    else if (args[i] == "--out" && i < length(args)) { out_file <- args[i + 1]; i <- i + 2 }
    else i <- i + 1
  }
  modules_to_run <- if (length(requested) > 0) unique(requested) else names(ALL_MODULES)

  unknown <- setdiff(modules_to_run, names(ALL_MODULES))
  if (length(unknown) > 0) {
    stop("Unknown module(s): ", paste(unknown, collapse = ", "), "\nAvailable: ", paste(names(ALL_MODULES), collapse = ", "))
  }

  cat(sprintf("Workspace: %s\nPartner packages checked: %s\n", MSNA_WORKSPACE_DIR, PKG_ROOT))
  cat(sprintf("Running %d module(s): %s\n", length(modules_to_run), paste(modules_to_run, collapse = ", ")))
  log <- new_check_log()

  for (mod_name in modules_to_run) {
    mod <- ALL_MODULES[[mod_name]]
    cat(sprintf("\n>>> %s (%s)...\n", mod_name, mod$repo))
    t0 <- Sys.time()
    tryCatch({
      source(mod$file)
      log <- do.call(mod$fn, list(log))
    }, error = function(e) {
      log <<- check_result(log, mod_name, "MODULE CRASHED", "FAIL", sprintf("Error running this module: %s", conditionMessage(e)))
    })
    cat(sprintf("    done in %.1fs\n", as.numeric(Sys.time() - t0, units = "secs")))
  }

  print_check_log(log)

  # write a machine-readable copy alongside the human-readable console output
  res <- log_to_dataframe(log)
  if (!dir.exists("run_history")) dir.create("run_history")
  out_path <- file.path("run_history", paste0("run_", format(Sys.time(), "%Y-%m-%d_%H%M%S"), ".csv")) # nolint
  write.csv(res, out_path, row.names = FALSE)
  cat(sprintf("\nMachine-readable copy written to: %s\n", out_path))
  if (!is.null(out_file)) {
    dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)
    write.csv(res, out_file, row.names = FALSE)
    cat(sprintf("Result table also written to: %s\n", out_file))
  }
  sum(res$status == "FAIL")
}

n_fail <- tryCatch(run_suite(commandArgs(trailingOnly = TRUE)), error = function(e) {
  cat(sprintf("\nVALIDITY SUITE COULD NOT RUN: %s\n", conditionMessage(e)))
  NA_integer_
})
if (!interactive()) quit(save = "no", status = if (is.na(n_fail)) 2L else if (n_fail > 0) 1L else 0L)
