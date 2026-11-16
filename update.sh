#!/usr/bin/env bash
# Usage: ./update.sh stable|nightly [version]
#        ./update.sh --outdated   lists channels behind their latest release
set -euo pipefail
cd "$(dirname "$0")"

if [[ $# -lt 1 || $# -gt 2 || ($1 != stable && $1 != nightly && $1 != --outdated) || ($1 == --outdated && $# != 1) ]]; then
  echo "Usage: $0 stable|nightly [version] | --outdated" >&2
  exit 1
fi

NIX=${NIX:-nix}
fake=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

latest() {
  local tag
  case $1 in
    stable) tag=$(gh api repos/pingdotgg/t3code/releases/latest --jq '.tag_name // empty') || return ;;
    nightly) tag=$(gh api 'repos/pingdotgg/t3code/releases?per_page=30' --jq '[.[] | select(.tag_name | test("-nightly\\."))][0].tag_name // empty') || return ;;
    *) echo "Unknown channel: $1" >&2; exit 1 ;;
  esac
  [[ -n $tag ]] || { echo "Could not resolve the $1 version" >&2; exit 1; }
  echo "${tag#v}"
}

get() { sed -n "s/^  $1 = \"\(.*\)\";/\1/p" "$file"; }
set_value() { sed -i "s|^  $1 = \".*\";|  $1 = \"$2\";|" "$file"; }

# Builds a fixed-output derivation with a fake hash and stores the hash Nix reports.
fix_hash() {
  set_value "$1" "$fake"
  local hash log
  log=$("$NIX" build --no-link ".#$channel.$2" 2>&1) || true
  hash=$(sed -n 's/.*got: *\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' <<< "$log" | tail -1)
  [[ -n $hash ]] || { echo "$log" >&2; echo "Could not compute $1. Use stock Nix through NIX=/path/to/nix." >&2; exit 1; }
  set_value "$1" "$hash"
}

if [[ $1 == --outdated ]]; then
  for channel in stable nightly; do
    file=sources/$channel.nix
    version=$(latest "$channel") || exit 1
    [[ $version == "$(get version)" ]] || echo "$channel"
  done
  exit 0
fi

channel=$1
file=sources/$channel.nix
version=${2:-$(latest "$channel")}
version=${version#v}
[[ $version =~ ^[0-9][A-Za-z0-9.+-]*$ ]] || { echo "Invalid version: $version" >&2; exit 1; }
if [[ $version == "$(get version)" ]]; then
  echo "$channel is already $version"
  exit 0
fi

backup=$(mktemp)
cp "$file" "$backup"
trap 'status=$?; if (( status != 0 )); then cp "$backup" "$file"; fi; rm -f "$backup"' EXIT

set_value version "$version"
fix_hash hash src
spdxRev=$(sed -n 's/^const SPDX_LICENSE_LIST_REVISION = "\(.*\)";/\1/p' \
  "$("$NIX" build --no-link --print-out-paths ".#$channel.src")/scripts/lib/third-party-licenses.ts")
[[ -n $spdxRev ]] || { echo "Could not resolve the SPDX revision" >&2; exit 1; }
if [[ $spdxRev != "$(get spdxRev)" ]]; then
  set_value spdxRev "$spdxRev"
  fix_hash spdxHash spdxLicenses
fi
fix_hash cargoHash resourceMonitor.cargoDeps
fix_hash pnpmDepsHash pnpmDeps
echo "Updated $channel to $version"
