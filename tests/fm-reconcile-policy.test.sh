#!/usr/bin/env bash
# Issue-lease and merge-readiness fail-closed policy tests.
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

HEAD_SHA=abcdef1234567890abcdef1234567890abcdef12
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-validation-record.sh" task-7 "$HEAD_SHA" run-1 >/dev/null

# The readiness report is the whole product. The task carries the same real meta
# any PR task has, so the assertions below can prove the report never records
# the pr=/pr_head= metadata that only a merge path writes.
WORKTREE="$TMP/wt-task-7"
mkdir -p "$WORKTREE"
cat > "$STATE/task-7.meta" <<EOF
window=fm-task-7
worktree=$WORKTREE
project=$WORKTREE
kind=ship
mode=no-mistakes
EOF
chmod 0600 "$STATE/task-7.meta"

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
    {"author":{"login":"greptile-apps[bot]"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 5/5"}
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

REPORT="$TMP/readiness.txt"

# Both forge logs are truncated per assessment, so every assertion reads only
# the calls that one run made.
assess_readiness() {  # [task-id]
  : > "$GH_AXI_LOG"
  : > "$GH_LOG"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_TEST_GH_LOG="$GH_LOG" FM_TEST_GH_AXI_LOG="$GH_AXI_LOG" FM_TEST_PR_VIEW="$PR_VIEW" \
    "$ROOT/bin/fm-pr-merge-readiness.sh" "${1:-task-7}" https://github.com/acme/app/pull/8 \
    > "$REPORT" 2>&1
}

# No readiness result is merge authority, so no run may reach a merge on any
# path: gh-axi is how bin/fm-pr-merge.sh lands a PR, `gh pr merge` is the
# lower-level path around it, and recorded pr= metadata is the trace either one
# would leave behind.
assert_nothing_merged() {  # <case>
  [ ! -s "$GH_AXI_LOG" ] || fail "$1: a merge command was invoked through gh-axi"
  if grep -qE 'pr (merge|review)' "$GH_LOG"; then
    fail "$1: a merge or approval command was invoked through gh"
  fi
  if grep -qE '^(pr|pr_head)=' "$STATE"/*.meta; then
    fail "$1: PR merge metadata was recorded, so a merge path ran"
  fi
}

# A refusal must fail and name the condition that refused, so a not-merge-ready
# report is actionable rather than a bare non-zero exit.
refuses() {  # <cause> <case> [task-id]
  if assess_readiness "${3:-task-7}"; then fail "$2: reported merge-ready"; fi
  grep -F "not merge-ready: $1" "$REPORT" >/dev/null \
    || fail "$2: refusal did not name its cause"
  assert_nothing_merged "$2"
}

assess_readiness || fail "fully gated PR was not reported merge-ready"
grep -E "^fm-pr-merge-readiness: merge-ready: https://github.com/acme/app/pull/8 at $HEAD_SHA\$" \
  "$REPORT" >/dev/null || fail "merge-ready report did not name the PR and the head it covers"
assert_nothing_merged "fully gated PR"
pass "a fully gated PR is reported merge-ready and nothing is merged"

set_reviews '[{"author":{"login":"greptile-apps[bot]"},"submittedAt":"2026-07-23T09:30:00Z","body":"Quality score: 5/5"}]'
refuses 'no Greptile review posted after the current head commit' \
  "a 5/5 predating the current head"

set_reviews '[{"author":{"login":"helpful-bot"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 5/5"}]'
refuses 'no Greptile review posted after the current head commit' \
  "a Greptile lookalike author"

set_reviews '[{"author":{"login":"my-greptile-bot"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 5/5"}]'
refuses 'no Greptile review posted after the current head commit' \
  "a login containing greptile"

set_reviews '[{"author":{"login":"greptile-apps[bot]"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 4/5"}]'
refuses 'Greptile score is not exactly 5/5' "a 4/5 Greptile score"

set_reviews '[
  {"author":{"login":"greptile-apps[bot]"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 5/5"},
  {"author":{"login":"greptile-apps[bot]"},"submittedAt":"2026-07-24T12:00:00Z","body":"Quality score: 3/5"}
]'
refuses 'Greptile score is not exactly 5/5' "a superseded 5/5"

set_reviews '[{"author":{"login":"greptile-apps[bot]"},"submittedAt":"2026-07-24T11:00:00Z","body":"Reads like a 5/5 change to me, but I cannot score it."}]'
refuses 'latest Greptile review has no score field' "incidental 5/5 prose"

set_reviews '[{"author":{"login":"greptile-apps[bot]"},"submittedAt":"2026-07-24T11:00:00Z","body":"Quality score: 5/5"}]'
assess_readiness || fail "restored current 5/5 evidence was not reported merge-ready"

pass "merge readiness requires the latest Greptile score field, posted after the head commit, to be exactly 5/5"

# Each required gate is refused on its own, so no single missing or failing
# condition can be carried by the others.
mutate_pr_view() {  # <jq-program>
  write_pr_view
  jq "$1" "$PR_VIEW" > "$PR_VIEW.tmp"
  mv "$PR_VIEW.tmp" "$PR_VIEW"
}

write_pr_view
assess_readiness || fail "the restored baseline PR was not reported merge-ready"

mutate_pr_view 'del(.statusCheckRollup[] | select(.name == "Cypress E2E"))'
refuses 'required Cypress check is missing' "a PR without Cypress"

mutate_pr_view '.statusCheckRollup += [{"name":"Cypress E2E","status":"COMPLETED","conclusion":"FAILURE"}]'
refuses 'every CI check must be green' "a PR with failing Cypress"

mutate_pr_view 'del(.statusCheckRollup[] | select(.name == "Migration Drift / stg"))'
refuses 'required Migration Drift check is missing' "a PR without Migration Drift"

mutate_pr_view '.statusCheckRollup |= map(
  if .name == "Migration Drift / stg" then .conclusion = "FAILURE" else . end)'
refuses 'every CI check must be green' "a PR with failing Migration Drift"

mutate_pr_view '.mergeable = "CONFLICTING"'
refuses 'PR is not cleanly mergeable (CONFLICTING)' "a conflicted PR"

# This gate describes the feature-to-stg path only. Any other base is outside
# what it can speak to, so it refuses rather than reporting readiness.
mutate_pr_view '.baseRefName = "main"'
refuses 'this gate covers the feature-to-stg path only, found base main' \
  "a PR based on main"

# The recorded evidence names one exact commit, so a PR that gained a commit
# after validation has no complete No Mistakes run for what it now contains.
mutate_pr_view '.headRefOid = "999999999999cafe"
  | .commits += [{"oid":"999999999999cafe","committedDate":"2026-07-24T13:00:00Z"}]'
refuses 'No Mistakes evidence does not match current PR head' \
  "a head commit with no No Mistakes evidence"

write_pr_view
refuses 'missing complete No Mistakes evidence for task-unvalidated' \
  "a task with no No Mistakes evidence at all" task-unvalidated

pass "merge readiness requires exact No Mistakes evidence and every mandatory green gate, naming what refused"

# The product is a report, so no merge or approval invocation may exist on any
# path in the helper, including one guarded by every gate passing.
if grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-pr-merge-readiness.sh" \
    | grep -qE 'pr[[:space:]]+(merge|review)|--auto|--squash|fm-pr-merge\.sh|fm-merge-local\.sh|gh-axi'; then
  fail "the merge-readiness helper contains a merge or approval invocation"
fi
pass "merge readiness reports only: no merge or approval path exists in the helper"
