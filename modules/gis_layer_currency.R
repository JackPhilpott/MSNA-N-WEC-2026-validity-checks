# Module: gis_layer_currency (cross-repo)
#
# Standing guard for a failure mode this project has hit more than once:
# the dashboard's MAP layers drifting out of step with the sampling frame
# that everything else reads. The layers are frame-DERIVED (built by
# 2_monitoring/cleaning/prep/prep_psu_geometries.R and prep_accessibility_
# layer.R), so nothing about them self-corrects when the frame moves -
# a resampling round can add supplementary clusters, or a stratum can be
# excluded, and the Coverage Map simply keeps drawing yesterday's picture.
# Precedent: 2026-09-02, ~375 newly-drawn clusters were COMPLETELY ABSENT
# from psu_hexagons/psu_sites because the geometry came only from a frozen
# 2026-08-06 archive, and every cluster/LGA/partner total downstream of
# those layers silently undercounted; 2026-09-07, a stale accessibility
# shapefile let clusters be drawn into wards already known inaccessible.
#
# Added 2026-09-22 at Jack's request, in his words: make sure the LGA,
# accessibility and cluster GIS layers "are always being updated and passed
# to/checked by the dashboard ... particularly when assessing dropped/newly
# instated clusters, where we have had stale problems here in the past".
#
# The checks are deliberately CONTENT-based first (which cluster_ids are in
# the layers vs the frame) and mtime-based only as a secondary ordering
# signal - a layer rebuilt from an unchanged frame is current even though
# its mtime moved, and a layer with the right mtime can still have been
# built from the wrong source.
library(dplyr)
library(sf)
library(readr)

