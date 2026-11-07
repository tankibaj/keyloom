#!/bin/zsh
# Render Icon/AppIcon.icon in every look with ictool and tile a contact sheet: Default, Dark, Tinted, Clear
# at 256 pt, then Default at 32 and 16 pt. Prints the PNG path.
set -euo pipefail
ROOT="${0:A:h:h}"
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ICTOOL" ]] || { print -u2 "icon_review: ictool not found at $ICTOOL"; exit 1; }
"$ROOT/tools/make_icon.sh" >/dev/null
OUT="${1:-/tmp/Keyloom-icon.png}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICON="$ROOT/Icon/AppIcon.icon"
render() { "$ICTOOL" "$ICON" --export-image --output-file "$TMP/$1.png" --platform macOS --rendition "$2" --width "$3" --height "$3" --scale 1 >/dev/null; }
render default Default 512
render dark Dark 512
render tinted TintedLight 512
render clear ClearLight 512
render s32 Default 32
render s16 Default 16
cat > "$TMP/sheet.swift" <<'S'
import AppKit
let d = CommandLine.arguments[1]
let W = 4 * 276 + 20, H = 276 + 100
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
func draw(_ n: String, _ r: NSRect) {
  guard let i = NSImage(contentsOfFile: "\(d)/\(n).png") else { return }
  NSGraphicsContext.current?.imageInterpolation = .high
  i.draw(in: r)
}
for (i, n) in ["default", "dark", "tinted", "clear"].enumerated() { draw(n, NSRect(x: 20 + i * 276, y: 90, width: 256, height: 256)) }
draw("s32", NSRect(x: 20, y: 30, width: 32, height: 32))
draw("s16", NSRect(x: 80, y: 38, width: 16, height: 16))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
S
swift "$TMP/sheet.swift" "$TMP" "$OUT"
print "wrote $OUT"
