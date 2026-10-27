import XCTest
@testable import tidest

final class UsageTimelineTests: XCTestCase {
    func testLayoutPanelAppearsAfterTheShortcutAndClosesBeforePlacement() {
        func at(_ seconds: Double) -> UsageTimeline {
            UsageTimeline(progress: seconds / UsageTimeline.duration)
        }
        XCTAssertEqual(at(0).layoutPanelOpacity, 0)
        XCTAssertEqual(at(1.1).layoutPanelOpacity, 0)
        XCTAssertEqual(at(1.35).layoutPanelOpacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(at(1.6).layoutPanelOpacity, 1)
        XCTAssertEqual(at(5.8).layoutPanelOpacity, 0)
        XCTAssertEqual(at(5.8).layoutPlacement, 0)
        XCTAssertEqual(at(6.35).layoutPlacement, 0.5, accuracy: 0.001)
        XCTAssertEqual(at(6.8).layoutPlacement, 1)
    }

    func testSeekingCanStopBetweenThePickupAndTheDock() {
        let beginning = UsageTimeline(progress: 3.2 / UsageTimeline.duration)
        let midway = UsageTimeline(progress: 3.95 / UsageTimeline.duration)
        let end = UsageTimeline(progress: 4.7 / UsageTimeline.duration)
        XCTAssertEqual(beginning.dockFlight, 0)
        XCTAssertEqual(midway.dockFlight, 0.5, accuracy: 0.001)
        XCTAssertEqual(end.dockFlight, 1)
    }

    func testStepButtonsSeekInsideTheirOwnStepAndTheEndStaysAtTheEnd() {
        for (step, position) in UsageTimeline.stepPositions.enumerated() {
            XCTAssertEqual(UsageTimeline(progress: position).step, step)
        }
        let end = UsageTimeline(progress: 1)
        XCTAssertEqual(end.step, 2)
        XCTAssertEqual(end.time, 9)
        XCTAssertEqual(end.layoutPlacement, 1)
    }
}
