//
//  LCShortcutsSettingSection.swift
//  LiveContainer (fork)
//
//  Per-app "Shortcuts" switch in the app's settings. Off by default. Turning it on or off rebuilds
//  LiveContainer with that app's Shortcuts actions added or removed, and the built-in SideStore
//  reinstalls it (see LCShortcutsSelfUpdate).
//

import SwiftUI

extension LCAppInfo {
    private static let shortcutsKey = "LCShortcutsEnabled"

    /// Whether this app's Shortcuts actions are registered under LiveContainer. Off by default.
    var shortcutsEnabled: Bool {
        get { (info()[LCAppInfo.shortcutsKey] as? Bool) ?? false }
        set {
            info()[LCAppInfo.shortcutsKey] = newValue
            save()
        }
    }

    /// Whether the app ships any App Intents actions at all.
    var hasShortcutsActions: Bool {
        !LCGuestIntentsIndexer.metadataFolders(in: URL(fileURLWithPath: bundlePath())).isEmpty
    }
}

struct LCShortcutsSettingSection: View {
    let appInfo: LCAppInfo
    @State private var enabled: Bool
    private let hasActions: Bool
    private let isPrimary = LCGuestIntentsIndexer.isPrimaryLiveContainer

    init(appInfo: LCAppInfo) {
        self.appInfo = appInfo
        _enabled = State(initialValue: appInfo.shortcutsEnabled)
        hasActions = appInfo.hasShortcutsActions
    }

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Text("Shortcuts")
            }
            .disabled(!hasActions || !isPrimary)
            .onChange(of: enabled) { newValue in
                guard newValue != appInfo.shortcutsEnabled else { return }
                appInfo.shortcutsEnabled = newValue
                LCShortcutsSelfUpdate.applySettingChange()
            }
        } footer: {
            if !isPrimary {
                Text("Manage Shortcuts in the primary LiveContainer.")
            } else if hasActions {
                Text("Show this app's actions in the Shortcuts app, in their own section under LiveContainer. Changing this reinstalls LiveContainer through the built-in SideStore; your data is kept.")
            } else {
                Text("This app has no Shortcuts actions.")
            }
        }
    }
}
