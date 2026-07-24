#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# The build is selected for the host platform, so the one installer CI runs also
# gives a developer machine the identical pinned ShellCheck. Without that, the
# canonical lint command (bin/fm-lint.sh, which refuses any other version for CI
# parity) was only runnable on CI's linux.x86_64 runner and exited 127 anywhere
# else, so the pre-push gate could not lint at all on a macOS checkout.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"
# Upstream publishes one archive per platform, so the pin is per platform too:
# every checksum below is for that same single pinned ShellCheck release.
PLATFORM="$(uname -s).$(uname -m)"
case "$PLATFORM" in
  Linux.x86_64)
    SLUG=linux.x86_64
    SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    ;;
  Linux.aarch64|Linux.arm64)
    SLUG=linux.aarch64
    SHA256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
    ;;
  Darwin.x86_64)
    SLUG=darwin.x86_64
    SHA256=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
    ;;
  Darwin.arm64|Darwin.aarch64)
    SLUG=darwin.aarch64
    SHA256=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
    ;;
  *)
    printf 'fm-install-shellcheck.sh: no pinned ShellCheck %s build for %s\n' \
      "$VERSION" "$PLATFORM" >&2
    exit 1
    ;;
esac
ARCHIVE="shellcheck-v${VERSION}.${SLUG}.tar.xz"
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=3
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-shellcheck.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep "$download_attempt"
  download_attempt=$((download_attempt + 1))
done
# macOS ships shasum, not coreutils' sha256sum, and the checksum is the whole
# trust anchor here, so the fallback is a different spelling of the same digest.
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
else
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
  exit 1
}
tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/shellcheck-v${VERSION}/shellcheck" "$DESTINATION/shellcheck"
"$DESTINATION/shellcheck" --version
