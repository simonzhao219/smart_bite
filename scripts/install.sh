#!/usr/bin/env bash
#
# Smart Bite installer for Raspberry Pi 4
# (Raspberry Pi OS 64-bit, Debian 12 "Bookworm" or newer)
#
# Downloads a release build from GitHub Releases, verifies its SHA-256 checksum,
# unpacks it into the install directory and creates a launcher. Re-run it to
# update. User data (~/Documents/data.csv, preferences.txt, printer_name.txt,
# rfid_timing.json) lives outside the install directory and is left untouched.
#
# Quick start (run on the Pi):
#   curl -fsSL https://raw.githubusercontent.com/simonzhao219/smart_bite/main/scripts/install.sh | sudo bash
#
# Custom location and pinned version:
#   curl -fsSL https://raw.githubusercontent.com/simonzhao219/smart_bite/main/scripts/install.sh \
#     | sudo bash -s -- --dir /home/pi/smart_bite --version v1.2.0
#
# Options:
#   --dir DIR          Install directory (default: /opt/smart_bite; env INSTALL_DIR)
#   --version TAG      Release tag such as v1.2.0 (default: latest; env SMART_BITE_VERSION)
#   --repo OWNER/REPO  GitHub repository (default: simonzhao219/smart_bite; env SMART_BITE_REPO)
#   --from-file FILE   Install from a local smart_bite-linux-<arch>.tar.gz instead of downloading
#   --arch ARCH        arm64 or x64 (default: detected with uname -m)
#   --no-deps          Skip apt-get installation of the runtime libraries
#   --no-launcher      Do not create /usr/local/bin/smart_bite
#   -h, --help         Show this help
#
# Without root the script can still install into a directory you own; the
# apt-get and launcher steps are skipped in that case.

set -euo pipefail

REPO="${SMART_BITE_REPO:-simonzhao219/smart_bite}"
INSTALL_DIR="${INSTALL_DIR:-/opt/smart_bite}"
VERSION="${SMART_BITE_VERSION:-latest}"
FROM_FILE=""
ARCH=""
INSTALL_DEPS=1
CREATE_LAUNCHER=1
LAUNCHER="/usr/local/bin/smart_bite"

if [[ -t 1 ]]; then
  C_INFO=$'\033[1;34m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Smart Bite installer for Raspberry Pi 4 (Raspberry Pi OS 64-bit, Bookworm or newer)

Usage:
  curl -fsSL https://raw.githubusercontent.com/simonzhao219/smart_bite/main/scripts/install.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/simonzhao219/smart_bite/main/scripts/install.sh | sudo bash -s -- [options]
  sudo ./install.sh [options]

Options:
  --dir DIR          Install directory (default: /opt/smart_bite; env INSTALL_DIR)
  --version TAG      Release tag such as v1.2.0 (default: latest; env SMART_BITE_VERSION)
  --repo OWNER/REPO  GitHub repository (default: simonzhao219/smart_bite; env SMART_BITE_REPO)
  --from-file FILE   Install from a local smart_bite-linux-<arch>.tar.gz instead of downloading
  --arch ARCH        arm64 or x64 (default: detected with uname -m)
  --no-deps          Skip apt-get installation of the runtime libraries
  --no-launcher      Do not create /usr/local/bin/smart_bite
  -h, --help         Show this help
USAGE
}

# --- options -----------------------------------------------------------------

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "option $1 needs a value (see --help)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)          need_value "$@"; INSTALL_DIR="$2"; shift 2 ;;
    --dir=*)        INSTALL_DIR="${1#*=}"; shift ;;
    --version)      need_value "$@"; VERSION="$2"; shift 2 ;;
    --version=*)    VERSION="${1#*=}"; shift ;;
    --repo)         need_value "$@"; REPO="$2"; shift 2 ;;
    --repo=*)       REPO="${1#*=}"; shift ;;
    --from-file)    need_value "$@"; FROM_FILE="$2"; shift 2 ;;
    --from-file=*)  FROM_FILE="${1#*=}"; shift ;;
    --arch)         need_value "$@"; ARCH="$2"; shift 2 ;;
    --arch=*)       ARCH="${1#*=}"; shift ;;
    --no-deps)      INSTALL_DEPS=0; shift ;;
    --no-launcher)  CREATE_LAUNCHER=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown option: $1 (see --help)" ;;
  esac
done

# --- preflight ---------------------------------------------------------------

