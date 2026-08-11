#!/usr/bin/env bash
# Render Formula/knaix.rb from whatever releases.knaix.com currently serves.
#
#   scripts/render-formula.sh [version] [output-path]
#
# Lives here rather than in knaix-cli because the workflow that runs it lives
# here too. A bump is a push to this repository, and a workflow in this
# repository can make it with its own GITHUB_TOKEN. Driving it from knaix-cli
# meant a cross-repository push, which needed a personal access token that
# silently lost its scope and left every release needing a manual push.
#
# Both arguments are optional. Version defaults to whatever
# releases.knaix.com currently serves, output defaults to stdout.
#
# The S3 publish is a manual step (see "Releasing the Knaix CLI" in the
# kovalent repo), so this script must assume the artifacts are not there yet
# and refuses to render a formula pointing at anything it cannot download.
#
# Exit codes:
#   0  formula rendered
#   1  something is wrong (a checksum does not match its binary)
#   3  not ready yet: the release has not been published to S3
set -euo pipefail

RELEASES="${KNAIX_RELEASES_URL:-https://releases.knaix.com}"
PLATFORMS=(darwin-arm64 darwin-x86_64 linux-arm64 linux-x86_64)
NOT_READY=3

# This script runs hourly, so it is a large share of all traffic to
# releases.knaix.com. Identifying itself is what lets the download figures tell
# our own polling apart from somebody installing the CLI; without it every run
# was counted as four installs arriving by install.sh, because that is what a
# bare curl looks like in the logs.
#
# Must not contain the word "homebrew": the log classifier tests for that first,
# and this traffic is the bump job, not a brew install.
UA="knaix-tap-bump/1 (+https://github.com/kovalentai/tap-bump)"

# Set to any non-empty value to re-download and re-verify even when the formula
# already pins the published version.
FORCE_VERIFY="${KNAIX_TAP_FORCE_VERIFY:-}"

version="${1:-}"
out="${2:-}"

# The formula this script maintains. Read to reuse checksums that were already
# verified, never to decide what to publish.
formula="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Formula/knaix.rb"

note() { printf '%s\n' "$*" >&2; }

