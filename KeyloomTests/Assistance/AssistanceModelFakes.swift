import Foundation
import os
import XCTest
@testable import Keyloom

/// Test side of one pending model response: the test decides when, and with what, the model answers.
/// It deliberately ignores task cancellation (the worst case: a model that finishes late regardless).
actor ResponseGate {
    private var waiting: [CheckedContinuation<String, any Error>] = []
    private var arrived = 0
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func respond() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            arrived += 1
            let ready = arrivalWaiters.filter { $0.count <= arrived }
            arrivalWaiters.removeAll { $0.count <= arrived }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func waitForRequests(_ count: Int = 1) async {
        if arrived >= count { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func release(_ text: String) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: text)
    }
}

/// Fake of the language-model boundary. Counts sessions, calls and live sessions, and keeps what the model
/// was sent so tests can assert what did and did not reach it.
final class FakeModelFactory: AssistanceModelSessionFactory, Sendable {
    enum Behavior: Sendable {
        case reply(String)
        case gated
        case fail(any Error)
    }

    private struct State {
        var behavior: Behavior
        var created = 0
        var responded = 0
        var live = 0
        var returnedCancelled: [Bool] = []
        var instructions: [String] = []
        var prompts: [String] = []
        var failCreation = false
    }

    private let state: OSAllocatedUnfairLock<State>
    let gate = ResponseGate()

    init(_ behavior: Behavior = .reply("")) { state = OSAllocatedUnfairLock(initialState: State(behavior: behavior)) }

    var behavior: Behavior {
        get { state.withLock { $0.behavior } }
        set { state.withLock { $0.behavior = newValue } }
    }

    var failCreation: Bool {
        get { state.withLock { $0.failCreation } }
        set { state.withLock { $0.failCreation = newValue } }
    }

    var created: Int { state.withLock { $0.created } }
    var responded: Int { state.withLock { $0.responded } }
    var live: Int { state.withLock { $0.live } }
    var instructions: [String] { state.withLock { $0.instructions } }
    var prompts: [String] { state.withLock { $0.prompts } }
    /// For each response that came back: whether the task running it had been cancelled by then.
    var returnedCancelled: [Bool] { state.withLock { $0.returnedCancelled } }

    func makeSession(instructions: String) throws -> any AssistanceModelSession {
        try state.withLock { state in
            if state.failCreation { throw ModelSessionError(failure: .other) }
            state.created += 1
            state.live += 1
            state.instructions.append(instructions)
        }
        return FakeSession(owner: self)
    }

    fileprivate func respond(to prompt: String) async throws -> String {
        let behavior = state.withLock { state -> Behavior in
            state.responded += 1
            state.prompts.append(prompt)
            return state.behavior
        }
        switch behavior {
        case .reply(let text):
            return text
        case .fail(let error):
            throw error
        case .gated:
            let text = try await gate.respond()
            state.withLock { $0.returnedCancelled.append(Task.isCancelled) }
            return text
        }
    }

    fileprivate func sessionReleased() { state.withLock { $0.live -= 1 } }
}

private final class FakeSession: AssistanceModelSession {
    private let owner: FakeModelFactory
    init(owner: FakeModelFactory) { self.owner = owner }
    deinit { owner.sessionReleased() }
    func respond(to prompt: String) async throws -> String { try await owner.respond(to: prompt) }
}

/// Mutable policy source for the service, standing in for `WritingAssistancePolicy`.
final class PolicyBox: Sendable {
    private let state: OSAllocatedUnfairLock<PolicySnapshot>

    init(_ snapshot: PolicySnapshot = PolicyBox.ready) { state = OSAllocatedUnfairLock(initialState: snapshot) }

    static let ready = PolicySnapshot(assistanceOptIn: true, writingToolsOptIn: false, managed: .notManaged,
                                      modelAvailability: .available)
    static let off = PolicySnapshot(assistanceOptIn: false, writingToolsOptIn: false, managed: .notManaged,
                                    modelAvailability: nil)

    var snapshot: PolicySnapshot {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    var source: @Sendable () async -> PolicySnapshot { { [self] in snapshot } }
}

/// Waits on a condition by yielding, never by sleeping; fails after a bounded number of turns.
func eventually(_ message: String = "condition", file: StaticString = #filePath, line: UInt = #line,
                _ condition: @Sendable () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("timed out waiting for \(message)", file: file, line: line)
}
