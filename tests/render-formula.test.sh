#!/usr/bin/env bash
# Covers scripts/render-formula.sh: every exit, every note it prints, and the
# formula it renders.
#
#   tests/render-formula.test.sh              run the suite
#   bashcov -- tests/render-formula.test.sh   run it and measure coverage
#
# No network and no ports. Each case gets its own world: a ${FAKE_WWW} tree
# standing in for releases.knaix.com, a PATH holding only the tools the script
# uses -- curl among them replaced by tests/fake-curl -- and a fixture formula
# reached through KNAIX_TAP_FORMULA. Limiting PATH is what lets a case decide
# whether sha256sum exists, so both arms of sha256_of run on any machine.
# SC2312: the helpers below are called inside assertions, where their exit
# status is masked by design -- a helper that fails shows up as the assertion
# failing on an empty value, which is the report this suite exists to print.
# shellcheck disable=SC2312
set -uo pipefail

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TESTS}/../scripts/render-formula.sh"
PLATFORMS=(darwin-arm64 darwin-x86_64 linux-arm64 linux-x86_64)
HOST="http://releases.test"

# Everything the script and the stand-in curl shell out to, so a world's PATH
# can hold just these.
TOOLS=(awk bash cat cp dirname mktemp rm sed tr)

for tool in "${TOOLS[@]}" shasum
do
  command -v "${tool}" >/dev/null || {
    printf 'These tests need %s on PATH.\n' "${tool}" >&2
    exit 1
  }
done

pass=0
fail=0

ok() {
  printf 'ok   %s\n' "$1"
  pass=$((pass + 1))
}

bad() {
  printf 'FAIL %s\n       %s\n' "$1" "$2"
  fail=$((fail + 1))
}

eq() {
  if [[ "$2" == "$3" ]]
  then
    ok "$1"
  else
    bad "$1" "expected [$2], got [$3]"
  fi
}

has() {
  if [[ "$3" == *"$2"* ]]
  then
    ok "$1"
  else
    bad "$1" "expected to contain [$2], got [$3]"
  fi
}

lacks() {
  if [[ "$3" != *"$2"* ]]
  then
    ok "$1"
  else
    bad "$1" "expected not to contain [$2], got [$3]"
  fi
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# What the stand-in curl was asked for, one URL per line.
fetched() { awk '{print $NF}' "${LOG}"; }

# A fresh world. Call before each case.
world() {
  # Templated rather than a bare -d: BSD mktemp ignores TMPDIR without one, and
  # a sandboxed run only has somewhere to write if TMPDIR is honoured.
  work="$(mktemp -d "${TMPDIR:-/tmp}/render-formula.XXXXXX")" || exit 1
  trash+=("${work}")
  WWW="${work}/www"
  BIN="${work}/bin"
  LOG="${work}/curl.log"
  FORMULA="${work}/knaix.rb"
  FORCE=""
  mkdir -p "${WWW}" "${BIN}"
  : >"${LOG}"
  for tool in "${TOOLS[@]}"
  do
    ln -sf "$(command -v "${tool}")" "${BIN}/${tool}"
  done
  ln -sf "${TESTS}/fake-curl" "${BIN}/curl"
  ln -sf "$(command -v shasum)" "${BIN}/shasum"
}

# Offer sha256sum as well, which the script prefers over shasum.
with_sha256sum() { ln -sf "${TESTS}/fake-sha256sum" "${BIN}/sha256sum"; }

# Publish a version: latest-version, the four binaries and their sidecars.
publish() {
  printf '%s\n' "$1" >"${WWW}/latest-version"
  mkdir -p "${WWW}/v$1"
  for platform in "${PLATFORMS[@]}"
  do
    printf 'knaix %s %s\n' "$1" "${platform}" >"${WWW}/v$1/knaix-${platform}"
    sha_of "${WWW}/v$1/knaix-${platform}" >"${WWW}/v$1/knaix-${platform}.sha256"
  done
}

# A fixture formula pinning a version, with the checksums the bucket serves for
# it, or a stand-in when that version was never published.
pin() {
  {
    printf 'class Knaix < Formula\n  version "%s"\n' "$1"
    for platform in "${PLATFORMS[@]}"
    do
      sidecar="${WWW}/v$1/knaix-${platform}.sha256"
      printf '      url "%s/v%s/knaix-%s"\n' "${HOST}" "$1" "${platform}"
      if [[ -f "${sidecar}" ]]
      then
        printf '      sha256 "%s"\n' "$(cat "${sidecar}")"
      else
        printf '      sha256 "%064d"\n' 0
      fi
    done
  } >"${FORMULA}"
}

# Run the script in this world. Sets ${stdout}, ${stderr} and ${status}.
render() {
  stdout="$(
    PATH="${BIN}" \
      KNAIX_RELEASES_URL="${HOST}" \
      KNAIX_TAP_FORMULA="${FORMULA}" \
      KNAIX_TAP_FORCE_VERIFY="${FORCE}" \
      FAKE_WWW="${WWW}" \
      FAKE_CURL_LOG="${LOG}" \
      "${SCRIPT}" "$@" 2>"${work}/err"
  )"
  status=$?
  stderr="$(cat "${work}/err")"
}

