//
//  LCGuestIntentsMerger.swift
//  LiveContainer (fork)
//
//  Merges the guest
//  App Intents metadata recorded by LCGuestIntentsIndexer into a copy of LiveContainer.app.
//
//  LiveContainer's own metadata (SideStore's actions in LiveContainer+SideStore) is kept as
//  LCBaseMetadata.appintents inside the bundle, so each merge starts clean and apps you have
//  deleted disappear from Shortcuts at the next reinstall.
//

import CryptoKit
import Foundation

enum LCGuestIntentsMerger {
    static let baseFolder = "LCBaseMetadata.appintents"
    static let mapFile = "LCGuestIntentsMap.plist"
    static let stateFile = "LCGuestIntentsState.plist"

    struct Guest {
        let bundleId: String
        let name: String
        let metadataFiles: [URL]
        let strings: [String: [String: String]]
    }

    static func loadGuests(from root: URL = LCGuestIntentsIndexer.rootURL) -> [Guest] {
        let fm = FileManager.default
        let ids = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        return ids.compactMap { id in
            let dir = root.appendingPathComponent(id)
            guard let info = NSDictionary(contentsOf: dir.appendingPathComponent("info.plist")),
                  let bundleId = info["bundleId"] as? String else { return nil }
            let metaRoot = dir.appendingPathComponent("Metadata")
            let files = ((try? fm.contentsOfDirectory(atPath: metaRoot.path)) ?? []).sorted()
                .map { metaRoot.appendingPathComponent($0).appendingPathComponent("extract.actionsdata") }
                .filter { fm.fileExists(atPath: $0.path) }
            guard !files.isEmpty else { return nil }
            var strings: [String: [String: String]] = [:]
            let sdir = dir.appendingPathComponent("Strings")
            for name in (try? fm.contentsOfDirectory(atPath: sdir.path)) ?? [] where name.hasSuffix(".strings") {
                if let table = NSDictionary(contentsOf: sdir.appendingPathComponent(name)) as? [String: String] {
                    strings[String(name.dropLast(".strings".count))] = table
                }
            }
            return Guest(bundleId: bundleId, name: info["name"] as? String ?? bundleId, metadataFiles: files, strings: strings)
        }
    }

