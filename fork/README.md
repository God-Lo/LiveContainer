# LiveContainer fork

A fork of [LiveContainer](https://github.com/LiveContainer/LiveContainer) with two additions:
Shortcuts actions for apps inside LiveContainer, and screen broadcast for apps inside LiveContainer.
It keeps the upstream bundle ID, so it installs over LiveContainer and keeps your data.

Not affiliated with or endorsed by Apple or the LiveContainer team.

## Install and update

Add this source to SideStore (or the SideStore built into LiveContainer):

```
https://raw.githubusercontent.com/God-Lo/LiveContainer/main/source.json
```

Or download `LiveContainer+SideStore.ipa` from Releases.

## Shortcuts for apps

- Each app has a **Shortcuts** switch in its settings. It is off by default.
- Turning it on adds the app's actions to Shortcuts, in their own section. LiveContainer rebuilds itself
  with the actions and the built-in SideStore reinstalls it. Your data is kept. Choose "keep app
  extensions" so no new App IDs are used.
- Actions run in the background, even while another app is open in LiveContainer.
- Deleting an app offers to remove its actions.
- Always available: **Open App in LiveContainer** and **Open URL in App**.
- Needs LiveContainer+SideStore. Actions that need the app's UI or ask follow-up questions aren't
  supported.

## Screen broadcast for apps

- Nothing to turn on. Apps with a broadcast upload extension are prepared automatically.
- Start a broadcast from Control Center (long-press Screen Recording) and choose **LiveContainer**.
  It runs the broadcast extension of the app you opened most recently.
- Needs LiveContainer's signing certificate (JIT-less mode).
- For app developers: [BROADCAST_FOR_APP_DEVELOPERS.md](BROADCAST_FOR_APP_DEVELOPERS.md).

## Build and release

```bash
fork/scripts/update-from-upstream.sh   # merge the latest upstream source into main
fork/scripts/build-ipa.sh              # build fork/out/LiveContainer+SideStore.ipa
fork/scripts/release.sh                # build, publish a GitHub release, add it to source.json
```

Needs Xcode, Homebrew and the GitHub CLI.
