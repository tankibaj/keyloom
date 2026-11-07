import Foundation
import Observation

/// State machine of the named-argument prompt: one field per distinct name, defaults prefilled, choices as
/// pickers, finished exactly once with the answers (Confirm) or nil (Cancel). Answers pass through here and
/// are never stored or logged.
@MainActor @Observable
final class ArgumentPromptModel {
    struct Field: Identifiable, Equatable {
        let name: String
        let choices: [String]
        /// Free text with no default: left blank, the snippet could not be rendered.
        let isRequired: Bool
        var value: String
        var id: String { name }
        var isChoice: Bool { !choices.isEmpty }

        fileprivate var isValid: Bool {
            isChoice ? choices.contains(value) : (!isRequired || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    let title: String
    private(set) var fields: [Field]
    @ObservationIgnored var onFinish: (([String: String]?) -> Void)?
    @ObservationIgnored private var isFinished = false

    /// Repeated names are asked once: the first occurrence wins.
    init(title: String, requirements: [ArgumentRequirement]) {
        self.title = title
        var seen = Set<String>()
        fields = requirements.filter { seen.insert($0.name).inserted }.map { requirement in
            let value: String
            if requirement.choices.isEmpty {
                value = requirement.defaultValue ?? ""
            } else {
                value = requirement.defaultValue.flatMap { requirement.choices.contains($0) ? $0 : nil } ?? requirement.choices[0]
            }
            return Field(name: requirement.name, choices: requirement.choices,
                         isRequired: requirement.choices.isEmpty && requirement.defaultValue == nil, value: value)
        }
    }

    var canConfirm: Bool { !isFinished && fields.allSatisfy(\.isValid) }

    /// A choice field keeps its value when handed something outside its options.
    func setValue(_ value: String, for name: String) {
        guard let index = fields.firstIndex(where: { $0.name == name }) else { return }
        if fields[index].isChoice, !fields[index].choices.contains(value) { return }
        fields[index].value = value
    }

    func confirm() {
        guard canConfirm else { return }
        finish(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) }))
    }

    func cancel() { finish(nil) }

    private func finish(_ answers: [String: String]?) {
        guard !isFinished else { return }
        isFinished = true
        onFinish?(answers)
    }
}
