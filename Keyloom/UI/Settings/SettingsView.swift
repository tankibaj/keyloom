import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Settings scene (Command-comma): four tabs, each a grouped form of system controls.
struct SettingsView: View {
    let settings: SettingsModels?
    /// Why the launch-time daily snapshot failed, if it did.
    var snapshotError: String?

    /// Roomy by default, resizable down to a size where every tab still reads without clipping.
    static let defaultSize = CGSize(width: 720, height: 560)
    static let minimumSize = CGSize(width: 640, height: 480)

    var body: some View {
        if let settings {
            TabView {
                Tab("General", systemImage: "gearshape") {
                    GeneralSettingsView(appearance: settings.appearance, shortcut: settings.shortcut, startup: settings.startup)
                }
                Tab("Expansion", systemImage: "keyboard") {
                    ExpansionSettingsView(model: settings.expansion)
                }
                Tab("Sync", systemImage: "icloud") {
                    SyncBackupsSettingsView(sync: settings.sync, backups: settings.backups, snapshotError: snapshotError)
                }
                Tab("Assistance", systemImage: "wand.and.stars") {
                    WritingAssistanceSettingsView(model: settings.assistance)
                }
            }
            .frame(minWidth: Self.minimumSize.width, idealWidth: Self.defaultSize.width,
                   minHeight: Self.minimumSize.height, idealHeight: Self.defaultSize.height)
            .background(ResizableWindow(minimum: Self.minimumSize))
        } else {
            ProgressView("Starting…").padding(40).frame(width: Self.defaultSize.width)
        }
    }
}

/// SwiftUI builds the Settings window without the resizable style, whatever the scene's resizability says. This
/// adds it back, with the content's minimum size, once the view is in its window.
private struct ResizableWindow: NSViewRepresentable {
    let minimum: CGSize

    func makeNSView(context: Context) -> NSView { Probe(minimum: minimum) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let minimum: CGSize
        private var observer: (any NSObjectProtocol)?

        init(minimum: CGSize) {
            self.minimum = minimum
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            // SwiftUI configures the window after the view arrives and again when it becomes key: apply on both.
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = minimum
        }
    }
}

struct GeneralSettingsView: View {
    @Bindable var appearance: AppearanceSettings
    @Bindable var shortcut: ShortcutSettingsModel
    @Bindable var startup: StartupSettings
    @State private var recorder = KeyRecorder()

    /// The app's fixed commands, taught here as well as in the menus.
    static let appShortcuts: [(title: String, keys: String)] = [
        ("Open Library", "⌘L"), ("New Snippet", "⌘N"), ("Settings", "⌘,"), ("Quit Keyloom", "⌘Q"),
    ]

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
                LabeledContent("Open Picker") { shortcutField }
                if let message = shortcut.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .accessibilityIdentifier("settings.general.shortcutMessage")
                }
                LabeledContent {
                    Button("Reset") { shortcut.reset() }
                        .accessibilityLabel("Reset picker shortcut to Control-Option-Space")
                        .accessibilityIdentifier("settings.general.shortcutReset")
                } label: {
                    Text("Click the field, then press the new combination. Esc cancels.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Startup") {
                Toggle("Open Keyloom at login", isOn: $startup.opensAtLogin)
                    .accessibilityIdentifier("settings.general.openAtLogin")
                if startup.needsApproval {
                    Text("Allow Keyloom under System Settings > General > Login Items.")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.general.loginApproval")
                }
                if let error = startup.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        .accessibilityIdentifier("settings.general.loginError")
                }
                Toggle("Show in menu bar", isOn: $startup.showInMenuBar)
                    .accessibilityIdentifier("settings.general.showInMenuBar")
            }
            Section("Keyboard Shortcuts") {
                ForEach(Self.appShortcuts, id: \.title) { item in
                    LabeledContent(item.title) { SettingsKeycap(text: item.keys) }
                        .accessibilityElement(children: .combine)
                }
                Text("In the menu bar panel, ⌘1 to ⌘9 insert the numbered snippet.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: shortcut.isRecording) { _, recording in
            if recording { recorder.start { shortcut.handleKey(keyCode: $0, modifiers: $1) } } else { recorder.stop() }
        }
        .onAppear { startup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in startup.refresh() }
        .onDisappear {
            shortcut.cancelRecording()
            recorder.stop()
        }
    }

    /// The shortcut as keycaps in a field. The field records; the ✕ (while recording) cancels. There is no "no
    /// shortcut" state: the picker always has one, so Reset is the way back to the default.
    private var shortcutField: some View {
        HStack(spacing: 4) {
            Button {
                if shortcut.isRecording { shortcut.cancelRecording() } else { shortcut.beginRecording() }
            } label: {
                HStack(spacing: 4) {
                    if shortcut.isRecording {
                        Text("Type the shortcut…").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(ShortcutDisplay.keys(for: shortcut.current).enumerated()), id: \.offset) { SettingsKeycap(text: $1) }
                    }
                }
                .frame(minWidth: 120, minHeight: 24, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Picker shortcut")
            .accessibilityValue(shortcut.isRecording ? "Recording" : shortcut.display)
            .accessibilityHint("Activate, then press the new key combination. Escape cancels.")
            .accessibilityIdentifier("settings.general.shortcut")
            if shortcut.isRecording {
                Button("Cancel", systemImage: "xmark.circle.fill") { shortcut.cancelRecording() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel recording")
                    .accessibilityIdentifier("settings.general.shortcutCancel")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(shortcut.isRecording ? Color.accentColor : .clear, lineWidth: 2))
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

/// A keyboard shortcut or keyword as a small monospaced chip.
struct SettingsKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 5))
    }
}

