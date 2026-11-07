#!/bin/zsh
# Build, sign, notarize and verify the arm64 Developer ID release of Keyloom, and write the evidence.
#
# Usage: scripts/release/release.sh [--dry-run | --check-env] [--sync-state TEXT] [--help]
#   (no mode)         full release: archive, sign, notarize, staple, verify, zip, SHA256, evidence
#   --dry-run         everything that needs no credentials: unsigned arm64 Release archive, arch, minos and
#                     bundle-version checks, evidence file. Never signs or notarizes; verdict NOT VERIFIED
#   --check-env       list the required environment variables by name (set or MISSING), nothing else
#   --sync-state TEXT label recorded in the evidence, for example off, on-idle, signed-out (default unknown)
#
# Required environment for the full release (values are never printed or written; this script reads them only):
#   KEYLOOM_SIGN_IDENTITY   name of the "Developer ID Application" signing identity in the keychain
#   KEYLOOM_NOTARY_PROFILE  keychain profile name created with `xcrun notarytool store-credentials`
#
# Both build modes refuse to run unless every tracked file matches HEAD (untracked files are ignored), so the
# recorded commit is the commit that was built. Output goes to the git-ignored <repo>/dist/<mode>-<sha>/:
# Keyloom.xcarchive, notarytool and xcodebuild logs, release-evidence.md and, for a full release,
# Keyloom-<version>-arm64.zip with its .sha256. The evidence holds the commit, macOS/Xcode/SDK versions, chip and
# hardware model, arch, minos, bundle version and the sync-state label; never a serial number, user or host name,
# Apple ID, team ID or identity.
#
# Exit status: 0 VERIFIED (signed, notarized, stapled, Gatekeeper accepted), 3 NOT VERIFIED, 1 a check FAILED,
# 2 usage or setup error (bad option, missing variable or tool, dirty tree).
#
# Not done here, by design. GitHub Releases publishing is manual, only after Naim confirms the redistribution
# license and explicitly authorizes the release. With the artifact from dist/release-<sha>/ and <version> taken from
# release-evidence.md:
#   shasum -a 256 -c dist/release-<sha>/Keyloom-<version>-arm64.zip.sha256
#   git tag -s v<version> -m "Keyloom <version>" && git push origin v<version>
#   gh release create v<version> dist/release-<sha>/Keyloom-<version>-arm64.zip \
#       dist/release-<sha>/Keyloom-<version>-arm64.zip.sha256 --title "Keyloom <version>" \
#       --notes-file dist/release-<sha>/release-evidence.md
#   then download the asset from the release URL into an empty folder, verify the checksum, run
#   `spctl -a -vvv -t exec` on the unzipped app, launch it on a clean macOS install, and record the result.
#
# Limits: the app has no nested code (no frameworks or helpers), so the single app signature covers it. The build
# has no iCloud entitlement or provisioning profile (see Feasibility/CloudKit.entitlements.example), so the signed
# build runs with sync unavailable until a provisioned configuration is added. Output is a zip; no dmg.
set -euo pipefail

ROOT="${0:A:h:h:h}"
source "${0:A:h}/lib.zsh"

die() { print -u2 "release: $*"; exit 2 }
relpath() { print -r -- "${1#$ROOT/}" }

release_parse_args "$@" || exit $?

