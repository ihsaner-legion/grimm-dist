# grimm

grimm is a Clippy-inspired AI mix assistant for [Reaper](https://www.reaper.fm/). It watches your master bus in real time and flags mixing issues — mud, clipping, phase problems.

This repository is the public distribution surface. Source is not public.

## Prerequisites

- macOS 12 or newer, **Apple Silicon only** (Intel Macs not supported in v0.0.3)
- [Reaper 7.x](https://www.reaper.fm/download.php)
- [ReaPack](https://reapack.com/) installed in Reaper

## Install

**1. Add the ReaPack repository.**

In Reaper, open `Extensions → ReaPack → Manage repositories → Import repositories` and paste:

```
https://raw.githubusercontent.com/ihsaner-legion/grimm-dist/main/index.xml
```

Click OK, then `Synchronize packages`. Open `ReaPack → Browse packages`, filter for `grimm`, right-click each package (`grimm: start assistant` and `grimm master`) and install.

**2. Download the grimm app.**

Grab the latest `.dmg` from [Releases](https://github.com/ihsaner-legion/grimm-dist/releases/latest). Open the DMG and drag `grimm.app` to your Applications folder.

**First launch — bypass Gatekeeper:**

grimm is unsigned. On first launch macOS will refuse to open it.

- **macOS 12–14:** right-click `grimm.app` in Applications → `Open` → confirm.
- **macOS 15+:** try to open grimm, then go to `System Settings → Privacy & Security`, scroll to "grimm was blocked", click `Open Anyway`.

macOS remembers this choice after the first confirmation.

## First run

In Reaper, open the action list (`?`), type `grimm`, and run `grimm: start assistant`.

- grimm.app window appears as a transparent bubble
- `grimm_master.jsfx` is automatically inserted on your master bus
- the bubble shows live RMS in dB

To stop: run `grimm: start assistant` again. Everything tears down cleanly (JSFX is removed from master, socket closes).

## Troubleshooting

**`[grimm] app not found` in Reaper console**
→ grimm.app isn't installed. Follow step 2 above.

**`[grimm] grimm_master.jsfx not found`**
→ ReaPack didn't install the JSFX. Re-sync via ReaPack and make sure both packages are installed.

**Bubble says "Update grimm app"**
→ the Reaper-side scripts are newer than your downloaded app. Download the latest `.dmg`.

**Bubble says "Update grimm via ReaPack"**
→ the app is newer than your installed scripts. Re-sync ReaPack.

**Bubble stays on `—`**
→ the bridge script isn't connected to the app. Check the Reaper console (`View → Console`) for errors.

## License

MIT. Source available on request.