struct ExpansionSettingsView: View {
    @Bindable var model: ExpansionSettingsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Permission") {
                ForEach(model.permissionRows) { row in
                    LabeledContent {
                        Text(row.isGranted ? "Granted" : "Not granted")
                            .font(.caption)
                            .foregroundStyle(row.isGranted ? Color.green : Color.orange)
                            .padding(.horizontal, 9).padding(.vertical, 2)
                            .background((row.isGranted ? Color.green : Color.orange).opacity(0.16), in: .capsule)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "circle.fill").font(.system(size: 10))
                                .foregroundStyle(row.isGranted ? Color.green : Color.orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                Text(row.detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.expansion.permission.\(row.id.lowercased())")
                }
                LabeledContent {
                    HStack {
                        if model.needsPermission {
                            Button("Request Access…") { model.requestPermissions() }
                                .accessibilityIdentifier("settings.expansion.request")
                        }
                        Button("Open System Settings…") { openURL(ExpansionSettingsModel.accessibilitySettingsURL) }
                            .accessibilityIdentifier("settings.expansion.openSystemSettings")
                    }
                } label: {
                    Text("Missing after an update? Open Privacy & Security and re-enable Keyloom.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let note = model.secureInputNote {
                    Label(note, systemImage: "lock.fill").font(.callout)
                        .accessibilityIdentifier("settings.expansion.secureInput")
                }
            }
            Section("Behavior") {
                Toggle(isOn: $model.expandsInUninspectableApps) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Expand in browsers, Electron and terminals")
                        Text("Types over the field (delete keyword, paste). Never in secure fields, excluded apps or Finder.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings.expansion.uninspectable")
            }
            Section {
                if model.excludedApps.isEmpty {
                    Text("No apps are excluded.").foregroundStyle(.secondary)
                }
                ForEach(model.excludedApps) { app in
                    LabeledContent {
                        Button("Stop Excluding", systemImage: "minus.circle") { model.include(bundleID: app.bundleID) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Stop excluding \(app.name)")
                            .accessibilityIdentifier("settings.expansion.include.\(app.bundleID)")
                    } label: {
                        Label { Text(app.name) } icon: {
                            Image(nsImage: Self.icon(for: app.bundleID)).resizable().frame(width: 24, height: 24)
                        }
                    }
                }
                Button("Add App…", systemImage: "plus") { chooseApplication { model.exclude(applicationAt: $0) } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("settings.expansion.addApp")
            } header: {
                Text("Excluded Apps")
            } footer: {
                Text("Keyloom’s own windows and secure-input fields are always left alone.")
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

    /// The app's own icon, or the generic application icon when it is not installed.
    private static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
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
