#!/bin/bash
set -euo pipefail

# Build is safe to run locally. Package uses credentials only on a GitHub-hosted runner.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMMAND="${1:-}"
PROJECT="tidest.xcodeproj"
WORK="${RELEASE_WORK_DIR:-$ROOT/build/release}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
ARCHIVE="$WORK/Tidest.xcarchive"
APP="$ARCHIVE/Products/Applications/tidest.app"
SPARKLE_TOOLS="$WORK/SourcePackages/artifacts/sparkle/Sparkle/bin"

fail() { printf 'Release stopped: %s\n' "$*" >&2; exit 1; }
require() { [[ -n "${!1:-}" ]] || fail "Set $1 before packaging."; }

project_version="$(python3 - "$PROJECT/project.pbxproj" <<'PY'
import json
import subprocess
import sys

project = json.loads(subprocess.check_output(
    ["/usr/bin/plutil", "-convert", "json", "-o", "-", sys.argv[1]]))
objects = project["objects"]
target = next(value for value in objects.values()
              if value.get("isa") == "PBXNativeTarget" and value.get("name") == "tidest")
configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
release = next(objects[key] for key in configurations if objects[key]["name"] == "Release")
print(release["buildSettings"]["MARKETING_VERSION"])
PY
)"
TAG="${2:-v$project_version}"
[[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || fail "Use a stable version tag such as v2.0.1."
VERSION="${TAG#v}"
[[ "$VERSION" == "$project_version" ]] \
    || fail "Tag $TAG does not match the project's Release version $project_version."
DMG="$WORK/Tidest-$VERSION.dmg"

check_toolchain() {
    local actual_build
    actual_build="$(xcodebuild -version | awk '/Build version/ { print $3 }')"
    [[ "$actual_build" == "27A266a" ]] \
        || fail "This release requires Xcode 27.0 (27A266a); found $actual_build."
}

check_app() {
    [[ -d "$APP" ]] || fail "Build the app before packaging."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] \
        || fail "The built app's version does not match $TAG."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "com.mixbayes.tidest" ]] \
        || fail "Unexpected app bundle identifier."
    local architecture
    for architecture in arm64 x86_64; do
        /usr/bin/lipo "$APP/Contents/MacOS/tidest" -verify_arch "$architecture"
    done
}

