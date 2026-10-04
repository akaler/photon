import Foundation

/// The selectable skins for the Photon overlay.
public enum ThemeKind: String, Codable, CaseIterable, Sendable {
    case classic
    case carbonBar
    case carbonSolid
    case schematic
    case paper

    public var displayName: String {
        switch self {
        case .classic:     return "Classic"
        case .carbonBar:   return "Carbon Bar"
        case .carbonSolid: return "Carbon Solid"
        case .schematic:   return "Schematic"
        case .paper:       return "Paper"
        }
    }
}

/// How a result row communicates selection.
public enum SelectionKind: String, Codable, Sendable {
    case classicFill // blue rounded fill, margin (original look)
    case accentFill  // full-width solid fill, text flips to onSelection
    case accentBar   // tinted row + accent bar on the leading edge
    case outline     // inset stroke
}

/// Pure data describing one skin. PhotonCore is Foundation-only, so colors
/// travel as hex strings; the overlay converts them to SwiftUI Colors.
public struct Theme: Sendable, Equatable {
    public let id: ThemeKind

    // Surface
    public let usesMaterial: Bool
    public let bgTopHex: String
    public let bgBottomHex: String
    public let borderHex: String
    public let borderWidth: Double
    public let cornerRadius: Double

    // Typography
    public let queryFontSize: Double
    public let queryFontWeight: String // "light" | "regular" | "medium"
    public let queryIsMono: Bool
    public let nameFontSize: Double
    public let nameFontWeight: String  // "regular" | "medium" | "semibold"
    public let nameIsMono: Bool
    public let pathFontSize: Double
    public let pathIsMono: Bool
    public let pathAlpha: Double
    public let iconSize: Double

    // Color roles
    public let textHex: String
    public let textDimAlpha: Double
    public let accentHex: String
    public let calculatorAccentHex: String

    // Selection
    public let selectionKind: SelectionKind
    public let selectionHex: String
    public let onSelectionHex: String
    public let selectionTintAlpha: Double

    // Chrome
    public let showsFooter: Bool
    public let showsSearchIcon: Bool
    public let showsHeader: Bool
    public let showsStreak: Bool
    public let usesDottedDividers: Bool
    public let showsSlotChips: Bool

    public static func theme(_ kind: ThemeKind) -> Theme {
        switch kind {
        case .classic:
            return Theme(
                id: .classic,
                usesMaterial: true,
                bgTopHex: "#1C1E26", bgBottomHex: "#141519",
                borderHex: "#FFFFFF17", borderWidth: 1, cornerRadius: 18,
                queryFontSize: 24, queryFontWeight: "light", queryIsMono: false,
                nameFontSize: 16, nameFontWeight: "regular", nameIsMono: false,
                pathFontSize: 12, pathIsMono: false, pathAlpha: 0.55, iconSize: 26,
                textHex: "#F2F2F4", textDimAlpha: 0.55,
                accentHex: "#0A6EEB", calculatorAccentHex: "#F2F2F4",
                selectionKind: .classicFill,
                selectionHex: "#0A6EEB", onSelectionHex: "#FFFFFF", selectionTintAlpha: 0.9,
                showsFooter: false, showsSearchIcon: true,
                showsHeader: false, showsStreak: false,
                usesDottedDividers: false, showsSlotChips: false
            )
        case .carbonBar:
            return Theme(
                id: .carbonBar,
                usesMaterial: false,
                bgTopHex: "#10131F", bgBottomHex: "#0B0E17",
                borderHex: "#FFFFFF14", borderWidth: 1, cornerRadius: 10,
                queryFontSize: 28, queryFontWeight: "medium", queryIsMono: false,
                nameFontSize: 18, nameFontWeight: "medium", nameIsMono: false,
                pathFontSize: 12.5, pathIsMono: true, pathAlpha: 0.5, iconSize: 28,
                textHex: "#E6EDF5", textDimAlpha: 0.5,
                accentHex: "#7DD3FC", calculatorAccentHex: "#7DD3FC",
                selectionKind: .accentBar,
                selectionHex: "#7DD3FC", onSelectionHex: "#06121C", selectionTintAlpha: 0.09,
                showsFooter: true, showsSearchIcon: false,
                showsHeader: false, showsStreak: true,
                usesDottedDividers: false, showsSlotChips: true
            )
        case .carbonSolid:
            return Theme(
                id: .carbonSolid,
                usesMaterial: false,
                bgTopHex: "#0B0E17", bgBottomHex: "#0B0E17",
                borderHex: "#FFFFFF14", borderWidth: 1, cornerRadius: 10,
                queryFontSize: 28, queryFontWeight: "medium", queryIsMono: false,
                nameFontSize: 18, nameFontWeight: "medium", nameIsMono: false,
                pathFontSize: 12.5, pathIsMono: true, pathAlpha: 0.5, iconSize: 28,
                textHex: "#E0F2FE", textDimAlpha: 0.5,
                accentHex: "#7DD3FC", calculatorAccentHex: "#7DD3FC",
                selectionKind: .accentFill,
                selectionHex: "#7DD3FC", onSelectionHex: "#06121C", selectionTintAlpha: 1.0,
                showsFooter: true, showsSearchIcon: false,
                showsHeader: false, showsStreak: false,
                usesDottedDividers: false, showsSlotChips: true
            )
        case .schematic:
            return Theme(
                id: .schematic,
                usesMaterial: false,
                bgTopHex: "#07090D", bgBottomHex: "#07090D",
                borderHex: "#7DD3FC2E", borderWidth: 1, cornerRadius: 4,
                queryFontSize: 22, queryFontWeight: "regular", queryIsMono: true,
                nameFontSize: 15, nameFontWeight: "regular", nameIsMono: true,
                pathFontSize: 11.5, pathIsMono: true, pathAlpha: 0.55, iconSize: 26,
                textHex: "#DCE8F2", textDimAlpha: 0.55,
                accentHex: "#7DD3FC", calculatorAccentHex: "#7DD3FC",
                selectionKind: .outline,
                selectionHex: "#7DD3FC", onSelectionHex: "#DCE8F2", selectionTintAlpha: 0.05,
                showsFooter: true, showsSearchIcon: false,
                showsHeader: false, showsStreak: false,
                usesDottedDividers: true, showsSlotChips: true
            )
        case .paper:
            return Theme(
                id: .paper,
                usesMaterial: false,
                bgTopHex: "#FFFFFF", bgBottomHex: "#FFFFFF",
                borderHex: "#E5E8EE", borderWidth: 1, cornerRadius: 10,
                queryFontSize: 26, queryFontWeight: "medium", queryIsMono: false,
                nameFontSize: 18, nameFontWeight: "medium", nameIsMono: false,
                pathFontSize: 12.5, pathIsMono: true, pathAlpha: 0.62, iconSize: 28,
                textHex: "#111827", textDimAlpha: 0.62,
                accentHex: "#0274A8", calculatorAccentHex: "#0274A8",
                selectionKind: .accentFill,
                selectionHex: "#10131F", onSelectionHex: "#FFFFFF", selectionTintAlpha: 1.0,
                showsFooter: true, showsSearchIcon: false,
                showsHeader: false, showsStreak: false,
                usesDottedDividers: false, showsSlotChips: true
            )
        }
    }
}

extension ThemeKind: Identifiable {
    public var id: String { rawValue }
}
