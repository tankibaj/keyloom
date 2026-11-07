import AppKit
import SwiftUI

/// The Settings scene (Command-comma): four tabs, each a grouped form of system controls.
struct SettingsView: View {
    let settings: SettingsModels?
    /// Why the launch-time daily snapshot failed, if it did.
    var snapshotError: String?

    var body: some View {
        if let settings {
            TabView {
                Tab("General", systemImage: "gearshape") {
                    GeneralSettingsView(appearance: settings.appearance, shortcut: settings.shortcut)
                }
                Tab("Expansion", systemImage: "keyboard") {
                    ExpansionSettingsView(model: settings.expansion)
                }
                Tab("Sync & Backups", systemImage: "icloud") {
                    SyncBackupsSettingsView(sync: settings.sync, backups: settings.backups, snapshotError: snapshotError)
                }
                Tab("Writing Assistance", systemImage: "wand.and.stars") {
                    WritingAssistanceSettingsView(model: settings.assistance)
                }
            }
            .frame(width: 560)
        } else {
            ProgressView("Starting…").padding(40).frame(width: 560)
        }
    }
}

struct GeneralSettingsView: View {
    @Bindable var appearance: AppearanceSettings
    @Bindable var shortcut: ShortcutSettingsModel
    @State private var recorder = KeyRecorder()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance.preference) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.general.appearance")
                Text("Auto follows the appearance you chose in macOS.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Quick Picker") {
                LabeledContent("Shortcut") {
                    Button(shortcut.isRecording ? "Type the shortcut…" : shortcut.display) {
                        if shortcut.isRecording { shortcut.cancelRecording() } else { shortcut.beginRecording() }
                    }
                    .accessibilityLabel("Picker shortcut")
                    .accessibilityValue(shortcut.isRecording ? "Recording" : shortcut.display)
                    .accessibilityHint("Activate, then press the new key combination. Escape cancels.")
                    .accessibilityIdentifier("settings.general.shortcut")
                }
                if let message = shortcut.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .accessibilityIdentifier("settings.general.shortcutMessage")
                }
                Button("Reset to Control-Option-Space") { shortcut.reset() }
                    .accessibilityIdentifier("settings.general.shortcutReset")
            }
        }
        .formStyle(.grouped)
        .onChange(of: shortcut.isRecording) { _, recording in
            if recording { recorder.start { shortcut.handleKey(keyCode: $0, modifiers: $1) } } else { recorder.stop() }
        }
        .onDisappear {
            shortcut.cancelRecording()
            recorder.stop()
        }
    }
}

/// Feeds key presses to the shortcut recorder while it is recording, and swallows the ones it takes.
@MainActor
final class KeyRecorder {
    private var monitor: Any?

    func start(_ handle: @escaping @MainActor (UInt32, NSEvent.ModifierFlags) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { handle(UInt32(event.keyCode), event.modifierFlags) }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ExpansionSettingsView: View {
    @Bindable var model: ExpansionSettingsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Toggle("Pause expansion", isOn: $model.isPaused)
                    .accessibilityIdentifier("settings.expansion.pause")
                Text("While paused, typing a keyword does nothing. The picker still works.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                ForEach(model.permissionRows) { row in
                    LabeledContent {
                        Label(row.isGranted ? "Granted" : (row.isRequired ? "Not granted" : "Not granted (optional)"),
                              systemImage: row.isGranted ? "checkmark.circle.fill" : "xmark.circle")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            Text(row.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.expansion.permission.\(row.kind)")
                }
                if model.needsPermission {
                    Button("Request Access…") { model.requestPermissions() }
                        .accessibilityIdentifier("settings.expansion.request")
                    Button("Open Privacy & Security Settings") { openURL(ExpansionSettingsModel.systemSettingsURL(for: .accessibility)) }
                        .accessibilityIdentifier("settings.expansion.openSystemSettings")
                }
                if let note = model.secureInputNote {
                    Label(note, systemImage: "lock.fill").font(.callout)
                        .accessibilityIdentifier("settings.expansion.secureInput")
                }
            }
            Section("Excluded Apps") {
                if model.excludedApps.isEmpty {
                    Text("No apps are excluded. Keyloom’s own windows are always left alone.").foregroundStyle(.secondary)
                }
                ForEach(model.excludedApps) { app in
                    LabeledContent(app.name) {
                        Button("Stop Excluding", systemImage: "minus.circle") { model.include(bundleID: app.bundleID) }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Stop excluding \(app.name)")
                            .accessibilityIdentifier("settings.expansion.include.\(app.bundleID)")
                    }
                }
                Button("Add App…") { chooseApplication { model.exclude(applicationAt: $0) } }
                    .accessibilityIdentifier("settings.expansion.addApp")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .alert("Couldn’t Add That App", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func chooseApplication(_ choose: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { choose(url) }
        }
    }
}
