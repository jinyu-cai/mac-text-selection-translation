import AppKit
import Darwin
import MacTranslatorCore
import ServiceManagement

@main
struct ReliabilityTests {
    static func main() {
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        expect(
            ClipboardRestorePolicy.shouldRestore(capturedChangeCount: 42, currentChangeCount: 42),
            "clipboard: observed generation should be restored"
        )
        expect(
            !ClipboardRestorePolicy.shouldRestore(capturedChangeCount: 42, currentChangeCount: 43),
            "clipboard: a newer generation must not be overwritten"
        )
        expect(
            !ClipboardRestorePolicy.shouldRestore(capturedChangeCount: nil, currentChangeCount: 42),
            "clipboard: timeout without an observed copy must not restore later"
        )

        testPopupSize(expect: expect)
        testGrowingPopup(expect: expect)
        testLoginItemState(expect: expect)

        if failures.isEmpty {
            print("All reliability tests passed (13 assertions).")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }

    private static func testPopupSize(expect: (Bool, String) -> Void) {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = PopupGeometry.constrainedSize(
            CGSize(width: 2_000, height: 2_000),
            minimum: CGSize(width: 300, height: 140),
            maximum: CGSize(width: 900, height: 1_000),
            visibleFrame: visible
        )

        expect(size.width == 784, "popup: oversized width should fit the screen")
        expect(size.height == 584, "popup: oversized height should fit the screen")
    }

    private static func testGrowingPopup(expect: (Bool, String) -> Void) {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 360, height: 460)
        // This top-left fits the initial 180pt popup but a 460pt popup would
        // extend below the screen without the post-growth fitting step.
        let frame = PopupGeometry.frame(
            topLeft: NSPoint(x: 212, y: 188),
            size: size,
            visibleFrame: visible
        )

        expect(frame.minX >= visible.minX + PopupGeometry.margin, "popup: left edge escaped")
        expect(frame.maxX <= visible.maxX - PopupGeometry.margin, "popup: right edge escaped")
        expect(frame.minY >= visible.minY + PopupGeometry.margin, "popup: bottom edge escaped")
        expect(frame.maxY <= visible.maxY - PopupGeometry.margin, "popup: top edge escaped")
    }

    private static func testLoginItemState(expect: (Bool, String) -> Void) {
        expect(LoginItemRegistrationPolicy.isRegistered(.enabled), "login item: enabled should be registered")
        expect(
            LoginItemRegistrationPolicy.isRegistered(.requiresApproval),
            "login item: requiresApproval should remain registered"
        )
        expect(
            !LoginItemRegistrationPolicy.isRegistered(.notRegistered),
            "login item: notRegistered should be false"
        )
        expect(!LoginItemRegistrationPolicy.isRegistered(.notFound), "login item: notFound should be false")
    }
}
