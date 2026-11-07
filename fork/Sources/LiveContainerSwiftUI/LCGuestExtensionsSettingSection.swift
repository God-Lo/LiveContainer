//
//  LCGuestExtensionsSettingSection.swift
//  LiveContainer (fork)
//
//  "App Extensions" in an app's settings: the kinds of extensions the app has that LiveContainer runs.
//  Sensitive kinds (screen broadcast, keyboard, SMS filter) have a switch and are off until allowed.
//  Widgets: LiveContainer shows one app's widgets at a time; this picks which.
//

import SwiftUI
import WidgetKit

struct LCGuestExtensionsSettingSection: View {
    let appInfo: LCAppInfo
    private let points: [String]
    private let folder: String
    @State private var allowed: [String: Bool] = [:]
    @State private var widgetsHere: Bool

    init(appInfo: LCAppInfo) {
        self.appInfo = appInfo
        points = LCGuestExtensionPreparer.supportedPoints(inBundle: appInfo.bundlePath() ?? "")
        folder = appInfo.relativeBundlePath ?? ""
        _widgetsHere = State(initialValue: LCGuestExtensionPreparer.isWidgetAppFolder(appInfo.relativeBundlePath ?? ""))
    }

    private func binding(_ point: String) -> Binding<Bool> {
        Binding(
            get: { allowed[point] ?? LCGuestExtensionPreparer.isAllowedPoint(point, folder: folder) },
            set: {
                allowed[point] = $0
                LCGuestExtensionPreparer.setAllowed($0, point: point, folder: folder)
            })
    }

    var body: some View {
        if !points.isEmpty {
            Section {
                ForEach(points, id: \.self) { point in
                    let name = LCGuestExtensionPreparer.displayName(forPoint: point)
                    if LCGuestExtensionPreparer.isSensitivePoint(point) {
                        Toggle(isOn: binding(point)) { Text("Allow \(name)") }
                    } else if point == "com.apple.widgetkit-extension" {
                        Toggle(isOn: Binding(get: { widgetsHere }, set: { on in
                            widgetsHere = on
                            LCGuestExtensionPreparer.useWidgets(ofFolder: on ? folder : "")
                            WidgetCenter.shared.reloadAllTimelines()
                        })) { Text("Show This App's Widgets") }
                    } else {
                        Text(name)
                    }
                }
            } header: {
                Text("App Extensions")
            } footer: {
                Text("This app's extensions run through LiveContainer's extensions, named \"LiveContainer\" or \"LiveContainer Apps\". Keyboard, Screen Broadcast and SMS Filter can see private data, so they stay off until you allow them. LiveContainer shows one app's widgets at a time.")
            }
        }
    }
}
