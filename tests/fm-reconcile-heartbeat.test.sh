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

# bin/fm-session-start.sh runs the tick without --json, so the operator-facing
# digest is a shipped surface: it must render, not just the machine path.
# FM_PROCESS_OLD_SECS keeps the host's own long-lived processes out of the
# health verdict so these assertions cannot depend on the machine running them.
render_tick() {  # <label> <args...>
  local label=$1
  shift
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_RECONCILE_NOW="2026-07-24T13:00:00Z" \
    FM_RECONCILE_NOW_EPOCH=1784898000 \
    FM_RECONCILE_ISSUE_LIMIT=100 \
    FM_RECONCILE_PR_LIMIT=100 \
    FM_PROCESS_OLD_SECS=999999999 \
    "$ROOT/bin/fm-reconcile.sh" "$@" > "$TMP/$label.out" 2> "$TMP/$label.err" \
    || fail "$label: default renderer exited $? ($(cat "$TMP/$label.err"))"
  [ ! -s "$TMP/$label.err" ] \
    || fail "$label: default renderer wrote to stderr ($(cat "$TMP/$label.err"))"
  for expected in 'schema: fm-reconcile.v1' 'health: ' 'counts: open=1' \
    'next_interval_seconds: ' 'ack_token: '; do
    grep -F "$expected" "$TMP/$label.out" >/dev/null \
      || fail "$label: default renderer omitted '$expected'"
  done
}

render_tick tick-due --tick --force
grep -E '^ack_token: [0-9]+-[0-9]+$' "$TMP/tick-due.out" >/dev/null \
  || fail "default renderer did not print the acknowledgement token"
render_tick tick-not-due --tick
cmp -s "$TMP/tick-due.out" "$TMP/tick-not-due.out" \
  || fail "not-due tick did not render the persisted snapshot it was supposed to reuse"
render_tick inspect --inspect
pass "the default renderer prints the digest on the tick, not-due, and inspect paths"

# --- active work with zero open issues -------------------------------------
HOME_B="$TMP/home-b"
FAKEBIN_B="$TMP/bin-b"
mkdir -p "$HOME_B/state" "$HOME_B/data" "$HOME_B/projects/app" "$FAKEBIN_B"
cat > "$HOME_B/data/projects.md" <<'EOF'
- app [no-mistakes +yolo] - Test application (added 2026-07-24)
EOF
git -C "$HOME_B/projects/app" init -q
git -C "$HOME_B/projects/app" remote add origin https://github.com/acme/app.git
cat > "$FAKEBIN_B/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1 $2" in
  "issue list") printf '[]\n' ;;
  "pr list")
    printf '%s\n' '[{"number":11,"title":"Ship it","url":"https://github.com/acme/app/pull/11","headRefName":"feature","baseRefName":"stg","mergeable":"MERGEABLE","statusCheckRollup":[],"closingIssuesReferences":[]}]'
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKEBIN_B/gh"

OUT_B="$TMP/out-b.json"
PATH="$FAKEBIN_B:$PATH" \
  FM_HOME="$HOME_B" \
  FM_RECONCILE_NOW="2026-07-24T12:00:00Z" \
  FM_RECONCILE_NOW_EPOCH=1784894400 \
  FM_PROCESS_OLD_SECS=999999999 \
  "$ROOT/bin/fm-reconcile.sh" --tick --json > "$OUT_B"
jq -e '.counts.open == 0 and .counts.open_prs == 1' "$OUT_B" >/dev/null \
  || fail "zero-open fleet with an open PR was not inventoried"
jq -e '.next_interval_seconds == 600' "$OUT_B" >/dev/null \
  || fail "active work with zero open issues did not select the 10-minute cadence"
jq -e '.health.state == "action-required"' "$OUT_B" >/dev/null \
  || fail "active work with zero open issues was reported as an idle complete fleet"
jq -e '.ack.required == true and .ack.token != null' "$OUT_B" >/dev/null \
  || fail "active work with zero open issues did not require an acknowledgement"
[ -e "$HOME_B/state/reconcile/pending" ] \
  || fail "active work with zero open issues did not latch a reconciliation wake"
pass "a crew, PR, validation run, or lease keeps the 10-minute cadence after the last issue closes"

