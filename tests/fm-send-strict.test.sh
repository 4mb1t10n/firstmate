#!/usr/bin/env bash
# fm-send strict target resolution and key delivery reporting.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
# They also verify that a key send reports whether delivery actually succeeded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    # FM_FAKE_TMUX_SEND_KEY_FAIL names one key whose delivery fails, so the
    # --key exit contract can be driven both ways from the same stub.
    if [ "$literal" = 0 ] && [ -n "${FM_FAKE_TMUX_SEND_KEY_FAIL:-}" ] \
      && [ "${1:-}" = "$FM_FAKE_TMUX_SEND_KEY_FAIL" ]; then
      exit 1
    fi
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys") : ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
remaining=${FM_FAKE_CODEX_REMAINING:-100}
if [ -n "${FM_FAKE_QUOTA_ENTERED:-}" ]; then
  : > "$FM_FAKE_QUOTA_ENTERED"
  while [ ! -e "$FM_FAKE_QUOTA_RELEASE" ]; do
    /bin/sleep 0.01
  done
fi
jq -n --argjson remaining "$remaining" --arg refreshed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {
    schemaVersion: 3,
    providers: [{
      provider: "codex",
      state: {status: "fresh", stale: false, refreshedAt: $refreshed},
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
  chmod +x "$fb/quota-axi"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

enable_quota_policy() {
  local home=$1
  printf '%s\n' '{"version":1,"codex":{"worker_minimum_percent_remaining":20,"brain_handoff_percent_remaining":10,"brain_emergency_minimum_percent_remaining":5,"active_worker_action":"drain-at-checkpoint"},"selection":"task-and-quota-aware","context":{"compaction_trigger_used_fraction":0.5},"telemetry":{"poll_seconds":60,"maximum_snapshot_age_seconds":300,"stale_behavior":"deny"}}' \
    > "$home/config/quota-policy.json"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err log herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; log="$dir/tmux.log"; herdr_log="$dir/herdr.log"
  : > "$log"
  : > "$herdr_log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted as explicit"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send strict: fm-prefixed Herdr sessions remain explicit backend targets"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

test_native_codex_policy_preserves_only_control_keys() {
  local dir fb home err log rc submitting_key
  dir="$TMP_ROOT/codex-drain"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home codexdrain); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-drain.meta" "window=sess:fm-lane-drain" "kind=ship" "harness=codex" "model=gpt-5.6" "quota_identity=structured" "quota_turn_gate=none"
  enable_quota_policy "$home"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=100 FM_SEND_SETTLE=0 \
    "$SEND" lane-drain "start another turn" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "native Codex text should fail without a verified turn-start gate"
  assert_contains "$(cat "$err")" "no verified turn-start quota gate" \
    "the native Codex refusal did not name its missing turn boundary"
  assert_contains "$(cat "$err")" "let the active turn drain" \
    "the native Codex refusal did not preserve in-flight draining"
  [ ! -s "$log" ] || fail "a denied Codex text turn still reached the endpoint"

  for submitting_key in Enter enter C-m; do
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
      FM_FAKE_CODEX_REMAINING=100 FM_SEND_SETTLE=0 \
      "$SEND" lane-drain --key "$submitting_key" >/dev/null 2>"$err"; rc=$?
    expect_code 1 "$rc" "$submitting_key should not bypass the native Codex turn boundary"
    [ ! -s "$log" ] || fail "a denied Codex $submitting_key still reached the endpoint"
  done

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=20 FM_SEND_SETTLE=0 \
    "$SEND" lane-drain --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a control key should remain available at the Codex reserve"
  assert_contains "$(cat "$log")" "arg=Escape" \
    "the control key did not reach the draining Codex worker"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=20 FM_SEND_SETTLE=0 \
    "$SEND" lane-drain --key Ctrl-C >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an interrupt alias should remain available at the Codex reserve"
  assert_contains "$(cat "$log")" "arg=C-c" \
    "the normalized interrupt did not reach the draining Codex worker"
  pass "native Codex policy preserves in-flight drain and control keys"
}

test_quota_policy_covers_pi_and_unknown_endpoints() {
  local dir fb home err log rc
  dir="$TMP_ROOT/quota-identities"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home quotaidentities); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  enable_quota_policy "$home"
  fm_write_meta "$home/state/lane-pi.meta" "window=sess:fm-lane-pi" "kind=ship" "harness=pi" "model=openai-codex/gpt-5.6-sol" "quota_identity=structured" "quota_turn_gate=before-agent-start"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=20 FM_SEND_SETTLE=0 \
    "$SEND" lane-pi "start another turn" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "Pi using an openai-codex model should respect the reserve"
  [ ! -s "$log" ] || fail "a denied Pi Codex text turn still reached the endpoint"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=21 FM_SEND_SETTLE=0 \
    "$SEND" lane-pi "continue above reserve" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "Pi Codex delivery should proceed above the reserve for its live turn recheck"
  assert_contains "$(cat "$log")" "arg=continue above reserve" \
    "an allowed Pi Codex delivery did not reach the endpoint"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=100 FM_SEND_SETTLE=0 \
    "$SEND" sess:outside "unclassified turn" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "text to an endpoint without harness identity should be denied under the policy"
  assert_contains "$(cat "$err")" "does not prove a structured launch" \
    "the explicit-endpoint refusal did not name its missing launch provenance"
  [ ! -s "$log" ] || fail "an ambiguous explicit-endpoint text turn still reached the endpoint"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=20 FM_SEND_SETTLE=0 \
    "$SEND" sess:outside --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a non-submitting interrupt should remain available on an explicit endpoint"
  assert_contains "$(cat "$log")" "arg=Escape" \
    "the explicit-endpoint interrupt did not reach the worker"
  pass "quota-aware sends cover Pi Codex models and unknown explicit endpoints"
}

test_endpoint_meta_override_keeps_target_identity_narrow() {
  local dir fb home err log meta rc
  dir="$TMP_ROOT/endpoint-override"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home endpointoverride); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  mkdir -p "$home/state/parent-route"
  meta="$home/state/parent-route/route.meta"
  fm_write_meta "$meta" "window=sess:fm-route" "worktree=$home" "project=$home" "kind=secondmate" "harness=claude" "model=claude-sonnet-5" "quota_identity=structured" "quota_turn_gate=none"
  enable_quota_policy "$home"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_ENDPOINT_META_OVERRIDE="$meta" FM_FAKE_CODEX_REMAINING=100 FM_SEND_SETTLE=0 \
    "$SEND" sess:fm-route "continue remotely" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an exact endpoint metadata override should resolve its recorded target"
  assert_contains "$(cat "$log")" "target=sess:fm-route literal=1 arg=continue remotely" \
    "the endpoint override did not preserve the remote target identity"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_ENDPOINT_META_OVERRIDE="$meta" FM_FAKE_CODEX_REMAINING=100 FM_SEND_SETTLE=0 \
    "$SEND" sess:fm-other "wrong route" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "an endpoint metadata override should reject a different requested target"
  assert_contains "$(cat "$err")" "binds 'sess:fm-route', not requested target 'sess:fm-other'" \
    "the mismatched override refusal did not name both targets"
  [ ! -s "$log" ] || fail "a mismatched endpoint metadata override still attempted delivery"
  pass "fm-send endpoint metadata overrides bind only their exact target"
}

test_quota_policy_refuses_unproven_legacy_metadata() {
  local dir fb home err log rc
  dir="$TMP_ROOT/legacy-provenance"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home legacyprovenance); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  enable_quota_policy "$home"
  fm_write_meta "$home/state/legacy.meta" "window=sess:fm-legacy" "kind=ship" "harness=claude" "model=claude-sonnet-5"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=100 FM_SEND_SETTLE=0 \
    "$SEND" legacy "legacy composite command" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "legacy metadata should not prove a safe quota identity"
  assert_contains "$(cat "$err")" "relaunch the endpoint with a verified adapter" \
    "legacy metadata refusal did not explain how to establish provenance"
  [ ! -s "$log" ] || fail "unproven legacy metadata still reached the endpoint"

  fm_write_meta "$home/state/raw-pi.meta" "window=sess:fm-raw-pi" "kind=ship" "harness=pi" "model=openai-codex/gpt-5.6-sol" "quota_identity=unprotected" "quota_turn_gate=none"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=100 FM_SEND_SETTLE=0 \
    "$SEND" raw-pi "raw Pi continuation" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "raw Pi metadata should not claim a generated turn-start gate"
  [ ! -s "$log" ] || fail "unprotected raw Pi metadata still reached the endpoint"
  pass "quota-aware sends require proven endpoint launch provenance"
}