trash=()
cleanup() {
  for dir in ${trash+"${trash[@]}"}
  do
    rm -rf "${dir}"
  done
}
trap cleanup EXIT

# --- latest-version decides whether there is anything to do ------------------

world
render
eq 'unreachable latest-version is not ready' 3 "${status}"
has 'unreachable latest-version says so' "Could not read ${HOST}/latest-version." "${stderr}"

world
: >"${WWW}/latest-version"
render
eq 'empty latest-version is not ready' 3 "${status}"
has 'empty latest-version says so' "${HOST}/latest-version is empty." "${stderr}"

world
publish 1.2.3
render 2.0.0
eq 'a version ahead of the publish is not ready' 3 "${status}"
has 'a version ahead of the publish says what is served' \
  'asked for 2.0.0, but http://releases.test/latest-version still serves 1.2.3' "${stderr}"

# --- the full download-and-verify path ---------------------------------------

world
publish 1.2.3
pin 0.9.0
render
eq 'a formula behind the release renders' 0 "${status}"
has 'the rendered formula carries the published version' 'version "1.2.3"' "${stdout}"
has 'the rendered formula points at the published binary' \
  'url "http://releases.test/v1.2.3/knaix-darwin-arm64"' "${stdout}"
has 'the rendered formula pins the verified checksum' \
  "sha256 \"$(sha_of "${WWW}/v1.2.3/knaix-linux-x86_64")\"" "${stdout}"
has 'a full verify says so' 'All 4 platforms verified at v1.2.3.' "${stderr}"
# The token the stats query keys on to file this traffic as ci rather than as an
# install. Asserted on every request, since one unmarked fetch is one phantom
# install.
eq 'every request carries the bump token' '' \
  "$(grep -v 'knaix-tap-bump' "${LOG}" || true)"

world
publish 1.2.3
pin 0.9.0
with_sha256sum
render v1.2.3
eq 'a v-prefixed version renders with sha256sum' 0 "${status}"
has 'sha256sum produces the same checksum' \
  "sha256 \"$(sha_of "${WWW}/v1.2.3/knaix-darwin-arm64")\"" "${stdout}"

world
publish 1.2.3
pin 0.9.0
render '' "${work}/out.rb"
eq 'rendering to a file succeeds' 0 "${status}"
has 'rendering to a file says where it went' "Wrote ${work}/out.rb." "${stderr}"
has 'the file holds the formula' 'version "1.2.3"' "$(cat "${work}/out.rb")"
eq 'nothing goes to stdout as well' '' "${stdout}"

