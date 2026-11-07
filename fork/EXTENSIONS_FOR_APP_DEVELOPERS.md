# App extensions inside LiveContainer

LiveContainer ships one extension of each supported kind. When iOS starts one, it loads the matching
extension of an app installed in LiveContainer and runs it in that app's environment. Build your app as
usual; in most cases nothing needs to change.

## What works unchanged

- Your extension's principal class (or main storyboard, for share and action extensions) is used as is.
  For widgets, your `@main` widget bundle runs as is, including Live Activities and controls.
- `Bundle.main` inside the extension is your extension's bundle, so its resources load normally.
- App groups and `UserDefaults(suiteName:)` are redirected the same way in your app and its extension,
  so they share data. Any group ID works.
- Darwin notifications and localhost sockets work between app and extension.
- Calls that name your extension by its bundle ID are pointed at LiveContainer's extension:
  `SFContentBlockerManager` reload/state, `CXCallDirectoryManager` reload/status, and
  `RPSystemBroadcastPickerView.preferredExtension`.
- File Provider domains your app adds belong to LiveContainer's File Provider, which runs your code
  for them.

## Limits

- One app per kind runs at a time: the app opened most recently (share and action extensions ask).
  Widgets come from the app picked in LiveContainer.
- Keyboard, screen broadcast and SMS filter extensions run only after the user allows them for your
  app in LiveContainer (app settings → App Extensions).
- Your extension's executable is converted to a dylib with the rpath `@loader_path/../../Frameworks`,
  so it can use frameworks in your app's `Frameworks/`. Don't put frameworks inside the `.appex`.
- Widgets configured with App Intents need their intents registered at install time; static widgets
  are the safe choice.
- Keychain sharing between app and extension isn't redirected.
- System memory limits apply as usual (about 50 MB for broadcast, 30 MB for widgets).
- Not supported: extensions that need entitlements a free account can't get (push notifications,
  Network Extension, AutoFill), Safari web extensions, Quick Look and notification extensions.

## Debugging

If an app's extension can't be loaded, LiveContainer's extension shows or returns the reason. The device
log has `[LCGuestExtension]` lines.
