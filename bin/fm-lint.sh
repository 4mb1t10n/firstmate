#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs ShellCheck over firstmate's tracked shell scripts at ShellCheck's default
# severity (which reports info, warning, and error - the levels CI fails on).
# The lint command, the file set, the config, AND the pinned ShellCheck version
# live here and ONLY here, so the gates cannot drift apart: both invoke this
# script with no arguments.
#   - CI:       .github/workflows/ci.yml installs the version this script prints
#               via `--required-version`, then runs `bin/fm-lint.sh`.
#   - Pre-push: .no-mistakes.yaml `commands.lint` runs `bin/fm-lint.sh`, so the
#               no-mistakes gate runs the SAME shellcheck as CI. Without a
#               configured commands.lint, that gate step never ran this
#               deterministic shellcheck, so info-level findings were not
#               surfaced locally before CI rejected them.
#
# Self-contained bootstrap: this script refuses any ShellCheck other than the
# pin, and the pre-push gate runs each step in a fresh environment with nothing
# on PATH, so a bare invocation there used to exit 127 and the gate had no lint
# at all. Rather than require a pre-installed tool or re-download on every push,
# a ShellCheck that is absent or not exactly the pin is resolved from a
# version-and-platform-keyed user cache; a valid entry is reused with no network
# (offline runs lint fine), and a miss or an invalid entry is replaced by the
# checksum-verified installer (bin/fm-install-shellcheck.sh) through an atomic
# swap. The cache lives under an ephemeral user cache dir - never the repo, never
# declarative global config - so wiping it just triggers one re-download. When
# PATH already supplies exactly the pin (as CI's runner does) nothing is cached
# or downloaded at all. Fail-closed: if no valid cache exists and the install
# cannot produce the pin (e.g. offline with a cold cache), this exits non-zero
# and never lints, so a gate can never pass on a lint that did not run.
#
# Version parity: CI's ShellCheck used to float with the runner image, and
# ShellCheck retired SC2015 in 0.11.0, so an older CI ShellCheck rejected an
# SC2015 that a newer local one no longer emits. This script pins one exact
# version (REQUIRED_SHELLCHECK) and asserts the resolved `shellcheck` matches it,
# so CI and local run the identical rule set. This is not a CI relaxation: it
# adopts one upstream release consistently; the only difference from the old
# floating CI is dropping the upstream-retired, false-positive-prone SC2015.
# No severity downgrade and no blanket exclude of checks - every still-supported
# finding at default severity is enforced.
# The local == CI parity contract is asserted by tests/fm-lint.test.sh.
#
# Usage:
#   fm-lint.sh                    lint the canonical file set (what both gates run)
#   fm-lint.sh <path>...          lint only the given paths with the same config
#                                  (developer convenience; the gates never pass args)
#   fm-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#
# Exit status is ShellCheck's own on a lint run, so a caller (CI or the gate)
# fails exactly when ShellCheck reports a finding; a pin that cannot be obtained
# or verified fails before linting with a distinct message.
set -eu

# The single source of the pinned ShellCheck version. Bump here and CI follows
# automatically via `--required-version`; the test suite reads it the same way.
REQUIRED_SHELLCHECK=0.11.0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Expose the pinned version without needing ShellCheck installed, so CI can read
# it to install the exact same build before any lint runs. This must stay ahead of
# the bootstrap below: bin/fm-install-shellcheck.sh reads the version from here, so
# the bootstrap's call into the installer lands on this early exit, never recursing.
if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

# Ambient options can hide findings CI fails on, so drop them before the version
# probe: the ShellCheck this resolves is then the ShellCheck it lints with.
unset SHELLCHECK_OPTS

# probe_shellcheck_version <command-or-path>: print the version that binary
# reports, or nothing when it is missing or does not run. Used inside conditions
# so "absent" and "broken" both read as "not the pin" rather than aborting under
# set -e. Deliberately not named `shellcheck_*`: a comment opening with that word
# parses as a ShellCheck directive (SC1073) instead of prose.
probe_shellcheck_version() {
  "$1" --version 2>/dev/null | awk '/^version:/ {print $2; exit}'
}

# Bootstrap the pin unless PATH already resolves exactly it. CI installs the pin
# onto PATH itself, so the whole block is skipped there: no cache, no download.
if [ "$(probe_shellcheck_version shellcheck)" != "$REQUIRED_SHELLCHECK" ]; then
  # Keyed by version AND platform so a version bump or a different host installs a
  # fresh entry instead of reusing a stale one.
  PLATFORM="$(uname -s)-$(uname -m)"
  CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/shellcheck"
  CACHE_DIR="$CACHE_ROOT/${REQUIRED_SHELLCHECK}-${PLATFORM}"
  CACHED="$CACHE_DIR/shellcheck"
  # Cache hit: reuse the pinned build with no network. Reuse re-verifies the exact
  # version every time, so a corrupt or superseded entry is rejected.
  if [ -x "$CACHED" ] && [ "$(probe_shellcheck_version "$CACHED")" = "$REQUIRED_SHELLCHECK" ]; then
    :
  else
    # Miss or invalid entry: install the checksum-verified pin into same-filesystem
    # staging, verify the staged binary is exactly the pin, then atomically swap it
    # in so a concurrent run never observes a half-written cache entry.
    mkdir -p "$CACHE_ROOT"
    staging=$(mktemp -d "$CACHE_ROOT/.staging.XXXXXX")
    trap 'rm -rf "$staging"' EXIT
    if ! "$ROOT/bin/fm-install-shellcheck.sh" "$staging" >&2; then
      printf 'fm-lint.sh: no valid ShellCheck %s cache and the pinned install failed; not linting.\n' \
        "$REQUIRED_SHELLCHECK" >&2
      exit 1
    fi
    if [ "$(probe_shellcheck_version "$staging/shellcheck")" != "$REQUIRED_SHELLCHECK" ]; then
      printf 'fm-lint.sh: staged ShellCheck is not the pinned %s; not linting.\n' \
        "$REQUIRED_SHELLCHECK" >&2
      exit 1
    fi
    mkdir -p "$CACHE_DIR"
    mv -f "$staging/shellcheck" "$CACHED"
    rm -rf "$staging"
    trap - EXIT
  fi
  PATH="$CACHE_DIR:$PATH"
  export PATH
fi

# Defense in depth: whether PATH supplied the pin or the bootstrap did, assert the
# resolved version before linting so local and CI cannot silently diverge.
resolved=$(probe_shellcheck_version shellcheck)
# Log the resolved version to stderr so both CI and local runs record it.
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  exec shellcheck --norc "$@"
fi

# Canonical file set: the ONE authoritative definition. Callers reference this
# script; they never re-spell these globs.
exec shellcheck --norc bin/*.sh bin/backends/*.sh tests/*.sh
