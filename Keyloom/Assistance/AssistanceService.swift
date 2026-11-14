import Foundation

/// Process boundary: one on-device language-model session. A real adapter wraps FoundationModels.
protocol AssistanceModelSession: Sendable {
    func respond(to prompt: String) async throws -> String
}

/// Process boundary: creates sessions on demand. A session lives only while one request runs.
protocol AssistanceModelSessionFactory: Sendable {
    /// Throws `ModelSessionError`. Must not prompt the user or start any setup flow.
    func makeSession(instructions: String) throws -> any AssistanceModelSession
}

/// Runs explicit writing-assistance requests, one at a time, and owns the lifecycle of their results.
///
/// - Nothing here is reachable from typing, matching or search: the only way to the model is `propose`, and
///   `propose` first asks the policy, so with assistance off, managed off or the model not ready, no session
///   is created.
/// - A session is created per request and dropped when the reply (or failure) arrives. No retries.
/// - Every request, and the suggestion it produces, belongs to an epoch. `cancel`, `policyDidChange`,
///   `editorClosed`, a changed editor state and a newer request each end the epoch: the in-flight call
///   returns `AssistanceError.cancelled` at once, its task is cancelled, and a late reply from a model that
///   ignores cancellation is dropped. The policy is read again when the reply arrives, so a switch turned off
///   while the model was working also fences it.
/// - One suggestion is held until `apply`, `cancel` or any of the events above; `apply` re-checks the policy
///   and that the editor revision and selection still match, and hands it out once.
/// - Prompts, replies, clipboard values and arguments are never logged: this type has no logging and its
///   errors carry no text.
actor AssistanceService {
    private struct Basis {
        let revision: Int
        let selection: ValidatedUTF16Range
    }

    private struct InFlight {
        let epoch: Int
        let task: Task<Void, Never>
        let continuation: CheckedContinuation<String, any Error>
    }

    private let policy: @Sendable () async -> PolicySnapshot
    private let sessions: any AssistanceModelSessionFactory
    private let makeID: @Sendable () -> UUID
    private var epoch = 0
    private var basis: Basis?
    private var inFlight: InFlight?
    private var pending: ProposedEdit?

    /// `policy` supplies the current snapshot on every call (see `WritingAssistancePolicy.currentSnapshot`).
    init(policy: @escaping @Sendable () async -> PolicySnapshot, sessions: any AssistanceModelSessionFactory,
         makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.policy = policy
        self.sessions = sessions
        self.makeID = makeID
    }

    /// A request is running or a suggestion is waiting to be applied.
    var hasPendingWork: Bool { inFlight != nil || pending != nil }

    /// Proofread, shorten or change the tone of the selected prose. Supersedes any earlier request.
    func propose(_ request: EditRequest) async throws -> ProposedEdit {
        let before = await policy()
        guard before.permitsOnDeviceEdits else { throw AssistanceError.notPermitted(before.assistance) }
        let plan = try EditPlanner.plan(request)

        endEpoch()
        let mine = epoch
        basis = Basis(revision: request.revision, selection: request.selection)
        do {
            let reply = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = Task { [sessions] in
                        let result: Result<String, any Error>
                        do { result = .success(try await Self.generate(plan, with: sessions)) } catch { result = .failure(error) }
                        self.finish(epoch: mine, result)
                    }
                    inFlight = InFlight(epoch: mine, task: task, continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancel(epoch: mine) }
            }
            guard epoch == mine else { throw AssistanceError.cancelled }
            let after = await policy()
            guard epoch == mine else { throw AssistanceError.cancelled }
            guard after.permitsOnDeviceEdits else { throw AssistanceError.notPermitted(after.assistance) }
            let edit = try plan.proposal(from: reply, id: makeID())
            pending = edit
            return edit
        } catch {
            if epoch == mine { basis = nil }
            throw error
        }
    }

    /// Hands out the suggestion's payload once, if it is still the current one, assistance is still permitted
    /// and the editor is still at the revision and selection it was made for. Otherwise it is discarded.
    func apply(_ edit: ProposedEdit, currentRevision: Int, currentSelection: ValidatedUTF16Range) async throws -> ApplyPayload {
        guard pending?.id == edit.id else { throw AssistanceError.stale }
        let snapshot = await policy()
        guard pending?.id == edit.id else { throw AssistanceError.stale }
        guard snapshot.permitsOnDeviceEdits else {
            endEpoch()
            throw AssistanceError.notPermitted(snapshot.assistance)
        }
        guard edit.baseRevision == currentRevision, edit.originalSelection == currentSelection else {
            endEpoch()
            throw AssistanceError.stale
        }
        pending = nil
        basis = nil
        return edit.applyPayload
    }

    /// The user cancelled: stop any request and drop any unapplied suggestion.
    func cancel() { endEpoch() }

    /// Assistance was switched off, managed policy changed, or availability changed.
    func policyDidChange() { endEpoch() }

    /// The editor holding the selection closed.
    func editorClosed() { endEpoch() }

    /// The editor's revision or selection moved; work made for the old state is stale.
    func editorStateChanged(revision: Int, selection: ValidatedUTF16Range) {
        guard let basis, basis.revision != revision || basis.selection != selection else { return }
        endEpoch()
    }

    // MARK: Internals

    private nonisolated static func generate(_ plan: EditPlan, with sessions: any AssistanceModelSessionFactory) async throws -> String {
        let session = try sessions.makeSession(instructions: plan.instructions)
        return try await session.respond(to: plan.prompt)
    }

    private func finish(epoch finished: Int, _ result: Result<String, any Error>) {
        guard let flight = inFlight, flight.epoch == finished else { return }
        inFlight = nil
        flight.continuation.resume(with: result.mapError(Self.assistanceError))
    }

    private func cancel(epoch cancelled: Int) {
        if epoch == cancelled { endEpoch() }
    }

    /// Cancels the running request (its caller gets `.cancelled` now), drops the suggestion, fences old replies.
    private func endEpoch() {
        epoch += 1
        pending = nil
        basis = nil
        guard let flight = inFlight else { return }
        inFlight = nil
        flight.task.cancel()
        flight.continuation.resume(throwing: AssistanceError.cancelled)
    }

    private static func assistanceError(_ error: any Error) -> AssistanceError {
        switch error {
        case let error as AssistanceError: error
        case let error as ModelSessionError: .modelFailed(error.failure)
        case is CancellationError: .cancelled
        default: .modelFailed(.other)
        }
    }
}

extension AssistanceService {
    /// Wires a service to the app's policy so a switch-off or managed change ends pending work.
    /// `sessions` defaults to the on-device system model.
    @MainActor
    static func make(policy: WritingAssistancePolicy,
                     sessions: any AssistanceModelSessionFactory = SystemModelSessionFactory()) -> AssistanceService {
        let service = AssistanceService(policy: { await policy.currentSnapshot() }, sessions: sessions)
        policy.attach(service)
        return service
    }
}
