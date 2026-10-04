# Photon

**⌥Space, type, go.** A fast, offline Spotlight replacement for macOS.

![Photon — apps-only home, Acid Matrix](screenshots/hero.png)

## Why

Spotlight has now become an everything app. Alfred's best features are behind a paywall. This free open-source app offers speed and simplicity - just index apps and the folders you need. 

It's a small project by one developer. Found a bug? Want a feature? This is open
software — clone it, run `swift build`, and **feel free to use your own agents
to fix it**. Contributions welcome.

## Install

```bash
swift run photon-overlay
```

⌥Space opens the overlay. Type. Enter launches. That's it.

## Features

- **Apps always searchable** — no setup, no permissions on first run
- **Eight themes** — from flat light to full neon, switchable live in Settings
- **Files opt-in** — add folders in Settings via the native picker; access is
  granted per-folder (no broad permission dialogs)
- **Calculator** — type `2^10`, Enter copies the answer
- **Instant slots** — ⌘1–9 launches the first rows instantly

## Themes

Every animated theme has its own living background — rendered as chunky pixel art on a tiny
90×58 bitmap at 15fps, so it stays under 1% CPU.

<p>
<img src="screenshots/matrix.gif" width="48%" alt="Acid Matrix — falling code">
<img src="screenshots/ice.gif" width="48%" alt="Ice Circuit — snowfall and accumulation">
</p>
<p>
<img src="screenshots/sunset.gif" width="48%" alt="Synthwave Sunset — Miami grid">
<img src="screenshots/city.gif" width="48%" alt="Neon City — skyline and neon signs">
</p>

## Screenshots

![Search](screenshots/search.png)

![Calculator — type an expression, Enter copies it](screenshots/calc.png)

## Keys

| Key | Action |
|-----|--------|
| `⌥Space` | Toggle overlay |
| `↑` `↓` | Navigate (wraps) |
| `Enter` | Open |
| `⇧Enter` | Reveal in Finder |
| `⌘1–9` | Launch 1st–9th home row |
| `⌘,` | Settings |
| `Esc` | Close |

## Config

`~/.config/photon/config.json` — scan folders, per-folder depth/caps, theme.

## Privacy

Offline. No tracking. Per-folder access via the native picker only.

## Build

```bash
swift build
swift run photon-overlay    # the overlay
swift run photon            # CLI to configure scan folders
```

Release builds: `scripts/build_release.sh` (signed `.app` + zip).
