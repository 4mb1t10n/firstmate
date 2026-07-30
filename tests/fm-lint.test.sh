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
# parity refusal and linted nothing. fm-lint.sh now bootstraps the pin itself,
# reusing a version-and-platform-keyed ShellCheck cache instead of re-downloading
# on every push, which is why the tests below drive the configured command end to
# end. The cache tests prove cold install, warm offline reuse, invalid entry
# replacement, fail-closed behaviour when no valid cache exists, that a
# non-pinned ShellCheck on PATH is never linted with, and that a PATH already
# supplying the pin (as CI's runner does) neither downloads nor caches.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

test_list_files_reports_the_shell_inventory() {
  local listed expected
  listed=$("$LINT" --list-files)
  expected=$(find bin bin/backends tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  [ "$(printf '%s\n' "$listed" | LC_ALL=C sort)" = "$expected" ] \
    || fail "fm-lint.sh --list-files did not return the complete shell inventory"
  pass "fm-lint.sh --list-files reports the complete shell inventory"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
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

# write_fake_shellcheck <path> <version>: drop an executable stub ShellCheck at
# <path> that reports <version> on `--version` and, on a lint run, prints a
# marker and exits FM_FAKE_SHELLCHECK_EXIT (default 0). Used to pre-seed a cache
# entry so the gate's reuse/replace decision can be driven without a network.
write_fake_shellcheck() {
  local path=$1 version=$2
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: $version\n'
  exit 0
fi
printf 'fm-fake-shellcheck linted %s paths\n' "\$#"
exit "\${FM_FAKE_SHELLCHECK_EXIT:-0}"
SH
  chmod +x "$path"
}

# lint_cache_entry <cache-home>: the version-and-platform-keyed cache path
# fm-lint.sh resolves under XDG_CACHE_HOME. The platform is pinned to Linux
# x86_64 to match fake_uname, so a test can seed or inspect the exact entry.
lint_cache_entry() {
  printf '%s/firstmate/shellcheck/%s-Linux-x86_64/shellcheck\n' "$1" "$REQUIRED"
}

# shadow_unpinned_shellcheck <fakebin> <version-or-empty>: shadow `shellcheck` on
# PATH with a stub that is NOT the pin, so every bootstrap test below takes the
# bootstrap path deterministically even on a host that already has the pin
# installed. An empty <version> reports nothing and exits non-zero, which is what
# fm-lint.sh's version probe sees when ShellCheck is absent altogether. Linting
# through this stub prints a marker distinct from write_fake_shellcheck's, so a
# test can assert the non-pinned ShellCheck was never used to lint.
shadow_unpinned_shellcheck() {
  local fakebin=$1 version=$2
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  [ -n '$version' ] || exit 127
  printf 'ShellCheck - shell script analysis tool\nversion: $version\n'
  exit 0
fi
printf 'fm-unpinned-shellcheck linted %s paths\n' "\$#"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
}

# fake_download_ok <fakebin>: a `curl` stub that "downloads" the archive by
# truncating the output path, so the installer proceeds to the stubbed checksum
# and tar without a network.
fake_download_ok() {
  cat > "$1/curl" <<'SH'
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
  chmod +x "$1/curl"
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

test_lint_bootstraps_the_pin() {
  # Regression: the lint runner may start in a fresh environment with no
  # lint step in a fresh environment with no ShellCheck on PATH, so the pre-push
  # lint exited 127 on the parity refusal and the gate had no lint at all - the
  # same blind spot the bootstrap was added to close. The lint command must
  # install the pin itself (into a version-and-platform-keyed cache),
  # lint under exactly that build, hand back ShellCheck's own exit status, and
  # leave no staging behind. This drives the public lint command and installer
  # with a stubbed download.
  local cmd tmp fakebin cache store out rc
  cmd=$LINT
  tmp=$(fm_test_tmproot fm-lint-bootstrap)
  fakebin=$(fm_fakebin "$tmp")
  cache="$tmp/cache"
  store="$cache/firstmate/shellcheck"

  fake_pinned_toolchain "$fakebin"
  fake_download_ok "$fakebin"
  shadow_unpinned_shellcheck "$fakebin" ''

  # First run cold-installs the pin into the redirected cache and lints under it.
  rc=0
  out=$(cd "$ROOT" && XDG_CACHE_HOME="$cache" PATH="$fakebin:$PATH" FM_FAKE_SHELLCHECK_EXIT=0 sh -c "$cmd" 2>&1) || rc=$?
  expect_code 0 "$rc" "configured lint command failed with no ShellCheck on PATH"$'\n'"$out"
  assert_contains "$out" "fm-fake-shellcheck" "configured lint command did not lint with the ShellCheck it installed"
  assert_contains "$out" "(pinned $REQUIRED)" "configured lint command did not resolve the pinned ShellCheck"
  [ -x "$(lint_cache_entry "$cache")" ] || fail "configured lint command did not populate the version-and-platform-keyed cache"
  [ -z "$(ls -d "$store"/.staging.* 2>/dev/null)" ] || fail "configured lint command left its staging directory behind"

  # A finding must reach the gate as a failure: an exit status swallowed by the
  # bootstrap would report a passing lint that never ran clean. This run reuses
  # the now-warm cache, so it also proves propagation on the reuse path.
  rc=0
  out=$(cd "$ROOT" && XDG_CACHE_HOME="$cache" PATH="$fakebin:$PATH" FM_FAKE_SHELLCHECK_EXIT=3 sh -c "$cmd" 2>&1) || rc=$?
  expect_code 3 "$rc" "configured lint command did not propagate ShellCheck's exit status"$'\n'"$out"
  [ -z "$(ls -d "$store"/.staging.* 2>/dev/null)" ] || fail "configured lint command left its staging directory behind after a finding"
  pass "configured lint command bootstraps the pin into the cache, propagates lint status, and cleans staging"
}

test_lint_cold_install() {
  # Cold cache: the one owner must install the checksum-verified pin, populate the
  # version-and-platform-keyed cache entry, and lint under it.
  local tmp fakebin cache out rc entry
  tmp=$(fm_test_tmproot fm-lint-cache-cold)
  fakebin=$(fm_fakebin "$tmp")
  cache="$tmp/cache"
  entry=$(lint_cache_entry "$cache")

  fake_pinned_toolchain "$fakebin"
  fake_download_ok "$fakebin"
  shadow_unpinned_shellcheck "$fakebin" ''

  [ ! -e "$entry" ] || fail "cold-install fixture started with a populated cache"
  rc=0
  out=$(XDG_CACHE_HOME="$cache" PATH="$fakebin:$PATH" FM_FAKE_SHELLCHECK_EXIT=0 "$LINT" 2>&1) || rc=$?
  expect_code 0 "$rc" "fm-lint.sh failed to cold-install the pin"$'\n'"$out"
  [ -x "$entry" ] || fail "fm-lint.sh did not populate the keyed cache entry on a cold cache"
  [ "$("$entry" --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ] \
    || fail "fm-lint.sh cached a ShellCheck other than the pin"
  assert_contains "$out" "fm-fake-shellcheck" "fm-lint.sh did not lint with the freshly cached ShellCheck"
  pass "fm-lint.sh cold-installs the pin into the keyed cache and lints under it"
}

test_lint_warm_offline_reuse() {
  # A valid cache entry must be reused with no network: an offline run (curl only
  # records its call and fails) still lints, and the installer is never invoked.
  local tmp fakebin cache out rc entry called
  tmp=$(fm_test_tmproot fm-lint-cache-warm)
  fakebin=$(fm_fakebin "$tmp")
  cache="$tmp/cache"
  entry=$(lint_cache_entry "$cache")
  called="$tmp/curl-called"

  fake_uname "$fakebin" Linux x86_64
  shadow_unpinned_shellcheck "$fakebin" ''
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$CURL_CALLED"
exit 22
SH
  chmod +x "$fakebin/curl"

  write_fake_shellcheck "$entry" "$REQUIRED"

  rc=0
  out=$(CURL_CALLED="$called" XDG_CACHE_HOME="$cache" PATH="$fakebin:$PATH" FM_FAKE_SHELLCHECK_EXIT=0 "$LINT" 2>&1) || rc=$?
  expect_code 0 "$rc" "fm-lint.sh failed to reuse a valid cache entry offline"$'\n'"$out"
  [ ! -f "$called" ] || fail "fm-lint.sh hit the network despite a valid cache entry"
  assert_contains "$out" "fm-fake-shellcheck" "fm-lint.sh did not lint with the cached ShellCheck"
  pass "fm-lint.sh reuses a valid cache entry offline without re-downloading"
}

test_lint_invalid_entry_replaced() {
  # A cache entry reporting the wrong version must be treated as invalid and
  # atomically replaced with a fresh checksum-verified install of the pin.
  local tmp fakebin cache out rc entry
  tmp=$(fm_test_tmproot fm-lint-cache-invalid)
  fakebin=$(fm_fakebin "$tmp")
  cache="$tmp/cache"
  entry=$(lint_cache_entry "$cache")

  fake_pinned_toolchain "$fakebin"
  fake_download_ok "$fakebin"
  shadow_unpinned_shellcheck "$fakebin" ''

  write_fake_shellcheck "$entry" 0.9.9
  [ "$("$entry" --version | awk '/^version:/ {print $2; exit}')" = "0.9.9" ] \
    || fail "invalid-entry fixture did not seed a stale ShellCheck"

  rc=0
  out=$(XDG_CACHE_HOME="$cache" PATH="$fakebin:$PATH" FM_FAKE_SHELLCHECK_EXIT=0 "$LINT" 2>&1) || rc=$?
  expect_code 0 "$rc" "fm-lint.sh failed to replace an invalid cache entry"$'\n'"$out"
  [ "$("$entry" --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ] \
    || fail "fm-lint.sh did not replace the stale cache entry with the pin"
  assert_contains "$out" "fm-fake-shellcheck" "fm-lint.sh did not lint after replacing the stale entry"
  pass "fm-lint.sh replaces an invalid cache entry with the pinned ShellCheck"
}

test_lint_fails_closed_offline_cold() {
  # The binding fail-closed guarantee: with no valid cache and no network, the one
  # owner must exit non-zero and never lint. A skipped lint reported as a pass is
  # exactly the blind spot this whole mechanism exists to remove.
  local tmp fakebin cache store out rc entry
  tmp=$(fm_test_tmproot fm-lint-cache-failclosed)
  fakebin=$(fm_fakebin "$tmp")
  cache="$tmp/cache"
  store="$cache/firstmate/shellcheck"
  entry=$(lint_cache_entry "$cache")

  fake_pinned_toolchain "$fakebin"
  shadow_unpinned_shellcheck "$fakebin" ''
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 22
SH
  chmod +x "$fakebin/curl"

  [ ! -e "$entry" ] || fail "fail-closed fixture started with a populated cache"
  rc=0
  out=$(XDG_CACHE_HOME="$cache" PATH="$fakebin:$PATH" FM_FAKE_SHELLCHECK_EXIT=0 "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed with no valid cache and no network"$'\n'"$out"
  assert_contains "$out" "not linting" "fm-lint.sh did not disclose that it refused to lint"
  assert_not_contains "$out" "fm-fake-shellcheck" "fm-lint.sh linted despite failing to obtain the pinned ShellCheck"
  [ ! -e "$entry" ] || fail "fm-lint.sh left a cache entry behind after a failed install"
  [ -z "$(ls -d "$store"/.staging.* 2>/dev/null)" ] || fail "fm-lint.sh left staging behind after a failed install"
  pass "fm-lint.sh fails closed when no valid cache exists and the pin cannot be installed"
}

test_never_lints_under_a_non_pinned_shellcheck() {
  # Version-independent parity: a shellcheck on PATH reporting a different version
  # must never be the one that lints. With no valid cache and no network the run
  # must fail closed instead of silently falling back to it, so local and CI cannot
  # diverge on rule set. (When the pin IS obtainable, the bootstrap replaces the
  # non-pin instead - proven by the cold-install test.)
  local tmp fakebin cache out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  cache="$tmp/cache"

  fake_pinned_toolchain "$fakebin"
  shadow_unpinned_shellcheck "$fakebin" 0.9.9
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 22
SH
  chmod +x "$fakebin/curl"

  rc=0
  out=$(XDG_CACHE_HOME="$cache" PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version"
  assert_not_contains "$out" "fm-unpinned-shellcheck" "fm-lint.sh linted with the non-pinned ShellCheck on PATH"
  pass "fm-lint.sh never lints under a non-pinned ShellCheck version"
}

test_lint_reuses_a_pinned_path_shellcheck() {
  # CI installs the pin onto PATH itself, so the bootstrap must recognize that and
  # neither download nor populate a cache - otherwise every CI lint job would pay
  # for a redundant install of the build it already has.
  local tmp fakebin cache out rc called
  tmp=$(fm_test_tmproot fm-lint-pinned-path)
  fakebin=$(fm_fakebin "$tmp")
  cache="$tmp/cache"
  called="$tmp/curl-called"

  fake_uname "$fakebin" Linux x86_64
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$CURL_CALLED"
exit 22
SH
  chmod +x "$fakebin/curl"
  write_fake_shellcheck "$fakebin/shellcheck" "$REQUIRED"

  rc=0
  out=$(CURL_CALLED="$called" XDG_CACHE_HOME="$cache" PATH="$fakebin:$PATH" FM_FAKE_SHELLCHECK_EXIT=0 "$LINT" 2>&1) || rc=$?
  expect_code 0 "$rc" "fm-lint.sh failed with the pin already on PATH"$'\n'"$out"
  assert_contains "$out" "fm-fake-shellcheck" "fm-lint.sh did not lint with the pinned ShellCheck already on PATH"
  [ ! -f "$called" ] || fail "fm-lint.sh downloaded ShellCheck despite the pin already being on PATH"
  [ ! -e "$cache/firstmate" ] || fail "fm-lint.sh populated a cache despite the pin already being on PATH"
  pass "fm-lint.sh reuses a pinned PATH ShellCheck without downloading or caching"
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

test_jobs_are_deterministic_and_complete() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): deterministic bounded jobs check"
    return
  fi
  local tmp good bad_a bad_b out_clean_1 out_clean_2 out_fail_1 out_fail_2 out_fail_2b
  local telemetry telemetry_out cleanup_tmp cleanup_out rc_clean_1 rc_clean_2 rc_fail_1 rc_fail_2 rc_fail_2b rc_bad_jobs
  tmp=$(fm_test_tmproot fm-lint-jobs)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  bad_a="$tmp/bad-a.sh"
  bad_b="$tmp/bad-b.sh"
  telemetry="$tmp/telemetry.tsv"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$bad_a" <<'SH'
#!/usr/bin/env bash
bad_a() {
  local a= b=
  printf '%s\n' "$a$b"
}
SH
  cat > "$bad_b" <<'SH'
#!/usr/bin/env bash
bad_b() {
  printf '%s\n' $1
}
SH

  rc_clean_1=0
  out_clean_1=$(FM_LINT_JOBS=1 "$LINT" "$good" 2>&1) || rc_clean_1=$?
  rc_clean_2=0
  out_clean_2=$(FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) || rc_clean_2=$?
  [ "$rc_clean_1" -eq 0 ] && [ "$rc_clean_2" -eq 0 ] || fail "clean jobs=1/jobs=2 paths must both pass"
  [ "$out_clean_1" = "$out_clean_2" ] || fail "clean jobs=1/jobs=2 output differs"

  rc_fail_1=0
  out_fail_1=$(FM_LINT_JOBS=1 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_1=$?
  rc_fail_2=0
  out_fail_2=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2=$?
  rc_fail_2b=0
  out_fail_2b=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2b=$?
  [ "$rc_fail_1" -ne 0 ] && [ "$rc_fail_1" -eq "$rc_fail_2" ] && [ "$rc_fail_2" -eq "$rc_fail_2b" ] \
    || fail "failing jobs=1/jobs=2 exit results differ: $rc_fail_1/$rc_fail_2/$rc_fail_2b"
  [ "$out_fail_1" = "$out_fail_2" ] && [ "$out_fail_2" = "$out_fail_2b" ] \
    || fail "failing diagnostics are not byte-identical and deterministic across jobs"
  assert_contains "$out_fail_1" "SC1007" "the first failing root diagnostic was lost"
  assert_contains "$out_fail_1" "SC2086" "the later failing root diagnostic was lost"
  rc_bad_jobs=0
  FM_LINT_JOBS=3 "$LINT" "$good" >/dev/null 2>&1 || rc_bad_jobs=$?
  [ "$rc_bad_jobs" -eq 2 ] || fail "the lint owner must reject unbounded worker counts"

  telemetry_out=$(FM_LINT_JOBS=2 FM_LINT_TELEMETRY="$telemetry" "$LINT" "$good" 2>&1) \
    || fail "telemetry-enabled clean lint failed"
  [ "$telemetry_out" = "$out_clean_2" ] || fail "quiet telemetry changed routine lint output"
  assert_grep $'format\tfm-lint-telemetry-v1' "$telemetry" "telemetry format marker is missing"
  assert_grep $'jobs\t2' "$telemetry" "telemetry did not record bounded jobs"
  assert_grep $'root_count\t1' "$telemetry" "telemetry did not record root count"
  assert_grep $'wall_seconds\t' "$telemetry" "telemetry did not record wall time"
  assert_grep $'user_seconds\t' "$telemetry" "telemetry did not record user CPU"
  assert_grep $'system_seconds\t' "$telemetry" "telemetry did not record system CPU"
  assert_grep $'max_worker_rss_kib\t' "$telemetry" "telemetry did not record maximum RSS"
  assert_grep $'source_boundary_directives\t' "$telemetry" "telemetry did not record source-graph boundaries"
  assert_grep $'shellcheck_processes_start\t' "$telemetry" "telemetry did not record competing ShellCheck conditions"

  cleanup_tmp="$tmp/lint-tmp"
  mkdir -p "$cleanup_tmp"
  cleanup_out=$(TMPDIR="$cleanup_tmp" FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) \
    || fail "cleanup fixture lint failed"
  [ "$cleanup_out" = "$out_clean_2" ] || fail "cleanup fixture changed routine diagnostics"
  [ -z "$(find "$cleanup_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
    || fail "bounded lint left temporary worker state behind"
  pass "jobs=1 and jobs=2 preserve deterministic diagnostics, failures, cleanup bounds, and quiet telemetry"
}

test_worker_trees_stop_on_signal() {
  local tmp fakebin fixture jobs telemetry lint_tmp pid_file out_file telemetry_file
  local parent_pid shellcheck_pid i parent_rc survivor
  tmp=$(fm_test_tmproot fm-lint-signal)
  mkdir -p "$tmp"
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/good.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
printf '%s\n' "$$" > "$FM_TEST_SHELLCHECK_PID"
trap 'exit 143' HUP INT TERM
while :; do
  sleep 1
done
SH
  chmod +x "$fakebin/shellcheck"

  for jobs in 1 2; do
    for telemetry in off on; do
      lint_tmp="$tmp/lint-$jobs-$telemetry"
      pid_file="$tmp/shellcheck-$jobs-$telemetry.pid"
      out_file="$tmp/output-$jobs-$telemetry"
      telemetry_file=
      mkdir -p "$lint_tmp"
      if [ "$telemetry" = on ]; then
        telemetry_file="$tmp/telemetry-$jobs.tsv"
      fi
      PATH="$fakebin:$PATH" TMPDIR="$lint_tmp" FM_LINT_JOBS="$jobs" \
        FM_LINT_TELEMETRY="$telemetry_file" FM_TEST_SHELLCHECK_PID="$pid_file" \
        "$LINT" "$fixture" > "$out_file" 2>&1 &
      parent_pid=$!
      i=0
      while [ "$i" -lt 500 ] && [ ! -s "$pid_file" ]; do
        kill -0 "$parent_pid" 2>/dev/null || break
        sleep 0.01
        i=$((i + 1))
      done
      [ -s "$pid_file" ] || {
        kill -TERM "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "jobs=$jobs telemetry=$telemetry did not start ShellCheck"
      }
      shellcheck_pid=$(cat "$pid_file")
      kill -TERM "$parent_pid" 2>/dev/null \
        || fail "jobs=$jobs telemetry=$telemetry parent could not be interrupted"
      parent_rc=0
      wait "$parent_pid" 2>/dev/null || parent_rc=$?
      survivor=0
      i=0
      while [ "$i" -lt 100 ] && kill -0 "$shellcheck_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
      if kill -0 "$shellcheck_pid" 2>/dev/null; then
        survivor=1
        kill -KILL "$shellcheck_pid" 2>/dev/null || true
      fi
      [ "$parent_rc" -eq 143 ] \
        || fail "jobs=$jobs telemetry=$telemetry signal exit was $parent_rc, expected 143"
      [ "$survivor" -eq 0 ] \
        || fail "jobs=$jobs telemetry=$telemetry left ShellCheck running"
      [ -z "$(find "$lint_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
        || fail "jobs=$jobs telemetry=$telemetry left temporary worker state"
    done
  done
  pass "jobs=1 and jobs=2 stop complete worker trees with and without telemetry"
}

test_seeded_module_boundary_parity() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): seeded source-boundary parity check"
    return
  fi
  local tmp rel adapter dispatcher dep owner test_root out rc
  tmp=$(mktemp -d "$ROOT/.fm-lint-parity.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$tmp")
  rel=${tmp#"$ROOT/"}
  adapter="$tmp/adapter.sh"
  dispatcher="$tmp/dispatcher.sh"
  dep="$tmp/owner-dep.sh"
  owner="$tmp/owner.sh"
  test_root="$tmp/test-local.sh"

  cat > "$adapter" <<'SH'
#!/usr/bin/env bash
adapter_bad() {
  rm $1
}
SH
  cat > "$dispatcher" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$adapter"
dispatcher_bad() {
  local a= b=
  printf '%s\n' "\$a\$b"
}
SH
  cat > "$dep" <<'SH'
#!/usr/bin/env bash
owner_dependency_value=ok
SH
  cat > "$owner" <<SH
#!/usr/bin/env bash
# shellcheck source=$rel/owner-dep.sh
. "$dep"
owner_bad() {
  printf '%s\n' "\$owner_dependency_value"
  cd "\$1"
}
SH
  cat > "$test_root" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$owner"
test_local_bad() {
  local output=\$(printf ok)
  printf '%s\n' "\$output"
}
SH

  rc=0
  out=$(FM_LINT_JOBS=2 "$LINT" "$dispatcher" "$adapter" "$owner" "$test_root" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "seeded module-boundary defects unexpectedly passed"
  assert_contains "$out" "SC1007" "representative dispatcher defect was hidden"
  assert_contains "$out" "SC2086" "representative canonical adapter defect was hidden"
  assert_contains "$out" "SC2164" "representative production-owner defect was hidden"
  assert_contains "$out" "SC2155" "representative test-local defect was hidden"
  assert_not_contains "$out" "SC2154" "the production owner lost source-aware dependency context"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2086 (info)')" -eq 1 ] \
    || fail "the dispatcher boundary re-imported the adapter diagnostic"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2164 (warning)')" -eq 1 ] \
    || fail "the test boundary re-imported the production-owner diagnostic"
  pass "seeded dispatcher, adapter, production-owner, and test-local diagnostics preserve parity"
}

test_list_files_reports_the_shell_inventory
test_pins_an_explicit_version
test_installer_pins_a_build_for_every_supported_platform
test_installer_retries_transient_download_failure
test_lint_bootstraps_the_pin
test_lint_cold_install
test_lint_warm_offline_reuse
test_lint_invalid_entry_replaced
test_lint_fails_closed_offline_cold
test_never_lints_under_a_non_pinned_shellcheck
test_lint_reuses_a_pinned_path_shellcheck
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_jobs_are_deterministic_and_complete
test_worker_trees_stop_on_signal
test_seeded_module_boundary_parity
