#!/usr/bin/env bash
# Drain durable queued heavy spawns in true FIFO order (the monotonic queue seq)
# while resource policy permits. Wired into the away-supervision daemon's
# housekeeping (bin/fm-supervise-daemon.sh); safe to run by hand too. A single
# drainer runs at a time under a lock, a drain crashed mid-claim recovers its
# in-flight entry, and a task the gate defers again (exit 75) keeps its place.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
QUEUE="$STATE/resource-queue"
SPAWN="${FM_QUEUE_SPAWN:-$FM_ROOT/bin/fm-spawn.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

[ -d "$QUEUE" ] || exit 0

# Single drainer at a time: a second invocation exits cleanly rather than racing
# the claim rename below. The lock also makes .running recovery safe - if we
# hold it, no other drainer can be mid-claim, so any stray .running is a genuine
# orphan from a crashed drain.
DRAIN_LOCK="$STATE/.resource-queue-drain.lock"
fm_lock_try_acquire "$DRAIN_LOCK" || exit 0
trap 'fm_lock_release "$DRAIN_LOCK" || true' EXIT

# Recover entries a previous drainer claimed (renamed to .running) but never
# resolved because it was interrupted between the claim and the spawn result.
for running in "$QUEUE"/*.queue.running; do
  [ -e "$running" ] || continue
  mv -f "$running" "${running%.running}"
done

queue_seq() {  # <queue-file>  -> monotonic seq, 0 for legacy entries
  local s
  s=$(sed -n 's/^seq=//p' "$1" 2>/dev/null | tail -1)
  case "$s" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$s" ;;
  esac
}

# Snapshot the pending set once, ordered by enqueue seq (then id for legacy
# ties). The loop mutates the queue as it goes; iterating the snapshot avoids
# reprocessing a just-renamed entry, and read -r keeps ids with spaces intact.
while IFS= read -r item; do
  [ -n "$item" ] || continue
  [ -e "$item" ] || continue
  id=${item##*/}
  id=${id%.queue}
  argv=$(sed -n 's/^argv=//p' "$item")
  [ -n "$argv" ] || continue
  running="$item.running"
  mv "$item" "$running" 2>/dev/null || continue
  status=0
  FM_RESOURCE_FROM_QUEUE=1 FM_QUEUE_ARGV="$argv" FM_QUEUE_SPAWN="$SPAWN" \
    bash -c 'eval "set -- $FM_QUEUE_ARGV"; exec "$FM_QUEUE_SPAWN" "$@"' || status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$running"
    echo "admitted $id"
  elif [ "$status" -eq 75 ]; then
    # Capacity is full again: restore this entry (seq preserved) and stop; the
    # rest stay queued in order for the next drain.
    mv -f "$running" "$item"
    break
  else
    mv -f "$running" "$item.failed"
    echo "error: queued spawn $id failed with status $status" >&2
  fi
done < <(
  for item in "$QUEUE"/*.queue; do
    [ -e "$item" ] || continue
    printf '%s\t%s\n' "$(queue_seq "$item")" "$item"
  done | sort -n -k1,1 -k2 | cut -f2-
)
