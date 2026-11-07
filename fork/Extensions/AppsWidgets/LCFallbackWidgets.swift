//
//  LCFallbackWidgets.swift
//  LiveContainer (fork)
//
//  Placeholder widget shown when no app in LiveContainer has widgets (see main.m).
//

import SwiftUI
import WidgetKit

private struct PlaceholderEntry: TimelineEntry { let date: Date }

private struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) { completion(PlaceholderEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

private struct PlaceholderView: View {
    var body: some View {
        let text = Text("Open an app with widgets in LiveContainer.").font(.footnote).multilineTextAlignment(.center).padding()
        if #available(iOS 17.0, *) {
            text.containerBackground(.fill.tertiary, for: .widget)
        } else {
            text
        }
    }
}

private struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LCPlaceholderWidget", provider: PlaceholderProvider()) { _ in PlaceholderView() }
            .configurationDisplayName("LiveContainer")
            .description("Shows your apps' widgets once an app with widgets is installed in LiveContainer.")
    }
}

private struct FallbackWidgets: WidgetBundle {
    var body: some Widget { PlaceholderWidget() }
}

@_cdecl("LCFallbackWidgetsMain")
func LCFallbackWidgetsMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    FallbackWidgets.main()
    return 0
}
