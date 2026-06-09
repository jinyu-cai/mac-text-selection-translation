#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Text Selection Translation.app"
BUNDLE_ID="com.example.mactranslator"
PROCESS_NAME="MacTranslator"

CONFIG="${CONFIG:-release}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
OPEN_AFTER_INSTALL=1
FORCE_QUIT=0

usage() {
    cat <<USAGE
Usage: scripts/install-app.sh [--no-open] [--force-quit]

Builds the app, replaces ${INSTALL_DIR}/${APP_NAME}, then opens the installed app.

Environment:
  CONFIG=release|debug       Build configuration, default: release
  INSTALL_DIR=/Applications  Install destination, default: /Applications

Options:
  --no-open     Install but do not launch the app afterward
  --force-quit  If the old app does not quit gracefully, terminate it
  -h, --help    Show this help
USAGE
}

while (($#)); do
    case "$1" in
        --no-open)
            OPEN_AFTER_INSTALL=0
            ;;
        --force-quit)
            FORCE_QUIT=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

DEST_APP="${INSTALL_DIR}/${APP_NAME}"
BUILT_APP="${ROOT}/${APP_NAME}"
TMP_APP="${INSTALL_DIR}/.${APP_NAME%.app}.install.$$.app"

needs_sudo() {
    [[ ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" || ( -e "$DEST_APP" && ! -w "$DEST_APP" ) ]]
}

install_cmd() {
    if needs_sudo; then
        sudo "$@"
    else
        "$@"
    fi
}

cleanup() {
    if [[ -e "$TMP_APP" ]]; then
        install_cmd /bin/rm -rf "$TMP_APP"
    fi
}
trap cleanup EXIT

echo "==> Building ${APP_NAME} (${CONFIG})"
make -C "$ROOT" app CONFIG="$CONFIG"

if [[ ! -d "$BUILT_APP" ]]; then
    echo "Build did not produce ${BUILT_APP}" >&2
    exit 1
fi

if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "==> Quitting running app"
    osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true

    for _ in {1..20}; do
        if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.25
    done

    if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
        if [[ "$FORCE_QUIT" -eq 1 ]]; then
            echo "==> Force quitting ${PROCESS_NAME}"
            pkill -x "$PROCESS_NAME" || true
        else
            echo "The old app is still running. Quit it and rerun, or use --force-quit." >&2
            exit 1
        fi
    fi
fi

echo "==> Installing to ${DEST_APP}"
if [[ ! -d "$INSTALL_DIR" ]]; then
    install_cmd /bin/mkdir -p "$INSTALL_DIR"
fi
install_cmd /usr/bin/ditto "$BUILT_APP" "$TMP_APP"
if [[ -e "$DEST_APP" ]]; then
    install_cmd /bin/rm -rf "$DEST_APP"
fi
install_cmd /bin/mv "$TMP_APP" "$DEST_APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${DEST_APP}/Contents/Info.plist" 2>/dev/null || echo "?")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${DEST_APP}/Contents/Info.plist" 2>/dev/null || echo "?")
echo "==> Installed ${APP_NAME} version ${VERSION} (${BUILD})"

if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
    echo "==> Opening installed app"
    open "$DEST_APP"
fi
