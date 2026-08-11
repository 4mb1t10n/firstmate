#!/usr/bin/env bash
# Enforce the captain's Codex reserve before a worker starts another turn.
# Usage: fm-codex-quota-gate.sh [worker [harness [model]]]
#
# Silent success means the optional policy is absent or current Codex
# availability is above its configured reserve. Every configured uncertainty
# fails closed so a stale snapshot can never spend the protected reserve.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
POLICY="${FM_QUOTA_POLICY_PATH:-$CONFIG/quota-policy.json}"
ROLE=${1:-worker}
HARNESS=codex
MODEL=default
[ "$#" -lt 2 ] || HARNESS=$2
[ "$#" -lt 3 ] || MODEL=$3

[ "$ROLE" = worker ] || {
  echo "error: quota gate role must be worker" >&2
  exit 2
}
[ "$#" -le 3 ] || {
  echo "error: quota gate accepts worker, harness, and model only" >&2
  exit 2
}
[ -e "$POLICY" ] || [ -L "$POLICY" ] || exit 0

# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

if [ "$MODEL" = "${MODEL#openai-codex/}" ]; then
  family=$(fm_control_harness_family "$HARNESS" 2>/dev/null || true)
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

if ! jq -e '
  .version == 1
  and (.codex.worker_minimum_percent_remaining == 20)
  and (.codex.active_worker_action == "drain-at-checkpoint")
  and (.telemetry.maximum_snapshot_age_seconds | type == "number" and . > 0 and floor == .)
  and (.telemetry.stale_behavior == "deny")
' "$POLICY" >/dev/null 2>&1; then
  echo "error: Codex worker denied because $POLICY is invalid" >&2
  exit 1
fi

minimum=$(jq -r '.codex.worker_minimum_percent_remaining' "$POLICY")
maximum_age=$(jq -r '.telemetry.maximum_snapshot_age_seconds' "$POLICY")
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
  select(.schemaVersion == 3)
  | (.providers[] | select(.provider == "codex")) as $provider
  | select($provider.state.status == "fresh" and $provider.state.stale == false)
  | ($provider.state.refreshedAt | parsed_epoch) as $refreshed
  | select((now - $refreshed) >= -60 and (now - $refreshed) <= $maximum_age)
  | select($provider.quotaSemantics.status == "known")
  | ($provider.quotaSemantics.effectiveAvailability[]
      | select(.scope == "all_models" and .status == "known")
      | .effectivePercentRemaining)
  | select(type == "number" and . >= 0 and . <= 100)
' "$snapshot" 2>/dev/null) || {
  echo "error: Codex worker denied because quota telemetry is stale, incomplete, or incompatible" >&2
  exit 1
}

if jq -en --argjson remaining "$remaining" --argjson minimum "$minimum" \
  '$remaining <= $minimum' >/dev/null; then
  used=$(jq -nr --argjson remaining "$remaining" '100 - $remaining')
  echo "error: Codex worker denied at ${used}% consumed (${remaining}% remaining); select a non-Codex dispatch profile and let any active Codex turn drain at its checkpoint" >&2
  exit 1
fi
