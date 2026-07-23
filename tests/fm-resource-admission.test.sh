#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
# shellcheck source=bin/fm-resource-lib.sh
. "$ROOT/bin/fm-resource-lib.sh"

state="$TMP_ROOT/state"
config="$TMP_ROOT/config"
mkdir -p "$state" "$config"

write_heavy() {
  printf 'kind=ship\nresource_class=heavy\n' > "$state/$1.meta"
}

fm_resource_admit "$state" "$config" heavy
write_heavy one
write_heavy two
write_heavy three

if fm_resource_admit "$state" "$config" heavy; then
  echo "FAIL: fourth heavy crew was admitted without a headroom probe" >&2
  exit 1
fi

printf '#!/bin/sh\nexit 0\n' > "$config/resource-admission-probe"
chmod +x "$config/resource-admission-probe"
fm_resource_admit "$state" "$config" heavy

write_heavy four
if fm_resource_admit "$state" "$config" heavy; then
  echo "FAIL: fifth heavy crew was admitted" >&2
  exit 1
fi

fm_resource_admit "$state" "$config" medium
fm_resource_queue_write "$state" queued task-id "/path with spaces" --resource-class heavy
grep -q '^argv=' "$state/resource-queue/queued.queue"
grep -q '^seq=' "$state/resource-queue/queued.queue"

# --- liveness gating: a confirmed-dead crew's meta stops occupying a slot ------
# Stub the backend liveness helpers the lib injects by availability. DEAD_TARGETS
# marks which recorded windows probe as confidently dead.
DEAD_TARGETS=
fm_backend_of_meta() { fm_resource_meta_value "$1" backend; }
fm_backend_target_of_meta() { fm_resource_meta_value "$1" window; }
fm_backend_agent_alive() {
  case " $DEAD_TARGETS " in
    *" $2 "*) printf dead ;;
    *) printf alive ;;
  esac
}

live="$TMP_ROOT/live"
mkdir -p "$live"
for n in 1 2 3 4; do
  printf 'kind=ship\nresource_class=heavy\nbackend=tmux\nwindow=w-%s\n' "$n" > "$live/task-$n.meta"
done

DEAD_TARGETS="w-3 w-4"
[ "$(fm_resource_heavy_count "$live" '' 0)" -eq 4 ] || {
  echo "FAIL: naive count should see all four heavy metas" >&2; exit 1; }
[ "$(fm_resource_heavy_count "$live" '' 1)" -eq 2 ] || {
  echo "FAIL: liveness count should skip the two confirmed-dead crews" >&2; exit 1; }
if ! fm_resource_admit "$live" "$config" heavy; then
  echo "FAIL: two live heavy crews should admit a third without probing" >&2; exit 1; fi

# With every crew live again, the guarantee caps at three and probes the fourth.
DEAD_TARGETS=
rm -f "$live/task-4.meta"
if fm_resource_admit "$live" "$config" heavy; then
  : # three live crews, probe present (exit 0) -> admitted
else
  echo "FAIL: fourth heavy crew should be admitted when the headroom probe passes" >&2; exit 1
fi
DEAD_TARGETS=
unset -f fm_backend_of_meta fm_backend_target_of_meta fm_backend_agent_alive

# Non-stubbed: with the real backend helpers, a tmux crew whose window is GONE
# (the primary leak - a killed crew) must drop from the live count, even though
# the agent probe alone reports it only as `unknown`, never `dead`. Run in a
# subshell so sourcing fm-backend.sh does not leak into the assertions above.
(
  . "$ROOT/bin/fm-backend.sh"
  . "$ROOT/bin/fm-resource-lib.sh"
  gone="$TMP_ROOT/tmux-gone"
  mkdir -p "$gone"
  printf 'kind=ship\nresource_class=heavy\nbackend=tmux\nwindow=fm-nonexistent-xyz:fm-nope\n' \
    > "$gone/task.meta"
  [ "$(fm_resource_heavy_count "$gone" '' 0)" -eq 1 ] || {
    echo "FAIL: naive count should still see the leaked meta" >&2; exit 1; }
  [ "$(fm_resource_heavy_count "$gone" '' 1)" -eq 0 ] || {
    echo "FAIL: a gone tmux window must not occupy a heavy slot" >&2; exit 1; }
) || exit 1

