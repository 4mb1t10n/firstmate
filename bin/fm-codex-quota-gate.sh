#!/usr/bin/env bash
# Enforce the captain's Codex reserve before a worker starts another turn.
# Usage: fm-codex-quota-gate.sh [worker|delivery|continuation|unprotected [harness [model [identity [turn-gate]]]]]
#
# Silent success means the optional policy is absent, or the caller has a live
# turn boundary and current Codex availability is above its configured reserve.
# Every configured uncertainty fails closed so a stale snapshot can never spend
# the protected reserve.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
POLICY="${FM_QUOTA_POLICY_PATH:-$CONFIG/quota-policy.json}"
ROLE=${1:-worker}
HARNESS=codex
MODEL=default
QUOTA_IDENTITY=${FM_WORKER_QUOTA_IDENTITY:-}
QUOTA_TURN_GATE=${FM_WORKER_QUOTA_TURN_GATE:-}
[ "$#" -lt 2 ] || HARNESS=$2
[ "$#" -lt 3 ] || MODEL=$3
[ "$#" -lt 4 ] || QUOTA_IDENTITY=$4
[ "$#" -lt 5 ] || QUOTA_TURN_GATE=$5

case "$ROLE" in
  worker|delivery|continuation|unprotected) ;;
  *)
    echo "error: quota gate role must be worker, delivery, continuation, or unprotected" >&2
    exit 2
    ;;
esac
[ "$#" -le 5 ] || {
  echo "error: quota gate accepts role, harness, model, identity provenance, and turn-gate provenance only" >&2
  exit 2
}
[ -e "$POLICY" ] || [ -L "$POLICY" ] || exit 0

if [ "$ROLE" = unprotected ]; then
  echo "error: worker denied under the Codex quota policy because a raw launch command cannot establish a structured quota identity or verified live turn gate; use a verified --harness adapter" >&2
  exit 1
fi

if [ "$ROLE" = continuation ]; then
  SECOND_MATE_MARKER="$FM_HOME/.fm-secondmate-home"
  [ -e "$SECOND_MATE_MARKER" ] || [ -L "$SECOND_MATE_MARKER" ] || exit 0
  [ -f "$SECOND_MATE_MARKER" ] && [ ! -L "$SECOND_MATE_MARKER" ] || {
    echo "error: Codex worker denied because $SECOND_MATE_MARKER is not a regular secondmate identity file" >&2
    exit 1
  }
fi

case "$ROLE" in
  delivery|continuation)
    if [ "$QUOTA_IDENTITY" != structured ]; then
      echo "error: Codex quota policy denied worker input because endpoint identity provenance '${QUOTA_IDENTITY:-missing}' does not prove a structured launch; relaunch the endpoint with a verified adapter before sending more text" >&2
      exit 1
    fi
    ;;
esac

# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

family=$(fm_control_harness_family "$HARNESS" 2>/dev/null || true)
if [ "$MODEL" = "${MODEL#openai-codex/}" ]; then
  case "$family" in
    codex) ;;
    pi|pi-signed)
      case "$MODEL" in
        */?*) exit 0 ;;
        *)
          echo "error: Codex worker denied because quota consumption is ambiguous for harness '$HARNESS' model '$MODEL'" >&2
          exit 1
          ;;
      esac
      ;;
    claude|opencode|grok|kimi|muse) exit 0 ;;
    *)
      echo "error: Codex worker denied because quota consumption is ambiguous for harness '${HARNESS:-unknown}' model '${MODEL:-default}'" >&2
      exit 1
      ;;
  esac
fi

case "$ROLE" in
  delivery|continuation)
    case "$family:$QUOTA_TURN_GATE" in
      pi:before-agent-start|pi-signed:before-agent-start) ;;
      *)
        echo "error: Codex worker continuation denied because harness '$HARNESS' has no verified turn-start quota gate and may queue text before the next turn; let the active turn drain, use control keys if needed, and select a Pi-family Codex or non-Codex profile for follow-up work" >&2
        exit 1
        ;;
    esac
    ;;
