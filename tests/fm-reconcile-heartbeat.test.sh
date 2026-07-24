#!/usr/bin/env bash
# End-to-end reconciliation heartbeat contract.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-reconcile-heartbeat.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
PROJECTS="$HOME_DIR/projects"
FAKEBIN="$TMP/bin"
mkdir -p "$STATE" "$DATA" "$PROJECTS/app" "$FAKEBIN"

cat > "$DATA/projects.md" <<'EOF'
- app [no-mistakes +yolo] - Test application (added 2026-07-24)
EOF

git -C "$PROJECTS/app" init -q
git -C "$PROJECTS/app" remote add origin https://github.com/acme/app.git

cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$*" in
  "issue list --repo acme/app --state open --limit 100 --json number,title,url,labels,createdAt,updatedAt")
    cat <<'JSON'
[{"number":7,"title":"Finish the work","url":"https://github.com/acme/app/issues/7","labels":[],"createdAt":"2026-07-20T00:00:00Z","updatedAt":"2026-07-20T00:00:00Z"}]
JSON
    ;;
  "pr list --repo acme/app --state open --limit 100 --json number,title,url,headRefName,baseRefName,mergeable,statusCheckRollup,closingIssuesReferences")
    printf '[]\n'
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$FAKEBIN/gh"

OUT="$TMP/out.json"
PATH="$FAKEBIN:$PATH" \
  FM_HOME="$HOME_DIR" \
  FM_RECONCILE_NOW="2026-07-24T12:00:00Z" \
  FM_RECONCILE_NOW_EPOCH=1784894400 \
  FM_RECONCILE_ISSUE_LIMIT=100 \
  FM_RECONCILE_PR_LIMIT=100 \
  "$ROOT/bin/fm-reconcile.sh" --tick --json > "$OUT"

jq -e '.schema == "fm-reconcile.v1"' "$OUT" >/dev/null \
  || fail "missing reconciliation schema"
jq -e '.counts.open == 1 and .counts.available == 1' "$OUT" >/dev/null \
  || fail "open issue was not inventoried as available"
jq -e '.health.state == "action-required"' "$OUT" >/dev/null \
  || fail "open unassigned issue did not require action"
jq -e '.next_interval_seconds == 1800' "$OUT" >/dev/null \
  || fail "idle unresolved work did not select the 30-minute cadence"
[ -s "$STATE/.wake-queue" ] \
  || fail "silent open issue did not create a durable reconciliation wake"
grep "$(printf '\treconcile\t')" "$STATE/.wake-queue" >/dev/null \
  || fail "wake queue did not identify reconciliation work"

ACK_TOKEN=$(jq -r '.ack.token' "$OUT")
[ -n "$ACK_TOKEN" ] && [ "$ACK_TOKEN" != null ] \
  || fail "actionable tick did not issue an acknowledgement token"

WATCH_OUT="$TMP/watch.out"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_POLL=1 \
  FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$WATCH_OUT"
grep -F "reconcile: token=$ACK_TOKEN" "$WATCH_OUT" >/dev/null \
  || fail "normal watcher did not surface the external reconciliation request"

OUT2="$TMP/out2.json"
PATH="$FAKEBIN:$PATH" \
  FM_HOME="$HOME_DIR" \
  FM_RECONCILE_NOW="2026-07-24T12:16:40Z" \
  FM_RECONCILE_NOW_EPOCH=1784895400 \
  FM_RECONCILE_ISSUE_LIMIT=100 \
  FM_RECONCILE_PR_LIMIT=100 \
  "$ROOT/bin/fm-reconcile.sh" --tick --force --json > "$OUT2"
jq -e --arg token "$ACK_TOKEN" \
  '.health.state == "control-plane-failed" and .ack.token == $token and .ack.previous_unacked == true' \
  "$OUT2" >/dev/null \
  || fail "unacknowledged reconciliation did not retain its token and degrade the control plane"

PATH="$FAKEBIN:$PATH" \
  FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-reconcile-ack.sh" "$ACK_TOKEN" "inventory accepted"

jq -e --arg token "$ACK_TOKEN" '.token == $token and .note == "inventory accepted"' \
  "$STATE/reconcile/last-ack.json" >/dev/null \
  || fail "acknowledgement was not persisted"
[ ! -e "$STATE/reconcile/pending" ] \
  || fail "acknowledgement did not clear the pending wake latch"

pass "silent GitHub work produces a durable, acknowledged reconciliation wake"