run_gis_layer_currency_checks <- function(log) {
  psu_dir <- file.path(MONITORING_ROOT, "input_data/boundaries/psu")
  hex_path <- file.path(psu_dir, "psu_hexagons_non_idp.gpkg")
  site_path <- file.path(psu_dir, "psu_sites_idp.gpkg")
  acc_path <- file.path(MONITORING_ROOT, "input_data/accessibility/accessible_area_lga_ward_portions_repaired.gpkg")
  ward_path <- file.path(MONITORING_ROOT, "input_data/boundaries/nga_wards_grid3.gpkg")
  adm2_path <- file.path(MONITORING_ROOT, "input_data/boundaries/nga_admin2_em.shp")

  if (!file.exists(hex_path) || !file.exists(site_path)) {
    log <- check_result(log, "gis_layer_currency", "PSU geometry layers exist", "FAIL",
                         sprintf("Missing %s and/or %s - the Coverage Map has no cluster geometry to draw at all",
                                 basename(hex_path), basename(site_path)), NA)
    return(log)
  }

  hex <- suppressWarnings(st_read(hex_path, quiet = TRUE))
  sit <- suppressWarnings(st_read(site_path, quiet = TRUE))
  geo_ids <- unique(c(as.character(hex$cluster_id), as.character(sit$cluster_id)))

  # The frame the DASHBOARD actually reads (its own mirror), not
  # 1_sampling's canonical copy - cross_repo_propagation_freshness already
  # guards that those two agree, and this module is about what the map is
  # drawing relative to what the app itself believes.
  mirror_dir <- file.path(MONITORING_ROOT, "input_data/sampling_frame")
  pick <- function(suffix) {
    f <- list.files(mirror_dir, pattern = paste0("^NGA_MSNA_2026_stage2_sampling_frame_v[0-9]+_", suffix, "[.]csv$"), full.names = TRUE)
    if (length(f) == 0) return(NA_character_)
    f[which.max(as.integer(gsub(".*_v([0-9]+)_.*", "\\1", basename(f))))]
  }
  wk_path <- pick("WORKING"); fu_path <- pick("FULL")
  if (is.na(wk_path) || is.na(fu_path)) {
    log <- check_result(log, "gis_layer_currency", "Dashboard frame mirror present for the GIS comparison", "FAIL",
                         "No stage2 WORKING/FULL frame in 2_monitoring/input_data/sampling_frame - cannot compare the map layers against anything", NA)
    return(log)
  }
  wk <- read_csv(wk_path, show_col_types = FALSE, col_types = cols(.default = "c"))
  fu <- read_csv(fu_path, show_col_types = FALSE, col_types = cols(.default = "c"))

  # MSNA Light clusters are expected to have NO geometry: that collection is
  # LGA-level via government enumerators with no georeferencing at all, so
  # there is no hexagon or site point to draw (see 1_sampling's MSNA Light
  # notes). Exempted EXPLICITLY and counted, never silently filtered - the
  # whole point of this module is that an absent cluster gets noticed.
  light_ids <- unique(wk$cluster_id[!is.na(wk$sampling_method) & wk$sampling_method == "MSNA Light"])
  wk_ids <- unique(wk$cluster_id)
  expected_ids <- setdiff(wk_ids, light_ids)

  missing <- setdiff(expected_ids, geo_ids)
  missing_supp <- sum(grepl("supp", missing))
  log <- check_result(log, "gis_layer_currency",
                       "Every active (WORKING) cluster the map should draw has geometry in psu_hexagons/psu_sites",
                       if (length(missing) == 0) "PASS" else "FAIL",
                       sprintf("%d of %d expected cluster(s) have no geometry (%d of them supplementary/newly-drawn)%s. MSNA Light clusters are excluded from this expectation by design (%d of them, no georeferencing) and are reported separately below. A nonzero count here is the 2026-09-02 failure again: a cluster the frame considers active that the Coverage Map cannot show, so every map-derived figure for it silently undercounts",
                               length(missing), length(expected_ids), missing_supp,
                               if (length(missing) == 0) "" else paste0(": ", paste(head(sort(missing), 6), collapse = ", "), if (length(missing) > 6) ", ..." else ""),
                               length(light_ids)),
                       length(missing))

  # MSNA Light and geometry: tested for CONSISTENCY rather than against an
  # assumed answer. Written first as "Light clusters have no geometry,
  # expected 0" - which was my own assumption from the no-georeferencing
  # arrangement, and the first live run immediately contradicted it:
  # Guzamala's 13 Light clusters DO carry hexagons while Abadam's 17 and
  # Nganzai's 17 carry none, all of them genuine Light-only ids (no shared
  # id with a Full Design cluster, checked). Whichever way that should be
  # resolved is Jack's/1_sampling's call, not this suite's - but 13 of 47
  # is a state nobody chose, and the map showing a third of the Light
  # clusters is exactly the kind of half-updated layer this module exists
  # to catch. So: all-or-none passes, a mixture fails.
  light_with_geo <- intersect(light_ids, geo_ids)
  log <- check_result(log, "gis_layer_currency",
                       "No MSNA Light cluster carries cluster-level map geometry (Jack's rule, 2026-09-22: Light is LGA-level only)",
                       if (length(light_with_geo) == 0) "PASS" else "FAIL",
                       sprintf("%d of %d MSNA Light cluster(s) in WORKING carry map geometry%s. Jack, 2026-09-22: \"the three MSNA Light LGAs should not have any geometry at a cluster level, only at a LGA level\" - that collection is negotiated LGA-level enumeration with no georeferencing, so a hexagon for a Light cluster implies precision that doesn't exist. Enforced at source in prep_psu_geometries.R; a nonzero count here means either that exclusion was lost or Light geometry arrived from a new-cluster batch. Was 13 of 47 when found (Guzamala 13, Abadam 0, Nganzai 0 - inconsistent, which is how it surfaced)",
                               length(light_with_geo), length(light_ids),
                               if (length(light_with_geo) == 0) "" else
                                 paste0(": ", paste(head(sort(light_with_geo), 4), collapse = ", "), if (length(light_with_geo) > 4) ", ..." else "")),
                       length(light_with_geo))

  # Dropped/retired direction: geometry that outlived the frame. This is the
  # half that makes a dropped cluster keep appearing as a live target.
  fu_ids <- unique(fu$cluster_id)
  fu_cov <- unique(fu$cluster_id[fu$coverage_status == "covered"])
  ghost <- setdiff(geo_ids, fu_ids)
  log <- check_result(log, "gis_layer_currency",
                       "No map geometry for a cluster the frame no longer contains at all",
                       if (length(ghost) == 0) "PASS" else "FAIL",
                       sprintf("%d geometry cluster(s) absent from the FULL frame%s - these draw on the Coverage Map as if they were still real sampling targets",
                               length(ghost),
                               if (length(ghost) == 0) "" else paste0(": ", paste(head(sort(ghost), 6), collapse = ", "))),
                       length(ghost))

  dropped_geo <- setdiff(intersect(geo_ids, fu_ids), fu_cov)
  log <- check_result(log, "gis_layer_currency",
                       "Map geometry for clusters in a no-longer-covered (dropped/excluded) stratum (informational)",
                       "PASS",
                       sprintf("%d cluster(s) - these are legitimately still drawn (a Dropped stratum stays visible at its own row/on the map, per Jack's 2026-09-14 rule) but must never count toward a rollup; dashboard_deletion_identity covers the counting side",
                               length(dropped_geo)),
                       length(dropped_geo))

  # Ordering signal: a frame-derived layer built BEFORE the frame's own last
  # write was, at best, built from a previous write of it.
  frame_mtime <- max(file.info(c(wk_path, fu_path))$mtime)
  derived <- c(hex_path, site_path, acc_path)
  derived <- derived[file.exists(derived)]
  older <- derived[file.info(derived)$mtime < frame_mtime]
  log <- check_result(log, "gis_layer_currency",
                       "Frame-derived GIS layers (PSU geometry, accessibility portions) are not older than the frame they describe",
                       if (length(older) == 0) "PASS" else "WARN",
                       sprintf("frame mirror last written %s; %d of %d derived layer(s) older than that%s. WARN not FAIL: a layer built from an identical earlier write of the same frame version is still correct, and the content checks above are the authoritative test - but after any resampling round, rerun prep_psu_geometries.R/prep_accessibility_layer.R (deploy_dashboard.R does both) before trusting the map",
                               format(frame_mtime, "%Y-%m-%d %H:%M"), length(older), length(derived),
                               if (length(older) == 0) "" else paste0(": ", paste(basename(older), collapse = ", "))),
                       length(older))

  # The app on shinyapps.io only ever sees dashboard_app/'s bundled copies.
  mirrors <- c(hex_path, site_path, acc_path, ward_path, adm2_path)
  mirrors <- mirrors[file.exists(mirrors)]
  bad_mirror <- character(0)
  for (p in mirrors) {
    rel <- sub(paste0("^", MONITORING_ROOT, "/"), "", p)
    mp <- file.path(MONITORING_ROOT, "dashboard_app", rel)
    if (!file.exists(mp)) { bad_mirror <- c(bad_mirror, paste0(basename(p), " (mirror missing)")); next }
    if (file.info(p)$size != file.info(mp)$size) bad_mirror <- c(bad_mirror, paste0(basename(p), " (size differs)"))
  }
  log <- check_result(log, "gis_layer_currency",
                       "Every GIS layer is mirrored into dashboard_app/ at the same size (that bundle is all the deployed app can see)",
                       if (length(bad_mirror) == 0) "PASS" else "FAIL",
                       sprintf("%d of %d layer(s) differ between the canonical copy and the dashboard_app bundle%s - bundle_dashboard_mirrors() refreshes these; a mismatch means the deployed map is drawing something other than what this workspace holds",
                               length(bad_mirror), length(mirrors),
                               if (length(bad_mirror) == 0) "" else paste0(": ", paste(bad_mirror, collapse = ", "))),
                       length(bad_mirror))

  log
}
