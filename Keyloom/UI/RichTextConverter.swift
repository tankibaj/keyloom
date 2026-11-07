import AppKit

/// Converts between the WP2 `Document` and the attributed string the editor shows.
///
/// - Paragraphs are separated by "\n"; list paragraphs start with a real marker ("• " or "N. ") tagged
///   `listMarkerKey`, so the rendered text matches what expansion later inserts. Markers are not part of the model.
/// - Tokens are the exact `raw` source text tagged `tokenKey`, drawn as a chip. Because the raw text is kept, every
///   offset in a marker-free paragraph is the same UTF-16 offset in the model's `plainText`.
/// - Styles live in the font traits and the underline attribute, as in any native text view.
enum RichTextConverter {
    static let tokenKey = NSAttributedString.Key("app.keyloom.token")
    static let kindKey = NSAttributedString.Key("app.keyloom.paragraphKind")
    static let listMarkerKey = NSAttributedString.Key("app.keyloom.listMarker")

    static var baseFont: NSFont { .preferredFont(forTextStyle: .body) }

    // MARK: Model to text

    static func attributedString(from document: Document) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var number = 0
        var previous = ParagraphKind.plain
        for (index, paragraph) in document.paragraphs.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n", attributes: attributes(style: [], kind: previous))) }
            number = paragraph.kind == .numbered && previous == .numbered ? number + 1 : 1
            previous = paragraph.kind
            if let marker = markerText(paragraph.kind, number: number) {
                out.append(NSAttributedString(string: marker, attributes: attributes(style: [], kind: paragraph.kind, isMarker: true)))
            }
            for run in paragraph.runs {
                for span in run.spans {
                    switch span {
                    case .literal(let text):
                        out.append(NSAttributedString(string: text, attributes: attributes(style: run.style, kind: paragraph.kind)))
                    case .token(let token):
                        out.append(NSAttributedString(string: token.raw, attributes: attributes(style: run.style, kind: paragraph.kind, isToken: true)))
                    }
                }
            }
        }
        return out
    }

    static func markerText(_ kind: ParagraphKind, number: Int) -> String? {
        switch kind {
        case .plain: nil
        case .bullet: "• "
        case .numbered: "\(number). "
        }
    }

    static func attributes(style: TextStyle, kind: ParagraphKind, isMarker: Bool = false, isToken: Bool = false) -> [NSAttributedString.Key: Any] {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if style.contains(.bold) { traits.insert(.bold) }
        if style.contains(.italic) { traits.insert(.italic) }
        let font = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(traits), size: baseFont.pointSize) ?? baseFont
        var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        if style.contains(.underline) { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if kind != .plain {
            result[kindKey] = kind.rawValue
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = 18
            result[.paragraphStyle] = paragraphStyle
        }
        if isMarker { result[listMarkerKey] = true }
        if isToken {
            result[tokenKey] = true
            result[.backgroundColor] = NSColor.controlAccentColor.withAlphaComponent(0.2)
        }
        return result
    }

    static func style(of attributes: [NSAttributedString.Key: Any]) -> TextStyle {
        var style: TextStyle = []
        if let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits {
            if traits.contains(.bold) { style.insert(.bold) }
            if traits.contains(.italic) { style.insert(.italic) }
        }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { style.insert(.underline) }
        return style
    }

    // MARK: Text to model

    /// Never fails: text that is not a valid token stays literal. Size limits are checked when the document is saved.
    static func document(from text: NSAttributedString) -> Document {
        guard text.length > 0 else { return Document(paragraphs: []) }
        return Document(paragraphs: paragraphRanges(in: text.string).map { paragraph(in: text, range: $0) })
    }

    private static func paragraph(in text: NSAttributedString, range: NSRange) -> Paragraph {
        let kind = range.length > 0 ? ParagraphKind(rawValue: text.attribute(kindKey, at: range.location, effectiveRange: nil) as? String ?? "") ?? .plain : .plain
        let contentStart = range.location + markerLength(in: text, paragraph: range)
        let contentRange = NSRange(location: contentStart, length: range.upperBound - contentStart)
        var runs: [Run] = []
        text.enumerateAttributes(in: contentRange) { attributes, segment, _ in
            let style = style(of: attributes)
            let raw = (text.string as NSString).substring(with: segment)
            let span: TemplateSpan = attributes[tokenKey] != nil ? token(fromSource: raw).map { .token($0) } ?? .literal(raw) : .literal(raw)
            if let last = runs.last, last.style == style {
                if case .literal(let more) = span, case .literal(let before)? = runs[runs.count - 1].spans.last {
                    runs[runs.count - 1].spans[runs[runs.count - 1].spans.count - 1] = .literal(before + more)
                } else {
                    runs[runs.count - 1].spans.append(span)
                }
            } else {
                runs.append(Run(style: style, spans: [span]))
            }
        }
        return Paragraph(kind: kind, runs: runs.isEmpty ? [Run(style: [], spans: [])] : runs)
    }

    private static func token(fromSource source: String) -> Token? {
        guard let parsed = try? TokenParser.parse(source), parsed.spans.count == 1, case .token(let token) = parsed.spans[0].span else { return nil }
        return token
    }

    // MARK: Paragraph helpers

    /// Ranges of each paragraph without its "\n"; an empty string is one empty paragraph.
    static func paragraphRanges(in string: String) -> [NSRange] {
        let text = string as NSString
        var ranges: [NSRange] = []
        var start = 0
        while true {
            let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
            if newline.location == NSNotFound {
                ranges.append(NSRange(location: start, length: text.length - start))
                return ranges
            }
            ranges.append(NSRange(location: start, length: newline.location - start))
            start = newline.upperBound
        }
    }

    static func markerLength(in text: NSAttributedString, paragraph: NSRange) -> Int {
        var length = 0
        while length < paragraph.length, text.attribute(listMarkerKey, at: paragraph.location + length, effectiveRange: nil) != nil { length += 1 }
        return length
    }

    static func paragraphIndex(containing location: Int, in string: String) -> Int {
        paragraphRanges(in: string).lastIndex { $0.location <= location } ?? 0
    }

    // MARK: Lists

    /// Makes every list paragraph carry the marker its kind and position call for (renumbering after any edit).
    /// A paragraph's kind is read from its first character, so an empty paragraph is plain.
    static func normalizeLists(_ text: NSMutableAttributedString) {
        var number = 0
        var previous = ParagraphKind.plain
        var index = 0
        while index < paragraphRanges(in: text.string).count {
            let range = paragraphRanges(in: text.string)[index]
            let kind = range.length > 0 ? ParagraphKind(rawValue: text.attribute(kindKey, at: range.location, effectiveRange: nil) as? String ?? "") ?? .plain : .plain
            number = kind == .numbered && previous == .numbered ? number + 1 : 1
            previous = kind
            let existing = NSRange(location: range.location, length: markerLength(in: text, paragraph: range))
            let expected = markerText(kind, number: number) ?? ""
            if (text.string as NSString).substring(with: existing) != expected {
                text.replaceCharacters(in: existing, with: NSAttributedString(string: expected, attributes: attributes(style: [], kind: kind, isMarker: true)))
            }
            index += 1
        }
    }

    // MARK: Tokens

    /// Turns valid token source typed or pasted as plain text into chips, in one paragraph. If the paragraph's untagged
    /// text does not parse as a whole (an unclosed or malformed token), it is left as text.
    static func chipTokens(in text: NSMutableAttributedString, paragraphAt index: Int) {
        let ranges = paragraphRanges(in: text.string)
        guard ranges.indices.contains(index) else { return }
        var segments: [NSRange] = []
        text.enumerateAttribute(tokenKey, in: ranges[index]) { value, range, _ in if value == nil { segments.append(range) } }
        for segment in segments {
            guard let parsed = try? TokenParser.parse((text.string as NSString).substring(with: segment)) else { continue }
            for piece in parsed.spans {
                guard case .token = piece.span else { continue }
                let range = NSRange(location: segment.location + piece.sourceRange.start, length: piece.sourceRange.length)
                let style = style(of: text.attributes(at: range.location, effectiveRange: nil))
                text.setAttributes(attributes(style: style, kind: ParagraphKind(rawValue: text.attribute(kindKey, at: range.location, effectiveRange: nil) as? String ?? "") ?? .plain, isToken: true), range: range)
            }
        }
    }

    enum TokenEdit: Equatable {
        case allow
        /// Replace this wider range instead: the edit touched part of a token.
        case replace(NSRange)
        case reject
    }

    /// Tokens are atomic: typing inside one is refused; deleting or replacing part of one takes all of it.
    static func tokenEdit(range: NSRange, replacement: String, in text: NSAttributedString) -> TokenEdit {
        var union = range
        var strictlyInside = false
        text.enumerateAttribute(tokenKey, in: NSRange(location: 0, length: text.length)) { value, token, _ in
            guard value != nil else { return }
            if range.length == 0 {
                if range.location > token.location, range.location < token.upperBound { strictlyInside = true }
            } else if NSIntersectionRange(range, token).length > 0 {
                union = NSUnionRange(union, token)
            }
        }
        if strictlyInside, !replacement.isEmpty { return .reject }
        return union == range ? .allow : .replace(union)
    }
}