case "$MODE" in
  help) release_usage; exit 0 ;;
  check-env)
    missing=(${(f)"$(release_missing_env)"})
    for name in $RELEASE_REQUIRED_ENV; do
      if (( ${missing[(Ie)$name]} )); then print "$name: MISSING"; else print "$name: set"; fi
    done
    (( ${#missing} == 0 )) && exit 0
    exit 2 ;;
esac

if [[ "$MODE" == release ]]; then
  missing="$(release_missing_env | tr '\n' ' ')"
  [[ -z "$missing" ]] || die "required environment variables not set: ${missing% } (see --check-env)"
fi
release_tree_is_clean "$ROOT" || die "a clean tracked tree is required: commit or discard changes to tracked files"

tools=(xcodebuild xcrun vtool lipo plutil shasum git sysctl sw_vers)
[[ "$MODE" == release ]] && tools+=(codesign spctl ditto)
for tool in $tools; do command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"; done
[[ "$MODE" == release ]] && { xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found (needs Xcode 13+)"; }
[[ -d "$ROOT/Keyloom.xcodeproj" ]] || die "Keyloom.xcodeproj not found under the repo root"

EV_MODE="$MODE"
EV_GIT_SHA="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
EV_MACOS="$(sw_vers -productVersion)"
EV_MACOS_BUILD="$(sw_vers -buildVersion)"
EV_XCODE="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
EV_SDK="macosx$(xcrun --sdk macosx --show-sdk-version)"
EV_HW_MODEL="$(sysctl -n hw.model)"
EV_CHIP="$(sysctl -n machdep.cpu.brand_string)"
EV_MEM_GIB="$(( $(sysctl -n hw.memsize) / 1073741824 ))"
EV_SYNC_STATE="$SYNC_STATE"
EV_BUILD_STATUS="NOT VERIFIED" EV_SIGN_STATUS="NOT VERIFIED" EV_NOTARY_STATUS="NOT VERIFIED"
EV_STAPLE_STATUS="NOT VERIFIED" EV_GATEKEEPER_STATUS="NOT VERIFIED"

OUT="$ROOT/dist/${MODE}-${EV_GIT_SHA}"
rm -rf "$OUT"
mkdir -p "$OUT"
ARCHIVE="$OUT/Keyloom.xcarchive"

# Build the unsigned arm64 Release archive. Signing happens afterwards so dry-run needs no identity.
build_archive() {
  xcodebuild archive \
    -project "$ROOT/Keyloom.xcodeproj" -scheme Keyloom -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$OUT/derived" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES ENABLE_TESTABILITY=NO \
    >"$OUT/xcodebuild.log" 2>&1 || { print -u2 "release: archive failed, see $(relpath "$OUT/xcodebuild.log")"; return 1 }
}

# Checks arch, minos and bundle metadata of the app at $1; fills the EV_* facts.
check_artifact() {
  local app="$1" plist="$1/Contents/Info.plist" binary failed=0
  binary="$app/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$plist")"
  EV_ARCH="$(lipo -archs "$binary")"
  EV_MINOS="$(vtool -show-build "$binary" | release_parse_minos || print missing)"
  EV_BUNDLE_MIN="$(plutil -extract LSMinimumSystemVersion raw "$plist" 2>/dev/null || print missing)"
  EV_VERSION="$(plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || print missing)"
  EV_BUILD="$(plutil -extract CFBundleVersion raw "$plist" 2>/dev/null || print missing)"
  [[ "$EV_ARCH" == arm64 ]] || { print -u2 "release: architecture is '$EV_ARCH', expected arm64"; failed=1 }
  [[ "$EV_MINOS" == "$RELEASE_EXPECTED_MINOS" ]] || { print -u2 "release: minos is '$EV_MINOS', expected $RELEASE_EXPECTED_MINOS"; failed=1 }
  [[ "$EV_BUNDLE_MIN" == "$RELEASE_EXPECTED_MINOS" ]] || { print -u2 "release: bundle minimum is '$EV_BUNDLE_MIN', expected $RELEASE_EXPECTED_MINOS"; failed=1 }
  [[ "$EV_VERSION" == <->.<->.<-> && "$EV_BUILD" == <-> ]] || { print -u2 "release: bundle version '$EV_VERSION' ($EV_BUILD) is not X.Y.Z (integer build)"; failed=1 }
  return $failed
}

# Sign with hardened runtime, notarize, staple, verify, then zip the stapled app. Stops at the first failure;
# later verdicts stay NOT VERIFIED.
sign_notarize_verify() {
  local app="$1" flags
  codesign --force --timestamp --options runtime --sign "$KEYLOOM_SIGN_IDENTITY" "$app" || { EV_SIGN_STATUS=FAIL; return 1 }
  flags="$(codesign -dv "$app" 2>&1)" || true
  [[ "$flags" == *"flags="*"runtime"* ]] || { print -u2 "release: hardened runtime flag missing after signing"; EV_SIGN_STATUS=FAIL; return 1 }
  codesign --verify --deep --strict --verbose=2 "$app" || { EV_SIGN_STATUS=FAIL; return 1 }
  EV_SIGN_STATUS=PASS

  ditto -c -k --keepParent "$app" "$OUT/notarize-upload.zip" \
    || { print -u2 "release: zipping for upload failed"; EV_NOTARY_STATUS=FAIL; return 1 }
  xcrun notarytool submit "$OUT/notarize-upload.zip" --keychain-profile "$KEYLOOM_NOTARY_PROFILE" --wait \
    >"$OUT/notarytool.log" 2>&1 || true
  if ! grep -q "status: Accepted" "$OUT/notarytool.log"; then
    print -u2 "release: notarization not accepted, see $(relpath "$OUT/notarytool.log")"; EV_NOTARY_STATUS=FAIL; return 1
  fi
  EV_NOTARY_STATUS=PASS

  xcrun stapler staple "$app" >"$OUT/stapler.log" 2>&1 && xcrun stapler validate "$app" >>"$OUT/stapler.log" 2>&1 \
    || { print -u2 "release: stapling failed, see $(relpath "$OUT/stapler.log")"; EV_STAPLE_STATUS=FAIL; return 1 }
  EV_STAPLE_STATUS=PASS

  codesign --verify --deep --strict --verbose=2 "$app" || { EV_SIGN_STATUS=FAIL; return 1 }
  spctl -a -vvv -t exec "$app" || { EV_GATEKEEPER_STATUS=FAIL; return 1 }
  EV_GATEKEEPER_STATUS=PASS

  EV_ARTIFACT="Keyloom-${EV_VERSION}-arm64.zip"
  { ditto -c -k --keepParent "$app" "$OUT/$EV_ARTIFACT" && (cd "$OUT" && shasum -a 256 "$EV_ARTIFACT" >"$EV_ARTIFACT.sha256") } \
    || { print -u2 "release: packaging failed"; EV_BUILD_STATUS=FAIL; return 1 }
  EV_SHA256="$(cut -d' ' -f1 "$OUT/$EV_ARTIFACT.sha256")"
}

finish() {
  release_render_evidence >"$OUT/release-evidence.md"
  cat "$OUT/release-evidence.md"
  local verdict
  verdict="$(release_overall_verdict "$EV_BUILD_STATUS" "$EV_SIGN_STATUS" "$EV_NOTARY_STATUS" "$EV_STAPLE_STATUS" "$EV_GATEKEEPER_STATUS")"
  print -- "\nrelease: $verdict (evidence: $(relpath "$OUT/release-evidence.md"))"
  case "$verdict" in PASS) exit 0 ;; FAIL) exit 1 ;; *) exit 3 ;; esac
}

if ! build_archive; then EV_BUILD_STATUS=FAIL; finish; fi
APP="$ARCHIVE/Products/Applications/Keyloom.app"
[[ -d "$APP" ]] || { print -u2 "release: expected product missing in the archive"; EV_BUILD_STATUS=FAIL; finish; }
if check_artifact "$APP"; then EV_BUILD_STATUS=PASS; else EV_BUILD_STATUS=FAIL; finish; fi

if [[ "$MODE" == release ]]; then
  sign_notarize_verify "$APP" || true
fi
finish
