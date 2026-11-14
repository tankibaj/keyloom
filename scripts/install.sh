#!/bin/zsh
# Build Keyloom.app, then install it into a directory (default /Applications).
# Usage: scripts/install.sh [dest-dir]     (or KEYLOOM_INSTALL_DIR=dest-dir)
# Stages into a fresh sibling dir, checks bundle identity, swaps with rollback.
set -euo pipefail

ROOT="${0:A:h:h}"
BUNDLE_ID="com.thenaim.keyloom"
# Earlier spellings of the bundle id; an install may still replace a build that used one of them.
LEGACY_BUNDLE_IDS=("app.keyloom.Keyloom" "com.thenaim.Keyloom")
DEST="${1:-${KEYLOOM_INSTALL_DIR:-/Applications}}"
TARGET="$DEST/Keyloom.app"
STAGE=""
SWAPPED=0

die() { print -u2 "install: $*"; exit 1; }

bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true; }

cleanup() {
  local rc=$?
  # failed after moving the old bundle aside: put it back
  if (( rc != 0 && SWAPPED )) && [[ -n "$STAGE" && -d "$STAGE/old/Keyloom.app" && ! -e "$TARGET" ]]; then
    mv "$STAGE/old/Keyloom.app" "$TARGET" && print -u2 "install: rolled back to previous Keyloom.app"
  fi
  # STAGE is our own mktemp dir; on failure keep it if the old app is still stranded in it
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then
    if (( rc != 0 )) && [[ -e "$STAGE/old/Keyloom.app" ]]; then
      print -u2 "install: previous app kept at $STAGE/old/Keyloom.app"
    else
      rm -rf "$STAGE"
    fi
  fi
  exit $rc
}
trap cleanup EXIT

[[ -d "$DEST" ]] || die "destination is not a directory: $DEST"
[[ -w "$DEST" ]] || die "destination not writable: $DEST"
DEST="${DEST:A}"
TARGET="$DEST/Keyloom.app"

# Build first; last stdout line is the product path
BUILT="$("$ROOT/scripts/build.sh" | tail -n 1)"
[[ -d "$BUILT" ]] || die "built app not found: $BUILT"
[[ "$(bundle_id "$BUILT")" == "$BUNDLE_ID" ]] || die "built app has unexpected bundle id: $(bundle_id "$BUILT")"

# Existing target must be a real Keyloom bundle, else leave it alone
if [[ -L "$TARGET" ]]; then
  die "refusing to replace symlink: $TARGET"
elif [[ -e "$TARGET" ]]; then
  [[ -d "$TARGET" ]] || die "refusing to replace non-bundle: $TARGET"
  EXISTING="$(bundle_id "$TARGET")"
  [[ "$EXISTING" == "$BUNDLE_ID" || ${LEGACY_BUNDLE_IDS[(Ie)$EXISTING]} -gt 0 ]] || die "existing $TARGET has bundle id '${EXISTING:-none}', expected $BUNDLE_ID; not replacing"
fi

# Fresh sibling staging dir (same filesystem, so the moves below are renames)
STAGE="$(mktemp -d "$DEST/.Keyloom-stage.XXXXXX")" || die "cannot create staging dir in $DEST"
ditto "$BUILT" "$STAGE/Keyloom.app"
[[ "$(bundle_id "$STAGE/Keyloom.app")" == "$BUNDLE_ID" ]] || die "staged copy failed identity check"

# The build is ad-hoc signed, so its identity is a hash that changes every build and macOS drops the Accessibility
# grant on each install. Pin the designated requirement to the bundle id so the grant survives rebuilds.
codesign --force --sign - --preserve-metadata=entitlements,flags \
  -r="designated => identifier \"$BUNDLE_ID\"" "$STAGE/Keyloom.app" >&2 || die "re-signing failed"

# macOS mv has no atomic swap: move old aside, move new in, roll back on failure
if [[ -e "$TARGET" ]]; then
  mkdir "$STAGE/old"
  SWAPPED=1
  mv "$TARGET" "$STAGE/old/Keyloom.app"
fi
mv "$STAGE/Keyloom.app" "$TARGET"

print "Installed: $TARGET"
