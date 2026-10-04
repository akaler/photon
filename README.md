# Photon

Fast, offline macOS search overlay.

## Motivation

Spotlight is built in, but you can't control what it scans. Other launcher apps offer workflow automation, clipboard history, widgets, and integrations — great if you want an everything app. But most of them run a background agent constantly, consume memory even when idle, and add complexity you didn't ask for.

Photon is a Spotlight replacement that stays scoped — and stays small. Apps are always searchable; file folders are an explicit, per-folder opt-in. No background agent. No network. No bloat. Just launch something and move on.

## Quick Start

```bash
swift run photon-overlay
```

Press `Option + Space` to launch the floating overlay. Start typing — apps appear instantly.

> **No permissions needed.** Photon's first-run experience is apps-only, and the hotkey is a system Carbon hotkey (no Accessibility prompt). File search is opt-in: add a folder in Settings and macOS's native picker grants access to *just that folder* — no broad permission dialogs.

## What Is Photon?

A lightweight macOS search tool. It scans your apps and any folders you opt into, keeps the index live in memory, and presents it as a floating overlay.

- Runs only when you launch it
- Apps always indexed; folders only when you add them
- Results cached in memory; instant search
- Offline — no data leaves your machine

## How It Works

`photon-overlay` scans standard app directories (`/System/Applications`, `/Applications`, `~/Applications`) on launch. The results are cached in memory. Each time you press the hotkey, the overlay opens instantly.

To search files, open Settings (`⌘,` or the gear) and add folders. Each folder you add gets its own **depth** and **file-count cap** (defaults: depth 3, 5,000 files), so indexing stays bounded even on machines with huge folders.

## Settings

Open Settings with `⌘,` or the gear icon in the top-right.

- **Theme** — 5 skins: Classic, Carbon Bar, Carbon Solid, Schematic, Paper. Arrows move the cursor; `Return` applies.
- **Scan folders** — apps are always indexed. Add folders via the native picker (`+ Add folder…`), which grants access to exactly the folder you choose. Select a folder and press `Return` to edit its depth/cap; `⌫` removes it.

## Ranking

Photon ranks results by match quality, then applies tiebreakers based on kind and path depth. Frequently/recently launched items get a bounded frecency boost within their match tier.

### Match Tiers

| Tier | Type | Points | Description |
|------|------|--------|-------------|
| 1 | **Exact name** | 1,500,000 / 1,000,500 / 900,000 | Your query matches the name exactly. E.g., `screenshot` matches `Screenshots`. |
| 2 | **Prefix** | 250,000 / 200,000 / 100,000 | Your query matches the start of the name. E.g., `scre` matches `Screenshots`. |
| 3 | **Contains** | 20,000 / 10,000 / 5,000 | Your query appears somewhere in the name. E.g., `shot` matches `Screenshots`. |
| 4 | **Path** | 1,500 / 1,000 / 500 | Your query appears only in the full path. |

Higher tier always wins. The three numbers per row are apps / directories / files.

### Example: Query = `screenshot`

```
1. /Desktop/Screenshots                          — exact match, tier 1
2. /Users/me/projects/screenshots/photo.jpg       — exact match, tier 1
3. Screenshot_2024-06-01.png                      — exact match, tier 1
4. screencapture.mov                              — prefix match, tier 2
5. Documents/Screens/capture_log.pdf              — path match, tier 4
```

## Calculator

Type an arithmetic expression (`2+2`, `(4+2)*3`, `2^10`) — the result pins to the top. `Return` copies it to the clipboard and closes. Non-expression queries fall through to normal search.

## Keybindings

| Key | Action |
|-----|--------|
| `Option+Space` | Toggle overlay |
| `Up` / `Down` | Navigate results (wraps around) |
| `Enter` | Open selected result |
| `Shift+Enter` | Reveal containing folder in Finder |
| `⌘A/C/V/X/Z` | Text editing in the search field |
| `⌘1–9` | Launch the 1st–9th home-screen row instantly |
| `⌘,` | Open Settings |
| `Escape` | Close overlay / leave settings |

## Configuration

Settings are stored in `~/.config/photon/config.json` (scan folders, per-folder limits, theme).

### Change the Hotkey

Edit the constants at the top of `Sources/photon-overlay/OverlayApp.swift`:

```swift
let hotkeyKeyCode: Int = 49                 // space bar
let status = RegisterEventHotKey(
    UInt32(hotkeyKeyCode),
    UInt32(optionKey),                  // default: Option
    carbonHotkeyID,
    GetApplicationEventTarget(),
    0,
    &hotKeyRef
)
```

Modifiers use Carbon constants: `cmdKey`, `optionKey`, `shiftKey`, `controlKey` (combine with `|`).

Common keycodes: `space=49, Q=12, W=13, E=14, R=15, Y=17, U=18, I=19, O=21, P=22`

## Privacy

Photon is fully offline. No data leaves your machine. No tracking. No analytics. File paths reside in memory only for as long as the process runs. Folder access is granted per-folder through the native picker — never broad or silent.

## Build & Run

```bash
swift build
swift run photon-overlay              # The search overlay
swift run photon                      # CLI tool for configuring scan folders
```

## Releasing (build a signed .app)

```bash
scripts/build_release.sh
```

The script signs with a stable local identity (`Photon Development`, self-signed in your login keychain) so TCC folder-access grants survive rebuilds. Output: `dist/Photon Overlay.app` and a zip. A self-signed build is fine for your own machines; for wide distribution you'd add notarization (requires an Apple Developer account).