# The sha256 that the current formula pins for one platform. Matched from the
# url line rather than by position, so reordering the on_macos/on_linux blocks
# cannot silently pair a platform with another's checksum.
pinned_sha_for() {
  awk -v want="knaix-$1\"" '
    index($0, want) { found = 1; next }
    found && $1 == "sha256" { gsub(/"/, "", $2); print $2; exit }
  ' "${formula}" 2>/dev/null
}

pinned_version() {
  sed -n 's/^  version "\(.*\)"$/\1/p' "${formula}" 2>/dev/null
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1
  then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

published="$(curl -fsSL -A "${UA}" "${RELEASES}/latest-version" | tr -d '[:space:]')" ||
  {
    note "Could not read ${RELEASES}/latest-version."
    exit "${NOT_READY}"
  }

[[ -n "${published}" ]] || {
  note "${RELEASES}/latest-version is empty."
  exit "${NOT_READY}"
}

version="${version:-${published}}"
version="${version#v}"

# The formula must never get ahead of the installer. If latest-version still
# points at the previous release, the manual publish has not finished, and a
# bump now would send brew users to a version the curl installer does not yet
# serve -- or to binaries that are not uploaded at all.
if [[ "${version}" != "${published}" ]]
then
  note "Not ready: asked for ${version}, but ${RELEASES}/latest-version still serves ${published}."
  exit "${NOT_READY}"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

# Nothing has been published since the last run, so the four binaries would be
# downloaded only to recompute checksums the formula already carries. Reuse them
# and render an identical formula instead.
#
# This deliberately renders rather than exiting early. The caller treats a
# successful render as "compare and push if changed", and that path also proves
# the push credential still works -- the failure that once went unnoticed for
# several releases. Exiting here would take that check with it.
#
# Only for the unattended path: naming a version explicitly, or setting
# KNAIX_TAP_FORCE_VERIFY, always re-downloads and re-verifies.
reuse_pinned=""
if [[ -z "${1:-}" && -z "${FORCE_VERIFY}" && "$(pinned_version)" == "${version}" ]]
then
  reuse_pinned="yes"
  for platform in "${PLATFORMS[@]}"
  do
    sha="$(pinned_sha_for "${platform}")"
    # A formula missing a checksum is not one to copy from.
    if [[ ! "${sha}" =~ ^[0-9a-f]{64}$ ]]
    then
      note "Formula pins v${version} but has no usable checksum for knaix-${platform}; re-verifying from the bucket."
      reuse_pinned=""
      break
    fi
    printf '%s' "${sha}" >"${work}/${platform}.verified"
  done
fi

if [[ -n "${reuse_pinned}" ]]
then
  note "Formula already pins v${version}; reused its verified checksums without downloading."
fi

# Verified checksums go to files rather than an associative array: macOS still
# ships bash 3.2, and a command substitution could not exit the script from the
# loop anyway.
for platform in "${PLATFORMS[@]}"
do
  [[ -z "${reuse_pinned}" ]] || break

  binary_url="${RELEASES}/v${version}/knaix-${platform}"
  sidecar_url="${binary_url}.sha256"

  if ! curl -fsSL -A "${UA}" -o "${work}/${platform}" "${binary_url}"
  then
    note "Not ready: ${binary_url} is not reachable."
    exit "${NOT_READY}"
  fi
  if ! curl -fsSL -A "${UA}" -o "${work}/${platform}.sha256" "${sidecar_url}"
  then
    note "Not ready: ${sidecar_url} is not reachable."
    exit "${NOT_READY}"
  fi

  expected="$(tr -d '[:space:]' <"${work}/${platform}.sha256")"
  actual="$(sha256_of "${work}/${platform}")"

  # Recomputed from the bytes rather than copied from the sidecar. Trusting the
  # sidecar would happily bake in the checksum of a truncated upload, and brew
  # would then verify a broken binary against its own broken hash.
  if [[ "${expected}" != "${actual}" ]]
  then
    note "Checksum mismatch for knaix-${platform}: sidecar says ${expected}, the binary is ${actual}."
    exit 1
  fi

  printf '%s' "${actual}" >"${work}/${platform}.verified"
done

if [[ -z "${reuse_pinned}" ]]
then
  note "All ${#PLATFORMS[@]} platforms verified at v${version}."
fi

sha_darwin_arm64="$(cat "${work}/darwin-arm64.verified")"
sha_darwin_x86_64="$(cat "${work}/darwin-x86_64.verified")"
sha_linux_arm64="$(cat "${work}/linux-arm64.verified")"
sha_linux_x86_64="$(cat "${work}/linux-x86_64.verified")"

read -r -d '' formula <<EOF || true
# Generated by the bump workflow in this repository from what releases.knaix.com
# serves. Edit scripts/render-formula.sh, not this file.
class Knaix < Formula
  desc "Command-line client for Kovalent: private AI nodes with cited answers"
  homepage "https://knaix.com"
  version "${version}"
  license "Apache-2.0"

  # No livecheck block. It cannot pass brew style here: with no top-level url,
  # the LivecheckUrlSymbol cop reads livecheck's own url as the stable one and
  # demands \`url :stable\`, while ComponentsOrder demands livecheck sit above the
  # on_macos block where that happens. CI compares this version against
  # releases.knaix.com/latest-version instead, which fails louder anyway.

  on_macos do
    on_arm do
      url "${RELEASES}/v${version}/knaix-darwin-arm64"
      sha256 "${sha_darwin_arm64}"
    end
    on_intel do
      url "${RELEASES}/v${version}/knaix-darwin-x86_64"
      sha256 "${sha_darwin_x86_64}"
    end
  end

  on_linux do
    on_arm do
      url "${RELEASES}/v${version}/knaix-linux-arm64"
      sha256 "${sha_linux_arm64}"
    end
    on_intel do
      url "${RELEASES}/v${version}/knaix-linux-x86_64"
      sha256 "${sha_linux_x86_64}"
    end
  end

  def install
    # The published artifacts are bare binaries rather than archives, so the
    # staged file is renamed onto PATH instead of extracted. It arrives 0644
    # from the bucket and install keeps that mode, so set it before anything
    # tries to run the binary.
    bin.install Dir["knaix-*"].first => "knaix"
    chmod 0755, bin/"knaix"
    generate_completions_from_executable(bin/"knaix", "completions")
  end

  def caveats
    <<~EOS
      Start a node on this machine:
        knaix local setup

      Or sign in to a node Kovalent runs for you:
        knaix login
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/knaix --version")
    assert_match "_knaix", shell_output("#{bin}/knaix completions bash")
  end
end
EOF

if [[ -n "${out}" ]]
then
  printf '%s\n' "${formula}" >"${out}"
  note "Wrote ${out}."
else
  printf '%s\n' "${formula}"
fi