[[ "$(uname -s)" == "Linux" ]] || die "this installer only supports Linux"

for tool in tar sha256sum mktemp realpath; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
if [[ -z "$FROM_FILE" ]]; then
  command -v curl >/dev/null 2>&1 || die "curl is required to download the release (sudo apt-get install curl)"
fi

if [[ -z "$ARCH" ]]; then
  case "$(uname -m)" in
    aarch64|arm64) ARCH="arm64" ;;
    x86_64)        ARCH="x64" ;;
    armv7l|armv6l)
      die "32-bit Raspberry Pi OS detected ($(uname -m)). Smart Bite needs the 64-bit OS: reinstall Raspberry Pi OS (64-bit) Bookworm or newer." ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
fi
case "$ARCH" in
  arm64|x64) ;;
  *) die "--arch must be arm64 or x64 (got '$ARCH')" ;;
esac

# Release builds are made on Debian 12 (bookworm); older Debian/Raspberry Pi OS lacks the glibc they need.
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  os_id="$( (. /etc/os-release && printf '%s' "${ID:-}") || true)"
  # shellcheck disable=SC1091
  os_version="$( (. /etc/os-release && printf '%s' "${VERSION_ID:-}") || true)"
  # shellcheck disable=SC1091
  os_pretty="$( (. /etc/os-release && printf '%s' "${PRETTY_NAME:-}") || true)"
  case "$os_id" in
    debian|raspbian)
      if [[ "$os_version" =~ ^[0-9]+$ ]] && (( os_version < 12 )); then
        warn "${os_pretty:-$os_id $os_version} detected; release builds target Debian 12 (Bookworm) or newer and will not start here."
      fi ;;
  esac
fi

is_root() { [[ "$(id -u)" -eq 0 ]]; }

INSTALL_DIR="$(realpath -m -- "$INSTALL_DIR")"
[[ "$INSTALL_DIR" != "/" && -n "$INSTALL_DIR" ]] || die "refusing to install into '$INSTALL_DIR'"

# Never replace a directory that is not a Smart Bite install (e.g. --dir /opt).
if [[ -e "$INSTALL_DIR" ]]; then
  [[ -d "$INSTALL_DIR" ]] || die "$INSTALL_DIR exists and is not a directory"
  if [[ ! -e "$INSTALL_DIR/smart_bite" && ! -e "$INSTALL_DIR/VERSION" ]] && [[ -n "$(ls -A -- "$INSTALL_DIR")" ]]; then
    die "$INSTALL_DIR exists but does not look like a Smart Bite install; choose another --dir"
  fi
fi

parent_dir="$(dirname -- "$INSTALL_DIR")"
if ! mkdir -p -- "$parent_dir" 2>/dev/null || [[ ! -w "$parent_dir" ]]; then
  die "cannot write to $parent_dir; re-run with sudo or pick a --dir inside your home directory"
fi

# --- fetch -------------------------------------------------------------------

asset="smart_bite-linux-${ARCH}.tar.gz"
workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT

if [[ -n "$FROM_FILE" ]]; then
  FROM_FILE="$(realpath -e -- "$FROM_FILE" 2>/dev/null)" || die "file not found: $FROM_FILE"
  log "Installing from $FROM_FILE"
  if [[ -f "$FROM_FILE.sha256" ]]; then
    (cd "$(dirname -- "$FROM_FILE")" && sha256sum -c --quiet -- "$(basename -- "$FROM_FILE").sha256") \
      || die "checksum verification failed for $FROM_FILE"
    log "Checksum OK"
  else
    warn "no $(basename -- "$FROM_FILE").sha256 next to the archive; skipping checksum verification"
  fi
  tarball="$FROM_FILE"
else
  if [[ "$VERSION" == "latest" ]]; then
    base_url="https://github.com/${REPO}/releases/latest/download"
  else
    base_url="https://github.com/${REPO}/releases/download/${VERSION}"
  fi
  curl_progress=(-sS)
  [[ -t 2 ]] && curl_progress=(--progress-bar)

  log "Downloading ${asset} (${VERSION}) from ${REPO}"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 "${curl_progress[@]}" \
    -o "$workdir/$asset" "$base_url/$asset" \
    || die "download failed: $base_url/$asset (no release yet, wrong --version, or no linux-${ARCH} build in that release)"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
    -o "$workdir/$asset.sha256" "$base_url/$asset.sha256" \
    || die "checksum download failed: $base_url/$asset.sha256"
  (cd "$workdir" && sha256sum -c --quiet -- "$asset.sha256") || die "checksum verification failed"
  log "Checksum OK"
  tarball="$workdir/$asset"
