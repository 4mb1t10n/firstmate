#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-codex-quota-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-quota-gate)

make_case() {
  local dir="$TMP_ROOT/$1" fakebin="$TMP_ROOT/$1/fakebin"
  mkdir -p "$dir/config" "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_QUOTA_CALLS:-}" ] || printf 'called\n' >> "$FM_FAKE_QUOTA_CALLS"
remaining=${FM_FAKE_CODEX_REMAINING:-100}
refreshed=${FM_FAKE_CODEX_REFRESHED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
status=${FM_FAKE_CODEX_STATUS:-fresh}
stale=${FM_FAKE_CODEX_STALE:-false}
provider_count=${FM_FAKE_CODEX_PROVIDER_COUNT:-1}
availability_count=${FM_FAKE_CODEX_AVAILABILITY_COUNT:-1}
jq -n --argjson remaining "$remaining" --arg refreshed "$refreshed" \
  --arg status "$status" --argjson stale "$stale" \
  --argjson provider_count "$provider_count" --argjson availability_count "$availability_count" '
  {
    schemaVersion: 3,
    providers: [range(0; $provider_count) | {
      provider: "codex",
      state: {status: $status, stale: $stale, refreshedAt: $refreshed},
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [range(0; $availability_count) | {
          scope: "all_models",
          status: "known",
          effectivePercentRemaining: $remaining
        }]
      }
    }]
  }'
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$dir"
}

write_policy() {
  local home=$1 minimum=${2:-20}
  printf '%s\n' "{\"version\":1,\"codex\":{\"worker_minimum_percent_remaining\":$minimum,\"active_worker_action\":\"drain-at-checkpoint\"},\"telemetry\":{\"maximum_snapshot_age_seconds\":300,\"stale_behavior\":\"deny\"}}" \
    > "$home/config/quota-policy.json"
}

run_gate_role() {
  local home=$1 role=$2 harness=$3 model=$4
  shift 4
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$@" \
    "$GATE" "$role" "$harness" "$model" 2>&1
}

run_gate() {
  local home=$1 harness=$2 model=$3
  shift 3
  run_gate_role "$home" worker "$harness" "$model" "$@"
}

test_optional_policy_and_exact_reserve() {
  local home out rc
  home=$(make_case exact)

  out=$(run_gate "$home" "" default); rc=$?
  expect_code 0 "$rc" "an absent optional policy should allow an unclassified target"
  [ -z "$out" ] || fail "an absent policy should be silent: $out"

  write_policy "$home"
  out=$(run_gate "$home" codex gpt-5 FM_FAKE_CODEX_REMAINING=20); rc=$?
  expect_code 1 "$rc" "Codex should be denied at exactly 20 percent remaining"
  assert_contains "$out" "20% remaining" "the exact-cutoff refusal did not report remaining quota"

  out=$(run_gate "$home" codex gpt-5 FM_FAKE_CODEX_REMAINING=21); rc=$?
  expect_code 0 "$rc" "Codex should remain available above the reserve"
  pass "Codex quota gate enforces the exact 20 percent reserve"
}

test_policy_shape_and_source_fail_closed() {
  local home out rc
  home=$(make_case policy)
  write_policy "$home" 0
  out=$(run_gate "$home" codex gpt-5); rc=$?
  expect_code 1 "$rc" "a policy that changes the required reserve should be invalid"
  assert_contains "$out" "is invalid" "the invalid cutoff refusal was not actionable"

  rm -f "$home/config/quota-policy.json"
  ln -s "$home/config/missing-policy.json" "$home/config/quota-policy.json"
  out=$(run_gate "$home" codex gpt-5); rc=$?
  expect_code 1 "$rc" "a dangling policy symlink should deny Codex work"
  assert_contains "$out" "not a regular policy file" "the dangling-link refusal did not name the unsafe policy"
  pass "Codex quota gate rejects invalid cutoffs and dangling policy links"
}

