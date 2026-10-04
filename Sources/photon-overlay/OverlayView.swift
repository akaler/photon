import SwiftUI
import AppKit
import PhotonCore

// MARK: - Color(hex:)

private extension Color {
    /// Supports #RGB, #RRGGBB, and #RRGGBBAA.
    init(hex: String) {
        var str = hex
        if str.hasPrefix("#") { str.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: str).scanHexInt64(&value)
        let r, g, b, a: Double
        switch str.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            r = 1; g = 1; b = 1; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

private extension Font.Weight {
    static func named(_ string: String) -> Font.Weight {
        switch string {
        case "light": return .light
        case "medium": return .medium
        case "semibold": return .semibold
        default: return .regular
        }
    }
}

// MARK: - OverlayView

struct OverlayView: View {
    @ObservedObject var state: ScanState
    let onSubmit: (SearchResult) -> Void
    let onReveal: (SearchResult) -> Void
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var settingsMode = false
    @State private var settingsIndex = 0
    /// Index into `state.scanFolders` currently being edited inline (nil = none).
    @State private var editingFolder: Int? = nil
    /// While editing a folder, which limit is active (false = depth, true = cap).
    @State private var editingCap = false

    private var theme: Theme { state.theme }

    var body: some View {
        Group {
            if settingsMode {
                settingsPage
            } else {
                searchPage
            }
        }
        .frame(width: 720, height: 460)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        .onKeyPress { handleKey($0) }
        .task {
            searchFocused = true
            if state.results.isEmpty { state.scan() }
        }
        .onChange(of: state.focusGeneration) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // let the panel become key
                searchFocused = true
            }
        }
    }

    // MARK: Key handling (arrows, esc, return, ⌘, and ⌘1–9 slots)

    private func handleKey(_ key: KeyPress) -> KeyPress.Result {
        if settingsMode {
            // Inline limit editing: arrows change the active number.
            if let folderIdx = editingFolder, state.scanFolders.indices.contains(folderIdx) {
                switch key.key {
                case .upArrow, .downArrow:
                    var folder = state.scanFolders[folderIdx]
                    let delta = key.key == .upArrow ? 1 : -1
                    if editingCap {
                        folder.fileCap = max(1, folder.fileCap + delta)
                    } else {
                        folder.depth = max(1, folder.depth + delta)
                    }
                    state.updateScanFolder(folder)
                    return .handled
                case .leftArrow:
                    editingCap = false
                    return .handled
                case .rightArrow:
                    editingCap = true
                    return .handled
                case .escape, .return:
                    editingFolder = nil
                    return .handled
                default:
                    return .handled
                }
            }

            switch key.key {
            case .upArrow:
                guard settingsIndex > 0 else { return .handled }
                settingsIndex -= 1
                return .handled
            case .downArrow:
                guard settingsIndex < settingsRows.count - 1 else { return .handled }
                settingsIndex += 1
                return .handled
            case .return:
                activateSettingsSelection()
                return .handled
            case .delete:
                removeSelectedFolder()
                return .handled
            case .escape:
                exitSettings()
                return .handled
            default:
                return .ignored
            }
        }

        switch key.key {
        case .upArrow:    state.moveUp(); return .handled
        case .downArrow:  state.moveDown(); return .handled
        case .escape:     onClose(); return .handled
        case .return:
            if key.modifiers.contains(.shift) { revealCurrent() }
            else { submitCurrent() }
            return .handled
        default:
            break
        }

        if key.modifiers.contains(.command) {
            // ⌘, opens settings
            if key.characters == "," {
                openSettings()
                return .handled
            }
            // ⌘1–9: slot launch, home screen only — mid-search, digits type.
            if let n = Int(key.characters), (1...9).contains(n) {
                if state.query.isEmpty, let r = state.slotResult(n) {
                    submit(r)
                }
                return .handled
            }
            // The blanket .onKeyPress intercepts every command key, so route
            // text-editing shortcuts (⌘A/C/V/X/Z…) back to the field editor
            // via the responder chain, or select-all etc. would never fire.
            switch key.characters {
            case "a": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case "c": NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case "x": NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case "v": NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case "z": NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            case "Z": NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            default: break
            }
            if ["a", "c", "x", "v", "z", "Z"].contains(key.characters) {
                return .handled
            }
        }
        return .ignored
    }

