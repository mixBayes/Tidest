import CoreGraphics
import Foundation
import XCTest
@testable import tidest

final class MultiWindowLayoutTests: XCTestCase {
    private struct Original: Identifiable, Equatable, Sendable {
        let id: UUID
        let frame: CGRect
    }

    func testSuccessfulNoOpApplicationCannotUndoAnOlderLayout() {
        var history = LayoutUndoHistory<Original>()
        let older = Original(id: UUID(), frame: CGRect(x: 10, y: 20, width: 800, height: 600))
        history.recordApplication([older], hasSuccessfulResults: true)
        XCTAssertEqual(history.originals, [older])
        history.beginDraft()
        // The next application succeeded, but all windows were already in place.
        XCTAssertTrue(history.recordApplication([], hasSuccessfulResults: true))
        XCTAssertTrue(history.originals.isEmpty, "Undo must never restore the earlier unrelated layout")
    }

    func testRejectedPreflightKeepsThePreviousUndoAvailable() {
        var history = LayoutUndoHistory<Original>()
        let older = Original(id: UUID(), frame: CGRect(x: 10, y: 20, width: 800, height: 600))
        history.recordApplication([older], hasSuccessfulResults: true)
        history.beginDraft()
        XCTAssertFalse(history.recordApplication([], hasSuccessfulResults: false))
        XCTAssertEqual(history.originals, [older])
    }