    /// Fingerprint of the recorded guest metadata; changes when an app with actions is added, updated or removed.
    static func signature(of guests: [Guest]) -> String {
        var hasher = SHA256()
        for guest in guests {
            hasher.update(data: Data(guest.bundleId.utf8))
            for file in guest.metadataFiles {
                hasher.update(data: (try? Data(contentsOf: file)) ?? Data())
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Signature of the guests merged into the running LiveContainer ("" when none).
    static var installedSignature: String {
        let url = Bundle.main.bundleURL.appendingPathComponent(stateFile)
        return (NSDictionary(contentsOf: url)?["signature"] as? String) ?? ""
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw NSError(domain: "LiveContainer.SelfUpdate", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unreadable App Intents metadata at \(url.lastPathComponent)"])
        }
        return obj
    }

    /// Merges `guests` into `app` (a writable copy of LiveContainer.app). Returns the number of actions added.
    @discardableResult
    static func merge(into app: URL, guests: [Guest]) throws -> Int {
        let fm = FileManager.default
        let meta = app.appendingPathComponent("Metadata.appintents")
        let base = app.appendingPathComponent(baseFolder)
        // First merge ever: what is there now is LiveContainer's own metadata (or nothing).
        if !fm.fileExists(atPath: base.path) {
            if fm.fileExists(atPath: meta.path) {
                try fm.copyItem(at: meta, to: base)
                try stripPreviouslyMergedActions(base: base, map: app.appendingPathComponent(mapFile))
            } else {
                try fm.createDirectory(at: base, withIntermediateDirectories: true)
            }
        }
        try? fm.removeItem(at: meta)
        let baseActions = base.appendingPathComponent("extract.actionsdata")
        let hasBase = fm.fileExists(atPath: baseActions.path)
        if hasBase {
            try fm.copyItem(at: base, to: meta)
        }
        try? fm.removeItem(at: app.appendingPathComponent(mapFile))
        guard !guests.isEmpty else {
            try writeState(app: app, guests: guests)
            return 0
        }

        var root: [String: Any]
        if hasBase {
            root = try readJSON(baseActions)
        } else {
            root = try readJSON(guests[0].metadataFiles[0])
            for key in ["actions", "entities", "queries"] { root[key] = [String: Any]() }
            for key in ["assistantEntities", "assistantIntentNegativePhrases", "assistantIntents",
                        "autoShortcuts", "negativePhrases", "enums"] { root[key] = [Any]() }
            root["autoShortcutProviderMangledName"] = ""
            try fm.createDirectory(at: meta, withIntermediateDirectories: true)
            let version = guests[0].metadataFiles[0].deletingLastPathComponent().appendingPathComponent("version.json")
            if fm.fileExists(atPath: version.path) {
                try fm.copyItem(at: version, to: meta.appendingPathComponent("version.json"))
            } else {
                try Data(#"{"toolsVersion":"16.0","version":"3.0"}"#.utf8).write(to: meta.appendingPathComponent("version.json"))
            }
        }

        var actions = root["actions"] as? [String: Any] ?? [:]
        var entities = root["entities"] as? [String: Any] ?? [:]
        var queries = root["queries"] as? [String: Any] ?? [:]
        var enums = root["enums"] as? [[String: Any]] ?? []
        var enumIds = Set(enums.compactMap { $0["identifier"] as? String })
        var map: [String: [String: String]] = [:]

        for guest in guests {
            for file in guest.metadataFiles {
                let data = try readJSON(file)
                for (ident, value) in data["actions"] as? [String: Any] ?? [:] {
                    guard var action = value as? [String: Any] else { continue }
                    var mergedId = ident
                    if actions[mergedId] != nil {
                        mergedId = "\(guest.bundleId.replacingOccurrences(of: ".", with: "_"))_\(ident)"
                        if actions[mergedId] != nil { continue }
                    }
                    action["identifier"] = mergedId
                    if var title = action["title"] as? [String: Any], let key = title["key"] as? String {
                        let table = title["table"] as? String ?? "Localizable"
                        title["key"] = "\(guest.name): \(guest.strings[table]?[key] ?? key)"
                        title.removeValue(forKey: "table")
                        title["alternatives"] = [Any]()
                        action["title"] = title
                    }
                    // Shortcuts shows one section per category name, so give each app its own section.
                    var description = action["descriptionMetadata"] as? [String: Any]
                        ?? ["descriptionText": ["alternatives": [Any](), "key": ""], "searchKeywords": [Any]()]
                    description["categoryName"] = ["title": ["alternatives": [Any](), "key": guest.name]]
                    action["descriptionMetadata"] = description
                    actions[mergedId] = action
                    map[mergedId] = ["bundleId": guest.bundleId, "identifier": ident,
                                     "mangledTypeName": action["mangledTypeName"] as? String ?? ""]
                }
                for (ident, item) in data["entities"] as? [String: Any] ?? [:] where entities[ident] == nil { entities[ident] = item }
                for (ident, item) in data["queries"] as? [String: Any] ?? [:] where queries[ident] == nil { queries[ident] = item }
                for item in data["enums"] as? [[String: Any]] ?? [] {
                    let id = item["identifier"] as? String ?? ""
                    if enumIds.insert(id).inserted { enums.append(item) }
                }
            }
        }
        root["actions"] = actions
        root["entities"] = entities
        root["queries"] = queries
        root["enums"] = enums

        let json = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try json.write(to: meta.appendingPathComponent("extract.actionsdata"))
        try PropertyListSerialization.data(fromPropertyList: map, format: .binary, options: 0)
            .write(to: app.appendingPathComponent(mapFile))
        try writeState(app: app, guests: guests)
        return map.count
    }

    /// Builds made before the base snapshot existed already contain guest actions; take them out.
    private static func stripPreviouslyMergedActions(base: URL, map mapURL: URL) throws {
        guard let map = NSDictionary(contentsOf: mapURL) as? [String: Any], !map.isEmpty else { return }
        let actionsURL = base.appendingPathComponent("extract.actionsdata")
        var root = try readJSON(actionsURL)
        var actions = root["actions"] as? [String: Any] ?? [:]
        for id in map.keys { actions.removeValue(forKey: id) }
        root["actions"] = actions
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: actionsURL)
    }

    private static func writeState(app: URL, guests: [Guest]) throws {
        try PropertyListSerialization.data(fromPropertyList: ["signature": guests.isEmpty ? "" : signature(of: guests)],
                                           format: .xml, options: 0)
            .write(to: app.appendingPathComponent(stateFile))
    }
}
