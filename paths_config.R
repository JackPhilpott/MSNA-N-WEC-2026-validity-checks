# Central path constants - sourced FIRST by run_all_checks.R and by every
# module (each module also sources this directly, so it works standalone
# too, not just via the orchestrator). Never duplicate these paths inline
# in a module - if a workspace path changes, this is the one place to fix it.

WORKSPACE_ROOT <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA"
SAMPLING_ROOT <- file.path(WORKSPACE_ROOT, "4. Data/MSNA N-WEC 2026/1_sampling")
MONITORING_ROOT <- file.path(WORKSPACE_ROOT, "4. Data/MSNA N-WEC 2026/2_monitoring")
# MSNA_PKG_ROOT (env var, optional) points the package checks at a STAGED build instead of the live
# partner folder, so a rebuild can be validated before it is copied live (2026-10-02, first used for
# Resampling's staged package rebuild the night before the Round 1 submission). Unset = live folder.
PKG_ROOT <- Sys.getenv("MSNA_PKG_ROOT", unset = file.path(WORKSPACE_ROOT, "3. External coordination/NGA MSNA 2026 Package"))

latest_frame_file <- function(prefix, suffix) {
  files <- list.files(file.path(SAMPLING_ROOT, "output/data/data_collection"),
                       pattern = paste0("^", prefix, "_v[0-9]+_", suffix, "\\.csv$"), full.names = TRUE)
  if (length(files) == 0) stop("No frame file found for ", prefix, "_", suffix)
  versions <- as.integer(gsub(".*_v([0-9]+)_.*", "\\1", basename(files)))
  files[which.max(versions)]
}
