import Foundation

/// A parsed piece with the exact UTF-16 range of the source text it came from.
struct ParsedSpan: Sendable, Hashable {
    let span: TemplateSpan
    let sourceRange: ValidatedUTF16Range
}

struct ParsedTemplate: Sendable, Hashable {
    var spans: [ParsedSpan]
    /// Source ranges of unsupported tokens, kept literally and flagged for the user to review.
    var unsupported: [ValidatedUTF16Range]

    /// Unstyled document: literal newlines start new plain paragraphs.
    var document: Document {
        var paragraphs: [[TemplateSpan]] = [[]]
        for parsed in spans {
            switch parsed.span {
            case .literal(let text):
                // "\r\n" is one Character, so it is matched as a whole; a lone CR is a line break too.
                let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
                for (index, line) in lines.enumerated() {
                    if index > 0 { paragraphs.append([]) }
                    if !line.isEmpty { paragraphs[paragraphs.count - 1].append(.literal(String(line))) }
                }
            case .token:
                paragraphs[paragraphs.count - 1].append(parsed.span)
            }
        }
        return Document(paragraphs: paragraphs.map { Paragraph(kind: .plain, runs: [Run(style: [], spans: $0)]) })
    }
}

/// Parse failures. Payloads are UTF-16 offsets of the source (and an argument name, which is template
/// metadata); template text and values never appear in an error.
enum TemplateParseError: Error, Equatable, Sendable {
    /// A `{` with no closing `}` (a `}` inside a quoted value does not close it).
    case unterminatedToken(offset: Int)
    /// Known token whose attributes are not `key="value"` pairs, repeat a key, or give an empty format.
    case malformedToken(ValidatedUTF16Range)
    case emptyArgumentName(ValidatedUTF16Range)
    /// The same name defined twice with different defaults or different options.
    case conflictingArgument(name: String, ValidatedUTF16Range)
    case defaultNotInOptions(name: String, ValidatedUTF16Range)
    /// Range of the second cursor marker.
    case multipleCursors(ValidatedUTF16Range)
}

/// Parses Raycast-style template source: `{date format="yyyy-MM-dd"}`, `{time}`, `{uuid}`, `{clipboard}`,
/// `{cursor}`, `{argument name="n" default="d" options="a, b"}`.
///
/// Rules:
/// - Escapes outside tokens: `\{` `\}` `\\` yield the literal character; any other backslash stays as is.
///   A lone `}` outside a token is literal. Inside a token, values are double-quoted and `\"` `\\` escape.
/// - Names are lowercase ASCII. An unknown name, a name not followed by whitespace, or a known name with
///   an unknown attribute (for example `{date offset="+1d"}`) becomes `.unsupported`: its source is kept
///   literally and its range is listed in `unsupported` for review.
/// - A known token with broken attribute syntax is an error rather than unsupported, since its intent is clear.
/// - One argument name may repeat; definitions must not conflict (an absent default or options fills in
///   from another occurrence). Renderer and prompt reuse one answer per name.
enum TokenParser {
    static func parse(_ source: String) throws -> ParsedTemplate {
        var scanner = Scanner(source: source)
        try scanner.run()
        try scanner.checkArguments()
        return ParsedTemplate(spans: scanner.spans, unsupported: scanner.unsupported)
    }
}

private struct Scanner {
    let source: String
    let scalars: [Unicode.Scalar]
    /// UTF-16 offset of each scalar index, plus the total at the end.
    let offsets: [Int]
    var spans: [ParsedSpan] = []
    var unsupported: [ValidatedUTF16Range] = []

    init(source: String) {
        self.source = source
        scalars = Array(source.unicodeScalars)
        var running = 0
        var table = [0]
        table.reserveCapacity(scalars.count + 1)
        for scalar in scalars {
            running += scalar.value > 0xFFFF ? 2 : 1
            table.append(running)
        }
        offsets = table
    }

    private func range(_ start: Int, _ end: Int) throws -> ValidatedUTF16Range {
        try ValidatedUTF16Range(start: offsets[start], end: offsets[end], in: source)
    }

    mutating func run() throws {
        var literal = ""
        var literalStart = 0
        var index = 0
        func flush(upTo end: Int, into scanner: inout Scanner) throws {
            guard !literal.isEmpty else { return }
            scanner.spans.append(ParsedSpan(span: .literal(literal), sourceRange: try scanner.range(literalStart, end)))
            literal = ""
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "{" {
                try flush(upTo: index, into: &self)
                guard let close = closingBrace(from: index) else {
                    throw TemplateParseError.unterminatedToken(offset: offsets[index])
                }
                try appendToken(from: index, to: close)
                index = close + 1
                literalStart = index
                continue
            }
            if literal.isEmpty { literalStart = index }
            if scalar == "\\", index + 1 < scalars.count, ["{", "}", "\\"].contains(scalars[index + 1]) {
                literal.unicodeScalars.append(scalars[index + 1])
                index += 2
            } else {
                literal.unicodeScalars.append(scalar)
                index += 1
            }
        }
        try flush(upTo: scalars.count, into: &self)
    }

