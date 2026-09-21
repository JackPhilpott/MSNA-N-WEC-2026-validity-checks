"""Standalone mirror of build_partner_dc_packages.py's _is_achieved() (lines
~645-650), duplicated here per this project's own "duplicated, not imported"
standalone-script convention - used ONLY by achieved_target_definitions.R's
R-vs-Python parity check, to compare against frame_status.R's
compute_achieved_lookup() without executing the real (file-writing,
partner-facing) build_partner_dc_packages.py script.

Usage: python compute_achieved_mirror.py <real_submissions.csv> <CONFIRMED_DELETIONS_OVERLAY.csv> <output.csv>
Output: one row per achieved item - non_idp rows keyed by survey_id,
idp rows keyed by cluster_id with a summed achieved count.
"""
import csv
import sys
from collections import defaultdict

real_submissions_csv, overlay_csv, output_csv = sys.argv[1:4]

_CONFIRMED_OVERLAY_TERMINAL_STATUSES = {"confirmed", "contested"}
with open(overlay_csv, encoding="utf-8") as f:
    confirmed_deleted_uuids = {r["uuid"] for r in csv.DictReader(f) if r["status"] in _CONFIRMED_OVERLAY_TERMINAL_STATUSES}


def _is_achieved(r):
    return (
        r.get("interview_outcome") == "completed"
        and r.get("matched_survey_id") not in (None, "", "NA")
        and r.get("submission_uuid") not in confirmed_deleted_uuids
    )


non_idp_survey_ids = set()
idp_cluster_counts = defaultdict(int)

with open(real_submissions_csv, encoding="utf-8") as f:
    for r in csv.DictReader(f):
        if not _is_achieved(r):
            continue
        if r.get("pop_type") == "non_idp":
            non_idp_survey_ids.add(r["matched_survey_id"])
        elif r.get("pop_type") == "idp":
            idp_cluster_counts[r["matched_cluster_id"]] += 1

with open(output_csv, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["kind", "key", "n_achieved"])
    for sid in sorted(non_idp_survey_ids):
        w.writerow(["non_idp", sid, 1])
    for cid, n in sorted(idp_cluster_counts.items()):
        w.writerow(["idp", cid, n])