    func testFailureAndRetryKeepTheFirstGeometryForEveryAttemptedWindow() {
        var history = LayoutUndoHistory<Original>()
        let first = Original(id: UUID(), frame: CGRect(x: 10, y: 20, width: 800, height: 600))
        let second = Original(id: UUID(), frame: CGRect(x: 900, y: 20, width: 800, height: 600))
        history.recordApplication([first], hasSuccessfulResults: false)
        let later = Original(id: first.id, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(history.recordApplication([later, second], hasSuccessfulResults: true))
        XCTAssertEqual(history.originals, [first, second], "Retry must not overwrite the original pre-application baseline")
    }

    func testPartialRestorationKeepsOnlyUnrestoredWindows() {
        var history = LayoutUndoHistory<Original>()
        let first = Original(id: UUID(), frame: CGRect(x: 10, y: 20, width: 800, height: 600))
        let second = Original(id: UUID(), frame: CGRect(x: 900, y: 20, width: 800, height: 600))
        history.recordApplication([first, second], hasSuccessfulResults: true)
        history.recordRestoration(successfulIDs: [first.id])
        XCTAssertEqual(history.originals, [second])
        history.recordRestoration(successfulIDs: [second.id])
        XCTAssertTrue(history.originals.isEmpty)
    }

    func testExactlyFourStartingStructuresAndSeparateBlankEntry() {
        XCTAssertEqual(LayoutStartingPoint.allCases.map(\.rawValue), ["columns", "rows", "largeLeft", "grid"])
        XCTAssertEqual(LayoutStartingPoint.allCases.map { $0.makeRegion().leafIDs.count }, [2, 2, 3, 4])
        XCTAssertEqual(LayoutRegion.leaf(UUID()).leafIDs.count, 1)
    }

    func testStartingLayoutsTileOffsetPortraitAndLandscapeAreas() {
        for area in [CGRect(x: -1512, y: -900, width: 1512, height: 876),
                     CGRect(x: 1200, y: 24, width: 900, height: 1576),
                     CGRect(x: 0, y: 24, width: 1728, height: 1053)] {
            for start in LayoutStartingPoint.allCases { assertTiling(start.makeRegion(), in: area) }
        }
    }

    func testLargeLeftStartsAtTwoThirds() {
        let root = LayoutStartingPoint.largeLeft.makeRegion()
        XCTAssertEqual(root.leaves[0].frame.width, 2.0 / 3, accuracy: 0.000001)
    }

    func testPixelRoundingSharesBoundariesWithoutAccumulatedGaps() {
        let area = CGRect(x: -1511, y: 24, width: 1511, height: 877)
        let initial = LayoutStartingPoint.grid.makeRegion()
        let root = initial.resizing(initial.id, ratio: 0.63)
        for scale in [1.0, 2.0] {
            let frames = root.placements(in: area, scale: scale).filter {
                if case .leaf = $0.region { return true }; return false
            }.map(\.frame)
            XCTAssertEqual(frames.reduce(0) { $0 + $1.width * $1.height }, area.width * area.height, accuracy: 0.000001)
            for frame in frames {
                for edge in [frame.minX, frame.maxX, frame.minY, frame.maxY] {
                    XCTAssertEqual(edge * scale, (edge * scale).rounded(), accuracy: 0.000001)
                }
            }
        }
    }

    func testSplittingAddsAnEmptyRegionAtTheClickedEdgeAndKeepsAllWindows() throws {
        let cases: [(LayoutSplitEdge, CGRect, CGRect)] = [
            (.left, CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
            (.right, CGRect(x: 0.5, y: 0, width: 0.5, height: 1), CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            (.top, CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)),
            (.bottom, CGRect(x: 0, y: 0.5, width: 1, height: 0.5), CGRect(x: 0, y: 0, width: 1, height: 0.5))
        ]
        for (edge, emptyFrame, retainedFrame) in cases {
            var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
            let ids = draft.root.leafIDs
            let first = UUID(), second = UUID()
            XCTAssertTrue(draft.assign(first, to: ids[0]))
            XCTAssertTrue(draft.assign(second, to: ids[1]))
            draft.selectedRegion = ids[0]
            let before = draft

            XCTAssertTrue(draft.split(edge), edge.rawValue)
            let children = try XCTUnwrap(draft.root.region(ids[0])).leaves
            let empty = try XCTUnwrap(children.first { draft.assignments[$0.region.id] == nil })
            let retained = try XCTUnwrap(children.first { draft.assignments[$0.region.id] == first })
            XCTAssertEqual(empty.frame, emptyFrame, edge.rawValue)
            XCTAssertEqual(retained.frame, retainedFrame, edge.rawValue)
            XCTAssertEqual(draft.selectedRegion, retained.region.id)
            XCTAssertNil(draft.assignments[ids[0]])
            XCTAssertEqual(draft.assignments[ids[1]], second)
            XCTAssertEqual(draft.assignments.count, 2)
            XCTAssertFalse(draft.isComplete)
            XCTAssertFalse(draft.assign(first, to: empty.region.id), "The retained window cannot be assigned twice")
            assertTiling(draft.root)
            draft.undo()
            XCTAssertEqual(draft, before)
        }
    }

    func testRepeatedSplitsKeepTheOriginalWindowAndRejectedSplitsLeaveTheDraftUntouched() throws {
        var draft = MultiWindowLayoutDraft(root: .leaf(UUID()))
        let window = UUID()
        draft.assign(window, to: draft.root.id)
        let original = draft
        let edges: [LayoutSplitEdge] = [.left, .top, .right, .bottom]
        for edge in edges {
            XCTAssertTrue(draft.split(edge, minimumSize: CGSize(width: 0.2, height: 0.2)))
            let selected = try XCTUnwrap(draft.selectedRegion)
            XCTAssertEqual(draft.assignments, [selected: window])
        }
        let beforeRejectedSplit = draft
        for edge in edges {
            XCTAssertFalse(draft.split(edge, minimumSize: CGSize(width: 0.2, height: 0.2)))
            XCTAssertEqual(draft, beforeRejectedSplit)
        }
        for _ in edges { draft.undo() }
        XCTAssertEqual(draft, original)
    }

    func testMergeRequiresConfirmationAndClearsOnlySiblingChoices() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.largeLeft.makeRegion())
        let ids = draft.root.leafIDs
        let windows = [UUID(), UUID(), UUID()]
        for (region, window) in zip(ids, windows) { XCTAssertTrue(draft.assign(window, to: region)) }
        draft.selectedRegion = ids[1]
        let before = draft
        XCTAssertFalse(draft.merge())
        XCTAssertEqual(draft, before)
        XCTAssertTrue(draft.merge(confirmed: true))
        XCTAssertEqual(draft.assignments, [ids[0]: windows[0]])
        XCTAssertEqual(draft.root.leafIDs.count, 2)
        draft.undo()
        XCTAssertEqual(draft, before)
    }

