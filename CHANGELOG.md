# Changelog

## Unreleased

- Overhauled the overlay entrance: fixed the opening stutter (the panel no longer animates toward closed after appearing), disabled the system window zoom (`animationBehavior = .none`), and replaced it with a fast, subtle custom entrance (~40ms, tiny scale + fade, tuned for 120Hz displays). It now reads as instant with a barely-perceptible settle.
- Changed the overlay shortcut to `Option + Shift + Space` to avoid conflicting with common macOS shortcuts.
- Registered the overlay shortcut with macOS using `RegisterEventHotKey` so it continues working after the overlay has been opened and hidden.
- Added local and global key monitor fallbacks for the overlay shortcut.
- Lowered the Swift tools version to 6.1 so the package builds with the currently installed Apple Swift 6.1 toolchain.
