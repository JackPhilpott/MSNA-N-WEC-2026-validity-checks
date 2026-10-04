# Central path constants - sourced FIRST by run_all_checks.R and by every
# module (each module also sources this directly, so it works standalone
# too, not just via the orchestrator). Never duplicate these paths inline
# in a module - if a workspace path changes, this is the one place to fix it.
#
# 2026-10-04: portable, so the suite runs on any machine or Windows account (the data officer's laptop for the
# week of 5 Oct). The workspace is the "MSNA N-WEC 2026" folder that holds 1_sampling/ and 2_monitoring/:
#   1. env var MSNA_WORKSPACE, if it points at such a folder (same convention as 1_sampling and 2_monitoring);
#   2. otherwise this folder's parent, or the working directory itself.
# WORKSPACE_ROOT keeps its old meaning: the shared "IMPACT NGA - 02. MSNA" folder two levels above.

.msna_find_workspace <- function() {
  is_ws <- function(p) nzchar(p) && dir.exists(file.path(p, "1_sampling")) && dir.exists(file.path(p, "2_monitoring"))
  cands <- c(Sys.getenv("MSNA_WORKSPACE", unset = ""), "..", ".")
  for (p in cands) if (is_ws(p)) return(normalizePath(p, winslash = "/"))
  stop("validity_checks: cannot find the MSNA workspace. Run from validity_checks/, or set the environment ",
       "variable MSNA_WORKSPACE to the 'MSNA N-WEC 2026' folder (the one holding 1_sampling and 2_monitoring).")
}
MSNA_WORKSPACE_DIR <- .msna_find_workspace()
WORKSPACE_ROOT <- dirname(dirname(MSNA_WORKSPACE_DIR))
SAMPLING_ROOT <- file.path(MSNA_WORKSPACE_DIR, "1_sampling")
MONITORING_ROOT <- file.path(MSNA_WORKSPACE_DIR, "2_monitoring")
# MSNA_PKG_ROOT (env var, optional) points the package checks at a STAGED build instead of the live
# partner folder, so a rebuild can be validated before it is copied live (2026-10-02, first used for
# Resampling's staged package rebuild the night before the Round 1 submission). Unset = live folder.
PKG_ROOT <- Sys.getenv("MSNA_PKG_ROOT", unset = file.path(WORKSPACE_ROOT, "3. External coordination/NGA MSNA 2026 Package"))

# The dashboard's deploy allowlist (2026-10-02): dashboard_app/ holds only the files the deployed app reads, rebuilt
# from input_data/ and data/ at every deploy. Checks of dashboard_app/ copies use this list (cross_repo module).
dashboard_allowlist <- function() {
  p <- file.path(MONITORING_ROOT, "scripts/shared/dashboard_bundle_allowlist.txt")
  if (!file.exists(p)) return(character(0))
  x <- trimws(readLines(p, warn = FALSE))
  x[nzchar(x) & !startsWith(x, "#")]
}
is_bundled <- function(rel_path) any(vapply(dashboard_allowlist(), function(rx) grepl(rx, rel_path), logical(1)))

latest_frame_file <- function(prefix, suffix) {
  files <- list.files(file.path(SAMPLING_ROOT, "output/data/data_collection"),
                       pattern = paste0("^", prefix, "_v[0-9]+_", suffix, "\\.csv$"), full.names = TRUE)
  if (length(files) == 0) stop("No frame file found for ", prefix, "_", suffix)
  versions <- as.integer(gsub(".*_v([0-9]+)_.*", "\\1", basename(files)))
  files[which.max(versions)]
}
