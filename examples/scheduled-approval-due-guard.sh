#!/usr/bin/env bash
# Due-guard walkthrough for scheduled auto-approvals (this round).
#
# Once the booked UTC instant has arrived but the sweep has not processed the
# appointment yet (the background poller is delayed or disabled), the waiting
# appointment belongs to due processing: rebooking (a repeated booking call),
# rescheduling and cancelling are all refused inside the same revision
# arbitration as the sweep (409 scheduled_approval_due) and change nothing --
# the application, the appointment, its waitlist place, the revision and the
# appointment's lifecycle events all stay as they were, so the due
# adjudication is never skipped.
#
# Start the service with the background sweeper disabled so the due
# appointment stays waiting until the explicit process-due call:
#
#   SCHEDULED_APPROVAL_BACKGROUND=0 uvicorn app.main:app
#   # or: SCHEDULED_APPROVAL_BACKGROUND=0 docker compose up --build
#
# Usage: ./examples/scheduled-approval-due-guard.sh [BASE_URL]
set -euo pipefail

BASE="${1:-http://localhost:8000}"
J() { python3 -m json.tool; }
post() { curl -s -X POST "$BASE$1" -H 'Content-Type: application/json' -d "${2:-}"; }
at() { date -u -d "$1" +%FT%TZ; }

# POST and show the JSON body followed by the HTTP status (for the refusals).
show() {
  local body http
  body=$(mktemp)
  http=$(curl -s -o "$body" -w '%{http_code}' -X POST "$BASE$1" \
    -H 'Content-Type: application/json' -d "${2:-}")
  python3 -m json.tool "$body"
  echo "-> HTTP $http"
  rm -f "$body"
}

echo "== 0. health =="
curl -s "$BASE/health"; echo

echo "== 1. submit pending application G =="
G=$(post /api/applications "{
  \"name\":\"G\",
  \"circle\":{\"cx\":0,\"cy\":0,\"radius\":10},
  \"frequency\":{\"low\":500,\"high\":510},
  \"time_window\":{\"start\":\"$(at '+2 days')\",\"end\":\"$(at '+3 days')\"}
}")
echo "$G" | J
G_ID=$(echo "$G" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

echo "== 2. book the auto-approval 2 seconds ahead (no revision consumed) =="
BOOK=$(post "/api/applications/$G_ID/scheduled-approvals" \
  "{\"scheduled_at\":\"$(at '+2 seconds')\",\"reason\":\"on-site check\"}")
echo "$BOOK" | J
B_ID=$(echo "$BOOK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["scheduled_approval_id"])')

echo "-- waiting for the booked instant to arrive (sweeper disabled/delayed) --"
sleep 3

echo "== 3. rebook (duplicate booking) -> 409 scheduled_approval_due =="
show "/api/applications/$G_ID/scheduled-approvals" \
  "{\"scheduled_at\":\"$(at '+1 hour')\"}"

echo "== 4. explicit reschedule -> 409 scheduled_approval_due =="
show "/api/applications/$G_ID/scheduled-approvals/reschedule" \
  "{\"scheduled_at\":\"$(at '+1 hour')\"}"

echo "== 5. cancel -> 409 scheduled_approval_due =="
show "/api/applications/$G_ID/scheduled-approvals/cancel" '{"reason":"too late"}'

echo "== 6. nothing changed: original appointment still waiting, revision still 0 =="
curl -s "$BASE/api/scheduled-approvals/$B_ID" | J
curl -s "$BASE/api/revision/current" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(json.dumps({"current_revision": d["current_revision"], "scheduled_approval_ids": d["scheduled_approval_ids"]}, indent=2))'

echo "== 7. the sweep still adjudicates the preserved appointment =="
post /api/scheduled-approvals/process-due | J

echo "== 8. decision consistent between the live and the historical queries =="
curl -s "$BASE/api/scheduled-approvals/$B_ID" | J
curl -s "$BASE/api/revision/1" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(json.dumps({"revision": d["revision"], "approvals": d["approvals"], "scheduled_approvals": d["scheduled_approvals"]}, indent=2))'
curl -s "$BASE/api/revision/0" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(json.dumps({"revision": d["revision"], "scheduled_approvals": d["scheduled_approvals"]}, indent=2))'

echo "== 9. terminal state: reschedule/cancel -> 409 scheduled_approval_not_active; rebook -> 409 not_pending =="
show "/api/applications/$G_ID/scheduled-approvals/reschedule" \
  "{\"scheduled_at\":\"$(at '+1 hour')\"}"
show "/api/applications/$G_ID/scheduled-approvals/cancel"
show "/api/applications/$G_ID/scheduled-approvals" \
  "{\"scheduled_at\":\"$(at '+1 hour')\"}"
