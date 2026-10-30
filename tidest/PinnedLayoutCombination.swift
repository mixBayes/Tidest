import AppKit

/// A single shelf item keeps the grid and the exact reopen target for each cell.
nonisolated struct SavedPinnedCombination: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    let root: LayoutRegion
    var windows: [UUID: SavedPinnedWindow]
    let displayID: UInt32
    let width: Double
    let height: Double

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            root.isValid && Set(root.leafIDs) == Set(windows.keys) &&
            Set(windows.values.map(\.id)).count == windows.count &&
            width.isFinite && height.isFinite && width > 0 && height > 0
    }

    func requests(using choices: [UUID: LayoutWindowChoice], on display: LayoutDisplay) -> [(LayoutWindowChoice, CGRect)] {
        root.placements(in: display.layoutArea, scale: display.scale).compactMap { placement in
            guard let choice = choices[placement.region.id] else { return nil }
            return (choice, placement.frame)
        }
    }
}

nonisolated enum SavedPinnedItem: Codable, Equatable, Sendable {
    case window(SavedPinnedWindow)
    case combination(SavedPinnedCombination)
}

@MainActor
struct LayoutCombinationSnapshot {
    let root: LayoutRegion
    let windows: [UUID: WindowItem]
    let display: LayoutDisplay
}
