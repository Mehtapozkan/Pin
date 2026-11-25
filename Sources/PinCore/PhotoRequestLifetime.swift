import Foundation

/// Owns the single terminal transition of a callback-based image request.
/// PhotoKit can call back before it returns a request ID, so cancellation of
/// the waiting task and cancellation of the underlying request are registered
/// separately. No callback is invoked while holding the lock.
public final class PhotoRequestLifetime: @unchecked Sendable {
    private enum State { case pending, completed, cancelled }
    private let lock = NSLock()
    private var state = State.pending
    private var cancelWaiter: (@Sendable () -> Void)?
    private var cancelRequest: (@Sendable () -> Void)?

    public init() {}

    /// Installs the waiter before starting the image request. A task that was
    /// already cancelled is released immediately and must not start a request.
    public func begin(onCancel: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        if state == .cancelled {
            lock.unlock()
            onCancel()
            return false
        }
        guard state == .pending else { lock.unlock(); return false }
        cancelWaiter = onCancel
        lock.unlock()
        return true
    }

    /// Registers the request ID after the underlying API returns. If the task
    /// cancelled during that call, cancel the newly returned request at once.
    public func setRequestCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        let cancelled = state == .cancelled
        if state == .pending { cancelRequest = cancellation }
        lock.unlock()
        if cancelled { cancellation() }
    }

    /// Delivers the first terminal result only. Degraded/progress callbacks
    /// should be ignored by the caller before reaching this method.
    @discardableResult
    public func complete(_ delivery: () -> Void) -> Bool {
        lock.lock()
        guard state == .pending else { lock.unlock(); return false }
        state = .completed
        cancelWaiter = nil
        cancelRequest = nil
        lock.unlock()
        delivery()
        return true
    }

    public func cancel() {
        lock.lock()
        guard state == .pending else { lock.unlock(); return }
        state = .cancelled
        let request = cancelRequest
        let waiter = cancelWaiter
        cancelRequest = nil
        cancelWaiter = nil
        lock.unlock()
        // Release the task even if PhotoKit does not send a cancellation result.
        // Cancel the request first so a replacement scan does not race a still
        // running request whose identifier is already available.
        request?()
        waiter?()
    }
}
