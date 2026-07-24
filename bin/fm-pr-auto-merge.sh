#!/usr/bin/env bash
# Fail-closed automatic feature-to-stg merge gate.
#
# Requires exact-head No Mistakes evidence, Greptile 5/5, present and passing
# Migration Drift and Cypress checks, every reported CI check green, a clean
# mergeable PR, and stg as the base branch.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TASK=${1:?usage: fm-pr-auto-merge.sh <task-id> <pr-url>}
PR_URL=${2:?usage: fm-pr-auto-merge.sh <task-id> <pr-url>}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# Both arguments are validated before either one is used: the task id addresses
# the evidence file that anchors this gate's trust, and the PR reference reaches
# gh only as a parsed number and owner/repository pair.
case "$TASK" in *[!A-Za-z0-9._-]*|'') printf 'fm-pr-auto-merge: invalid task id\n' >&2; exit 2 ;; esac
fm_pr_url_parse "$PR_URL" || { printf 'fm-pr-auto-merge: invalid GitHub PR URL\n' >&2; exit 2; }
[ "$FM_PR_PROVIDER" = github ] || { printf 'fm-pr-auto-merge: automatic merge supports GitHub only\n' >&2; exit 2; }
EVIDENCE="$STATE/reconcile/validation/$TASK.json"

command -v jq >/dev/null 2>&1 || { printf 'fm-pr-auto-merge: jq not found\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'fm-pr-auto-merge: gh not found\n' >&2; exit 1; }
command -v gh-axi >/dev/null 2>&1 || { printf 'fm-pr-auto-merge: gh-axi not found\n' >&2; exit 1; }
[ -s "$EVIDENCE" ] || {
  printf 'fm-pr-auto-merge: missing complete No Mistakes evidence for %s\n' "$TASK" >&2
  exit 1
}

view=$(gh pr view "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" \
  --json number,url,state,baseRefName,headRefOid,mergeable,statusCheckRollup,reviews,comments,commits)
state=$(printf '%s' "$view" | jq -r '.state')
base=$(printf '%s' "$view" | jq -r '.baseRefName')
head=$(printf '%s' "$view" | jq -r '.headRefOid')
mergeable=$(printf '%s' "$view" | jq -r '.mergeable')
evidence_head=$(jq -r '.head_sha // empty' "$EVIDENCE")
evidence_result=$(jq -r '.no_mistakes // empty' "$EVIDENCE")

[ "$state" = OPEN ] || { printf 'fm-pr-auto-merge: PR is not open\n' >&2; exit 1; }
[ "$base" = stg ] || { printf 'fm-pr-auto-merge: automatic merge requires stg base, found %s\n' "$base" >&2; exit 1; }
[ "$mergeable" = MERGEABLE ] || { printf 'fm-pr-auto-merge: PR is not cleanly mergeable (%s)\n' "$mergeable" >&2; exit 1; }
[ "$evidence_result" = passed ] && [ "$evidence_head" = "$head" ] || {
  printf 'fm-pr-auto-merge: No Mistakes evidence does not match current PR head\n' >&2
  exit 1
}

checks=$(printf '%s' "$view" | jq '
  [.statusCheckRollup[]? | {
    name:(.name // .context // ""),
    status:(.status // ""),
    conclusion:(.conclusion // "")
  }]
')
check_count=$(printf '%s' "$checks" | jq 'length')
[ "$check_count" -gt 0 ] || { printf 'fm-pr-auto-merge: PR has no CI checks\n' >&2; exit 1; }

non_green=$(printf '%s' "$checks" | jq '[.[] | select(.conclusion != "SUCCESS")] | length')
[ "$non_green" -eq 0 ] || {
  printf 'fm-pr-auto-merge: every CI check must be green\n' >&2
  printf '%s\n' "$checks" | jq -r '.[] | select(.conclusion != "SUCCESS") | "  \(.name): status=\(.status) conclusion=\(.conclusion)"' >&2
  exit 1
}

has_migration=$(printf '%s' "$checks" | jq '[.[] | select(.name | test("migration[ _-]*drift"; "i"))] | length')
has_cypress=$(printf '%s' "$checks" | jq '[.[] | select(.name | test("cypress"; "i"))] | length')
[ "$has_migration" -gt 0 ] || { printf 'fm-pr-auto-merge: required Migration Drift check is missing\n' >&2; exit 1; }
[ "$has_cypress" -gt 0 ] || { printf 'fm-pr-auto-merge: required Cypress check is missing\n' >&2; exit 1; }

# Greptile's verdict only counts for the code being merged, so the score is read
# from the latest Greptile review or comment posted after the current head
# commit. A score from an earlier revision is stale evidence, not approval.
head_committed_at=$(printf '%s' "$view" | jq -r --arg head "$head" '
  [.commits[]? | select((.oid // "") == $head) | (.committedDate // "")]
  | map(select(. != "")) | first // ""
')
[ -n "$head_committed_at" ] || {
  printf 'fm-pr-auto-merge: current PR head has no dated commit to date Greptile against\n' >&2
  exit 1
}

greptile_body=$(printf '%s' "$view" | jq -r --arg since "$head_committed_at" '
  [
    (.reviews[]? | {at:(.submittedAt // ""), body:(.body // ""), login:(.author.login // "")}),
    (.comments[]? | {at:(.createdAt // ""), body:(.body // ""), login:(.author.login // "")})
  ]
  | map(select((.login | test("greptile"; "i")) and .at > $since))
  | sort_by(.at)
  | last
  | if . == null then "" else .body end
')
[ -n "$greptile_body" ] || {
  printf 'fm-pr-auto-merge: no Greptile review posted after the current head commit\n' >&2
  exit 1
}

# The verdict must be Greptile's own score field, so prose that merely contains
# "5/5" cannot authorize a merge and any non-5 score refuses.
score_fields=$(printf '%s\n' "$greptile_body" | tr -d '\r' \
  | grep -Eio '^[^0-9]*score[^0-9]*[0-9]+(\.[0-9]+)?[[:space:]]*/[[:space:]]*5' || true)
[ -n "$score_fields" ] || {
  printf 'fm-pr-auto-merge: latest Greptile review has no score field\n' >&2
  exit 1
}
if printf '%s\n' "$score_fields" | grep -Eqv '[^0-9]5[[:space:]]*/[[:space:]]*5$'; then
  printf 'fm-pr-auto-merge: Greptile score is not exactly 5/5\n' >&2
  printf '%s\n' "$score_fields" >&2
  exit 1
fi

# Every task PR merge lands through bin/fm-pr-merge.sh (AGENTS.md section 7),
# which records the canonical pr= and the forge's pr_head= before merging so
# bin/fm-teardown.sh can still verify landed work after the squash. Calling
# gh-axi directly here merged around that recording and left an auto-merged task
# with no PR reference to verify against.
#
# This delegation is the whole authority for the call and it is deliberately
# narrow: it is reached only on the one gated-stg path above, after this gate has
# already proven stg base, conflict-free mergeability, exact-head No Mistakes
# evidence, an exactly-5/5 post-head Greptile score, present and passing
# Migration Drift and Cypress, and every reported check green. It grants no
# standing automatic merge to any other caller and changes nothing about the
# routine paths, where the captain's explicit word or `yolo` remains the only
# authority to merge (AGENTS.md section 7).
"$SCRIPT_DIR/fm-pr-merge.sh" "$TASK" "$FM_PR_URL" -- --squash --delete-branch
