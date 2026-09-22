#!/usr/bin/env bash
# Fail when any ELF binary in a Flutter Linux bundle needs a newer glibc than the
# target OS ships. Raspberry Pi OS Bookworm (Debian 12) has glibc 2.36.
#
# Usage: scripts/check_glibc.sh <bundle dir> <max glibc version>
#   e.g. scripts/check_glibc.sh build/linux/arm64/release/bundle 2.36
set -euo pipefail

bundle="${1:?usage: $0 <bundle dir> <max glibc version>}"
max="${2:?usage: $0 <bundle dir> <max glibc version>}"

[[ -d "$bundle" ]] || { echo "error: bundle directory not found: $bundle" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "error: readelf not found (apt-get install binutils)" >&2; exit 1; }

status=0
checked=0
while IFS= read -r -d '' f; do
  # Only ELF files carry symbol version requirements.
  [[ "$(head -c 4 -- "$f" | tr -d '\0')" == $'\x7fELF' ]] || continue
  need="$(readelf --dyn-syms -W -- "$f" | grep -o 'GLIBC_[0-9.]*' | sed 's/^GLIBC_//' | sort -Vu | tail -n 1 || true)"
  [[ -n "$need" ]] || continue
  checked=$((checked + 1))
  if [[ "$(printf '%s\n%s\n' "$need" "$max" | sort -V | tail -n 1)" == "$max" ]]; then
    printf 'ok    %-60s GLIBC_%s\n' "$f" "$need"
  else
    printf 'FAIL  %-60s GLIBC_%s (target has %s)\n' "$f" "$need" "$max"
    status=1
  fi
done < <(find "$bundle" -type f \( -perm -u+x -o -name '*.so*' \) -print0 | sort -z)

if (( checked == 0 )); then
  echo "error: no ELF binaries found under $bundle" >&2
  exit 1
fi
if (( status != 0 )); then
  echo "error: bundle needs a newer glibc than $max; it will not start on the target OS" >&2
fi
exit $status
