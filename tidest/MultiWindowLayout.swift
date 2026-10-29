import Foundation

nonisolated enum LayoutSplitAxis: String, Codable, Sendable {
    case columns, rows
}

/// Only structure and normalized ratios are persisted. No window or display identity belongs here.
nonisolated indirect enum LayoutRegion: Codable, Equatable, Sendable {
    case leaf(UUID)
    case split(UUID, LayoutSplitAxis, Double, LayoutRegion, LayoutRegion)

    var id: UUID {
        switch self {
        case .leaf(let id), .split(let id, _, _, _, _): id
        }
    }

    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, _, let first, let second): first.leafIDs + second.leafIDs
        }
    }

    func region(_ identifier: UUID) -> LayoutRegion? {
        if id == identifier { return self }
        guard case .split(_, _, _, let first, let second) = self else { return nil }
        return first.region(identifier) ?? second.region(identifier)
    }

    func parent(of identifier: UUID) -> LayoutRegion? {
        guard case .split(_, _, _, let first, let second) = self else { return nil }
        if first.id == identifier || second.id == identifier { return self }
        return first.parent(of: identifier) ?? second.parent(of: identifier)
    }

    func replacing(_ identifier: UUID, with replacement: LayoutRegion) -> LayoutRegion {
        if id == identifier { return replacement }
        guard case .split(let id, let axis, let ratio, let first, let second) = self else { return self }
        return .split(id, axis, ratio, first.replacing(identifier, with: replacement),
                      second.replacing(identifier, with: replacement))
    }

    struct Placement: Equatable, Sendable {
        let region: LayoutRegion
        let frame: CGRect
    }

    /// Top-left coordinates, shared by the preview and Accessibility execution.
    func placements(in frame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), scale: Double? = nil) -> [Placement] {
        let current = Placement(region: self, frame: frame)
        guard case .split(_, let axis, let ratio, let first, let second) = self else { return [current] }
        var boundary = axis == .columns ? frame.minX + frame.width * ratio : frame.minY + frame.height * ratio
        if let scale, scale.isFinite, scale > 0 { boundary = (boundary * scale).rounded() / scale }
        let firstFrame: CGRect
        let secondFrame: CGRect
        if axis == .columns {
            firstFrame = CGRect(x: frame.minX, y: frame.minY, width: boundary - frame.minX, height: frame.height)
            secondFrame = CGRect(x: boundary, y: frame.minY, width: frame.maxX - boundary, height: frame.height)
        } else {
            firstFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: boundary - frame.minY)
            secondFrame = CGRect(x: frame.minX, y: boundary, width: frame.width, height: frame.maxY - boundary)
        }
        return [current] + first.placements(in: firstFrame, scale: scale) + second.placements(in: secondFrame, scale: scale)
    }

    var leaves: [Placement] {
        placements().filter { if case .leaf = $0.region { return true }; return false }.sorted {
            abs($0.frame.minY - $1.frame.minY) < 0.000001 ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
    }

    /// Bound saved input and editing complexity; reject malformed templates instead of repairing them silently.
    var isValid: Bool {
        var identifiers = Set<UUID>()
        func check(_ region: LayoutRegion, depth: Int) -> Bool {
            guard depth <= 64, identifiers.count < 8192, identifiers.insert(region.id).inserted else { return false }
            switch region {
            case .leaf: return true
            case .split(_, _, let ratio, let first, let second):
                return ratio.isFinite && (0.1...0.9).contains(ratio) && check(first, depth: depth + 1) && check(second, depth: depth + 1)
            }
        }
        return check(self, depth: 0)
    }

    func fits(minimumSize: CGSize) -> Bool {
        leaves.allSatisfy { $0.frame.width + 0.000001 >= minimumSize.width && $0.frame.height + 0.000001 >= minimumSize.height }
    }

    /// Move touching, collinear dividers together (including the two halves of a four-cell grid).
    func resizing(_ identifier: UUID, ratio requested: Double, minimumSize: CGSize = .zero) -> LayoutRegion {
        guard requested.isFinite,
              let source = placements().first(where: { $0.region.id == identifier }),
              case .split(_, let axis, let oldRatio, _, _) = source.region else { return self }
        func start(_ rect: CGRect) -> Double { axis == .columns ? rect.minX : rect.minY }
        func length(_ rect: CGRect) -> Double { axis == .columns ? rect.width : rect.height }
        let oldPosition = start(source.frame) + length(source.frame) * oldRatio
        var linked = [source]
        let candidates = placements().filter {
            guard case .split(_, let otherAxis, let ratio, _, _) = $0.region, otherAxis == axis else { return false }
            return abs(start($0.frame) + length($0.frame) * ratio - oldPosition) < 0.000001
        }
        // Connect only segments that touch; a separate divider elsewhere need not follow.
        for _ in candidates.indices {
            for candidate in candidates where !linked.contains(where: { $0.region.id == candidate.region.id }) {
                if linked.contains(where: {
                    axis == .columns
                        ? candidate.frame.minY <= $0.frame.maxY + 0.000001 && candidate.frame.maxY >= $0.frame.minY - 0.000001
                        : candidate.frame.minX <= $0.frame.maxX + 0.000001 && candidate.frame.maxX >= $0.frame.minX - 0.000001
                }) { linked.append(candidate) }
            }
        }
        let lower = linked.map { start($0.frame) + length($0.frame) * 0.1 }.max()!
        let upper = linked.map { start($0.frame) + length($0.frame) * 0.9 }.min()!
        var position = start(source.frame) + length(source.frame) * requested
        // Useful proportional stops, plus existing parallel boundaries.
        var stops = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75].map { start(source.frame) + length(source.frame) * $0 }
        stops += placements().compactMap {
            guard case .split(let id, let otherAxis, let ratio, _, _) = $0.region,
                  otherAxis == axis, !linked.contains(where: { $0.region.id == id }) else { return nil }
            return start($0.frame) + length($0.frame) * ratio
        }
        if let stop = stops.min(by: { abs($0 - position) < abs($1 - position) }), abs(stop - position) < 0.012 {
            position = stop
        }
        position = min(upper, max(lower, position))
        var result = self
        for placement in linked {
            guard case .split(let id, let splitAxis, _, let first, let second) = placement.region else { continue }
            result = result.replacing(id, with: .split(id, splitAxis, (position - start(placement.frame)) / length(placement.frame), first, second))
        }
        return result.isValid && result.fits(minimumSize: minimumSize) ? result : self
    }
}

