#!/usr/bin/env bash
# Issue-lease and automatic-merge fail-closed policy tests.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-reconcile-policy.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
FAKEBIN="$TMP/bin"
mkdir -p "$STATE" "$FAKEBIN"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$1 $2" in
  "label create") exit 0 ;;
  "issue edit") exit 0 ;;
  "pr view") cat "$FM_TEST_PR_VIEW" ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
cat > "$FAKEBIN/gh-axi" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
EOF
chmod +x "$FAKEBIN/gh" "$FAKEBIN/gh-axi"

GH_LOG="$TMP/gh.log"
GH_AXI_LOG="$TMP/gh-axi.log"
PR_VIEW="$TMP/pr.json"
: > "$GH_LOG"
: > "$GH_AXI_LOG"

PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_TEST_GH_LOG="$GH_LOG" \
  "$ROOT/bin/fm-issue-lease.sh" reserve acme/app#7 task-7 app >/dev/null
grep -F 'label create in-progress --repo acme/app' "$GH_LOG" >/dev/null \
  || fail "reserve did not ensure the in-progress label exists"
grep -F 'issue edit 7 --repo acme/app --add-label in-progress' "$GH_LOG" >/dev/null \
  || fail "reserve did not apply in-progress"
jq -e '.repo == "acme/app" and .number == 7 and .task == "task-7"' \
  "$STATE/reconcile/leases/acme_app-7.json" >/dev/null \
  || fail "reserve did not persist the lease"

if PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_TEST_GH_LOG="$GH_LOG" \
    "$ROOT/bin/fm-issue-lease.sh" reserve acme/app#7 other-task app >/dev/null 2>&1; then
  fail "duplicate task acquired an existing issue lease"
fi

PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_TEST_GH_LOG="$GH_LOG" \
  "$ROOT/bin/fm-issue-lease.sh" release acme/app#7 task-7 resolved >/dev/null
grep -F 'issue edit 7 --repo acme/app --remove-label in-progress' "$GH_LOG" >/dev/null \
  || fail "release did not remove in-progress"
[ ! -e "$STATE/reconcile/leases/acme_app-7.json" ] \
  || fail "release retained the active lease"
pass "in-progress is an exclusive durable issue lease"

HEAD_SHA=abcdef1234567890
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-validation-record.sh" task-7 "$HEAD_SHA" run-1 >/dev/null

cat > "$PR_VIEW" <<EOF
{
  "number": 8,
  "url": "https://github.com/acme/app/pull/8",
  "state": "OPEN",
  "baseRefName": "stg",
  "headRefOid": "$HEAD_SHA",
  "mergeable": "MERGEABLE",
  "statusCheckRollup": [
    {"name":"Migration Drift / stg","status":"COMPLETED","conclusion":"SUCCESS"},
    {"name":"Cypress E2E","status":"COMPLETED","conclusion":"SUCCESS"},
    {"name":"Typecheck","status":"COMPLETED","conclusion":"SUCCESS"}
  ],
  "reviews": [
    {"author":{"login":"greptile-apps"},"body":"Quality score: 5/5"}
  ],
  "comments": []
}
EOF

PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
  FM_TEST_GH_LOG="$GH_LOG" FM_TEST_GH_AXI_LOG="$GH_AXI_LOG" FM_TEST_PR_VIEW="$PR_VIEW" \
  "$ROOT/bin/fm-pr-auto-merge.sh" task-7 https://github.com/acme/app/pull/8
grep -F 'pr merge 8 --repo acme/app --squash --delete-branch' "$GH_AXI_LOG" >/dev/null \
  || fail "fully gated PR was not merged"

jq 'del(.statusCheckRollup[] | select(.name == "Cypress E2E"))' "$PR_VIEW" > "$PR_VIEW.tmp"
mv "$PR_VIEW.tmp" "$PR_VIEW"
: > "$GH_AXI_LOG"
if PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_TEST_GH_LOG="$GH_LOG" FM_TEST_GH_AXI_LOG="$GH_AXI_LOG" FM_TEST_PR_VIEW="$PR_VIEW" \
    "$ROOT/bin/fm-pr-auto-merge.sh" task-7 https://github.com/acme/app/pull/8 >/dev/null 2>&1; then
  fail "PR without Cypress was allowed to auto-merge"
fi
[ ! -s "$GH_AXI_LOG" ] || fail "missing Cypress still invoked merge"

jq '.statusCheckRollup += [{"name":"Cypress E2E","status":"COMPLETED","conclusion":"FAILURE"}]' \
  "$PR_VIEW" > "$PR_VIEW.tmp"
mv "$PR_VIEW.tmp" "$PR_VIEW"
if PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_TEST_GH_LOG="$GH_LOG" FM_TEST_GH_AXI_LOG="$GH_AXI_LOG" FM_TEST_PR_VIEW="$PR_VIEW" \
    "$ROOT/bin/fm-pr-auto-merge.sh" task-7 https://github.com/acme/app/pull/8 >/dev/null 2>&1; then
  fail "failed Cypress was allowed to auto-merge"
fi

pass "automatic merge requires exact No Mistakes evidence and every mandatory green gate"
