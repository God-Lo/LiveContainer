//
//  GuestAppIntents.swift
//  LaunchAppExtension (fork)
//
//  Generic Shortcuts actions that work for every guest app without rebuilding LiveContainer:
//  "Open App in LiveContainer" and "Open URL in App". The app picker reads the guest list that
//  LiveContainer publishes to its shared defaults (LCGuestIntentsIndexer.publishGuestList), so
//  newly installed guests show up as soon as LiveContainer has been opened once.
//

import AppIntents
import Foundation

struct GuestAppEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "LiveContainer App" }
    static var defaultQuery = GuestAppQuery()

    /// The app's folder under Applications, which is how LiveContainer launch URLs name an app.
    var id: String
    var name: String
    var bundleId: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(bundleId)")
    }
}

struct GuestAppQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {
    static func installedApps() -> [GuestAppEntity] {
        guard let groupId = LCSharedUtils.appGroupID(),
              let defaults = UserDefaults(suiteName: groupId),
              let list = defaults.array(forKey: "LCShortcutGuestApps") as? [[String: String]] else {
            return []
        }
        return list.compactMap { item in
            guard let bundleId = item["bundleId"] else { return nil }
            return GuestAppEntity(id: item["folder"] ?? "\(bundleId).app", name: item["name"] ?? bundleId, bundleId: bundleId)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func entities(for identifiers: [String]) async throws -> [GuestAppEntity] {
        let apps = Self.installedApps()
        return identifiers.map { id in apps.first { $0.id == id } ?? GuestAppEntity(id: id, name: id, bundleId: id) }
    }

    func entities(matching string: String) async throws -> [GuestAppEntity] {
        Self.installedApps().filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.bundleId.localizedCaseInsensitiveContains(string)
        }
    }

    func allEntities() async throws -> [GuestAppEntity] { Self.installedApps() }
    func suggestedEntities() async throws -> [GuestAppEntity] { Self.installedApps() }
}

private func launchURL(for app: GuestAppEntity, openURL: URL?) -> URL {
    var components = URLComponents()
    components.scheme = "livecontainer"
    components.host = "livecontainer-launch"
    var items = [URLQueryItem(name: "bundle-name", value: app.id)]
    if let openURL {
        items.append(URLQueryItem(name: "open-url", value: Data(openURL.absoluteString.utf8).base64EncodedString()))
    }
    components.queryItems = items
    return components.url!
}

struct OpenGuestAppIntent: AppIntent {
    static var title: LocalizedStringResource { "Open App in LiveContainer" }
    static var description: IntentDescription { "Opens an app installed in LiveContainer." }

    @Parameter(title: "App")
    var app: GuestAppEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$app)") }

    func perform() async throws -> some IntentResult {
        let launcher = LaunchAppExtension()
        launcher.launchURL = launchURL(for: app, openURL: nil)
        _ = try await launcher.perform()
        return .result()
    }
}

struct OpenURLInGuestAppIntent: AppIntent {
    static var title: LocalizedStringResource { "Open URL in App" }
    static var description: IntentDescription { "Opens a URL (for example a deep link) in an app installed in LiveContainer." }

    @Parameter(title: "URL")
    var url: URL

    @Parameter(title: "App")
    var app: GuestAppEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$url) in \(\.$app)") }

    func perform() async throws -> some IntentResult {
        let launcher = LaunchAppExtension()
        launcher.launchURL = launchURL(for: app, openURL: url)
        _ = try await launcher.perform()
        return .result()
    }
}
