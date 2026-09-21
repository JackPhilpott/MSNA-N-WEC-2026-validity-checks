# Shared result-reporting convention for every module in this suite.
# Sourced by run_all_checks.R and by each module directly (so a module can
# also be run standalone). Deliberately tiny - this is a reporting
# convention, not a framework.

new_check_log <- function() {
  list(results = list())
}

# Checks temporarily silenced by name - code stays in place, just not run/
# reported, for a check Jack wants quiet without deleting the underlying
# logic. Add/remove entries here rather than commenting out code in a
# module. Each entry should say WHY and WHEN, so a silenced check doesn't
# just quietly rot forever.
SILENCED_CHECKS <- c(
  "Strata with achieved_sample > target_sample stays within the calibrated ceiling"
  # silenced 2026-09-19/20 per Jack - not deleted, just not surfaced for
  # now while other higher-priority items are worked through. Re-enable by
  # removing this line once revisited.
)

# status: "PASS" | "FAIL" | "WARN" (WARN = a known, accepted residual -
# e.g. "3 unresolved, all individually explained" - never used to mean
# "probably fine, didn't check closely")
check_result <- function(log, module, name, status, detail, count = NA) {
  if (name %in% SILENCED_CHECKS) {
    cat(sprintf("    [silenced, not reported] %s\n", name))
    return(log)
  }
  log$results[[length(log$results) + 1]] <- list(
    module = module, name = name, status = status, detail = detail, count = count
  )
  log
}

print_check_log <- function(log, module_filter = NULL) {
  r <- log$results
  if (!is.null(module_filter)) r <- Filter(function(x) x$module == module_filter, r)
  if (length(r) == 0) { cat("No checks run.\n"); return(invisible(NULL)) }
  n_pass <- sum(sapply(r, function(x) x$status == "PASS"))
  n_fail <- sum(sapply(r, function(x) x$status == "FAIL"))
  n_warn <- sum(sapply(r, function(x) x$status == "WARN"))
  cat(sprintf("\n%s\n", strrep("=", 78)))
  cat(sprintf("SUMMARY: %d PASS / %d WARN / %d FAIL  (of %d checks)\n", n_pass, n_warn, n_fail, length(r)))
  cat(sprintf("%s\n\n", strrep("=", 78)))
  cur_module <- NULL
  for (x in r) {
    if (!identical(x$module, cur_module)) {
      cat(sprintf("\n--- %s ---\n", x$module))
      cur_module <- x$module
    }
    mark <- switch(x$status, PASS = "[PASS]", FAIL = "[FAIL]", WARN = "[WARN]", "[????]")
    cat(sprintf("%s %s\n", mark, x$name))
    cat(sprintf("        %s\n", x$detail))
  }
  cat(sprintf("\n%s\n", strrep("=", 78)))
  if (n_fail > 0) {
    cat("RESULT: FAIL - see [FAIL] items above.\n")
  } else if (n_warn > 0) {
    cat("RESULT: PASS WITH WARNINGS - see [WARN] items above, all should be individually explained, not just accepted blindly.\n")
  } else {
    cat("RESULT: ALL CLEAR.\n")
  }
  cat(sprintf("%s\n", strrep("=", 78)))
  invisible(log)
}

log_to_dataframe <- function(log) {
  do.call(rbind, lapply(log$results, function(x) {
    data.frame(module = x$module, name = x$name, status = x$status,
               detail = x$detail, count = ifelse(is.na(x$count), NA, x$count),
               stringsAsFactors = FALSE)
  }))
}
