#!/usr/bin/env bash
# Reserve and release GitHub issue ownership through the in-progress label.
#
# Usage:
#   fm-issue-lease.sh reserve <owner/repo#number> <task-id> <project>
#   fm-issue-lease.sh release <owner/repo#number> <task-id> <reason>
#   fm-issue-lease.sh status <owner/repo#number>
#
# The local lease is durable evidence that explains the remote label.
# Reconciliation treats a remote label without this evidence, a linked PR, or
# another reconstructed owner as orphaned and asks First Mate to repair it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DIR="$STATE/reconcile/leases"
LOCK="$STATE/reconcile/lease-lock"
ACTION=${1:-}
REF=${2:-}
TASK=${3:-}
DETAIL=${4:-}

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

case "$REF" in
  */*#[0-9]*) ;;
  *) usage >&2; exit 2 ;;
esac
REPO=${REF%#*}
NUMBER=${REF##*#}
case "$REPO" in
  */*) ;;
  *) usage >&2; exit 2 ;;
esac
case "$REPO" in *[!A-Za-z0-9._/-]*) usage >&2; exit 2 ;; esac
case "$NUMBER" in ''|*[!0-9]*) usage >&2; exit 2 ;; esac
case "$TASK" in *[!A-Za-z0-9._-]*) usage >&2; exit 2 ;; esac
SAFE=$(printf '%s-%s' "$REPO" "$NUMBER" | tr '/:' '__')
FILE="$DIR/$SAFE.json"

command -v jq >/dev/null 2>&1 || { printf 'fm-issue-lease: jq not found\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'fm-issue-lease: gh not found\n' >&2; exit 1; }
mkdir -p "$DIR"
chmod 0700 "$STATE/reconcile" "$DIR" 2>/dev/null || true

cleanup() {
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
while ! mkdir "$LOCK" 2>/dev/null; do sleep 0.1; done

case "$ACTION" in
  reserve)
    [ -n "$TASK" ] && [ -n "$DETAIL" ] || { usage >&2; exit 2; }
    if [ -s "$FILE" ]; then
      owner=$(jq -r '.task // empty' "$FILE")
      if [ "$owner" != "$TASK" ]; then
        printf 'fm-issue-lease: %s is already reserved by %s\n' "$REF" "$owner" >&2
        exit 1
      fi
      cat "$FILE"
      exit 0
    fi
    gh label create in-progress --repo "$REPO" \
      --color FFB000 \
      --description "First Mate has assigned this issue to an active crew" \
      --force >/dev/null
    gh issue edit "$NUMBER" --repo "$REPO" --add-label in-progress >/dev/null
    tmp="$FILE.tmp.$$"
    jq -n \
      --arg repo "$REPO" \
      --argjson number "$NUMBER" \
      --arg task "$TASK" \
      --arg project "$DETAIL" \
      --arg reserved_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{repo:$repo,number:$number,task:$task,project:$project,reserved_at:$reserved_at}' > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$FILE"
    cat "$FILE"
    ;;
  release)
    [ -n "$TASK" ] && [ -n "$DETAIL" ] || { usage >&2; exit 2; }
    [ -s "$FILE" ] || { printf 'fm-issue-lease: no lease exists for %s\n' "$REF" >&2; exit 1; }
    owner=$(jq -r '.task // empty' "$FILE")
    [ "$owner" = "$TASK" ] || {
      printf 'fm-issue-lease: refusing to release %s owned by %s as %s\n' "$REF" "$owner" "$TASK" >&2
      exit 1
    }
    gh issue edit "$NUMBER" --repo "$REPO" --remove-label in-progress >/dev/null
    history="$STATE/reconcile/lease-history.jsonl"
    jq -c \
      --arg released_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg reason "$DETAIL" \
      '. + {released_at:$released_at,release_reason:$reason}' "$FILE" >> "$history"
    chmod 0600 "$history" 2>/dev/null || true
    rm -f "$FILE"
    printf 'released %s from %s\n' "$REF" "$TASK"
    ;;
  status)
    if [ -s "$FILE" ]; then cat "$FILE"; else printf '{"repo":"%s","number":%s,"reserved":false}\n' "$REPO" "$NUMBER"; fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