    /// Quote-aware: a `}` inside a double-quoted value does not end the token.
    private func closingBrace(from open: Int) -> Int? {
        var index = open + 1
        var inQuote = false
        while index < scalars.count {
            let scalar = scalars[index]
            if inQuote {
                if scalar == "\\" { index += 1 } else if scalar == "\"" { inQuote = false }
            } else if scalar == "\"" {
                inQuote = true
            } else if scalar == "}" {
                return index
            }
            index += 1
        }
        return nil
    }

    private mutating func appendToken(from open: Int, to close: Int) throws {
        let sourceRange = try range(open, close + 1)
        let raw = String(String.UnicodeScalarView(scalars[open...close]))
        let kind = try tokenKind(body: Array(scalars[(open + 1)..<close]), sourceRange: sourceRange) ?? .unsupported(raw: raw)
        if case .unsupported = kind { unsupported.append(sourceRange) }
        spans.append(ParsedSpan(span: .token(Token(kind: kind, raw: raw)), sourceRange: sourceRange))
    }

    /// `nil` means unsupported.
    private func tokenKind(body: [Unicode.Scalar], sourceRange: ValidatedUTF16Range) throws -> TokenKind? {
        let nameEnd = body.firstIndex { !("a"..."z").contains($0) } ?? body.count
        let name = String(String.UnicodeScalarView(body[..<nameEnd]))
        guard ["date", "time", "uuid", "clipboard", "cursor", "argument"].contains(name),
              nameEnd == body.count || body[nameEnd].properties.isWhitespace else { return nil }
        let attributes = try parseAttributes(body[nameEnd...], sourceRange: sourceRange)
        func only(_ allowed: Set<String>) -> Bool { Set(attributes.keys).isSubset(of: allowed) }
        switch name {
        case "date", "time":
            guard only(["format"]) else { return nil }
            let format = attributes["format"]
            if format?.isEmpty == true { throw TemplateParseError.malformedToken(sourceRange) }
            return name == "date" ? .date(format: format) : .time(format: format)
        case "uuid": return only([]) ? .uuid : nil
        case "clipboard": return only([]) ? .clipboard : nil
        case "cursor": return only([]) ? .cursor : nil
        default:
            guard only(["name", "default", "options"]) else { return nil }
            guard let argumentName = attributes["name"], !argumentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TemplateParseError.emptyArgumentName(sourceRange)
            }
            let choices = (attributes["options"] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let defaultValue = attributes["default"]
            if let defaultValue, !choices.isEmpty, !choices.contains(defaultValue) {
                throw TemplateParseError.defaultNotInOptions(name: argumentName, sourceRange)
            }
            return .argument(name: argumentName, defaultValue: defaultValue, choices: choices)
        }
    }

    private func parseAttributes(_ text: ArraySlice<Unicode.Scalar>, sourceRange: ValidatedUTF16Range) throws -> [String: String] {
        let malformed = TemplateParseError.malformedToken(sourceRange)
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].properties.isWhitespace { index += 1; continue }
            var key = ""
            while index < text.endIndex, ("a"..."z").contains(text[index]) {
                key.unicodeScalars.append(text[index])
                index += 1
            }
            guard !key.isEmpty, result[key] == nil, index + 1 < text.endIndex,
                  text[index] == "=", text[index + 1] == "\"" else { throw malformed }
            index += 2
            var value = ""
            var closed = false
            while index < text.endIndex {
                let scalar = text[index]
                index += 1
                if scalar == "\"" { closed = true; break }
                if scalar == "\\", index < text.endIndex, text[index] == "\"" || text[index] == "\\" {
                    value.unicodeScalars.append(text[index])
                    index += 1
                } else {
                    value.unicodeScalars.append(scalar)
                }
            }
            guard closed, index == text.endIndex || text[index].properties.isWhitespace else { throw malformed }
            result[key] = value
        }
        return result
    }

    /// Cross-token rules: one cursor, and compatible repeated argument definitions.
    func checkArguments() throws {
        var cursors = 0
        var definitions: [String: (defaultValue: String?, choices: [String])] = [:]
        for parsed in spans {
            guard case .token(let token) = parsed.span else { continue }
            switch token.kind {
            case .cursor:
                cursors += 1
                if cursors > 1 { throw TemplateParseError.multipleCursors(parsed.sourceRange) }
            case .argument(let name, let defaultValue, let choices):
                var merged = definitions[name] ?? (nil, [])
                if let defaultValue {
                    if let existing = merged.defaultValue, existing != defaultValue {
                        throw TemplateParseError.conflictingArgument(name: name, parsed.sourceRange)
                    }
                    merged.defaultValue = defaultValue
                }
                if !choices.isEmpty {
                    if !merged.choices.isEmpty, merged.choices != choices {
                        throw TemplateParseError.conflictingArgument(name: name, parsed.sourceRange)
                    }
                    merged.choices = choices
                }
                if let value = merged.defaultValue, !merged.choices.isEmpty, !merged.choices.contains(value) {
                    throw TemplateParseError.defaultNotInOptions(name: name, parsed.sourceRange)
                }
                definitions[name] = merged
            default:
                break
            }
        }
    }
}