    // MARK: Settings rows (themes + scan folders)

    private enum SettingsItem: Equatable {
        case theme(ThemeKind)
        case folder(Int)     // index into state.scanFolders
        case addFolder
        case hotkey
    }

    private var settingsRows: [SettingsItem] {
        ThemeKind.allCases.map(SettingsItem.theme)
            + state.scanFolders.indices.map(SettingsItem.folder)
            + [.addFolder, .hotkey]
    }

    private var selectedSettingsRow: SettingsItem? {
        guard settingsRows.indices.contains(settingsIndex) else { return nil }
        return settingsRows[settingsIndex]
    }

    /// Leave settings and return focus to the search field. Focus must be
    /// re-asserted AFTER the search view re-enters the hierarchy (the settings
    /// page was showing when the key fired), or the request is dropped.
    private func exitSettings() {
        settingsMode = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            searchFocused = true
        }
    }

    /// Return on a row (or a mouse click on a theme row): applies the theme,
    /// expands a folder's limits, or opens the folder picker. Arrows only move
    /// the cursor so browsing to the folder list never changes the theme.
    private func activateSettingsSelection() {
        switch selectedSettingsRow {
        case .theme(let kind):
            state.setTheme(kind)
            exitSettings()
        case .folder(let idx):
            editingFolder = idx
            editingCap = false
        case .addFolder:
            addFolderViaPicker()
        case .hotkey:
            state.setHotkeyUsesCommand(!state.hotkeyUsesCommand)
        case nil:
            break
        }
    }

    private func removeSelectedFolder() {
        guard case .folder(let idx) = selectedSettingsRow,
              state.scanFolders.indices.contains(idx) else { return }
        let folder = state.scanFolders[idx]
        state.removeScanFolder(folder)
        editingFolder = nil
        if settingsIndex >= settingsRows.count { settingsIndex = max(0, settingsRows.count - 1) }
    }

    /// Open the native folder picker (Powerbox grants access — no TCC prompt).
    private func addFolderViaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Index folder"
        panel.title = "Choose a folder to index"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = ScanFolder(name: url.lastPathComponent, path: url)
        state.addScanFolder(folder)
        // Select the newly added row.
        if let idx = state.scanFolders.firstIndex(where: { $0.path == url }) {
            settingsIndex = ThemeKind.allCases.count + idx
        }
    }

    private func openSettings() {
        settingsIndex = ThemeKind.allCases.firstIndex(of: theme.id) ?? 0
        settingsMode = true
        // Key events need a focused responder to reach the panel's key
        // handler; the settings page has no visible text field, so we park
        // focus on its hidden one.
        Task { @MainActor in searchFocused = true }
    }

    private func submitCurrent() {
        guard let r = state.selectedResult else { return }
        onSubmit(r)
    }

    private func revealCurrent() {
        guard let r = state.selectedResult else { return }
        onReveal(r)
    }

    private func submit(_ r: SearchResult) {
        onSubmit(r)
    }

    // MARK: Search page

    private var searchPage: some View {
        VStack(spacing: 0) {
            if theme.showsHeader { headerStrip }

            SearchBar(text: $state.query, theme: theme,
                      showsIcon: theme.showsSearchIcon)
                .focused($searchFocused)
                .onChange(of: state.query) { _, _ in state.selectedIndex = 0 }

            if theme.showsStreak {
                PhotonStreak()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            } else {
                Rectangle()
                    .fill(Color(hex: theme.textHex).opacity(0.10))
                    .frame(height: 1)
            }

            ResultsList(state: state, theme: theme, onSelect: submit)

            if theme.showsFooter {
                footer
            }
        }
        .overlay(alignment: .topTrailing) {
            settingsGear
                .padding(.top, 8)
                .padding(.trailing, 10)
        }
    }

    /// Settings gear pinned top-right. Always visible (including Classic,
    /// which hides the footer) so settings are reachable from every theme.
    private var settingsGear: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: theme.textHex).opacity(0.4))
        }
        .buttonStyle(.plain)
        .help("Settings (⌘,)")
    }

    private var headerStrip: some View {
        HStack {
            Text("PHOTON ⌁")
            Spacer()
            Text("⌥SPACE")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .tracking(1.5)
        .foregroundStyle(Color(hex: theme.accentHex).opacity(0.8))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            footerHint("↑↓", "navigate")
            footerHint("↵", "open")
            footerHint("⇧↵", "reveal")
            footerHint("esc", "close")
            Spacer()
            if state.isScanning {
                Text("scanning…").foregroundStyle(Color(hex: theme.accentHex))
            } else if state.scanFolders.isEmpty {
                // Apps-only nudge: tell users file search is opt-in.
                Button(action: openSettings) {
                    Text("add folders in ⚙ settings")
                        .foregroundStyle(Color(hex: theme.accentHex).opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            } else {
                let count = state.visibleResults.count
                Text("\(count) result\(count == 1 ? "" : "s")")
                    .foregroundStyle(Color(hex: theme.accentHex))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color(hex: theme.textHex).opacity(0.04))
    }

    private func footerHint(_ k: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(k)
                .foregroundStyle(Color(hex: theme.textHex).opacity(0.8))
                .padding(.horizontal, 4)
                .background(Color(hex: theme.textHex).opacity(0.12))
                .cornerRadius(3)
            Text(label)
                .foregroundStyle(Color(hex: theme.textHex).opacity(0.8))
        }
    }

    // MARK: Background

    @ViewBuilder
    private var backgroundView: some View {
        let stroke = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .strokeBorder(Color(hex: theme.borderHex), lineWidth: theme.borderWidth)
        if theme.usesMaterial {
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.55))
                .overlay(stroke)
        } else {
            LinearGradient(colors: [Color(hex: theme.bgTopHex), Color(hex: theme.bgBottomHex)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(stroke)
        }
    }

    // MARK: Settings page

    private var settingsPage: some View {
        VStack(spacing: 0) {
            // Invisible focus anchor so arrow keys reach the key handler.
            TextField("", text: .constant(""))
                .textFieldStyle(.plain)
                .frame(width: 1, height: 1)
                .opacity(0)
                .focused($searchFocused)
                .allowsHitTesting(false)

            HStack {
                Text("Settings")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: theme.textHex))
                Spacer()
                Text("↑↓ move · ↵ open/apply · ⌫ remove · esc done")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(hex: theme.textHex).opacity(0.45))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        settingsSectionHeader("Theme")

                        ForEach(ThemeKind.allCases, id: \.self) { kind in
                            ThemeRow(
                                kind: kind,
                                theme: theme,
                                isSelected: selectedSettingsRow == .theme(kind),
                                isActive: kind == theme.id,
                                onSelect: {
                                    // Mouse click = activate (apply + close),
                                    // same as Return. Arrows only move the cursor.
                                    settingsIndex = ThemeKind.allCases.firstIndex(of: kind) ?? 0
                                    activateSettingsSelection()
                                }
                            )
                            .id(ThemeKind.allCases.firstIndex(of: kind) ?? 0)
                        }

                        settingsSectionHeader("Scan folders")

                        if state.scanFolders.isEmpty {
                            settingsEmptyHint("Apps-only. Add folders to search files.")
                        } else {
                            ForEach(Array(state.scanFolders.enumerated()), id: \.offset) { index, folder in
                                FolderRow(
                                    folder: folder,
                                    theme: theme,
                                    isSelected: selectedSettingsRow == .folder(index),
                                    isEditing: editingFolder == index,
                                    editingCap: editingCap,
                                    onSelect: {
                                        // Click = move cursor only (no theme side effects).
                                        settingsIndex = ThemeKind.allCases.count + index
                                    },
                                    onStartEdit: {
                                        settingsIndex = ThemeKind.allCases.count + index
                                        editingFolder = index
                                        editingCap = false
                                    },
                                    onSetField: { editingCap = $0 },
                                    onRemove: {
                                        state.removeScanFolder(folder)
                                        editingFolder = nil
                                    }
                                )
                                .id(ThemeKind.allCases.count + index)
                            }
                        }

                        SettingsRow(
                            title: "+ Add folder…",
                            subtitle: "native picker · grants access",
                            theme: theme,
                            isSelected: selectedSettingsRow == .addFolder,
                            onSelect: {
                                // Click = activate (open picker), same as Return.
                                settingsIndex = settingsRows.count - 2
                                addFolderViaPicker()
                            }
                        )
                        .id(settingsRows.firstIndex(of: .addFolder) ?? 0)

                        settingsSectionHeader("Hotkey")

                        SettingsRow(
                            title: "⌘Space trigger",
                            subtitle: state.hotkeyUsesCommand
                                ? "on · Spotlight shortcut goes to Photon"
                                : "off · using ⌥Space (default)",
                            theme: theme,
                            isSelected: selectedSettingsRow == .hotkey,
                            onSelect: {
                                settingsIndex = settingsRows.count - 1
                                state.setHotkeyUsesCommand(!state.hotkeyUsesCommand)
                            }
                        )
                        .id(settingsRows.firstIndex(of: .hotkey) ?? 0)
                    }
                }
                .onChange(of: settingsIndex) { _, idx in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }

            Spacer()
        }
    }

    private func settingsSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Color(hex: theme.accentHex).opacity(0.8))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func settingsEmptyHint(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: theme.textHex).opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

