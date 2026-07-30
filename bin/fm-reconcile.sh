#!/usr/bin/env bash
# Build and persist the deterministic GitHub reconciliation inventory.
#
# Usage:
#   fm-reconcile.sh --tick [--force] [--json]
#   fm-reconcile.sh --inspect [--json]
#
# --tick obeys the last snapshot's next_due_epoch unless --force is present.
# An actionable tick appends one durable reconcile wake and writes
# state/reconcile/pending, which the normal watcher consumes within one poll.
# The external host supervisor may call --tick frequently because not-due calls
# are local-only and make no GitHub requests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
RECONCILE_DIR="$STATE/reconcile"
LAST="$RECONCILE_DIR/last.json"
ISSUED="$RECONCILE_DIR/issued.json"
ACK="$RECONCILE_DIR/last-ack.json"
PENDING="$RECONCILE_DIR/pending"
LOCK="$RECONCILE_DIR/lock"
NOW="${FM_RECONCILE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
NOW_EPOCH="${FM_RECONCILE_NOW_EPOCH:-$(date +%s)}"
GH_TIMEOUT=${FM_RECONCILE_GH_TIMEOUT:-30}
ISSUE_LIMIT=${FM_RECONCILE_ISSUE_LIMIT:-1000}
PR_LIMIT=${FM_RECONCILE_PR_LIMIT:-500}
ACTIVE_INTERVAL=${FM_RECONCILE_ACTIVE_INTERVAL:-600}
OPEN_IDLE_INTERVAL=${FM_RECONCILE_OPEN_IDLE_INTERVAL:-1800}
COMPLETE_INTERVAL=${FM_RECONCILE_COMPLETE_INTERVAL:-7200}
ACK_GRACE=${FM_RECONCILE_ACK_GRACE:-900}

MODE=tick
FORCE=0
FORMAT=toon
while [ $# -gt 0 ]; do
  case "$1" in
    --tick) MODE=tick ;;
    --inspect) MODE=inspect ;;
    --force) FORCE=1 ;;
    --json) FORMAT=json ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'fm-reconcile: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

case "$NOW_EPOCH" in ''|*[!0-9]*) printf 'fm-reconcile: invalid current epoch\n' >&2; exit 2 ;; esac
for pair in \
  "FM_RECONCILE_ACTIVE_INTERVAL=$ACTIVE_INTERVAL" \
  "FM_RECONCILE_OPEN_IDLE_INTERVAL=$OPEN_IDLE_INTERVAL" \
  "FM_RECONCILE_COMPLETE_INTERVAL=$COMPLETE_INTERVAL" \
  "FM_RECONCILE_ACK_GRACE=$ACK_GRACE" \
  "FM_RECONCILE_GH_TIMEOUT=$GH_TIMEOUT" \
  "FM_RECONCILE_ISSUE_LIMIT=$ISSUE_LIMIT" \
  "FM_RECONCILE_PR_LIMIT=$PR_LIMIT"; do
  value=${pair#*=}
  case "$value" in ''|*[!0-9]*|0) printf 'fm-reconcile: %s must be a positive integer\n' "${pair%%=*}" >&2; exit 2 ;; esac
done

command -v jq >/dev/null 2>&1 || { printf 'fm-reconcile: jq not found\n' >&2; exit 1; }
mkdir -p "$RECONCILE_DIR"
chmod 0700 "$RECONCILE_DIR" 2>/dev/null || true

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

render() {
  if [ "$FORMAT" = json ]; then
    cat
  else
    jq -r '
      "schema: \(.schema)",
      "generated: \(.generated)",
      "health: \(.health.state)",
      "counts: open=\(.counts.open) available=\(.counts.available) in_progress=\(.counts.in_progress) orphaned=\(.counts.orphaned) prs=\(.counts.open_prs) active_crews=\(.counts.active_crews)",
      "next_interval_seconds: \(.next_interval_seconds)",
      "ack_token: \(.ack.token // "none")"
    '
  fi
}

