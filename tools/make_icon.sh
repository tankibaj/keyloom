#!/bin/zsh
# Compile Icon/AppIcon.icon with actool into Resources/Assets.car and Resources/AppIcon.icns.
# The app build compiles the icon through Xcode itself (Keyloom/AppIcon.icon -> ../Icon/AppIcon.icon);
# this script is for review and standalone artifacts.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[[ -d "$ROOT/Icon/AppIcon.icon" ]] || { print -u2 "make_icon: Icon/AppIcon.icon missing"; exit 1; }
mkdir -p "$OUT"
xcrun actool "$ROOT/Icon/AppIcon.icon" --compile "$TMP" --output-format human-readable-text \
  --notices --warnings --errors --output-partial-info-plist "$TMP/partial.plist" \
  --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
  --development-region en --target-device mac --minimum-deployment-target 26.0 --platform macosx >&2
[[ -f "$TMP/Assets.car" && -f "$TMP/AppIcon.icns" ]] || { print -u2 "make_icon: actool wrote no output (folder must be named AppIcon.icon)"; exit 1; }
cp "$TMP/Assets.car" "$TMP/AppIcon.icns" "$OUT/"
print "wrote Resources/Assets.car and Resources/AppIcon.icns"
