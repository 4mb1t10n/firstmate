#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-policy-inheritance)

write_policy() {
  local path=$1
  mkdir -p "${path%/*}"
  printf '%s\n' '{"version":1,"codex":{"worker_minimum_percent_remaining":20,"active_worker_action":"drain-at-checkpoint"},"telemetry":{"maximum_snapshot_age_seconds":300,"stale_behavior":"deny"}}' > "$path"
}

test_override_is_materialized_for_nested_homes() {
  local src="$TMP_ROOT/materialize/src" dest="$TMP_ROOT/materialize/dest"
  local override="$TMP_ROOT/materialize/declarative/quota.json" rc
  mkdir -p "$src" "$dest"
  write_policy "$override"
  printf 'old local policy\n' > "$dest/quota-policy.json"

  FM_INHERITABLE_CONFIG=quota-policy.json FM_QUOTA_POLICY_PATH="$override" \
    propagate_inheritable_config "$src" "$dest"
  rc=$?

  expect_code 0 "$rc" "an external quota-policy override should inherit successfully"
  cmp -s "$override" "$dest/quota-policy.json" \
    || fail "the resolved quota-policy override was not materialized in the nested home"
  pass "quota-policy inheritance materializes the resolved override"
}

test_unsafe_override_does_not_remove_nested_policy() {
  local src="$TMP_ROOT/unsafe/src" dest="$TMP_ROOT/unsafe/dest"
  local override="$TMP_ROOT/unsafe/declarative/quota.json" out rc before
  mkdir -p "$src" "$dest" "${override%/*}"
  write_policy "$dest/quota-policy.json"
  before=$(cat "$dest/quota-policy.json")
  ln -s "$TMP_ROOT/unsafe/declarative/missing.json" "$override"

  out=$(FM_INHERITABLE_CONFIG=quota-policy.json FM_QUOTA_POLICY_PATH="$override" \
    propagate_inheritable_config "$src" "$dest" 2>&1)
  rc=$?

  expect_code 1 "$rc" "an unsafe quota-policy override should fail inheritance"
  assert_contains "$out" "unsafe primary quota policy source" \
    "the unsafe override refusal was not actionable"
  [ "$(cat "$dest/quota-policy.json")" = "$before" ] \
    || fail "an unsafe override removed or changed the nested policy"
  pass "unsafe quota-policy overrides preserve the last nested policy"
}

test_override_is_materialized_for_nested_homes
test_unsafe_override_does_not_remove_nested_policy

echo "# all fm-quota-policy-inheritance tests passed"
