import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Thin real adapter over the OS model-availability query. It maps what macOS exposes and nothing more.
/// COMPILE-ONLY: it cannot be exercised here (NOT VERIFIED on a real Apple Intelligence Mac).
/// Only `SystemLanguageModel.default`, the on-device model, is ever consulted.
struct SystemModelAvailabilityProvider: ModelAvailabilityProvider {
    func availability(for locale: Locale) -> ModelAvailability {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? .available : .unsupportedLanguage
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            return .downloading
        case .unavailable:
            return .unavailable(.unspecified)
        }
        #else
        return .unavailable(.unspecified)
        #endif
    }
}

/// Thin real adapter over the on-device language model; only `SystemLanguageModel.default` is used, never a
/// cloud model. COMPILE-ONLY: it cannot be exercised here (NOT VERIFIED on a real Apple Intelligence Mac).
/// It never calls anything that prompts the user or starts a setup flow.
struct SystemModelSessionFactory: AssistanceModelSessionFactory {
    func makeSession(instructions: String) throws -> any AssistanceModelSession {
        #if canImport(FoundationModels)
        SystemModelSession(LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions))
        #else
        throw ModelSessionError(failure: .other)
        #endif
    }
}

#if canImport(FoundationModels)
private final class SystemModelSession: AssistanceModelSession, @unchecked Sendable {
    private let session: LanguageModelSession

    init(_ session: LanguageModelSession) { self.session = session }

    func respond(to prompt: String) async throws -> String {
        do {
            return try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2)).content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ModelSessionError(failure: Self.failure(of: error))
        }
    }

    /// Only the macOS 27 error type is mapped; on macOS 26 every failure is `.other`.
    private static func failure(of error: any Error) -> ModelFailure {
        guard #available(macOS 27.0, *), let error = error as? LanguageModelError else { return .other }
        switch error {
        case .contextSizeExceeded: return .contextTooLarge
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        case .guardrailViolation, .refusal: return .refused
        default: return .other
        }
    }
}
#endif