# --- the 2-hour cadence is reserved for a genuinely finished fleet ----------
# The zero-open case above still holds an open PR, so it proves only that active
# work pins the fast cadence. The slow cadence needs its own fleet with nothing
# open and nothing active, or "every 2 hours only when no issues remain" would
# be the untested half of the same branch.
HOME_E="$TMP/home-e"
FAKEBIN_E="$TMP/bin-e"
mkdir -p "$HOME_E/state" "$HOME_E/data" "$HOME_E/projects/app" "$FAKEBIN_E"
cat > "$HOME_E/data/projects.md" <<'EOF'
- app [no-mistakes +yolo] - Test application (added 2026-07-24)
EOF
git -C "$HOME_E/projects/app" init -q
git -C "$HOME_E/projects/app" remote add origin https://github.com/acme/app.git
cat > "$FAKEBIN_E/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1 $2" in
  "issue list") printf '[]\n' ;;
  "pr list") printf '[]\n' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKEBIN_E/gh"

OUT_E="$TMP/out-e.json"
PATH="$FAKEBIN_E:$PATH" \
  FM_HOME="$HOME_E" \
  FM_RECONCILE_NOW="2026-07-24T12:00:00Z" \
  FM_RECONCILE_NOW_EPOCH=1784894400 \
  FM_PROCESS_OLD_SECS=999999999 \
  "$ROOT/bin/fm-reconcile.sh" --tick --json > "$OUT_E"
jq -e '.counts.open == 0 and .counts.open_prs == 0 and .counts.active_crews == 0
  and .counts.active_leases == 0 and .counts.validations == 0' "$OUT_E" >/dev/null \
  || fail "the finished fleet was not inventoried as empty"
jq -e '.next_interval_seconds == 7200' "$OUT_E" >/dev/null \
  || fail "a fleet with no open or active work did not select the 2-hour cadence"
jq -e '.health.state == "idle-complete"' "$OUT_E" >/dev/null \
  || fail "a fleet with no open or active work was not reported idle-complete"
jq -e '.ack.required == false and .ack.token == null' "$OUT_E" >/dev/null \
  || fail "a finished fleet demanded an acknowledgement with nothing to acknowledge"
[ ! -e "$HOME_E/state/reconcile/pending" ] \
  || fail "a finished fleet latched a reconciliation wake"
jq -e '.next_due_epoch == 1784901600' "$OUT_E" >/dev/null \
  || fail "the 2-hour cadence did not schedule the next tick 7200s out"

# The scheduler must actually hold that cadence: a tick arriving inside the
# window is local-only, so the supervisor may poll it often. A gh that records
# every call proves the quiet fleet costs no GitHub request until 7200s elapse.
GH_CALLS="$TMP/gh-calls-e.log"
: > "$GH_CALLS"
cat > "$FAKEBIN_E/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_TEST_GH_CALLS"
case "$1 $2" in
  "issue list") printf '[]\n' ;;
  "pr list") printf '[]\n' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKEBIN_E/gh"

tick_e() {  # <epoch> <out>
  PATH="$FAKEBIN_E:$PATH" \
    FM_HOME="$HOME_E" \
    FM_TEST_GH_CALLS="$GH_CALLS" \
    FM_RECONCILE_NOW_EPOCH="$1" \
    FM_PROCESS_OLD_SECS=999999999 \
    "$ROOT/bin/fm-reconcile.sh" --tick --json > "$2"
}

tick_e 1784901599 "$TMP/out-e2.json"
jq -e '.tick == "not-due"' "$TMP/out-e2.json" >/dev/null \
  || fail "a tick one second inside the 2-hour window was treated as due"
[ ! -s "$GH_CALLS" ] \
  || fail "a not-due tick still reached GitHub ($(cat "$GH_CALLS"))"

tick_e 1784901600 "$TMP/out-e3.json"
jq -e '.tick == "executed"' "$TMP/out-e3.json" >/dev/null \
  || fail "the tick due exactly 7200s later did not run"
grep -F 'issue list' "$GH_CALLS" >/dev/null \
  || fail "the due tick did not re-inventory open issues"
pass "an empty fleet with no open or active work falls back to the 2-hour cadence"