test_submitting_delivery_holds_the_task_lifecycle_lock() {
  local dir fb home err log entered release sender send_rc lock_rc
  dir="$TMP_ROOT/lifecycle-lock"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home lifecyclelock); err="$dir/send.err"; log="$dir/tmux.log"
  entered="$dir/quota.entered"; release="$dir/quota.release"; : > "$log"
  enable_quota_policy "$home"
  fm_write_meta "$home/state/lane-race.meta" "window=sess:fm-lane-race" "kind=ship" "harness=pi" "model=openai-codex/gpt-5.6-sol" "quota_identity=structured" "quota_turn_gate=before-agent-start"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_CODEX_REMAINING=21 FM_FAKE_QUOTA_ENTERED="$entered" \
    FM_FAKE_QUOTA_RELEASE="$release" FM_SEND_SETTLE=0 \
    "$SEND" lane-race "continue after drain" >/dev/null 2>"$err" &
  sender=$!
  for _ in $(seq 1 200); do
    [ -e "$entered" ] && break
    /bin/sleep 0.01
  done
  [ -e "$entered" ] || { kill "$sender" 2>/dev/null || true; fail "send did not reach its quota checkpoint"; }

  lock_rc=0
  STATE="$home/state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then
      fm_lock_release "$2"
      exit 0
    fi
    exit 1
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/.control-lane-race.lock" || lock_rc=$?
  : > "$release"
  send_rc=0
  wait "$sender" || send_rc=$?

  expect_code 1 "$lock_rc" "a relaunch must not acquire the task lock during submission authorization"
  expect_code 0 "$send_rc" "the authorized Pi continuation should still be delivered"
  assert_contains "$(cat "$log")" "arg=continue after drain" \
    "the lifecycle-locked continuation did not reach the endpoint"
  pass "fm-send submission stays atomic with task lifecycle changes"
}

