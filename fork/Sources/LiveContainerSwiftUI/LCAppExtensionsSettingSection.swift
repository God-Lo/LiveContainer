//
//  LCAppExtensionsSettingSection.swift
//  LiveContainer (fork)
//
//  "App Extensions" in an app's settings: one switch per feature LiveContainer can add for the app
//  (its Shortcuts actions and each kind of extension it has). Grayed out: the app doesn't have it. All
//  off by default. Apply Changes rebuilds LiveContainer once through the built-in SideStore (LCSelfUpdate).
//  iMessage and SMS Filter work for one app at a time; turning one on here turns it off for the
//  previous app (also selectable in LiveContainer's Settings, LCSingleAppExtensionsSection).
//

import SwiftUI

/// Turns a kind on for one app, and off for the others if iOS allows only one.
enum LCAppExtensionSwitch {
    static func set(_ point: String, enabled: Bool, for app: LCAppInfo, apply: Bool = true) {
        if enabled && LCGuestExtensionBuilder.isSingleAppPoint(point) {
            let model = DataManager.shared.model
            for other in (model.apps + model.hiddenApps).map(\.appInfo) where other !== app && other.isExtensionEnabled(point) {
                other.setExtension(point, enabled: false)
            }
        }
        app.setExtension(point, enabled: enabled)
        if apply { LCSelfUpdate.applySettingChange() }
    }
}

struct LCAppExtensionsSettingSection: View {
    let appInfo: LCAppInfo
    private let available: Set<String>
    private let hasShortcuts: Bool
    private let isPrimary = LCGuestIntentsIndexer.isPrimaryLiveContainer
    @State private var shortcutsOn: Bool
    @State private var enabled: Set<String>
    @State private var changed = false

    init(appInfo: LCAppInfo) {
        self.appInfo = appInfo
        available = Set(appInfo.supportedExtensionPoints)
        hasShortcuts = appInfo.hasShortcutsActions
        _shortcutsOn = State(initialValue: appInfo.shortcutsEnabled)
        _enabled = State(initialValue: appInfo.enabledExtensionPoints)
    }

    /// What the Files app last saw for this app's location.
    private var filesStatus: String {
        guard enabled.contains(LCForkFiles.fileProviderPoint), let folder = appInfo.relativeBundlePath,
              let status = LCForkFiles.status(folder: folder) else { return "" }
        return "\n\nFiles: " + status + "."
    }

    private func binding(_ point: String) -> Binding<Bool> {
        guard available.contains(point) else { return .constant(false) }
        return Binding(get: { enabled.contains(point) }, set: { on in
            if on { enabled.insert(point) } else { enabled.remove(point) }
            LCAppExtensionSwitch.set(point, enabled: on, for: appInfo, apply: false)
            changed = true
        })
    }

    var body: some View {
        Section {
            Toggle("Shortcuts", isOn: hasShortcuts ? $shortcutsOn : .constant(false))
                .disabled(!hasShortcuts || !isPrimary)
                .onChange(of: shortcutsOn) { newValue in
                    guard newValue != appInfo.shortcutsEnabled else { return }
                    appInfo.shortcutsEnabled = newValue
                    changed = true
                }
            ForEach(LCGuestExtensionBuilder.allPoints(), id: \.self) { point in
                Toggle(LCGuestExtensionBuilder.displayName(forPoint: point), isOn: binding(point))
                    .disabled(!available.contains(point) || !isPrimary)
            }
            if changed {
                Button("Apply Changes") {
                    changed = false
                    LCSelfUpdate.applySettingChange()
                }
            }
        } header: {
            Text("App Extensions")
        } footer: {
            Text(isPrimary
                 ? "Choose what this app adds to LiveContainer. Grayed out: the app doesn't have it. Apply Changes reinstalls LiveContainer; your data stays. Files gives this app a location in the Files app, served by its own File Provider or showing its Documents. iMessage, SMS Filter and Background Events work for one app at a time." + filesStatus
                 : "Change these in the main LiveContainer.")
        }
    }
}

/// In LiveContainer's Settings: which app uses each kind that works for one app at a time.
struct LCSingleAppExtensionsSection: View {
    @State private var refresh = 0

    private var lastBackgroundStart: String {
        guard let date = LCForkBackground.lastStart else { return "" }
        return "\n\nLast started in the background: " + date.formatted(date: .abbreviated, time: .shortened) + "."
    }

    private var apps: [LCAppInfo] {
        let model = DataManager.shared.model
        return (model.apps + model.hiddenApps).map(\.appInfo)
    }

    private func selection(_ point: String) -> Binding<String> {
        Binding(get: {
            _ = refresh
            return apps.first { $0.isExtensionEnabled(point) }?.relativeBundlePath ?? ""
        }, set: { folder in
            if let app = apps.first(where: { $0.relativeBundlePath == folder }) {
                LCAppExtensionSwitch.set(point, enabled: true, for: app)
            } else if let current = apps.first(where: { $0.isExtensionEnabled(point) }) {
                LCAppExtensionSwitch.set(point, enabled: false, for: current)
            }
            refresh += 1
        })
    }

    var body: some View {
        if LCGuestIntentsIndexer.isPrimaryLiveContainer {
            Section {
                ForEach(LCGuestExtensionBuilder.allPoints().filter { LCGuestExtensionBuilder.isSingleAppPoint($0) }, id: \.self) { point in
                    let candidates = apps.filter { $0.supportedExtensionPoints.contains(point) }
                    Picker(LCGuestExtensionBuilder.displayName(forPoint: point), selection: selection(point)) {
                        Text("None").tag("")
                        ForEach(candidates, id: \.relativeBundlePath) { app in
                            Text(app.displayName() ?? "App").tag(app.relativeBundlePath ?? "")
                        }
                    }
                    .disabled(candidates.isEmpty)
                }
            } header: {
                Text("App Extensions")
            } footer: {
                Text("iOS allows one app at a time for these. Grayed out: none of your apps has it. Background Events: iOS wakes LiveContainer for Bluetooth, accessories, location and background tasks, and LiveContainer starts this app without showing it, so the app updates its widgets and controls as it would on its own." + lastBackgroundStart)
            }
        }
    }
}
