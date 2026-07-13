#!/usr/bin/env bash
#
# thaw-build-dmg.sh — Local-only mirror of `.github/workflows/build-dmg.yml`.
#
# Hardcoded for this machine. Do not use in CI (CI keeps secrets in GitHub Actions).
#
# One-time notarization setup (stores app-specific password in login keychain):
#   xcrun notarytool store-credentials thaw-notary \
#     --apple-id "APPLE_ID" \
#     --team-id "TEAM_ID" \
#     --password "<app-specific-password>"
#
# Usage:
#   ./scripts/thaw-build-dmg.sh
#   ./scripts/thaw-build-dmg.sh --skip-notarize
#   ./scripts/thaw-build-dmg.sh --open
#
set -euo pipefail
cd "$(dirname "$0")/.."

# ── Local-only defaults ──────────────────────────────────────────────────────
TEAM_ID="TEAM_ID"
APPLE_ID="APPLE_ID"
NOTARY_PROFILE="thaw-notary"
SIGN_IDENTITY="Developer ID Application"
# ─────────────────────────────────────────────────────────────────────────────

APP_NAME="Thaw.app"
DMG_NAME="Thaw-dev.dmg"
PROJECT="Thaw.xcodeproj"
SCHEME="Thaw"
CONFIGURATION="Release"
DEPLOYMENT_TARGET="26.0"
BACKGROUND="Resources/background_27@2x.png"
ARCHIVE_PATH="build/Archive.xcarchive"
EXPORT_PATH="build/Export"
BUILD_DIR="build"
TEMP_DIR=""
SKIP_NOTARIZE=0
SKIP_ARCHIVE=0
OPEN_DMG=0

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --skip-archive) SKIP_ARCHIVE=1; shift ;;
        --dmg-name) DMG_NAME="${2:?}"; shift 2 ;;
        --open) OPEN_DMG=1; shift ;;
        -h | --help) usage ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

select_xcode() {
    local preferred="/Applications/Xcode_26.6.app/Contents/Developer"
    if [[ -n "${DEVELOPER_DIR:-}" ]]; then
        export DEVELOPER_DIR
        say "Using DEVELOPER_DIR=$DEVELOPER_DIR"
        return
    fi
    if [[ -d "$preferred" ]]; then
        export DEVELOPER_DIR="$preferred"
        say "Using CI-pinned Xcode: $DEVELOPER_DIR"
        return
    fi
    say "Xcode_26.6.app not found; using $(xcode-select -p)"
}

require_tools() {
    command -v xcodebuild >/dev/null || die "xcodebuild not found"
    command -v create-dmg >/dev/null || die "create-dmg not found (brew install create-dmg)"
    command -v jq >/dev/null || die "jq not found (brew install jq)"
    [[ -x /usr/libexec/PlistBuddy ]] || die "/usr/libexec/PlistBuddy not found"
    [[ -f "$BACKGROUND" ]] || die "DMG background missing: $BACKGROUND"
    [[ -d "$PROJECT" ]] || die "Project not found: $PROJECT"

    if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF 'Developer ID Application'; then
        die "No 'Developer ID Application' identity in your keychain.
Download the .cer from developer.apple.com, double-click to install into login,
then confirm with: security find-identity -v -p codesigning"
    fi
}

archive_app() {
    if [[ "$SKIP_ARCHIVE" -eq 1 ]]; then
        [[ -d "$ARCHIVE_PATH" ]] || die "--skip-archive set but $ARCHIVE_PATH missing"
        say "Skipping archive; using existing $ARCHIVE_PATH"
        return
    fi

    say "Archiving Release ($SCHEME) team=$TEAM_ID"
    mkdir -p "$BUILD_DIR"
    rm -rf "$ARCHIVE_PATH"

    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination platform=macOS \
        -configuration "$CONFIGURATION" \
        -archivePath "$ARCHIVE_PATH" \
        MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
}

export_and_package() {
    say "Exporting archive + packaging DMG"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/thaw-dmg.XXXXXX")"
    local export_plist="$TEMP_DIR/ExportOptions.plist"
    local staging="$TEMP_DIR/dmg-staging"

    /usr/libexec/PlistBuddy \
        -c "Add :method string developer-id" \
        -c "Add :teamID string $TEAM_ID" \
        -c "Add :signingStyle string manual" \
        -c "Add :destination string export" \
        "$export_plist"

    rm -rf "$EXPORT_PATH"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$export_plist"

    codesign -vvv --deep --strict "$EXPORT_PATH/$APP_NAME"

    local vol_name="${APP_NAME%.app}"
    rm -rf "$staging"
    mkdir -p "$staging"
    cp -R "$EXPORT_PATH/$APP_NAME" "$staging/$APP_NAME"
    ln -s /Applications "$staging/Applications"

    rm -f "$BUILD_DIR/$DMG_NAME"
    create-dmg \
        --volname "$vol_name" \
        --background "$BACKGROUND" \
        --window-size 582 373 \
        --icon-size 100 \
        --hide-extension "$APP_NAME" \
        --icon "$APP_NAME" 150 150 \
        --icon "Applications" 436 150 \
        "$BUILD_DIR/$DMG_NAME" \
        "$staging"

    codesign --sign "$SIGN_IDENTITY" \
        --timestamp \
        --team-id "$TEAM_ID" \
        "$BUILD_DIR/$DMG_NAME"
}

ensure_notary_credentials() {
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        say "Using notarytool profile: $NOTARY_PROFILE"
        return
    fi

    die "Notary profile '$NOTARY_PROFILE' not found. Run once:

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
    --apple-id \"$APPLE_ID\" \\
    --team-id \"$TEAM_ID\" \\
    --password \"<app-specific-password-from-appleid.apple.com>\""
}

notarize_and_validate() {
    if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
        say "Skipping notarization (--skip-notarize)"
        return
    fi

    ensure_notary_credentials

    say "Submitting $DMG_NAME to notarytool (this can take several minutes)"
    local submission submission_id status
    submission="$(xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" \
        --keychain-profile "$NOTARY_PROFILE" \
        --output-format json \
        --wait)"
    printf '%s\n' "$submission"

    submission_id="$(printf '%s\n' "$submission" | jq -r '.id')"
    status="$(printf '%s\n' "$submission" | jq -r '.status')"

    say "Fetching notarization log for $submission_id"
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" || true

    [[ "$status" == "Accepted" ]] || die "Notarization failed with status: $status"

    xcrun stapler staple "$BUILD_DIR/$DMG_NAME"
    xcrun stapler validate "$BUILD_DIR/$DMG_NAME"
    spctl --assess --type execute --verbose "$EXPORT_PATH/$APP_NAME"
}

main() {
    select_xcode
    require_tools
    archive_app
    export_and_package
    notarize_and_validate

    local dmg_path="$BUILD_DIR/$DMG_NAME"
    say "Done: $PWD/$dmg_path"
    ls -lh "$dmg_path"

    if [[ "$OPEN_DMG" -eq 1 ]]; then
        open "$dmg_path"
    fi
}

main
