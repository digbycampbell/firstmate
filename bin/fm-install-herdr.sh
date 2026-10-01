#!/usr/bin/env bash
# fm-install-herdr.sh - install the latest official Herdr release for CI.
#
# Resolves GitHub's latest non-prerelease release for ogulcancelik/herdr,
# selects the official host asset, and verifies GitHub's published SHA-256
# digest when one is present. The required real-Herdr CI lane follows upstream
# releases while retaining bounded downloads and the protocol feature floor.
#
# Usage:
#   fm-install-herdr.sh <destination-directory>
#
# Downloads the official GitHub Releases asset for the host OS/arch with a
# bounded maximum size, verifies any published digest, then refuses to finish
# unless the binary reports a client protocol at or above 16.
set -eu

FM_HERDR_CI_MIN_PROTOCOL=16
# Bounded download ceilings in bytes.
FM_HERDR_CI_MAX_METADATA_BYTES=1000000
FM_HERDR_CI_MAX_BYTES=50000000
FM_HERDR_CI_REPO=ogulcancelik/herdr

die() {
  printf 'fm-install-herdr.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-herdr.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET=herdr-linux-x86_64
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=herdr-linux-aarch64
    ;;
  Darwin-arm64)
    ASSET=herdr-macos-aarch64
    ;;
  Darwin-x86_64)
    ASSET=herdr-macos-x86_64
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Herdr assets are linux/macos x86_64 and aarch64"
    ;;
esac

TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-herdr.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

API_URL="https://api.github.com/repos/${FM_HERDR_CI_REPO}/releases/latest"
printf 'fm-install-herdr.sh: resolving latest release from %s\n' "$API_URL" >&2
curl -fsSL --max-filesize "$FM_HERDR_CI_MAX_METADATA_BYTES" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$API_URL" -o "$TMP/release.json" \
  || die "release lookup failed for $API_URL (bounded at $FM_HERDR_CI_MAX_METADATA_BYTES bytes)"

jq -e '.draft == false and .prerelease == false' "$TMP/release.json" >/dev/null 2>&1 \
  || die "GitHub's latest release response was not a stable release"
TAG=$(jq -er '.tag_name | select(type == "string" and length > 0)' "$TMP/release.json" 2>/dev/null) \
  || die "GitHub's latest release response had no tag"
ASSET_COUNT=$(jq -r --arg asset "$ASSET" '[.assets[]? | select(.name == $asset)] | length' "$TMP/release.json" 2>/dev/null) \
  || die "could not read assets from GitHub's latest release response"
[ "$ASSET_COUNT" = 1 ] \
  || die "latest Herdr release $TAG has $ASSET_COUNT assets named $ASSET; expected exactly one"
URL=$(jq -er --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .browser_download_url' "$TMP/release.json" 2>/dev/null) \
  || die "latest Herdr release $TAG has no download URL for $ASSET"
ASSET_SIZE=$(jq -er --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .size' "$TMP/release.json" 2>/dev/null) \
  || die "latest Herdr release $TAG has no size for $ASSET"
DIGEST=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .digest // empty' "$TMP/release.json" 2>/dev/null) \
  || die "could not read the published digest for $ASSET"

case "$URL" in
  https://github.com/*/releases/download/*/"$ASSET") ;;
  *) die "latest Herdr release $TAG returned a non-release download URL for $ASSET" ;;
esac
case "$ASSET_SIZE" in
  ''|*[!0-9]*) die "latest Herdr release $TAG returned an invalid size for $ASSET" ;;
esac
[ "$ASSET_SIZE" -gt 0 ] && [ "$ASSET_SIZE" -le "$FM_HERDR_CI_MAX_BYTES" ] \
  || die "latest Herdr release $TAG reports $ASSET at $ASSET_SIZE bytes, outside the 1-$FM_HERDR_CI_MAX_BYTES byte bound"

printf 'fm-install-herdr.sh: downloading %s from Herdr %s\n' "$ASSET" "$TAG" >&2
curl -fsSL --max-filesize "$FM_HERDR_CI_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $FM_HERDR_CI_MAX_BYTES bytes)"

if [ -n "$DIGEST" ]; then
  case "$DIGEST" in
    sha256:*) SHA256=${DIGEST#sha256:} ;;
    *) die "latest Herdr release $TAG published an unsupported digest for $ASSET: $DIGEST" ;;
  esac
  case "$SHA256" in
    *[!0-9a-f]*|'') die "latest Herdr release $TAG published a malformed SHA-256 digest for $ASSET" ;;
  esac
  [ "${#SHA256}" -eq 64 ] \
    || die "latest Herdr release $TAG published a malformed SHA-256 digest for $ASSET"
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
  else
    die "need sha256sum or shasum to verify Herdr's published digest"
  fi
  [ "$ACTUAL_SHA256" = "$SHA256" ] \
    || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"
else
  printf 'fm-install-herdr.sh: Herdr %s publishes no digest for %s; relying on HTTPS from GitHub Releases\n' \
    "$TAG" "$ASSET" >&2
fi

mkdir -p "$DESTINATION"
install -m 0755 "$TMP/$ASSET" "$DESTINATION/herdr"

# Post-install protocol gate.
installed_version=$("$DESTINATION/herdr" --version 2>/dev/null | awk '{print $2; exit}')
[ -n "$installed_version" ] || die "installed herdr did not report a version"

status=$("$DESTINATION/herdr" status --json 2>/dev/null) \
  || die "could not run 'herdr status --json' after install"
protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null) \
  || die "jq is required to parse herdr status after install"
case "$protocol" in
  ''|*[!0-9]*) die "could not read herdr client protocol from status --json" ;;
esac
[ "$protocol" -ge "$FM_HERDR_CI_MIN_PROTOCOL" ] \
  || die "herdr protocol $protocol is below the required floor $FM_HERDR_CI_MIN_PROTOCOL"

printf 'fm-install-herdr.sh: installed herdr %s (protocol %s) to %s\n' \
  "$installed_version" "$protocol" "$DESTINATION/herdr" >&2
"$DESTINATION/herdr" --version
