import AppKit
import SwiftUI

/// What the icon picker offers (symbols come from `SymbolCatalog`), and what it accepts when typed.
enum IconCatalog {
    static let emojis = ["📝", "✉️", "👋", "📅", "⏰", "✅", "⭐️", "💡", "🔗", "📞", "🏠", "💼", "🎉", "❤️", "🔒", "🧾"]
    static var symbols: [String] { SymbolCatalog.allNames }

    /// One emoji (a single grapheme with emoji presentation), else nil.
    static func emoji(from input: String) -> SnippetIcon? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 1, let first = text.unicodeScalars.first else { return nil }
        let isEmoji = first.properties.isEmojiPresentation || text.unicodeScalars.contains { $0.value == 0xFE0F }
            || (text.unicodeScalars.count > 1 && first.properties.isEmoji)
        return isEmoji ? .emoji(text) : nil
    }

    static func symbol(from input: String) -> SnippetIcon? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? nil : .symbol(name)
    }
}

/// A rendered snippet as styled text for the preview, with the caret position shown as a marker.
enum PreviewText {
    static let cursorMarker = "▏"

    static func attributed(_ rendered: RenderedSnippet) -> AttributedString {
        var result = AttributedString()
        var offset = 0
        func append(_ text: String, _ style: TextStyle) {
            guard !text.isEmpty else { return }
            var piece = AttributedString(text)
            var intent: InlinePresentationIntent = []
            if style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if style.contains(.italic) { intent.insert(.emphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if style.contains(.underline) { piece.underlineStyle = .single }
            result.append(piece)
        }
        for segment in rendered.segments {
            let length = segment.text.utf16.count
            if let cursor = rendered.cursorOffset, cursor >= offset, cursor < offset + length || (cursor == offset + length && segment == rendered.segments.last) {
                let split = String.Index(utf16Offset: cursor - offset, in: segment.text)
                append(String(segment.text[..<split]), segment.style)
                var marker = AttributedString(cursorMarker)
                marker.foregroundColor = .accentColor
                result.append(marker)
                append(String(segment.text[split...]), segment.style)
            } else {
                append(segment.text, segment.style)
            }
            offset += length
        }
        if rendered.segments.isEmpty, rendered.cursorOffset != nil { result.append(AttributedString(cursorMarker)) }
        return result
    }
}
