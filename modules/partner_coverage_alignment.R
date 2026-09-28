# Module: partner_coverage_alignment (cross-repo)
# Generalizes the 2026-09-19 Dikwa sweep to EVERY LGA, not just one -
# check 6.6: frame's partners_covering, 1_sampling's Partnerscoverage.xlsx,
# 2_monitoring's OWN separate copy of Partnerscoverage.xlsx, and
# partner_lga_assignment.csv (both 2_monitoring mirrors) must all agree,
# for every LGA. Found live 2026-09-19: a 4th, previously-unknown drift
# source (2_monitoring's own month-stale Partnerscoverage.xlsx copy).
library(dplyr)
library(readr)
library(readxl)
library(tidyr)
library(stringr)

# Mirrors analysis_partner_coverage.py's norm() exactly (1_sampling/scripts/
# partner_coverage/analysis_partner_coverage.py, line ~63) - lowercase, strip
# apostrophe-like characters (straight/curly/modifier/mangled-encoding), map
# "/" and "-" to spaces, collapse whitespace. Without this, "Jema'a" vs
# "Jema’a" and "Arewa-Dandi" vs "Arewa Dandi" read as different LGAs.
norm_lga <- function(s) {
  s <- tolower(trimws(s))
  s <- gsub("[/-]", " ", s)
  s <- gsub("[\'‘’ʼ�]", "", s)
  s <- gsub("\\s+", " ", s)
  trimws(s)
}

# Mirrors analysis_partner_coverage.py's COMBINED_PARTNER_SPLITS (same file,
# line ~83) - "IRC/LHI" is one column in the source Excel but two real orgs
# sharing that LGA's workload (confirmed with Jack 2026-08-07), already
# expanded everywhere else (build_partner_dc_packages.py, build_partner_lga_
# boundary_kml.R). Without this, Zuru/Isa/Sabon Birni/Tangaza (IRC/LHI's 4
# LGAs) false-flag as missing from the frame, which lists "IRC" and "LHI"
# as two separate partner tokens.
COMBINED_PARTNER_SPLITS <- list("irc/lhi" = c("irc", "lhi"))
expand_combined_partners <- function(df) {
  df %>%
    mutate(.split = COMBINED_PARTNER_SPLITS[partner]) %>%
    mutate(.split = if_else(lengths(.split) == 0, as.list(partner), .split)) %>%
    tidyr::unnest(.split) %>%
    mutate(partner = .split) %>%
    select(-.split)
}

# Mirrors analysis_partner_coverage.py's PROPOSED_RECONCILIATION dict exactly
# (same file, line ~199) - 10 hand-confirmed (state, Excel LGA text) ->
# master adm2_name pairs, for spelling/naming differences too large for
# norm_lga() alone (e.g. "Wasagu" vs "Wasagu/Danko" - a genuine substring
# difference, not just punctuation/case). Keyed "state|lga" (lowercased,
# raw Excel text) -> the frame's real adm2_name.
PROPOSED_RECONCILIATION_LGA <- c(
  "zamfara|birnin magaji/kiyaw" = "Birnin Magaji",
  "zamfara|kauran namoda" = "Kaura Namoda",
  "kaduna|makarfi" = "Markafi",
  "kaduna|zangon-kataf" = "Zango-Kataf",
  "kebbi|wasagu" = "Wasagu/Danko",
  "benue|otukpo" = "Oturkpo",
  "kogi|olamaboro" = "Olamabolo",
  "nasarawa|eggon" = "Nasarawa-Eggon",
  "niger|munya" = "Muya",
  "plateau|barkin ladi" = "Barikin Ladi"
)
apply_lga_reconciliation <- function(state, lga) {
  key <- paste(tolower(trimws(state)), tolower(trimws(lga)), sep = "|")
  hit <- PROPOSED_RECONCILIATION_LGA[key]
  if_else(!is.na(hit), unname(hit), lga)
}