// MARK: - PhotonStreak (Carbon Bar flourish)

private struct PhotonStreak: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear,
                             Color(hex: "#7DD3FC").opacity(0.55),
                             Color(hex: "#E0F2FE").opacity(0.9),
                             .clear],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

// MARK: - Settings rows

/// Text color for a row. Fill-type selections (Classic's blue fill, Paper's
/// dark fill) flip the text to `onSelectionHex`; tinted/outline selections keep
/// the theme text color. Mirrors ResultRow's selected-text behavior.
private func settingsTextColor(_ theme: Theme, isSelected: Bool) -> Color {
    if isSelected && (theme.selectionKind == .classicFill || theme.selectionKind == .accentFill) {
        return Color(hex: theme.onSelectionHex)
    }
    return Color(hex: theme.textHex)
}

private func settingsDimColor(_ theme: Theme, isSelected: Bool) -> Color {
    if isSelected && (theme.selectionKind == .classicFill || theme.selectionKind == .accentFill) {
        return Color(hex: theme.onSelectionHex).opacity(0.7)
    }
    return Color(hex: theme.textHex).opacity(0.5)
}

private struct SettingsRow: View {
    let title: String
    let subtitle: String
    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(settingsTextColor(theme, isSelected: isSelected))
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(settingsDimColor(theme, isSelected: isSelected))
            }
            Spacer()
            if isSelected {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(settingsTextColor(theme, isSelected: isSelected))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background {
            SelectionBackground(theme: theme, selected: isSelected)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - ThemeRow (settings mini preview)

private struct ThemeRow: View {
    let kind: ThemeKind
    let theme: Theme
    let isSelected: Bool
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ThemeSwatch(theme: Theme.theme(kind))
                .frame(width: 64, height: 40)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(hex: theme.borderHex), lineWidth: 1)
                )
            Text(kind.displayName)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(settingsTextColor(theme, isSelected: isSelected))
            Spacer()
            // The applied theme (distinct from the cursor): a checkmark.
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(hex: theme.accentHex))
            } else if isSelected {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(settingsTextColor(theme, isSelected: isSelected))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background {
            SelectionBackground(theme: theme, selected: isSelected)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - FolderRow (scan folder with inline limits)

private struct FolderRow: View {
    let folder: ScanFolder
    let theme: Theme
    let isSelected: Bool
    let isEditing: Bool
    let editingCap: Bool
    let onSelect: () -> Void
    let onStartEdit: () -> Void
    let onSetField: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(settingsDimColor(theme, isSelected: isSelected))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(settingsTextColor(theme, isSelected: isSelected))
                        .lineLimit(1)
                    Text(folder.path.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(settingsDimColor(theme, isSelected: isSelected))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("d\(folder.depth) · c\(folder.fileCap)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(settingsDimColor(theme, isSelected: isSelected))
                if isSelected {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(settingsTextColor(theme, isSelected: isSelected))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background {
                SelectionBackground(theme: theme, selected: isSelected)
            }
            .contentShape(Rectangle())
            .onTapGesture { if isSelected { onStartEdit() } else { onSelect() } }

            if isEditing {
                HStack(spacing: 18) {
                    LimitField(label: "depth", value: folder.depth,
                               active: !editingCap, theme: theme, onTap: { onSetField(false) })
                    LimitField(label: "cap", value: folder.fileCap,
                               active: editingCap, theme: theme, onTap: { onSetField(true) })
                    Spacer()
                    Text("◀▶ field · ↑↓ value · esc done")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(hex: theme.textHex).opacity(0.4))
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .foregroundStyle(Color(hex: theme.textHex).opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Remove folder (⌫)")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color(hex: theme.textHex).opacity(0.04))
            }
        }
    }
}

private struct LimitField: View {
    let label: String
    let value: Int
    let active: Bool
    let theme: Theme
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: theme.textHex).opacity(0.5))
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? Color(hex: theme.accentHex) : Color(hex: theme.textHex))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(active ? Color(hex: theme.accentHex).opacity(0.7) : Color(hex: theme.textHex).opacity(0.12),
                                      lineWidth: 1)
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - ThemeSwatch (settings mini preview)

private struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: theme.bgTopHex), Color(hex: theme.bgBottomHex)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: theme.textHex).opacity(0.5))
                    .frame(width: 34, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: theme.selectionHex).opacity(theme.selectionTintAlpha))
                    .frame(width: 46, height: 9)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: theme.textHex).opacity(0.25))
                    .frame(width: 40, height: 4)
            }
        }
    }
}

