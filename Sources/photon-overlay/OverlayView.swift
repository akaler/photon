import SwiftUI
import AppKit
import PhotonCore

struct OverlayView: View {
    @ObservedObject var state: ScanState
    let onSubmit: (SearchResult) -> Void
    let onReveal: (SearchResult) -> Void
    let onReindex: () -> Void
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(text: $state.query, isScanning: state.isScanning)
                .focused($searchFocused)
                .onChange(of: state.query) { _, _ in state.selectedIndex = 0 }

            Divider()

            ResultsList(state: state, onSelect: onSubmit, onReveal: onReveal)
        }
        .frame(width: 560, height: 360)
        .background(Color(NSColor.windowBackgroundColor))
        .onKeyPress(.upArrow)    { state.moveUp();    return .handled }
        .onKeyPress(.downArrow)  { state.moveDown();  return .handled }
        .onKeyPress(.escape)     { onClose();          return .handled }
        .onKeyPress(.return)      {
            if NSEvent.modifierFlags.contains(.shift) { revealCurrent() }
            else { submitCurrent() }
            return .handled
        }
        .task {
            searchFocused = true
            if state.results.isEmpty { state.scan() }
        }
    }

    private func submitCurrent() {
        guard let r = state.selectedResult else { return }
        onSubmit(r)
    }

    private func revealCurrent() {
        guard let r = state.selectedResult else { return }
        onReveal(r)
    }
}

// MARK: - SearchBar

private struct SearchBar: View {
    @Binding var text: String
    let isScanning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isScanning ? "circle.dotted" : "magnifyingglass")
                .symbolEffect(.variableColor.iterative, isActive: isScanning)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            TextField(isScanning ? "Scanning…" : "Search apps & files", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .light))
                .disableAutocorrection(true)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - ResultsList

private struct ResultsList: View {
    @ObservedObject var state: ScanState
    let onSelect: (SearchResult) -> Void
    let onReveal: (SearchResult) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.visibleResults.enumerated()), id: \.element.id) { index, result in
                        ResultRow(result: result, isSelected: index == state.selectedIndex)
                            .tag(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                state.selectedIndex = index
                                onSelect(result)
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

private struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            (result.icon.map { Image(nsImage: $0) }
             ?? Image(systemName: result.kind == .directory ? "folder" : "doc"))
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .frame(width: 20, height: 20)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.name).font(.system(size: 14))
                    .lineLimit(1)
                Text(result.path.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let size = result.displaySize {
                Text(size)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.9) : .clear)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}
