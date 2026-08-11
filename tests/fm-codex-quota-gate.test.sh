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
jq -n --argjson remaining "$remaining" --arg refreshed "$refreshed" \
  --arg status "$status" --argjson stale "$stale" '
  {
    schemaVersion: 3,
    providers: [{
      provider: "codex",
      state: {status: $status, stale: $stale, refreshedAt: $refreshed},
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [{
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

run_gate() {
  local home=$1 harness=$2 model=$3
  shift 3
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$@" \
    "$GATE" worker "$harness" "$model" 2>&1
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

test_stale_telemetry_fails_closed() {
  local home out rc
  home=$(make_case stale)
  write_policy "$home"
  out=$(run_gate "$home" codex gpt-5 FM_FAKE_CODEX_STATUS=stale FM_FAKE_CODEX_STALE=true); rc=$?
  expect_code 1 "$rc" "stale Codex telemetry should deny a new worker turn"
  assert_contains "$out" "stale, incomplete, or incompatible" "the stale telemetry refusal was not actionable"
  pass "Codex quota gate fails closed on stale telemetry"
}

test_optional_policy_and_exact_reserve
test_policy_shape_and_source_fail_closed
test_quota_consumer_classification
test_stale_telemetry_fails_closed

echo "# all fm-codex-quota-gate tests passed"
