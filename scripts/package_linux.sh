#!/usr/bin/env bash
# Package the Flutter Linux release bundle into a distributable tarball.
#
# Usage:  scripts/package_linux.sh <arm64|x64> <version>
# Input:  build/linux/<arch>/release/bundle      (from `flutter build linux --release`)
# Output: dist/smart_bite-linux-<arch>.tar.gz    (top-level directory: smart_bite/)
#         dist/smart_bite-linux-<arch>.tar.gz.sha256
#
# Used by .github/workflows/release.yml; can also be run locally.
set -euo pipefail

arch="${1:?usage: $0 <arm64|x64> <version>}"
version="${2:?usage: $0 <arm64|x64> <version>}"

case "$arch" in
  arm64|x64) ;;
  *) echo "error: arch must be arm64 or x64 (got '$arch')" >&2; exit 1 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$root/build/linux/$arch/release/bundle"
dist="$root/dist"
asset="smart_bite-linux-$arch.tar.gz"

if [[ ! -x "$bundle/smart_bite" ]]; then
  echo "error: $bundle/smart_bite not found; run 'flutter build linux --release' first" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

cp -a "$bundle" "$stage/smart_bite"
printf '%s\n' "$version" > "$stage/smart_bite/VERSION"

mkdir -p "$dist"
tar -C "$stage" --owner=0 --group=0 --numeric-owner -czf "$dist/$asset" smart_bite
(cd "$dist" && sha256sum "$asset" > "$asset.sha256")

echo "Packaged smart_bite $version ($arch):"
ls -l "$dist/$asset" "$dist/$asset.sha256"