test_quota_consumer_classification() {
  local home calls out rc
  home=$(make_case profiles)
  calls="$home/quota.calls"
  write_policy "$home"

  out=$(run_gate "$home" pi openai-codex/gpt-5.6-sol FM_FAKE_CODEX_REMAINING=20 FM_FAKE_QUOTA_CALLS="$calls"); rc=$?
  expect_code 1 "$rc" "Pi using an openai-codex model should consume the protected quota"
  assert_contains "$out" "20% remaining" "Pi Codex consumption did not reach the quota boundary"

  : > "$calls"
  out=$(run_gate "$home" pi anthropic/claude-sonnet-5 FM_FAKE_CODEX_REMAINING=20 FM_FAKE_QUOTA_CALLS="$calls"); rc=$?
  expect_code 0 "$rc" "Pi using an explicit non-Codex provider should remain available"
  [ ! -s "$calls" ] || fail "a proven non-Codex Pi profile unnecessarily collected Codex telemetry"

  out=$(run_gate "$home" pi default FM_FAKE_CODEX_REMAINING=100); rc=$?
  expect_code 1 "$rc" "Pi without a provider-qualified model should be denied under the policy"
  assert_contains "$out" "quota consumption is ambiguous" "the ambiguous Pi profile refusal was not actionable"

  out=$(run_gate "$home" "" default FM_FAKE_CODEX_REMAINING=100); rc=$?
  expect_code 1 "$rc" "a target without harness identity should be denied under the policy"
  assert_contains "$out" "quota consumption is ambiguous" "the unknown-target refusal was not actionable"

  out=$(run_gate "$home" claude claude-sonnet-5 FM_FAKE_CODEX_REMAINING=20); rc=$?
  expect_code 0 "$rc" "a verified non-Codex harness should remain available"
  pass "Codex quota gate classifies provider-aware and ambiguous worker profiles"
}

test_unprotected_turn_boundary_is_policy_gated() {
  local home calls out rc
  home=$(make_case unprotected)
  calls="$home/quota.calls"

  out=$(run_gate_role "$home" unprotected claude claude-sonnet-5); rc=$?
  expect_code 0 "$rc" "an absent optional policy should allow an unprotected raw launch command"
  [ -z "$out" ] || fail "an absent policy should be silent for an unprotected launch: $out"

  write_policy "$home"
  out=$(run_gate_role "$home" unprotected claude claude-sonnet-5 \
    FM_FAKE_QUOTA_CALLS="$calls"); rc=$?
  expect_code 1 "$rc" "a configured policy should refuse every unprotected raw launch command"
  assert_contains "$out" "raw launch command cannot establish a structured quota identity" \
    "the unprotected launch refusal did not name the missing identity boundary"
  [ ! -s "$calls" ] || fail "an unprotected launch unnecessarily collected telemetry before refusing"
  pass "configured quota policy requires a structured launch boundary"
}

test_stale_telemetry_fails_closed() {
  local home out rc
  home=$(make_case stale)
  write_policy "$home"
  out=$(run_gate "$home" codex gpt-5 FM_FAKE_CODEX_STATUS=stale FM_FAKE_CODEX_STALE=true); rc=$?
  expect_code 1 "$rc" "stale Codex telemetry should deny a new worker turn"
  assert_contains "$out" "stale, incomplete, or incompatible" "the stale telemetry refusal was not actionable"
  pass "Codex quota gate fails closed on stale telemetry"
}

test_ambiguous_telemetry_fails_closed() {
  local home out rc
  home=$(make_case ambiguous)
  write_policy "$home"

  out=$(run_gate "$home" codex gpt-5 FM_FAKE_CODEX_REMAINING=100 FM_FAKE_CODEX_PROVIDER_COUNT=2); rc=$?
  expect_code 1 "$rc" "duplicate Codex providers should deny a new worker turn"
  assert_contains "$out" "stale, incomplete, or incompatible" "duplicate providers did not fail closed"

  out=$(run_gate "$home" codex gpt-5 FM_FAKE_CODEX_REMAINING=100 FM_FAKE_CODEX_AVAILABILITY_COUNT=2); rc=$?
  expect_code 1 "$rc" "duplicate all-model availability should deny a new worker turn"
  assert_contains "$out" "stale, incomplete, or incompatible" "duplicate availability did not fail closed"
  pass "Codex quota gate rejects telemetry with ambiguous cardinality"
}

test_internal_continuations_gate_only_secondmate_workers() {
  local home calls out rc
  home=$(make_case continuation)
  calls="$home/quota.calls"
  write_policy "$home"

  out=$(run_gate_role "$home" continuation codex gpt-5 \
    FM_FAKE_CODEX_REMAINING=20 FM_FAKE_QUOTA_CALLS="$calls"); rc=$?
  expect_code 0 "$rc" "a captain continuation should remain outside the worker reserve"
  [ ! -s "$calls" ] || fail "a captain continuation unnecessarily collected worker quota telemetry"

  printf '%s\n' secondmate > "$home/.fm-secondmate-home"
  out=$(run_gate_role "$home" continuation codex gpt-5 \
    FM_FAKE_CODEX_REMAINING=100 FM_FAKE_QUOTA_CALLS="$calls"); rc=$?
  expect_code 1 "$rc" "a native Codex secondmate continuation should require a verified turn-start gate"
  assert_contains "$out" "no verified turn-start quota gate" \
    "the native continuation refusal did not name the missing turn boundary"
  [ ! -s "$calls" ] || fail "a native continuation unnecessarily collected telemetry before refusing"

  out=$(run_gate_role "$home" continuation pi openai-codex/gpt-5.6-sol \
    FM_FAKE_CODEX_REMAINING=20 FM_FAKE_QUOTA_CALLS="$calls"); rc=$?
  expect_code 1 "$rc" "a Pi secondmate continuation should be denied at the reserve"
  assert_contains "$out" "20% remaining" "the Pi secondmate continuation did not reach the worker cutoff"
  pass "internal continuations gate secondmate workers without gating the captain"
}

