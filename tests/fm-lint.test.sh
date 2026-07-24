#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. fm-lint.sh now pins one exact version and both
# gates resolve it, so command, file set, config, AND version all match. A third
# axis was availability: the gate runs each step in a fresh environment, so a
# commands.lint that assumed an installed ShellCheck just exited 127 on the
# parity refusal and linted nothing. Both gates now install the pin themselves,
# which is why the tests below drive the configured command end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The authoritative file set the one owner must run.
CANON='shellcheck --norc bin/*.sh bin/backends/*.sh tests/*.sh'
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

test_owner_exists_and_executable() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable so CI/gate can run it directly"
  pass "one-owner lint script exists and is executable"
}

test_owner_defines_canonical_set() {
  assert_grep "$CANON" "$LINT" "fm-lint.sh must run the canonical shellcheck file set"
  # It must not weaken CI: no severity downgrade and no blanket disable/exclude
  # that would hide findings CI fails on.
  assert_no_grep '--severity' "$LINT" "fm-lint.sh must not lower severity below the CI default"
  assert_no_grep '--exclude' "$LINT" "fm-lint.sh must not blanket-exclude checks CI enforces"
  [ "$(grep -Fc 'exec shellcheck --norc' "$LINT")" -eq 2 ] || fail "both lint modes must ignore ambient ShellCheck configuration"
  pass "fm-lint.sh is the sole authoritative definition at CI-default severity"
}

test_ci_invokes_the_owner() {
  grep -Eq '^      - run: bin/fm-lint\.sh$' "$CI" || fail "CI lint job must invoke the one-owner script as a run step"
  # Guard against regression to an inline re-spelling of the command.
  assert_no_grep 'run: shellcheck' "$CI" "CI must call fm-lint.sh, not re-spell shellcheck inline"
  pass "CI lint job calls the one-owner script, not an inline command"
}

# nm_lint_command: the exact shell command the gate runs for its lint step,
# unescaped from .no-mistakes.yaml's single-line single-quoted scalar (where ''
# is one literal quote). The tests below drive THIS string, so they prove the
# configured command rather than a re-spelling of it.
nm_lint_command() {
  sed -n "s/^  lint: '\(.*\)'$/\1/p" "$NM" | sed "s/''/'/g"
}

test_nomistakes_invokes_the_owner() {
  local cmd
  cmd=$(nm_lint_command)
  [ -n "$cmd" ] || fail "no-mistakes commands.lint must be a single-line single-quoted command"
  assert_contains "$cmd" "bin/fm-lint.sh" "no-mistakes commands.lint must run the one-owner script"
  # Bootstrapping the pin is part of the configured command: the gate runs each
  # step in a fresh environment, and fm-lint.sh refuses any other version.
  assert_contains "$cmd" "bin/fm-install-shellcheck.sh" "no-mistakes commands.lint must install the pinned ShellCheck itself"
  # Guard against regression to an inline re-spelling of the lint definition.
  assert_not_contains "$cmd" "$CANON" "no-mistakes commands.lint must call fm-lint.sh, not re-spell shellcheck inline"
  pass "no-mistakes pre-push lint bootstraps the pin and calls the one-owner script"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_ci_installs_and_logs_the_pinned_version() {
  # CI must derive the version from the one owner (never hardcode a divergent
  # number) and log the resolved version as parity evidence.
  assert_grep "VERSION=\"\$(\"\$ROOT/bin/fm-lint.sh\" --required-version)\"" "$INSTALLER" "installer must read the version fm-lint.sh pins"
  [ "$(grep -Fc "bin/fm-install-shellcheck.sh \"\$RUNNER_TEMP/bin\"" "$CI")" -eq 4 ] || fail "lint and all three portable behavior jobs must use the shared ShellCheck installer"
  assert_grep "ACTUAL_SHA256=\$(sha256sum" "$INSTALLER" "installer must calculate the ShellCheck archive checksum"
  assert_grep "[ \"\$ACTUAL_SHA256\" = \"\$SHA256\" ]" "$INSTALLER" "installer must verify the ShellCheck archive checksum"
  assert_grep "\"\$DESTINATION/shellcheck\" --version" "$INSTALLER" "installer must log the resolved ShellCheck version as evidence"
  pass "CI installs and logs the pinned ShellCheck version from the one owner"
}

# fake_uname <fakebin> <sysname> <machine>: shadow uname so a test can pin the
# platform the installer resolves, independently of the host running the suite.
fake_uname() {
  local fakebin=$1 sysname=$2 machine=$3
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  -s) printf '%s\n' '$sysname' ;;
  -m) printf '%s\n' '$machine' ;;
  *) printf '%s\n' '$sysname' ;;
esac
SH
  chmod +x "$fakebin/uname"
}