run_partner_coverage_alignment_checks <- function(log) {
  full <- read_csv(latest_frame_file("NGA_MSNA_2026_stage2_sampling_frame", "FULL"), show_col_types = FALSE, col_types = cols(.default = "c"))

  # Source A: frame's own partners_covering (one row per adm2_pcode+pop_type,
  # should be constant per cluster/LGA - split on ", " since a value can be
  # a combined multi-partner string like "IRC, LHI")
  frame_cov <- full %>% distinct(adm1_name, adm2_pcode, adm2_name, pop_type, partners_covering) %>%
    filter(!is.na(partners_covering)) %>%
    separate_rows(partners_covering, sep = ",\\s*") %>%
    mutate(partner = tolower(trimws(partners_covering))) %>%
    distinct(adm1_name, adm2_pcode, adm2_name, pop_type, partner)

  # Source B: 1_sampling's Partnerscoverage.xlsx (wide format, one column
  # per partner, marker = partner name in that LGA's row)
  read_partnerscoverage <- function(path) {
    sheets <- c("NE", "NW", "NC")
    out <- list()
    for (s in sheets) {
      df <- tryCatch(read_excel(path, sheet = s), error = function(e) NULL)
      if (is.null(df)) next
      partner_cols <- setdiff(names(df), c("Region", "State", "LGA", "COUNT", "Number of Partners", "Surveys"))
      partner_cols <- partner_cols[!grepl("^\\.\\.\\.", partner_cols)]
      long <- df %>% select(State, LGA, all_of(partner_cols)) %>%
        pivot_longer(-c(State, LGA), names_to = "partner_col", values_to = "marker") %>%
        filter(!is.na(marker)) %>%
        mutate(partner = tolower(trimws(partner_col))) %>%
        distinct(State, LGA, partner)
      out[[s]] <- long
    }
    bind_rows(out)
  }
  source_b_path <- file.path(SAMPLING_ROOT, "input_data/boundaries/partner_coverage/Partnerscoverage.xlsx")
  source_c_path <- file.path(MONITORING_ROOT, "input_data/partner_coverage/Partnerscoverage.xlsx")
  source_b <- tryCatch(read_partnerscoverage(source_b_path), error = function(e) tibble())
  source_c <- tryCatch(read_partnerscoverage(source_c_path), error = function(e) tibble())

  # Source B vs C: do 1_sampling's and 2_monitoring's OWN copies of the
  # same Excel file agree? (the exact 2026-09-19 finding)
  b_set <- paste(source_b$LGA, source_b$partner)
  c_set <- paste(source_c$LGA, source_c$partner)
  only_in_b <- setdiff(b_set, c_set)
  only_in_c <- setdiff(c_set, b_set)
  bc_mismatch <- length(only_in_b) + length(only_in_c)
  log <- check_result(log, "partner_coverage_alignment", "1_sampling's and 2_monitoring's own copies of Partnerscoverage.xlsx agree",
                       if (bc_mismatch == 0) "PASS" else "FAIL",
                       sprintf("%d LGA-partner markers differ between the two copies (1_sampling only: %d, 2_monitoring only: %d). These are two independently-maintained copies of the same source file with no sync mechanism - found genuinely drifted by a full month on 2026-09-19 (Dikwa reassignment never reached 2_monitoring's copy).",
                               bc_mismatch, length(only_in_b), length(only_in_c)),
                       bc_mismatch)

  # Source D: partner_lga_assignment.csv, both 2_monitoring mirrors
  d1_path <- file.path(MONITORING_ROOT, "dashboard_app/input_data/partner_coverage/partner_lga_assignment.csv")
  d2_path <- file.path(MONITORING_ROOT, "input_data/partner_coverage/partner_lga_assignment.csv")
  d1 <- tryCatch(read_csv(d1_path, show_col_types = FALSE), error = function(e) tibble())
  d2 <- tryCatch(read_csv(d2_path, show_col_types = FALSE), error = function(e) tibble())
  d1_key <- if (nrow(d1) > 0) paste(d1$adm2_pcode, tolower(d1[[ncol(d1)]])) else character(0)
  d2_key <- if (nrow(d2) > 0) paste(d2$adm2_pcode, tolower(d2[[ncol(d2)]])) else character(0)
  d_mismatch <- length(setdiff(d1_key, d2_key)) + length(setdiff(d2_key, d1_key))
  log <- check_result(log, "partner_coverage_alignment", "partner_lga_assignment.csv agrees between dashboard_app and input_data mirrors",
                       if (d_mismatch == 0) "PASS" else "FAIL",
                       sprintf("%d rows differ between the two mirrored copies of partner_lga_assignment.csv", d_mismatch),
                       d_mismatch)

  # Frame (source A) vs 1_sampling's Partnerscoverage.xlsx (source B) -
  # every LGA×pop_type's partner set should be consistent (frame is the
  # union with the Excel, per the 2026-09-16 fix in prep_partner_lga_assignment.R,
  # so frame partners should be a SUPERSET of, or equal to, the Excel's).
  # Both sides normalized via norm_lga(), name-reconciled via
  # PROPOSED_RECONCILIATION_LGA, and expanded via COMBINED_PARTNER_SPLITS
  # before comparing (2026-09-20 fix - the raw tolower/trimws comparison
  # this used to do false-flagged all 12 of the then-current mismatches:
  # 5 were already-known name variants from analysis_partner_coverage.py's
  # own PROPOSED_RECONCILIATION dict, 2 were apostrophe-encoding variants,
  # 1 a hyphen/space variant, and 4 were the IRC/LHI joint-column split -
  # all real, all already correctly handled by production code, none a
  # genuine sync gap. Verified against those exact 12 before shipping this
  # fix - all 12 now resolve to 0.)
  # Keyed on (state, LGA, partner) together, not LGA+partner alone - a
  # second real LGA-name-collision bug found live 2026-09-20 in the
  # coverage_summary_v2.csv check below (Obi exists in both Benue and
  # Nasarawa, Bassa in both Kogi and Plateau) applies here too in
  # principle, even though today's specific data doesn't happen to trip it
  # (no cross-state same-partner coincidence currently masks it) - fixed
  # proactively rather than waiting for it to actually produce a wrong
  # answer.
  frame_lga_partners <- frame_cov %>% distinct(adm1_name, adm2_name, partner) %>%
    mutate(key = paste(norm_lga(adm1_name), norm_lga(adm2_name), partner))
  excel_lga_partners <- source_b %>% distinct(State, LGA, partner) %>%
    mutate(LGA = apply_lga_reconciliation(State, LGA)) %>%
    expand_combined_partners() %>%
    mutate(key = paste(norm_lga(State), norm_lga(LGA), partner))
  excel_only <- setdiff(excel_lga_partners$key, frame_lga_partners$key)
  log <- check_result(log, "partner_coverage_alignment", "Every partner-LGA pair in 1_sampling's Partnerscoverage.xlsx also appears in the frame's partners_covering",
                       if (length(excel_only) == 0) "PASS" else "WARN",
                       sprintf("%d LGA-partner pairs exist in Partnerscoverage.xlsx but not in the frame's partners_covering column, after normalizing LGA-name spelling/punctuation (norm_lga()), applying the 10 hand-confirmed name reconciliations (PROPOSED_RECONCILIATION_LGA), and expanding the IRC/LHI joint column into both real orgs (COMBINED_PARTNER_SPLITS) - all three mirror analysis_partner_coverage.py exactly, so a nonzero count here is a genuine sync gap, not a name-variant/joint-column artifact already handled elsewhere",
                               length(excel_only)),
                       length(excel_only))

  # ---- coverage_summary_v2.csv (analysis_partner_coverage.py's per-LGA
  # covered/not_covered rollup) matches the CURRENT Partnerscoverage.xlsx -
  # this file is only regenerated when that pipeline is deliberately rerun
  # (discouraged casually, per 1_sampling/CLAUDE.md's own rules), so it can
  # drift arbitrarily far behind partner reassignments in the meantime. ----
  cs_path <- file.path(SAMPLING_ROOT, "output/data/data_collection/NGA_MSNA_2026_coverage_summary_v2.csv")
  cs_status <- "FAIL"; cs_detail <- "coverage_summary_v2.csv not found"; cs_count <- NA
  if (file.exists(cs_path)) {
    cs <- read_csv(cs_path, show_col_types = FALSE)
    # 2026-09-20 fix: was distinct(lga_norm) alone (dropped State before
    # dedup) - a real LGA-name collision bug found live, the exact class
    # this project keeps re-hitting (Sabon Birni/Gwadabawa+Tambuwal, etc.):
    # "Obi" exists in both Benue (not covered) and Nasarawa (CARE-covered),
    # "Bassa" in both Kogi (not covered) and Plateau (CRS-covered) - an
    # unscoped name match wrongly borrowed Nasarawa's/Plateau's coverage
    # onto Benue's/Kogi's same-named-but-different LGA, false-flagging both
    # as stale. Now keyed on (state, lga) together, matching every other
    # check in this module.
    excel_covered_keys <- source_b %>% distinct(State, LGA) %>%
      mutate(LGA = apply_lga_reconciliation(State, LGA)) %>%
      mutate(key = paste(norm_lga(State), norm_lga(LGA))) %>% distinct(key) %>% pull(key)
    cs2 <- cs %>% mutate(key = paste(norm_lga(state), norm_lga(lga)), expected_status = if_else(key %in% excel_covered_keys, "covered", "not_covered"))
    mismatch <- cs2 %>% filter(coverage_status != expected_status)
    cs_mtime <- file.info(cs_path)$mtime
    xlsx_mtime <- file.info(source_b_path)$mtime
    if (nrow(mismatch) == 0) {
      cs_status <- "PASS"
      cs_detail <- sprintf("0 of %d LGAs disagree between coverage_summary_v2.csv (mtime %s) and Partnerscoverage.xlsx (mtime %s)", nrow(cs2), format(cs_mtime), format(xlsx_mtime))
      cs_count <- 0
    } else {
      cs_status <- "WARN"
      cs_detail <- sprintf("%d of %d LGAs' covered/not_covered status disagrees between coverage_summary_v2.csv (mtime %s, only regenerated on a deliberate pipeline rerun) and the CURRENT Partnerscoverage.xlsx (mtime %s): %s - each should be individually confirmed as a genuine partner reassignment, not assumed benign staleness",
                            nrow(mismatch), nrow(cs2), format(cs_mtime), format(xlsx_mtime),
                            paste(sprintf("%s/%s (file says %s, excel implies %s)", mismatch$state, mismatch$lga, mismatch$coverage_status, mismatch$expected_status), collapse = "; "))
      cs_count <- nrow(mismatch)
    }
  }
  log <- check_result(log, "partner_coverage_alignment", "coverage_summary_v2.csv matches the current Partnerscoverage.xlsx",
                       cs_status, cs_detail, cs_count)

  # ---- Partner-name consistency scan: the frame's partners_covering
  # spellings must exactly match 2_monitoring's ACCESSIBILITY_PARTNER_TO_ORG
  # lookup keys, byte-for-byte - not just case-insensitively. This is the
  # exact class of bug behind the 2026-08-27 Solidarités encoding incident
  # (a truncated/mangled name silently producing a phantom "NA" partner in
  # the dashboard's accessibility popup) - a name that "looks the same" but
  # differs by one dropped letter or a curly-vs-straight character would
  # not be caught by a case-insensitive comparison. --------------------------
  frame_partner_names <- full %>% filter(!is.na(partners_covering)) %>% pull(partners_covering) %>%
    strsplit(",\\s*") %>% unlist() %>% trimws() %>% unique() %>% sort()
  global_r_path <- file.path(MONITORING_ROOT, "dashboard_app/global.R")
  name_scan_status <- "FAIL"; name_scan_detail <- "global.R not found"; name_scan_count <- NA
  if (file.exists(global_r_path)) {
    gr <- readLines(global_r_path, warn = FALSE, encoding = "UTF-8")
    start <- grep("^ACCESSIBILITY_PARTNER_TO_ORG <- c\\(", gr)
    if (length(start) == 1) {
      end <- start + which(grepl("^\\)", gr[start:(start + 15)]))[1] - 1
      block <- paste(gr[start:end], collapse = " ")
      pairs <- stringr::str_match_all(block, '"([^"]+)"\\s*=\\s*"([^"]+)"')[[1]]
      org_keys <- pairs[, 2]
      # A partner registered with ZERO LGAs (ACF, once its five LGAs moved to ZOA on 2026-09-25) is
      # legitimately in the lookup but absent from the frame: it stays a valid collector. Only names
      # whose org_id 2_monitoring's derived partner registry lists with n_lgas == 0 are excused.
      reg_path <- file.path(MONITORING_ROOT, "input_data/partner_coverage/partner_registry.csv")
      zero_lga_orgs <- character(0)
      if (file.exists(reg_path)) {
        reg <- read_csv(reg_path, show_col_types = FALSE, col_types = cols(.default = "c"))
        zero_lga_orgs <- reg$org_id[reg$n_lgas == "0"]
      }
      expected_lookup_only <- pairs[pairs[, 3] %in% zero_lga_orgs, 2]
      only_in_frame <- setdiff(frame_partner_names, org_keys)
      only_in_org_lookup <- setdiff(setdiff(org_keys, frame_partner_names), expected_lookup_only)
      total_diff <- length(only_in_frame) + length(only_in_org_lookup)
      name_scan_status <- if (total_diff == 0) "PASS" else "FAIL"
      name_scan_detail <- sprintf("%d partner name(s) differ (byte-for-byte) between the frame's partners_covering spellings and 2_monitoring's ACCESSIBILITY_PARTNER_TO_ORG keys - frame-only: %s; lookup-only: %s (the 2026-08-27 Solidarités incident was exactly this kind of silent, case-insensitive-passing mismatch)%s",
                                   total_diff, paste(only_in_frame, collapse = ", "), paste(only_in_org_lookup, collapse = ", "),
                                   if (length(expected_lookup_only)) sprintf("; %d registered zero-LGA partner(s) expected lookup-only and not counted: %s", length(expected_lookup_only), paste(expected_lookup_only, collapse = ", ")) else "")
      name_scan_count <- total_diff
    }
  }
  log <- check_result(log, "partner_coverage_alignment", "Partner-name spellings agree byte-for-byte between the frame and 2_monitoring's ACCESSIBILITY_PARTNER_TO_ORG lookup",
                       name_scan_status, name_scan_detail, name_scan_count)

  log
}
