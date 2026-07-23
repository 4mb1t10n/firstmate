#!/usr/bin/env bash
# Shared resource admission for crewmate launches.

fm_resource_meta_value() {
  local meta=$1 key=$2
  sed -n "s/^${key}=//p" "$meta" 2>/dev/null | tail -1
}

fm_resource_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# A crew meta occupies a heavy slot unless its crew is CONFIRMED gone. A meta
# with no recorded backend target is an in-flight spawn (window not created
# yet) and always counts. A leaked meta from a crashed or killed crew is skipped
# so it cannot wedge dispatch; the meta file itself is left in place for recovery
# and is never deleted here. Confirmed-dead means:
#   * tmux: the recorded window no longer exists. A tmux crew cannot outlive its
#     pane or server, so a gone target is genuine death, never a transient - and
#     it is the PRIMARY leak (a killed crew whose window died), which the agent
#     probe alone reports only as `unknown` (unreadable pane), never `dead`. A
#     still-present pane that dropped to a bare shell is `dead` from the agent
#     probe and also skipped.
#   * every other backend: only a confident `dead` from the agent probe (herdr's
#     structurally-gone/no-agent pane). A herdr network blip reads `unknown` and
#     keeps counting, so it can never falsely open the gate.
# Anything unreadable/unknown keeps counting, so uncertainty can never over-admit.
# The backend helpers exist only when fm-backend.sh has been sourced (fm-spawn.sh
# sources it before this lib); standalone callers skip the probe and treat every
# meta as live, preserving the naive count.
fm_resource_meta_confirmed_dead() {  # <meta>
  local meta=$1 target backend state
  command -v fm_backend_target_of_meta >/dev/null 2>&1 || return 1
  command -v fm_backend_agent_alive >/dev/null 2>&1 || return 1
  target=$(fm_backend_target_of_meta "$meta" 2>/dev/null || true)
  [ -n "$target" ] || return 1
  backend=$(fm_backend_of_meta "$meta" 2>/dev/null || printf tmux)
  if [ "$backend" = tmux ] && command -v fm_backend_target_exists >/dev/null 2>&1; then
    fm_backend_target_exists tmux "$target" 2>/dev/null || return 0
  fi
  state=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
  [ "$state" = dead ]
}

# Count heavy crews holding a slot: fully-spawned crews (their state/<id>.meta)
# plus in-flight reservations (state/resource-reservations/<id>, written under
# the admission lock before the window exists) whose spawning process is still
# alive. A reservation is superseded once its crew's meta lands, so the same
# crew is never counted twice. With live_only=1 the meta scan additionally skips
# confirmed-dead crews so leaked metas cannot wedge dispatch forever.
fm_resource_heavy_count() {  # <state> [exclude-id] [live_only]
  local state=$1 exclude=${2:-} live_only=${3:-0} meta res id class kind pid count=0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$meta" != "$state/$exclude.meta" ] || continue
    kind=$(fm_resource_meta_value "$meta" kind)
    [ "$kind" != secondmate ] || continue
    class=$(fm_resource_meta_value "$meta" resource_class)
    [ -n "$class" ] || class=heavy
    [ "$class" = heavy ] || continue
    if [ "$live_only" = 1 ] && fm_resource_meta_confirmed_dead "$meta"; then
      continue
    fi
    count=$((count + 1))
  done
  for res in "$state"/resource-reservations/*; do
    [ -f "$res" ] || continue
    id=${res##*/}
    [ "$id" != "$exclude" ] || continue
    [ ! -f "$state/$id.meta" ] || continue
    class=$(fm_resource_meta_value "$res" resource_class)
    [ -n "$class" ] || class=heavy
    [ "$class" = heavy ] || continue
    pid=$(fm_resource_meta_value "$res" pid)
    fm_resource_pid_alive "$pid" || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

fm_resource_admit() {  # <state> <config> <class> [exclude-id]
  local state=$1 config=$2 class=$3 exclude=${4:-} count probe
  [ "$class" = heavy ] || return 0
  # Fast common path: a naive count under the guarantee needs no liveness probe.
  count=$(fm_resource_heavy_count "$state" "$exclude" 0)
  [ "$count" -lt 3 ] && return 0
  # At or over the guarantee, recount excluding confirmed-dead crews so leaked
  # metas cannot wedge dispatch, paying the backend probe only when it matters.
  count=$(fm_resource_heavy_count "$state" "$exclude" 1)
  [ "$count" -lt 3 ] && return 0
  [ "$count" -lt 4 ] || return 75
  probe="$config/resource-admission-probe"
  [ -x "$probe" ] || return 75
  "$probe" || return 75
}

# Reserve a heavy slot under the admission lock, before the crew's window (and
# thus its meta) exists, so a concurrent spawn observes the slot immediately and
# the guarantee cannot be exceeded by a launch race. The recording process's pid
# lets the count prune a reservation whose spawn was SIGKILLed mid-flight.
fm_resource_reservation_write() {  # <state> <id> <class>
  local state=$1 id=$2 class=$3
  mkdir -p "$state/resource-reservations"
  {
    printf 'resource_class=%s\n' "$class"
    printf 'pid=%s\n' "${BASHPID:-$$}"
    printf 'reserved_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$state/resource-reservations/$id"
}

fm_resource_reservation_clear() {  # <state> <id>
  local state=$1 id=$2
  rm -f "$state/resource-reservations/$id" 2>/dev/null || true
}

# Durably record a heavy spawn deferred by capacity. seq= is a monotonic counter
# stamped under the admission lock so the drainer can admit in true enqueue order
# even when a batch queues several tasks within one wall-clock second.
fm_resource_queue_write() {  # <state> <id> <argv...>
  local state=$1 id=$2 seq seq_file
  shift 2
  mkdir -p "$state/resource-queue"
  seq_file="$state/.resource-queue.seq"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file"
  {
    printf 'seq=%s\n' "$seq"
    printf 'queued_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'argv='
    printf '%q ' "$@"
    printf '\n'
  } > "$state/resource-queue/$id.queue"
}
