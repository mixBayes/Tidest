import ApplicationServices
import CoreGraphics
import XCTest
@testable import tidest

final class MultiWindowLayoutServiceTests: XCTestCase {
    func testNonResizableWindowIsSkippedWithoutMovingOrResizing() async {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        var writes = 0
        let result = await MultiWindowLayoutService.performPlacement(
            in: CGRect(x: 0, y: 24, width: 400, height: 800),
            readFrame: { original }, isSettable: { $0 != kAXSizeAttribute },
            setSize: { _ in writes += 1; return .success },
            setPosition: { _ in writes += 1; return .success }, pause: { true })

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(writes, 0)
    }

    func testSizeLimitDiscoveredAfterResizingKeepsClosestTargetPositionAndSize() async {
        let original = CGRect(x: 500, y: 60, width: 800, height: 600)
        var frame = original
        let result = await MultiWindowLayoutService.performPlacement(
            in: CGRect(x: 0, y: 24, width: 400, height: 800),
            readFrame: { frame }, isSettable: { _ in true },
            setSize: {
                frame.size = CGSize(width: max(760, $0.width), height: max(560, $0.height))
                return .success
            },
            setPosition: { frame.origin = $0; return .success }, pause: { true })

        XCTAssertEqual(result, .constrained)
        XCTAssertEqual(frame, CGRect(x: 0, y: 24, width: 760, height: 800))
    }

    func testOperableWindowStillReachesItsRequestedRegion() async {
        let original = CGRect(x: 500, y: 60, width: 800, height: 600)
        let requested = CGRect(x: 0, y: 24, width: 400, height: 800)
        var frame = original
        let result = await MultiWindowLayoutService.performPlacement(in: requested,
            readFrame: { frame }, isSettable: { _ in true },
            setSize: { frame.size = $0; return .success },
            setPosition: { frame.origin = $0; return .success }, pause: { true })

        XCTAssertEqual(result, .exact)
        XCTAssertEqual(frame, requested)
    }

    func testUnavailablePermissionDoesNotAttemptWindowWrites() async {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        var writes = 0
        let result = await MultiWindowLayoutService.performPlacement(
            in: CGRect(x: 0, y: 24, width: 400, height: 800),
            readFrame: { original }, isSettable: { _ in nil },
            setSize: { _ in writes += 1; return .apiDisabled },
            setPosition: { _ in writes += 1; return .apiDisabled }, pause: { true })

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(writes, 0)
    }
}