esac

[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || {
  echo "error: Codex worker denied because $POLICY is not a regular policy file" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "error: Codex worker denied because jq is unavailable for $POLICY" >&2
  exit 1
}
command -v quota-axi >/dev/null 2>&1 || {
  echo "error: Codex worker denied because quota-axi is unavailable" >&2
  exit 1
}

policy_values=$(jq -er '
  if (
    .version == 1
    and (.codex.worker_minimum_percent_remaining == 20)
    and (.codex.active_worker_action == "drain-at-checkpoint")
    and (.telemetry.maximum_snapshot_age_seconds | type == "number" and . > 0 and floor == .)
    and (.telemetry.stale_behavior == "deny")
  ) then
    [.codex.worker_minimum_percent_remaining, .telemetry.maximum_snapshot_age_seconds]
    | @tsv
  else empty end
' "$POLICY" 2>/dev/null) || {
  echo "error: Codex worker denied because $POLICY is invalid" >&2
  exit 1
}

IFS=$'\t' read -r minimum maximum_age extra <<< "$policy_values"
[ -n "$minimum" ] && [ -n "$maximum_age" ] && [ -z "${extra:-}" ] || {
  echo "error: Codex worker denied because $POLICY is invalid" >&2
  exit 1
}
snapshot=$(mktemp "${TMPDIR:-/tmp}/fm-codex-quota.XXXXXX")
trap 'rm -f "$snapshot"' EXIT

run_quota_axi() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 quota-axi --json > "$snapshot" 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 10 quota-axi --json > "$snapshot" 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); open STDOUT, ">", $ARGV[0] or die; exec "quota-axi", "--json" } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm 10; waitpid $pid, 0; exit($? >> 8)' "$snapshot" 2>/dev/null
  else
    return 1
  fi
}

if ! run_quota_axi; then
  echo "error: Codex worker denied because fresh quota telemetry could not be collected" >&2
  exit 1
fi

remaining=$(jq -er --argjson maximum_age "$maximum_age" '
  def parsed_epoch:
    if type == "string" then sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 else error("timestamp") end;
  [select(.schemaVersion == 3)
    | [.providers[] | select(.provider == "codex")] as $providers
    | select($providers | length == 1)
    | $providers[0] as $provider
    | select($provider.state.status == "fresh" and $provider.state.stale == false)
    | ($provider.state.refreshedAt | parsed_epoch) as $refreshed
    | select((now - $refreshed) >= -60 and (now - $refreshed) <= $maximum_age)
    | select($provider.quotaSemantics.status == "known")
    | [$provider.quotaSemantics.effectiveAvailability[]
        | select(.scope == "all_models")] as $availability
    | select($availability | length == 1)
    | ($availability[0] | select(.status == "known") | .effectivePercentRemaining)
    | select(type == "number" and . >= 0 and . <= 100)]
  | select(length == 1)
  | .[0]
' "$snapshot" 2>/dev/null) || {
  echo "error: Codex worker denied because quota telemetry is stale, incomplete, or incompatible" >&2
  exit 1
}

at_or_below=$(jq -nr --argjson remaining "$remaining" --argjson minimum "$minimum" \
  '$remaining <= $minimum' 2>/dev/null) || {
  echo "error: Codex worker denied because quota telemetry is stale, incomplete, or incompatible" >&2
  exit 1
}
case "$at_or_below" in
true)
  used=$(jq -nr --argjson remaining "$remaining" '100 - $remaining')
  echo "error: Codex worker denied at ${used}% consumed (${remaining}% remaining); select a non-Codex dispatch profile and let any active Codex turn drain at its checkpoint" >&2
  exit 1
  ;;
false) ;;
*)
  echo "error: Codex worker denied because quota telemetry is stale, incomplete, or incompatible" >&2
  exit 1
  ;;
esac
