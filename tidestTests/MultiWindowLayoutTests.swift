import Foundation
import XCTest
#if os(Linux)
@testable import LayoutLogic
#else
@testable import tidest
#endif

final class MultiWindowLayoutTests: XCTestCase {
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

    func testSplittingAssignedRegionRequiresConfirmationAndPreservesOtherChoices() {
        var draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        let ids = draft.root.leafIDs
        let first = UUID(), second = UUID()
        XCTAssertTrue(draft.assign(first, to: ids[0]))
        XCTAssertTrue(draft.assign(second, to: ids[1]))
        draft.selectedRegion = ids[0]
        let before = draft
        XCTAssertFalse(draft.split(.rows))
        XCTAssertEqual(draft, before)
        XCTAssertTrue(draft.split(.rows, confirmed: true))
        XCTAssertNil(draft.assignments[ids[0]])
        XCTAssertEqual(draft.assignments[ids[1]], second)
        XCTAssertEqual(draft.assignments.count, 1)
        draft.undo()
        XCTAssertEqual(draft, before)
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
        XCTAssertTrue(draft.split(.rows))
        draft.selectedRegion = left
        XCTAssertNil(draft.mergeRegion)
        XCTAssertFalse(draft.merge(confirmed: true))
        draft.selectedRegion = draft.root.region(right)?.leafIDs.first
        XCTAssertTrue(draft.merge())
        draft.selectedRegion = left
        XCTAssertTrue(draft.merge())
        XCTAssertEqual(draft.root.leafIDs.count, 1)
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
        XCTAssertTrue(draft.split(.columns, minimumSize: minimum))
        XCTAssertTrue(draft.split(.columns, minimumSize: minimum))
        let before = draft
        XCTAssertFalse(draft.split(.columns, minimumSize: minimum))
        XCTAssertEqual(draft, before)
        XCTAssertTrue(draft.split(.rows, minimumSize: minimum))
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
            if next(3) == 0 { _ = draft.merge(confirmed: true) }
            else { _ = draft.split(next(2) == 0 ? .columns : .rows, confirmed: true, minimumSize: CGSize(width: 0.05, height: 0.05)) }
            let splits = draft.root.placements().filter { if case .split = $0.region { return true }; return false }
            if !splits.isEmpty {
                draft.resize(splits[next(splits.count)].region.id, ratio: Double(next(70) + 15) / 100,
                             minimumSize: CGSize(width: 0.05, height: 0.05))
            }
            XCTAssertTrue(draft.root.isValid)
            assertTiling(draft.root)
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
