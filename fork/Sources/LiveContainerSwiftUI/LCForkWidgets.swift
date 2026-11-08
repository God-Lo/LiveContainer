//
//  LCForkWidgets.swift
//  LiveContainer (fork)
//
//  Tapping an app's widget opens that app, as it would natively. iOS sends widget taps to the
//  containing app, LiveContainer: a link (widgetURL, Link) or, without one, an activity named after
//  the widget's kind. LiveContainer finds the app it belongs to and launches it with the link.
//

import Foundation

enum LCForkWidgets {
    private static var apps: [LCAppInfo] {
        let model = DataManager.shared.model
        return (model.apps + model.hiddenApps).map(\.appInfo)
    }

    private static var lcSchemes: Set<String> {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return Set(types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.map { $0.lowercased() })
    }

    /// A LiveContainer launch link for an app's own link (e.g. from its widget), or nil if no app
    /// registers its scheme.
    static func launchURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), !url.isFileURL, scheme != "sidestore", !lcSchemes.contains(scheme),
              let app = apps.first(where: { ($0.urlSchemes() as? [String] ?? []).contains { $0.lowercased() == scheme } }),
              let folder = app.relativeBundlePath else { return nil }
        return launchURL(folder: folder, open: url)
    }

    /// Opens the app a tapped widget belongs to. Returns false for other activities.
    @discardableResult
    static func open(_ activity: NSUserActivity) -> Bool {
        guard let kind = activity.userInfo?["WGWidgetUserInfoKeyKind"] as? String ?? widgetKind(activity),
              let folder = widgetApp(kind: kind, activity: activity),
              let url = launchURL(folder: folder, open: nil) else { return false }
        DataManager.shared.model.selectedTab = .apps
        DataManager.shared.model.deepLink = url
        return true
    }

    private static func widgetKind(_ activity: NSUserActivity) -> String? {
        // Widget taps carry the widget's family next to its kind; nothing else does.
        activity.userInfo?["WGWidgetUserInfoKeyFamily"] != nil ? activity.activityType : nil
    }

    private static func launchURL(folder: String, open: URL?) -> URL? {
        var components = URLComponents()
        components.scheme = LCUtils.appUrlScheme()
        components.host = "livecontainer-launch"
        components.queryItems = [URLQueryItem(name: "bundle-name", value: folder)]
        if let open, let encoded = open.absoluteString.data(using: .utf8)?.base64EncodedString() {
            components.queryItems?.append(URLQueryItem(name: "open-url", value: encoded))
        }
        return components.url
    }

    /// The app folder whose widget has this kind: by the extension's ID if iOS names it, then by the kind
    /// in the widget's code, then the only app with widgets.
    private static func widgetApp(kind: String, activity: NSUserActivity) -> String? {
        let plugins = Bundle.main.builtInPlugInsURL
        var copies: [(folder: String, bundleId: String, executable: URL)] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: plugins?.path ?? "")) ?? [] {
            guard let appex = plugins?.appendingPathComponent(name),
                  let info = NSDictionary(contentsOf: appex.appendingPathComponent("Info.plist")) as? [String: Any],
                  (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension",
                  let folder = (info["LCGuestExtension"] as? [String: Any])?["folder"] as? String,
                  let exec = info["CFBundleExecutable"] as? String else { continue }
            copies.append((folder, info["CFBundleIdentifier"] as? String ?? "", appex.appendingPathComponent(exec)))
        }
        let named = Set((activity.userInfo ?? [:]).values.compactMap { $0 as? String })
        if let match = copies.first(where: { named.contains($0.bundleId) }) { return match.folder }
        let needle = Data(kind.utf8)
        if let match = copies.first(where: { (try? Data(contentsOf: $0.executable, options: .mappedIfSafe))?.range(of: needle) != nil }) {
            return match.folder
        }
        let folders = Set(copies.map(\.folder))
        return folders.count == 1 ? folders.first : nil
    }
}
