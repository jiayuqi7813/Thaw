#!/usr/bin/env bash
#
# thaw-devrun.sh — Build the Debug config and run it from /Applications so the
# macOS 27 menu-bar hiding feature works with a local build.
#
# Why this exists: on macOS 27 a status item's menu-bar scene is only attributed
# to its app when the app has a clean code identity AND a canonical /Applications
# location. A Debug build run straight from DerivedData/Xcode hosts its status
# item as `nil`, so the visibility-restriction allowlist can't protect it and
# Thaw's own icon vanishes whenever anything is hidden.
#
# The Debug configuration uses bundle id `com.stonerl.Thaw.debug` (cleanly owned
# by the building developer's own team — no conflict with the Developer-ID
# `com.stonerl.Thaw`, which only the release signer can use). This script builds
# it, quits any running 'Thaw Debug' (the app AND its XPC service), deletes the
# old `/Applications/Thaw Debug.app`, installs the fresh build, and launches it —
# no manual quitting or trashing needed, no Developer-ID cert and no release.
#
# Usage:
#   ./scripts/thaw-devrun.sh
#   ./scripts/thaw-devrun.sh --skip-packages
#
# The development workspace includes the sibling `../PlatformRuntimeKit`
# checkout as Xcode's local override for the public `prk-bin` dependency. This
# keeps the checked-in project on the distributable binary package while local
# builds see current source changes that have not been published yet.
#
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="Thaw"
CONFIG="Debug"
DEST="/Applications/Thaw Debug.app"
DEBUG_BUNDLE_ID="com.stonerl.Thaw.debug"
WORKSPACE="ThawDev.xcworkspace"
PRK_SOURCE="../PlatformRuntimeKit"
PRK_OVERRIDE_DIR=".swiftpm-overrides"
PRK_OVERRIDE="$PRK_OVERRIDE_DIR/prk-bin"
export MENU_BAR_MODEL_PATH="$PWD/MenuBarModel"
export MENU_BAR_MODEL_PATH="$PWD/MenuBarModel"
PACKAGE_RESOLUTION_ARGS=(-onlyUsePackageVersionsFromResolvedFile)

SKIP_PACKAGES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-packages)
            SKIP_PACKAGES=1
            shift
            ;;
        -h | --help)
            sed -n '1,22p' "$0" | tail -n +2
            exit 0
            ;;
        *)
            echo "Unknown option: $1 (try --help)" >&2
            exit 2
            ;;
    esac
done

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

prepare_local_package_override() {
    if [[ ! -f "$PRK_SOURCE/Package.swift" ]]; then
        echo "Sibling PlatformRuntimeKit checkout not found at $PRK_SOURCE" >&2
        echo "Clone it beside Thaw before running this development script." >&2
        exit 1
    fi

    mkdir -p "$PRK_OVERRIDE_DIR"
    if [[ -L "$PRK_OVERRIDE" ]]; then
        rm "$PRK_OVERRIDE"
    fi
    mkdir -p "$PRK_OVERRIDE"
    rsync -a --delete \
        --exclude .build \
        --exclude .git \
        --exclude .swiftpm \
        --exclude dist \
        "$PRK_SOURCE/" "$PRK_OVERRIDE/"
}

resolve_swift_packages() {
    say "Resolving Swift packages…"
    xcodebuild -resolvePackageDependencies \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        "${PACKAGE_RESOLUTION_ARGS[@]}"
}

prepare_local_package_override
if [[ "$SKIP_PACKAGES" -eq 0 ]]; then
    resolve_swift_packages
fi

# Quit every running 'Thaw Debug' process — the app AND its MenuBarItemService
# XPC child — without touching a release `Thaw`. Matches on the install path so
# it's precise. Tries a graceful quit first (clean assertion teardown), then
# force-kills anything still alive. The hiding assertion auto-releases on exit,
# so a force-kill leaves no lingering restriction.
quit_thaw_debug() {
    pgrep -f "$DEST/" >/dev/null 2>&1 || return 0

    say "Quitting running 'Thaw Debug'…"
    # Backgrounded so a macOS 27 quit-hang can't stall the script.
    ( osascript -e "tell application id \"$DEBUG_BUNDLE_ID\" to quit" >/dev/null 2>&1 ) &

    # Poll up to ~4s for the app + XPC service to exit on their own.
    for _ in {1..8}; do
        pgrep -f "$DEST/" >/dev/null 2>&1 || return 0
        sleep 0.5
    done

    say "Force-killing leftover 'Thaw Debug' processes…"
    pkill -9 -f "$DEST/" 2>/dev/null || true
    sleep 1
}

say "Building ${CONFIG}…"
xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination 'platform=macOS' "${PACKAGE_RESOLUTION_ARGS[@]}" build >/dev/null

PRODUCTS_DIR=$(xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIG" \
    "${PACKAGE_RESOLUTION_ARGS[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="${PRODUCTS_DIR}/Thaw.app"
[ -d "$APP" ] || { echo "Build product not found: $APP"; exit 1; }

quit_thaw_debug

if [ -e "$DEST" ]; then
    say "Removing existing ${DEST}…"
    rm -rf "$DEST"
fi

say "Installing to ${DEST}…"
mv "$APP" "$DEST"

say "Launching…"
open "$DEST"
say "Running 'Thaw Debug'. First launch: grant Accessibility + Screen Recording."
