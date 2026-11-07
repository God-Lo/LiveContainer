<div align="center">
  <img width="160" src="./screenshots/livecontainer_icon.png" alt="">
  <h1>LiveContainer Fork</h1>
  <p>Run iOS apps without installing them, now with Shortcuts and screen broadcast for your apps.</p>
</div>

A fork of [LiveContainer](https://github.com/LiveContainer/LiveContainer). It keeps the same bundle ID,
so it installs over LiveContainer and keeps your apps and data.

## Install

Add this source to SideStore or AltStore:

```
https://raw.githubusercontent.com/God-Lo/LiveContainer/main/source.json
```

Or download `LiveContainer+SideStore.ipa` from [Releases](https://github.com/God-Lo/LiveContainer/releases/latest).

## What's new

**Shortcuts for your apps**
- Turn on **Shortcuts** in an app's settings in LiveContainer. Its actions show up in the Shortcuts app,
  in their own section.
- Actions run in the background, even while another app is open in LiveContainer.
- Always available: **Open App in LiveContainer** and **Open URL in App**.
- Needs the built-in SideStore, which reinstalls LiveContainer with the actions. Your data is kept.

**Screen broadcast for your apps**
- Apps with a screen broadcast extension work automatically.
- Control Center → long-press Screen Recording → choose **LiveContainer**. It uses the app you opened last.
- Needs LiveContainer's signing certificate (JIT-less mode).
- App developers: see [BROADCAST_FOR_APP_DEVELOPERS.md](fork/BROADCAST_FOR_APP_DEVELOPERS.md).

Everything else works like LiveContainer. See its [documentation](https://livecontainer.github.io/docs/intro).

## Build

Needs Xcode, Homebrew and the GitHub CLI.

```bash
fork/scripts/update-from-upstream.sh   # get the latest LiveContainer source
fork/scripts/build-ipa.sh              # build fork/out/LiveContainer+SideStore.ipa
fork/scripts/release.sh "notes"        # publish a release and add it to source.json
```

## Credits and license

Based on [LiveContainer](https://github.com/LiveContainer/LiveContainer) by the LiveContainer team and
contributors. Licensed under the [AGPL-3.0](LICENSE), like the original.

Not affiliated with or endorsed by Apple or the LiveContainer team.