fi

# --- unpack and install ------------------------------------------------------

log "Unpacking"
mkdir -p -- "$workdir/extract"
tar -xzf "$tarball" -C "$workdir/extract"
[[ -x "$workdir/extract/smart_bite/smart_bite" ]] \
  || die "unexpected archive layout: smart_bite/smart_bite not found in $(basename -- "$tarball")"
new_version="$(cat -- "$workdir/extract/smart_bite/VERSION" 2>/dev/null || echo unknown)"

if [[ -f "$INSTALL_DIR/VERSION" ]]; then
  log "Updating Smart Bite $(cat -- "$INSTALL_DIR/VERSION") -> $new_version in $INSTALL_DIR"
else
  log "Installing Smart Bite $new_version into $INSTALL_DIR"
fi

staging="${INSTALL_DIR}.new.$$"
previous="${INSTALL_DIR}.old.$$"
rm -rf -- "$staging"
mv -- "$workdir/extract/smart_bite" "$staging"
if [[ -e "$INSTALL_DIR" ]]; then
  mv -- "$INSTALL_DIR" "$previous"
fi
if ! mv -- "$staging" "$INSTALL_DIR"; then
  [[ -e "$previous" ]] && mv -- "$previous" "$INSTALL_DIR"
  die "could not move the new version into $INSTALL_DIR"
fi
rm -rf -- "$previous"
chmod 755 -- "$INSTALL_DIR"

# --- runtime libraries -------------------------------------------------------

if (( INSTALL_DEPS )); then
  if is_root && command -v apt-get >/dev/null 2>&1; then
    log "Installing runtime libraries (GTK 3, EGL/GLES)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || warn "apt-get update failed; trying to install with the current package lists"
    # Debian 12 ships libgtk-3-0; Debian 13 / Ubuntu 24.04 renamed it to libgtk-3-0t64.
    gtk_pkg="libgtk-3-0"
    if ! apt-cache policy libgtk-3-0 2>/dev/null | grep -q 'Candidate: [^(]' \
       && apt-cache policy libgtk-3-0t64 2>/dev/null | grep -q 'Candidate: [^(]'; then
      gtk_pkg="libgtk-3-0t64"
    fi
    apt-get install -y -qq --no-install-recommends \
      "$gtk_pkg" libegl1 libgles2 libblkid1 liblzma5 \
      || warn "could not install the runtime libraries; make sure $gtk_pkg is present before starting the app"
  else
    warn "skipping runtime library installation (needs root and apt-get); make sure libgtk-3-0 is installed"
  fi
fi

# --- launcher ----------------------------------------------------------------

if (( CREATE_LAUNCHER )); then
  if is_root; then
    ln -sfn -- "$INSTALL_DIR/smart_bite" "$LAUNCHER"
    log "Launcher: $LAUNCHER -> $INSTALL_DIR/smart_bite"
  else
    warn "skipping $LAUNCHER (needs root); start the app with $INSTALL_DIR/smart_bite"
  fi
fi

# --- hardware hints (Raspberry Pi only) --------------------------------------

if [[ "$ARCH" == "arm64" ]]; then
  if [[ -r /proc/device-tree/model ]]; then
    log "Device: $(tr -d '\0' < /proc/device-tree/model)"
  fi
  if [[ ! -e /dev/spidev0.0 ]]; then
    warn "SPI is disabled (/dev/spidev0.0 missing). Enable it with: sudo raspi-config nonint do_spi 0  (then reboot)"
  fi
  app_user="${SUDO_USER:-${USER:-$(id -un)}}"
  for grp in spi gpio; do
    if getent group "$grp" >/dev/null 2>&1 && ! id -nG "$app_user" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
      warn "user $app_user is not in group '$grp': sudo usermod -aG $grp $app_user  (log out and in again afterwards)"
    fi
  done
fi

# --- done --------------------------------------------------------------------

log "Smart Bite $new_version installed in $INSTALL_DIR"
cat <<SUMMARY

Start it from the Pi's desktop session (the app opens full screen):
  $INSTALL_DIR/smart_bite$( (( CREATE_LAUNCHER )) && is_root && printf '      # or simply: smart_bite')
  RFID_MODE=mock $INSTALL_DIR/smart_bite    # try it without RC522 hardware

Update later by running this installer again.
SUMMARY
