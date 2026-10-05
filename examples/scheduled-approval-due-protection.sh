#!/usr/bin/env bash
# Scheduled auto-approvals: a due-but-not-yet-swept appointment can no longer
# be rebooked, explicitly rescheduled or cancelled.
#
# When the background sweep is delayed or disabled (SCHEDULED_APPROVAL_BACKGROUND=0)
# the booked UTC instant may have arrived while the row is still "scheduled".
# All three modification paths then:
#   * run inside the same singleton revision arbitration the sweep uses;
#   * compare the ORIGINAL appointment's scheduled_at against server UTC;
#   * fail with HTTP 409 scheduled_approval_due;
#   * change nothing (application, appointment instant/status, waitlist place,
#     revision and lifecycle events all stay as they were);
#   * leave the appointment for POST /api/scheduled-approvals/process-due,
#     which still adjudicates against the live guard band / effective
#     licenses / active restriction windows.
#
# Requires a running server (default http://127.0.0.1:8000) and curl + jq.
set -euo pipefail

BASE="${BASE_URL:-http://127.0.0.1:8000}"

req() { # METHOD PATH [JSON_BODY] -- prints body, fails on non-3xx/4xx... so use raw for errors
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$BASE$path" \
      -H 'Content-Type: application/json' -d "$body"
  else
    curl -sS -X "$method" "$BASE$path"
  fi
}

# Like req() but keeps the HTTP status: prints "STATUS\nBODY".
raw() { # METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -o /tmp/sdue-body -w '%{http_code}' -X "$method" "$BASE$path" \
      -H 'Content-Type: application/json' -d "$body"
  else
    curl -sS -o /tmp/sdue-body -w '%{http_code}' -X "$method" "$BASE$path"
  fi
  echo
  cat /tmp/sdue-body
}

iso_offset() { # SECONDS_AHEAD
  date -u -d "+$1 seconds" +%FT%TZ
}

payload() { # LOW HIGH NAME
  cat <<JSON
{"name":"$3",
 "circle":{"cx":0,"cy":0,"radius":10},
 "frequency":{"low":$1,"high":$2},
 "time_window":{"start":"$(iso_offset 172800)","end":"$(iso_offset 259200)"}}
JSON
}

echo "== 1. submit a pending application with a free band 400-410"
A=$(req POST /api/applications "$(payload 400 410 due-protection)" | jq .id)
echo "    application id=$A"

echo "== 2. book an appointment 2 seconds in the future"
BOOK=$(req POST "/api/applications/$A/scheduled-approvals" \
  "{\"scheduled_at\":\"$(iso_offset 2)\",\"reason\":\"booked\"}")
BID=$(echo "$BOOK" | jq .scheduled_approval_id)
echo "    booked appointment id=$BID -> $(echo "$BOOK" | jq -c '{action,status,scheduled_at}')"

echo "== 3. wait past the booked instant WITHOUT running the sweep"
sleep 3
BEFORE=$(req GET "/api/scheduled-approvals/$BID")
echo "    still waiting: $(echo "$BEFORE" | jq -c '{id,status,scheduled_at}')"
test "$(echo "$BEFORE" | jq -r .status)" = "scheduled"
REQ_REVISION=$(req GET /api/revision/current | jq .current_revision)

echo "== 4. rebooking (POST the book endpoint again) is refused, appointment kept"
OUT=$(raw POST "/api/applications/$A/scheduled-approvals" \
  "{\"scheduled_at\":\"$(iso_offset 3600)\",\"reason\":\"late rebook\"}")
echo "    HTTP $(echo "$OUT" | head -1)"
echo "$OUT" | tail -1 | jq '.error | {code,message,details}'
test "$(echo "$OUT" | head -1)" = "409"
test "$(echo "$OUT" | tail -1 | jq -r .error.code)" = "scheduled_approval_due"

echo "== 5. explicit reschedule is refused (even with a valid future instant)"
OUT=$(raw POST "/api/applications/$A/scheduled-approvals/reschedule" \
  "{\"scheduled_at\":\"$(iso_offset 3600)\",\"reason\":\"late move\"}")
echo "    HTTP $(echo "$OUT" | head -1) $(echo "$OUT" | tail -1 | jq -r .error.code)"
test "$(echo "$OUT" | head -1)" = "409"
test "$(echo "$OUT" | tail -1 | jq -r .error.code)" = "scheduled_approval_due"

echo "== 6. cancel is refused too"
OUT=$(raw POST "/api/applications/$A/scheduled-approvals/cancel" '{"reason":"late"}')
echo "    HTTP $(echo "$OUT" | head -1) $(echo "$OUT" | tail -1 | jq -r .error.code)"
test "$(echo "$OUT" | head -1)" = "409"
test "$(echo "$OUT" | tail -1 | jq -r .error.code)" = "scheduled_approval_due"

echo "== 7. nothing changed: same scheduled row, same instant, no revision consumed"
AFTER=$(req GET "/api/scheduled-approvals/$BID")
echo "    $(echo "$AFTER" | jq -c '{id,status,scheduled_at}')"
test "$(echo "$AFTER" | jq -r .status)" = "scheduled"
test "$(echo "$AFTER" | jq -r .scheduled_at)" = "$(echo "$BEFORE" | jq -r .scheduled_at)"
test "$(req GET /api/revision/current | jq .current_revision)" = "$REQ_REVISION"
test "$(req GET "/api/applications/$A" | jq -r .status)" = "pending"

echo "== 8. the due sweep still adjudicates and approves the ORIGINAL appointment"
req POST /api/scheduled-approvals/process-due \
  | jq '{processed_count,approved_application_ids,blocked_application_ids,final_revision}'
FINAL=$(req GET "/api/scheduled-approvals/$BID")
echo "    $(echo "$FINAL" | jq -c '{id,status,approval_revision,processed_at,processed_guard_band}')"
test "$(echo "$FINAL" | jq -r .status)" = "approved"
test "$(req GET "/api/applications/$A" | jq -r .status)" = "approved"

echo "== 9. after the terminal state, reschedule/cancel keep the old rejection code"
OUT=$(raw POST "/api/applications/$A/scheduled-approvals/cancel")
echo "    cancel HTTP $(echo "$OUT" | head -1) $(echo "$OUT" | tail -1 | jq -r .error.code)"
test "$(echo "$OUT" | tail -1 | jq -r .error.code)" = "scheduled_approval_not_active"
OUT=$(raw POST "/api/applications/$A/scheduled-approvals/reschedule" \
  "{\"scheduled_at\":\"$(iso_offset 3600)\"}")
echo "    reschedule HTTP $(echo "$OUT" | head -1) $(echo "$OUT" | tail -1 | jq -r .error.code)"
test "$(echo "$OUT" | tail -1 | jq -r .error.code)" = "scheduled_approval_not_active"
echo "OK"