# --- durable leases are cross-checked against live task ids ----------------
HOME_C="$TMP/home-c"
FAKEBIN_C="$TMP/bin-c"
mkdir -p "$HOME_C/state/reconcile/leases" "$HOME_C/data" "$HOME_C/projects/app" "$FAKEBIN_C"
cat > "$HOME_C/data/projects.md" <<'EOF'
- app [no-mistakes +yolo] - Test application (added 2026-07-24)
EOF
git -C "$HOME_C/projects/app" init -q
git -C "$HOME_C/projects/app" remote add origin https://github.com/acme/app.git
cat > "$FAKEBIN_C/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1 $2" in
  "issue list")
    printf '%s\n' '[{"number":7,"title":"Finish the work","url":"https://github.com/acme/app/issues/7","labels":[{"name":"in-progress"}],"createdAt":"2026-07-20T00:00:00Z","updatedAt":"2026-07-20T00:00:00Z"}]'
    ;;
  "pr list") printf '[]\n' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKEBIN_C/gh"
printf '%s\n' '{"repo":"acme/app","number":7,"task":"task-dead","project":"app"}' \
  > "$HOME_C/state/reconcile/leases/acme_app-7.json"

reconcile_c() {  # <out> <epoch>
  PATH="$FAKEBIN_C:$PATH" \
    FM_HOME="$HOME_C" \
    FM_RECONCILE_NOW="2026-07-24T12:00:00Z" \
    FM_RECONCILE_NOW_EPOCH="$2" \
    FM_PROCESS_OLD_SECS=999999999 \
    "$ROOT/bin/fm-reconcile.sh" --tick --force --json > "$1"
}

OUT_C="$TMP/out-c.json"
reconcile_c "$OUT_C" 1784894400
jq -e '.leases[0].owner_live == false and .leases[0].orphaned == true' "$OUT_C" >/dev/null \
  || fail "a lease whose task no longer exists was trusted as a live owner"
jq -e '.counts.orphaned_leases == 1 and .counts.active_leases == 0' "$OUT_C" >/dev/null \
  || fail "dead-owner lease was not counted as orphaned"
jq -e '.counts.orphaned == 1 and .issues[0].orphaned == true' "$OUT_C" >/dev/null \
  || fail "an in-progress issue held only by a dead-owner lease was not reported orphaned"
jq -e '.next_interval_seconds == 600' "$OUT_C" >/dev/null \
  || fail "an orphaned lease did not select the 10-minute cadence"

printf 'issue_repo=acme/app\nissue_number=7\nproject=app\n' > "$HOME_C/state/task-dead.meta"
OUT_C2="$TMP/out-c2.json"
reconcile_c "$OUT_C2" 1784895400
jq -e '.leases[0].owner_live == true and .leases[0].orphaned == false' "$OUT_C2" >/dev/null \
  || fail "a lease with a live task id was still reported as a dead owner"
jq -e '.counts.orphaned_leases == 0 and .counts.orphaned == 0' "$OUT_C2" >/dev/null \
  || fail "a live-owner lease was still counted as orphaned"
pass "issue leases are cross-checked against live task ids, not trusted alone"

# --- heavyweight process ownership -----------------------------------------
# ps and uname are shadowed for these invocations only: BSD ps has no elapsed
# seconds column, so the old-unowned path is only reachable through a simulated
# Linux table.
HOME_D="$TMP/home-d"
FAKEBIN_D="$TMP/bin-d"
mkdir -p "$HOME_D/state" "$FAKEBIN_D"
cat > "$FAKEBIN_D/uname" <<'EOF'
#!/bin/sh
printf 'Linux\n'
EOF
cat > "$FAKEBIN_D/ps" <<'EOF'
#!/bin/sh
cat "$FM_TEST_PS_TABLE"
EOF
chmod +x "$FAKEBIN_D/uname" "$FAKEBIN_D/ps"
PS_TABLE="$TMP/ps-table.txt"
cat > "$PS_TABLE" <<'EOF'
 4100     1 90000 bash /bin/bash /srv/wt/task-7/run.sh
 4102  4100 28900 chrome /opt/google/chrome/chrome --type=renderer
 4210  4300 32400 node /usr/bin/node /srv/app/node_modules/.bin/next dev
 4300     1 40000 bash /bin/bash --login
 4315     1 36000 node /usr/bin/node /usr/lib/cypress/bin/cypress run
 4500     1 40000 node /usr/bin/node cypress run --project /srv/wt/task-7 --config /srv/wt/task-9
 4600     1 50000 bash /bin/bash
 4700     1 50000 node /usr/bin/node chrome-devtools-mcp --port 1 /fm/bin/fm-supervise-daemon.sh
