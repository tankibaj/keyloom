import AppKit

/// How a placeholder looks in the body: monospaced text on a rounded pill, in a blue that is quiet in light mode and
/// luminous in dark mode. Colors resolve per appearance each time they are drawn.
enum TokenPill {
    static let fontSize: CGFloat = 12

    static var fill: NSColor {
        dynamic(light: NSColor(srgbRed: 0xE8 / 255, green: 0xF0 / 255, blue: 0xFE / 255, alpha: 1),
                dark: NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 255 / 255, alpha: 0.22))
    }

    static var text: NSColor {
        dynamic(light: NSColor(srgbRed: 0x0A / 255, green: 0x58 / 255, blue: 0xCA / 255, alpha: 1),
                dark: NSColor(srgbRed: 0x7C / 255, green: 0xB8 / 255, blue: 0xFF / 255, alpha: 1))
    }

    /// The pill font with the run's bold and italic carried over, so a styled placeholder keeps its style.
    static func font(traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let base = NSFont.monospacedSystemFont(ofSize: fontSize, weight: traits.contains(.bold) ? .bold : .regular)
        guard traits.contains(.italic) else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic)), size: fontSize) ?? base
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// Draws the rounded pill behind every token of a paragraph, then the text on top (TextKit 2 has no per-run
/// rounded backgrounds of its own).
final class TokenPillFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        if let paragraph = textElement as? NSTextParagraph {
            let text = paragraph.attributedString
            var color = TokenPill.fill.cgColor
            NSAppearance.currentDrawing().performAsCurrentDrawingAppearance { color = TokenPill.fill.cgColor }
            context.saveGState()
            context.setFillColor(color)
            text.enumerateAttribute(RichTextConverter.tokenKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard value != nil else { return }
                for line in textLineFragments {
                    let covered = NSIntersectionRange(range, line.characterRange)
                    guard covered.length > 0 else { continue }
                    let start = line.locationForCharacter(at: covered.location).x
                    let end = line.locationForCharacter(at: covered.location + covered.length).x
                    let bounds = line.typographicBounds
                    let rect = CGRect(x: point.x + bounds.minX + start, y: point.y + bounds.minY, width: max(0, end - start), height: bounds.height)
                        .insetBy(dx: -1, dy: 1)
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
                    context.fillPath()
                }
            }
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}

/// Hands TextKit 2 the pill-drawing fragment for every paragraph.
final class TokenPillFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        TokenPillFragment(textElement: textElement, range: textElement.elementRange)
    }
}
