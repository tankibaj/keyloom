import AppKit
import Combine
import SwiftUI

/// Synthetic fixture values; the live run instructions in docs/spike use the same ones.
enum Fixtures {
    static let documentText = "KL-FIXTURE-v1\nSTART  END"
    static let defaultRecipient = "Alex Fixture"
    static let scenario = """
    1. Click "Copy fixture document", open a NEW TextEdit / Safari textarea / VS Code document, paste.
    2. Put the caret between the two spaces (press Left 4 times; the document is ASCII-only).
    3. Arm the probe, return to the document and type  ;kl  on the keyboard.
    Expected (AX plain): START Hallo 👩🏽‍💻 Keyloom! END, caret before "!" (UTF-16 offset 41).
    Typing  ;hi  asks for a recipient; default gives "Hi Alex Fixture!". Cancel leaves  ;hi  untouched.
    """
}

@main
struct KeyloomProbeApp: App {
    @StateObject private var model = ProbeModel()

    var body: some Scene {
        WindowGroup("Keyloom Probe (WP1 feasibility, not the product)") {
            ProbeView(model: model)
                .frame(minWidth: 560, minHeight: 640)
        }
    }
}

final class ProbeModel: ObservableObject {
    @Published var permissions = PermissionStatus.current()
    @Published var armed = false
    @Published var acceptSynthetic = false { didSet { engine.acceptSynthetic = acceptSynthetic } }
    @Published var mode: DeliveryMode = .axPlain { didSet { engine.deliveryMode = mode } }
    @Published var counters = Counters()
    @Published var log: [String] = []
    @Published var status = "Disarmed"
    @Published var containerID = ""
    @Published var cloudStatus = "Not run. Live CloudKit is opt-in and needs a signed test container."
    @Published var cloudRunning = false

    private let engine = ProbeEngine(
        destination: AXDestination(),
        pasteboard: SystemPasteboard(),
        environment: SystemEnvironment(),
        allowedBundleIDs: AXDestination.allowedBundleIDs
    )
    private let tap = EventTap()

    init() {
        tap.onEvent = { [weak self] event in
            guard let self else { return }
            engine.handle(event)
            counters = engine.counters
        }
        engine.onPrompt = { [weak self] insertion in self?.showPrompt(insertion) }
        engine.onOutcome = { [weak self] outcome in self?.record(outcome) }
    }

    func refresh() {
        permissions = PermissionStatus.current()
        if armed && !permissions.allGranted { setArmed(false, reason: "Permission revoked") }
    }

    func requestPermissions() {
        PermissionStatus.request()
        refresh()
    }

    func setArmed(_ on: Bool, reason: String? = nil) {
        if on {
            refresh()
            guard permissions.allGranted else {
                status = "Cannot arm: grant Accessibility and Input Monitoring first"
                armed = false
                return
            }
            guard tap.start() else {
                status = "Cannot arm: event tap could not be created"
                armed = false
                return
            }
            engine.armed = true
            armed = true
            status = "Armed: fixture documents in TextEdit, Safari and VS Code only"
        } else {
            tap.stop()
            engine.armed = false
            armed = false
            status = reason ?? "Disarmed"
        }
    }

    func copyFixtureDocument() { copyToClipboard(Fixtures.documentText) }

    func copyFallbackOfLastTrigger() { engine.copyFallback(argument: nil) }

    func copyReport() { copyToClipboard(reportText()) }

