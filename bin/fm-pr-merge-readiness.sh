#!/usr/bin/env bash
# Fail-closed feature-to-stg merge-readiness report.
#
# Reports whether one PR meets every required condition: exact-head No Mistakes
# evidence, Greptile 5/5, present and passing Migration Drift and Cypress
# checks, every reported CI check green, a clean mergeable PR, and stg as the
# base branch. Any condition that is absent, pending, failing, or unverifiable
# is reported as not merge-ready, naming which one it was.
#
# This script only reports. It never approves a PR, never enables auto-merge,
# and never merges: on this path the merge is the captain's own decision and the
# captain's own action. A merge-ready result is an input to that decision, not
# merge authority, so no future edit may grow an approve, auto-merge, or merge
# call here (docs/reconciliation-heartbeat.md owns the contract).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TASK=${1:?usage: fm-pr-merge-readiness.sh <task-id> <pr-url>}
PR_URL=${2:?usage: fm-pr-merge-readiness.sh <task-id> <pr-url>}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# Every refusal below exits non-zero, so an unassessed or failed condition can
# never be read as readiness.
not_ready() {  # <reason>
  printf 'fm-pr-merge-readiness: not merge-ready: %s\n' "$1" >&2
}

# Both arguments are validated before either one is used: the task id addresses
# the evidence file that anchors this report's trust, and the PR reference
# reaches gh only as a parsed number and owner/repository pair.
case "$TASK" in *[!A-Za-z0-9._-]*|'') printf 'fm-pr-merge-readiness: invalid task id\n' >&2; exit 2 ;; esac
fm_pr_url_parse "$PR_URL" || { printf 'fm-pr-merge-readiness: invalid GitHub PR URL\n' >&2; exit 2; }
[ "$FM_PR_PROVIDER" = github ] || { printf 'fm-pr-merge-readiness: readiness reporting supports GitHub only\n' >&2; exit 2; }
EVIDENCE="$STATE/reconcile/validation/$TASK.json"

command -v jq >/dev/null 2>&1 || { not_ready 'cannot assess, jq not found'; exit 1; }
command -v gh >/dev/null 2>&1 || { not_ready 'cannot assess, gh not found'; exit 1; }
[ -s "$EVIDENCE" ] || {
  not_ready "missing complete No Mistakes evidence for $TASK"
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

[ "$state" = OPEN ] || { not_ready 'PR is not open'; exit 1; }
[ "$base" = stg ] || { not_ready "this gate covers the feature-to-stg path only, found base $base"; exit 1; }
[ "$mergeable" = MERGEABLE ] || { not_ready "PR is not cleanly mergeable ($mergeable)"; exit 1; }
[ "$evidence_result" = passed ] && [ "$evidence_head" = "$head" ] || {
  not_ready 'No Mistakes evidence does not match current PR head'
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
[ "$check_count" -gt 0 ] || { not_ready 'PR has no CI checks'; exit 1; }

non_green=$(printf '%s' "$checks" | jq '[.[] | select(.conclusion != "SUCCESS")] | length')
[ "$non_green" -eq 0 ] || {
  not_ready 'every CI check must be green'
  printf '%s\n' "$checks" | jq -r '.[] | select(.conclusion != "SUCCESS") | "  \(.name): status=\(.status) conclusion=\(.conclusion)"' >&2
  exit 1
}

has_migration=$(printf '%s' "$checks" | jq '[.[] | select(.name | test("migration[ _-]*drift"; "i"))] | length')
has_cypress=$(printf '%s' "$checks" | jq '[.[] | select(.name | test("cypress"; "i"))] | length')
[ "$has_migration" -gt 0 ] || { not_ready 'required Migration Drift check is missing'; exit 1; }
[ "$has_cypress" -gt 0 ] || { not_ready 'required Cypress check is missing'; exit 1; }

# Greptile's verdict only counts for the code that would be merged, so the score
# is read from the latest Greptile review or comment posted after the current
# head commit. A score from an earlier revision is stale evidence, not approval.
head_committed_at=$(printf '%s' "$view" | jq -r --arg head "$head" '
  [.commits[]? | select((.oid // "") == $head) | (.committedDate // "")]
  | map(select(. != "")) | first // ""
')
[ -n "$head_committed_at" ] || {
  not_ready 'current PR head has no dated commit to date Greptile against'
  exit 1
}

greptile_body=$(printf '%s' "$view" | jq -r --arg since "$head_committed_at" \
  --arg login 'greptile-apps[bot]' '
  [
    (.reviews[]? | {at:(.submittedAt // ""), body:(.body // ""), login:(.author.login // "")}),
    (.comments[]? | {at:(.createdAt // ""), body:(.body // ""), login:(.author.login // "")})
  ]
  | map(select(.login == $login and .at > $since))
  | sort_by(.at)
  | last
  | if . == null then "" else .body end
')
[ -n "$greptile_body" ] || {
  not_ready 'no Greptile review posted after the current head commit'
  exit 1
}

# The verdict must be Greptile's own score field, so prose that merely contains
# "5/5" cannot report readiness and any non-5 score refuses.
score_fields=$(printf '%s\n' "$greptile_body" | tr -d '\r' \
  | grep -Eio '^[^0-9]*score[^0-9]*[0-9]+(\.[0-9]+)?[[:space:]]*/[[:space:]]*5' || true)
[ -n "$score_fields" ] || {
  not_ready 'latest Greptile review has no score field'
  exit 1
}
if printf '%s\n' "$score_fields" | grep -Eqv '[^0-9]5[[:space:]]*/[[:space:]]*5$'; then
  not_ready 'Greptile score is not exactly 5/5'
  printf '%s\n' "$score_fields" >&2
  exit 1
fi

printf 'fm-pr-merge-readiness: merge-ready: %s at %s\n' "$FM_PR_URL" "$head"
printf 'fm-pr-merge-readiness: report only - the captain decides and performs the merge.\n'
