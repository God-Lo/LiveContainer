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

To update: LiveContainer checks at launch, or tap **Settings → Check for Updates**. Updates also show in the
built-in SideStore under My Apps.

## What's new

**Shortcuts for your apps**
- Turn on **Shortcuts** in an app's settings in LiveContainer. Its actions show up in the Shortcuts app,
  in their own section.
- Actions run in the background, even while another app is open in LiveContainer.
- Always available: **Open App in LiveContainer** and **Open URL in App**.
- Needs the built-in SideStore, which reinstalls LiveContainer with the actions. Your data is kept.
- Updates from the built-in SideStore always keep extensions under LiveContainer's one App ID; it no
  longer asks.

**Your apps' extensions**

LiveContainer runs these kinds of extensions from your apps, with no changes to the apps and no extra App IDs:

| Kind | Where it shows up |
|---|---|
| Share, Actions | Share sheet, as **LiveContainer Apps** |
| Widgets, Live Activities, controls | Widget gallery, as **LiveContainer Apps** |
| Keyboard | Settings → Keyboards, as **LiveContainer** |
| Safari content blocker | Settings → Safari → Extensions |
| Files (File Provider) | Files app |
| Screen broadcast | Control Center → Screen Recording → **LiveContainer** |
| Photo editing, iMessage app | Photos edit menu, Messages app drawer |
| Call blocking, SMS filter | Settings → Phone / Messages |

- Each kind runs the app you opened most recently. Share and Actions ask which app when several have one.
- Widgets come from one app at a time: the one with **Widgets** turned on in its settings.
- **Keyboard, Screen Broadcast and SMS Filter** can see private data. They stay off until you allow them
  in the app's settings in LiveContainer, under **App Extensions**, where every feature has a switch.
- Needs LiveContainer's signing certificate (JIT-less mode).
- App developers: see [EXTENSIONS_FOR_APP_DEVELOPERS.md](fork/EXTENSIONS_FOR_APP_DEVELOPERS.md).

Everything else works like LiveContainer. See its [documentation](https://livecontainer.github.io/docs/intro).

## Build

Needs Xcode, Homebrew and the GitHub CLI. Fork code lives in `fork/`; upstream files only have a
one-line call into it where needed, so updates from LiveContainer merge easily.

```bash
fork/scripts/update-from-upstream.sh   # get the latest LiveContainer source
fork/scripts/build-ipa.sh              # build fork/out/LiveContainer+SideStore.ipa
fork/scripts/release.sh "notes"        # publish a release and add it to source.json
```

## Credits and license

Based on [LiveContainer](https://github.com/LiveContainer/LiveContainer) by the LiveContainer team and
contributors. Licensed under the [AGPL-3.0](LICENSE), like the original.

Not affiliated with or endorsed by Apple or the LiveContainer team.
