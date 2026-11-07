# App extensions inside LiveContainer

When the user turns on an app's extensions in LiveContainer (app settings → App Extensions), LiveContainer
rebuilds itself with a copy of each of the app's extensions of those kinds and reinstalls through the
built-in SideStore. The copy is your extension bundle as built: same code, resources, principal class or
storyboard, widget bundle and App Intents metadata. It only gets a new bundle ID under LiveContainer and
loads LiveContainer's runtime first. Build your app as usual; in most cases nothing needs to change.

## What works unchanged

- Your extension runs as itself. `Bundle.main` is its own bundle; widgets, Live Activities and controls
  come from your `@main` widget bundle and its App Intents metadata.
- App groups and `UserDefaults(suiteName:)` are redirected the same way in your app and its extension, so
  they share data. Any group ID works.
- Calls that name your extension by its bundle ID are pointed at its copy: `SFContentBlockerManager`
  reload/state, `CXCallDirectoryManager` reload/status, and `RPSystemBroadcastPickerView.preferredExtension`.
- Files: LiveContainer shows your app's Documents as its own location in the Files app. Your File Provider
  extension isn't used, and domains your app adds are ignored (the request still succeeds).
- Frameworks in your app's `Frameworks/` that the extension links are copied next to it.

## Limits

- Supported kinds: widgets (with Live Activities and controls), share, action, Safari
  content blocker, photo editing, iMessage, call directory, keyboard, broadcast upload, SMS filter.
- iMessage and SMS filter: one app at a time in LiveContainer, shown as "LiveContainer".
  Share extensions are listed in LiveContainer's share item under "Share With". Other kinds are shown as
  "<App> - <Extension>".
- Your extension gets only LiveContainer's app groups, never other entitlements (push, iCloud, keychain
  sharing, Network Extension, AutoFill and similar don't work).
- Keyboards need Allow Full Access to reach your app's data; without it they get a data folder of their
  own, and only app groups are shared.
- Changes take a LiveContainer reinstall: turning a kind on or off, and updating your app.

## Debugging

The device log has `[LCGuestExtension]` lines from your extension's process.
