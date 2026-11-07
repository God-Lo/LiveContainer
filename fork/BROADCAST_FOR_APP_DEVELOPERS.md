# Making an app's live screen capture work inside LiveContainer

This fork of LiveContainer ships one ReplayKit broadcast upload extension, shown as "LiveContainer" in
the iOS broadcast picker. It loads the broadcast upload extension of the app opened most recently in LiveContainer.
Build your app as a normal app with a standard broadcast extension; the rules below make it also work
inside LiveContainer.

## 1. Packaging

- The IPA must contain `Payload/<App>.app/PlugIns/<Name>.appex` whose Info.plist `NSExtension` has:
  - `NSExtensionPointIdentifier` = `com.apple.broadcast-services-upload`
  - `NSExtensionPrincipalClass` = your handler, e.g. `$(PRODUCT_MODULE_NAME).SampleHandler`
  - `RPBroadcastProcessMode` = `RPBroadcastProcessModeSampleBuffer`
- The principal class must subclass `RPBroadcastSampleHandler`. LiveContainer finds it with
  `NSClassFromString(principalClass)`, so a normal Swift class (`Module.SampleHandler`) works. Don't rename
  it with a mismatched `@objc(...)` name.
- LiveContainer converts the appex executable into a dylib and adds the rpath `@loader_path/../../Frameworks`,
  so the extension can use frameworks in the main app's `Frameworks/`. Don't put frameworks inside the
  `.appex` itself: its `@executable_path` will be LiveContainer's extension, not yours. Prefer static
  linking or the app's `Frameworks/`.

## 2. App ↔ extension communication

- Use an App Group: `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` and
  `UserDefaults(suiteName:)`. LiveContainer redirects both the same way in the app and the extension, so
  they share data. Declare the group in both entitlements for native builds; inside LiveContainer any
  group ID works.
- Hard-code the group ID. Inside the extension, `Bundle.main` is LiveContainer's extension bundle, not
  your appex, so don't read configuration from it.
- Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) and localhost sockets
  (e.g. the extension streams frames over TCP `127.0.0.1:<port>` to the app) work between the two processes.
- Keychain sharing between app and extension is not redirected; don't rely on it.
- Real-time frames: in `processSampleBuffer(_:with: .video)`, downscale and compress (`VTCompressionSession`
  H.264, or JPEG at reduced size), then send over a localhost socket, or a ring-buffer file in the app group
  plus a Darwin notification. Broadcast extensions are capped at about 50 MB of memory; never buffer raw
  full-resolution frames.

## 3. Turning it on

- Just install the IPA in LiveContainer. Its broadcast extension is prepared automatically (needs
  LiveContainer's JIT-less signing certificate); updating the app prepares it again.
- If several apps have a broadcast extension, the broadcast runs the one from the app opened most recently.
- Start capture: Control Center → long-press Screen Recording → choose **LiveContainer**.
  In-app, `RPSystemBroadcastPickerView` works. Inside LiveContainer, set `preferredExtension` to
  `<LiveContainer bundle ID>.LiveBroadcastExtension` (e.g. `com.kdt.livecontainer.<TEAMID>.LiveBroadcastExtension`), or
  leave it nil and let the user pick. Outside LiveContainer, use your own appex ID.

## 4. Debugging

- If loading fails, the broadcast stops with a reason from LiveContainer (no app prepared, can't load
  code, class not found).
- The device log has `[LCBroadcast]` lines from the extension.
