import AppKit

/// Watches global mouse events to decide when the user has likely selected
/// text (a drag, or a double/triple click), so we can offer the floating icon.
final class SelectionWatcher {
    var onSelection: ((NSPoint) -> Void)?
    var onDismiss: (() -> Void)?

    private var monitors: [Any] = []
    private var mouseDownLocation: NSPoint = .zero
    private var didDrag = false
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        addMonitor(.leftMouseDown) { [weak self] _ in
            self?.mouseDownLocation = NSEvent.mouseLocation
            self?.didDrag = false
            self?.onDismiss?()
        }
        addMonitor(.leftMouseDragged) { [weak self] _ in
            self?.didDrag = true
        }
        addMonitor(.leftMouseUp) { [weak self] event in
            guard let self else { return }
            let location = NSEvent.mouseLocation
            let movedFar = self.didDrag && Self.distance(self.mouseDownLocation, location) > 6
            let multiClick = event.clickCount >= 2
            guard movedFar || multiClick else { return }
            // Small delay so the selection settles in the source app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.onSelection?(location)
            }
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        isRunning = false
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(monitor)
        }
    }

    private static func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    deinit { stop() }
}