world
publish 1.2.3
pin 0.9.0
rm "${WWW}/v1.2.3/knaix-linux-arm64"
render
eq 'a missing binary is not ready' 3 "${status}"
has 'a missing binary names its url' \
  'Not ready: http://releases.test/v1.2.3/knaix-linux-arm64 is not reachable.' "${stderr}"

world
publish 1.2.3
pin 0.9.0
rm "${WWW}/v1.2.3/knaix-darwin-x86_64.sha256"
render
eq 'a missing sidecar is not ready' 3 "${status}"
has 'a missing sidecar names its url' \
  'Not ready: http://releases.test/v1.2.3/knaix-darwin-x86_64.sha256 is not reachable.' "${stderr}"

world
publish 1.2.3
pin 0.9.0
sidecar_says="$(cat "${WWW}/v1.2.3/knaix-darwin-arm64.sha256")"
printf 'truncated\n' >"${WWW}/v1.2.3/knaix-darwin-arm64"
render
eq 'a binary that does not match its sidecar fails' 1 "${status}"
has 'a mismatch names both checksums' \
  "Checksum mismatch for knaix-darwin-arm64: sidecar says ${sidecar_says}, the binary is $(sha_of "${WWW}/v1.2.3/knaix-darwin-arm64")." \
  "${stderr}"
lacks 'a mismatch renders nothing' 'class Knaix' "${stdout}"

# --- reusing checksums the formula already carries ---------------------------

world
publish 1.2.3
pin 1.2.3
render
eq 'a formula already at the release renders' 0 "${status}"
has 'the reuse says it matched the sidecars' \
  'Formula already pins v1.2.3; reused its checksums after matching each against its published sidecar.' "${stderr}"
has 'the reused formula still carries the version' 'version "1.2.3"' "${stdout}"
eq 'the reuse downloads no binary' '' "$(fetched | grep -v -e 'latest-version' -e '\.sha256$' || true)"

world
publish 1.2.3
pin 1.2.3
sed -i.bak 's/sha256 ".*"/sha256 "not-a-checksum"/' "${FORMULA}"
render
eq 'a formula with an unusable checksum still renders' 0 "${status}"
has 'an unusable checksum falls through to the bucket' \
  'Formula pins v1.2.3 but has no usable checksum for knaix-darwin-arm64; re-verifying from the bucket.' "${stderr}"
has 'the fall-through verifies everything' 'All 4 platforms verified at v1.2.3.' "${stderr}"

world
publish 1.2.3
pin 1.2.3
rm "${WWW}/v1.2.3/knaix-linux-x86_64.sha256"
render
eq 'a sidecar that will not load is not fatal' 3 "${status}"
has 'a sidecar that will not load falls through' \
  'Could not read the published sidecar for knaix-linux-x86_64; re-verifying from the bucket.' "${stderr}"

world
publish 1.2.3
pin 1.2.3
printf 'republished\n' >"${WWW}/v1.2.3/knaix-darwin-x86_64"
sha_of "${WWW}/v1.2.3/knaix-darwin-x86_64" >"${WWW}/v1.2.3/knaix-darwin-x86_64.sha256"
render
eq 'a release republished under the same version renders the new bytes' 0 "${status}"
has 'a changed sidecar falls through' \
  'Published sidecar for knaix-darwin-x86_64 no longer matches the pinned checksum; re-verifying from the bucket.' "${stderr}"
has 'the new checksum is the one rendered' \
  "sha256 \"$(sha_of "${WWW}/v1.2.3/knaix-darwin-x86_64")\"" "${stdout}"

world
publish 1.2.3
pin 1.2.3
FORCE=1
render
eq 'forcing a verify renders' 0 "${status}"
has 'forcing a verify skips the reuse' 'All 4 platforms verified at v1.2.3.' "${stderr}"

world
publish 1.2.3
render
eq 'no formula to read is not fatal' 0 "${status}"
has 'no formula to read means a full verify' 'All 4 platforms verified at v1.2.3.' "${stderr}"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
