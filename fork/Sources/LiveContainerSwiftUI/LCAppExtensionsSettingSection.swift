//
//  LCAppExtensionsSettingSection.swift
//  LiveContainer (fork)
//
//  "App Extensions" in an app's settings: one switch per feature LiveContainer can run for the app
//  (Shortcuts and the app's extensions). Features the app doesn't have are grayed out.
//  - Shortcuts: off by default; changing it reinstalls LiveContainer (LCShortcutsSelfUpdate).
//  - Keyboard, Screen Broadcast, SMS Filter: off by default, they can see private data.
//  - Widgets: one app at a time; turning it on here turns it off for the previous app.
//  - Everything else: on by default.
//

import SwiftUI
import WidgetKit

struct LCAppExtensionsSettingSection: View {
    let appInfo: LCAppInfo
    private let folder: String
    private let available: Set<String>
    private let hasShortcuts: Bool
    private let isPrimary = LCGuestIntentsIndexer.isPrimaryLiveContainer
    @State private var shortcutsOn: Bool
    @State private var allowed: [String: Bool] = [:]
    @State private var widgetsOn: Bool

    /// Display order: everyday features first, the ones that can see private data last.
    private static let points = ["com.apple.widgetkit-extension", "com.apple.share-services", "com.apple.ui-services",
                                 "com.apple.fileprovider-nonui", "com.apple.Safari.content-blocker",
                                 "com.apple.photo-editing", "com.apple.message-payload-provider",
                                 "com.apple.callkit.call-directory", "com.apple.keyboard-service",
                                 "com.apple.broadcast-services-upload", "com.apple.identitylookup.message-filter"]

    init(appInfo: LCAppInfo) {
        self.appInfo = appInfo
        let folder = appInfo.relativeBundlePath ?? ""
        self.folder = folder
        available = Set(LCGuestExtensionPreparer.supportedPoints(inBundle: appInfo.bundlePath() ?? ""))
        hasShortcuts = appInfo.hasShortcutsActions
        _shortcutsOn = State(initialValue: appInfo.shortcutsEnabled)
        _widgetsOn = State(initialValue: LCGuestExtensionPreparer.isWidgetAppFolder(folder)
                           && LCGuestExtensionPreparer.isAllowedPoint("com.apple.widgetkit-extension", folder: folder))
    }

    private func binding(_ point: String) -> Binding<Bool> {
        if point == "com.apple.widgetkit-extension" {
            return Binding(get: { widgetsOn }, set: { on in
                widgetsOn = on
                LCGuestExtensionPreparer.setAllowed(on, point: point, folder: folder)
                if on {
                    LCGuestExtensionPreparer.useWidgets(ofFolder: folder)
                } else if LCGuestExtensionPreparer.isWidgetAppFolder(folder) {
                    LCGuestExtensionPreparer.useWidgets(ofFolder: "")
                }
                WidgetCenter.shared.reloadAllTimelines()
            })
        }
        return Binding(
            get: { allowed[point] ?? LCGuestExtensionPreparer.isAllowedPoint(point, folder: folder) },
            set: {
                allowed[point] = $0
                LCGuestExtensionPreparer.setAllowed($0, point: point, folder: folder)
            })
    }

    var body: some View {
        Section {
            Toggle("Shortcuts", isOn: hasShortcuts ? $shortcutsOn : .constant(false))
                .disabled(!hasShortcuts || !isPrimary)
                .onChange(of: shortcutsOn) { newValue in
                    guard newValue != appInfo.shortcutsEnabled else { return }
                    appInfo.shortcutsEnabled = newValue
                    LCShortcutsSelfUpdate.applySettingChange()
                }
            ForEach(Self.points, id: \.self) { point in
                Toggle(LCGuestExtensionPreparer.displayName(forPoint: point),
                       isOn: available.contains(point) ? binding(point) : .constant(false))
                    .disabled(!available.contains(point) || !isPrimary)
            }
        } header: {
            Text("App Extensions")
        } footer: {
            Text(isPrimary
                 ? "Choose what this app can use. Grayed out: the app doesn't have it. Keyboard, Screen Broadcast and SMS Filter start off. Only one app's widgets show at a time. Changing Shortcuts reinstalls LiveContainer; your data stays."
                 : "Change these in the main LiveContainer.")
        }
    }
}
