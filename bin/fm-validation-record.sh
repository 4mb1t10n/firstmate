#!/usr/bin/env bash
# Record complete No Mistakes validation for one exact PR head commit.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TASK=${1:?usage: fm-validation-record.sh <task-id> <head-sha> [run-id]}
HEAD_SHA=${2:?usage: fm-validation-record.sh <task-id> <head-sha> [run-id]}
RUN_ID=${3:-}

case "$TASK" in *[!A-Za-z0-9._-]*|'') printf 'fm-validation-record: invalid task id\n' >&2; exit 2 ;; esac
case "$HEAD_SHA" in *[!0-9a-fA-F]*|'') printf 'fm-validation-record: invalid head SHA\n' >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { printf 'fm-validation-record: jq not found\n' >&2; exit 1; }

mkdir -p "$STATE/reconcile/validation"
file="$STATE/reconcile/validation/$TASK.json"
tmp="$file.tmp.$$"
jq -n \
  --arg task "$TASK" \
  --arg head_sha "$HEAD_SHA" \
  --arg run_id "$RUN_ID" \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{task:$task,head_sha:$head_sha,run_id:$run_id,no_mistakes:"passed",completed_at:$completed_at}' > "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$file"
cat "$file"