nonisolated enum LayoutStartingPoint: String, CaseIterable, Identifiable {
    case columns, rows, largeLeft, grid
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .columns: "左右两栏"
        case .rows: "上下两栏"
        case .largeLeft: "左大右两小"
        case .grid: "四宫格"
        }
    }
    func makeRegion() -> LayoutRegion {
        func leaf() -> LayoutRegion { .leaf(UUID()) }
        func rows() -> LayoutRegion { .split(UUID(), .rows, 0.5, leaf(), leaf()) }
        switch self {
        case .columns: return .split(UUID(), .columns, 0.5, leaf(), leaf())
        case .rows: return rows()
        case .largeLeft: return .split(UUID(), .columns, 2.0 / 3, leaf(), rows())
        case .grid: return .split(UUID(), .columns, 0.5, rows(), rows())
        }
    }
}

nonisolated struct LayoutTemplate: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var root: LayoutRegion
}

/// The application and its retries share one undo baseline. A new successful no-op
/// consumes the previous baseline too, while a preflight rejection leaves it intact.
nonisolated struct LayoutUndoHistory<Entry: Identifiable & Sendable>: Sendable where Entry.ID: Sendable {
    private(set) var originals: [Entry] = []
    private var hasAttemptedApplication = false

    mutating func beginDraft() { hasAttemptedApplication = false }

    /// Returns whether this result replaces the previous application's undo record.
    @discardableResult
    mutating func recordApplication(_ changedOrUncertain: [Entry], hasSuccessfulResults: Bool) -> Bool {
        guard !changedOrUncertain.isEmpty || hasSuccessfulResults else { return false }
        let replacing = !hasAttemptedApplication
        if replacing { originals = [] }
        for entry in changedOrUncertain where !originals.contains(where: { $0.id == entry.id }) {
            originals.append(entry)
        }
        hasAttemptedApplication = true
        return replacing
    }

    mutating func recordRestoration(successfulIDs: Set<Entry.ID>) {
        originals.removeAll { successfulIDs.contains($0.id) }
        hasAttemptedApplication = false
    }
}

