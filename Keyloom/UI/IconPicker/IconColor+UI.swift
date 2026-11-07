import AppKit
import SwiftUI

extension IconColor {
    var displayName: String { rawValue.capitalized }

    /// Each name maps to an adaptive system color, so light, dark and Increase Contrast pick their own value.
    /// Where the system has no such color the name is a fixed mix of two system colors, resolved per appearance:
    ///
    ///     red systemRed          salmon  systemRed + systemOrange   orange systemOrange
    ///     yellow systemYellow    green   systemGreen               teal   systemTeal
    ///     sky systemCyan         blue    systemBlue                indigo systemIndigo
    ///     purple systemPurple    violet  systemPurple + systemIndigo + white   pink systemPink
    ///     gray systemGray        sage    systemGreen + systemGray  tan    systemBrown + systemOrange
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .salmon: Self.mix(.systemRed, .systemOrange, 0.5)
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .sky: .systemCyan
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .violet: Self.mix(Self.mix(.systemPurple, .systemIndigo, 0.5), .white, 0.25)
        case .pink: .systemPink
        case .gray: .systemGray
        case .sage: Self.mix(.systemGreen, .systemGray, 0.55)
        case .tan: Self.mix(.systemBrown, .systemOrange, 0.3)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// A dynamic color: the blend is computed each time the appearance changes, never frozen.
    private static func mix(_ base: NSColor, _ other: NSColor, _ fraction: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var mixed = base
            appearance.performAsCurrentDrawingAppearance {
                mixed = base.blended(withFraction: fraction, of: other) ?? base
            }
            return mixed
        }
    }
}

extension SnippetIcon {
    /// What VoiceOver reads for the icon button.
    var spoken: String {
        switch self {
        case .emoji(let emoji): emoji
        case .symbol(let name, let color):
            [SymbolEntry(name: name, keywords: []).label, color?.rawValue].compactMap { $0 }.joined(separator: ", ")
        }
    }
}