# The due test reads the last snapshot and makes no GitHub request, so it runs
# BEFORE the lock: the frequent not-due supervisor polls must never contend for
# the lock a slow due tick is holding across its inventory.
tick_not_due() {
  local next_due
  [ "$MODE" = tick ] || return 1
  [ "$FORCE" = 0 ] || return 1
  [ -s "$LAST" ] || return 1
  next_due=$(jq -r '.next_due_epoch // 0' "$LAST" 2>/dev/null || printf 0)
  case "$next_due" in ''|*[!0-9]*) next_due=0 ;; esac
  [ "$NOW_EPOCH" -lt "$next_due" ]
}

report_not_due() {
  jq --arg tick not-due '. + {tick:$tick}' "$LAST" | render
}

if tick_not_due; then
  report_not_due
  exit 0
fi

# Acquire before installing any release trap: a losing racer must never free the
# winner's lock. fm_lock_release verifies the recorded holder pid, and
# fm_lock_try_acquire steals a lock whose holder died without releasing it.
if ! fm_lock_try_acquire "$LOCK"; then
  printf 'fm-reconcile: another reconciliation owns %s\n' "$LOCK" >&2
  exit 0
fi
trap 'fm_lock_release "$LOCK" || true' EXIT
trap 'exit 1' INT TERM

# Re-test under the lock: a tick that arrived while the previous holder was
# still inventorying must not immediately repeat the cycle that holder finished.
if tick_not_due; then
  report_not_due
  exit 0
fi

command -v gh >/dev/null 2>&1 || { printf 'fm-reconcile: gh not found\n' >&2; exit 1; }

gh_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 timeout "$GH_TIMEOUT" gh "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gtimeout "$GH_TIMEOUT" gh "$@"
  else
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
  fi
}

repo_slug() {
  printf '%s\n' "$1" \
    | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' \
    | sed 's#\.git$##; s#/$##'
}

registry_projects() {
  [ -f "$DATA/projects.md" ] || return 0
  awk '$1 == "-" && $2 !~ /^\[/ { print $2 }' "$DATA/projects.md"
}

