#!/usr/bin/env bash
# Persist First Mate's acknowledgement of the latest reconciliation request.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DIR="$STATE/reconcile"
ISSUED="$DIR/issued.json"
ACK="$DIR/last-ack.json"
TOKEN=${1:?usage: fm-reconcile-ack.sh <token> [note]}
NOTE=${2:-accepted}
LOCK="$DIR/lock"

command -v jq >/dev/null 2>&1 || { printf 'fm-reconcile-ack: jq not found\n' >&2; exit 1; }
mkdir -p "$DIR"
# Serialize the issued-token check, acknowledgement write, and pending-latch
# removal with reconciliation itself.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_lock_acquire_wait "$LOCK"
trap 'fm_lock_release "$LOCK" || true' EXIT
trap 'exit 1' INT TERM

[ -s "$ISSUED" ] || { printf 'fm-reconcile-ack: no reconciliation is awaiting acknowledgement\n' >&2; exit 1; }
LATEST=$(jq -r '.token // empty' "$ISSUED")
[ "$TOKEN" = "$LATEST" ] || {
  printf 'fm-reconcile-ack: token %s is stale; latest token is %s\n' "$TOKEN" "$LATEST" >&2
  exit 1
}

tmp="$DIR/last-ack.json.tmp.$$"
jq -n \
  --arg token "$TOKEN" \
  --arg note "$NOTE" \
  --arg acknowledged "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{token:$token,note:$note,acknowledged:$acknowledged}' > "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$ACK"
if [ -s "$DIR/pending" ] && grep -Eq "(^|[[:space:]])token=$TOKEN([[:space:]]|$)" "$DIR/pending"; then
  rm -f "$DIR/pending"
fi
printf 'acknowledged reconciliation %s\n' "$TOKEN"