EOF
printf 'worktree=/srv/wt/task-7\n' > "$HOME_D/state/task-7.meta"
printf 'worktree=/srv/wt/task-9\n' > "$HOME_D/state/task-9.meta"

inventory() {  # <table-file>
  PATH="$FAKEBIN_D:$PATH" \
    FM_HOME="$HOME_D" \
    FM_TEST_PS_TABLE="$1" \
    "$ROOT/bin/fm-process-inventory.sh"
}

PROC_OUT="$TMP/processes.json"
inventory "$PS_TABLE" > "$PROC_OUT"
jq -e '.counts.next == 1' "$PROC_OUT" >/dev/null \
  || fail "a 'next dev' process was never classified"
jq -e '[.old_unowned[].pid] == [4210, 4315]' "$PROC_OUT" >/dev/null \
  || fail "old unowned cleanup candidates were not exactly the abandoned next and cypress processes"
jq -e '.counts.old_unowned == 2' "$PROC_OUT" >/dev/null \
  || fail "old unowned count did not match the cleanup candidate list"
jq -e '.counts.owned == 1 and .counts.ambiguous == 1 and .counts.protected == 1' "$PROC_OUT" >/dev/null \
  || fail "ownership classes were not resolved into owned, ambiguous, and protected"

# Each protected class is then isolated, so the combined counts above cannot hide
# which process was excluded for which reason.
CASE_TABLE="$TMP/ps-case.txt"

cat > "$CASE_TABLE" <<'EOF'
 4100     1 90000 bash /bin/bash /srv/wt/task-7/run.sh
 4102  4100 28900 chrome /opt/google/chrome/chrome --type=renderer
EOF
inventory "$CASE_TABLE" > "$PROC_OUT"
jq -e '.counts.owned == 1 and .counts.old_unowned == 0' "$PROC_OUT" >/dev/null \
  || fail "an old chrome child did not inherit ownership from its crew parent"

cat > "$CASE_TABLE" <<'EOF'
 4500     1 40000 node /usr/bin/node cypress run --project /srv/wt/task-7 --config /srv/wt/task-9
EOF
inventory "$CASE_TABLE" > "$PROC_OUT"
jq -e '.counts.ambiguous == 1 and .counts.old_unowned == 0' "$PROC_OUT" >/dev/null \
  || fail "a process matching two worktrees was offered for cleanup instead of held as ambiguous"

cat > "$CASE_TABLE" <<'EOF'
 4700     1 50000 node /usr/bin/node chrome-devtools-mcp --port 1 /fm/bin/fm-supervise-daemon.sh
EOF
inventory "$CASE_TABLE" > "$PROC_OUT"
jq -e '.counts.protected == 1 and .counts.old_unowned == 0' "$PROC_OUT" >/dev/null \
  || fail "a supervision-plane process was offered for cleanup"

cat > "$CASE_TABLE" <<EOF
 4900     1 50000 node $HOME_D/bin/fm-launcher --with cypress
EOF
inventory "$CASE_TABLE" > "$PROC_OUT"
jq -e '.counts.protected == 1' "$PROC_OUT" >/dev/null \
  || fail "this home's own command surface was not protected"

# Crew worktrees live under the home, so protecting the command surface must not
# protect the whole home and silently retire the cleanup surface.
cat > "$CASE_TABLE" <<EOF
 4950     1 50000 node /usr/bin/node cypress run --project $HOME_D/projects/app
EOF
inventory "$CASE_TABLE" > "$PROC_OUT"
jq -e '.counts.old_unowned == 1' "$PROC_OUT" >/dev/null \
  || fail "an abandoned process under the home was protected instead of offered for cleanup"
pass "heavyweight processes inherit ownership through the parent chain, and ambiguous or supervision processes are never cleanup candidates"