    func runCloudProbe() {
        if let blocker = CloudProvisioning.blocker(containerID: containerID) {
            cloudStatus = "NOT VERIFIED: \(blocker)"
            return
        }
        cloudRunning = true
        cloudStatus = "Running against the supplied container..."
        let identifier = containerID
        Task { [self] in
            let report = await CloudProbeRunner(
                store: CloudKitRecordStore(containerIdentifier: identifier)
            ).run()
            await MainActor.run {
                cloudRunning = false
                cloudStatus = (report.passed ? "PASS: " : "FAILED: ")
                    + report.steps.map { "\($0.name)=\($0.ok ? "ok" : "fail")\($0.detail.isEmpty ? "" : " (\($0.detail))")" }
                        .joined(separator: ", ")
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func record(_ outcome: Outcome) {
        counters = engine.counters
        let time = ISO8601DateFormatter().string(from: Date())
        log.insert("\(time) \(outcome) | physical=\(counters.physical) synthetic=\(counters.synthetic)", at: 0)
    }

    private func showPrompt(_ insertion: PendingInsertion) {
        DispatchQueue.main.async { [self] in
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Recipient"
            alert.informativeText = "Fixture prompt. Leave empty for the default (\(Fixtures.defaultRecipient))."
            let field = NSTextField(string: Fixtures.defaultRecipient)
            field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            alert.accessoryView = field
            // Without a safe writer for this mode, Insert is not offered: Copy is the way out.
            let canInsert = engine.canInsert
            if canInsert { alert.addButton(withTitle: "Insert") }
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Copy")
            let button = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            switch canInsert ? button : button + 1 {
            case 0: engine.confirm(argument: field.stringValue)
            case 2: engine.copyFallback(argument: field.stringValue)
            default: engine.cancel()
            }
        }
    }

    func reportText() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let lines = [
            "Keyloom probe report (outcomes only, no typed text)",
            "OS: \(os), arch: arm64",
            "Permissions: accessibility=\(permissions.accessibility) inputMonitoring=\(permissions.inputMonitoring)",
            "Delivery mode: \(mode.rawValue); accept synthetic input: \(acceptSynthetic)",
            "Counters: \(counters)",
            "Physical input evidence: \(counters.physical > 0 ? "yes" : "NO")",
            "Rich insertion: NOT VERIFIED / unsupported (no field-bound styled writer via Accessibility; the probe sends no paste keystroke and never writes the clipboard on its own). Use Copy (plain + RTF).",
        ]
        return (lines + log).joined(separator: "\n")
    }
}

struct ProbeView: View {
    @ObservedObject var model: ProbeModel
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Permissions (required to arm)") {
                VStack(alignment: .leading) {
                    row("Accessibility", model.permissions.accessibility)
                    row("Input Monitoring", model.permissions.inputMonitoring)
                    Button("Request missing permissions") { model.requestPermissions() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Run") {
                VStack(alignment: .leading) {
                    Toggle("Armed", isOn: Binding(get: { model.armed }, set: { model.setArmed($0) }))
                    Text(model.status).font(.callout)
                    Picker("Delivery", selection: $model.mode) {
                        ForEach(DeliveryMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Accept synthetic (automated) input, self-test only", isOn: $model.acceptSynthetic)
                    HStack {
                        Button("Copy fixture document") { model.copyFixtureDocument() }
                        Button("Copy fallback of last trigger") { model.copyFallbackOfLastTrigger() }
                        Button("Copy report") { model.copyReport() }
                    }
                    Text(Fixtures.scenario).font(.footnote).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Counters (no typed text is kept)") {
                Text(String(describing: model.counters)).font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Outcomes") {
                List(model.log, id: \.self) { Text($0).font(.system(.footnote, design: .monospaced)) }
                    .frame(minHeight: 100)
            }
            GroupBox("CloudKit (opt-in, disposable record)") {
                VStack(alignment: .leading) {
                    TextField("Test container identifier (iCloud.…)", text: $model.containerID)
                    Button("Run CloudKit probe") { model.runCloudProbe() }
                        .disabled(model.containerID.isEmpty || model.cloudRunning)
                    Text(model.cloudStatus).font(.footnote).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .onReceive(tick) { _ in model.refresh() }
    }

    private func row(_ name: String, _ granted: Bool) -> some View {
        Label(name + (granted ? ": granted" : ": missing"),
              systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
    }
}
