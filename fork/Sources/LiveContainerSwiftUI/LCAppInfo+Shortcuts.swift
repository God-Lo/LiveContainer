//
//  LCAppInfo+Shortcuts.swift
//  LiveContainer (fork)
//
//  Per-app Shortcuts setting (the Shortcuts switch under App Extensions). Off by default. Turning it on
//  or off rebuilds LiveContainer with that app's Shortcuts actions added or removed, and the built-in
//  SideStore reinstalls it (see LCShortcutsSelfUpdate).
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
