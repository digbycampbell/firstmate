#!/usr/bin/env bash
# fm-install-slack-mirror.sh - install the pinned agent-slack-mirror release.
#
# The terminal-to-Slack mirror now lives in its own public repository,
# https://github.com/digbycampbell/agent-slack-mirror; this script fetches the
# pinned commit of that repository into the destination directory so
# bin/fm-slack-mirror.sh can resolve the tool there instead of the in-tree
# copy. The pin is a full commit id, so the fetch is content-addressed and
# needs no separate checksum: a clone whose HEAD does not equal the pin is
# refused and nothing is installed.
#
# The tool lands at <destination-directory>/agent-slack-mirror/, replacing any
# previous install atomically (built beside, then swapped in), so a failed
# download can never leave a half-installed tool where the mirror would run it.
#
# Usage:
#   fm-install-slack-mirror.sh <destination-directory>
set -eu

REPO_URL=https://github.com/digbycampbell/agent-slack-mirror
PINNED_COMMIT=2cae976f7c48c6f7a02533a349cc9d32ac0f002e

die() {
  printf 'fm-install-slack-mirror.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-slack-mirror.sh <destination-directory>}
command -v git >/dev/null 2>&1 || die "need git to fetch the pinned release"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-mirror-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=4
download_attempt=1
while ! git clone -q "$REPO_URL" "$TMP/clone" 2>/dev/null; do
  rm -rf "$TMP/clone"
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] \
    || die "clone failed after $DOWNLOAD_ATTEMPTS attempts"
  printf 'fm-install-slack-mirror.sh: clone attempt %s failed; retrying\n' \
    "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

git -C "$TMP/clone" checkout -q "$PINNED_COMMIT" \
  || die "pinned commit $PINNED_COMMIT is not in $REPO_URL"
[ "$(git -C "$TMP/clone" rev-parse HEAD)" = "$PINNED_COMMIT" ] \
  || die "checkout did not land on the pinned commit"
[ -x "$TMP/clone/slack-mirror.sh" ] \
  || die "the pinned release does not carry an executable slack-mirror.sh"

rm -rf "$TMP/clone/.git"
mkdir -p "$DESTINATION"
STAGE="$DESTINATION/.agent-slack-mirror.installing.$$"
rm -rf "$STAGE"
mv "$TMP/clone" "$STAGE"
rm -rf "$DESTINATION/agent-slack-mirror"
mv "$STAGE" "$DESTINATION/agent-slack-mirror"
printf 'installed agent-slack-mirror %s to %s\n' \
  "$PINNED_COMMIT" "$DESTINATION/agent-slack-mirror"
