#!/usr/bin/env bash
#
# Home Dashboard for GNOME Files — installer
#
# Installs one of the two available builds:
#   portal    home-dashboard portal backend.py  (also works in Open/Save dialogs)
#   standard  home-dashboard.py
#
# Both builds install as the same Nautilus extension, so only one can be
# active at a time. Installing both would show two dashboards.
#
# Usage:
#   ./install.sh                     # interactive build picker
#   ./install.sh --portal            # portal-backend build (recommended)
#   ./install.sh --standard          # standard build
#   ./install.sh --uninstall         # remove the installed extension
#   ./install.sh --uninstall --purge # also remove its config
#   ./install.sh --system --portal   # install for every user (uses sudo)
#   ./install.sh --no-restart        # do not quit Nautilus afterwards
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" >/dev/null 2>&1 && pwd -P)"
STANDARD_SRC="$SCRIPT_DIR/home-dashboard.py"
PORTAL_SRC="$SCRIPT_DIR/home-dashboard portal backend.py"
EXT_NAME="home-dashboard.py"
CONFIG_NAME="nautilus-home-dashboard"

BUILD=""
MODE="install"
SYSTEM=0
PURGE=0
RESTART=1

info() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Home Dashboard for GNOME Files — installer

Usage:
  ./install.sh [BUILD] [OPTIONS]

Builds (only one can be installed at a time):
  portal       Portal-backend build: also appears in apps' Open/Save dialogs
               (home-dashboard portal backend.py) — recommended
  standard     Classic build (home-dashboard.py)

Options:
  --portal             Select the portal-backend build
  --standard           Select the standard build
  --system             Install system-wide under /usr/share (uses sudo)
  --uninstall          Remove the installed extension
  --purge              With --uninstall, also remove the JSON config
  --no-restart         Do not quit Nautilus after installing/removing
  -h, --help           Show this help

With no build selected, the installer asks interactively. In a
non-interactive shell it defaults to the portal-backend build.
EOF
}

while (($#)); do
    case "$1" in
        portal|--portal) BUILD="portal" ;;
        standard|--standard) BUILD="standard" ;;
        --both)
            die "Install one build at a time. Both register the same extension and would show two dashboards."
            ;;
        --system) SYSTEM=1 ;;
        --uninstall|uninstall) MODE="uninstall" ;;
        --purge) PURGE=1 ;;
        --no-restart) RESTART=0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

if [[ $PURGE -eq 1 && $MODE != "uninstall" ]]; then
    die "--purge only makes sense together with --uninstall."
fi

# -- destinations -----------------------------------------------------------

if [[ $SYSTEM -eq 1 ]]; then
    EXT_DIR="/usr/share/nautilus-python/extensions"
    if [[ $EUID -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || die "sudo is required for --system."
        SUDO=(sudo)
    else
        SUDO=()
    fi
else
    if [[ $EUID -eq 0 ]]; then
        die "Run this installer as your normal user, not root. Use --system for a system-wide install."
    fi
    EXT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus-python/extensions"
    SUDO=()
fi

DEST="$EXT_DIR/$EXT_NAME"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$CONFIG_NAME"

# When --system is run through sudo, --purge should remove the invoking
# user's config, not root's.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    _sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [[ -n "$_sudo_home" ]]; then
        CONFIG_DIR="$_sudo_home/.config/$CONFIG_NAME"
    fi
fi

run() {
    if [[ ${#SUDO[@]} -gt 0 ]]; then
        "${SUDO[@]}" "$@"
    else
        "$@"
    fi
}

package_manager() {
    if command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper"
    else echo "unknown"
    fi
}

install_hint() {
    case "$(package_manager)" in
        dnf)     echo "  sudo dnf install nautilus-python python3-gobject gtk4 libadwaita" ;;
        apt)     echo "  sudo apt install nautilus-python python3-gi gir1.2-gtk-4.0 gir1.2-adw-1" ;;
        pacman)  echo "  sudo pacman -S python-nautilus python-gobject gtk4 libadwaita" ;;
        zypper)  echo "  sudo zypper install nautilus-python python3-gobject typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1" ;;
        *)       echo "  See README.md → Requirements" ;;
    esac
}