test_delivery_requires_verified_turn_start_boundary() {
  local home calls out rc
  home=$(make_case delivery)
  calls="$home/quota.calls"
  write_policy "$home"

  out=$(run_gate_role "$home" delivery codex gpt-5 \
    FM_FAKE_CODEX_REMAINING=100 FM_FAKE_QUOTA_CALLS="$calls"); rc=$?
  expect_code 1 "$rc" "native Codex delivery should be denied without a verified turn-start gate"
  assert_contains "$out" "no verified turn-start quota gate" \
    "native Codex delivery did not name the missing turn boundary"
  [ ! -s "$calls" ] || fail "native Codex delivery unnecessarily collected telemetry before refusing"

  out=$(run_gate_role "$home" delivery pi openai-codex/gpt-5.6-sol \
    FM_FAKE_CODEX_REMAINING=21 FM_FAKE_QUOTA_CALLS="$calls"); rc=$?
  expect_code 0 "$rc" "Pi Codex delivery should proceed above the reserve for a later live recheck"
  [ -s "$calls" ] || fail "Pi Codex delivery did not collect quota telemetry"

  : > "$calls"
  out=$(run_gate_role "$home" delivery claude claude-sonnet-5 \
    FM_FAKE_CODEX_REMAINING=20 FM_FAKE_QUOTA_CALLS="$calls"); rc=$?
  expect_code 0 "$rc" "a verified non-Codex delivery should remain available"
  [ ! -s "$calls" ] || fail "a non-Codex delivery unnecessarily collected Codex telemetry"
  pass "delivery requires a verified turn-start quota boundary for Codex consumers"
}

test_policy_replacement_cannot_change_validated_cutoff() {
  local home calls out rc real_jq
  home=$(make_case policy-race)
  calls="$home/policy.calls"
  real_jq=$(command -v jq)
  write_policy "$home"
  printf '%s\n' '{"version":1,"codex":{"worker_minimum_percent_remaining":0,"active_worker_action":"drain-at-checkpoint"},"telemetry":{"maximum_snapshot_age_seconds":300,"stale_behavior":"deny"}}' \
    > "$home/replacement-policy.json"
  cat > "$home/fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -u
policy_call=0
for arg in "$@"; do
  [ "$arg" = "$FM_FAKE_POLICY_PATH" ] && policy_call=1
done
if [ "$policy_call" -eq 1 ]; then
  count=0
  [ ! -f "$FM_FAKE_POLICY_CALLS" ] || count=$(cat "$FM_FAKE_POLICY_CALLS")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_POLICY_CALLS"
  "$FM_REAL_JQ" "$@"
  status=$?
  if [ "$count" -eq 1 ]; then
    mv -f "$FM_FAKE_POLICY_REPLACEMENT" "$FM_FAKE_POLICY_PATH"
  fi
  exit "$status"
fi
exec "$FM_REAL_JQ" "$@"
SH
  chmod +x "$home/fakebin/jq"

  out=$(run_gate "$home" codex gpt-5 \
    FM_FAKE_CODEX_REMAINING=20 \
    FM_REAL_JQ="$real_jq" \
    FM_FAKE_POLICY_PATH="$home/config/quota-policy.json" \
    FM_FAKE_POLICY_REPLACEMENT="$home/replacement-policy.json" \
    FM_FAKE_POLICY_CALLS="$calls"); rc=$?
  expect_code 1 "$rc" "an atomic policy replacement should not lower the already-validated cutoff"
  assert_contains "$out" "20% remaining" "the policy replacement bypassed the captured cutoff"
  [ "$(cat "$calls")" = 1 ] || fail "the gate read the mutable policy more than once"
  pass "policy validation and extraction use one immutable read"
}

test_optional_policy_and_exact_reserve
test_policy_shape_and_source_fail_closed
test_quota_consumer_classification
test_unprotected_turn_boundary_is_policy_gated
test_stale_telemetry_fails_closed
test_ambiguous_telemetry_fails_closed
test_internal_continuations_gate_only_secondmate_workers
test_delivery_requires_verified_turn_start_boundary
test_policy_replacement_cannot_change_validated_cutoff

echo "# all fm-codex-quota-gate tests passed"