test_installer_pins_a_build_for_every_supported_platform() {
  # Regression: the installer hardcoded CI's linux.x86_64 archive, so the pinned
  # ShellCheck could not be installed anywhere else. bin/fm-lint.sh refuses any
  # other version for CI parity, so on a developer machine the canonical lint -
  # the same command .no-mistakes.yaml commands.lint runs - exited 127 and the
  # pre-push gate had no lint at all. Each platform must resolve its own pinned
  # archive, and an unsupported one must say so instead of installing a
  # mismatched build.
  local tmp fakebin urls out rc sysname machine slug
  tmp=$(fm_test_tmproot fm-shellcheck-platform)
  fakebin=$(fm_fakebin "$tmp")
  urls="$tmp/urls"

  # curl records the archive it was asked for and fails, so the platform
  # mapping is observable without a per-platform download.
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in https://*) printf '%s\n' "$arg" >> "$CURL_URLS" ;; esac
done
exit 22
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/curl" "$fakebin/sleep"

  while read -r sysname machine slug; do
    [ -n "$sysname" ] || continue
    : > "$urls"
    fake_uname "$fakebin" "$sysname" "$machine"
    rc=0
    out=$(CURL_URLS="$urls" PATH="$fakebin:$PATH" "$INSTALLER" "$tmp/bin" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "installer reported success without a download ($sysname.$machine)"
    assert_grep "shellcheck-v$REQUIRED.$slug.tar.xz" "$urls" \
      "installer did not request the pinned $slug build on $sysname.$machine"$'\n'"$out"
  done <<EOF
Linux x86_64 linux.x86_64
Linux aarch64 linux.aarch64
Linux arm64 linux.aarch64
Darwin x86_64 darwin.x86_64
Darwin arm64 darwin.aarch64
Darwin aarch64 darwin.aarch64
EOF

  : > "$urls"
  fake_uname "$fakebin" Plan9 vax
  rc=0
  out=$(CURL_URLS="$urls" PATH="$fakebin:$PATH" "$INSTALLER" "$tmp/bin" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted a platform it has no pinned build for"
  assert_contains "$out" "no pinned ShellCheck" "installer did not name the unsupported platform refusal"
  [ ! -s "$urls" ] || fail "installer downloaded an archive for an unsupported platform"
  pass "ShellCheck installer resolves the pinned build for the host platform"
}

# fake_pinned_toolchain <fakebin>: shadow the tools the installer shells out to,
# so an installer run needs no network. `tar` materializes a stub ShellCheck that
# reports the pinned version and, on a lint run, exits with
# FM_FAKE_SHELLCHECK_EXIT - so a caller can drive the installed binary's verdict.
# The installer resolves one pinned build per platform, so this fixture's single
# hardcoded checksum is only the linux.x86_64 one; the platform is pinned to
# match, leaving the behaviour under test as the only variable. The caller
# supplies `curl`, which is what each test varies.
fake_pinned_toolchain() {
  local fakebin=$1
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198  %s\n' "$1"
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    mkdir -p "$2/shellcheck-v0.11.0"
    cat > "$2/shellcheck-v0.11.0/shellcheck" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
printf 'fm-fake-shellcheck linted %s paths\n' "$#"
exit "${FM_FAKE_SHELLCHECK_EXIT:-0}"
EOF
    chmod +x "$2/shellcheck-v0.11.0/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fake_uname "$fakebin" Linux x86_64
  chmod +x "$fakebin/sha256sum" "$fakebin/tar" "$fakebin/sleep"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-shellcheck-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fake_pinned_toolchain "$fakebin"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
[ "$count" -gt 1 ] || exit 35
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/curl"

  out=$(CURL_COUNT="$tmp/curl-count" PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 2 ] || fail "installer did not retry exactly once after recovery"
  assert_contains "$out" "download attempt 1 failed; retrying" "installer did not disclose its retry"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck after retrying"
  pass "ShellCheck installer retries a transient download failure"
}

test_nomistakes_lint_bootstraps_the_pin() {
  # Regression: commands.lint was a bare `bin/fm-lint.sh`, but the gate runs its
  # lint step in a fresh environment with no ShellCheck on PATH, so the pre-push
  # lint exited 127 on the parity refusal and the gate had no lint at all - the
  # same blind spot the configured command was added to close. The configured
  # command must install the pin itself, lint under exactly that build, hand back
  # ShellCheck's own exit status, and leave nothing behind. Driven through the
  # real installer and the real one-owner script with a stubbed download, so it
  # proves the whole configured command rather than any part of it in isolation.
  local cmd tmp fakebin scratch out rc
  cmd=$(nm_lint_command)
  tmp=$(fm_test_tmproot fm-lint-gate)
  fakebin=$(fm_fakebin "$tmp")
  scratch="$tmp/tmpdir"
  mkdir -p "$scratch"

  fake_pinned_toolchain "$fakebin"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/curl"

  # TMPDIR is redirected into the fixture so the directory the command creates
  # is observable: an empty scratch afterwards is the cleanup proof.
  rc=0
  out=$(cd "$ROOT" && TMPDIR="$scratch" PATH="$fakebin:$PATH" FM_FAKE_SHELLCHECK_EXIT=0 sh -c "$cmd" 2>&1) || rc=$?
  expect_code 0 "$rc" "configured lint command failed with no ShellCheck on PATH"$'\n'"$out"
  assert_contains "$out" "fm-fake-shellcheck" "configured lint command did not lint with the ShellCheck it installed"
  assert_contains "$out" "(pinned $REQUIRED)" "configured lint command did not resolve the pinned ShellCheck"
  [ -z "$(ls -A "$scratch")" ] || fail "configured lint command left its ShellCheck directory behind"

  # A finding must reach the gate as a failure: an exit status swallowed by the
  # bootstrap would report a passing lint that never ran clean.
  rc=0
  out=$(cd "$ROOT" && TMPDIR="$scratch" PATH="$fakebin:$PATH" FM_FAKE_SHELLCHECK_EXIT=3 sh -c "$cmd" 2>&1) || rc=$?
  expect_code 3 "$rc" "configured lint command did not propagate ShellCheck's exit status"$'\n'"$out"
  [ -z "$(ls -A "$scratch")" ] || fail "configured lint command left its ShellCheck directory behind after a finding"
  pass "configured lint command bootstraps the pin, propagates lint status, and cleans up"
}

test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\nlicense: x\nwebsite: y\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_owner_exists_and_executable
test_owner_defines_canonical_set
test_ci_invokes_the_owner
test_nomistakes_invokes_the_owner
test_pins_an_explicit_version
test_ci_installs_and_logs_the_pinned_version
test_installer_pins_a_build_for_every_supported_platform
test_installer_retries_transient_download_failure
test_nomistakes_lint_bootstraps_the_pin
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
