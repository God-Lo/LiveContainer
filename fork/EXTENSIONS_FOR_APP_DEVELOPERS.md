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
- Files: your app gets one location in the Files app, and your File Provider (replicated, iOS 16+) serves
  it, loaded by LiveContainer's own File Provider. `init(domain:)` gets LiveContainer's domain for your
  app; use it as given. Domains your app adds or removes are ignored (the request still succeeds).
  Without a File Provider, the location shows your app's Documents. Needs LiveContainer's JIT-less
  signing certificate, like share. iOS may run several apps' File Providers in one process; then only
  the first app gets its own home folder and settings, so keep the provider's data in an app group.
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

## Background events

With **Background Events** on for your app, LiveContainer's Info.plist gets your `UIBackgroundModes`,
`UISupportedExternalAccessoryProtocols`, `BGTaskSchedulerPermittedIdentifiers` and any permission texts
it lacks. iOS sends these events to LiveContainer, which passes them to your app running in the
background (LiveProcess). Use the standard APIs as usual:

- Bluetooth: your `CBCentralManager` restore IDs and `registerForConnectionEvents` filters are made by
  LiveContainer; your delegate gets `centralManager(_:willRestoreState:)` and
  `centralManager(_:connectionEventDidOccur:for:)`.
- Accessories: `EAAccessoryManager.connectedAccessories` and the connect/disconnect notifications work,
  and `EASession` streams are relayed to the real accessory by LiveContainer.
- Location: significant-change and region monitoring; your delegate gets the updates.
- Background tasks: your `BGTaskScheduler` handlers run with the task; `setTaskCompleted` and
  `expirationHandler` work.

LiveContainer learns what your app registers while it runs, so it needs to have run once after the
switch is on. Push notifications and VoIP pushes don't work: they need entitlements LiveContainer doesn't
have. Events arrive while LiveContainer shows its own screen or is in the background, not while it's
running another app.
