import AppKit
import ServiceManagement

public enum ClipboardRestorePolicy {
    public static func shouldRestore(capturedChangeCount: Int?, currentChangeCount: Int) -> Bool {
        guard let capturedChangeCount else { return false }
        return capturedChangeCount == currentChangeCount
    }
}

public enum SelectionCapturePolicy {
    public static let maximumCopyAttempts = 2
    public static let minimumSelectionDragDistance: CGFloat = 2

    /// A retry is useful only when the previous synthetic copy did not touch
    /// the pasteboard. Once it changed, retrying could overwrite a real copy
    /// made by the user and makes the clipboard's origin ambiguous.
    public static func shouldRetryCopy(
        completedAttempts: Int,
        pasteboardChanged: Bool
    ) -> Bool {
        completedAttempts < maximumCopyAttempts && !pasteboardChanged
    }

    /// AppKit already filters ordinary click jitter before emitting a drag
    /// event, so a small real drag can represent a one-character selection.
    public static func isLikelySelectionGesture(
        didDrag: Bool,
        dragDistance: CGFloat,
        clickCount: Int
    ) -> Bool {
        (didDrag && dragDistance >= minimumSelectionDragDistance) || clickCount >= 2
    }
}

public enum LoginItemRegistrationPolicy {
    public static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }
}

public enum ListOrderingPolicy {
    /// Returns a copy with one item moved to its final destination index.
    /// Invalid indices are treated as a no-op so UI boundary actions stay safe.
    public static func moving<Element>(
        _ items: [Element],
        from sourceIndex: Int,
        to destinationIndex: Int
    ) -> [Element] {
        guard items.indices.contains(sourceIndex),
              items.indices.contains(destinationIndex),
              sourceIndex != destinationIndex
        else {
            return items
        }

        var reordered = items
        let item = reordered.remove(at: sourceIndex)
        reordered.insert(item, at: destinationIndex)
        return reordered
    }
}

public enum NetworkRetryPolicy {
    public static let maximumAttempts = 2

    /// Retries one transient URL-loading failure, but only before any response
    /// content has been delivered to the caller.
    public static func shouldRetry(
        errorDomain: String,
        errorCode: Int,
        completedAttempts: Int,
        hasReceivedContent: Bool
    ) -> Bool {
        guard errorDomain == NSURLErrorDomain,
              completedAttempts < maximumAttempts,
              !hasReceivedContent
        else {
            return false
        }

        let transientCodes: Set<Int> = [
            URLError.timedOut.rawValue,
            URLError.cannotFindHost.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.dnsLookupFailed.rawValue,
            URLError.resourceUnavailable.rawValue,
            URLError.notConnectedToInternet.rawValue,
            URLError.secureConnectionFailed.rawValue,
            URLError.cannotLoadFromNetwork.rawValue,
        ]
        return transientCodes.contains(errorCode)
    }
}

public enum PopupGeometry {
    public static let margin: CGFloat = 8

    public static func constrainedSize(
        _ requested: CGSize,
        minimum: CGSize,
        maximum: CGSize,
        visibleFrame: NSRect
    ) -> CGSize {
        let availableWidth = max(1, visibleFrame.width - margin * 2)
        let availableHeight = max(1, visibleFrame.height - margin * 2)
        let maxWidth = min(maximum.width, availableWidth)
        let maxHeight = min(maximum.height, availableHeight)
        let minWidth = min(minimum.width, maxWidth)
        let minHeight = min(minimum.height, maxHeight)
        return CGSize(
            width: min(max(requested.width, minWidth), maxWidth),
            height: min(max(requested.height, minHeight), maxHeight)
        )
    }

    public static func topLeft(near point: NSPoint, size: CGSize, visibleFrame: NSRect) -> NSPoint {
        var topLeft = NSPoint(x: point.x + 12, y: point.y - 12)
        if topLeft.y - size.height < visibleFrame.minY + margin {
            topLeft.y = point.y + size.height + 12
        }
        let fitted = frame(topLeft: topLeft, size: size, visibleFrame: visibleFrame)
        return NSPoint(x: fitted.minX, y: fitted.maxY)
    }

    public static func frame(topLeft: NSPoint, size: CGSize, visibleFrame: NSRect) -> NSRect {
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - margin - size.width
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - margin - size.height
        let origin = NSPoint(
            x: min(max(topLeft.x, minX), maxX),
            y: min(max(topLeft.y - size.height, minY), maxY)
        )
        return NSRect(origin: origin, size: size)
    }
}
