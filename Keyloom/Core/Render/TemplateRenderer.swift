import Foundation

/// Everything the renderer needs from the outside world, injected so tests and callers control it.
/// Clipboard text and argument values pass through rendering only; nothing here stores or logs them.
struct RenderEnvironment: Sendable {
    var date: Date
    var timeZone: TimeZone
    var locale: Locale
    var makeUUID: @Sendable () -> UUID
    /// Current clipboard text, `nil` when it holds none. Called at most once per render.
    var clipboardText: @Sendable () -> String?
}

/// One argument to prompt for, merged over every occurrence of its name.
struct ArgumentRequirement: Sendable, Hashable {
    let name: String
    /// Prefill for the prompt; also the value used when no answer is given.
    let defaultValue: String?
    /// Selectable options; empty means free text.
    let choices: [String]
}

enum RenderError: Error, Equatable, Sendable {
    /// Arguments with no value and no default, in order of first appearance.
    case missingArguments(names: [String])
    /// The value (provided or default) is not one of the argument's options. Never carries the value.
    case choiceNotInOptions(name: String)
}

struct StyledSegment: Sendable, Hashable {
    let text: String
    let style: TextStyle
}

/// Styled and plain output of one render. Deliberately not `Codable`: it may hold clipboard text and
/// argument values, which must not be persisted.
struct RenderedSnippet: Sendable, Hashable {
    /// One segment per styled run (substituted values inherit the run's style), plus unstyled list
    /// markers and paragraph newlines. Concatenated, the segments equal `plainText`.
    let segments: [StyledSegment]
    let plainText: String
    /// Caret position in `plainText` as UTF-16 units on a scalar boundary; `nil` without a cursor marker.
    let cursorOffset: Int?
}

/// Renders a parsed `Document`. List paragraphs get a text marker ("• " or "N. ") in both outputs, because
/// destinations outside the app only receive text.
struct TemplateRenderer: Sendable {
    let environment: RenderEnvironment

    /// Arguments that still need an answer: every distinct name with no entry in `provided`, in order
    /// of first appearance. Empty means direct expansion. An argument with a default is listed (so the
    /// prompt can prefill it); a caller that wants to skip those checks `defaultValue`.
    static func requiredArguments(in document: Document, provided: [String: String] = [:]) -> [ArgumentRequirement] {
        mergedArguments(in: document).filter { provided[$0.name] == nil }
    }

    func render(_ document: Document, arguments: [String: String] = [:]) throws -> RenderedSnippet {
        try document.validate()
        let values = try Self.resolve(Self.mergedArguments(in: document), arguments: arguments)
        var output = Output()
        var clipboard: String?? = nil
        var number = 0
        var previousKind = ParagraphKind.plain
        for (index, paragraph) in document.paragraphs.enumerated() {
            if index > 0 { output.append("\n", style: []) }
            number = paragraph.kind == .numbered && previousKind == .numbered ? number + 1 : 1
            previousKind = paragraph.kind
            switch paragraph.kind {
            case .plain: break
            case .bullet: output.append("• ", style: [])
            case .numbered: output.append("\(number). ", style: [])
            }
            for run in paragraph.runs {
                var text = ""
                for span in run.spans {
                    switch span {
                    case .literal(let literal):
                        text += literal
                    case .token(let token):
                        switch token.kind {
                        case .cursor:
                            output.flush(&text, style: run.style)
                            output.cursorOffset = output.length
                        case .date(let pattern): text += formatDate(environment, pattern: pattern, isDate: true)
                        case .time(let pattern): text += formatDate(environment, pattern: pattern, isDate: false)
                        case .uuid: text += environment.makeUUID().uuidString
                        case .clipboard:
                            if clipboard == nil { clipboard = .some(environment.clipboardText()) }
                            text += clipboard.flatMap { $0 } ?? ""
                        case .argument(let name, _, _): text += values[name] ?? ""
                        case .unsupported: text += token.raw
                        }
                    }
                }
                output.flush(&text, style: run.style)
            }
        }
        let plain = output.segments.map(\.text).joined()
        let cursor = try output.cursorOffset.map { try plain.validatedCursor(utf16Offset: $0) }
        return RenderedSnippet(segments: output.segments, plainText: plain, cursorOffset: cursor)
    }

    /// Distinct arguments in order of first appearance; the first default and first non-empty options win.
    private static func mergedArguments(in document: Document) -> [ArgumentRequirement] {
        var order: [String] = []
        var merged: [String: ArgumentRequirement] = [:]
        for run in document.paragraphs.flatMap(\.runs) {
            for case .token(let token) in run.spans {
                guard case .argument(let name, let defaultValue, let choices) = token.kind else { continue }
                let existing = merged[name]
                if existing == nil { order.append(name) }
                merged[name] = ArgumentRequirement(name: name,
                                                   defaultValue: existing?.defaultValue ?? defaultValue,
                                                   choices: existing.map { $0.choices.isEmpty ? choices : $0.choices } ?? choices)
            }
        }
        return order.compactMap { merged[$0] }
    }

    private static func resolve(_ requirements: [ArgumentRequirement], arguments: [String: String]) throws -> [String: String] {
        let missing = requirements.filter { arguments[$0.name] == nil && $0.defaultValue == nil }.map(\.name)
        guard missing.isEmpty else { throw RenderError.missingArguments(names: missing) }
        var values: [String: String] = [:]
        for requirement in requirements {
            let value = arguments[requirement.name] ?? requirement.defaultValue ?? ""
            guard requirement.choices.isEmpty || requirement.choices.contains(value) else {
                throw RenderError.choiceNotInOptions(name: requirement.name)
            }
            values[requirement.name] = value
        }
        return values
    }
}

private struct Output {
    var segments: [StyledSegment] = []
    var length = 0
    var cursorOffset: Int?

    mutating func append(_ text: String, style: TextStyle) {
        guard !text.isEmpty else { return }
        segments.append(StyledSegment(text: text, style: style))
        length += text.utf16.count
    }

    mutating func flush(_ text: inout String, style: TextStyle) {
        append(text, style: style)
        text = ""
    }
}

private func formatDate(_ environment: RenderEnvironment, pattern: String?, isDate: Bool) -> String {
    let formatter = DateFormatter()
    formatter.locale = environment.locale
    formatter.calendar = environment.locale.calendar
    formatter.timeZone = environment.timeZone
    if let pattern {
        formatter.dateFormat = pattern
    } else if isDate {
        formatter.dateStyle = .medium
    } else {
        formatter.timeStyle = .short
    }
    return formatter.string(from: environment.date)
}