    func testNestedSplitMustBeMergedFromTheInsideFirst() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        let left = draft.root.leafIDs[0]
        let right = draft.root.leafIDs[1]
        draft.selectedRegion = right
        XCTAssertTrue(draft.split(.bottom))
        draft.selectedRegion = left
        XCTAssertNil(draft.mergeRegion)
        XCTAssertFalse(draft.merge(confirmed: true))
        draft.selectedRegion = draft.root.region(right)?.leafIDs.first
        XCTAssertTrue(draft.merge())
        draft.selectedRegion = left
        XCTAssertTrue(draft.merge())
        XCTAssertEqual(draft.root.leafIDs.count, 1)
    }

    func testRemovingOneRegionPreservesOtherAssignmentsAndUndoRestoresTheDraft() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.grid.makeRegion())
        let ids = draft.root.leafIDs
        for id in ids { draft.assign(UUID(), to: id) }
        draft.selectedRegion = ids[3]
        let before = draft
        XCTAssertTrue(draft.removeRegion(ids[0]))
        XCTAssertEqual(draft.root.leafIDs.count, 3)
        XCTAssertNil(draft.assignments[ids[0]])
        for id in ids.dropFirst() { XCTAssertEqual(draft.assignments[id], before.assignments[id]) }
        XCTAssertEqual(draft.selectedRegion, ids[3])
        XCTAssertTrue(draft.isComplete)
        let expanded = draft.root.leaves.first { $0.region.id == ids[1] }
        XCTAssertEqual(expanded?.frame, CGRect(x: 0, y: 0, width: 0.5, height: 1))
        assertTiling(draft.root)
        draft.undo()
        XCTAssertEqual(draft, before)
    }

    func testRemovingRegionNextToNestedGroupExpandsThatGroupWithoutLosingItsRatios() {
        let top = LayoutRegion.leaf(UUID()), bottom = LayoutRegion.leaf(UUID())
        let group = LayoutRegion.split(UUID(), .rows, 0.35, top, bottom)
        let removed = LayoutRegion.leaf(UUID())
        var draft = MultiWindowLayoutDraft(root: .split(UUID(), .columns, 0.6, group, removed))
        for id in draft.root.leafIDs { draft.assign(UUID(), to: id) }
        draft.selectedRegion = removed.id
        let before = draft
        XCTAssertTrue(draft.removeRegion(removed.id))
        XCTAssertEqual(draft.root, group)
        XCTAssertEqual(draft.selectedRegion, top.id)
        XCTAssertEqual(draft.assignments[top.id], before.assignments[top.id])
        XCTAssertEqual(draft.assignments[bottom.id], before.assignments[bottom.id])
        XCTAssertEqual(draft.root.leaves[0].frame, CGRect(x: 0, y: 0, width: 1, height: 0.35))
        assertTiling(draft.root, in: CGRect(x: -1440, y: 33, width: 1440, height: 867))
        draft.undo()
        XCTAssertEqual(draft, before)
    }

    func testRemovingLastRegionOrAnythingOtherThanALeafDoesNothing() {
        var single = MultiWindowLayoutDraft(root: .leaf(UUID()))
        let before = single
        XCTAssertFalse(single.removeRegion(single.root.id))
        XCTAssertFalse(single.removeRegion(UUID()))
        XCTAssertEqual(single, before)
        var split = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        let splitBefore = split
        XCTAssertFalse(split.removeRegion(split.root.id))
        XCTAssertEqual(split, splitBefore)
    }

    func testDuplicateWindowIsRejectedAndCurrentAssignmentCanBeReplacedOrCleared() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        let ids = draft.root.leafIDs
        let window = UUID()
        XCTAssertTrue(draft.assign(window, to: ids[0]))
        XCTAssertFalse(draft.assign(window, to: ids[1]))
        XCTAssertFalse(draft.assign(UUID(), to: UUID()))
        XCTAssertTrue(draft.assign(window, to: ids[0]))
        XCTAssertTrue(draft.assign(nil, to: ids[0]))
        XCTAssertTrue(draft.assign(window, to: ids[1]))
    }

    func testApplyCompletenessRequiresEveryLeaf() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.grid.makeRegion())
        XCTAssertFalse(draft.isComplete)
        let ids = draft.root.leafIDs
        for id in ids.dropLast() { XCTAssertTrue(draft.assign(UUID(), to: id)) }
        XCTAssertFalse(draft.isComplete)
        XCTAssertTrue(draft.assign(UUID(), to: ids.last!))
        XCTAssertTrue(draft.isComplete)
        XCTAssertTrue(draft.assign(nil, to: ids[0]))
        XCTAssertFalse(draft.isComplete)
    }

    func testRatioChangesRetainAllWindowChoicesAndUndoAsOneDrag() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        for id in draft.root.leafIDs { draft.assign(UUID(), to: id) }
        let before = draft
        draft.checkpoint()
        for ratio in [0.55, 0.60, 0.65, 0.70] { draft.resize(draft.root.id, ratio: ratio) }
        XCTAssertEqual(draft.assignments, before.assignments)
        XCTAssertEqual(draft.root.leaves[0].frame.width, 0.70, accuracy: 0.000001)
        draft.undo()
        XCTAssertEqual(draft, before)
    }

    func testGridCollinearDividersMoveTogetherAndStayAlignedAfterColumnResize() {
        let root = LayoutStartingPoint.grid.makeRegion()
        guard case .split(_, _, _, let left, let right) = root else { return XCTFail() }
        let resized = root.resizing(left.id, ratio: 0.7)
        XCTAssertEqual(resized.region(left.id)?.leaves[0].frame.height, 0.7)
        XCTAssertEqual(resized.region(right.id)?.leaves[0].frame.height, 0.7)
        let wider = resized.resizing(root.id, ratio: 0.65)
        let rowDividers = wider.placements().filter {
            if case .split(_, .rows, _, _, _) = $0.region { return true }; return false
        }
        XCTAssertEqual(rowDividers.count, 2)
        assertTiling(wider)
    }

    func testIndependentNonCollinearDividerDoesNotFollow() {
        let left = LayoutRegion.split(UUID(), .rows, 0.35, .leaf(UUID()), .leaf(UUID()))
        let right = LayoutRegion.split(UUID(), .rows, 0.6, .leaf(UUID()), .leaf(UUID()))
        let root = LayoutRegion.split(UUID(), .columns, 0.5, left, right)
        let resized = root.resizing(left.id, ratio: 0.75)
        XCTAssertEqual(resized.region(right.id), right)
        assertTiling(resized)
    }

    func testProportionalStopsSnapAndInvalidRatiosLeaveDraftUntouched() {
        let root = LayoutStartingPoint.columns.makeRegion()
        XCTAssertEqual(root.resizing(root.id, ratio: 0.499), root)
        XCTAssertEqual(root.resizing(root.id, ratio: .nan), root)
        XCTAssertEqual(root.resizing(UUID(), ratio: 0.7), root)
    }

    func testSplitAndResizeUseActualAvailableSpaceInsteadOfACellCountLimit() {
        var draft = MultiWindowLayoutDraft(root: .leaf(UUID()))
        let minimum = CGSize(width: 0.18, height: 0.18)
        XCTAssertTrue(draft.split(.right, minimumSize: minimum))
        XCTAssertTrue(draft.split(.right, minimumSize: minimum))
        let before = draft
        XCTAssertFalse(draft.split(.right, minimumSize: minimum))
        XCTAssertEqual(draft, before)
        XCTAssertTrue(draft.split(.bottom, minimumSize: minimum))
        XCTAssertTrue(draft.root.fits(minimumSize: minimum))
        let rootBefore = draft.root
        draft.resize(draft.root.id, ratio: 0.1, minimumSize: minimum)
        XCTAssertEqual(draft.root, rootBefore)
    }

    func testReplacingTemplateCanBeUndoneWithItsWindowChoices() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        draft.assign(UUID(), to: draft.root.leafIDs[0])
        let before = draft
        draft.replace(with: LayoutStartingPoint.grid.makeRegion())
        XCTAssertTrue(draft.assignments.isEmpty)
        draft.undo()
        XCTAssertEqual(draft, before)
    }

    func testTemplatesPersistOnlyNameIdentityStructureAndRatios() throws {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.largeLeft.makeRegion())
        let window = UUID()
        draft.assign(window, to: draft.root.leafIDs[0])
        let template = LayoutTemplate(name: "My layout", root: draft.root)
        let data = try JSONEncoder().encode(template)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(window.uuidString))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "name", "root"])
        XCTAssertEqual(try JSONDecoder().decode(LayoutTemplate.self, from: data), template)
        XCTAssertTrue(MultiWindowLayoutDraft(root: template.root).assignments.isEmpty)
    }

    func testLayoutComparisonIgnoresRegionIDsAndEquivalentSplitOrder() {
        for start in LayoutStartingPoint.allCases {
            let root = start.makeRegion()
            let copy = start.makeRegion()
            XCTAssertNotEqual(root, copy)
            XCTAssertTrue(root.hasSameLayout(as: copy))
        }
        let columns = { LayoutRegion.split(UUID(), .columns, 0.5, .leaf(UUID()), .leaf(UUID())) }
        let grid = LayoutRegion.split(UUID(), .rows, 0.5, columns(), columns())
        XCTAssertTrue(grid.hasSameLayout(as: LayoutStartingPoint.grid.makeRegion()))
        XCTAssertTrue(LayoutRegion.leaf(UUID()).hasSameLayout(as: .leaf(UUID())))
    }

    func testLayoutComparisonDistinguishesDifferentPositionsAndProportions() {
        let columns = LayoutStartingPoint.columns.makeRegion()
        XCTAssertFalse(columns.hasSameLayout(as: LayoutStartingPoint.rows.makeRegion()))
        XCTAssertFalse(columns.hasSameLayout(as: LayoutStartingPoint.grid.makeRegion()))
        let resized = LayoutRegion.split(UUID(), .columns, 0.50000001, .leaf(UUID()), .leaf(UUID()))
        XCTAssertFalse(columns.hasSameLayout(as: resized))
        let mirrored = LayoutRegion.split(UUID(), .columns, 1.0 / 3,
                                         .split(UUID(), .rows, 0.5, .leaf(UUID()), .leaf(UUID())), .leaf(UUID()))
        XCTAssertFalse(mirrored.hasSameLayout(as: LayoutStartingPoint.largeLeft.makeRegion()))
    }

    func testMalformedStructuresAreRejected() {
        let duplicate = UUID()
        XCTAssertFalse(LayoutRegion.split(UUID(), .rows, 0.5, .leaf(duplicate), .leaf(duplicate)).isValid)
        for ratio in [-1.0, 0.0, 1.0, .nan, .infinity] {
            XCTAssertFalse(LayoutRegion.split(UUID(), .columns, ratio, .leaf(UUID()), .leaf(UUID())).isValid)
        }
    }

    func testManyDeterministicEditsNeverCreateOverlapsHolesOrOutOfBoundsRegions() {
        var state: UInt64 = 0x746964657374
        func next(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state % UInt64(count))
        }
        var draft = MultiWindowLayoutDraft(root: .leaf(UUID()))
        for _ in 0..<220 {
            let ids = draft.root.leafIDs
            draft.selectedRegion = ids[next(ids.count)]
            switch next(5) {
            case 0: _ = draft.merge(confirmed: true)
            case 1: _ = draft.removeRegion(draft.selectedRegion!)
            default: _ = draft.split([LayoutSplitEdge.left, .right, .top, .bottom][next(4)], minimumSize: CGSize(width: 0.05, height: 0.05))
            }
            let splits = draft.root.placements().filter { if case .split = $0.region { return true }; return false }
            if !splits.isEmpty {
                draft.resize(splits[next(splits.count)].region.id, ratio: Double(next(70) + 15) / 100,
                             minimumSize: CGSize(width: 0.05, height: 0.05))
            }
            XCTAssertTrue(draft.root.isValid)
            assertTiling(draft.root)
        }
    }

    func testDroppingInTheCenterSwapsOnlyWindowChoicesAndUndoesInOneStep() throws {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.largeLeft.makeRegion())
        let ids = draft.root.leafIDs
        let windows = [UUID(), UUID(), UUID()]
        for (region, window) in zip(ids, windows) { draft.assign(window, to: region) }
        let before = draft
        let preview = try XCTUnwrap(draft.previewingDrop(from: ids[0], to: .swap(ids[2])))
        XCTAssertEqual(draft, before, "Preview must not mutate the live draft or its history")
        XCTAssertEqual(preview.root, before.root)
        XCTAssertTrue(draft.drop(from: ids[0], to: .swap(ids[2])))
        XCTAssertEqual(draft.assignments, [ids[0]: windows[2], ids[1]: windows[1], ids[2]: windows[0]])
        XCTAssertTrue(draft.isComplete)
        draft.undo()
        XCTAssertEqual(draft, before)
    }

    func testSwappingWithAnEmptyCellMovesTheWindowWithoutDuplicatingIt() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        let ids = draft.root.leafIDs
        let window = UUID()
        draft.assign(window, to: ids[0])
        let before = draft
        XCTAssertTrue(draft.drop(from: ids[0], to: .swap(ids[1])))
        XCTAssertEqual(draft.assignments, [ids[1]: window])
        XCTAssertFalse(draft.isComplete)
        draft.undo()
        XCTAssertEqual(draft, before)
    }

    func testMovingLargeLeftCellToRightPreservesItsWidthAndTheTwoSmallCellsOrder() throws {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.largeLeft.makeRegion())
        let ids = draft.root.leafIDs
        for id in ids { draft.assign(UUID(), to: id) }
        let before = draft
        XCTAssertTrue(draft.drop(from: ids[0], to: .move(.right)))
        let frames = Dictionary(uniqueKeysWithValues: draft.root.leaves.map { ($0.region.id, $0.frame) })
        let large = try XCTUnwrap(frames[ids[0]])
        XCTAssertEqual(large.minX, 1.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(large.width, 2.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(large.height, 1)
        XCTAssertEqual(frames[ids[1]], CGRect(x: 0, y: 0, width: large.minX, height: 0.5))
        XCTAssertEqual(frames[ids[2]], CGRect(x: 0, y: 0.5, width: large.minX, height: 0.5))
        XCTAssertEqual(draft.assignments, before.assignments)
        XCTAssertTrue(draft.isComplete)
        assertTiling(draft.root)
        draft.undo()
        XCTAssertEqual(draft, before)
    }

    func testMovingAnEmptyNestedCellToAnyEdgeKeepsEveryCellAndThePreviewMatchesCommit() throws {
        for edge in [LayoutSplitEdge.left, .right, .top, .bottom] {
            var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.grid.makeRegion())
            let original = draft
            let source = draft.root.leafIDs[0]
            let preview = try XCTUnwrap(draft.previewingDrop(from: source, to: .move(edge)))
            XCTAssertFalse(preview.canUndo, "Hovering a target must not add an undo step")
            XCTAssertEqual(draft, original)
            XCTAssertTrue(draft.drop(from: source, to: .move(edge)))
            XCTAssertEqual(draft.root, preview.root)
            XCTAssertEqual(Set(draft.root.leafIDs), Set(original.root.leafIDs))
            let frame = try XCTUnwrap(draft.root.leaves.first { $0.region.id == source }?.frame)
            switch edge {
            case .left: XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 0.5, height: 1))
            case .right: XCTAssertEqual(frame, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
            case .top: XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1, height: 0.5))
            case .bottom: XCTAssertEqual(frame, CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
            }
            assertTiling(draft.root)
            draft.undo()
            XCTAssertEqual(draft, original)
        }
    }

    func testMovingAFullHeightColumnToTopLeavesRoomForTheOtherCells() throws {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.largeLeft.makeRegion())
        let source = draft.root.leafIDs[0]
        XCTAssertTrue(draft.drop(from: source, to: .move(.top)))
        let frame = try XCTUnwrap(draft.root.leaves.first { $0.region.id == source }?.frame)
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1, height: 0.5))
        assertTiling(draft.root)
    }

    func testMovingANinetyPercentCellToTheOppositeEdgeKeepsTheRatioWithinBounds() throws {
        let source = LayoutRegion.leaf(UUID())
        var draft = MultiWindowLayoutDraft(root: .split(UUID(), .columns, 0.9, source, .leaf(UUID())))
        XCTAssertTrue(draft.drop(from: source.id, to: .move(.right)))
        let frame = try XCTUnwrap(draft.root.leaves.first { $0.region.id == source.id }?.frame)
        XCTAssertEqual(frame.width, 0.9, accuracy: 0.000001)
        XCTAssertTrue(draft.root.isValid)
        assertTiling(draft.root)
    }

    func testInvalidNoOpAndTooSmallDropsLeaveTheDraftAndHistoryUntouched() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.grid.makeRegion())
        let ids = draft.root.leafIDs
        let before = draft
        for (source, target) in [(ids[0], LayoutRegionDropTarget.swap(ids[0])),
                                 (ids[0], .swap(ids[1])), (UUID(), .move(.left)),
                                 (ids[0], .swap(UUID()))] {
            XCTAssertNil(draft.previewingDrop(from: source, to: target))
            XCTAssertFalse(draft.drop(from: source, to: target))
            XCTAssertEqual(draft, before)
        }
        XCTAssertFalse(draft.drop(from: ids[0], to: .move(.right), minimumSize: CGSize(width: 0.3, height: 0.3)))
        XCTAssertEqual(draft, before)
        var columns = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        XCTAssertFalse(columns.drop(from: columns.root.leafIDs[0], to: .move(.left)))
        XCTAssertFalse(columns.canUndo)
        var single = MultiWindowLayoutDraft(root: .leaf(UUID()))
        XCTAssertFalse(single.drop(from: single.root.id, to: .move(.bottom)))
        XCTAssertFalse(single.canUndo)
    }

    func testDropHitTestingDistinguishesScreenEdgesCellCentersAndOutsideTheCanvas() {
        let root = LayoutStartingPoint.largeLeft.makeRegion()
        let source = root.leafIDs[0]
        let size = CGSize(width: 1200, height: 800)
        XCTAssertEqual(LayoutRegionDropTarget.hitTest(CGPoint(x: 1100, y: 200), in: size, root: root, source: source), .swap(root.leafIDs[1]))
        XCTAssertEqual(LayoutRegionDropTarget.hitTest(CGPoint(x: 1190, y: 200), in: size, root: root, source: source), .move(.right))
        XCTAssertEqual(LayoutRegionDropTarget.hitTest(CGPoint(x: 600, y: 8), in: size, root: root, source: source), .move(.top))
        XCTAssertEqual(LayoutRegionDropTarget.hitTest(CGPoint(x: 8, y: 400), in: size, root: root, source: source), .move(.left))
        XCTAssertEqual(LayoutRegionDropTarget.hitTest(CGPoint(x: 600, y: 800), in: size, root: root, source: source), .move(.bottom))
        for point in [CGPoint(x: 300, y: 400), CGPoint(x: -1, y: 200), CGPoint(x: 1201, y: 400),
                      CGPoint(x: 300, y: -1), CGPoint(x: 300, y: 801), CGPoint(x: CGFloat.nan, y: 10)] {
            XCTAssertNil(LayoutRegionDropTarget.hitTest(point, in: size, root: root, source: source))
        }
    }

    func testRepeatedMovesAndSwapsKeepAllWindowChoicesAndNeverCreateGapsOrOverlaps() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.grid.makeRegion())
        let ids = draft.root.leafIDs
        for id in ids { draft.assign(UUID(), to: id) }
        let windows = Set(draft.assignments.values)
        for index in 0..<100 {
            let source = ids[index % ids.count]
            _ = draft.drop(from: source, to: .move([LayoutSplitEdge.left, .top, .right, .bottom][index / 4 % 4]),
                           minimumSize: CGSize(width: 0.04, height: 0.04))
            _ = draft.drop(from: source, to: .swap(ids[(index + 1) % ids.count]))
            XCTAssertEqual(Set(draft.root.leafIDs), Set(ids))
            XCTAssertEqual(Set(draft.assignments.values), windows)
            XCTAssertTrue(draft.isComplete)
            assertTiling(draft.root, in: CGRect(x: -1440, y: 33, width: 1440, height: 867))
        }
    }

    private func assertTiling(_ root: LayoutRegion, in area: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), file: StaticString = #filePath, line: UInt = #line) {
        let frames = root.placements(in: area).filter { if case .leaf = $0.region { return true }; return false }.map(\.frame)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.width * $1.height }, area.width * area.height,
                       accuracy: 0.000001, file: file, line: line)
        for (index, frame) in frames.enumerated() {
            XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, area.minX - 0.000001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, area.minY - 0.000001, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, area.maxX + 0.000001, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, area.maxY + 0.000001, file: file, line: line)
            for other in frames.dropFirst(index + 1) {
                let intersection = frame.intersection(other)
                XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.000001, file: file, line: line)
            }
        }
    }
}