repos='[]'
issues='[]'
prs='[]'
errors='[]'
seen_repos=' '
while IFS= read -r project; do
  [ -n "$project" ] || continue
  project_dir="$PROJECTS/$project"
  if [ ! -d "$project_dir" ]; then
    errors=$(printf '%s' "$errors" | jq --arg project "$project" '. + [{project:$project,error:"project clone missing"}]')
    continue
  fi
  remote=$(git -C "$project_dir" remote get-url origin 2>/dev/null || true)
  slug=$(repo_slug "$remote")
  if [ -z "$slug" ]; then
    errors=$(printf '%s' "$errors" | jq --arg project "$project" '. + [{project:$project,error:"GitHub origin missing"}]')
    continue
  fi
  case "$seen_repos" in *" $slug "*) continue ;; esac
  seen_repos="$seen_repos$slug "
  repos=$(printf '%s' "$repos" | jq --arg project "$project" --arg repo "$slug" '. + [{project:$project,repo:$repo}]')
  if issue_rows=$(gh_bounded issue list --repo "$slug" --state open --limit "$ISSUE_LIMIT" \
      --json number,title,url,labels,createdAt,updatedAt 2>/dev/null); then
    issue_rows=$(printf '%s' "$issue_rows" | jq --arg project "$project" --arg repo "$slug" '
      map(. + {
        project:$project,
        repo:$repo,
        label_names:([.labels[]?.name]),
        lease:(if any(.labels[]?; .name == "in-progress") then "in-progress" else "available" end)
      })
    ')
    issues=$(jq -cn --argjson a "$issues" --argjson b "$issue_rows" '$a + $b')
  else
    errors=$(printf '%s' "$errors" | jq --arg project "$project" --arg repo "$slug" \
      '. + [{project:$project,repo:$repo,error:"open issue inventory failed"}]')
  fi
  if pr_rows=$(gh_bounded pr list --repo "$slug" --state open --limit "$PR_LIMIT" \
      --json number,title,url,headRefName,baseRefName,mergeable,statusCheckRollup,closingIssuesReferences 2>/dev/null); then
    pr_rows=$(printf '%s' "$pr_rows" | jq --arg project "$project" --arg repo "$slug" \
      'map(. + {project:$project,repo:$repo})')
    prs=$(jq -cn --argjson a "$prs" --argjson b "$pr_rows" '$a + $b')
  else
    errors=$(printf '%s' "$errors" | jq --arg project "$project" --arg repo "$slug" \
      '. + [{project:$project,repo:$repo,error:"open PR inventory failed"}]')
  fi
done <<EOF
$(registry_projects)
EOF

tasks='[]'
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  issue_repo=$(awk -F= '$1=="issue_repo" {sub(/^[^=]*=/,""); print; exit}' "$meta")
  issue_number=$(awk -F= '$1=="issue_number" {sub(/^[^=]*=/,""); print; exit}' "$meta")
  project=$(awk -F= '$1=="project" {sub(/^[^=]*=/,""); print; exit}' "$meta")
  tasks=$(printf '%s' "$tasks" | jq \
    --arg id "$id" --arg project "$project" --arg repo "$issue_repo" --arg number "$issue_number" \
    '. + [{id:$id,project:$project,issue_repo:$repo,issue_number:$number}]')
done

live_task_ids=$(printf '%s' "$tasks" | jq -r '.[].id' | tr '\n' ' ')

leases='[]'
for lease in "$RECONCILE_DIR"/leases/*.json; do
  [ -f "$lease" ] || continue
  if lease_row=$(jq -e '
      select(
        (.repo | type) == "string"
        and (.number | type) == "number"
        and (.task | type) == "string"
      )
    ' "$lease" 2>/dev/null); then
    leases=$(jq -cn --argjson a "$leases" --argjson b "$lease_row" '$a + [$b]')
  else
    errors=$(printf '%s' "$errors" | jq --arg path "$lease" \
      '. + [{path:$path,error:"invalid issue lease"}]')
  fi
done

# A lease file is a claim, not proof of an owner: cross-check every lease against
# the live task ids so a lease whose crew died is reported as an orphan to repair
# instead of silently vouching for the remote in-progress label.
leases=$(printf '%s' "$leases" | jq --argjson tasks "$tasks" '
  ($tasks | map(.id)) as $live
  | map(
      ((.task as $task | $live | index($task)) != null) as $owner_live
      | . + {owner_live:$owner_live, orphaned:($owner_live | not)}
    )
')

issues=$(printf '%s' "$issues" | jq --argjson tasks "$tasks" --argjson leases "$leases" --argjson prs "$prs" '
  map(
    . as $issue
    | (
        ($tasks | map(select(.issue_repo == $issue.repo and (.issue_number | tostring) == ($issue.number | tostring))))
        + ($leases | map(select(.owner_live and .repo == $issue.repo and (.number | tostring) == ($issue.number | tostring))))
      ) as $owners
    | ($prs | map(select(
        .repo == $issue.repo
        and any(.closingIssuesReferences[]?; (.number | tostring) == ($issue.number | tostring))
      ))) as $linked_prs
    | . + {
        owners:$owners,
        linked_prs:($linked_prs | map({number,title,url,headRefName,baseRefName,mergeable,statusCheckRollup})),
        orphaned:(.lease == "in-progress" and ($owners | length) == 0 and ($linked_prs | length) == 0)
      }
  )
')

open_count=$(printf '%s' "$issues" | jq 'length')
available_count=$(printf '%s' "$issues" | jq '[.[] | select(.lease == "available")] | length')
in_progress_count=$((open_count - available_count))
orphaned_count=$(printf '%s' "$issues" | jq '[.[] | select(.orphaned)] | length')
pr_count=$(printf '%s' "$prs" | jq 'length')
active_count=$(printf '%s' "$tasks" | jq 'length')
error_count=$(printf '%s' "$errors" | jq 'length')
lease_count=$(printf '%s' "$leases" | jq 'length')
active_lease_count=$(printf '%s' "$leases" | jq '[.[] | select(.owner_live)] | length')
orphaned_lease_count=$((lease_count - active_lease_count))
# A validation record is live work only while its task still exists: the record
# itself is never cleaned, so counting bare records would pin the fast cadence.
validation_count=0
for validation in "$STATE"/reconcile/validation/*.json; do
  [ -f "$validation" ] || continue
  case " $live_task_ids " in
    *" $(basename "$validation" .json) "*) validation_count=$((validation_count + 1)) ;;
  esac
done
if processes=$("$SCRIPT_DIR/fm-process-inventory.sh" 2>/dev/null); then
  old_unowned_count=$(printf '%s' "$processes" | jq '.counts.old_unowned')
else
  processes='{"tasks":[],"counts":{"total":0,"owned":0,"unowned":0,"old_unowned":0,"chrome":0,"cypress":0,"devtools":0,"next":0},"old_unowned":[],"truncated":false}'
  old_unowned_count=0
  errors=$(printf '%s' "$errors" | jq '. + [{error:"process ownership inventory failed"}]')
  error_count=$((error_count + 1))
fi

# Active work, not the open issue count, selects the fast cadence and demands an
# acknowledgement: a crew, an open PR, a validation run, or an issue lease still
# needs supervision after the last issue closes.
active_work=0
if [ "$active_count" -gt 0 ] || [ "$pr_count" -gt 0 ] || [ "$in_progress_count" -gt 0 ] \
    || [ "$lease_count" -gt 0 ] || [ "$validation_count" -gt 0 ]; then
  active_work=1
fi

if [ "$error_count" -gt 0 ]; then
  health=degraded-sync
elif [ "$old_unowned_count" -gt 0 ]; then
  health=degraded-cleanup
elif [ "$open_count" -eq 0 ] && [ "$active_work" -eq 0 ]; then
  health=idle-complete
else
  health=action-required
fi

if [ "$error_count" -gt 0 ] || [ "$active_work" -eq 1 ]; then
  interval=$ACTIVE_INTERVAL
elif [ "$open_count" -gt 0 ]; then
  interval=$OPEN_IDLE_INTERVAL
else
  interval=$COMPLETE_INTERVAL
fi
next_due=$((NOW_EPOCH + interval))

previous_unacked=false
outstanding_token=
outstanding_epoch=0
if [ -s "$ISSUED" ]; then
  issued_token=$(jq -r '.token // empty' "$ISSUED" 2>/dev/null || true)
  issued_epoch=$(jq -r '.epoch // 0' "$ISSUED" 2>/dev/null || printf 0)
  ack_token=$(jq -r '.token // empty' "$ACK" 2>/dev/null || true)
  case "$issued_epoch" in ''|*[!0-9]*) issued_epoch=0 ;; esac
  if [ -n "$issued_token" ] && [ "$ack_token" != "$issued_token" ]; then
    outstanding_token=$issued_token
    outstanding_epoch=$issued_epoch
    if [ $((NOW_EPOCH - issued_epoch)) -ge "$ACK_GRACE" ]; then
      previous_unacked=true
      health=control-plane-failed
    fi
  fi
fi

ack_json='{"required":false,"token":null,"previous_unacked":false}'
token=
new_token=false
if [ "$open_count" -gt 0 ] || [ "$error_count" -gt 0 ] || [ "$old_unowned_count" -gt 0 ] \
    || [ "$active_work" -eq 1 ] || [ -n "$outstanding_token" ]; then
  if [ -n "$outstanding_token" ]; then
    token=$outstanding_token
  elif [ "$MODE" = tick ]; then
    token="${NOW_EPOCH}-$$"
    outstanding_epoch=$NOW_EPOCH
    new_token=true
  fi
  # Only a tick persists issued.json, so only a tick may mint a token. An
  # inspect reports that an acknowledgement is required and reuses an
  # outstanding token, but never advertises one that could never be accepted.
  if [ -n "$token" ]; then
    ack_json=$(jq -n --arg token "$token" --argjson previous_unacked "$previous_unacked" \
      '{required:true,token:$token,previous_unacked:$previous_unacked}')
  else
    ack_json=$(jq -n --argjson previous_unacked "$previous_unacked" \
      '{required:true,token:null,previous_unacked:$previous_unacked}')
  fi
fi

snapshot=$(jq -n \
  --arg generated "$NOW" \
  --arg health "$health" \
  --argjson epoch "$NOW_EPOCH" \
  --argjson next_due "$next_due" \
  --argjson interval "$interval" \
  --argjson repos "$repos" \
  --argjson issues "$issues" \
  --argjson prs "$prs" \
  --argjson tasks "$tasks" \
  --argjson leases "$leases" \
  --argjson processes "$processes" \
  --argjson errors "$errors" \
  --argjson ack "$ack_json" \
  --argjson open "$open_count" \
  --argjson available "$available_count" \
  --argjson in_progress "$in_progress_count" \
  --argjson orphaned "$orphaned_count" \
  --argjson open_prs "$pr_count" \
  --argjson active_crews "$active_count" \
  --argjson active_leases "$active_lease_count" \
  --argjson orphaned_leases "$orphaned_lease_count" \
  --argjson validations "$validation_count" \
  '{
    schema:"fm-reconcile.v1",
    tick:"executed",
    generated:$generated,
    generated_epoch:$epoch,
    next_due_epoch:$next_due,
    next_interval_seconds:$interval,
    health:{state:$health},
    counts:{
      open:$open,
      available:$available,
      in_progress:$in_progress,
      orphaned:$orphaned,
      open_prs:$open_prs,
      active_crews:$active_crews,
      active_leases:$active_leases,
      orphaned_leases:$orphaned_leases,
      validations:$validations
    },
    repositories:$repos,
    issues:$issues,
    prs:$prs,
    tasks:$tasks,
    leases:$leases,
    processes:$processes,
    errors:$errors,
    ack:$ack
  }')

# last.json carries the scheduler's next_due_epoch, so only a tick persists it.
# An inspect is a read-only view and must never postpone the next heartbeat.
if [ "$MODE" = tick ]; then
  tmp="$RECONCILE_DIR/last.json.tmp.$$"
  printf '%s\n' "$snapshot" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$LAST"
fi

if [ -n "$token" ] && [ "$MODE" = tick ]; then
  if [ "$new_token" = true ]; then
    issued_tmp="$RECONCILE_DIR/issued.json.tmp.$$"
    jq -n --arg token "$token" --arg generated "$NOW" --argjson epoch "$outstanding_epoch" \
      '{token:$token,generated:$generated,epoch:$epoch}' > "$issued_tmp"
    chmod 0600 "$issued_tmp"
    mv -f "$issued_tmp" "$ISSUED"
  fi
  payload="reconcile: token=$token open=$open_count available=$available_count in-progress=$in_progress_count orphaned=$orphaned_count prs=$pr_count snapshot=$LAST"
  fm_wake_append reconcile "$token" "$payload"
  pending_tmp="$RECONCILE_DIR/pending.tmp.$$"
  printf '%s\n' "$payload" > "$pending_tmp"
  chmod 0600 "$pending_tmp"
  mv -f "$pending_tmp" "$PENDING"
fi

printf '%s\n' "$snapshot" | render
