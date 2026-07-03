import AppKit

/// Grabs the currently selected text from whatever app is frontmost by
/// posting a synthetic ⌘C and reading the pasteboard, then (optionally)
/// restoring the previous clipboard contents.
enum TextCapture {
    @MainActor
    static func captureSelectedText(restore: Bool) async -> String? {
        // If a mouse button is still down (e.g. the hotkey fired mid-drag),
        // wait for the release (up to ~1s) so the ⌘C lands on the finished
        // selection instead of in the middle of the drag.
        for _ in 0..<40 {
            guard NSEvent.pressedMouseButtons != 0 else { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let saved = restore ? snapshotItems(pasteboard) : nil

        simulateCopy()

        // Poll for the pasteboard to change (up to ~450ms).
        var captured: String?
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 15_000_000)
            if pasteboard.changeCount != previousChangeCount {
                captured = pasteboard.string(forType: .string)
                break
            }
        }

        if let saved {
            if captured != nil {
                restoreItems(pasteboard, from: saved)
            } else if pasteboard.changeCount == previousChangeCount {
                // Nothing was copied within the window, but a slow app may
                // still deliver the ⌘C after we gave up — watch briefly and
                // put the previous contents back if that happens. If nothing
                // ever lands, the pasteboard was untouched: no restore needed.
                Task { @MainActor in
                    for _ in 0..<12 {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        if pasteboard.changeCount != previousChangeCount {
                            restoreItems(pasteboard, from: saved)
                            return
                        }
                    }
                }
            } else {
                restoreItems(pasteboard, from: saved)
            }
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
