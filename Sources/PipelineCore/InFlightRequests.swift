import Foundation

/// Tracks cancellable requests by id, with counts, so "requests for off-screen cells are
/// cancelled" is something a test can assert instead of a hope.
///
/// A grid starts a request when a cell appears and cancels it when the cell scrolls away. This
/// class is the bookkeeping for that and knows nothing about PhotoKit: the app passes in the
/// action that starts a request and gets back the action that cancels it. Single-threaded by
/// design (the app uses it from the main actor).
public final class InFlightRequests<ID: Hashable> {
    private var cancelActions: [ID: () -> Void] = [:]

    public private(set) var startedCount = 0
    public private(set) var cancelledCount = 0
    public private(set) var finishedCount = 0

    public init() {}

    /// Requests currently running.
    public var activeCount: Int { cancelActions.count }

    public func isActive(_ id: ID) -> Bool { cancelActions[id] != nil }

    /// Starts a request for `id` unless one is already running for it. `start` returns the action
    /// that cancels the request it started.
    @discardableResult
    public func begin(_ id: ID, start: () -> () -> Void) -> Bool {
        guard cancelActions[id] == nil else { return false }
        cancelActions[id] = start()
        startedCount += 1
        return true
    }

    /// The request for `id` completed normally, so there is nothing left to cancel.
    public func finish(_ id: ID) {
        guard cancelActions.removeValue(forKey: id) != nil else { return }
        finishedCount += 1
    }

    /// Cancels the request for `id` if it is still running.
    public func cancel(_ id: ID) {
        guard let cancel = cancelActions.removeValue(forKey: id) else { return }
        cancelledCount += 1
        cancel()
    }

    public func cancelAll() {
        for id in Array(cancelActions.keys) { cancel(id) }
    }
}