// MARK: - SearchBar

private struct SearchBar: View {
    @Binding var text: String
    let theme: Theme
    let showsIcon: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsIcon {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color(hex: theme.textHex).opacity(0.45))
                    .frame(width: 20)
            }

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: theme.queryFontSize,
                              weight: .named(theme.queryFontWeight),
                              design: theme.queryIsMono ? .monospaced : .default))
                .foregroundStyle(Color(hex: theme.textHex))
                .tint(Color(hex: theme.accentHex))
                .disableAutocorrection(true)
                .overlay(alignment: .leading) {
                    if text.isEmpty {
                        Text("Search apps & files")
                            .font(.system(size: theme.queryFontSize,
                                          weight: .named(theme.queryFontWeight),
                                          design: theme.queryIsMono ? .monospaced : .default))
                            .foregroundStyle(Color(hex: theme.textHex).opacity(0.5))
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - ResultsList

private struct ResultsList: View {
    @ObservedObject var state: ScanState
    let theme: Theme
    let onSelect: (SearchResult) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.visibleResults.enumerated()), id: \.element.id) { index, result in
                        ResultRow(
                            result: result,
                            theme: theme,
                            isSelected: index == state.selectedIndex,
                            slotNumber: (state.query.isEmpty && index < 9) ? index + 1 : nil
                        )
                        .tag(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.selectedIndex = index
                            onSelect(result)
                        }
                        if theme.usesDottedDividers {
                            DashedDivider(color: Color(hex: theme.textHex).opacity(0.07))
                        }
                    }
                }
                .onChange(of: state.selectedIndex) { _, index in
                    let visible = state.visibleResults
                    guard index < visible.count else { return }
                    proxy.scrollTo(visible[index].id, anchor: .center)
                }
            }
        }
    }
}

