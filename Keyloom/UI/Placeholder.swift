import Foundation

/// A placeholder the Insert Placeholder menu can add. `source()` is the exact token text the parser reads back.
enum Placeholder: Equatable {
    case date(format: String?)
    case time(format: String?)
    case uuid
    case clipboard
    case cursor
    case argument(name: String, defaultValue: String?, choices: [String])

    func source() throws -> String {
        switch self {
        case .date(let format): return Self.dated("date", format)
        case .time(let format): return Self.dated("time", format)
        case .uuid: return "{uuid}"
        case .clipboard: return "{clipboard}"
        case .cursor: return "{cursor}"
        case .argument(let name, let defaultValue, let choices):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.invalid("name must not be blank") }
            guard !choices.contains(where: { $0.contains(",") }) else { throw Self.invalid("choices cannot contain commas") }
            if let defaultValue, !choices.isEmpty, !choices.contains(defaultValue) { throw Self.invalid("default must be one of the choices") }
            var source = "{argument name=\(Self.quoted(name))"
            if let defaultValue { source += " default=\(Self.quoted(defaultValue))" }
            if !choices.isEmpty { source += " options=\(Self.quoted(choices.joined(separator: ", ")))" }
            return source + "}"
        }
    }

    private static func dated(_ name: String, _ format: String?) -> String {
        format.map { "{\(name) format=\(quoted($0))}" } ?? "{\(name)}"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func invalid(_ reason: String) -> KeyloomError { .invalidSnippet(field: "argument", reason: reason) }
}

/// The Argument sheet's fields.
struct ArgumentForm: Equatable {
    var name = ""
    var defaultValue = ""
    var choicesText = ""

    /// `nil` until a name is given. Empty default and choices are left out.
    var placeholder: Placeholder? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let choices = choicesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return .argument(name: name, defaultValue: defaultValue.isEmpty ? nil : defaultValue, choices: choices)
    }
}
