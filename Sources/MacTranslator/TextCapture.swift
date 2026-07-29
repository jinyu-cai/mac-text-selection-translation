import AppKit
import ApplicationServices
import MacTranslatorCore

/// Grabs the currently selected text from the focused UI element, falling
/// back to a synthetic ⌘C for apps that do not expose their selection through
/// Accessibility. Clipboard fallback can optionally restore the old contents.
enum TextCapture {
    private static let mouseReleasePollInterval: UInt64 = 25_000_000
    private static let selectionSettleDelay: UInt64 = 80_000_000
    private static let copyPollInterval: UInt64 = 15_000_000
    private static let copyPollIterations = 20

    @MainActor
    static func captureSelectedText(restore: Bool) async -> String? {
        guard !Task.isCancelled else { return nil }

        // If a mouse button is still down (e.g. the hotkey fired mid-drag),
        // wait for the release (up to ~1s) so the ⌘C lands on the finished
        // selection instead of in the middle of the drag.
        for _ in 0..<40 {
            guard NSEvent.pressedMouseButtons != 0 else { break }
            do {
                try await Task.sleep(nanoseconds: mouseReleasePollInterval)
            } catch {
                return nil
            }
        }

        // Mouse-up and the source app's selected-text state are not committed
        // atomically. In particular, browsers and Electron apps can still
        // report the previous/empty selection for the first few run-loop turns.
        do {
            try await Task.sleep(nanoseconds: selectionSettleDelay)
        } catch {
            return nil
        }

        // Prefer the side-effect-free Accessibility path. Besides preserving
        // the clipboard, it avoids relying on the first synthetic key event
        // being accepted by the source app.
        if let captured = accessibilitySelectedText() {
            return captured
        }

        let pasteboard = NSPasteboard.general
        let saved = restore ? snapshotItems(pasteboard) : nil

        var captured: String?
        var capturedChangeCount: Int?
        let unchangedChangeCount = pasteboard.changeCount
        for attempt in 1...SelectionCapturePolicy.maximumCopyAttempts {
            // A slow first copy can land exactly between polling rounds. Read
            // it before posting another key event so a successful late result
            // is not mistaken for the new baseline.
            if pasteboard.changeCount != unchangedChangeCount {
                captured = normalized(pasteboard.string(forType: .string))
                capturedChangeCount = pasteboard.changeCount
                break
            }

            simulateCopy()

            // Poll for this copy to change the pasteboard (up to ~300ms).
            var pasteboardChanged = false
            for _ in 0..<copyPollIterations {
                do {
                    try await Task.sleep(nanoseconds: copyPollInterval)
                } catch {
                    return nil
                }
                if pasteboard.changeCount != unchangedChangeCount {
                    captured = normalized(pasteboard.string(forType: .string))
                    capturedChangeCount = pasteboard.changeCount
                    pasteboardChanged = true
                    break
                }
            }

            if captured != nil {
                break
            }
            guard SelectionCapturePolicy.shouldRetryCopy(
                completedAttempts: attempt,
                pasteboardChanged: pasteboardChanged
            ) else { break }
        }

        // Restore only the exact pasteboard generation we observed from the
        // synthetic copy. A later generation may be an intentional user copy
        // and must never be overwritten. Do not run a delayed restore after a
        // timeout because its origin can no longer be distinguished safely.
        if let saved,
           ClipboardRestorePolicy.shouldRestore(
               capturedChangeCount: capturedChangeCount,
               currentChangeCount: pasteboard.changeCount
           ) {
            restoreItems(pasteboard, from: saved)
        }

        return captured
    }

    private static func accessibilitySelectedText() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue
        else {
            return nil
        }

        let focusedElement = focusedValue as! AXUIElement
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
        let selectedValue
        else {
            return nil
        }

        if let text = selectedValue as? String {
            return normalized(text)
        }
        if let attributedText = selectedValue as? NSAttributedString {
            return normalized(attributedText.string)
        }
        return nil
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func simulateCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // After posting a synthetic event, macOS suppresses real keyboard and
        // mouse input for ~250ms by default, which visibly stalls or breaks a
        // drag-selection overlapping the capture. Keep local events flowing.
        source?.localEventsSuppressionInterval = 0
        let permitAll: CGEventFilterMask = [
            .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents,
        ]
        source?.setLocalEventsFilterDuringSuppressionState(
            permitAll, state: .eventSuppressionStateSuppressionInterval
        )
        source?.setLocalEventsFilterDuringSuppressionState(
            permitAll, state: .eventSuppressionStateRemoteMouseDrag
        )

        let cKey: CGKeyCode = 0x08 // ANSI "C"
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshotItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy.types.isEmpty ? nil : copy
        } ?? []
    }

    private static func restoreItems(_ pasteboard: NSPasteboard, from items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
