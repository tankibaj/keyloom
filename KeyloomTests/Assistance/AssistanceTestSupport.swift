import Foundation
import os
@testable import Keyloom

/// Fake of the OS model-availability boundary; counts queries so tests can prove the OS was not asked.
final class FakeAvailability: ModelAvailabilityProvider, Sendable {
    private let state: OSAllocatedUnfairLock<(value: ModelAvailability, queries: Int)>

    init(_ value: ModelAvailability = .available) { state = OSAllocatedUnfairLock(initialState: (value, 0)) }

    var value: ModelAvailability {
        get { state.withLock { $0.value } }
        set { state.withLock { $0.value = newValue } }
    }

    var queries: Int { state.withLock { $0.queries } }

    func availability(for locale: Locale) -> ModelAvailability {
        state.withLock { $0.queries += 1; return $0.value }
    }
}

/// Fake of the managed-preferences boundary.
final class FakeManagedPolicy: ManagedPolicyReader, Sendable {
    private let state: OSAllocatedUnfairLock<ManagedAssistancePolicy>

    init(_ value: ManagedAssistancePolicy = .notManaged) { state = OSAllocatedUnfairLock(initialState: value) }

    var value: ManagedAssistancePolicy {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func read() -> ManagedAssistancePolicy { state.withLock { $0 } }
}

/// A throwaway per-test preference domain, so no test touches the real one.
func makeIsolatedDefaults() -> (defaults: UserDefaults, name: String) {
    let name = "keyloom.tests.assistance.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}
