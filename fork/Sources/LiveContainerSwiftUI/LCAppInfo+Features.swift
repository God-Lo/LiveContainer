//
//  LCAppInfo+Features.swift
//  LiveContainer (fork)
//
//  Per-app switches under App Extensions in the app's settings, stored with the app (so they go away
//  when the app is deleted). All off by default. Changing one rebuilds LiveContainer through the
//  built-in SideStore (LCSelfUpdate).
//

import Foundation

extension LCAppInfo {
    private static let shortcutsKey = "LCShortcutsEnabled"
    private static let extensionsKey = "LCExtensionsEnabled"

    /// Whether this app's Shortcuts actions are added to LiveContainer.
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

    /// Extension points of this app's extensions that LiveContainer can run.
    var supportedExtensionPoints: [String] {
        // Files works for every app: LiveContainer's File Provider runs the app's own, or shows its Documents.
        var points = LCGuestExtensionBuilder.supportedPoints(inBundle: bundlePath())
        if !points.contains(LCForkFiles.fileProviderPoint) { points.append(LCForkFiles.fileProviderPoint) }
        return points
    }

    /// Extension points turned on for this app.
    var enabledExtensionPoints: Set<String> {
        get { Set((info()[LCAppInfo.extensionsKey] as? [String: Bool] ?? [:]).filter(\.value).map(\.key)) }
        set {
            info()[LCAppInfo.extensionsKey] = Dictionary(uniqueKeysWithValues: newValue.map { ($0, true) })
            save()
        }
    }

    func isExtensionEnabled(_ point: String) -> Bool { enabledExtensionPoints.contains(point) }

    func setExtension(_ point: String, enabled: Bool) {
        var points = enabledExtensionPoints
        if enabled { points.insert(point) } else { points.remove(point) }
        enabledExtensionPoints = points
    }

    /// Anything turned on that needs LiveContainer rebuilt.
    var hasFeaturesEnabled: Bool { shortcutsEnabled || !enabledExtensionPoints.isEmpty }
}
