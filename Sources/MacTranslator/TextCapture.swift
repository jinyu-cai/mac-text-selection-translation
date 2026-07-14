import AppKit
import MacTranslatorCore

/// Grabs the currently selected text from whatever app is frontmost by
/// posting a synthetic ⌘C and reading the pasteboard, then (optionally)
/// restoring the previous clipboard contents.
enum TextCapture {
    @MainActor
    static func captureSelectedText(restore: Bool) async -> String? {
        guard !Task.isCancelled else { return nil }

        // If a mouse button is still down (e.g. the hotkey fired mid-drag),
        // wait for the release (up to ~1s) so the ⌘C lands on the finished
        // selection instead of in the middle of the drag.
        for _ in 0..<40 {
            guard NSEvent.pressedMouseButtons != 0 else { break }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return nil
            }
        }

        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let saved = restore ? snapshotItems(pasteboard) : nil

        simulateCopy()

        // Poll for the pasteboard to change (up to ~450ms).
        var captured: String?
        var capturedChangeCount: Int?
        for _ in 0..<30 {
            do {
                try await Task.sleep(nanoseconds: 15_000_000)
            } catch {
                return nil
            }
            if pasteboard.changeCount != previousChangeCount {
                captured = pasteboard.string(forType: .string)
                capturedChangeCount = pasteboard.changeCount
                break
            }
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

        return captured?.trimmingCharacters(in: .whitespacesAndNewlines)
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