check_dependencies() {
    local output
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 was not found in PATH."
        install_hint >&2
        return 1
    fi
    if output="$(python3 - <<'PY' 2>&1
import sys

try:
    import gi
except Exception as exc:
    print(f"PyGObject is missing: {exc}")
    raise SystemExit(1)

for namespace, version in (("Gtk", "4.0"), ("Adw", "1"), ("Gdk", "4.0"), ("Pango", "1.0")):
    try:
        gi.require_version(namespace, version)
        __import__("gi.repository", fromlist=[namespace])
    except Exception as exc:
        print(f"{namespace} {version} is missing: {exc}")
        raise SystemExit(1)

try:
    gi.require_version("Nautilus", "4.0")
    from gi.repository import Nautilus  # noqa: F401
except (ValueError, ImportError):
    try:
        gi.require_version("Nautilus", "4.1")
        from gi.repository import Nautilus  # noqa: F401
    except Exception as exc:
        print(f"The Nautilus Python typelib is missing: {exc}")
        raise SystemExit(1)
PY
    )"; then
        return 0
    fi

    warn "$output"
    warn "Missing dependencies. Install them and re-run the installer:"
    install_hint >&2
    return 1
}

validate_source() {
    python3 - "$1" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
}

pick_build() {
    [[ -n "$BUILD" ]] && return

    if [[ -t 0 && -t 1 ]]; then
        info "Select the Home Dashboard build to install:"
        info "  1) Portal backend  (recommended — also works in Open/Save dialogs)"
        info "  2) Standard"
        while true; do
            printf 'Choice [1]: '
            read -r answer || answer=""
            case "${answer:-1}" in
                1|portal|p) BUILD="portal"; break ;;
                2|standard|s) BUILD="standard"; break ;;
                *) info "Please enter 1 or 2." ;;
            esac
        done
    else
        BUILD="portal"
    fi
}

uninstall_extension() {
    if [[ -e "$DEST" ]]; then
        run rm -f "$DEST"
        run rm -rf "$EXT_DIR/__pycache__"
        info "Removed: $DEST"
    else
        info "Not installed at: $DEST"
    fi

    if [[ $PURGE -eq 1 ]]; then
        if [[ -d "$CONFIG_DIR" ]]; then
            run rm -rf "$CONFIG_DIR"
            info "Removed config: $CONFIG_DIR"
        else
            info "No config found at: $CONFIG_DIR"
        fi
    fi

    if [[ $RESTART -eq 1 ]] && pgrep -x nautilus >/dev/null 2>&1; then
        info "Quitting Nautilus…"
        nautilus -q >/dev/null 2>&1 || true
    fi

    info "Done."
}

install_extension() {
    pick_build

    case "$BUILD" in
        portal)
            SRC="$PORTAL_SRC"
            LABEL="portal backend"
            ;;
        standard)
            SRC="$STANDARD_SRC"
            LABEL="standard"
            ;;
        *)
            die "Unknown build: $BUILD"
            ;;
    esac

    [[ -f "$SRC" ]] || die "Source file not found: $SRC"

    info "Home Dashboard installer"
    info "  Build:  $LABEL"
    info "  Source: $SRC"
    info "  Target: $DEST"

    if ! check_dependencies; then
        die "Install the missing dependencies, then run this installer again."
    fi

    validate_source "$SRC" || die "Syntax check failed: $SRC"

    run mkdir -p "$EXT_DIR"
    run install -m 644 "$SRC" "$DEST"
    run rm -rf "$EXT_DIR/__pycache__"

    info "Installed successfully."

    # A differently named copy would be loaded as a second extension and
    # would draw a second dashboard.
    for other in \
        "$EXT_DIR/home-dashboard portal backend.py" \
        "$EXT_DIR/home-dashboard-portal.py"; do
        if [[ -e "$other" ]]; then
            warn "Another copy exists at: $other"
            warn "Remove it to avoid duplicate dashboards."
        fi
    done

    if [[ $RESTART -eq 1 ]]; then
        if pgrep -x nautilus >/dev/null 2>&1; then
            info "Restarting Nautilus…"
            nautilus -q >/dev/null 2>&1 || true
        fi
        info "Open Files and visit Home to see the dashboard."
    else
        info "Run 'nautilus -q' and reopen Files to load the extension."
    fi
}

if [[ $MODE == "uninstall" ]]; then
    uninstall_extension
else
    install_extension
fi
