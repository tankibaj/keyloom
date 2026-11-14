import Foundation

/// Why macOS says the on-device model is unavailable. Only reasons the OS exposes appear here; a reason the
/// app does not recognise is `unspecified`. Nothing is ever inferred, in particular not an IT restriction.
enum UnavailableReason: Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case unspecified
}

/// What the OS reports about the on-device language model, separately from system Writing Tools.
enum ModelAvailability: Equatable, Sendable {
    case available
    /// macOS reports the model as not ready yet (Apple documents this as possibly still downloading).
    case downloading
    case unsupportedLanguage
    case unavailable(UnavailableReason)
}

/// Effective state of the app's own on-device assistance.
enum AssistanceState: Equatable, Sendable {
    case off
    case ready
    case unavailable(UnavailableReason)
    case downloading
    case unsupportedLanguage
    /// `AllowWritingAssistance=false` is forced by the organization.
    case managedOff
}

/// Effective state of the system Writing Tools opt-in. `allowed` only means the app does not block them:
/// macOS (and any device restriction) decides whether they appear, and the app cannot and does not read that.
enum WritingToolsState: Equatable, Sendable {
    case off
    case allowed
    case managedOff
}

/// The managed `AllowWritingAssistance` preference. It can only force assistance off.
enum ManagedAssistancePolicy: Equatable, Sendable {
    case notManaged
    case allowed
    case forbidden
}

/// What the editor sets as the text view's `writingToolsBehavior`.
enum EditorWritingToolsBehavior: Equatable, Sendable {
    case none
    case `default`
}

/// Process boundary: the OS model-availability query. A real adapter wraps FoundationModels.
protocol ModelAvailabilityProvider: Sendable {
    func availability(for locale: Locale) -> ModelAvailability
}

/// Process boundary: the managed-preferences domain.
protocol ManagedPolicyReader: Sendable {
    func read() -> ManagedAssistancePolicy
}

/// An immutable view of the policy at one moment. Pure: every rule lives here, so it is testable without
/// UserDefaults or the OS.
struct PolicySnapshot: Equatable, Sendable {
    var assistanceOptIn: Bool
    var writingToolsOptIn: Bool
    var managed: ManagedAssistancePolicy
    /// `nil` when the OS was not asked (opt-in off or managed off).
    var modelAvailability: ModelAvailability?

    var assistance: AssistanceState {
        if managed == .forbidden { return .managedOff }
        guard assistanceOptIn else { return .off }
        switch modelAvailability {
        case .available: return .ready
        case .downloading: return .downloading
        case .unsupportedLanguage: return .unsupportedLanguage
        case .unavailable(let reason): return .unavailable(reason)
        // Opted in but not yet asked: never report ready.
        case nil: return .unavailable(.unspecified)
        }
    }

    var writingTools: WritingToolsState {
        if managed == .forbidden { return .managedOff }
        return writingToolsOptIn ? .allowed : .off
    }

    var permitsOnDeviceEdits: Bool { assistance == .ready }

    /// `none` unless the user opted in, nothing forces it off and the field holds prose. A Writing Tools
    /// restriction by the system is invisible here and never opens another route.
    func writingToolsBehavior(forProseField isProse: Bool) -> EditorWritingToolsBehavior {
        isProse && writingTools == .allowed ? .default : .none
    }
}
