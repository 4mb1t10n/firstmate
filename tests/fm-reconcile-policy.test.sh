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

# The lease is renewable by its own owner: re-reserving returns the existing
# lease unchanged and re-labels nothing, so a crew that reconciles repeatedly
# cannot churn the issue or lose its original reservation time.
RESERVED_AT=$(jq -r '.reserved_at' "$STATE/reconcile/leases/acme_app-7.json")
ADD_LABEL_CALLS=$(grep -c -- '--add-label in-progress' "$GH_LOG")
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_TEST_GH_LOG="$GH_LOG" \
  "$ROOT/bin/fm-issue-lease.sh" reserve acme/app#7 task-7 app >/dev/null \
  || fail "the owning task could not renew its own lease"
jq -e --arg at "$RESERVED_AT" '.task == "task-7" and .reserved_at == $at' \
  "$STATE/reconcile/leases/acme_app-7.json" >/dev/null \
  || fail "renewing a lease rewrote the original reservation"
[ "$(grep -c -- '--add-label in-progress' "$GH_LOG")" -eq "$ADD_LABEL_CALLS" ] \
  || fail "renewing an existing lease re-applied the remote in-progress label"

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

HEAD_AT=2026-07-24T10:00:00Z
# A fully gated PR, rewritten before each case so every refusal below has
# exactly one cause and a passing case can never be a leftover mutation.
write_pr_view() {
  cat > "$PR_VIEW" <<EOF
{
  "number": 8,
  "url": "https://github.com/acme/app/pull/8",
  "state": "OPEN",
  "baseRefName": "stg",
  "headRefOid": "$HEAD_SHA",
  "mergeable": "MERGEABLE",
  "commits": [
    {"oid":"0000000000000000","committedDate":"2026-07-23T09:00:00Z"},
    {"oid":"$HEAD_SHA","committedDate":"$HEAD_AT"}
  ],
  "statusCheckRollup": [
    {"name":"Migration Drift / stg","status":"COMPLETED","conclusion":"SUCCESS"},
    {"name":"Cypress E2E","status":"COMPLETED","conclusion":"SUCCESS"},
    {"name":"Typecheck","status":"COMPLETED","conclusion":"SUCCESS"}
  ],
  "reviews": [
    {"author":{"login":"greptile-apps"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 5/5"}
  ],
  "comments": []
}
EOF
}
write_pr_view

# Rewrite only the review evidence, so every Greptile case runs against an
# otherwise fully gated PR and the refusal can have no other cause.
set_reviews() {
  jq --argjson reviews "$1" '.reviews = $reviews | .comments = []' "$PR_VIEW" > "$PR_VIEW.tmp"
  mv "$PR_VIEW.tmp" "$PR_VIEW"
}

try_merge() {
  : > "$GH_AXI_LOG"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_TEST_GH_LOG="$GH_LOG" FM_TEST_GH_AXI_LOG="$GH_AXI_LOG" FM_TEST_PR_VIEW="$PR_VIEW" \
    "$ROOT/bin/fm-pr-auto-merge.sh" task-7 https://github.com/acme/app/pull/8 >/dev/null 2>&1
}

try_merge || fail "fully gated PR was not merged"
grep -F 'pr merge 8 --repo acme/app --squash --delete-branch' "$GH_AXI_LOG" >/dev/null \
  || fail "fully gated PR was not merged"

set_reviews '[{"author":{"login":"greptile-apps"},"submittedAt":"2026-07-23T09:30:00Z","body":"Quality score: 5/5"}]'
if try_merge; then fail "a 5/5 predating the current head authorized the merge"; fi
[ ! -s "$GH_AXI_LOG" ] || fail "stale Greptile evidence still invoked merge"

set_reviews '[{"author":{"login":"helpful-bot"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 5/5"}]'
if try_merge; then fail "a Greptile lookalike author authorized the merge"; fi

set_reviews '[{"author":{"login":"greptile-apps"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 4/5"}]'
if try_merge; then fail "a 4/5 Greptile score authorized the merge"; fi

set_reviews '[
  {"author":{"login":"greptile-apps"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 5/5"},
  {"author":{"login":"greptile-apps"},"submittedAt":"2026-07-24T12:00:00Z","body":"Quality score: 3/5"}
]'
if try_merge; then fail "a superseded 5/5 authorized the merge"; fi

set_reviews '[{"author":{"login":"greptile-apps"},"submittedAt":"2026-07-24T11:00:00Z","body":"Reads like a 5/5 change to me, but I cannot score it."}]'
if try_merge; then fail "incidental 5/5 prose authorized the merge without a score field"; fi

set_reviews '[{"author":{"login":"greptile-apps"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 5/5"}]'
try_merge || fail "restored current 5/5 evidence did not merge"

pass "automatic merge requires the latest Greptile score field, posted after the head commit, to be exactly 5/5"

jq 'del(.statusCheckRollup[] | select(.name == "Cypress E2E"))' "$PR_VIEW" > "$PR_VIEW.tmp"
mv "$PR_VIEW.tmp" "$PR_VIEW"
if try_merge; then
  fail "PR without Cypress was allowed to auto-merge"
fi
[ ! -s "$GH_AXI_LOG" ] || fail "missing Cypress still invoked merge"

jq '.statusCheckRollup += [{"name":"Cypress E2E","status":"COMPLETED","conclusion":"FAILURE"}]' \
  "$PR_VIEW" > "$PR_VIEW.tmp"
mv "$PR_VIEW.tmp" "$PR_VIEW"
if try_merge; then
  fail "failed Cypress was allowed to auto-merge"
fi

# Each remaining required gate is refused on its own. Cypress and Greptile were
# covered above; Migration Drift, conflict-freedom, and exact-head No Mistakes
# evidence are equally mandatory, so each one is removed from an otherwise
# mergeable PR and must refuse by itself.
mutate_pr_view() {  # <jq-program>
  write_pr_view
  jq "$1" "$PR_VIEW" > "$PR_VIEW.tmp"
  mv "$PR_VIEW.tmp" "$PR_VIEW"
}

write_pr_view
try_merge || fail "the restored baseline PR was not mergeable"

mutate_pr_view 'del(.statusCheckRollup[] | select(.name == "Migration Drift / stg"))'
if try_merge; then fail "PR without Migration Drift was allowed to auto-merge"; fi
[ ! -s "$GH_AXI_LOG" ] || fail "missing Migration Drift still invoked merge"

mutate_pr_view '.statusCheckRollup |= map(
  if .name == "Migration Drift / stg" then .conclusion = "FAILURE" else . end)'
if try_merge; then fail "failing Migration Drift was allowed to auto-merge"; fi

mutate_pr_view '.mergeable = "CONFLICTING"'
if try_merge; then fail "a conflicted PR was allowed to auto-merge"; fi
[ ! -s "$GH_AXI_LOG" ] || fail "a conflicted PR still invoked merge"

# The recorded evidence names one exact commit, so a PR that gained a commit
# after validation has no complete No Mistakes run for what would be merged.
mutate_pr_view '.headRefOid = "999999999999cafe"
  | .commits += [{"oid":"999999999999cafe","committedDate":"2026-07-24T13:00:00Z"}]'
if try_merge; then fail "a head commit with no No Mistakes evidence was auto-merged"; fi
[ ! -s "$GH_AXI_LOG" ] || fail "stale No Mistakes evidence still invoked merge"

write_pr_view
if PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_TEST_GH_LOG="$GH_LOG" FM_TEST_GH_AXI_LOG="$GH_AXI_LOG" FM_TEST_PR_VIEW="$PR_VIEW" \
    "$ROOT/bin/fm-pr-auto-merge.sh" task-unvalidated https://github.com/acme/app/pull/8 \
    >/dev/null 2>&1; then
  fail "a task with no No Mistakes evidence at all was auto-merged"
fi

pass "automatic merge requires exact No Mistakes evidence and every mandatory green gate"
