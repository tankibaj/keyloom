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