# --- reservations: hold a slot before the meta lands, pruned when the pid dies -
resv="$TMP_ROOT/resv"
mkdir -p "$resv"
fm_resource_reservation_write "$resv" resv-live heavy
[ "$(fm_resource_heavy_count "$resv" '' 0)" -eq 1 ] || {
  echo "FAIL: a live reservation should occupy a heavy slot" >&2; exit 1; }

( exit 0 ) &
deadpid=$!
wait "$deadpid" 2>/dev/null || true
printf 'resource_class=heavy\npid=%s\n' "$deadpid" > "$resv/resource-reservations/resv-dead"
[ "$(fm_resource_heavy_count "$resv" '' 0)" -eq 1 ] || {
  echo "FAIL: a reservation whose spawn pid is dead must not occupy a slot" >&2; exit 1; }

printf 'kind=ship\nresource_class=heavy\n' > "$resv/resv-live.meta"
[ "$(fm_resource_heavy_count "$resv" '' 0)" -eq 1 ] || {
  echo "FAIL: a landed meta must supersede its reservation, not double-count" >&2; exit 1; }

# --- durable queue drain: true FIFO by seq, requeue on 75, recover orphans -----
STUB_ORDER_FILE="$TMP_ROOT/admit-order"
STUB_EXIT=0
export STUB_ORDER_FILE STUB_EXIT
cat > "$TMP_ROOT/stub-spawn.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_ORDER_FILE"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$TMP_ROOT/stub-spawn.sh"

run_drain() {  # <state>
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$1" \
    FM_QUEUE_SPAWN="$TMP_ROOT/stub-spawn.sh" \
    "$ROOT/bin/fm-admit-queued.sh"
}

qstate="$TMP_ROOT/queue-fifo"
mkdir -p "$qstate"
# Enqueue lexical-out-of-order ids so lexical sorting would reorder them; seq
# order (enqueue order) must win.
fm_resource_queue_write "$qstate" zebra zebra
fm_resource_queue_write "$qstate" alpha alpha
fm_resource_queue_write "$qstate" mango mango
: > "$STUB_ORDER_FILE"
run_drain "$qstate"
got=$(tr '\n' ' ' < "$STUB_ORDER_FILE")
[ "$got" = "zebra alpha mango " ] || {
  echo "FAIL: drain must admit in enqueue (seq) order, got: $got" >&2; exit 1; }

# Requeue on 75: the deferred entry is restored with its seq, never lost.
qretry="$TMP_ROOT/queue-retry"
mkdir -p "$qretry"
fm_resource_queue_write "$qretry" only-one only-one
STUB_EXIT=75
: > "$STUB_ORDER_FILE"
run_drain "$qretry"
STUB_EXIT=0
[ -f "$qretry/resource-queue/only-one.queue" ] || {
  echo "FAIL: an entry the gate defers (75) must be restored to the queue" >&2; exit 1; }
[ ! -e "$qretry/resource-queue/only-one.queue.running" ] || {
  echo "FAIL: no .running claim may leak after a requeue" >&2; exit 1; }
grep -q '^seq=' "$qretry/resource-queue/only-one.queue" || {
  echo "FAIL: requeue must preserve the recorded seq" >&2; exit 1; }

# A hard spawn failure quarantines the entry as .failed rather than looping.
qfail="$TMP_ROOT/queue-fail"
mkdir -p "$qfail"
fm_resource_queue_write "$qfail" boom boom
STUB_EXIT=1
: > "$STUB_ORDER_FILE"
run_drain "$qfail" || true
STUB_EXIT=0
[ -f "$qfail/resource-queue/boom.queue.failed" ] || {
  echo "FAIL: a hard spawn failure must be quarantined as .failed" >&2; exit 1; }

# Orphan recovery: a .running left by a crashed drainer is retried, not lost.
qorphan="$TMP_ROOT/queue-orphan"
mkdir -p "$qorphan/resource-queue"
printf 'seq=1\nqueued_at=now\nargv=orphan \n' > "$qorphan/resource-queue/orphan.queue.running"
: > "$STUB_ORDER_FILE"
run_drain "$qorphan"
grep -qx orphan "$STUB_ORDER_FILE" || {
  echo "FAIL: an orphaned .running entry must be recovered and admitted" >&2; exit 1; }
[ ! -e "$qorphan/resource-queue/orphan.queue.running" ] || {
  echo "FAIL: recovered orphan must not leave a .running claim behind" >&2; exit 1; }

echo "PASS: resource admission guarantees three, probes the fourth, caps at four, gates on liveness, reserves in-flight slots, and drains the durable queue in order"