private struct DashedDivider: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: geo.size.width, y: 0))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        .frame(height: 1)
    }
}

// MARK: - ResultRow

private struct ResultRow: View {
    let result: SearchResult
    let theme: Theme
    let isSelected: Bool
    let slotNumber: Int?

    @State private var icon: NSImage? = nil

    private var nameColor: Color {
        if isSelected {
            return theme.selectionKind == .classicFill || theme.selectionKind == .accentFill
                ? Color(hex: theme.onSelectionHex)
                : Color(hex: theme.textHex)
        }
        if result.kind == .calculator, theme.id != .classic {
            return Color(hex: theme.calculatorAccentHex)
        }
        return Color(hex: theme.textHex)
    }

    private var pathColor: Color {
        if isSelected && (theme.selectionKind == .classicFill || theme.selectionKind == .accentFill) {
            return Color(hex: theme.onSelectionHex).opacity(0.65)
        }
        return Color(hex: theme.textHex).opacity(theme.pathAlpha)
    }

    private var chipColor: Color {
        if isSelected && (theme.selectionKind == .classicFill || theme.selectionKind == .accentFill) {
            return Color(hex: theme.onSelectionHex).opacity(0.7)
        }
        return Color(hex: theme.textHex).opacity(0.4)
    }

    var body: some View {
        HStack(spacing: 12) {
            (icon.map { Image(nsImage: $0) }
             ?? Image(systemName: result.kind == .directory ? "folder" : "doc"))
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .frame(width: theme.iconSize, height: theme.iconSize)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: theme.nameFontSize,
                                  weight: .named(isSelected && theme.selectionKind == .accentFill
                                                ? "semibold" : theme.nameFontWeight),
                                  design: theme.nameIsMono ? .monospaced : .default))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                Text(result.path.path)
                    .font(.system(size: theme.pathFontSize, design: .monospaced))
                    .foregroundStyle(pathColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if let slotNumber {
                Text("⌘\(slotNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(chipColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: theme.textHex).opacity(0.07))
                    )
            }

            if let size = result.displaySize {
                Text(size)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isSelected ? Color(hex: theme.onSelectionHex).opacity(0.8) : Color(hex: theme.textHex).opacity(0.55))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background {
            SelectionBackground(theme: theme, selected: isSelected)
        }
        .onAppear {
            guard icon == nil else { return }
            icon = result.makeIcon()
        }
    }
}

// MARK: - SelectionBackground

private struct SelectionBackground: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        if !selected {
            Color.clear
        } else {
            switch theme.selectionKind {
            case .classicFill:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: theme.selectionHex).opacity(theme.selectionTintAlpha))
                    .padding(.horizontal, 4)
            case .accentFill:
                Rectangle()
                    .fill(Color(hex: theme.selectionHex).opacity(theme.selectionTintAlpha))
            case .accentBar:
                Rectangle()
                    .fill(Color(hex: theme.selectionHex).opacity(theme.selectionTintAlpha))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color(hex: theme.selectionHex))
                            .frame(width: 3)
                            .padding(.vertical, 6)
                            .shadow(color: Color(hex: theme.selectionHex).opacity(0.55), radius: 6)
                    }
            case .outline:
                Rectangle()
                    .fill(Color(hex: theme.selectionHex).opacity(theme.selectionTintAlpha))
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color(hex: theme.selectionHex).opacity(0.5), lineWidth: 1)
                    )
            }
        }
    }
}
