#!/usr/bin/env bash
# Behavioral coverage for the latest-release Herdr installer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-herdr.sh"

make_fixture() {  # <name> <os> <arch> <protocol> <digest-mode> [reported-size]
  local name=$1 os=$2 arch=$3 protocol=$4 digest_mode=$5 reported_size=${6:-}
  local tmp fakebin asset digest size
  tmp=$(fm_test_tmproot "fm-install-herdr-$name")
  fakebin="$tmp/fakebin"
  mkdir -p "$fakebin" "$tmp/runner" "$tmp/destination"

  case "$os-$arch" in
    Linux-x86_64) asset=herdr-linux-x86_64 ;;
    Linux-aarch64|Linux-arm64) asset=herdr-linux-aarch64 ;;
    Darwin-arm64) asset=herdr-macos-aarch64 ;;
    Darwin-x86_64) asset=herdr-macos-x86_64 ;;
    *) fail "test fixture received unsupported platform $os-$arch" ;;
  esac

  cat > "$tmp/release-asset" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'herdr 9.8.7\n' ;;
  status) printf '{"client":{"version":"9.8.7","protocol":%s}}\n' "${FM_TEST_PROTOCOL:?}" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$tmp/release-asset"

  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$tmp/release-asset" | awk '{print $1}')
  else
    digest=$(shasum -a 256 "$tmp/release-asset" | awk '{print $1}')
  fi
  case "$digest_mode" in
    valid) digest_json="\"sha256:$digest\"" ;;
    invalid) digest_json='"sha256:0000000000000000000000000000000000000000000000000000000000000000"' ;;
    absent) digest_json=null ;;
    *) fail "test fixture received unknown digest mode $digest_mode" ;;
  esac
  size=${reported_size:-$(wc -c < "$tmp/release-asset" | tr -d '[:space:]')}

  cat > "$tmp/release.json" <<EOF
{"tag_name":"v9.8.7","draft":false,"prerelease":false,"assets":[{"name":"$asset","size":$size,"digest":$digest_json,"browser_download_url":"https://github.com/herdrdev/herdr/releases/download/v9.8.7/$asset"}]}
EOF

  cat > "$fakebin/uname" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  -s) printf '%s\n' '$os' ;;
  -m) printf '%s\n' '$arch' ;;
  *) exit 1 ;;
esac
EOF
  cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -H|--max-filesize) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ -n "$out" ] && [ -n "$url" ] || exit 2
printf '%s\n' "$url" >> "$FM_TEST_CURL_LOG"
case "$url" in
  https://api.github.com/repos/ogulcancelik/herdr/releases/latest)
    cp "$FM_TEST_RELEASE_JSON" "$out"
    ;;
  https://github.com/*/releases/download/*)
    cp "$FM_TEST_RELEASE_ASSET" "$out"
    ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$fakebin/uname" "$fakebin/curl"

  printf '%s\t%s\t%s\t%s\n' "$tmp" "$fakebin" "$asset" "$protocol"
}

run_fixture() {  # <fixture-row>
  local row=$1 tmp fakebin asset protocol
  IFS=$'\t' read -r tmp fakebin asset protocol <<< "$row"
  FM_TEST_RELEASE_JSON="$tmp/release.json" \
    FM_TEST_RELEASE_ASSET="$tmp/release-asset" \
    FM_TEST_CURL_LOG="$tmp/curl.log" \
    FM_TEST_PROTOCOL="$protocol" \
    RUNNER_TEMP="$tmp/runner" \
    PATH="$fakebin:$PATH" \
    bash "$INSTALLER" "$tmp/destination"
}

test_platform_asset_selection_and_digest_verification() {
  local row tmp fakebin asset protocol output
  while read -r name os arch expected; do
    row=$(make_fixture "$name" "$os" "$arch" 16 valid)
    IFS=$'\t' read -r tmp fakebin asset protocol <<< "$row"
    output=$(run_fixture "$row" 2>&1) || fail "installer rejected the latest $os-$arch release"$'\n'"$output"
    [ "$asset" = "$expected" ] || fail "fixture selected $asset instead of $expected"
    assert_grep "/$expected" "$tmp/curl.log" "installer did not download the $os-$arch asset"
    assert_contains "$output" "installed herdr 9.8.7 (protocol 16)" "installer did not report the installed latest release"
    [ -x "$tmp/destination/herdr" ] || fail "installer did not install an executable for $os-$arch"
  done <<'EOF'
linux-x86 Linux x86_64 herdr-linux-x86_64
linux-arm Linux aarch64 herdr-linux-aarch64
mac-arm Darwin arm64 herdr-macos-aarch64
mac-x86 Darwin x86_64 herdr-macos-x86_64
EOF
  pass "Herdr installer selects each host asset from the latest release and verifies its published digest"
}

test_missing_digest_uses_official_https_asset() {
  local row output
  row=$(make_fixture no-digest Linux x86_64 16 absent)
  output=$(run_fixture "$row" 2>&1) || fail "installer rejected a release without a published digest"$'\n'"$output"
  assert_contains "$output" "publishes no digest" "installer did not disclose the HTTPS-only integrity path"
  pass "Herdr installer accepts an official HTTPS release asset when GitHub publishes no digest"
}

test_wrong_digest_is_rejected() {
  local row output rc
  row=$(make_fixture wrong-digest Linux x86_64 16 invalid)
  rc=0
  output=$(run_fixture "$row" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an asset that did not match its published digest"
  assert_contains "$output" "checksum mismatch" "installer did not identify the digest mismatch"
  pass "Herdr installer rejects an asset that does not match its published digest"
}

test_protocol_floor_is_enforced() {
  local row output rc
  row=$(make_fixture old-protocol Linux x86_64 15 valid)
  rc=0
  output=$(run_fixture "$row" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted a Herdr client below protocol 16"
  assert_contains "$output" "protocol 15 is below the required floor 16" "installer did not identify the protocol floor failure"
  pass "Herdr installer rejects a latest release below protocol 16"
}

test_reported_asset_size_is_bounded() {
  local row tmp fakebin asset protocol output rc
  row=$(make_fixture oversized Linux x86_64 16 valid 50000001)
  IFS=$'\t' read -r tmp fakebin asset protocol <<< "$row"
  rc=0
  output=$(run_fixture "$row" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an asset above its download bound"
  assert_contains "$output" "outside the 1-50000000 byte bound" "installer did not identify the reported-size bound"
  [ "$(wc -l < "$tmp/curl.log" | tr -d '[:space:]')" = 1 ] \
    || fail "installer attempted an asset download after rejecting its reported size"
  pass "Herdr installer rejects an oversized release asset before download"
}

test_platform_asset_selection_and_digest_verification
test_missing_digest_uses_official_https_asset
test_wrong_digest_is_rejected
test_protocol_floor_is_enforced
test_reported_asset_size_is_bounded