nonisolated struct MultiWindowLayoutDraft: Equatable, Sendable {
    private(set) var root: LayoutRegion
    private(set) var assignments: [UUID: UUID] = [:]
    var selectedRegion: UUID?
    private var history: [Snapshot] = []
    private struct Snapshot: Equatable, Sendable {
        let root: LayoutRegion
        let assignments: [UUID: UUID]
        let selectedRegion: UUID?
    }

    init(root: LayoutRegion) {
        self.root = root
        selectedRegion = root.leafIDs.first
    }

    var canUndo: Bool { !history.isEmpty }
    var isComplete: Bool {
        root.isValid && root.leafIDs.allSatisfy { assignments[$0] != nil } &&
            Set(assignments.values).count == root.leafIDs.count
    }
    var mergeRegion: LayoutRegion? {
        guard let parent = selectedRegion.flatMap({ root.parent(of: $0) }),
              case .split(_, _, _, .leaf, .leaf) = parent else { return nil }
        return parent
    }

    mutating func checkpoint() {
        history.append(Snapshot(root: root, assignments: assignments, selectedRegion: selectedRegion))
        if history.count > 50 { history.removeFirst() }
    }

    mutating func undo() {
        guard let previous = history.popLast() else { return }
        root = previous.root
        assignments = previous.assignments
        selectedRegion = previous.selectedRegion
    }

    mutating func replace(with region: LayoutRegion) {
        guard region.isValid else { return }
        checkpoint()
        root = region
        assignments = [:]
        selectedRegion = region.leafIDs.first
    }

    @discardableResult
    mutating func assign(_ window: UUID?, to region: UUID) -> Bool {
        guard root.leafIDs.contains(region), window == nil || !assignments.contains(where: { $0.key != region && $0.value == window }) else { return false }
        checkpoint()
        assignments[region] = window
        return true
    }

    @discardableResult
    mutating func split(_ axis: LayoutSplitAxis, confirmed: Bool = false, minimumSize: CGSize = .zero) -> Bool {
        guard let selectedRegion, root.leafIDs.contains(selectedRegion),
              confirmed || assignments[selectedRegion] == nil else { return false }
        let first = UUID(), second = UUID()
        let replacement = LayoutRegion.split(selectedRegion, axis, 0.5, .leaf(first), .leaf(second))
        let updated = root.replacing(selectedRegion, with: replacement)
        guard updated.isValid, updated.fits(minimumSize: minimumSize) else { return false }
        checkpoint()
        assignments[selectedRegion] = nil
        root = updated
        self.selectedRegion = first
        return true
    }

    @discardableResult
    mutating func merge(confirmed: Bool = false) -> Bool {
        guard let parent = mergeRegion,
              confirmed || parent.leafIDs.allSatisfy({ assignments[$0] == nil }) else { return false }
        checkpoint()
        for id in parent.leafIDs { assignments[id] = nil }
        root = root.replacing(parent.id, with: .leaf(parent.id))
        selectedRegion = parent.id
        return true
    }

    /// A continuous drag makes one history entry, supplied by the caller at drag start.
    mutating func resize(_ split: UUID, ratio: Double, minimumSize: CGSize = .zero) {
        root = root.resizing(split, ratio: ratio, minimumSize: minimumSize)
    }
}