build_app() {
    check_toolchain
    [[ ! -e "$ARCHIVE" ]] || fail "Archive already exists at $ARCHIVE; use a fresh RELEASE_WORK_DIR."
    local build_number
    build_number="${GITHUB_RUN_NUMBER:-1}"
    [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "Invalid build number."
    xcodebuild archive \
        -project "$PROJECT" -scheme tidest -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$WORK/DerivedData" -archivePath "$ARCHIVE" \
        -clonedSourcePackagesDirPath "$WORK/SourcePackages" -onlyUsePackageVersionsFromResolvedFile \
        'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES \
        CURRENT_PROJECT_VERSION="$build_number" \
        2>&1 | tee "$WORK/build.log"
    check_app
}

prepare_dmg() {
    "${PYTHON_BIN:-python3}" -m venv "$WORK/dmg-tools"
    "$WORK/dmg-tools/bin/python" -m pip install --require-hashes --only-binary=:all: \
        -r "$ROOT/scripts/dmg/requirements.txt"
}

create_dmg() {
    [[ ! -e "$DMG" ]] || fail "DMG output already exists; use a fresh RELEASE_WORK_DIR."
    [[ -x "$WORK/dmg-tools/bin/dmgbuild" ]] || fail "Run prepare-dmg in this RELEASE_WORK_DIR before packaging."
    # Store the layout in the image itself; packaging does not need a running Finder.
    "$WORK/dmg-tools/bin/dmgbuild" -s "$ROOT/scripts/dmg/settings.py" \
        -D app="$APP" -D background="$ROOT/scripts/dmg/background.png" Tidest "$DMG"
}

package_app() {
    [[ "${GITHUB_ACTIONS:-}" == "true" && "${RUNNER_ENVIRONMENT:-}" == "github-hosted" ]] \
        || fail "Signed packaging runs only on a GitHub-hosted runner."
    require APPLE_CERTIFICATE_P12_BASE64
    require APPLE_CERTIFICATE_PASSWORD
    require APPLE_ID
    require APPLE_APP_SPECIFIC_PASSWORD
    require APPLE_TEAM_ID
    require SPARKLE_ED25519_PRIVATE_KEY
    require RUNNER_TEMP
    [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "APPLE_TEAM_ID must contain 10 letters or digits."
    check_toolchain
    check_app

    # Keep credentials outside the build output and never print shell expansions.
    set +x
    local signing_dir keychain keychain_password identity profile mounted
    signing_dir="$(mktemp -d "$RUNNER_TEMP/tidest-signing.XXXXXX")"
    keychain="$signing_dir/signing.keychain-db"
    keychain_password="$(/usr/bin/openssl rand -hex 32)"
    profile="tidest-notarization"
    mounted=""
    cleanup() {
        if [[ -n "$mounted" ]]; then /usr/bin/hdiutil detach "$mounted" >/dev/null 2>&1 || true; fi
        /usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || true
        rm -rf "$signing_dir"
    }
    # EXIT traps run after function locals disappear, so perform packaging in this subshell.
    (
        trap cleanup EXIT
        umask 077
        printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | /usr/bin/base64 --decode > "$signing_dir/certificate.p12"
        /usr/bin/security create-keychain -p "$keychain_password" "$keychain"
        /usr/bin/security set-keychain-settings -lut 21600 "$keychain"
        /usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
        /usr/bin/security import "$signing_dir/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" \
            -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
        /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s \
            -k "$keychain_password" "$keychain" >/dev/null
        identity="$(/usr/bin/security find-identity -v -p codesigning "$keychain" \
            | awk -v team="($APPLE_TEAM_ID)\"" '/"Developer ID Application:/ && index($0, team) { print $2 }')"
        [[ "$identity" =~ ^[A-Fa-f0-9]{40}$ ]] \
            || fail "The p12 must contain exactly one valid Developer ID Application identity for APPLE_TEAM_ID."
        /usr/bin/xcrun notarytool store-credentials "$profile" --keychain "$keychain" \
            --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_SPECIFIC_PASSWORD" >/dev/null

        notarize() {
            local path name report submission status
            path="$1"
            name="$2"
            report="$WORK/notarization-$name.json"
            /usr/bin/xcrun notarytool submit "$path" --keychain-profile "$profile" \
                --keychain "$keychain" --wait --timeout 30m --output-format json > "$report"
            submission="$(/usr/bin/plutil -extract id raw -o - "$report")"
            status="$(/usr/bin/plutil -extract status raw -o - "$report")"
            if [[ "$status" != "Accepted" ]]; then
                /usr/bin/xcrun notarytool log "$submission" --keychain-profile "$profile" \
                    --keychain "$keychain" "$WORK/notarization-$name-log.json" || true
                fail "Apple notarization for $name returned $status (submission $submission)."
            fi
            /usr/bin/xcrun stapler staple "$3"
            /usr/bin/xcrun stapler validate "$3"
        }

        # Sign nested code inside out. Signing the host alone does not sign
        # Sparkle's installer, relaunch agent or XPC services for our Team.
        local framework nested
        framework="$APP/Contents/Frameworks/Sparkle.framework"
        for nested in "$framework/Versions/B/Autoupdate" \
                      "$framework/Versions/B/Updater.app" \
                      "$framework/Versions/B/XPCServices/Downloader.xpc" \
                      "$framework/Versions/B/XPCServices/Installer.xpc" \
                      "$framework"; do
            [[ -e "$nested" ]] || fail "Missing Sparkle component: $nested"
            /usr/bin/codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
                --keychain "$keychain" --sign "$identity" "$nested"
        done
        /usr/bin/codesign --force --timestamp --options runtime \
            --entitlements Config/Tidest.entitlements --keychain "$keychain" --sign "$identity" "$APP"
        /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
        # Staple the app before enclosing it in the DMG, so the copied app works offline too.
        /usr/bin/ditto -c -k --keepParent "$APP" "$WORK/notarization-app.zip"
        # ZIP files cannot be stapled: submit the ZIP, then staple the app itself.
        notarize "$WORK/notarization-app.zip" app "$APP"
        /usr/sbin/spctl --assess --type execute --verbose=4 "$APP"

        create_dmg
        /usr/bin/codesign --force --timestamp --keychain "$keychain" --sign "$identity" "$DMG"
        notarize "$DMG" dmg "$DMG"
        /usr/bin/codesign --verify --strict --verbose=2 "$DMG"
        /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
        mkdir "$WORK/mounted"
        mounted="$WORK/mounted"
        /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mounted" "$DMG"
        /usr/bin/codesign --verify --deep --strict --verbose=2 "$mounted/tidest.app"
        /usr/bin/xcrun stapler validate "$mounted/tidest.app"
        /usr/sbin/spctl --assess --type execute --verbose=4 "$mounted/tidest.app"
        /usr/bin/hdiutil detach "$mounted"
        mounted=""
    )

    generate_update_feed

    # All operations that change the DMG have finished before hashes and attestations.
    python3 - "$WORK" "$VERSION" "$TAG" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

work = pathlib.Path(sys.argv[1])
version, tag = sys.argv[2:]
def output(*args):
    return subprocess.check_output(args, text=True).strip()
notarization = {}
for name in ("app", "dmg"):
    report = json.loads((work / f"notarization-{name}.json").read_text())
    notarization[name] = {"id": report["id"], "status": report["status"]}
dmg = work / f"Tidest-{version}.dmg"
info = {
    "version": version,
    "build_number": os.environ["GITHUB_RUN_NUMBER"],
    "tag": tag,
    "commit": output("git", "rev-parse", "HEAD"),
    "repository": os.environ["GITHUB_REPOSITORY"],
    "workflow_run": f'https://github.com/{os.environ["GITHUB_REPOSITORY"]}/actions/runs/{os.environ["GITHUB_RUN_ID"]}/attempts/{os.environ["GITHUB_RUN_ATTEMPT"]}',
    "architectures": ["arm64", "x86_64"],
    "xcode": output("xcodebuild", "-version"),
    "sdk": output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
    "swift": output("xcrun", "swift", "--version"),
    "macos": output("sw_vers", "-productVersion"),
    "runner_image": {key: os.environ.get(key) for key in ("ImageOS", "ImageVersion", "RUNNER_ARCH")},
    "apple_team_id": os.environ["APPLE_TEAM_ID"],
    "notarization": notarization,
    "artifact": {"name": dmg.name, "sha256": hashlib.sha256(dmg.read_bytes()).hexdigest()},
}
(work / "BUILD-INFO.json").write_text(json.dumps(info, indent=2) + "\n")
PY
    (cd "$WORK" && /usr/bin/shasum -a 256 "Tidest-$VERSION.dmg" BUILD-INFO.json appcast.xml > SHA256SUMS)
}

generate_update_feed() {
    require SPARKLE_ED25519_PRIVATE_KEY
    require GITHUB_REPOSITORY
    [[ -x "$SPARKLE_TOOLS/generate_appcast" ]] || fail "Build with the pinned Sparkle package before generating the feed."
    [[ -f "$DMG" ]] || fail "Package the final DMG before generating the feed."
    local feed="$WORK/update-feed"
    [[ ! -e "$feed" ]] || fail "Update feed output already exists; use a fresh RELEASE_WORK_DIR."
    mkdir "$feed"
    # Keep notarization ZIPs out of the directory scanned by generate_appcast.
    cp "$DMG" "$feed/Tidest-$VERSION.dmg"
    printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | "$SPARKLE_TOOLS/generate_appcast" \
        --ed-key-file - --maximum-deltas 0 --maximum-versions 1 \
        --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/" \
        --link https://tidest.app \
        --full-release-notes-url "https://github.com/$GITHUB_REPOSITORY/releases/tag/$TAG" \
        "$feed"
    # generate_appcast only warns when the private key does not match the app's
    # public key. An unsigned enclosure must stop publication, not pass as a feed.
    python3 - "$feed/appcast.xml" "$VERSION" \
        "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/Tidest-$VERSION.dmg" "$DMG" <<'PY'
import base64
import pathlib
import sys
import xml.etree.ElementTree as ET

path, version, url, dmg = sys.argv[1:]
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(path).findall("./channel/item")
if len(items) != 1:
    sys.exit("Release stopped: expected exactly one update in the feed.")
item = items[0]
enclosure = item.find("enclosure")
if item.findtext(namespace + "shortVersionString") != version or enclosure is None:
    sys.exit("Release stopped: update feed version does not match the release.")
signature = base64.b64decode(enclosure.get(namespace + "edSignature", ""), validate=True)
if len(signature) != 64 or enclosure.get("url") != url or int(enclosure.get("length", "0")) != pathlib.Path(dmg).stat().st_size:
    sys.exit("Release stopped: update archive signature, URL or size is invalid. Check the signing key.")
PY
    printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | "$SPARKLE_TOOLS/sign_update" \
        --ed-key-file - --verify "$feed/appcast.xml"
    cp "$feed/appcast.xml" "$WORK/appcast.xml"
}

case "$COMMAND" in
    check) check_toolchain; printf 'Release version: %s\n' "$VERSION" ;;
    build) build_app ;;
    prepare-dmg) prepare_dmg ;;
    package) package_app ;;
    appcast) generate_update_feed ;;
    smoke-dmg) check_app; create_dmg ;;
    *) fail "Usage: bash scripts/release.sh {check|build|prepare-dmg|package|appcast|smoke-dmg} [vX.Y.Z]" ;;
esac
