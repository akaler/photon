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
        .frame(width: 720, height: 460)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .frame(width: 20)

            TextField(isScanning ? "Scanning…" : "Search apps & files", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .light))
                .disableAutocorrection(true)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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
                .frame(width: 26, height: 26)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.name).font(.system(size: 16))
                    .lineLimit(1)
                Text(result.path.path)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let size = result.displaySize {
                Text(size)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.9))
            } else {
                Color.clear
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}