# A --key send is how firstmate interrupts a worker, so its exit status is the
# only signal that the interrupt actually landed.
# Reporting success for a key that was never delivered would leave supervision
# believing a runaway worker had been stopped, so the failing case must exit
# nonzero and name the key.
# Both directions are asserted from one stub so the failing case cannot go
# quietly vacuous if the key ever stops being delivered at all.
test_key_send_exit_status_follows_delivery() {
  local dir fb home err log rc
  dir="$TMP_ROOT/key-exit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyexit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-key.meta" "window=sess:fm-lane-key" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a delivered --key interrupt should report success"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the delivered case should send the named key"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_SEND_KEY_FAIL=Escape \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an undelivered --key interrupt reported success"
  assert_contains "$(cat "$err")" "key 'Escape' not sent" "the undelivered case should name the key that failed"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the undelivered case should still have attempted the send"
  pass "fm-send --key: exit status follows delivery, and an undelivered key never reports success"
}

test_exact_lane_id_send_still_works
test_key_send_exit_status_follows_delivery
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
test_native_codex_policy_preserves_only_control_keys
test_quota_policy_covers_pi_and_unknown_endpoints
test_endpoint_meta_override_keeps_target_identity_narrow
test_quota_policy_refuses_unproven_legacy_metadata
test_submitting_delivery_holds_the_task_lifecycle_lock
