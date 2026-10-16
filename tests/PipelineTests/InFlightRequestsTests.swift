import XCTest
@testable import StillMotionsPipeline

final class InFlightRequestsTests: XCTestCase {
    /// A request whose cancellation is observable.
    final class FakeRequest {
        var cancelled = false
    }

    func testScrollingAwayCancelsTheRequestAndOnlyThatRequest() {
        let requests = InFlightRequests<String>()
        var fakes: [String: FakeRequest] = [:]
        for id in ["a", "b", "c"] {
            requests.begin(id) {
                let fake = FakeRequest()
                fakes[id] = fake
                return { fake.cancelled = true }
            }
        }
        XCTAssertEqual(requests.activeCount, 3)
        XCTAssertEqual(requests.startedCount, 3)

        requests.cancel("b") // the cell for "b" scrolled away

        XCTAssertTrue(fakes["b"]!.cancelled)
        XCTAssertFalse(fakes["a"]!.cancelled)
        XCTAssertFalse(fakes["c"]!.cancelled)
        XCTAssertEqual(requests.activeCount, 2)
        XCTAssertEqual(requests.cancelledCount, 1)
    }

    func testACompletedRequestIsNotCancelledLater() {
        let requests = InFlightRequests<Int>()
        var cancelled = false
        requests.begin(1) { { cancelled = true } }
        requests.finish(1)
        requests.cancel(1) // the cell scrolls away after its image arrived: nothing to do
        XCTAssertFalse(cancelled)
        XCTAssertEqual(requests.finishedCount, 1)
        XCTAssertEqual(requests.cancelledCount, 0)
        XCTAssertEqual(requests.activeCount, 0)
    }

    func testAnIdAlreadyInFlightIsNotStartedTwice() {
        let requests = InFlightRequests<Int>()
        var starts = 0
        XCTAssertTrue(requests.begin(7) { starts += 1; return {} })
        XCTAssertFalse(requests.begin(7) { starts += 1; return {} })
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(requests.startedCount, 1)
    }

    func testCancellingSomethingNotRunningIsHarmless() {
        let requests = InFlightRequests<Int>()
        requests.cancel(42)
        requests.finish(42)
        XCTAssertEqual(requests.cancelledCount, 0)
        XCTAssertEqual(requests.finishedCount, 0)
    }

    func testAScrollThroughManyCellsNeverLeavesMoreThanTheVisibleOnesActive() {
        // A 3-column grid showing 24 cells at a time over 600 photos: cells appear as the window
        // moves down and disappear as it passes. Active requests never exceed one window.
        let requests = InFlightRequests<Int>()
        let window = 24
        var peak = 0
        for top in stride(from: 0, to: 600 - window, by: 3) {
            for index in top..<(top + window) { requests.begin(index) { {} } }
            if top >= 3 { for index in (top - 3)..<top { requests.cancel(index) } }
            peak = max(peak, requests.activeCount)
        }
        XCTAssertLessThanOrEqual(peak, window + 3)
        requests.cancelAll()
        XCTAssertEqual(requests.activeCount, 0)
        XCTAssertGreaterThan(requests.cancelledCount, 500, "scrolling past cells cancels their requests")
    }
}
