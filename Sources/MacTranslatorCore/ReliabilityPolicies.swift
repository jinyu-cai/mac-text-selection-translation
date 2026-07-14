import AppKit
import ServiceManagement

public enum ClipboardRestorePolicy {
    public static func shouldRestore(capturedChangeCount: Int?, currentChangeCount: Int) -> Bool {
        guard let capturedChangeCount else { return false }
        return capturedChangeCount == currentChangeCount
    }
}

public enum LoginItemRegistrationPolicy {
    public static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
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
