# Photon

Fast, offline macOS search overlay.

## Motivation

Spotlight is built in, but you can't control what it scans. Other launcher apps offer workflow automation, clipboard history, widgets, and integrations — great if you want an everything app. But most of them run a background agent constantly, consume memory even when idle, and add complexity you didn't ask for.

Photon is a spotlight replacement that stays scoped. Choose what gets indexed — your apps, your directories. Build the index once. Search from memory fast. No background agent. No extensions. No bloat. Just launch something and move on.

## Quick Start

```bash
swift run photon-overlay
```

Press Command + Option + Space to launch the floating overlay. Start typing — results appear instantly.

> **First run:** macOS will prompt for Accessibility permission. Allow it. Photon needs it to capture the global hotkey while other apps are active.

## What Is Photon?

A lightweight macOS search tool. It scans your apps and scoped directories once, keeps the index live in memory, and presents it as a floating overlay. No background agent. No constant polling. No network calls.

- Runs only when you launch it
- Indexes only the folders you choose
- Results cached in memory at all times

## How It Works

When `photon-overlay` starts, it scans your app directories and configured scopes (Desktop, Documents, Downloads by default). The results are cached in memory. Each time you press the hotkey, the overlay opens instantly with your cached results.

Press Option + R to refresh the index.

## Scan Scopes

By default, Photon indexes:
- Desktop
- Documents  
- Downloads

It also scans standard app directories: `/System/Applications`, `/Applications`, and `~/Applications`.

### Add Custom Scopes

Run `swift run photon` to interactively select which folders to index, then save.

## Ranking — How Results Are Sorted

Photon ranks results by match quality, then applies tiebreakers based on kind and path depth.

### Match Tiers

| Tier | Type | Points | Description |
|------|------|--------|-------------|
| 1 | **Exact name** | 1,500,000 / 1,000,500 / 900,000 | Your query matches the name exactly. E.g., `screenshot` matches `Screenshots`. |
| 2 | **Prefix** | 250,000 / 200,000 / 100,000 | Your query matches the start of the name. E.g., `scre` matches `Screenshots`. |
| 3 | **Contains** | 20,000 / 10,000 / 5,000 | Your query appears somewhere in the name. E.g., `shot` matches `Screenshots`. |
| 4 | **Path** | 1,500 / 1,000 / 500 | Your query appears only in the full path. E.g., `shot` matches `Documents/Screens/capture_log.pdf`. |

Higher tier always wins. Within each tier, the first point in each row applies to apps, the second to directories, the third to files. A prefix-match app (tier 2) outranks an exact-match file (tier 1) only if tiers are equal — which they never are since tiers are compared first.

### Tiebreakers

When two results land in the same tier:

1. **Kind:** Apps rank first, then directories, then files
2. **Root proximity:** Items closer to the root rank higher. `/Desktop/Screenshots` beats `/Users/jim/Projects/Screenshots`
3. **Alphabetical:** Pure alphabetical for identical scores

These tiebreakers reflect common use cases: you usually want the app or folder you are looking for over a file inside it, and a directory at the root of your scopes over a similarly-named deep folder.

### Example: Query = `screenshot`

```
1. /Desktop/Screenshots                          — exact match, tier 1, path depth 1
2. /Users/me/projects/screenshots/photo.jpg       — exact match, tier 1, path depth 7
3. Screenshot_2024-06-01.png                      — exact match, tier 1, file
4. screencapture.mov                              — prefix match, tier 2
5. Documents/Screens/capture_log.pdf              — path match, tier 4
```

## Keybindings

| Key | Action |
|-----|--------|
| Command+Option+Space | Toggle overlay |
| Up / Down | Navigate results (wraps around) |
| Enter | Open selected result |
| Shift+Enter | Reveal containing folder in Finder |
| Option+R | Refresh index |
| Escape | Close overlay |

## Configuration

### Scan Scopes

```bash
swift run photon
```

The CLI walks you through selecting scopes and saving your choices to `~/.config/photon/config.json`.

### Change the Hotkey

Edit the constants at the top of `Sources/photon-overlay/OverlayApp.swift`:

```swift
let hotkeyModifiers: NSEvent.ModifierFlags = [.command, .option]
let hotkeyKeyCode: Int = 49                 // space bar
```

Common keycodes: `space=49, Q=12, W=13, E=14, R=15, Y=17, U=18, I=19, O=21, P=22`

## Privacy

Photon is fully offline. No data leaves your machine. No tracking. No analytics. Your file paths reside in memory only for as long as the running process.

## Build & Run

```bash
swift build
swift run photon-overlay              # The search overlay
swift run photon                      # CLI tool for configuring scopes
```
