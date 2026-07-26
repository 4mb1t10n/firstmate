#!/usr/bin/env bash
# fm-lint-gate.sh - run the canonical lint under a cached, pinned ShellCheck.
#
# This is the pre-push no-mistakes gate's lint entrypoint (.no-mistakes.yaml
# commands.lint). It keeps bin/fm-lint.sh as the single owner of the lint
# definition (file set, config, version pin) and only adds the bootstrap the
# gate needs: the gate runs each step in a fresh environment with nothing on
# PATH, and fm-lint.sh refuses any ShellCheck other than the pin, so a bare
# `bin/fm-lint.sh` exited 127 and the gate had no lint at all.
#
# Rather than re-download the pinned build on every push, the pin is stored in a
# version-and-platform-keyed user cache. On a cache hit the binary is reused with
# no network at all (offline runs lint fine); on a miss or an invalid entry the
# checksum-verified installer (bin/fm-install-shellcheck.sh) stages a fresh build
# and it is atomically swapped into the cache. The cache lives under an ephemeral
# user cache dir - never the repo, never declarative global config - so wiping it
# just triggers one re-download.
#
# Fail-closed: if no valid cache exists and the install cannot produce the pinned
# build (e.g. offline with a cold cache), this exits non-zero and never lints, so
# the gate can never pass on a lint that did not actually run.
#
# CI does NOT use this: its runners are ephemeral, so caching buys nothing there;
# .github/workflows/ci.yml installs the pin fresh into $RUNNER_TEMP/bin instead.
#
# Usage:
#   fm-lint-gate.sh            ensure the pinned ShellCheck, then run fm-lint.sh
#   fm-lint-gate.sh <path>...  same, forwarding paths to fm-lint.sh (dev convenience)
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The version is owned by fm-lint.sh; read it from there so the cache key can
# never pin a different ShellCheck than the lint definition enforces.
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"
PLATFORM="$(uname -s)-$(uname -m)"

# Ephemeral, regenerable user cache. Keyed by version AND platform so a version
# bump or a different host installs a fresh entry instead of reusing a stale one.
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/shellcheck"
CACHE_DIR="$CACHE_ROOT/${VERSION}-${PLATFORM}"
CACHED="$CACHE_DIR/shellcheck"

# pinned_version <shellcheck-path>: print the version the binary reports, or
# nothing if it is missing or does not run. Used inside conditions so a failure
# reads as "not the pin" (reinstall) rather than aborting under set -e.
pinned_version() {
  "$1" --version 2>/dev/null | awk '/^version:/ {print $2; exit}'
}

# Cache hit: reuse the pinned build with no network. The reuse check re-verifies
# the exact version every time, so a corrupt or superseded entry is rejected.
if [ -x "$CACHED" ] && [ "$(pinned_version "$CACHED")" = "$VERSION" ]; then
  :
else
  # Miss or invalid entry: install the checksum-verified pin into same-filesystem
  # staging, verify the staged binary is exactly the pin, then atomically swap it
  # in. If the install cannot produce the pin, set -e propagates its failure and
  # the EXIT trap clears the staging dir - fail-closed, no lint.
  mkdir -p "$CACHE_ROOT"
  staging=$(mktemp -d "$CACHE_ROOT/.staging.XXXXXX")
  trap 'rm -rf "$staging"' EXIT
  "$ROOT/bin/fm-install-shellcheck.sh" "$staging" >&2
  if [ "$(pinned_version "$staging/shellcheck")" != "$VERSION" ]; then
    printf 'fm-lint-gate.sh: staged ShellCheck is not the pinned %s\n' "$VERSION" >&2
    exit 1
  fi
  mkdir -p "$CACHE_DIR"
  # Rename the single binary within the cache filesystem: atomic, so a concurrent
  # gate run never observes a half-written cache entry.
  mv -f "$staging/shellcheck" "$CACHED"
  rm -rf "$staging"
  trap - EXIT
fi

# Hand off to the one owner with only the cache ahead of PATH, forwarding any
# developer-supplied paths. fm-lint.sh re-asserts the pin as defense in depth.
exec env PATH="$CACHE_DIR:$PATH" "$ROOT/bin/fm-lint.sh" "$@"
