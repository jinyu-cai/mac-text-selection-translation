import AppKit

/// Grabs the currently selected text from whatever app is frontmost by
/// posting a synthetic ⌘C and reading the pasteboard, then (optionally)
/// restoring the previous clipboard contents.
enum TextCapture {
    @MainActor
    static func captureSelectedText(restore: Bool) async -> String? {
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
            restoreItems(pasteboard, from: saved)
        }

        return captured?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func simulateCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
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
