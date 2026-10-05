#!/usr/bin/env bash
# Emergency occupation: confirmation, release and revision-bounded history.
#
# Demonstrates the historical look-back rule:
#   * GET /api/revision/{n} renders each occupation strictly as of revision n;
#   * before the release revision the occupation stays "active", with
#     released_revision = null and release_reason = "" -- querying that same
#     revision AFTER the release happened returns the identical body;
#   * the actual released_revision / release_reason appear only from the
#     release revision on.
#
# Requires a running server (default http://127.0.0.1:8000) and curl + jq.
set -euo pipefail

BASE="${BASE_URL:-http://127.0.0.1:8000}"

req() { # METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" "$BASE$path" \
      -H 'Content-Type: application/json' -d "$body"
  else
    curl -fsS -X "$method" "$BASE$path"
  fi
}

payload() { # LOW HIGH NAME
  cat <<JSON
{"name":"$3",
 "circle":{"cx":0,"cy":0,"radius":10},
 "frequency":{"low":$1,"high":$2},
 "time_window":{"start":"2026-10-01T08:00:00Z","end":"2026-10-01T10:00:00Z"}}
JSON
}

echo "== 1. submit + approve an ordinary license 100-110 (revision 0 -> 1)"
A=$(req POST /api/applications "$(payload 100 110 ordinary-A)" | jq .id)
req POST "/api/applications/$A/approve" '{"expected_revision":0}' >/dev/null

echo "== 2. submit an emergency application 104-109"
EM=$(req POST /api/applications "$(payload 104 109 burst-emergency)" | jq .id)

echo "== 3. read-only emergency preview (no revision consumed)"
req POST /api/emergency-occupations/preview \
  "{\"application_id\":$EM,\"reason\":\"burst traffic\"}" \
  | jq '{current_revision, ready, force_suspend_application_ids, blockers}'

echo "== 4. confirm the occupation at expected revision 1"
echo "    (A force-suspended at revision 2, emergency license approved at 3)"
req POST /api/emergency-occupations \
  "{\"application_id\":$EM,\"expected_revision\":1,\"reason\":\"burst traffic\"}" \
  | jq '{emergency_approval_revision, force_suspended_application_ids}'

echo "== 5. snapshot at revision 3 (BEFORE any release): active, null / \"\""
req GET /api/revision/3 \
  | jq '.emergency_occupations[0]
        | {status, emergency_approval_revision, released_revision,
           release_reason, force_suspended_application_ids,
           still_force_suspended_application_ids}'

echo "== 6. release the occupation at expected revision 3"
echo "    (emergency license revoked at 4, license A restored at 5)"
req POST "/api/emergency-occupations/$EM/release" \
  '{"expected_revision":3,"reason":"incident over"}' \
  | jq '{emergency_revocation_revision, restored_application_ids, final_revision}'

echo "== 7. re-query revision 3 AFTER the release: identical to step 5"
req GET /api/revision/3 \
  | jq '.emergency_occupations[0]
        | {status, emergency_approval_revision, released_revision,
           release_reason, force_suspended_application_ids,
           still_force_suspended_application_ids}'

echo "== 8. revision 4 is the first revision showing the release decision"
req GET /api/revision/4 \
  | jq '.emergency_occupations[0]
        | {status, released_revision, release_reason}'

echo "== 9. current revision 5: released with the actual release information"
req GET /api/revision/current \
  | jq '.emergency_occupations[0]
        | {status, released_revision, release_reason,
           recovered_application_ids}'

echo "== 10. compare revisions 1 -> 5: activated then released, ordered"
req GET "/api/revision/compare?base_revision=1&target_revision=5" \
  | jq '[.emergency_occupation_events[]
        | {revision, type}]'

echo "== 11. live occupation lookup shows the released record"
req GET "/api/emergency-occupations/$EM" \
  | jq '.occupation
        | {status, emergency_approval_revision, released_revision,
           release_reason, released_at}'
echo "OK"
